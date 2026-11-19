// The browser side: Octoroom's client publishes your mic to Cloudflare and
// plays the agent's voice, and octoroom_agents shows the agent's state and
// transcript and sends what you type. The LiveView shows the latency.
import {Socket} from "phoenix"
import {RoomClient} from "../../../../priv/static/octoroom.mjs"
import {agents} from "../../../../agents/priv/static/octoroom_agents.mjs"

// Times each reply in this tab: from your voice going quiet to the agent's
// voice arriving, read from an analyser on each every 10 ms. Speech "ends"
// after 400 ms below the threshold, and is dated to its last loud sample.
class LatencyProbe {
  constructor(local, onHeard) {
    this.local = local // an AnalyserNode on what this tab sends
    this.remote = null // one on the agent's voice, once it arrives
    this.onHeard = onHeard
    this.state = "idle" // "speaking" | "waiting"
    this.lastVoice = 0
  }

  tick() {
    if (!this.remote) return
    const now = performance.now()
    const local = rms(this.local)
    const remote = rms(this.remote)

    if (this.state === "waiting" && remote > 0.01) {
      this.onHeard(now - this.lastVoice)
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
}

function rms(analyser) {
  const data = new Float32Array(analyser.fftSize)
  analyser.getFloatTimeDomainData(data)
  let sum = 0
  for (const x of data) sum += x * x
  return Math.sqrt(sum / data.length)
}

const badges = {listening: "badge-success", thinking: "badge-info", waiting: "badge-info", speaking: "badge-warning"}

export const Agent = {
  mounted() {
    this.socket = new Socket("/socket")
    this.socket.connect()
    this.$ = (sel) => this.el.querySelector(sel)
    this.$("#join").onclick = () => this.join()
    this.$("#leave").onclick = () => this.room?.leave()
    this.$("#mute").onclick = () => this.toggleMute()
    this.el.querySelectorAll(".ask").forEach((b) => (b.onclick = () => this.ask(b.dataset.src)))
    this.$("#say").onsubmit = (e) => {
      e.preventDefault()
      this.say()
    }
    this.clips = new Map() // question URL => AudioBuffer
  },

  status(text) {
    this.$("#status").textContent = text
  },

  enable(inCall) {
    this.$("#join").disabled = inCall
    for (const el of this.el.querySelectorAll("#leave, #mute, .ask, #say input, #say button")) {
      el.disabled = !inCall
    }
  },

  // What this tab sends is a mix of your mic and, when you ask one, a
  // recorded question: both go through `this.send`, and the room publishes
  // its output as the mic.
  async join() {
    this.enable(true)
    this.status("Joining…")
    const startedAt = performance.now()

    this.ctx = new AudioContext()
    const mic = await navigator.mediaDevices
      .getUserMedia({audio: {echoCancellation: true, noiseSuppression: true, autoGainControl: true}})
      .catch(() => null)
    this.micStream = mic
    this.send = this.ctx.createGain()
    const out = this.ctx.createMediaStreamDestination()
    this.send.connect(out)
    // Chrome stops producing frames from a destination whose sources have
    // all ended (a question played without a mic), and WebRTC then sends
    // nothing, so the agent's speech-to-text never hears the turn end. A
    // silent source that never ends keeps the track flowing.
    const keepAlive = this.ctx.createConstantSource()
    keepAlive.offset.value = 0
    keepAlive.connect(this.send)
    keepAlive.start()
    if (mic) {
      this.micGain = this.ctx.createGain()
      this.ctx.createMediaStreamSource(mic).connect(this.micGain).connect(this.send)
    }
    const local = this.ctx.createAnalyser()
    local.fftSize = 512
    this.send.connect(local)
    this.probe = new LatencyProbe(local, (ms) => this.pushEvent("heard", {ms}))
    this.probeTimer = setInterval(() => this.probe.tick(), 10)

    const room = new RoomClient({socket: this.socket, topic: `room:${this.el.dataset.room}`, stream: out.stream})
    this.room = room
    const ai = agents(room)

    ai.on("agents", (list) => {
      const state = list.find((a) => a.id === "assistant")?.state || "joining"
      const pill = this.$("#state")
      pill.textContent = state
      pill.className = `badge ${badges[state] || "badge-ghost"}`
    })
    ai.on("transcript", ({agent, items}) => agent === "assistant" && this.renderTranscript(items))
    ai.on("error", ({stage, fatal}) => this.status(`The agent's ${stage} failed${fatal ? " and it stopped" : ""}.`))
    this.ai = ai

    // When the agent's voice arrives, and when its greeting is first heard:
    // a greeting that starts before the track arrives loses its first words.
    let greeting = null
    room.on("tracks", (tracks) => {
      const voice = tracks.find((t) => t.kind === "audio" && t.track === "assistant")
      if (!voice || this.probe.remote) return
      const remote = this.ctx.createAnalyser()
      remote.fftSize = 512
      this.ctx.createMediaStreamSource(voice.stream).connect(remote)
      this.probe.remote = remote
      greeting = {track: performance.now() - startedAt}
      const listen = setInterval(() => {
        if (!this.probe || performance.now() - startedAt > 30_000) return clearInterval(listen)
        if (rms(remote) > 0.01) {
          clearInterval(listen)
          this.pushEvent("greeting", {...greeting, sound: performance.now() - startedAt})
        }
      }, 10)
    })
    room.on("error", (error) => this.status(`Error: ${error.message}`))
    room.on("left", () => this.cleanup())

    try {
      await room.join()
      this.status(`Joined in ${Math.round(performance.now() - startedAt)} ms.${mic ? "" : " No microphone: ask a recorded question or type."}`)
    } catch (error) {
      this.status(`Couldn't join: ${error.message}`)
      this.cleanup()
    }
  },

  // Plays a recorded question into what this tab sends, with the mic off
  // meanwhile, so the agent hears only the question.
  async ask(src) {
    if (!this.room) return
    try {
      if (!this.clips.has(src)) {
        const response = await fetch(src)
        if (!response.ok) throw new Error(`${response.status} ${response.statusText}`)
        this.clips.set(src, await this.ctx.decodeAudioData(await response.arrayBuffer()))
      }
      const clip = this.ctx.createBufferSource()
      clip.buffer = this.clips.get(src)
      clip.connect(this.send)
      clip.connect(this.ctx.destination) // so you hear what it asked
      if (this.micGain) this.micGain.gain.value = 0
      clip.onended = () => this.micGain && (this.micGain.gain.value = this.room?.muted ? 0 : 1)
      clip.start()
    } catch (error) {
      this.status(`Couldn't ask: ${error.message}`)
    }
  },

  async say() {
    const input = this.$("#text")
    const text = input.value.trim()
    if (!text || !this.ai) return
    input.value = ""
    await this.ai.say("assistant", text).catch((reason) => this.status(`Not sent: ${reason}`))
  },

  toggleMute() {
    if (!this.room) return
    const muted = !this.room.muted
    this.room.setMuted(muted)
    if (this.micGain) this.micGain.gain.value = muted ? 0 : 1
    this.$("#mute").textContent = muted ? "Unmute" : "Mute"
  },

  renderTranscript(items) {
    const box = document.getElementById("transcript")
    box.replaceChildren(
      ...items.map((item) => {
        const p = document.createElement("p")
        if (item.interrupted) p.className = "text-base-content/60"
        const who = document.createElement("span")
        who.className = "font-semibold mr-2"
        who.textContent = item.role === "assistant" ? "Agent" : "You"
        p.append(who, item.text + (item.interrupted ? " (interrupted)" : ""))
        return p
      }),
    )
  },

  cleanup() {
    clearInterval(this.probeTimer)
    this.probe = null
    this.micStream?.getTracks().forEach((t) => t.stop())
    this.ctx?.close()
    this.ctx = null
    this.clips.clear() // decoded for that AudioContext
    this.room = null
    this.ai = null
    this.enable(false)
    this.$("#mute").textContent = "Mute"
    this.$("#state").textContent = "not joined"
    this.$("#state").className = "badge badge-ghost"
    this.status("Left.")
  },

  destroyed() {
    this.room?.leave()
    this.socket.disconnect()
  },
}
