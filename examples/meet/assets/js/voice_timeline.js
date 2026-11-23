// Phoenix LiveView hook for Meet's multi-party Voice Timeline.
//
// Option A's clean multi-lane Speech Tape with Option B's on-demand waterfall
// popover when hovering any assistant reply turn or latency pill.

import {audioTracks, isCallLive} from "./call.js"
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

const AGENT_COLORS = {
  assistant: {light: "#4f46e5", dark: "#818cf8"},
  atlas: {light: "#0284c7", dark: "#38bdf8"},
  openai: {light: "#9333ea", dark: "#c084fc"},
  gemini: {light: "#2563eb", dark: "#60a5fa"},
}
const AGENT_FALLBACK = [
  {light: "#4f46e5", dark: "#818cf8"},
  {light: "#0284c7", dark: "#38bdf8"},
  {light: "#9333ea", dark: "#c084fc"},
  {light: "#2563eb", dark: "#60a5fa"},
]
const USER_COLORS = [
  {light: "#059669", dark: "#34d399"},
  {light: "#d97706", dark: "#fbbf24"},
  {light: "#db2777", dark: "#f472b6"},
  {light: "#0d9488", dark: "#2dd4bf"},
]

// Stage colors shared with MeetWeb.OctoroomDashboardPage for the hover waterfall.
const STAGE_COLORS = {
  stt: "#64748b",
  decisions: "#f59e0b",
  floor_wait: "#d97706",
  llm: "#4f46e5",
  tool: "#9333ea",
  tools: "#9333ea",
  tts: "#10b981",
  live: "#0284c7",
  transcriber: "#0ea5e9",
}

function isDarkTheme() {
  const attr = document.documentElement.getAttribute("data-theme")
  if (attr === "dark") return true
  if (attr === "light") return false
  return matchMedia("(prefers-color-scheme: dark)").matches
}

function laneHex(lane, userIdx, agentIdx, dark) {
  const pair =
    lane.role === "agent"
      ? AGENT_COLORS[lane.id] || AGENT_FALLBACK[agentIdx % AGENT_FALLBACK.length]
      : USER_COLORS[userIdx % USER_COLORS.length]
  return dark ? pair.dark : pair.light
}

function stageColor(stage) {
  if (stage.status === "error") return "#ef4444"
  if (stage.status === "interrupted" || stage.status === "cancelled") return "#fb923c"
  return STAGE_COLORS[stage.kind] || "#64748b"
}

function formatMs(ms) {
  return ms < 1000 ? `${Math.round(ms)}ms` : `${(ms / 1000).toFixed(1)}s`
}

function formatStageMetric(stage) {
  const dur = `${Math.round(stage.durationMs)}ms`
  if (stage.kind === "llm" && typeof stage.firstOutputMs === "number") {
    return `${Math.round(stage.firstOutputMs)}ms TTFT`
  }
  if (stage.kind === "tts" && typeof stage.firstOutputMs === "number") {
    return `${Math.round(stage.firstOutputMs)}ms TTFB`
  }
  return dur
}

export const VoiceTimeline = {
  mounted() {
    this.canvas = this.el.querySelector("[data-timeline-canvas]")
    this.laneListEl = this.el.querySelector("[data-timeline-lane-labels]")
    this.popoverEl = this.el.querySelector("[data-timeline-popover]")
    this.bodyEl = this.el.querySelector("#voice-timeline-body")
    this.pauseBtn = this.el.querySelector("[data-timeline-pause]")
    this.pauseLabel = this.el.querySelector("[data-timeline-pause-label]")
    this.liveBtn = this.el.querySelector("[data-timeline-live]")
    this.windowBtns = [...this.el.querySelectorAll("[data-timeline-window]")]

    this.state = createTimelineState()
    this.lanes = []
    this.laneHexes = {}
    this.audibleLanes = new Set()
    this.paused = false
    this.windowMs = DEFAULT_WINDOW_MS
    this.dragging = false
    this.dragLastX = 0

    this.renderer = createVoiceTimelineCanvas(this.canvas, {
      onSpeechEvent: (event) => this.dispatch(event),
      onLevelSpeaking: (laneId, speaking) => {
        if (speaking) this.audibleLanes.add(laneId)
        else this.audibleLanes.delete(laneId)
        this.syncLaneStatus()
      },
      onScrollChange: (scrolledBack) => {
        this.liveBtn?.classList.toggle("hidden", !scrolledBack)
      },
    })

    this.handleEvent("timeline_event", (payload) => this.onServerEvent(payload))

    this.onMedia = () => this.syncTracks()
    this.onCallState = (e) => this.onCallStateChange(Boolean(e.detail?.running))
    this.onGesture = () => resumeTimelineAudio()
    window.addEventListener("meet:media", this.onMedia)
    window.addEventListener("meet:call-state", this.onCallState)
    window.addEventListener("pointerdown", this.onGesture, {passive: true})

    this.onPauseClick = () => {
      this.paused = !this.paused
      this.renderer.setPaused(this.paused)
      this.updatePauseUi()
    }
    this.pauseBtn?.addEventListener("click", this.onPauseClick)

    this.onLiveClick = () => {
      this.paused = false
      this.renderer.jumpToLive()
      this.updatePauseUi()
    }
    this.liveBtn?.addEventListener("click", this.onLiveClick)

    this.onWindowClick = (event) => {
      const btn = event.currentTarget
      const seconds = Number(btn.dataset.timelineWindow)
      if (!Number.isFinite(seconds) || seconds <= 0) return
      this.windowMs = seconds * 1000
      this.renderer.setWindowMs(this.windowMs)
      this.updateWindowUi()
    }
    for (const btn of this.windowBtns) {
      btn.addEventListener("click", this.onWindowClick)
    }
    this.updateWindowUi()

    // Wheel scroll (trackpad horizontal or mouse vertical) scrubs through history.
    this.onWheel = (event) => {
      const delta = Math.abs(event.deltaX) >= Math.abs(event.deltaY) ? event.deltaX : event.deltaY
      if (delta === 0) return
      event.preventDefault()
      this.hidePopover()
      this.renderer.scrollByPixels(delta)
    }
    this.canvas.addEventListener("wheel", this.onWheel, {passive: false})

    // Click-and-drag pan on the timeline canvas.
    this.onPointerDown = (event) => {
      if (event.button !== 0) return
      this.dragging = true
      this.dragLastX = event.clientX
      this.canvas.setPointerCapture?.(event.pointerId)
      this.canvas.style.cursor = "grabbing"
      this.hidePopover()
    }
    this.onPointerUp = (event) => {
      if (!this.dragging) return
      this.dragging = false
      this.canvas.releasePointerCapture?.(event.pointerId)
      this.canvas.style.cursor = "grab"
    }

    // Option B-style on-demand waterfall popover when hovering an assistant reply.
    this.onPointerMove = (event) => {
      if (this.dragging) {
        const dx = event.clientX - this.dragLastX
        this.dragLastX = event.clientX
        this.renderer.scrollByPixels(-dx)
        return
      }
      const rect = this.canvas.getBoundingClientRect()
      const cx = event.clientX - rect.left
      const cy = event.clientY - rect.top
      const hit = this.renderer.hitTestTurn(cx, cy)
      this.renderer.setHoveredTurn(hit ? hit.turn.id : null)
      this.canvas.style.cursor = hit ? "pointer" : "grab"
      if (!hit) {
        this.hidePopover()
        return
      }
      this.showPopover(hit, event.clientX)
    }
    this.onPointerLeave = () => {
      if (this.dragging) return
      this.renderer.setHoveredTurn(null)
      this.canvas.style.cursor = ""
      this.hidePopover()
    }
    this.canvas.addEventListener("pointerdown", this.onPointerDown)
    this.canvas.addEventListener("pointerup", this.onPointerUp)
    this.canvas.addEventListener("pointercancel", this.onPointerUp)
    this.canvas.addEventListener("pointermove", this.onPointerMove)
    this.canvas.addEventListener("pointerleave", this.onPointerLeave)

    this.applyTheme = () => {
      this.computeLaneColors()
      this.syncPalette()
      this.syncLaneSwatches()
    }
    this.themeObserver = new MutationObserver(this.applyTheme)
    this.themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["class", "style", "data-theme"],
    })
    this.scheme = matchMedia("(prefers-color-scheme: dark)")
    this.scheme.addEventListener("change", this.applyTheme)

    this.syncLanes()
    this.syncPalette()
    this.syncTracks()

    if (isCallLive()) {
      this.renderer.reset()
      this.renderer.setRunning(true)
    }
  },

  updated() {
    this.syncLanes()
    this.syncPalette()
    this.syncTracks()
  },

  dispatch(event) {
    this.state = applyTimelineEvent(this.state, event)
    this.renderer.setTimelineState(this.state)
    this.syncLaneStatus()
  },

  onServerEvent(payload) {
    const now = performance.now()
    switch (payload.type) {
      case "agent_state": {
        const prev = this.state.agentStates[payload.id]
        this.dispatch({type: "agent-state", agentId: payload.id, state: payload.state, now})
        if (!this.renderer.hasTrack(payload.id)) {
          if (payload.state === "speaking" && prev !== "speaking") {
            this.dispatch({type: "speech-start", laneId: payload.id, role: "agent", now})
          } else if (payload.state !== "speaking" && prev === "speaking") {
            this.dispatch({type: "speech-end", laneId: payload.id, role: "agent", now})
          }
        }
        break
      }

      case "interruption":
        this.dispatch({type: "interruption", agentId: payload.agent, now})
        break

      case "reply_latency":
        this.dispatch({type: "reply-latency", agentId: payload.agent, audioMs: payload.audio_ms, now})
        break

      case "user_turn":
        this.dispatch({
          type: "user-transcript",
          laneId: payload.lane_id,
          text: payload.text,
          outcome: payload.outcome,
          now,
        })
        break

      case "stage_spans":
        this.dispatch({type: "stage-spans", spans: payload.spans, now})
        break
    }
  },

  onCallStateChange(running) {
    if (running) {
      this.state = applyTimelineEvent(this.state, {type: "reset", now: performance.now()})
      this.renderer.setTimelineState(this.state)
      this.renderer.reset()
      this.paused = false
      this.renderer.setPaused(false)
      this.updatePauseUi()
      this.hidePopover()
      this.syncTracks()
      this.renderer.setRunning(true)
    } else {
      this.dispatch({type: "disconnected", now: performance.now()})
      this.renderer.setRunning(false)
    }
  },

  showPopover(hit, clientX) {
    if (!this.popoverEl || !this.bodyEl) return
    const {turn, track} = hit
    const stages = stagesForTurn(this.state, turn)
    const isCut = this.state.overlaps.some(
      (o) => o.cut && o.agentId === turn.laneId && o.start >= turn.start - 500 && o.start <= (turn.end ?? performance.now()) + 500,
    )

    this.popoverEl.replaceChildren()

    // Header row: assistant name + reply latency + optional interrupted badge.
    const head = document.createElement("div")
    head.className = "flex items-center justify-between gap-3"

    const title = document.createElement("span")
    title.className = "flex items-center gap-1.5 font-sans text-xs font-semibold"
    const dot = document.createElement("span")
    dot.className = "size-2 rounded-full"
    dot.style.backgroundColor = this.laneHexes[track.id] || "#818cf8"
    const labelText = document.createElement("span")
    labelText.textContent =
      turn.latencyMs !== null ? `${track.label} · ${formatMs(turn.latencyMs)}` : track.label
    title.append(dot, labelText)
    head.append(title)

    if (isCut) {
      const cutTag = document.createElement("span")
      cutTag.className = "rounded-full bg-error/20 px-1.5 py-0.5 text-[10px] font-semibold text-error"
      cutTag.textContent = "interrupted"
      head.append(cutTag)
    } else if (turn.end !== null) {
      const dur = document.createElement("span")
      dur.className = "text-[10px] opacity-60"
      dur.textContent = `${formatMs(turn.end - turn.start)} audio`
      head.append(dur)
    }

    this.popoverEl.append(head)

    // Proportional mini-waterfall bar + stage breakdown from TraceStore.
    if (stages.length > 0) {
      const totalDur = stages.reduce((sum, s) => sum + Math.max(s.durationMs, 1), 0)
      const bar = document.createElement("div")
      bar.className = "mt-2 mb-1.5 flex h-2 w-full gap-px overflow-hidden rounded"

      for (const s of stages) {
        const seg = document.createElement("div")
        seg.className = "relative h-full min-w-[3px]"
        seg.style.width = `${(Math.max(s.durationMs, 1) / totalDur) * 100}%`
        if (s.kind === "floor_wait") {
          seg.style.background =
            "repeating-linear-gradient(-45deg, rgba(245,158,11,0.7), rgba(245,158,11,0.7) 2px, rgba(245,158,11,0.2) 2px, rgba(245,158,11,0.2) 4px)"
        } else {
          seg.style.backgroundColor = stageColor(s)
        }
        if (typeof s.firstOutputMs === "number" && s.durationMs > 0) {
          const pinPct = Math.min(Math.max((s.firstOutputMs / s.durationMs) * 100, 0), 100)
          const tail = document.createElement("span")
          tail.className = "absolute inset-y-0 right-0 bg-white/40"
          tail.style.width = `${100 - pinPct}%`
          const pin = document.createElement("span")
          pin.className = "absolute inset-y-0 w-0.5 bg-black/80"
          pin.style.left = `${pinPct}%`
          seg.append(tail, pin)
        }
        bar.append(seg)
      }
      this.popoverEl.append(bar)

      const kv = document.createElement("div")
      kv.className = "flex flex-wrap gap-x-2.5 gap-y-0.5 text-[10px] opacity-80"
      for (const s of stages) {
        const item = document.createElement("span")
        item.className = "inline-flex items-center gap-1"
        const sw = document.createElement("span")
        sw.className = "size-1.5 rounded-[1px]"
        sw.style.backgroundColor = stageColor(s)
        const txt = document.createElement("span")
        txt.textContent = `${s.label} ${formatStageMetric(s)}`
        item.append(sw, txt)
        kv.append(item)
      }
      this.popoverEl.append(kv)
    } else {
      const hint = document.createElement("div")
      hint.className = "mt-1 text-[10px] opacity-60"
      hint.textContent =
        turn.end === null ? "Speaking now — stage trace updates on turn completion" : "Audio reply"
      this.popoverEl.append(hint)
    }

    this.popoverEl.classList.remove("hidden")
    const bodyRect = this.bodyEl.getBoundingClientRect()
    const popWidth = this.popoverEl.offsetWidth || 280
    const relX = clientX - bodyRect.left
    const clampedX = Math.min(
      Math.max(relX - popWidth / 2, 8),
      Math.max(8, bodyRect.width - popWidth - 8),
    )
    this.popoverEl.style.left = `${Math.round(clampedX)}px`
  },

  hidePopover() {
    this.popoverEl?.classList.add("hidden")
  },

  computeLaneColors() {
    const dark = isDarkTheme()
    let agentIdx = 0
    let userIdx = 0
    this.laneHexes = {}
    for (const lane of this.lanes) {
      this.laneHexes[lane.id] = laneHex(lane, userIdx, agentIdx, dark)
      if (lane.role === "agent") agentIdx++
      else userIdx++
    }
  },

  syncLanes() {
    let parsed = []
    try {
      parsed = JSON.parse(this.el.dataset.lanes || "[]")
    } catch {
      parsed = []
    }
    this.lanes = parsed
    this.computeLaneColors()

    const layout = this.renderer.setLanes(this.lanes)
    this.renderTrackHeaders(layout)
  },

  renderTrackHeaders(layout) {
    if (!this.laneListEl) return
    this.laneListEl.style.height = `${layout.totalHeight}px`
    this.laneListEl.innerHTML = ""

    for (const track of layout.tracks) {
      const row = document.createElement("div")
      row.dataset.lane = track.id
      row.dataset.role = track.role
      row.className =
        "group/lane absolute inset-x-0 flex items-center justify-between gap-1.5 rounded-md px-1.5 text-xs text-base-content/60 transition-colors duration-150 data-[state=speaking]:bg-base-200/80 data-[state=speaking]:text-base-content"
      row.style.top = `${track.top}px`
      row.style.height = `${track.height}px`

      const left = document.createElement("span")
      left.className = "flex min-w-0 items-center gap-1.5"

      const swatch = document.createElement("span")
      swatch.dataset.laneSwatch = ""
      swatch.setAttribute("aria-hidden", "true")
      swatch.className =
        "h-3 w-1 shrink-0 rounded-full opacity-45 transition-opacity duration-150 group-data-[state=speaking]/lane:opacity-100 group-data-[state=thinking]/lane:animate-pulse group-data-[state=thinking]/lane:opacity-85 group-data-[state=waiting]/lane:opacity-80"
      swatch.style.backgroundColor = this.laneHexes[track.id] || "#6366f1"

      const name = document.createElement("span")
      name.className = "truncate font-medium"
      name.textContent = track.label
      name.title = track.label

      left.append(swatch, name)

      const tag = document.createElement("span")
      tag.dataset.laneTag = ""
      tag.className = "hidden shrink-0 font-mono text-[9px] uppercase tracking-wide opacity-75"

      row.append(left, tag)
      this.laneListEl.append(row)
    }

    this.syncLaneStatus()
  },

  syncLaneSwatches() {
    if (!this.laneListEl) return
    for (const lane of this.lanes) {
      const swatch = this.laneListEl.querySelector(
        `[data-lane="${CSS.escape(lane.id)}"] [data-lane-swatch]`,
      )
      if (swatch) swatch.style.backgroundColor = this.laneHexes[lane.id] || "#6366f1"
    }
  },

  syncLaneStatus() {
    if (!this.laneListEl) return
    for (const lane of this.lanes) {
      const row = this.laneListEl.querySelector(`[data-lane="${CSS.escape(lane.id)}"]`)
      if (!row) continue
      const tag = row.querySelector("[data-lane-tag]")
      const isSpeaking =
        this.audibleLanes.has(lane.id) ||
        Boolean(this.state.speaking[lane.id]) ||
        lane.state === "speaking"

      let state = "silent"
      let badge = ""
      if (isSpeaking) {
        state = "speaking"
      } else if (lane.state === "thinking") {
        state = "thinking"
        badge = "think"
      } else if (lane.state === "waiting") {
        state = "waiting"
        badge = "wait"
      } else if (lane.muted) {
        state = "muted"
        badge = "muted"
      }

      row.dataset.state = state
      if (tag) {
        tag.textContent = badge
        tag.classList.toggle("hidden", badge === "")
      }
    }
  },

  syncTracks() {
    this.renderer.setTracks(audioTracks())
  },

  syncPalette() {
    const dark = isDarkTheme()
    this.renderer.setPalette({
      laneColors: {...this.laneHexes},
      defaultAgent: dark ? "#818cf8" : "#4f46e5",
      defaultUser: dark ? "#34d399" : "#059669",
      divider: dark ? "rgba(255,255,255,0.12)" : "rgba(15,23,42,0.10)",
      grid: dark ? "rgba(255,255,255,0.06)" : "rgba(15,23,42,0.05)",
      mutedText: dark ? "rgba(255,255,255,0.45)" : "rgba(15,23,42,0.45)",
      chipBg: dark ? "#1f2937" : "#111827",
      chipText: "#f9fafb",
      wait: "#f59e0b",
      cut: "#ef4444",
      backchannel: dark ? "#94a3b8" : "#64748b",
    })
  },

  updatePauseUi() {
    if (!this.pauseBtn) return
    this.pauseBtn.dataset.paused = String(this.paused)
    this.pauseBtn.title = this.paused ? "Resume live timeline" : "Pause timeline"
    if (this.pauseLabel) {
      this.pauseLabel.textContent = this.paused ? "Resume" : "Pause"
    }
  },

  updateWindowUi() {
    const activeSec = Math.round(this.windowMs / 1000)
    for (const btn of this.windowBtns) {
      const isActive = Number(btn.dataset.timelineWindow) === activeSec
      btn.classList.toggle("btn-active", isActive)
      btn.setAttribute("aria-pressed", String(isActive))
    }
  },

  destroyed() {
    window.removeEventListener("meet:media", this.onMedia)
    window.removeEventListener("meet:call-state", this.onCallState)
    window.removeEventListener("pointerdown", this.onGesture)
    this.pauseBtn?.removeEventListener("click", this.onPauseClick)
    this.liveBtn?.removeEventListener("click", this.onLiveClick)
    for (const btn of this.windowBtns) {
      btn.removeEventListener("click", this.onWindowClick)
    }
    this.canvas?.removeEventListener("wheel", this.onWheel)
    this.canvas?.removeEventListener("pointerdown", this.onPointerDown)
    this.canvas?.removeEventListener("pointerup", this.onPointerUp)
    this.canvas?.removeEventListener("pointercancel", this.onPointerUp)
    this.canvas?.removeEventListener("pointermove", this.onPointerMove)
    this.canvas?.removeEventListener("pointerleave", this.onPointerLeave)
    this.themeObserver?.disconnect()
    this.scheme?.removeEventListener("change", this.applyTheme)
    this.renderer?.dispose()
  },
}
