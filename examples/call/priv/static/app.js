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
  },

  status(text) {
    this.$("#status").textContent = text
  },

  buttons(inCall) {
    this.$("#join").disabled = inCall
    this.$("#leave").disabled = !inCall
    this.$("#mute").disabled = !inCall
  },

  async join() {
    const name = this.$("#name").value.trim() || `guest-${Math.floor(Math.random() * 1000)}`
    this.$("#name").value = name
    try { localStorage.setItem("octoroom-name", name) } catch {}

    this.tone = this.$("#tone").checked ? testTone() : null
    const room = new RoomClient({
      socket: this.socket,
      topic: `room:${this.el.dataset.room}`,
      params: {name},
      stream: this.tone?.stream,
      audio: {echoCancellation: true, noiseSuppression: true, autoGainControl: true},
    })
    this.room = room

    room.on("state", (state) => {
      this.pushEvent("client", {state, participant_id: room.participantId})
      this.buttons(state !== "idle")
    })
    room.on("connection", (state) => this.status(`Connection to Cloudflare: ${state}`))
    room.on("tracks", (tracks) => {
      if (room.state === "joined") this.status(`In the call. Playing ${tracks.length} track(s).`)
    })
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
    this.tone?.stop()
    this.tone = null
    this.$("#mute").textContent = "Mute"
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
