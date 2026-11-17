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

// Times the assistant in this tab: from your mic going quiet to the
// assistant's audio arriving, with a WebAudio analyser on each, every 10 ms.
// Speech "ends" after 400 ms below the threshold, and is dated to the last
// loud sample. Use headphones: the assistant leaking into your mic looks
// like you talking.
class LatencyProbe {
  constructor(ctx, onLatency) {
    this.ctx = ctx
    this.onLatency = onLatency
    this.sources = new Map() // track id => analyser
    this.state = "idle" // "speaking" | "waiting"
    this.lastVoice = 0
  }

  analyser(track) {
    if (!this.sources.has(track.id)) {
      const analyser = this.ctx.createAnalyser()
      analyser.fftSize = 512
      this.ctx.createMediaStreamSource(new MediaStream([track])).connect(analyser)
      this.sources.set(track.id, analyser)
    }
    return this.sources.get(track.id)
  }

  rms(analyser) {
    const data = new Float32Array(analyser.fftSize)
    analyser.getFloatTimeDomainData(data)
    let sum = 0
    for (const x of data) sum += x * x
    return Math.sqrt(sum / data.length)
  }

  // `mic` and `assistant` are MediaStreamTracks (or null).
  tick(mic, assistant) {
    if (!mic || !assistant) return
    const now = performance.now()
    const local = this.rms(this.analyser(mic))
    const remote = this.rms(this.analyser(assistant))

    if (this.state === "waiting" && remote > 0.01) {
      this.onLatency(now - this.lastVoice)
      this.state = "idle"
    } else if (local > 0.02 && remote < 0.01) {
      this.state = "speaking"
      this.lastVoice = now
    } else if (this.state === "speaking" && now - this.lastVoice > 400) {
      this.state = "waiting"
    } else if (this.state === "waiting" && now - this.lastVoice > 15_000) {
      this.state = "idle"
    }
  }

  close() {
    this.ctx.close()
  }
}

const Call = {
  mounted() {
    window.octoroomCall = this
    this.socket = new Socket("/socket")
    this.socket.connect()
    this.$ = (sel) => this.el.querySelector(sel)
    this.$("#name").value = localStorage.getItem("octoroom-name") || ""
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
    this.$("#join").disabled = inCall
    this.$("#leave").disabled = !inCall
    this.$("#mute").disabled = !inCall
    this.$("#camera").disabled = !inCall
    this.$("#screen").disabled = !inCall || !navigator.mediaDevices.getDisplayMedia
    this.updateVideoButtons()
  },

  updateVideoButtons() {
    const local = this.room?.state === "joined" ? this.room.localTracks() : {}
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
    const withCamera = this.$("#join-camera").checked
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
    })
    room.on("connection", (state) => this.status(`Connection to Cloudflare: ${state}`))
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
    room.on("left", () => this.cleanup())

    this.status(this.tone ? `Joining with a ${this.tone.frequency} Hz test tone…` : "Joining…")
    const started = performance.now()
    try {
      await room.join()
      this.status(`In the call (joined in ${Math.round(performance.now() - started)} ms).`)
      this.meters = setInterval(() => this.updateMeters(), 150)
      this.startProbe()
    } catch (error) {
      this.status(`Couldn't join: ${error.message}`)
    }
  },

  startProbe() {
    const ctx = new AudioContext()
    ctx.resume().catch(() => {})
    this.probe = new LatencyProbe(ctx, (ms) => this.pushEvent("heard_latency", {ms}))
    this.probeTimer = setInterval(() => {
      const room = this.room
      if (!room || room.state !== "joined" || room.muted) return
      const assistant = room.tracks().find((t) => t.kind === "audio" && t.track === "assistant")
      this.probe.tick(room.localTracks().mic?.track, assistant?.stream.getAudioTracks()[0])
    }, 10)
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

  // One tile per video: this tab's own camera and screen, and every video
  // track the server pulled into this session.
  renderVideos() {
    const grid = document.getElementById("videos")
    if (!grid) return
    const room = this.room
    const tiles = new Map()

    if (room && room.state !== "idle") {
      for (const [source, {track, muted}] of Object.entries(room.localTracks())) {
        if (source !== "camera" && source !== "screen") continue
        if (!this.previews.has(track)) this.previews.set(track, new MediaStream([track]))
        // A real camera is mirrored, like a mirror; a test pattern isn't, so its text reads.
        const mirror = source === "camera" && track !== this.pattern
        tiles.set(`local-${source}`, {stream: this.previews.get(track), source, muted, mirror, label: `You · ${source}`})
      }

      for (const t of room.tracks()) {
        if (t.kind !== "video") continue
        const p = room.participants.find((p) => p.id === t.participant_id)
        const name = p?.meta?.name || t.worker_id || "?"
        const muted = p?.tracks?.[t.source]?.muted || false
        tiles.set(`mid-${t.mid}`, {stream: t.stream, source: t.source, muted, label: `${name} · ${t.source}`})
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
        el.innerHTML = `<video autoplay playsinline muted></video><span class="paused">Video paused</span><span class="label"></span>`
        grid.appendChild(el)
      }
      const video = el.querySelector("video")
      if (video.srcObject !== tile.stream) {
        video.srcObject = tile.stream
        video.play().catch(() => {})
      }
      el.className = ["tile", tile.source, tile.muted && "muted", tile.mirror && "mirror"]
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

  cleanup() {
    clearInterval(this.meters)
    clearInterval(this.probeTimer)
    this.probe?.close()
    this.probe = null
    this.tone?.stop()
    this.tone = null
    this.pattern?.stop()
    this.pattern = null
    this.$("#mute").textContent = "Mute"
    this.updateVideoButtons()
    this.renderVideos()
    document.querySelectorAll("[id^=level-]").forEach((el) => (el.style.width = "0"))
  },

  // LiveView reconnected (e.g. after a server restart): its server side
  // starts afresh and needs to know who this tab is again.
  reconnected() {
    if (this.room) this.pushEvent("client", {state: this.room.state, participant_id: this.room.participantId})
  },

  destroyed() {
    this.room?.leave()
    this.socket.disconnect()
  },
}

const liveSocket = new LiveSocket("/live", Socket, {hooks: {Call}})
liveSocket.connect()
window.liveSocket = liveSocket
