// The browser side of the call: Octoroom's client publishes your mic (and
// camera, and screen) to Cloudflare and plays what the server subscribes you
// to, and sends what you type to an assistant. The LiveView renders
// everything else from the room server's state.
import {RoomClient} from "../../../../priv/static/octoroom.mjs"
import {Socket} from "phoenix"

let room = null
const previews = new WeakMap() // local track => MediaStream, so previews don't flicker

const AUDIO_CONSTRAINTS = {echoCancellation: true, noiseSuppression: true, autoGainControl: true}
const VIDEO_CONSTRAINTS = {width: 1280, height: 720}

// Pre-acquired lobby ("green room") media so joining skips cold getUserMedia.
// Tracks handed to RoomClient are tracked in `handedOffTracks`, because
// RoomClient doesn't stop tracks from a caller-provided stream.
const lobby = {
  stream: null,
  promise: null,
  generation: 0,
  wantCamera: true,
  mounted: false,
  videoEl: null,
  placeholderEl: null,
  statusEl: null,
}
const handedOffTracks = new Set()

const stopTracks = (tracks) => {
  for (const t of tracks) {
    try { t.stop() } catch {}
  }
}

const stopHandedOff = () => {
  stopTracks(handedOffTracks)
  handedOffTracks.clear()
}

const liveTracks = (stream, kind) =>
  stream ? stream.getTracks().filter((t) => t.kind === kind && t.readyState === "live") : []

const renderLobbyPreview = (statusText = null) => {
  const {videoEl, placeholderEl, statusEl, stream, wantCamera} = lobby
  if (!videoEl || !placeholderEl) return
  const [video] = liveTracks(stream, "video")
  if (video && wantCamera) {
    const media = new MediaStream([video])
    videoEl.srcObject = media
    videoEl.classList.remove("hidden")
    placeholderEl.classList.add("hidden")
    videoEl.play().catch(() => {})
  } else {
    videoEl.srcObject = null
    videoEl.classList.add("hidden")
    placeholderEl.classList.remove("hidden")
    if (statusEl) {
      if (statusText) statusEl.textContent = statusText
      else if (!wantCamera) {
        statusEl.textContent = liveTracks(stream, "audio").length > 0 ? "Camera off — mic ready" : "Camera off"
      } else {
        statusEl.textContent = "Preparing camera and mic…"
      }
    }
  }
}

const discardLobbyStream = () => {
  lobby.generation++
  if (lobby.stream) {
    stopTracks(lobby.stream.getTracks())
    lobby.stream = null
  }
  lobby.promise = null
}

const warmLobbyMedia = (wantCamera) => {
  lobby.wantCamera = wantCamera
  if (!navigator.mediaDevices?.getUserMedia) {
    renderLobbyPreview("Camera/mic will be requested on join")
    return Promise.resolve(null)
  }

  // If audio is already warm, only toggle the video track.
  if (lobby.stream && liveTracks(lobby.stream, "audio").length > 0) {
    const videos = liveTracks(lobby.stream, "video")
    if (!wantCamera) {
      for (const v of videos) {
        lobby.stream.removeTrack(v)
        v.stop()
      }
      renderLobbyPreview()
      return Promise.resolve(lobby.stream)
    }
    if (videos.length > 0) {
      renderLobbyPreview()
      return Promise.resolve(lobby.stream)
    }
    const gen = ++lobby.generation
    renderLobbyPreview("Starting camera…")
    const p = navigator.mediaDevices
      .getUserMedia({video: VIDEO_CONSTRAINTS})
      .then((camStream) => {
        const [video] = camStream.getVideoTracks()
        if (gen !== lobby.generation || !lobby.stream || !lobby.wantCamera) {
          stopTracks(camStream.getTracks())
          return lobby.stream
        }
        if (video) lobby.stream.addTrack(video)
        renderLobbyPreview()
        return lobby.stream
      })
      .catch(() => {
        if (gen === lobby.generation) renderLobbyPreview("Camera unavailable — mic ready")
        return lobby.stream
      })
      .finally(() => {
        if (lobby.promise === p) lobby.promise = null
      })
    lobby.promise = p
    return p
  }

  discardLobbyStream()
  const gen = lobby.generation
  renderLobbyPreview(wantCamera ? "Preparing camera and mic…" : "Preparing mic…")
  const p = navigator.mediaDevices
    .getUserMedia({audio: AUDIO_CONSTRAINTS, video: wantCamera ? VIDEO_CONSTRAINTS : false})
    .then((stream) => {
      if (gen !== lobby.generation) {
        stopTracks(stream.getTracks())
        return null
      }
      if (!lobby.wantCamera) {
        for (const v of stream.getVideoTracks()) {
          stream.removeTrack(v)
          v.stop()
        }
      }
      lobby.stream = stream
      renderLobbyPreview()
      return stream
    })
    .catch(() => {
      if (gen === lobby.generation) renderLobbyPreview("Camera/mic will be requested on join")
      return null
    })
    .finally(() => {
      if (lobby.promise === p) lobby.promise = null
    })
  lobby.promise = p
  return p
}

// Claims the pre-acquired lobby MediaStream if it matches the join's camera
// choice, returning null to let RoomClient call getUserMedia itself otherwise.
const takeLobbyStream = async (camera) => {
  if (lobby.promise) await lobby.promise
  let stream = lobby.stream
  if (!stream || liveTracks(stream, "audio").length === 0) return null

  if (!camera) {
    for (const v of stream.getVideoTracks()) {
      stream.removeTrack(v)
      v.stop()
    }
  } else if (liveTracks(stream, "video").length === 0) {
    // User asked for camera, but lobby only has audio: let RoomClient open both.
    discardLobbyStream()
    return null
  }

  // Hand off ownership of these tracks to the call lifecycle.
  lobby.stream = null
  lobby.generation++
  if (lobby.videoEl) lobby.videoEl.srcObject = null
  for (const t of stream.getTracks()) handedOffTracks.add(t)
  return stream
}

export const LobbyPreview = {
  mounted() {
    lobby.mounted = true
    lobby.videoEl = this.el.querySelector("[data-preview-video]")
    lobby.placeholderEl = this.el.querySelector("[data-preview-placeholder]")
    lobby.statusEl = this.el.querySelector("[data-preview-status]")

    const form = this.el.closest(".card-body")?.querySelector("#join-form")
    const checkbox = form?.querySelector('input[type="checkbox"][name="camera"]')
    const wantCamera = checkbox ? checkbox.checked : true
    this.onCameraToggle = (e) => warmLobbyMedia(e.target.checked)
    checkbox?.addEventListener("change", this.onCameraToggle)
    this.checkbox = checkbox

    warmLobbyMedia(wantCamera)
  },

  destroyed() {
    this.checkbox?.removeEventListener("change", this.onCameraToggle)
    lobby.mounted = false
    lobby.videoEl = null
    lobby.placeholderEl = null
    lobby.statusEl = null
    // If we left the lobby without handing the stream to a room (e.g. navigated
    // away), release the hardware devices.
    if (lobby.stream) discardLobbyStream()
  },
}

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

    const stream = await takeLobbyStream(camera)

    // Handlers use this client, not `room`: "left" clears `room` before the
    // client's last "state" event (idle) arrives.
    const client = new RoomClient({
      socket: this.socket,
      topic: `room:${this.el.dataset.room}`,
      params: {name},
      stream,
      audio: AUDIO_CONSTRAINTS,
      video: camera ? VIDEO_CONSTRAINTS : false,
    })
    room = client
    client.on("state", (state) => this.pushEvent("client", {state, participant_id: client.participantId}))
    client.on("tracks", mediaChanged)
    client.on("local", mediaChanged)
    client.on("error", (error) => console.error("octoroom:", error))
    client.on("left", () => {
      clearInterval(this.meters)
      stopHandedOff()
      if (room === client) room = null
    })

    try {
      await client.join()
      this.meters = setInterval(() => this.updateLevels(), 120)
    } catch (error) {
      console.error("couldn't join:", error)
      this.pushEvent("client", {state: "idle"})
      if (lobby.mounted) warmLobbyMedia(lobby.wantCamera)
    }
  },

  async toggleCamera() {
    if (!room) return
    const existing = room.localTracks().camera?.track
    if (existing) {
      await room.stop("camera")
      if (handedOffTracks.has(existing)) {
        existing.stop()
        handedOffTracks.delete(existing)
      }
    } else {
      await room.startCamera(VIDEO_CONSTRAINTS).catch((e) => console.error(e))
    }
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
    stopHandedOff()
    discardLobbyStream()
    this.socket.disconnect()
  },
}
