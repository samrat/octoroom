import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {RoomClient} from "octoroom"
import {agents} from "octoroom_agents"

const Teleprompter = {
  mounted() {
    window.teleprompter = this
    this.socket = new Socket("/socket")
    this.socket.connect()
    this.$ = (sel) => this.el.querySelector(sel)
    this.$("#join").onclick = () => this.join()
    this.$("#leave").onclick = () => this.leave()
    this.$("#mute").onclick = () => this.toggleMute()
    this.$("#say-form").onsubmit = (e) => {
      e.preventDefault()
      const input = this.$("#say-input")
      const text = input.value.trim()
      if (!text) return
      input.value = ""
      this.sayText(text)
    }
  },

  status(text) {
    this.$("#status").textContent = text
  },

  buttons(inCall) {
    this.el.classList.toggle("in-call", inCall)
    this.$("#join").disabled = inCall
    this.$("#leave").disabled = !inCall
    this.$("#mute").disabled = !inCall
    this.$("#say-btn").disabled = !inCall
  },

  async join() {
    const room = new RoomClient({
      socket: this.socket,
      topic: `room:${this.el.dataset.room}`,
      params: {name: "Speaker"},
      audio: {echoCancellation: true, noiseSuppression: true, autoGainControl: true},
      video: false,
    })
    this.room = room
    this.agents = agents(room)

    room.on("state", (state) => {
      this.pushEvent("client", {state, participant_id: room.participantId})
      this.buttons(state !== "idle")
    })
    room.on("error", (error) => this.status(`Error: ${error.message}`))
    room.on("reconnecting", () => this.status("Lost the server; reconnecting…"))
    room.on("reconnected", ({resumed}) =>
      this.status(resumed ? "Reconnected: resumed session." : "Reconnected."),
    )
    room.on("left", () => this.cleanup(room))

    this.status("Connecting microphone…")
    try {
      await room.join()
      this.startWaveform()
      this.status("Listening silently — talk in any order.")
    } catch (error) {
      this.status(`Couldn't connect: ${error.message}`)
    }
  },

  startWaveform() {
    this.stopWaveform()
    const canvas = this.$("#waveform")
    const track = this.room?.localTracks()?.mic?.track
    if (!canvas || !track) return

    try {
      const ctx = new (window.AudioContext || window.webkitAudioContext)()
      const source = ctx.createMediaStreamSource(new MediaStream([track]))
      const analyser = ctx.createAnalyser()
      analyser.fftSize = 256
      analyser.smoothingTimeConstant = 0.72
      source.connect(analyser)

      const bars = 36
      const history = new Float32Array(bars)
      const data = new Uint8Array(analyser.fftSize)
      const g = canvas.getContext("2d")
      let frame = 0

      const draw = () => {
        this.waveRaf = requestAnimationFrame(draw)
        const w = canvas.width
        const h = canvas.height
        g.clearRect(0, 0, w, h)

        const muted = Boolean(this.room?.muted)
        let amp = 0
        if (!muted) {
          analyser.getByteTimeDomainData(data)
          let sum = 0
          for (let i = 0; i < data.length; i++) {
            const v = (data[i] - 128) / 128
            sum += v * v
          }
          amp = Math.min(1, Math.sqrt(sum / data.length) * 4.5)
        }

        if (++frame % 2 === 0) {
          history.copyWithin(0, 1)
          history[bars - 1] = amp
        }

        const gap = 3
        const barW = Math.max(2, (w - gap * (bars - 1)) / bars)
        for (let i = 0; i < bars; i++) {
          const level = history[i]
          const bh = Math.max(4, level * (h - 6))
          const x = i * (barW + gap)
          const y = (h - bh) / 2
          g.fillStyle = muted ? "#d6d3d1" : level > 0.08 ? "#155dfc" : "#cbd5e1"
          g.beginPath()
          g.roundRect(x, y, barW, bh, barW / 2)
          g.fill()
        }
      }

      this.waveCtx = ctx
      draw()
    } catch {
      // Ignore AudioContext restrictions
    }
  },

  stopWaveform() {
    if (this.waveRaf) {
      cancelAnimationFrame(this.waveRaf)
      this.waveRaf = null
    }
    if (this.waveCtx) {
      this.waveCtx.close().catch(() => {})
      this.waveCtx = null
    }
  },

  async sayText(text) {
    if (!this.agents || !text) return
    try {
      await this.agents.say(text, "tracker")
    } catch (error) {
      this.status(`Couldn't send: ${error.message}`)
    }
  },

  async leave() {
    await this.room?.leave()
    this.status("Stopped listening.")
  },

  toggleMute() {
    if (!this.room) return
    this.room.setMuted(!this.room.muted)
    this.$("#mute").textContent = this.room.muted ? "Unmute mic" : "Mute mic"
  },

  cleanup(room) {
    this.stopWaveform()
    if (!room || this.room === room) {
      this.room = null
      this.agents = null
    }
    this.$("#mute").textContent = "Mute mic"
  },

  updated() {
    if (this.room) this.buttons(this.room.state !== "idle")
  },

  reconnected() {
    if (this.room) {
      this.buttons(this.room.state !== "idle")
      this.pushEvent("client", {state: this.room.state, participant_id: this.room.participantId})
    }
  },

  destroyed() {
    this.stopWaveform()
    this.room?.leave()
    this.socket.disconnect()
  },
}

const liveSocket = new LiveSocket("/live", Socket, {hooks: {Teleprompter}})
liveSocket.connect()
window.liveSocket = liveSocket
