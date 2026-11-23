// Browser side for the 1-on-1 Voice Stage + Workbench demo.
//
// Connects Octoroom's RoomClient + octoroom_agents helper to:
// - The headless Agent Presence Orb (`agent_orb.js`)
// - The headless 2-lane Voice Timeline (`voice_timeline_store.js` + `voice_timeline_canvas.js`)
// - Live streaming captions, chat transcript bubbles, recorded question probes,
//   and tab-measured reply latency (`LatencyProbe`).

import {Socket} from "phoenix"
import {RoomClient} from "../../../../priv/static/octoroom.mjs"
import {agents} from "../../../../agents/priv/static/octoroom_agents.mjs"
import {createAgentOrb} from "./agent_orb.js"
import {
  DEFAULT_WINDOW_MS,
  applyTimelineEvent,
  createTimelineState,
  stagesForTurn,
} from "./voice_timeline_store.js"
import {
  createVoiceTimelineCanvas,
  resumeTimelineAudio,
} from "./voice_timeline_canvas.js"

const STAGE_COLORS = {
  stt: "#64748b",
  decisions: "#f59e0b",
  floor_wait: "#d97706",
  llm: "#4f46e5",
  tool: "#9333ea",
  tts: "#10b981",
  live: "#0284c7",
}

// Times each reply in this tab: from your voice going quiet to the agent's
// voice arriving, read from an analyser on each every 10 ms. Speech "ends"
// after 400 ms below the threshold, and is dated to its last loud sample.
class LatencyProbe {
  constructor(local, onHeard) {
    this.local = local
    this.remote = null
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
  if (!analyser) return 0
  const data = new Float32Array(analyser.fftSize)
  analyser.getFloatTimeDomainData(data)
  let sum = 0
  for (let i = 0; i < data.length; i++) sum += data[i] * data[i]
  return Math.sqrt(sum / data.length)
}

function normalizedLevel(analyser) {
  const value = rms(analyser)
  const db = 20 * Math.log10(value + 1e-8)
  const linear = Math.min(1, Math.max(0, (db + 52) / 42))
  return linear > 0 ? Math.pow(linear, 1.15) : 0
}

function isDarkTheme() {
  const attr = document.documentElement.getAttribute("data-theme")
  if (attr === "dark") return true
  if (attr === "light") return false
  return matchMedia("(prefers-color-scheme: dark)").matches
}

function formatClock(ms) {
  const sec = Math.max(0, Math.floor(ms / 1000))
  const m = Math.floor(sec / 60)
  const s = sec % 60
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
}

function formatMs(ms) {
  return ms < 1000 ? `${Math.round(ms)}ms` : `${(ms / 1000).toFixed(1)}s`
}

const stateBadges = {
  listening: "badge-success",
  thinking: "badge-warning",
  waiting: "badge-warning",
  speaking: "badge-primary",
  joining: "badge-info",
  error: "badge-error",
}

const stateCopy = {
  idle: "Ready to talk",
  joining: "Connecting…",
  listening: "Listening",
  thinking: "Thinking…",
  waiting: "Waiting…",
  speaking: "Speaking",
  error: "Error",
}

const readyStates = new Set(["listening", "thinking", "waiting", "speaking"])

export const Agent = {
  mounted() {
    this.socket = new Socket("/socket")
    this.socket.connect()
    this.$ = (sel) => this.el.querySelector(sel)
    this.agentName = this.el.dataset.agentName || "Agent"

    this.$("#join").onclick = () => this.join()
    this.$("#leave").onclick = () => this.room?.leave()
    this.$("#mute").onclick = () => this.toggleMute()
    const camBtn = this.$("#camera")
    if (camBtn) camBtn.onclick = () => this.toggleCamera()
    this.el.querySelectorAll(".ask").forEach((b) => (b.onclick = () => this.ask(b.dataset.src)))
    this.$("#say").onsubmit = (e) => {
      e.preventDefault()
      this.say()
    }

    this.clips = new Map()
    this.localAnalyser = null
    this.remoteAnalyser = null
    this.agentState = "idle"
    this.awaitingReady = false
    this.callStartedAt = null
    this.clockTimer = null
    this.meterFrame = 0
    this.transcriptItems = []
    this.transcriptSeq = new Map()
    this.toolCalls = new Map()
    this.feedSeq = 0

    // Headless Agent Presence Orb
    this.orbCanvas = this.$("[data-agent-orb]")
    const initial = this.el.dataset.agentInitial || this.agentName.charAt(0).toUpperCase() || "A"
    this.orb = this.orbCanvas ? createAgentOrb(this.orbCanvas, {glyph: initial}) : null

    // Headless 2-lane Voice Timeline (Option A tape + Option B hover waterfall)
    this.tlCanvas = this.$("[data-timeline-canvas]")
    this.tlLanesEl = this.$("[data-timeline-lane-labels]")
    this.tlPopover = this.$("[data-timeline-popover]")
    this.tlBody = this.$("#voice-timeline-body")
    this.tlPauseBtn = this.$("[data-timeline-pause]")
    this.tlPauseLabel = this.$("[data-timeline-pause-label]")
    this.tlLiveBtn = this.$("[data-timeline-live]")
    this.tlWindowBtns = [...this.el.querySelectorAll("[data-timeline-window]")]
    this.tlState = createTimelineState()
    this.tlPaused = false
    this.tlWindowMs = DEFAULT_WINDOW_MS
    this.tlAudible = new Set()
    this.tlDragging = false
    this.tlDragLastX = 0

    this.tlLanes = [
      {id: "assistant", label: this.agentName, role: "agent"},
      {id: "you", label: "You", role: "user"},
    ]

    if (this.tlCanvas) {
      this.timeline = createVoiceTimelineCanvas(this.tlCanvas, {
        onSpeechEvent: (ev) => this.dispatchTimeline(ev),
        onLevelSpeaking: (laneId, speaking) => {
          if (speaking) this.tlAudible.add(laneId)
          else this.tlAudible.delete(laneId)
          this.syncTimelineLaneStatus()
        },
        onScrollChange: (scrolledBack) => {
          this.tlLiveBtn?.classList.toggle("hidden", !scrolledBack)
        },
      })
      const layout = this.timeline.setLanes(this.tlLanes)
      this.renderTimelineHeaders(layout)
      this.bindTimelineControls()
    }

    // Live theme sync for Orb + Voice Timeline
    this.applyTheme = () => this.syncTheme()
    this.themeObserver = new MutationObserver(this.applyTheme)
    this.themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["class", "style", "data-theme"],
    })
    this.scheme = matchMedia("(prefers-color-scheme: dark)")
    this.scheme.addEventListener("change", this.applyTheme)
    this.syncTheme()

    // LiveView pushed events: streaming captions, waterfall stage spans, and inline tool calls
    this.handleEvent("partial", ({text}) => {
      if (text) this.setCaption("You", text, {italic: true, role: "user"})
    })
    this.handleEvent("timeline_event", (payload) => this.onServerTimelineEvent(payload))
    this.handleEvent("tool_call", (call) => this.upsertToolCall(call))
    this.handleEvent("pipeline_switched", ({name}) => {
      this.status(`Switched pipeline to ${name} (restarting agent…)`)
    })

    // Start orb/meter animation loop
    const animateMeters = () => {
      const agentLvl = normalizedLevel(this.remoteAnalyser)
      const userLvl = normalizedLevel(this.localAnalyser)
      this.orb?.setLevels(agentLvl, userLvl)
      this.updateMicDots(userLvl)
      this.meterFrame = requestAnimationFrame(animateMeters)
    }
    this.meterFrame = requestAnimationFrame(animateMeters)
  },

  bindTimelineControls() {
    this.onPauseClick = () => {
      this.tlPaused = !this.tlPaused
      this.timeline?.setPaused(this.tlPaused)
      if (this.tlPauseBtn) {
        this.tlPauseBtn.dataset.paused = String(this.tlPaused)
        this.tlPauseBtn.title = this.tlPaused ? "Resume live timeline" : "Pause timeline"
      }
      if (this.tlPauseLabel) {
        this.tlPauseLabel.textContent = this.tlPaused ? "Resume" : "Pause"
      }
    }
    this.tlPauseBtn?.addEventListener("click", this.onPauseClick)

    this.onLiveClick = () => {
      this.tlPaused = false
      this.timeline?.jumpToLive()
      if (this.tlPauseBtn) {
        this.tlPauseBtn.dataset.paused = "false"
        this.tlPauseBtn.title = "Pause timeline"
      }
      if (this.tlPauseLabel) this.tlPauseLabel.textContent = "Pause"
    }
    this.tlLiveBtn?.addEventListener("click", this.onLiveClick)

    this.onWindowClick = (event) => {
      const sec = Number(event.currentTarget.dataset.timelineWindow)
      if (!Number.isFinite(sec) || sec <= 0) return
      this.tlWindowMs = sec * 1000
      this.timeline?.setWindowMs(this.tlWindowMs)
      this.updateWindowButtons()
    }
    for (const btn of this.tlWindowBtns) {
      btn.addEventListener("click", this.onWindowClick)
    }
    this.updateWindowButtons()

    // Wheel scroll (trackpad horizontal or mouse vertical) scrubs through history.
    this.onWheel = (event) => {
      const delta = Math.abs(event.deltaX) >= Math.abs(event.deltaY) ? event.deltaX : event.deltaY
      if (delta === 0) return
      event.preventDefault()
      this.tlPopover?.classList.add("hidden")
      this.timeline?.scrollByPixels(delta)
    }
    this.tlCanvas.addEventListener("wheel", this.onWheel, {passive: false})

    // Click-and-drag pan on the timeline canvas.
    this.onPointerDown = (event) => {
      if (event.button !== 0) return
      this.tlDragging = true
      this.tlDragLastX = event.clientX
      this.tlCanvas.setPointerCapture?.(event.pointerId)
      this.tlCanvas.style.cursor = "grabbing"
      this.tlPopover?.classList.add("hidden")
    }
    this.onPointerUp = (event) => {
      if (!this.tlDragging) return
      this.tlDragging = false
      this.tlCanvas.releasePointerCapture?.(event.pointerId)
      this.tlCanvas.style.cursor = "grab"
    }

    this.onPointerMove = (event) => {
      if (this.tlDragging) {
        const dx = event.clientX - this.tlDragLastX
        this.tlDragLastX = event.clientX
        // Dragging right pulls older history into view (scrolls backward in time).
        this.timeline?.scrollByPixels(-dx)
        return
      }
      const rect = this.tlCanvas.getBoundingClientRect()
      const hit = this.timeline.hitTestTurn(event.clientX - rect.left, event.clientY - rect.top)
      this.timeline.setHoveredTurn(hit ? hit.turn.id : null)
      this.tlCanvas.style.cursor = hit ? "pointer" : "grab"
      if (!hit) {
        this.tlPopover?.classList.add("hidden")
        return
      }
      this.showWaterfallPopover(hit, event.clientX)
    }
    this.onPointerLeave = () => {
      if (this.tlDragging) return
      this.timeline?.setHoveredTurn(null)
      this.tlCanvas.style.cursor = ""
      this.tlPopover?.classList.add("hidden")
    }
    this.tlCanvas.addEventListener("pointerdown", this.onPointerDown)
    this.tlCanvas.addEventListener("pointerup", this.onPointerUp)
    this.tlCanvas.addEventListener("pointercancel", this.onPointerUp)
    this.tlCanvas.addEventListener("pointermove", this.onPointerMove)
    this.tlCanvas.addEventListener("pointerleave", this.onPointerLeave)
  },

  updateWindowButtons() {
    const active = Math.round(this.tlWindowMs / 1000)
    for (const btn of this.tlWindowBtns) {
      const on = Number(btn.dataset.timelineWindow) === active
      btn.classList.toggle("btn-active", on)
      btn.setAttribute("aria-pressed", String(on))
    }
  },

  syncTheme() {
    const dark = isDarkTheme()
    const agentColor = dark ? "#818cf8" : "#4f46e5"
    const agentAccent = dark ? "#38bdf8" : "#0284c7"
    const userColor = dark ? "#34d399" : "#059669"

    this.orb?.setPalette({
      agent: agentColor,
      agentAccent,
      user: userColor,
      thinking: "#f59e0b",
      idle: dark ? "#64748b" : "#94a3b8",
    })

    this.timeline?.setPalette({
      laneColors: {assistant: agentColor, you: userColor},
      defaultAgent: agentColor,
      defaultUser: userColor,
      divider: dark ? "rgba(255,255,255,0.12)" : "rgba(15,23,42,0.10)",
      grid: dark ? "rgba(255,255,255,0.06)" : "rgba(15,23,42,0.05)",
      mutedText: dark ? "rgba(255,255,255,0.45)" : "rgba(15,23,42,0.45)",
      chipBg: dark ? "#1f2937" : "#111827",
      chipText: "#f9fafb",
      wait: "#f59e0b",
      cut: "#ef4444",
      backchannel: dark ? "#94a3b8" : "#64748b",
    })

    if (this.tlLanesEl) {
      const aSw = this.tlLanesEl.querySelector('[data-lane="assistant"] [data-lane-swatch]')
      const uSw = this.tlLanesEl.querySelector('[data-lane="you"] [data-lane-swatch]')
      if (aSw) aSw.style.backgroundColor = agentColor
      if (uSw) uSw.style.backgroundColor = userColor
    }
  },

  renderTimelineHeaders(layout) {
    if (!this.tlLanesEl) return
    this.tlLanesEl.style.height = `${layout.totalHeight}px`
    this.tlLanesEl.innerHTML = ""
    const dark = isDarkTheme()
    const colors = {assistant: dark ? "#818cf8" : "#4f46e5", you: dark ? "#34d399" : "#059669"}

    for (const track of layout.tracks) {
      const row = document.createElement("div")
      row.dataset.lane = track.id
      row.className =
        "group/lane absolute inset-x-0 flex items-center gap-1.5 rounded-md px-1.5 text-xs text-base-content/60 transition-colors duration-150 data-[state=speaking]:bg-base-200/80 data-[state=speaking]:text-base-content"
      row.style.top = `${track.top}px`
      row.style.height = `${track.height}px`

      const swatch = document.createElement("span")
      swatch.dataset.laneSwatch = ""
      swatch.className =
        "h-3 w-1 shrink-0 rounded-full opacity-45 transition-opacity duration-150 group-data-[state=speaking]/lane:opacity-100"
      swatch.style.backgroundColor = colors[track.id] || "#818cf8"

      const name = document.createElement("span")
      name.className = "truncate font-medium"
      name.textContent = track.label

      row.append(swatch, name)
      this.tlLanesEl.append(row)
    }
  },

  syncTimelineLaneStatus() {
    if (!this.tlLanesEl) return
    for (const lane of this.tlLanes) {
      const row = this.tlLanesEl.querySelector(`[data-lane="${lane.id}"]`)
      if (!row) continue
      const speaking =
        this.tlAudible.has(lane.id) ||
        Boolean(this.tlState.speaking[lane.id]) ||
        (lane.id === "assistant" && this.agentState === "speaking")
      row.dataset.state = speaking ? "speaking" : "silent"
    }
  },

  dispatchTimeline(event) {
    this.tlState = applyTimelineEvent(this.tlState, event)
    this.timeline?.setTimelineState(this.tlState)
    this.syncTimelineLaneStatus()
  },

  onServerTimelineEvent(payload) {
    const now = performance.now()
    if (payload.type === "reply_latency") {
      this.dispatchTimeline({type: "reply-latency", agentId: "assistant", audioMs: payload.audio_ms, now})
    } else if (payload.type === "stage_spans") {
      this.dispatchTimeline({type: "stage-spans", spans: payload.spans, now})
    } else if (payload.type === "interruption") {
      this.dispatchTimeline({type: "interruption", agentId: "assistant", userLaneId: "you", now})
    }
  },

  showWaterfallPopover(hit, clientX) {
    if (!this.tlPopover || !this.tlBody) return
    const {turn, track} = hit
    const stages = stagesForTurn(this.tlState, turn)
    const isCut = this.tlState.overlaps.some(
      (o) => o.cut && o.agentId === turn.laneId && o.start >= turn.start - 500 && o.start <= (turn.end ?? performance.now()) + 500,
    )

    this.tlPopover.replaceChildren()

    const head = document.createElement("div")
    head.className = "flex items-center justify-between gap-3"
    const title = document.createElement("span")
    title.className = "font-sans text-xs font-semibold"
    title.textContent =
      turn.latencyMs !== null ? `${track.label} · ${formatMs(turn.latencyMs)}` : track.label
    head.append(title)

    if (isCut) {
      const tag = document.createElement("span")
      tag.className = "rounded-full bg-error/20 px-1.5 py-0.5 text-[10px] font-semibold text-error"
      tag.textContent = "interrupted"
      head.append(tag)
    } else if (turn.end !== null) {
      const dur = document.createElement("span")
      dur.className = "text-[10px] opacity-60"
      dur.textContent = `${formatMs(turn.end - turn.start)} audio`
      head.append(dur)
    }
    this.tlPopover.append(head)

    if (stages.length > 0) {
      const total = stages.reduce((sum, s) => sum + Math.max(s.durationMs, 1), 0)
      const bar = document.createElement("div")
      bar.className = "mt-2 mb-1.5 flex h-2 w-full gap-px overflow-hidden rounded"
      for (const s of stages) {
        const seg = document.createElement("div")
        seg.className = "h-full min-w-[3px]"
        seg.style.width = `${(Math.max(s.durationMs, 1) / total) * 100}%`
        seg.style.backgroundColor = STAGE_COLORS[s.kind] || "#64748b"
        bar.append(seg)
      }
      this.tlPopover.append(bar)

      const kv = document.createElement("div")
      kv.className = "flex flex-wrap gap-x-2.5 gap-y-0.5 text-[10px] opacity-80"
      for (const s of stages) {
        const item = document.createElement("span")
        item.className = "inline-flex items-center gap-1"
        const dot = document.createElement("span")
        dot.className = "size-1.5 rounded-[1px]"
        dot.style.backgroundColor = STAGE_COLORS[s.kind] || "#64748b"
        const label = document.createElement("span")
        label.textContent = `${s.label} ${Math.round(s.durationMs)}ms`
        item.append(dot, label)
        kv.append(item)
      }
      this.tlPopover.append(kv)
    } else {
      const hint = document.createElement("div")
      hint.className = "mt-1 text-[10px] opacity-60"
      hint.textContent = turn.end === null ? "Speaking…" : "Audio reply"
      this.tlPopover.append(hint)
    }

    this.tlPopover.classList.remove("hidden")
    const bodyRect = this.tlBody.getBoundingClientRect()
    const popW = this.tlPopover.offsetWidth || 260
    const relX = clientX - bodyRect.left
    const clampedX = Math.min(Math.max(relX - popW / 2, 8), Math.max(8, bodyRect.width - popW - 8))
    this.tlPopover.style.left = `${Math.round(clampedX)}px`
  },

  setAgentState(next) {
    this.agentState = next
    if (next === "joining") this.awaitingReady = true
    this.orb?.setState(next)
    const pill = this.$("#state")
    if (pill) {
      pill.textContent = next
      pill.className = `badge badge-sm ${stateBadges[next] || "badge-ghost"}`
    }
    const stageLabel = this.$("[data-stage-state]")
    if (stageLabel) {
      stageLabel.textContent = stateCopy[next] || next
    }
    if (next === "listening" || next === "thinking" || next === "waiting" || next === "speaking") {
      this.dispatchTimeline({type: "agent-state", agentId: "assistant", state: next, now: performance.now()})
      this.maybePlayReadyChime()
    }
    this.syncTimelineLaneStatus()
  },

  maybePlayReadyChime() {
    if (!this.awaitingReady || !this.remoteVoiceTrack || !readyStates.has(this.agentState)) return
    this.awaitingReady = false
    this.playReadyChime()
  },

  // Subtle two-note ascending chime played locally (not routed into `this.send`,
  // so the agent never hears it) when the agent finishes connecting or restarting.
  playReadyChime() {
    const ctx = this.ctx
    if (!ctx || ctx.state === "closed") return
    if (ctx.state === "suspended") ctx.resume().catch(() => {})

    const now = ctx.currentTime
    const notes = [
      {freq: 523.25, start: 0, duration: 0.16},
      {freq: 783.99, start: 0.085, duration: 0.22},
    ]

    for (const {freq, start, duration} of notes) {
      const osc = ctx.createOscillator()
      const gain = ctx.createGain()
      osc.type = "sine"
      osc.frequency.setValueAtTime(freq, now + start)

      gain.gain.setValueAtTime(0.0001, now + start)
      gain.gain.exponentialRampToValueAtTime(0.12, now + start + 0.015)
      gain.gain.exponentialRampToValueAtTime(0.0001, now + start + duration)

      osc.connect(gain)
      gain.connect(ctx.destination)
      osc.start(now + start)
      osc.stop(now + start + duration + 0.01)
    }
  },

  setCaption(who, text, {italic = false, role = "agent"} = {}) {
    const el = this.$("[data-live-caption]")
    if (!el) return
    el.replaceChildren()
    if (!text) {
      el.classList.add("hidden")
      el.classList.remove("flex")
      return
    }
    el.classList.remove("hidden")
    el.classList.add("flex")
    if (who) {
      const tag = document.createElement("span")
      const color =
        role === "error" ? "text-error" : role === "agent" ? "text-primary" : "text-success"
      tag.className = `mr-2 font-mono text-[11px] font-bold uppercase tracking-wide ${color}`
      tag.textContent = who
      el.append(tag)
    }
    const body = document.createElement("span")
    if (italic) body.className = "italic opacity-70"
    body.textContent = text
    el.append(body)
  },

  updateMicDots(level) {
    const dots = this.el.querySelectorAll("[data-mic-dots] span")
    if (dots.length === 0) return
    const muted = Boolean(this.room?.muted) || !this.room
    dots.forEach((dot, i) => {
      const peak = i === 1 || i === 2 ? 14 : 10
      const h = !muted && level > 0.04 ? Math.max(4, Math.round(level * peak)) : 4
      dot.style.height = `${h}px`
    })
  },

  status(text) {
    const el = this.$("#status")
    if (el) el.textContent = text
  },

  enable(inCall) {
    this.$("#join").disabled = inCall
    for (const el of this.el.querySelectorAll("#leave, #mute, #camera, .ask, #say input, #say button")) {
      el.disabled = !inCall
    }
    const dot = this.$("[data-live-dot]")
    if (dot) dot.classList.toggle("bg-success", inCall)
    if (dot) dot.classList.toggle("bg-base-content/30", !inCall)
  },

  // What this tab sends is a mix of your mic and, when you ask one, a
  // recorded question: both go through `this.send`, and the room publishes
  // its output as the mic.
  async join() {
    resumeTimelineAudio()
    this.enable(true)
    this.setAgentState("joining")
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
    this.localAnalyser = local
    this.probe = new LatencyProbe(local, (ms) => this.pushEvent("heard", {ms}))
    this.probeTimer = setInterval(() => this.probe.tick(), 10)

    this.localOutTrack = out.stream.getAudioTracks()[0] || null
    this.remoteVoiceTrack = null
    this.transcriptItems = []
    this.transcriptSeq.clear()
    this.toolCalls.clear()
    this.feedSeq = 0
    this.renderFeed()
    this.tlState = applyTimelineEvent(this.tlState, {type: "reset", now: performance.now()})
    this.timeline?.setTimelineState(this.tlState)
    this.timeline?.reset()
    this.timeline?.setTracks(new Map([["you", this.localOutTrack]]))
    this.timeline?.setRunning(true)

    const pipeline = this.el.dataset.pipeline
    const room = new RoomClient({
      socket: this.socket,
      topic: `room:${this.el.dataset.room}`,
      params: pipeline ? {pipeline} : {},
      stream: out.stream,
    })
    this.room = room
    const ai = agents(room)

    ai.on("agents", (list) => {
      const state = list.find((a) => a.id === "assistant")?.state || "joining"
      this.setAgentState(state)
    })
    ai.on("transcript", ({agent, items}) => agent === "assistant" && this.renderTranscript(items))
    ai.on("error", ({stage, fatal, message}) => {
      const text = message || `The agent's ${stage} failed${fatal ? " and it stopped" : ""}.`
      this.status(text)
      if (fatal) {
        this.awaitingReady = false
        this.setAgentState("error")
        this.setCaption("Error", text, {role: "error"})
      }
    })
    this.ai = ai

    let greeting = null
    room.on("tracks", (tracks) => {
      const video = tracks.find(
        (t) => t.kind === "video" && (t.worker_id === "assistant" || t.track === "assistant/video"),
      )
      this.setAgentVideo(video?.stream || null)

      const voice = tracks.find(
        (t) => t.kind === "audio" && (t.worker_id === "assistant" || t.track === "assistant"),
      )
      if (!voice || this.probe.remote) return
      const remote = this.ctx.createAnalyser()
      remote.fftSize = 512
      this.ctx.createMediaStreamSource(voice.stream).connect(remote)
      this.probe.remote = remote
      this.remoteAnalyser = remote
      this.remoteVoiceTrack = voice.stream.getAudioTracks()[0] || null
      this.maybePlayReadyChime()
      this.timeline?.setTracks(
        new Map([
          ["assistant", this.remoteVoiceTrack],
          ["you", this.localOutTrack],
        ]),
      )

      greeting = {track: performance.now() - startedAt}
      const listen = setInterval(() => {
        if (!this.probe || performance.now() - startedAt > 30_000) return clearInterval(listen)
        if (rms(remote) > 0.01) {
          clearInterval(listen)
          this.pushEvent("greeting", {...greeting, sound: performance.now() - startedAt})
        }
      }, 10)
    })
    room.on("local", (tracks) => {
      const cam = tracks.camera?.track
      this.setLocalVideo(cam ? new MediaStream([cam]) : null)
      this.setCameraUi(Boolean(cam))
    })
    room.on("error", (error) => this.status(`Error: ${error.message}`))
    room.on("left", () => this.cleanup())

    try {
      await room.join()
      this.callStartedAt = performance.now()
      this.clockTimer = setInterval(() => {
        const el = this.$("[data-call-clock]")
        if (el && this.callStartedAt !== null) {
          el.textContent = formatClock(performance.now() - this.callStartedAt)
        }
      }, 500)
      this.setCaption(null, "")
      this.status(
        `Joined in ${Math.round(performance.now() - startedAt)} ms.${mic ? "" : " No microphone: ask a recorded question or type."}`,
      )
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
      clip.connect(this.ctx.destination)
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

  setMuteUi(muted) {
    const btn = this.$("#mute")
    if (!btn) return
    const text = muted ? "Unmute" : "Mute"
    const label = this.$("[data-mute-label]")
    if (label) label.textContent = text
    btn.title = muted ? "Unmute microphone" : "Mute microphone"
    btn.setAttribute("aria-label", text)
    btn.classList.toggle("btn-error", muted)
    btn.classList.toggle("btn-neutral", !muted)
    this.$("[data-mic-on]")?.classList.toggle("hidden", muted)
    this.$("[data-mic-off]")?.classList.toggle("hidden", !muted)
  },

  toggleMute() {
    if (!this.room) return
    const muted = !this.room.muted
    this.room.setMuted(muted)
    if (this.micGain) this.micGain.gain.value = muted ? 0 : 1
    this.setMuteUi(muted)
  },

  setCameraUi(on) {
    const btn = this.$("#camera")
    if (!btn) return
    const text = on ? "Stop camera" : "Share camera"
    const label = this.$("[data-camera-label]")
    if (label) label.textContent = text
    btn.title = text
    btn.setAttribute("aria-label", text)
    btn.classList.toggle("btn-primary", on)
    btn.classList.toggle("btn-neutral", !on)
    this.$("[data-cam-on]")?.classList.toggle("hidden", !on)
    this.$("[data-cam-off]")?.classList.toggle("hidden", on)
  },

  async toggleCamera() {
    if (!this.room) return
    try {
      if (this.room.localTracks().camera) {
        await this.room.stop("camera")
        this.setLocalVideo(null)
        this.setCameraUi(false)
      } else {
        await this.room.startCamera({width: {ideal: 1280}, height: {ideal: 720}})
        const track = this.room.localTracks().camera?.track
        if (track) this.setLocalVideo(new MediaStream([track]))
        this.setCameraUi(Boolean(track))
      }
    } catch (error) {
      this.status(`Camera error: ${error.message}`)
    }
  },

  renderTranscript(items) {
    this.transcriptItems = items.map((item, idx) => {
      const key = item.message_id || `idx-${idx}`
      if (!this.transcriptSeq.has(key)) this.transcriptSeq.set(key, ++this.feedSeq)
      return {kind: "turn", seq: this.transcriptSeq.get(key), item}
    })
    this.renderFeed()

    const latest = items[items.length - 1]
    if (latest) {
      this.setCaption(
        latest.role === "assistant" ? this.agentName : "You",
        latest.text,
        {role: latest.role === "assistant" ? "agent" : "user"},
      )
    }
  },

  upsertToolCall(call) {
    const existing = this.toolCalls.get(call.id)
    const seq = existing ? existing.seq : ++this.feedSeq
    this.toolCalls.set(call.id, {kind: "tool", seq, call})
    this.renderFeed()
  },

  renderFeed() {
    const box = document.getElementById("transcript")
    if (!box) return
    const entries = [...this.transcriptItems, ...this.toolCalls.values()].sort(
      (a, b) => a.seq - b.seq,
    )
    const empty = document.getElementById("transcript-empty")
    if (empty) empty.classList.toggle("hidden", entries.length > 0)

    box.replaceChildren(
      ...entries.map((entry) =>
        entry.kind === "tool"
          ? this.buildToolCallNode(entry.call)
          : this.buildTurnNode(entry.item),
      ),
    )

    const scroller = this.$("#transcript-scroll")
    if (scroller) scroller.scrollTop = scroller.scrollHeight
  },

  buildTurnNode(item) {
    const isAgent = item.role === "assistant"
    const wrap = document.createElement("div")
    wrap.className = "flex flex-col gap-1"

    const head = document.createElement("div")
    head.className = "flex items-center justify-between gap-2 text-xs"

    const who = document.createElement("span")
    who.className = `font-semibold ${isAgent ? "text-primary" : "text-success"}`
    who.textContent = isAgent ? this.agentName : "You"
    head.append(who)

    if (item.interrupted) {
      const badge = document.createElement("span")
      badge.className = "badge badge-xs badge-warning"
      badge.textContent = "interrupted"
      head.append(badge)
    } else if (item.status === "playing") {
      const badge = document.createElement("span")
      badge.className = "badge badge-xs badge-primary"
      badge.textContent = "speaking"
      head.append(badge)
    }

    const bubble = document.createElement("p")
    bubble.className = `rounded-xl px-3 py-2 text-sm ${
      isAgent ? "bg-primary/10 text-base-content" : "bg-base-200 text-base-content"
    } ${item.interrupted ? "opacity-75" : ""}`
    bubble.textContent = item.text

    wrap.append(head, bubble)
    return wrap
  },

  buildToolCallNode(call) {
    const isError = call.status === "error"
    const isRunning = call.status === "running"

    const card = document.createElement("div")
    card.id = `tool-call-${call.id}`
    card.className = `rounded-lg border px-2.5 py-2 font-mono text-[11px] ${
      isError ? "border-error/35 bg-error/10" : "border-secondary/30 bg-secondary/10"
    }`

    const head = document.createElement("div")
    head.className = "flex items-center justify-between gap-2 font-semibold"

    const left = document.createElement("span")
    left.className = `flex min-w-0 items-center gap-1.5 ${isError ? "text-error" : "text-secondary"}`

    const dot = document.createElement("span")
    dot.className = `size-1.5 shrink-0 rounded-full ${
      isError ? "bg-error" : isRunning ? "animate-pulse bg-warning" : "bg-secondary"
    }`

    const name = document.createElement("span")
    name.className = "truncate"
    name.textContent = call.name

    left.append(dot, name)

    const meta = document.createElement("span")
    meta.className = "shrink-0 text-[10px] font-normal opacity-70"
    meta.textContent = isRunning
      ? "running…"
      : `${call.duration_ms ?? 0}ms ${call.status === "ok" ? "✓" : "✗"}`

    head.append(left, meta)
    card.append(head)

    if (call.args_text) {
      const args = document.createElement("div")
      args.className = "mt-0.5 truncate text-[10px] text-base-content/65"
      args.title = call.args_text
      args.textContent = call.args_text
      card.append(args)
    }

    if (call.result_text) {
      const res = document.createElement("div")
      res.className = "mt-0.5 text-[10px] text-base-content/85"
      res.textContent = call.result_text
      card.append(res)
    }

    return card
  },

  setAgentVideo(stream) {
    const videoEl = this.$("[data-agent-video]")
    const orbWrap = this.$("[data-agent-orb-wrap]")
    if (!videoEl) return
    if (stream) {
      if (videoEl.srcObject !== stream) {
        videoEl.srcObject = stream
        videoEl.play().catch(() => {})
      }
      videoEl.classList.remove("hidden")
      orbWrap?.classList.add("hidden")
    } else {
      videoEl.srcObject = null
      videoEl.classList.add("hidden")
      orbWrap?.classList.remove("hidden")
    }
    this.positionLocalVideo()
  },

  setLocalVideo(stream) {
    const localEl = this.$("[data-local-video]")
    if (!localEl) return
    if (stream) {
      if (localEl.srcObject !== stream) {
        localEl.srcObject = stream
        localEl.play().catch(() => {})
      }
      localEl.classList.remove("hidden")
    } else {
      localEl.srcObject = null
      localEl.classList.add("hidden")
    }
    this.positionLocalVideo()
  },

  positionLocalVideo() {
    const agentEl = this.$("[data-agent-video]")
    const localEl = this.$("[data-local-video]")
    if (!localEl) return
    const overlay = agentEl && !agentEl.classList.contains("hidden")
    localEl.classList.toggle("absolute", overlay)
    localEl.classList.toggle("right-3", overlay)
    localEl.classList.toggle("bottom-3", overlay)
    localEl.classList.toggle("z-10", overlay)
  },

  cleanup() {
    this.setAgentVideo(null)
    this.setLocalVideo(null)
    this.setCameraUi(false)
    clearInterval(this.probeTimer)
    clearInterval(this.clockTimer)
    this.probe = null
    this.localAnalyser = null
    this.remoteAnalyser = null
    this.callStartedAt = null
    const clock = this.$("[data-call-clock]")
    if (clock) clock.textContent = "00:00"

    this.dispatchTimeline({type: "disconnected", now: performance.now()})
    this.timeline?.setTracks(new Map())
    this.timeline?.setRunning(false)

    this.micStream?.getTracks().forEach((t) => t.stop())
    this.ctx?.close()
    this.ctx = null
    this.clips.clear()
    this.room = null
    this.ai = null
    this.awaitingReady = false
    this.remoteVoiceTrack = null
    this.enable(false)
    this.setMuteUi(false)
    this.setAgentState("idle")
    const pill = this.$("#state")
    if (pill) {
      pill.textContent = "not joined"
      pill.className = "badge badge-sm badge-ghost"
    }
    this.setCaption(null, "")
    this.status("Left.")
  },

  destroyed() {
    cancelAnimationFrame(this.meterFrame)
    clearInterval(this.probeTimer)
    clearInterval(this.clockTimer)
    this.tlPauseBtn?.removeEventListener("click", this.onPauseClick)
    this.tlLiveBtn?.removeEventListener("click", this.onLiveClick)
    for (const btn of this.tlWindowBtns || []) btn.removeEventListener("click", this.onWindowClick)
    this.tlCanvas?.removeEventListener("wheel", this.onWheel)
    this.tlCanvas?.removeEventListener("pointerdown", this.onPointerDown)
    this.tlCanvas?.removeEventListener("pointerup", this.onPointerUp)
    this.tlCanvas?.removeEventListener("pointercancel", this.onPointerUp)
    this.tlCanvas?.removeEventListener("pointermove", this.onPointerMove)
    this.tlCanvas?.removeEventListener("pointerleave", this.onPointerLeave)
    this.themeObserver?.disconnect()
    this.scheme?.removeEventListener("change", this.applyTheme)
    this.orb?.dispose()
    this.timeline?.dispose()
    this.room?.leave()
    this.socket.disconnect()
  },
}
