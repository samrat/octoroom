// Octoroom browser client.
//
//   import {RoomClient} from "octoroom"
//
//   const room = new RoomClient({socket, topic: `room:${id}`, params: {name}})
//   room.on("participants", (list) => render(list))
//   room.on("tracks", (tracks) => render(tracks))   // video: element.srcObject = track.stream
//   await room.join()   // asks for the mic, publishes it, plays what the server subscribes
//   room.setMuted(true)
//   await room.startCamera()          // or new RoomClient({..., video: true})
//   await room.shareScreen()
//   room.mute("camera", true)         // sends black frames; nothing renegotiates
//   await room.stop("camera")
//   await room.leave()
//
// One RTCPeerConnection to Cloudflare carries what this client publishes
// (sendonly: mic, camera, screen, screen_audio) and every track the server
// pulls into this session. The server decides what this client hears: it
// sends Cloudflare's offers (`renegotiate`), asks for transceivers to be
// closed (`close`), and then says which mid is which track (`tracks`).
// Publishing more later goes through the server's queue too: the server
// asks for an offer (`push`) when it's this session's turn. Signaling is
// serialized: one exchange at a time.
//
// Remote audio plays by itself. Remote video is for the app to show: each
// entry of `tracks()` (and of the "tracks" event) has `kind` ("audio" or
// "video"), `source` ("mic", "camera", "screen", "screen_audio", or null
// for a worker's output), `participant_id` and a `stream` to put in a
// <video>'s srcObject. Whether a participant's camera is muted is in
// `participants`: `participant.tracks.camera.muted`.
//
// Reconnecting: the server hands out a resume token (refreshed with
// `resume_token`). When the Phoenix socket reconnects, the channel rejoins
// with it and the server takes this client back as the same participant
// with the same Cloudflare session, even after a server restart: the peer
// connection stays up the whole time, so audio keeps flowing. If there was
// nothing to resume, the client publishes again on a new peer connection.
// Events: "reconnecting", "reconnected" ({resumed}).
//
// Join timing: once connected, the "timings" event gives what each step
// took, in ms: `join_ms` (the channel join), `media_ms` (getUserMedia,
// including any permission prompt), `ice_ms` (waiting for a first ICE
// candidate, with `ice_timed_out` when none came), `publish_ms` (the server creating the session and
// pushing the tracks) and `connect_ms` (ICE and DTLS to Cloudflare). They go
// to the server too, which reports them as telemetry (`Octoroom.Telemetry`).

// How long the offer waits for a first ICE candidate. See connectMedia.
const ICE_CANDIDATE_WAIT_MS = 100
const CONNECT_TIMEOUT_MS = 15_000
const PUSH_TIMEOUT_MS = 30_000

export class RoomClient {
  /**
   * @param {object} options
   * @param {import("phoenix").Socket} options.socket a connected Phoenix socket
   * @param {string} options.topic e.g. "room:lobby"
   * @param {object} [options.params] passed to the room's join/2
   * @param {MediaStream} [options.stream] publish this instead of asking for the mic; its
   *   video track, if it has one, is published as the camera
   * @param {MediaTrackConstraints|boolean} [options.audio] getUserMedia audio constraints
   * @param {MediaTrackConstraints|boolean} [options.video] also publish the camera on join
   */
  constructor({socket, topic, params = {}, stream = null, audio = true, video = false}) {
    this.socket = socket
    this.topic = topic
    this.params = params
    this.providedStream = stream
    this.audioConstraints = audio
    this.videoConstraints = video
    this.listeners = {}
    this.participants = []
    this.participantId = null
    this.remote = new Map() // mid => {mid, track, kind, source, participant_id, gain, stream, element}
    // What this client publishes: source => {track, owned, muted, transceiver, ready}.
    this.local = new Map()
    this.queue = Promise.resolve()
    this.state = "idle"
    this.resumeToken = null
    // Bumped by every teardown, so a join that's left part way stops.
    this.generation = 0
  }

  on(event, fn) {
    ;(this.listeners[event] ||= []).push(fn)
    return () => (this.listeners[event] = this.listeners[event].filter((f) => f !== fn))
  }

  emit(event, payload) {
    for (const fn of this.listeners[event] || []) {
      try {
        fn(payload)
      } catch (error) {
        console.error(error)
      }
    }
  }

  setState(state) {
    this.state = state
    this.emit("state", state)
  }

  async join() {
    if (this.state !== "idle") throw new Error(`can't join while ${this.state}`)
    this.setState("joining")
    // leave() mid-join rejects the step this join is waiting on, so it
    // settles now rather than when that step times out, and doesn't tear
    // down again (possibly a newer join).
    const generation = this.generation
    const left = new Promise((_, reject) => (this.abortJoin = () => reject(new Error("left while joining"))))
    const step = (promise) => {
      promise.catch(() => {})
      return Promise.race([promise, left])
    }

    try {
      // A function, so a rejoin sends the latest resume token.
      const channel = this.socket.channel(this.topic, () =>
        this.resumeToken ? {...this.params, resume_token: this.resumeToken} : this.params,
      )
      this.channel = channel
      channel.on("renegotiate", (p) => this.serially(() => this.onRenegotiate(p)))
      channel.on("close", (p) => this.serially(() => this.onClose(p)))
      channel.on("push", (p) => this.serially(() => this.onPush(p)))
      channel.on("tracks", (p) => this.serially(() => this.onTracks(p)))
      channel.on("gain", ({mid, gain}) => this.setGain(mid, gain))
      channel.on("room_event", (event) => this.onRoomEvent(event))
      channel.on("resume_token", ({token}) => (this.resumeToken = token))
      channel.on("republish", () => this.serially(() => this.restartMedia()))
      channel.onError(() => this.state === "joined" && this.emit("reconnecting"))
      channel.onClose(() => this.channel === channel && this.teardown("closed"))

      const joinStarted = performance.now()
      const reply = await step(new Promise((resolve, reject) => {
        let joined = false
        channel
          .join(PUSH_TIMEOUT_MS)
          // Phoenix runs these again on every rejoin.
          .receive("ok", (reply) => (joined ? this.onRejoined(reply) : ((joined = true), resolve(reply))))
          .receive("error", (r) => !joined && reject(new Error(r?.reason || "join failed")))
          .receive("timeout", () => !joined && reject(new Error("join timed out")))
      }))
      this.onJoinReply(reply)
      const mediaStarted = performance.now()

      await step(this.openLocalMedia(generation))

      await step(this.connectMedia({join_ms: mediaStarted - joinStarted, media_ms: performance.now() - mediaStarted}))
      this.abortJoin = null
      // Closing the tab looks like a dropped connection, which the server
      // holds for a while in case it comes back: say goodbye instead.
      this.onPageHide = () => this.leave()
      window.addEventListener("pagehide", this.onPageHide)
      this.setState("joined")
      return reply
    } catch (error) {
      if (this.generation === generation) this.teardown("failed")
      throw error
    }
  }

  onJoinReply(reply) {
    this.participantId = reply.participant_id
    this.participants = reply.participants
    this.iceServers = reply.ice_servers
    this.resumeToken = reply.resume_token
    this.emit("participants", this.participants)
  }

  // The mic (and the camera, with `video`) from the provided stream or
  // getUserMedia, asking for both at once so the browser prompts once.
  async openLocalMedia(generation) {
    let stream = this.providedStream
    let owned = false
    if (!stream) {
      const video = this.videoConstraints || false
      stream = await navigator.mediaDevices.getUserMedia({audio: this.audioConstraints, video})
      owned = true
      // Left at the permission prompt: turn the devices back off.
      if (this.generation !== generation) {
        stream.getTracks().forEach((t) => t.stop())
        throw new Error("left while joining")
      }
    }
    this.stream = stream
    const [audio] = stream.getAudioTracks()
    const [video] = stream.getVideoTracks()
    if (audio) this.local.set("mic", {track: audio, owned, muted: false})
    if (video) this.local.set("camera", {track: video, owned, muted: false})
    if (this.local.size === 0) throw new Error("nothing to publish: no audio or video track")
    this.emit("local", this.localTracks())
  }

  onRejoined(reply) {
    this.onJoinReply(reply)
    this.emit("reconnected", {resumed: reply.resumed})
    // A restarted server adopts the session but not the mute flags.
    if (reply.resumed) {
      for (const [source, entry] of this.local) {
        if (entry.muted) this.push("mute", {source, muted: true}).catch(() => {})
      }
    }
    // Nothing to resume (the token expired, or the session was never
    // published): start over as a new participant.
    if (!reply.resumed && this.state === "joined") this.serially(() => this.restartMedia())
  }

  // A peer connection to Cloudflare with every local source published on it.
  // `timings` (ms) are what the join measured before this; with this
  // function's own, they go to the server with `connected` and to the app as
  // a "timings" event.
  async connectMedia(timings = {}) {
    const pc = new RTCPeerConnection({iceServers: this.iceServers, bundlePolicy: "max-bundle"})
    this.pc = pc
    pc.onconnectionstatechange = () => {
      if (this.pc !== pc) return
      this.emit("connection", pc.connectionState)
      if (pc.connectionState === "failed") this.emit("error", new Error("connection failed"))
    }

    const entries = [...this.local]
    for (const [, entry] of entries) entry.transceiver = addSender(pc, entry.track)
    let mark = performance.now()
    const lap = () => {
      const now = performance.now()
      const ms = Math.round(now - mark)
      mark = now
      return ms
    }
    await pc.setLocalDescription(await pc.createOffer())
    // Cloudflare is ICE-lite: this browser sends the connectivity checks,
    // from whatever candidates it has, to the ones in Cloudflare's answer,
    // and Cloudflare learns this browser's address from them. So the offer
    // needn't carry every candidate (Cloudflare takes no trickle ICE, but
    // needs none), and gathering carries on after it's sent: STUN and TURN
    // candidates found later are still used. Waiting for gathering to finish
    // cost the full timeout on every join, as some interface's STUN never
    // answers. The offer waits only for a first candidate, briefly, in case
    // one with none is refused.
    const candidate = await firstCandidate(pc, ICE_CANDIDATE_WAIT_MS)
    timings = {...roundAll(timings), ice_ms: lap(), ice_timed_out: !candidate}

    const mids = Object.fromEntries(entries.map(([source, entry]) => [source, entry.transceiver.mid]))
    const {sdp} = await this.push("publish", {sdp: pc.localDescription.sdp, mids})
    timings.publish_ms = lap()
    await pc.setRemoteDescription({type: "answer", sdp})
    await peerConnected(pc, CONNECT_TIMEOUT_MS)
    timings.connect_ms = lap()
    await this.push("connected", {timings})
    this.emit("timings", timings)
    for (const [source, entry] of entries) {
      if (entry.muted) this.push("mute", {source, muted: true}).catch(() => {})
    }
  }

  // The server lost this client's session: publish again on a new one.
  async restartMedia() {
    if (this.local.size === 0) return
    this.clearRemote()
    this.pc?.close()
    this.pc = null
    await this.connectMedia()
  }

  clearRemote() {
    for (const info of this.remote.values()) removeElement(info.element)
    this.remote.clear()
    this.emit("tracks", [])
  }

  async leave() {
    if (this.state === "idle") return
    this.teardown("left")
  }

  /** Mutes or unmutes the mic. */
  setMuted(muted) {
    this.muted = muted
    if (this.local.has("mic")) this.mute("mic", muted)
    else this.stream?.getAudioTracks().forEach((t) => (t.enabled = !muted))
  }

  /**
   * Mutes or unmutes a published source. The track keeps its transceiver
   * and keeps sending (silence, or black frames), so nothing renegotiates;
   * other participants see `tracks[source].muted`.
   */
  mute(source, muted) {
    const entry = this.local.get(source)
    if (!entry) return
    entry.muted = muted
    entry.track.enabled = !muted
    if (source === "mic") this.muted = muted
    if (this.state === "joined") this.push("mute", {source, muted}).catch(() => {})
    this.emit("local", this.localTracks())
  }

  /** Turns the camera on: a track you give, or one from getUserMedia with these constraints. */
  async startCamera(trackOrConstraints = true) {
    if (trackOrConstraints instanceof MediaStreamTrack) return this.publish({camera: trackOrConstraints})
    const stream = await navigator.mediaDevices.getUserMedia({video: trackOrConstraints})
    return this.publish({camera: stream.getVideoTracks()[0]}, {owned: true})
  }

  /**
   * Shares a screen, window or tab (the browser asks which). Its audio, when
   * the browser offers it, is published as `screen_audio`. Stopping from the
   * browser's own "Stop sharing" button unpublishes both.
   */
  async shareScreen(options = {video: true, audio: true}) {
    const stream = await navigator.mediaDevices.getDisplayMedia(options)
    const [video] = stream.getVideoTracks()
    const [audio] = stream.getAudioTracks()
    const tracks = audio ? {screen: video, screen_audio: audio} : {screen: video}
    video.addEventListener("ended", () => {
      this.stop("screen").catch(() => {})
      if (audio) this.stop("screen_audio").catch(() => {})
    })
    return this.publish(tracks, {owned: true})
  }

  /**
   * Publishes tracks by source, e.g. `{camera: track}`, after joining. With
   * `owned`, the tracks are stopped when unpublished.
   */
  async publish(tracks, {owned = false} = {}) {
    if (this.state !== "joined") throw new Error(`can't publish while ${this.state}`)
    const sources = Object.keys(tracks)
    const taken = sources.find((source) => this.local.has(source))
    if (taken) throw new Error(`${taken} is already published`)

    const request = this.push("publish_tracks", {sources})
    for (const source of sources) {
      this.local.set(source, {track: tracks[source], owned, muted: false, ready: request})
    }
    this.emit("local", this.localTracks())

    try {
      await request
    } catch (error) {
      // The session is being published again from scratch, these included.
      if (error.message === "republishing") return
      for (const source of sources) {
        const entry = this.local.get(source)
        if (entry?.ready !== request) continue
        this.local.delete(source)
        if (owned) entry.track.stop()
      }
      this.emit("local", this.localTracks())
      throw error
    }
  }

  /** Stops publishing a source: everyone's pulls of it close, then its transceiver does. */
  async stop(source) {
    const entry = this.local.get(source)
    if (!entry) return
    await entry.ready?.catch(() => {})
    if (this.local.get(source) !== entry) return
    // Stop sending now (and turn the camera light off); the server closes
    // the transceiver once nobody pulls the track any more.
    entry.transceiver?.sender.replaceTrack(null).catch(() => {})
    if (entry.owned) entry.track.stop()
    this.local.delete(source)
    this.emit("local", this.localTracks())
    if (this.state === "joined") await this.push("unpublish", {source}).catch(() => {})
  }

  /** What this client publishes: {source: {track, muted}}. */
  localTracks() {
    return Object.fromEntries([...this.local].map(([source, {track, muted}]) => [source, {track, muted}]))
  }

  /**
   * Remote tracks this client receives: [{mid, track, kind, source,
   * participant_id, worker_id, gain, stream}]. Audio plays by itself; put a
   * video's `stream` in a <video>'s srcObject.
   */
  tracks() {
    return [...this.remote.values()].map(({element, ...info}) => info)
  }

  /**
   * Audio levels (0..1) per remote participant and for the local mic, from
   * WebRTC stats: {local: number, remote: {participant_id: number}}.
   */
  async levels() {
    const result = {local: 0, remote: {}}
    if (!this.pc) return result
    const stats = await this.pc.getStats()
    stats.forEach((s) => {
      if (s.type === "inbound-rtp" && s.kind === "audio") {
        const info = this.remote.get(s.mid)
        if (info?.source === "mic") result.remote[info.participant_id] = s.audioLevel ?? 0
      } else if (s.type === "media-source" && s.kind === "audio" && s.trackIdentifier === this.local.get("mic")?.track.id) {
        result.local = s.audioLevel ?? 0
      }
    })
    return result
  }

  // -- signaling --

  serially(fn) {
    this.queue = this.queue.then(fn).catch((error) => this.emit("error", error))
    return this.queue
  }

  async onRenegotiate({op_id, sdp}) {
    const pc = this.pc
    await pc.setRemoteDescription({type: "offer", sdp})
    await pc.setLocalDescription(await pc.createAnswer())
    await this.push("answer", {op_id, sdp: pc.localDescription.sdp})
  }

  // The server's turn for this client to publish more: add the sources'
  // transceivers and offer them.
  async onPush({op_id, sources}) {
    const pc = this.pc
    const added = []
    for (const source of sources) {
      const entry = this.local.get(source)
      // Stopped while queued: publish nothing and let the server unpublish it.
      const track = entry?.track.readyState === "live" ? entry.track : null
      const kind = source === "mic" || source === "screen_audio" ? "audio" : "video"
      const transceiver = track ? addSender(pc, track) : pc.addTransceiver(kind, {direction: "sendonly"})
      if (entry) entry.transceiver = transceiver
      added.push([source, transceiver])
    }

    try {
      await pc.setLocalDescription(await pc.createOffer())
      const mids = Object.fromEntries(added.map(([source, t]) => [source, t.mid]))
      const {sdp} = await this.push("push_offer", {op_id, sdp: pc.localDescription.sdp, mids})
      await pc.setRemoteDescription({type: "answer", sdp})
    } catch (error) {
      if (pc.signalingState === "have-local-offer") await pc.setLocalDescription({type: "rollback"})
      for (const [, t] of added) t.stop()
      throw error
    }
    // The server pulls them for others once they flow.
    await this.push("connected", {})
  }

  async onClose({op_id, mids}) {
    const pc = this.pc
    for (const t of pc.getTransceivers()) {
      if (mids.includes(t.mid)) t.stop()
    }
    await pc.setLocalDescription(await pc.createOffer())
    const {sdp} = await this.push("close_offer", {op_id, sdp: pc.localDescription.sdp})
    await pc.setRemoteDescription({type: "answer", sdp})
  }

  onTracks({added, removed, reset}) {
    // After a reconnect the server sends everything this client hears: drop
    // what it didn't mention, and keep what's unchanged playing as it is.
    if (reset) {
      const now = new Map(added.map((info) => [info.mid, info]))
      removed = [...this.remote.keys()].filter((mid) => now.get(mid)?.track !== this.remote.get(mid).track)
      added = added.filter((info) => this.remote.get(info.mid)?.track !== info.track)
    }

    for (const mid of removed) {
      const info = this.remote.get(mid)
      if (info) {
        removeElement(info.element)
        this.remote.delete(mid)
      }
    }

    for (const info of added) {
      const transceiver = this.pc.getTransceivers().find((t) => t.mid === info.mid)
      if (!transceiver) continue
      const stream = new MediaStream([transceiver.receiver.track])
      let element = null
      // Audio plays in a hidden element; video is for the app to show.
      if (info.kind !== "video") {
        element = document.createElement("audio")
        element.autoplay = true
        element.dataset.octoroomMid = info.mid
        element.srcObject = stream
        element.volume = info.gain
        element.style.display = "none"
        document.body.appendChild(element)
        element.play().catch(() => {})
      }
      this.remote.set(info.mid, {...info, stream, element})
    }

    this.emit("tracks", this.tracks())
  }

  setGain(mid, gain) {
    const info = this.remote.get(mid)
    if (!info) return
    info.gain = gain
    if (info.element) info.element.volume = gain
    this.emit("tracks", this.tracks())
  }

  onRoomEvent({type, participant}) {
    if (type === "joined") {
      this.participants = [...this.participants.filter((p) => p.id !== participant.id), participant]
    } else if (type === "left") {
      this.participants = this.participants.filter((p) => p.id !== participant.id)
    } else {
      this.participants = this.participants.map((p) => (p.id === participant.id ? participant : p))
    }
    this.emit("room_event", {type, participant})
    this.emit("participants", this.participants)
  }

  push(event, payload) {
    if (!this.channel) return Promise.reject(new Error(`${event}: not in a room`))
    return new Promise((resolve, reject) => {
      this.channel
        .push(event, payload, PUSH_TIMEOUT_MS)
        .receive("ok", resolve)
        .receive("error", (r) => reject(new Error(r?.reason || `${event} failed`)))
        .receive("timeout", () => reject(new Error(`${event} timed out`)))
    })
  }

  teardown(reason) {
    this.generation++
    this.abortJoin?.()
    this.abortJoin = null
    if (this.onPageHide) window.removeEventListener("pagehide", this.onPageHide)
    this.onPageHide = null
    this.clearRemote()
    this.pc?.close()
    this.pc = null
    for (const entry of this.local.values()) if (entry.owned) entry.track.stop()
    this.local.clear()
    this.emit("local", {})
    this.stream = null
    const channel = this.channel
    this.channel = null
    if (reason !== "closed") channel?.leave()
    this.participants = []
    this.resumeToken = null
    this.queue = Promise.resolve()
    this.emit("participants", [])
    // "left": leave() was called; "closed": the server removed this client;
    // "failed": join() failed. Either way the client can join again.
    this.emit("left", reason)
    if (reason === "closed") this.emit("error", new Error("removed from the room"))
    this.setState("idle")
  }
}

function addSender(pc, track) {
  return pc.addTransceiver(track, {direction: "sendonly", streams: [new MediaStream([track])]})
}

function removeElement(element) {
  if (!element) return
  element.srcObject = null
  element.remove()
}

function roundAll(timings) {
  return Object.fromEntries(Object.entries(timings).map(([k, v]) => [k, Math.round(v)]))
}

// Resolves true once the local description has a candidate (or gathering
// finished), false if `timeoutMs` passed first.
function firstCandidate(pc, timeoutMs) {
  const ready = () => pc.iceGatheringState === "complete" || /^a=candidate:/m.test(pc.localDescription?.sdp || "")
  if (ready()) return Promise.resolve(true)
  return new Promise((resolve) => {
    const timer = setTimeout(() => done(false), timeoutMs)
    function done(found) {
      clearTimeout(timer)
      pc.removeEventListener("icecandidate", check)
      pc.removeEventListener("icegatheringstatechange", check)
      resolve(found)
    }
    function check() {
      if (ready()) done(true)
    }
    pc.addEventListener("icecandidate", check)
    pc.addEventListener("icegatheringstatechange", check)
  })
}

function peerConnected(pc, timeoutMs) {
  if (pc.connectionState === "connected") return Promise.resolve()
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => finish(new Error("connection to Cloudflare timed out")), timeoutMs)
    function finish(error) {
      clearTimeout(timer)
      pc.removeEventListener("connectionstatechange", check)
      error ? reject(error) : resolve()
    }
    function check() {
      if (pc.connectionState === "connected") finish()
      else if (pc.connectionState === "failed") finish(new Error("connection to Cloudflare failed"))
    }
    pc.addEventListener("connectionstatechange", check)
  })
}
