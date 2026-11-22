// Browser side for examples/vision: publishes mic + optional camera/screen
// through Octoroom's RoomClient, lets RoomClient auto-capture low-FPS JPEG
// snapshots when the room's agent sees them, and renders the agent's state
// and transcript via octoroom_agents.mjs.
import {Socket} from "phoenix"
import {RoomClient} from "../../../../priv/static/octoroom.mjs"
import {agents} from "../../../../agents/priv/static/octoroom_agents.mjs"

const badges = {
  listening: "badge-success",
  thinking: "badge-info",
  waiting: "badge-info",
  speaking: "badge-warning",
}

export const Vision = {
  mounted() {
    this.socket = new Socket("/socket")
    this.socket.connect()
    this.$ = (sel) => this.el.querySelector(sel)
    this.$("#join").onclick = () => this.join()
    this.$("#leave").onclick = () => this.room?.leave()
    this.$("#mute").onclick = () => this.toggleMute()
    this.$("#camera").onclick = () => this.toggleCamera()
    this.$("#screen").onclick = () => this.toggleScreen()
    this.$("#pause-vision").onclick = () => this.toggleVision()
    this.$("#say").onsubmit = (e) => {
      e.preventDefault()
      this.say()
    }
  },

  status(text) {
    this.$("#status").textContent = text
  },

  enable(inCall) {
    this.$("#join").disabled = inCall
    for (const el of this.el.querySelectorAll(
      "#leave, #mute, #camera, #screen, #pause-vision, #say input, #say button",
    )) {
      el.disabled = !inCall
    }
  },

  async join() {
    this.enable(true)
    this.status("Joining…")
    const startedAt = performance.now()

    const room = new RoomClient({
      socket: this.socket,
      topic: `room:${this.el.dataset.room}`,
      params: {mode: this.el.dataset.mode || "cascaded"},
      audio: {echoCancellation: true, noiseSuppression: true, autoGainControl: true},
    })
    this.room = room
    const ai = agents(room)
    this.ai = ai

    ai.on("agents", (list) => {
      const assistant = list.find((a) => a.id === "assistant")
      const state = assistant?.state || "joining"
      const pill = this.$("#state")
      pill.textContent = assistant?.name ? `${assistant.name}: ${state}` : state
      pill.className = `badge ${badges[state] || "badge-ghost"}`
    })
    ai.on("transcript", ({agent, items}) => agent === "assistant" && this.renderTranscript(items))
    ai.on("error", ({stage, fatal}) =>
      this.status(`The agent's ${stage} failed${fatal ? " and it stopped" : ""}.`),
    )

    room.on("local", (tracks) => this.renderLocal(tracks))
    room.on("capture", ({sources, enabled}) => this.renderCaptureBadge(sources, enabled))
    room.on("error", (error) => this.status(`Error: ${error.message}`))
    room.on("left", () => this.cleanup())

    try {
      await room.join()
      this.status(`Joined in ${Math.round(performance.now() - startedAt)} ms.`)
    } catch (error) {
      this.status(`Couldn't join: ${error.message}`)
      this.cleanup()
    }
  },

  async toggleCamera() {
    if (!this.room) return
    try {
      if (this.room.localTracks().camera) {
        await this.room.stop("camera")
      } else {
        await this.room.startCamera({width: {ideal: 1280}, height: {ideal: 720}})
      }
    } catch (error) {
      this.status(`Camera error: ${error.message}`)
    }
  },

  async toggleScreen() {
    if (!this.room) return
    try {
      if (this.room.localTracks().screen) {
        await this.room.stop("screen")
        await this.room.stop("screen_audio")
      } else {
        await this.room.shareScreen({video: true, audio: false})
      }
    } catch (error) {
      this.status(`Screen share error: ${error.message}`)
    }
  },

  toggleVision() {
    if (!this.room) return
    const next = !this.room.captureEnabled
    this.room.setCaptureEnabled(next)
    this.$("#pause-vision").textContent = next ? "Pause AI vision" : "Resume AI vision"
    this.renderCaptureBadge(this.room.capturingSources(), next)
  },

  toggleMute() {
    if (!this.room) return
    const muted = !this.room.muted
    this.room.setMuted(muted)
    this.$("#mute").textContent = muted ? "Unmute" : "Mute"
  },

  async say() {
    const input = this.$("#text")
    const text = input.value.trim()
    if (!text || !this.ai) return
    input.value = ""
    await this.ai.say("assistant", text).catch((reason) => this.status(`Not sent: ${reason}`))
  },

  renderLocal(tracks) {
    const cam = tracks.camera?.track
    const scr = tracks.screen?.track
    this.$("#camera").textContent = cam ? "Camera off" : "Camera on"
    this.$("#screen").textContent = scr ? "Stop sharing" : "Share screen"
    this.attachPreview("#camera-card", "#camera-video", cam)
    this.attachPreview("#screen-card", "#screen-video", scr)
  },

  attachPreview(cardSel, videoSel, track) {
    const card = this.$(cardSel)
    const video = this.$(videoSel)
    if (track) {
      card.classList.remove("hidden")
      if (video.srcObject?.getVideoTracks()?.[0] !== track) {
        video.srcObject = new MediaStream([track])
      }
    } else {
      card.classList.add("hidden")
      video.srcObject = null
    }
  },

  renderCaptureBadge(sources, enabled) {
    const badge = this.$("#capture-badge")
    if (!enabled) {
      badge.textContent = "AI vision paused"
      badge.className = "badge badge-ghost"
    } else if (sources.length > 0) {
      badge.textContent = `AI sees: ${sources.join(", ")}`
      badge.className = "badge badge-accent"
    } else {
      badge.textContent = "AI sees: nothing"
      badge.className = "badge badge-ghost"
    }
  },

  renderTranscript(items) {
    const box = this.$("#transcript")
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
    this.room = null
    this.ai = null
    this.enable(false)
    this.$("#mute").textContent = "Mute"
    this.$("#camera").textContent = "Camera on"
    this.$("#screen").textContent = "Share screen"
    this.$("#pause-vision").textContent = "Pause AI vision"
    this.attachPreview("#camera-card", "#camera-video", null)
    this.attachPreview("#screen-card", "#screen-video", null)
    this.$("#state").textContent = "not joined"
    this.$("#state").className = "badge badge-ghost"
    this.renderCaptureBadge([], true)
    this.status("Left.")
  },

  destroyed() {
    this.room?.leave()
    this.socket.disconnect()
  },
}
