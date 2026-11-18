// The browser side of the call: Octoroom's client publishes your mic (and
// camera, and screen) to Cloudflare and plays what the server subscribes you
// to, and sends what you type to an assistant. The LiveView renders
// everything else from the room server's state.
import {RoomClient} from "../../../../priv/static/octoroom.mjs"
import {Socket} from "phoenix"

let room = null
const previews = new WeakMap() // local track => MediaStream, so previews don't flicker

const mediaChanged = () => window.dispatchEvent(new Event("meet:media"))

// The <video> for a participant's camera or screen.
const streamFor = (participantId, source, local) => {
  if (!room) return null
  if (local) {
    const track = room.localTracks()[source]?.track
    if (!track) return null
    if (!previews.has(track)) previews.set(track, new MediaStream([track]))
    return previews.get(track)
  }
  const t = room.tracks().find((t) => t.kind === "video" && t.participant_id === participantId && t.source === source)
  return t?.stream || null
}

export const Video = {
  mounted() {
    this.attach = () => {
      const {participant, source, local} = this.el.dataset
      const stream = streamFor(participant, source, local === "true")
      if (this.el.srcObject !== stream) {
        this.el.srcObject = stream
        this.el.play().catch(() => {})
      }
    }
    window.addEventListener("meet:media", this.attach)
    this.attach()
  },
  destroyed() {
    window.removeEventListener("meet:media", this.attach)
  },
}

export const Call = {
  mounted() {
    this.socket = new Socket("/socket")
    this.socket.connect()

    const saved = localStorage.getItem("meet:name")
    if (saved) this.pushEvent("saved_name", {name: saved})

    this.handleEvent("join", ({name, camera}) => this.join(name, camera))
    this.el.addEventListener("meet:mic", () => room && room.setMuted(!room.muted))
    this.el.addEventListener("meet:camera", () => this.toggleCamera())
    this.el.addEventListener("meet:screen", () => this.toggleScreen())
    this.el.addEventListener("meet:leave", () => room?.leave())
    // The box under the transcript: typed straight to an assistant through
    // the room's channel. The room only takes it from someone the
    // assistant hears; what it says back comes through the transcript.
    this.el.addEventListener("submit", (event) => {
      if (event.target.id !== "say-form") return
      event.preventDefault()
      this.say(event.target)
    })
  },

  async say(form) {
    const to = form.elements.to.value
    const input = form.elements.text
    const text = input.value.trim()
    if (!room || !text) return
    input.value = ""
    try {
      await room.send(to, {text})
    } catch (error) {
      input.value = text
      this.pushEvent("say_failed", {to, reason: error.message})
    }
  },

  async join(name, camera) {
    try { localStorage.setItem("meet:name", name) } catch {}

    // Handlers use this client, not `room`: "left" clears `room` before the
    // client's last "state" event (idle) arrives.
    const client = new RoomClient({
      socket: this.socket,
      topic: `room:${this.el.dataset.room}`,
      params: {name},
      audio: {echoCancellation: true, noiseSuppression: true, autoGainControl: true},
      video: camera ? {width: 1280, height: 720} : false,
    })
    room = client
    client.on("state", (state) => this.pushEvent("client", {state, participant_id: client.participantId}))
    client.on("tracks", mediaChanged)
    client.on("local", mediaChanged)
    client.on("error", (error) => console.error("octoroom:", error))
    client.on("left", () => {
      clearInterval(this.meters)
      if (room === client) room = null
    })

    try {
      await client.join()
      this.meters = setInterval(() => this.updateLevels(), 120)
    } catch (error) {
      console.error("couldn't join:", error)
      this.pushEvent("client", {state: "idle"})
    }
  },

  async toggleCamera() {
    if (!room) return
    if (room.localTracks().camera) await room.stop("camera")
    else await room.startCamera({width: 1280, height: 720}).catch((e) => console.error(e))
  },

  async toggleScreen() {
    if (!room) return
    if (room.localTracks().screen) await Promise.all([room.stop("screen"), room.stop("screen_audio")])
    else await room.shareScreen().catch((e) => console.error(e))
  },

  // Lights each tile's ring while that person, or the assistant, is talking.
  async updateLevels() {
    if (!room?.pc) return
    const levels = {}
    const byMid = new Map(room.tracks().map((t) => [t.mid, t]))
    const micId = room.localTracks().mic?.track.id
    const stats = await room.pc.getStats()
    stats.forEach((s) => {
      if (s.kind !== "audio") return
      if (s.type === "inbound-rtp") {
        const t = byMid.get(s.mid)
        const id = t?.source === "mic" ? t.participant_id : t?.worker_id
        if (id) levels[id] = s.audioLevel ?? 0
      } else if (s.type === "media-source" && s.trackIdentifier === micId && !room.muted) {
        levels[room.participantId] = s.audioLevel ?? 0
      }
    })
    document.querySelectorAll("[data-level]").forEach((el) => {
      el.style.opacity = (levels[el.dataset.level] || 0) > 0.02 ? "1" : "0"
    })
  },

  // LiveView reconnected (e.g. the server restarted): tell it who we are again.
  reconnected() {
    if (room) this.pushEvent("client", {state: room.state, participant_id: room.participantId})
  },

  destroyed() {
    room?.leave()
    this.socket.disconnect()
  },
}
