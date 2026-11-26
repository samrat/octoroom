import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {RoomClient} from "octoroom"

// A beeping tone, for testing without a microphone. Each tab picks its own
// pitch so you can tell who you're hearing.
function testTone() {
  const ctx = new AudioContext()
  const osc = ctx.createOscillator()
  const gain = ctx.createGain()
  const dest = ctx.createMediaStreamDestination()
  osc.frequency.value = [330, 440, 550, 660, 770][Math.floor(Math.random() * 5)]
  gain.gain.value = 0
  osc.connect(gain).connect(dest)
  osc.start()
  const beep = () => {
    const t = ctx.currentTime
    gain.gain.setValueAtTime(0.3, t)
    gain.gain.setValueAtTime(0, t + 0.25)
  }
  beep()
  const timer = setInterval(beep, 1000)
  return {stream: dest.stream, frequency: osc.frequency.value, stop: () => (clearInterval(timer), ctx.close())}
}

// A moving test pattern, for testing without a camera: the tab's name and a
// clock on a per-tab colour, so you can tell whose video you're seeing and
// that it's live.
function testPattern(label) {
  const canvas = document.createElement("canvas")
  canvas.width = 640
  canvas.height = 360
  const ctx = canvas.getContext("2d")
  const hue = Math.floor(Math.random() * 360)
  const started = performance.now()
  const draw = () => {
    const t = (performance.now() - started) / 1000
    ctx.fillStyle = `hsl(${hue} 55% 30%)`
    ctx.fillRect(0, 0, 640, 360)
    ctx.fillStyle = `hsl(${hue} 70% 60%)`
    ctx.beginPath()
    ctx.arc(320 + Math.cos(t * 2) * 220, 250, 28, 0, Math.PI * 2)
    ctx.fill()
    ctx.fillStyle = "#fff"
    ctx.font = "bold 44px system-ui, sans-serif"
    ctx.textAlign = "center"
    ctx.fillText(label, 320, 130)
    ctx.font = "28px ui-monospace, monospace"
    ctx.fillText(new Date().toLocaleTimeString(), 320, 180)
  }
  draw()
  // A timer, not requestAnimationFrame, so it keeps drawing in a background tab.
  const timer = setInterval(draw, 1000 / 15)
  const [track] = canvas.captureStream(15).getVideoTracks()
  track.addEventListener("ended", () => clearInterval(timer))
  return track
}

const Call = {
  mounted() {
    window.octoroomCall = this
    this.socket = new Socket("/socket")
    this.socket.connect()
    this.$ = (sel) => this.el.querySelector(sel)
    this.$("#name").value = localStorage.getItem("octoroom-name") || ""
    this.$("#name").onkeydown = (e) => {
      if (e.key === "Enter" && !this.$("#join").disabled) this.join()
    }
    this.$("#join").onclick = () => this.join()
    this.$("#leave").onclick = () => this.leave()
    this.$("#mute").onclick = () => this.toggleMute()
    this.$("#camera").onclick = () => this.toggleCamera()
    this.$("#pause").onclick = () => this.togglePause()
    this.$("#screen").onclick = () => this.toggleScreen()
    this.previews = new WeakMap() // local track => MediaStream, so previews don't flicker
  },

  status(text) {
    this.$("#status").textContent = text
  },

  buttons(inCall) {
    this.el.classList.toggle("in-call", inCall)
    this.$("#join").disabled = inCall
    this.$("#leave").disabled = !inCall
    this.$("#mute").disabled = !inCall
    this.$("#camera").disabled = !inCall
    this.$("#screen").disabled = !inCall || !navigator.mediaDevices.getDisplayMedia
    this.updateVideoButtons()
  },

  updateVideoButtons() {
    const local = this.room?.state === "joined" ? this.room.localTracks() : {}
    this.el.classList.toggle("has-camera", Boolean(local.camera))
    this.$("#camera").textContent = local.camera ? "Camera off" : "Camera on"
    this.$("#pause").disabled = !local.camera
    this.$("#pause").textContent = local.camera?.muted ? "Resume video" : "Pause video"
    this.$("#screen").textContent = local.screen ? "Stop sharing" : "Share screen"
  },

  cameraTrack() {
    return this.$("#pattern").checked ? testPattern(this.$("#name").value) : null
  },

  async join() {
    const name = this.$("#name").value.trim() || `guest-${Math.floor(Math.random() * 1000)}`
    this.$("#name").value = name
    try { localStorage.setItem("octoroom-name", name) } catch {}

    this.tone = this.$("#tone").checked ? testTone() : null
    const withCamera = this.$("#join-camera").checked || this.$("#pattern").checked
    const pattern = withCamera ? this.cameraTrack() : null
    const audio = {echoCancellation: true, noiseSuppression: true, autoGainControl: true}
    let stream = this.tone?.stream
    // A provided stream's video track is published as the camera.
    if (pattern) {
      stream = stream || (await navigator.mediaDevices.getUserMedia({audio}).catch(() => null))
      stream = new MediaStream([...(stream?.getAudioTracks() || []), pattern])
    }
    this.pattern = pattern
    const room = new RoomClient({
      socket: this.socket,
      topic: `room:${this.el.dataset.room}`,
      params: {name},
      stream,
      audio,
      video: withCamera && !pattern ? {width: 640, height: 360} : false,
    })
    this.room = room

    room.on("state", (state) => {
      this.pushEvent("client", {state, participant_id: room.participantId})
      this.buttons(state !== "idle")
      if (state === "idle") this.renderVideos()
    })
    room.on("connection", (state) => this.status(`Media: ${state}`))
    room.on("tracks", (tracks) => {
      if (room.state === "joined") this.status(`In the call. Receiving ${tracks.length} track(s).`)
      this.renderVideos()
    })
    room.on("local", () => {
      this.renderVideos()
      this.updateVideoButtons()
    })
    room.on("participants", () => this.renderVideos())
    room.on("error", (error) => this.status(`Error: ${error.message}`))
    room.on("reconnecting", () => this.status("Lost the server; reconnecting (audio keeps flowing)…"))
    room.on("reconnected", ({resumed}) =>
      this.status(resumed ? "Reconnected: resumed the same session." : "Reconnected as a new participant; publishing again…"),
    )
    room.on("left", () => this.cleanup(room))

    this.status(this.tone ? `Joining with a ${this.tone.frequency} Hz test tone…` : "Joining…")
    const started = performance.now()
    try {
      await room.join()
      this.status(`In the call (joined in ${Math.round(performance.now() - started)} ms).`)
      this.meters = setInterval(() => this.updateMeters(), 150)
    } catch (error) {
      this.status(`Couldn't join: ${error.message}`)
    }
  },

  async leave() {
    await this.room?.leave()
    this.status("Left the call.")
  },

  toggleMute() {
    if (!this.room) return
    this.room.setMuted(!this.room.muted)
    this.$("#mute").textContent = this.room.muted ? "Unmute" : "Mute"
  },

  async toggleCamera() {
    if (!this.room) return
    const button = this.$("#camera")
    button.disabled = true
    try {
      if (this.room.localTracks().camera) {
        await this.room.stop("camera")
        this.pattern?.stop()
        this.pattern = null
      } else {
        this.pattern = this.cameraTrack()
        await this.room.startCamera(this.pattern || {width: 640, height: 360})
      }
    } catch (error) {
      this.status(`Camera: ${error.message}`)
    } finally {
      button.disabled = this.room?.state !== "joined"
      this.updateVideoButtons()
    }
  },

  togglePause() {
    const camera = this.room?.localTracks().camera
    if (camera) this.room.mute("camera", !camera.muted)
  },

  async toggleScreen() {
    if (!this.room) return
    try {
      if (this.room.localTracks().screen) {
        await Promise.all([this.room.stop("screen"), this.room.stop("screen_audio")])
      } else {
        await this.room.shareScreen()
      }
    } catch (error) {
      this.status(`Screen share: ${error.message}`)
    }
    this.updateVideoButtons()
  },

  // One tile per participant (showing their camera when on, or an avatar when
  // audio-only), plus a separate tile for any active screen share.
  renderVideos() {
    const grid = document.getElementById("videos")
    if (!grid) return
    const room = this.room
    const tiles = new Map()

    if (room && room.state !== "idle") {
      const local = room.localTracks()
      const me = room.participants.find((p) => p.id === room.participantId)
      const myName = me?.meta?.name || this.$("#name")?.value.trim() || "You"

      if (local.camera) {
        const {track, muted} = local.camera
        if (!this.previews.has(track)) this.previews.set(track, new MediaStream([track]))
        const mirror = track !== this.pattern
        tiles.set("local-camera", {stream: this.previews.get(track), source: "camera", muted, mirror, name: myName, label: `${myName} · you`})
      } else {
        tiles.set("local-camera", {stream: null, source: "audio", muted: false, mirror: false, name: myName, label: `${myName} · you`})
      }

      if (local.screen) {
        const {track, muted} = local.screen
        if (!this.previews.has(track)) this.previews.set(track, new MediaStream([track]))
        tiles.set("local-screen", {stream: this.previews.get(track), source: "screen", muted, mirror: false, name: myName, label: `${myName} · screen`})
      }

      const remoteVideoByParticipant = new Map()
      for (const t of room.tracks()) {
        if (t.kind !== "video") continue
        const p = room.participants.find((p) => p.id === t.participant_id)
        const name = p?.meta?.name || t.worker_id || "?"
        const muted = p?.tracks?.[t.source]?.muted || false
        if (t.source === "camera" && t.participant_id) {
          remoteVideoByParticipant.set(t.participant_id, {stream: t.stream, source: "camera", muted, mirror: false, name, label: name})
        } else {
          tiles.set(`mid-${t.mid}`, {stream: t.stream, source: t.source, muted, mirror: false, name, label: `${name} · ${t.source}`})
        }
      }

      for (const p of room.participants) {
        if (p.id === room.participantId) continue
        const name = p.meta?.name || p.id
        const cam = remoteVideoByParticipant.get(p.id)
        if (cam) {
          tiles.set(`p-${p.id}`, cam)
        } else {
          tiles.set(`p-${p.id}`, {stream: null, source: "audio", muted: false, mirror: false, name, label: name})
        }
      }
    }

    for (const el of [...grid.children]) {
      if (!tiles.has(el.dataset.key)) {
        el.querySelector("video").srcObject = null
        el.remove()
      }
    }

    for (const [key, tile] of tiles) {
      let el = grid.querySelector(`[data-key="${key}"]`)
      if (!el) {
        el = document.createElement("div")
        el.dataset.key = key
        el.innerHTML = `<video autoplay playsinline muted></video><div class="avatar-stage"><div class="avatar-circle"></div></div><span class="paused">Video paused</span><span class="label"></span>`
        grid.appendChild(el)
      }
      const video = el.querySelector("video")
      if (tile.stream) {
        if (video.srcObject !== tile.stream) {
          video.srcObject = tile.stream
          video.play().catch(() => {})
        }
      } else if (video.srcObject) {
        video.srcObject = null
      }
      const initial = (tile.name || "?").trim().charAt(0).toUpperCase() || "?"
      el.querySelector(".avatar-circle").textContent = initial
      el.className = [
        "tile",
        tile.source,
        !tile.stream && "audio-only",
        tile.muted && "muted",
        tile.mirror && "mirror",
      ]
        .filter(Boolean)
        .join(" ")
      el.querySelector(".label").textContent = tile.label
    }
  },

  async updateMeters() {
    if (!this.room || this.room.state !== "joined") return
    const {local, remote} = await this.room.levels()
    const set = (id, level) => {
      const bar = document.getElementById(`level-${id}`)
      // audioLevel is linear; a square root makes speech visible.
      if (bar) bar.style.width = `${Math.min(100, Math.sqrt(level) * 140)}%`
    }
    set(this.room.participantId, this.room.muted ? 0 : local)
    for (const [id, level] of Object.entries(remote)) set(id, level)
  },

  cleanup(room) {
    if (!room || this.room === room) this.room = null
    clearInterval(this.meters)
    this.tone?.stop()
    this.tone = null
    this.pattern?.stop()
    this.pattern = null
    this.$("#mute").textContent = "Mute"
    this.updateVideoButtons()
    this.renderVideos()
    document.querySelectorAll("[id^=level-]").forEach((el) => (el.style.width = "0"))
  },

  // LiveView still patches attributes on `#call` even with `phx-update="ignore"`,
  // which strips `.in-call` / `.has-camera` when it re-renders or reconnects.
  updated() {
    if (this.room) this.buttons(this.room.state !== "idle")
  },

  // LiveView reconnected (e.g. after a server restart): its server side
  // starts afresh and needs to know who this tab is again.
  reconnected() {
    if (this.room) {
      this.buttons(this.room.state !== "idle")
      this.pushEvent("client", {state: this.room.state, participant_id: this.room.participantId})
    }
  },

  destroyed() {
    this.room?.leave()
    this.socket.disconnect()
  },
}

const liveSocket = new LiveSocket("/live", Socket, {hooks: {Call}})
liveSocket.connect()
window.liveSocket = liveSocket
