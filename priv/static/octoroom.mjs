// Octoroom browser client.
//
//   import {RoomClient} from "octoroom"
//
//   const room = new RoomClient({socket, topic: `room:${id}`, params: {name}})
//   room.on("participants", (list) => render(list))
//   await room.join()   // asks for the mic, publishes it, plays what the server subscribes
//   room.setMuted(true)
//   await room.leave()
//
// One RTCPeerConnection to Cloudflare carries the mic (sendonly) and every
// track the server pulls into this session. The server decides what this
// client hears: it sends Cloudflare's offers (`renegotiate`), asks for
// transceivers to be closed (`close`), and then says which mid is which
// track (`tracks`). Signaling is serialized: one exchange at a time.
//
// Reconnecting: the server hands out a resume token (refreshed with
// `resume_token`). When the Phoenix socket reconnects, the channel rejoins
// with it and the server takes this client back as the same participant
// with the same Cloudflare session, even after a server restart: the peer
// connection stays up the whole time, so audio keeps flowing. If there was
// nothing to resume, the client publishes again on a new peer connection.
// Events: "reconnecting", "reconnected" ({resumed}).

const ICE_GATHERING_TIMEOUT_MS = 2_000
const CONNECT_TIMEOUT_MS = 15_000
const PUSH_TIMEOUT_MS = 30_000

export class RoomClient {
  /**
   * @param {object} options
   * @param {import("phoenix").Socket} options.socket a connected Phoenix socket
   * @param {string} options.topic e.g. "room:lobby"
   * @param {object} [options.params] passed to the room's join/2
   * @param {MediaStream} [options.stream] publish this instead of asking for the mic
   * @param {MediaTrackConstraints} [options.audio] getUserMedia audio constraints
   */
  constructor({socket, topic, params = {}, stream = null, audio = true}) {
    this.socket = socket
    this.topic = topic
    this.params = params
    this.providedStream = stream
    this.audioConstraints = audio
    this.listeners = {}
    this.participants = []
    this.participantId = null
    this.remote = new Map() // mid => {mid, track, participant_id, gain, element}
    this.queue = Promise.resolve()
    this.state = "idle"
    this.resumeToken = null
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

    try {
      // A function, so a rejoin sends the latest resume token.
      const channel = this.socket.channel(this.topic, () =>
        this.resumeToken ? {...this.params, resume_token: this.resumeToken} : this.params,
      )
      this.channel = channel
      channel.on("renegotiate", (p) => this.serially(() => this.onRenegotiate(p)))
      channel.on("close", (p) => this.serially(() => this.onClose(p)))
      channel.on("tracks", (p) => this.serially(() => this.onTracks(p)))
      channel.on("gain", ({mid, gain}) => this.setGain(mid, gain))
      channel.on("room_event", (event) => this.onRoomEvent(event))
      channel.on("resume_token", ({token}) => (this.resumeToken = token))
      channel.on("republish", () => this.serially(() => this.restartMedia()))
      channel.onError(() => this.state === "joined" && this.emit("reconnecting"))
      channel.onClose(() => this.channel === channel && this.teardown("closed"))

      const reply = await new Promise((resolve, reject) => {
        let joined = false
        channel
          .join(PUSH_TIMEOUT_MS)
          // Phoenix runs these again on every rejoin.
          .receive("ok", (reply) => (joined ? this.onRejoined(reply) : ((joined = true), resolve(reply))))
          .receive("error", (r) => !joined && reject(new Error(r?.reason || "join failed")))
          .receive("timeout", () => !joined && reject(new Error("join timed out")))
      })
      this.onJoinReply(reply)

      this.stream =
        this.providedStream || (await navigator.mediaDevices.getUserMedia({audio: this.audioConstraints}))

      await this.connectMedia()
      // Closing the tab looks like a dropped connection, which the server
      // holds for a while in case it comes back: say goodbye instead.
      this.onPageHide = () => this.leave()
      window.addEventListener("pagehide", this.onPageHide)
      this.setState("joined")
      return reply
    } catch (error) {
      this.teardown("failed")
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

  onRejoined(reply) {
    this.onJoinReply(reply)
    this.emit("reconnected", {resumed: reply.resumed})
    // Nothing to resume (the token expired, or the session was never
    // published): start over as a new participant.
    if (!reply.resumed && this.state === "joined") this.serially(() => this.restartMedia())
  }

  // A peer connection to Cloudflare with the mic published on it.
  async connectMedia() {
    const pc = new RTCPeerConnection({iceServers: this.iceServers, bundlePolicy: "max-bundle"})
    this.pc = pc
    pc.onconnectionstatechange = () => {
      if (this.pc !== pc) return
      this.emit("connection", pc.connectionState)
      if (pc.connectionState === "failed") this.emit("error", new Error("connection failed"))
    }

    const [track] = this.stream.getAudioTracks()
    const mic = pc.addTransceiver(track, {direction: "sendonly", streams: [this.stream]})
    await pc.setLocalDescription(await pc.createOffer())
    // Cloudflare takes no trickle ICE: send the offer with its candidates.
    await iceGathered(pc, ICE_GATHERING_TIMEOUT_MS)

    const {sdp} = await this.push("publish", {sdp: pc.localDescription.sdp, mids: {mic: mic.mid}})
    await pc.setRemoteDescription({type: "answer", sdp})
    await peerConnected(pc, CONNECT_TIMEOUT_MS)
    await this.push("connected", {})
  }

  // The server lost this client's session: publish again on a new one.
  async restartMedia() {
    if (!this.stream) return
    this.clearRemote()
    this.pc?.close()
    this.pc = null
    await this.connectMedia()
  }

  clearRemote() {
    for (const info of this.remote.values()) {
      info.element.srcObject = null
      info.element.remove()
    }
    this.remote.clear()
    this.emit("tracks", [])
  }

  async leave() {
    if (this.state === "idle") return
    this.teardown("left")
  }

  setMuted(muted) {
    this.muted = muted
    this.stream?.getAudioTracks().forEach((t) => (t.enabled = !muted))
  }

  /** Remote tracks this client is playing: [{mid, track, participant_id, gain}]. */
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
        if (info) result.remote[info.participant_id] = s.audioLevel ?? 0
      } else if (s.type === "media-source" && s.kind === "audio") {
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
        info.element.srcObject = null
        info.element.remove()
        this.remote.delete(mid)
      }
    }

    for (const info of added) {
      const transceiver = this.pc.getTransceivers().find((t) => t.mid === info.mid)
      if (!transceiver) continue
      const element = document.createElement("audio")
      element.autoplay = true
      element.dataset.octoroomMid = info.mid
      element.srcObject = new MediaStream([transceiver.receiver.track])
      element.volume = info.gain
      element.style.display = "none"
      document.body.appendChild(element)
      element.play().catch(() => {})
      this.remote.set(info.mid, {...info, element})
    }

    this.emit("tracks", this.tracks())
  }

  setGain(mid, gain) {
    const info = this.remote.get(mid)
    if (!info) return
    info.gain = gain
    info.element.volume = gain
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
    return new Promise((resolve, reject) => {
      this.channel
        .push(event, payload, PUSH_TIMEOUT_MS)
        .receive("ok", resolve)
        .receive("error", (r) => reject(new Error(r?.reason || `${event} failed`)))
        .receive("timeout", () => reject(new Error(`${event} timed out`)))
    })
  }

  teardown(reason) {
    if (this.onPageHide) window.removeEventListener("pagehide", this.onPageHide)
    this.onPageHide = null
    this.clearRemote()
    this.pc?.close()
    this.pc = null
    if (!this.providedStream) this.stream?.getTracks().forEach((t) => t.stop())
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

function iceGathered(pc, timeoutMs) {
  if (pc.iceGatheringState === "complete") return Promise.resolve()
  return new Promise((resolve) => {
    const timer = setTimeout(done, timeoutMs)
    function done() {
      clearTimeout(timer)
      pc.removeEventListener("icegatheringstatechange", check)
      resolve()
    }
    function check() {
      if (pc.iceGatheringState === "complete") done()
    }
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
