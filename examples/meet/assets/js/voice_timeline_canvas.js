// HiDPI Canvas 2D renderer for Meet's multi-party Voice Timeline.
//
// Renders a clean multi-lane Speech Tape (Option A):
// - Top relative lookback ruler (-10s, -5s, LIVE) with faint vertical gridlines
// - Crisp dual-layer DAW waveforms (peak needles + vivid vocal core) per speaker
// - Hatched amber floor-wait bands and subtle thinking indicators on assistant lanes
// - Single reply latency pill pinned before each assistant response, inline backchannel
//   chips, and coral barge-in overlap washes
// - Hoverable assistant turns for Option B's on-demand waterfall popover

import {DEFAULT_WINDOW_MS, SampleRing} from "./voice_timeline_store.js"

const RULER_HEIGHT = 20
const BOTTOM_PAD = 6
const PLAYHEAD_INSET = 6
const SLOW_REPLY_MS = 1000

const AUDIBLE_FLOOR = 0.04
const USER_SPEECH_ON = 0.14
const AGENT_SPEECH_ON = 0.08
const USER_ONSET_MS = 140
const USER_SILENCE_MS = 450
const AGENT_SILENCE_MS = 350
const REDUCED_MOTION_MS = 450
const STEM_PITCH_PX = 2.5
const STEM_WIDTH_PX = 1.5

/**
 * Computes clean uniform track geometry with assistants grouped above people.
 */
export function computeTrackLayout(lanes) {
  const count = lanes.length
  const trackHeight = count <= 2 ? 32 : count <= 4 ? 26 : 22
  const trackGap = count <= 2 ? 7 : count <= 4 ? 6 : 5
  const groupGap = 14

  const tracks = []
  let y = RULER_HEIGHT + 2
  let dividerY = null
  let prevRole = null

  for (let i = 0; i < lanes.length; i++) {
    const lane = lanes[i]
    if (i > 0) {
      if (prevRole === "agent" && lane.role === "user") {
        dividerY = Math.round(y + groupGap / 2)
        y += groupGap
      } else {
        y += trackGap
      }
    }
    tracks.push({...lane, top: y, height: trackHeight})
    y += trackHeight
    prevRole = lane.role
  }

  const tracksBottom = tracks.length > 0 ? y : RULER_HEIGHT + trackHeight
  const totalHeight = tracksBottom + BOTTOM_PAD
  return {
    tracks,
    rulerHeight: RULER_HEIGHT,
    dividerY,
    tracksTop: RULER_HEIGHT + 2,
    tracksBottom,
    totalHeight,
  }
}

let sharedAudioCtx = null

function getAudioContext() {
  if (typeof window === "undefined") return null
  const Ctx = window.AudioContext || window.webkitAudioContext
  if (!Ctx) return null
  if (!sharedAudioCtx || sharedAudioCtx.state === "closed") {
    sharedAudioCtx = new Ctx()
  }
  return sharedAudioCtx
}

export function resumeTimelineAudio() {
  const ctx = getAudioContext()
  if (ctx && ctx.state === "suspended") {
    ctx.resume().catch(() => {})
  }
}

/** Measures instantaneous RMS level (0..1) from a MediaStreamTrack. */
class TrackMeter {
  constructor(track) {
    this.track = track
    this.analyser = null
    this.source = null
    this.samples = null

    const ctx = getAudioContext()
    if (!ctx) return
    try {
      const stream = new MediaStream([track])
      const source = ctx.createMediaStreamSource(stream)
      const analyser = ctx.createAnalyser()
      analyser.fftSize = 256
      analyser.smoothingTimeConstant = 0
      source.connect(analyser)
      this.source = source
      this.analyser = analyser
      this.samples = new Float32Array(analyser.fftSize)
      if (ctx.state === "suspended") ctx.resume().catch(() => {})
    } catch {
      this.analyser = null
    }
  }

  read() {
    if (!this.analyser || !this.samples || this.track.readyState !== "live" || !this.track.enabled) {
      return 0
    }
    this.analyser.getFloatTimeDomainData(this.samples)
    let sum = 0
    for (let i = 0; i < this.samples.length; i++) sum += this.samples[i] * this.samples[i]
    const rms = Math.sqrt(sum / this.samples.length)
    const db = 20 * Math.log10(rms + 1e-8)
    const linear = Math.min(1, Math.max(0, (db + 52) / 42))
    return linear > 0 ? Math.pow(linear, 1.2) : 0
  }

  dispose() {
    try { this.source?.disconnect() } catch {}
    try { this.analyser?.disconnect() } catch {}
    this.source = null
    this.analyser = null
    this.samples = null
  }
}

function roundedRect(ctx, x, y, w, h, r) {
  const safeW = Math.max(0, w)
  const safeH = Math.max(0, h)
  const radius = Math.max(0, Math.min(r, safeW / 2, safeH / 2))
  ctx.beginPath()
  ctx.roundRect(x, y, safeW, safeH, radius)
}

function createHatchPattern(color) {
  if (typeof document === "undefined") return color
  const tile = document.createElement("canvas")
  tile.width = 8
  tile.height = 8
  const tctx = tile.getContext("2d")
  if (!tctx) return color
  tctx.strokeStyle = color
  tctx.lineWidth = 1.4
  tctx.globalAlpha = 0.5
  tctx.beginPath()
  tctx.moveTo(-2, 8)
  tctx.lineTo(8, -2)
  tctx.moveTo(4, 10)
  tctx.lineTo(10, 4)
  tctx.stroke()
  return tile
}

function formatLatency(ms) {
  return ms < 1000 ? `${Math.round(ms)}ms` : `${(ms / 1000).toFixed(1)}s`
}

/**
 * Creates the HiDPI Canvas 2D renderer for the multi-party Voice Timeline.
 */
export function createVoiceTimelineCanvas(canvas, callbacks = {}) {
  const ctx = canvas.getContext("2d")
  if (!ctx) throw new Error("Canvas 2D is unavailable")

  let lanes = []
  let layout = computeTrackLayout([])
  let timelineState = {phases: [], stages: [], turns: [], overlaps: [], speaking: {}, agentStates: {}}
  let windowMs = DEFAULT_WINDOW_MS
  let hoveredTurnId = null
  let turnHitBoxes = []
  let palette = {
    laneColors: {},
    defaultAgent: "#6366f1",
    defaultUser: "#10b981",
    divider: "rgba(128,128,128,0.16)",
    grid: "rgba(128,128,128,0.08)",
    mutedText: "rgba(128,128,128,0.55)",
    chipBg: "#111827",
    chipText: "#f9fafb",
    wait: "#f59e0b",
    cut: "#ef4444",
    backchannel: "#94a3b8",
  }

  let waitPattern = null

  const meters = new Map()
  const rings = new Map()
  const vad = new Map()

  let running = false
  let paused = false
  let frozenAt = performance.now()
  let frame = 0
  let lastDraw = -Infinity
  let width = 0

  const reducedMotion =
    typeof matchMedia === "function" ? matchMedia("(prefers-reduced-motion: reduce)") : null

  function resizeCanvas() {
    const dpr = window.devicePixelRatio || 1
    canvas.style.height = `${layout.totalHeight}px`
    canvas.width = Math.round(width * dpr)
    canvas.height = Math.round(layout.totalHeight * dpr)
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
  }

  const resize = new ResizeObserver(([entry]) => {
    if (!entry) return
    width = entry.contentRect.width
    resizeCanvas()
    redraw()
  })
  resize.observe(canvas)

  function ensureRing(id) {
    let ring = rings.get(id)
    if (!ring) {
      ring = new SampleRing()
      rings.set(id, ring)
    }
    return ring
  }

  function ensureVad(id) {
    let entry = vad.get(id)
    if (!entry) {
      entry = {speaking: false, onsetSince: null, lastAudibleAt: 0}
      vad.set(id, entry)
    }
    return entry
  }

  function updateVad(lane, level, now) {
    const entry = ensureVad(lane.id)
    const isAgent = lane.role === "agent"
    const onThreshold = isAgent ? AGENT_SPEECH_ON : USER_SPEECH_ON
    const onsetMs = isAgent ? 0 : USER_ONSET_MS
    const silenceMs = isAgent ? AGENT_SILENCE_MS : USER_SILENCE_MS

    if (level >= onThreshold) {
      entry.lastAudibleAt = now
      if (!entry.speaking) {
        if (entry.onsetSince === null) entry.onsetSince = now
        if (now - entry.onsetSince >= onsetMs) {
          entry.speaking = true
          callbacks.onLevelSpeaking?.(lane.id, true)
          callbacks.onSpeechEvent?.({
            type: "speech-start",
            laneId: lane.id,
            role: lane.role,
            at: entry.onsetSince,
            now,
          })
        }
      }
    } else if (level > AUDIBLE_FLOOR && entry.speaking) {
      entry.lastAudibleAt = now
    } else {
      if (!entry.speaking) entry.onsetSince = null
      if (entry.speaking && now - entry.lastAudibleAt >= silenceMs) {
        entry.speaking = false
        entry.onsetSince = null
        callbacks.onLevelSpeaking?.(lane.id, false)
        callbacks.onSpeechEvent?.({
          type: "speech-end",
          laneId: lane.id,
          role: lane.role,
          at: entry.lastAudibleAt,
          now,
        })
      }
    }
  }

  function redraw() {
    if (!running || paused) draw(frozenAt)
  }

  function tick(now) {
    for (const lane of lanes) {
      const meter = meters.get(lane.id)
      const level = meter ? meter.read() : 0
      ensureRing(lane.id).push(now, level)
      updateVad(lane, level, now)
    }

    if (!paused && (!reducedMotion?.matches || now - lastDraw >= REDUCED_MOTION_MS)) {
      draw(now)
      lastDraw = now
    }
    frame = requestAnimationFrame(tick)
  }

  function playheadX() {
    return Math.max(0, width - PLAYHEAD_INSET)
  }

  function xAt(time, now) {
    const right = playheadX()
    return right - ((now - time) / windowMs) * right
  }

  function laneColor(track) {
    return (
      palette.laneColors[track.id] ||
      (track.role === "agent" ? palette.defaultAgent : palette.defaultUser)
    )
  }

  function drawRuler() {
    const right = playheadX()
    const stepSec = windowMs <= 10_000 ? 2 : 5
    const totalSec = Math.floor(windowMs / 1000)

    ctx.font = "500 10px ui-monospace, SFMono-Regular, Menlo, monospace"
    ctx.textBaseline = "middle"

    for (let sec = stepSec; sec < totalSec; sec += stepSec) {
      const x = Math.round(right - ((sec * 1000) / windowMs) * right) + 0.5
      if (x < 24) continue

      ctx.strokeStyle = palette.grid
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(x, layout.tracksTop)
      ctx.lineTo(x, layout.tracksBottom)
      ctx.stroke()

      ctx.fillStyle = palette.mutedText
      ctx.textAlign = "center"
      ctx.fillText(`-${sec}s`, x, RULER_HEIGHT / 2)
    }

    ctx.fillStyle = paused ? palette.wait : palette.mutedText
    ctx.textAlign = "right"
    ctx.fillText(paused ? "PAUSED" : "LIVE", right - 2, RULER_HEIGHT / 2)
    ctx.textAlign = "left"
  }

  function drawBaselines() {
    const right = playheadX()
    for (const track of layout.tracks) {
      const midY = Math.round(track.top + track.height / 2) + 0.5
      ctx.strokeStyle = palette.grid
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(0, midY)
      ctx.lineTo(right, midY)
      ctx.stroke()
    }

    if (layout.dividerY !== null) {
      ctx.strokeStyle = palette.divider
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(0, layout.dividerY + 0.5)
      ctx.lineTo(right, layout.dividerY + 0.5)
      ctx.stroke()
    }
  }

  function drawPhases(now, fromTime) {
    const right = playheadX()
    const trackById = new Map(layout.tracks.map((t) => [t.id, t]))

    for (const phase of timelineState.phases) {
      const track = trackById.get(phase.laneId)
      if (!track) continue
      const end = phase.end ?? now
      if (end < fromTime || phase.start > now) continue

      const x1 = Math.max(0, xAt(phase.start, now))
      const x2 = Math.min(right, xAt(end, now))
      const w = x2 - x1
      if (w < 2) continue

      const bandH = track.height - 6
      const bandY = track.top + 3

      ctx.save()
      roundedRect(ctx, x1, bandY, w, bandH, 4)
      ctx.clip()

      if (phase.kind === "waiting") {
        ctx.fillStyle = palette.wait
        ctx.globalAlpha = 0.12
        ctx.fillRect(x1, bandY, w, bandH)
        if (waitPattern) {
          ctx.globalAlpha = 1
          ctx.fillStyle = waitPattern
          ctx.fillRect(x1, bandY, w, bandH)
        }
        ctx.globalAlpha = 0.55
        ctx.strokeStyle = palette.wait
        ctx.lineWidth = 1
        roundedRect(ctx, x1 + 0.5, bandY + 0.5, w - 1, bandH - 1, 4)
        ctx.stroke()
      } else {
        const color = laneColor(track)
        ctx.fillStyle = color
        ctx.globalAlpha = 0.11
        ctx.fillRect(x1, bandY, w, bandH)
        ctx.globalAlpha = 0.35
        ctx.strokeStyle = color
        ctx.setLineDash([3, 3])
        ctx.lineWidth = 1
        roundedRect(ctx, x1 + 0.5, bandY + 0.5, w - 1, bandH - 1, 4)
        ctx.stroke()
        ctx.setLineDash([])
      }

      if (w > 48) {
        ctx.globalAlpha = 0.8
        ctx.fillStyle = phase.kind === "waiting" ? palette.wait : laneColor(track)
        ctx.font = "500 9px ui-monospace, SFMono-Regular, Menlo, monospace"
        ctx.textBaseline = "middle"
        ctx.fillText(
          phase.kind === "waiting" ? "floor wait" : "thinking",
          x1 + 6,
          track.top + track.height / 2,
        )
      }
      ctx.restore()
    }
  }

  function drawOverlapWashes(now, fromTime) {
    const right = playheadX()
    const trackById = new Map(layout.tracks.map((t) => [t.id, t]))

    for (const overlap of timelineState.overlaps) {
      if (!overlap.cut) continue
      const end = overlap.end ?? now
      if (end < fromTime || overlap.start > now) continue

      const aTrack = trackById.get(overlap.agentId)
      const uTrack = trackById.get(overlap.userLaneId)
      if (!aTrack && !uTrack) continue

      const top = Math.min(aTrack?.top ?? Infinity, uTrack?.top ?? Infinity)
      const bottom = Math.max(
        aTrack ? aTrack.top + aTrack.height : -Infinity,
        uTrack ? uTrack.top + uTrack.height : -Infinity,
      )
      const x1 = Math.max(0, xAt(overlap.start, now))
      const x2 = Math.min(right, Math.max(x1 + 3, xAt(end, now)))

      ctx.save()
      ctx.fillStyle = palette.cut
      ctx.globalAlpha = 0.13
      roundedRect(ctx, x1, top, x2 - x1, bottom - top, 4)
      ctx.fill()

      ctx.globalAlpha = 0.7
      ctx.strokeStyle = palette.cut
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(Math.round(x1) + 0.5, top)
      ctx.lineTo(Math.round(x1) + 0.5, bottom)
      ctx.stroke()
      ctx.restore()
    }
  }

  /** Highlights the hovered assistant reply turn so the popover target is unmistakable. */
  function drawHoveredTurnHalo(now, fromTime) {
    if (hoveredTurnId === null) return
    const turn = timelineState.turns.find((t) => t.id === hoveredTurnId)
    if (!turn) return
    const track = layout.tracks.find((tr) => tr.id === turn.laneId)
    if (!track) return
    const end = turn.end ?? now
    if (end < fromTime || turn.start > now) return

    const right = playheadX()
    const x1 = Math.max(0, xAt(turn.start, now) - 2)
    const x2 = Math.min(right, Math.max(x1 + 12, xAt(end, now) + 2))
    const color = laneColor(track)

    ctx.save()
    roundedRect(ctx, x1, track.top + 1, x2 - x1, track.height - 2, 5)
    ctx.fillStyle = color
    ctx.globalAlpha = 0.12
    ctx.fill()
    ctx.strokeStyle = color
    ctx.globalAlpha = 0.55
    ctx.lineWidth = 1
    ctx.stroke()
    ctx.restore()
  }

  /**
   * Draws a crisp studio-DAW dual-layer waveform (fine peak needles + dense
   * inner vocal core) bucketed on a fixed time grid so stems never shimmer.
   */
  function drawWaveform(track, now, fromTime) {
    const ring = rings.get(track.id)
    if (!ring || ring.count === 0) return

    const right = playheadX()
    if (right <= 0) return
    const midY = track.top + track.height / 2
    const maxAmp = track.height / 2 - 2
    const baseColor = laneColor(track)

    const specialRanges = []
    for (const o of timelineState.overlaps) {
      if (!o.cut) continue
      if (o.agentId === track.id || o.userLaneId === track.id) {
        specialRanges.push({start: o.start, end: o.end ?? now, color: palette.cut})
      }
    }
    for (const t of timelineState.turns) {
      if (t.laneId === track.id && t.backchannel) {
        specialRanges.push({start: t.start, end: t.end ?? now, color: palette.backchannel})
      }
    }

    const colorAt = (time) => {
      for (let i = 0; i < specialRanges.length; i++) {
        const r = specialRanges[i]
        if (time >= r.start && time <= r.end) return r.color
      }
      return baseColor
    }

    const bucketMs = (STEM_PITCH_PX / right) * windowMs
    const peaks = new Map()
    const sums = new Map()
    const counts = new Map()

    ring.forEachInRange(fromTime, now, (t, level) => {
      if (level <= AUDIBLE_FLOOR) return
      const b = Math.floor(t / bucketMs)
      const prevPeak = peaks.get(b) || 0
      if (level > prevPeak) peaks.set(b, level)
      sums.set(b, (sums.get(b) || 0) + level)
      counts.set(b, (counts.get(b) || 0) + 1)
    })

    if (peaks.size === 0) return

    ctx.save()
    ctx.lineCap = "round"
    ctx.lineWidth = STEM_WIDTH_PX

    for (const [b, peak] of peaks) {
      const centerTime = (b + 0.5) * bucketMs
      const x = xAt(centerTime, now)
      if (x < 0 || x > right) continue

      const avg = (sums.get(b) || peak) / (counts.get(b) || 1)
      const color = colorAt(centerTime)
      const outerHalf = Math.max(1.5, peak * maxAmp)
      const coreHalf = Math.max(1, avg * maxAmp * 0.62)

      ctx.strokeStyle = color
      ctx.globalAlpha = 0.40
      ctx.beginPath()
      ctx.moveTo(x, midY - outerHalf)
      ctx.lineTo(x, midY + outerHalf)
      ctx.stroke()

      ctx.globalAlpha = 0.98
      ctx.beginPath()
      ctx.moveTo(x, midY - coreHalf)
      ctx.lineTo(x, midY + coreHalf)
      ctx.stroke()
    }

    ctx.restore()
  }

  function drawChip(x, centerY, text, bgColor, textColor, align = "left", borderColor = null) {
    ctx.save()
    ctx.font = "600 9.5px ui-monospace, SFMono-Regular, Menlo, monospace"
    const metrics = ctx.measureText(text)
    const padX = 5
    const chipW = Math.ceil(metrics.width + padX * 2)
    const chipH = 15
    const left =
      align === "center"
        ? Math.round(x - chipW / 2)
        : align === "right"
          ? Math.round(x - chipW)
          : Math.round(x)
    const top = Math.round(centerY - chipH / 2)

    roundedRect(ctx, left, top, chipW, chipH, 7.5)
    ctx.fillStyle = bgColor
    ctx.fill()
    if (borderColor) {
      ctx.strokeStyle = borderColor
      ctx.lineWidth = 1
      ctx.stroke()
    }

    ctx.fillStyle = textColor
    ctx.textBaseline = "middle"
    ctx.textAlign = "left"
    ctx.fillText(text, left + padX, top + chipH / 2 + 0.5)
    ctx.restore()
    return {left, width: chipW}
  }

  function drawInlineBadgesAndHitBoxes(now, fromTime) {
    turnHitBoxes = []
    const right = playheadX()
    const trackById = new Map(layout.tracks.map((t) => [t.id, t]))

    for (const turn of timelineState.turns) {
      const track = trackById.get(turn.laneId)
      if (!track) continue

      const end = turn.end ?? now
      if (end < fromTime || turn.start > now) continue

      if (turn.role === "agent") {
        const startX = xAt(turn.start, now)
        const endX = xAt(end, now)
        let hitLeft = Math.max(0, startX - 2)
        const hitRight = Math.min(right, Math.max(hitLeft + 18, endX + 2))

        if (turn.latencyMs !== null && startX > 8 && startX < right - 12) {
          const slow = turn.latencyMs >= SLOW_REPLY_MS
          const label = formatLatency(turn.latencyMs)
          const hovered = hoveredTurnId === turn.id
          const placeBefore = startX > 46
          const pill = drawChip(
            placeBefore ? startX - 4 : startX + 2,
            track.top + track.height / 2,
            label,
            slow ? palette.cut : hovered ? laneColor(track) : palette.chipBg,
            palette.chipText,
            placeBefore ? "right" : "left",
            hovered && !slow ? laneColor(track) : null,
          )
          hitLeft = Math.min(hitLeft, Math.max(0, pill.left))
        }

        if (hitRight > hitLeft) {
          turnHitBoxes.push({
            x: hitLeft,
            y: track.top,
            w: hitRight - hitLeft,
            h: track.height,
            centerX: (hitLeft + hitRight) / 2,
            turn,
            track,
          })
        }
      }

      if (turn.backchannel && turn.label) {
        const midTime = (turn.start + end) / 2
        const x = xAt(midTime, now)
        if (x > 20 && x < right - 20) {
          drawChip(
            x,
            track.top + track.height / 2,
            turn.label,
            palette.chipBg,
            palette.chipText,
            "center",
          )
        }
      }
    }

    for (const overlap of timelineState.overlaps) {
      if (!overlap.cut) continue
      const x = xAt(overlap.start, now)
      if (x < 16 || x > right - 24) continue
      const y = layout.dividerY ?? layout.tracksTop + 8
      drawChip(x, y, "cut", palette.cut, palette.chipText, "center")
    }
  }

  function drawPlayhead() {
    const x = playheadX()
    ctx.save()
    ctx.strokeStyle = paused ? palette.wait : palette.divider
    ctx.lineWidth = 1.5
    ctx.beginPath()
    ctx.moveTo(x + 0.5, layout.tracksTop)
    ctx.lineTo(x + 0.5, layout.tracksBottom)
    ctx.stroke()

    for (const track of layout.tracks) {
      const level = rings.get(track.id)?.latest() || 0
      if (level <= AUDIBLE_FLOOR) continue
      const midY = track.top + track.height / 2
      const color = laneColor(track)

      ctx.beginPath()
      ctx.arc(x + 0.5, midY, 2.5 + level * 2.5, 0, Math.PI * 2)
      ctx.fillStyle = color
      ctx.globalAlpha = 0.28
      ctx.fill()

      ctx.beginPath()
      ctx.arc(x + 0.5, midY, 2.4, 0, Math.PI * 2)
      ctx.fillStyle = color
      ctx.globalAlpha = 1
      ctx.fill()
    }
    ctx.restore()
  }

  function draw(now) {
    ctx.clearRect(0, 0, width, layout.totalHeight)
    if (width <= 0 || layout.tracks.length === 0) return

    const fromTime = now - windowMs
    drawRuler()
    drawBaselines()
    drawPhases(now, fromTime)
    drawOverlapWashes(now, fromTime)
    drawHoveredTurnHalo(now, fromTime)
    for (const track of layout.tracks) {
      drawWaveform(track, now, fromTime)
    }
    drawInlineBadgesAndHitBoxes(now, fromTime)
    drawPlayhead()
  }

  return {
    setLanes(nextLanes) {
      lanes = nextLanes
      const prevHeight = layout.totalHeight
      layout = computeTrackLayout(lanes)
      if (layout.totalHeight !== prevHeight) resizeCanvas()
      redraw()
      return layout
    },
    setTracks(trackMap) {
      for (const [id, meter] of meters) {
        const nextTrack = trackMap.get(id) || null
        if (meter.track !== nextTrack) {
          meter.dispose()
          meters.delete(id)
        }
      }
      for (const [id, track] of trackMap) {
        if (!track) continue
        if (!meters.has(id)) {
          meters.set(id, new TrackMeter(track))
        }
      }
    },
    hasTrack(laneId) {
      return meters.has(laneId)
    },
    setTimelineState(nextState) {
      timelineState = nextState
      redraw()
    },
    setWindowMs(nextMs) {
      windowMs = nextMs
      redraw()
    },
    hitTestTurn(x, y) {
      for (let i = turnHitBoxes.length - 1; i >= 0; i--) {
        const box = turnHitBoxes[i]
        if (x >= box.x && x <= box.x + box.w && y >= box.y && y <= box.y + box.h) {
          return box
        }
      }
      return null
    },
    setHoveredTurn(turnId) {
      if (hoveredTurnId === turnId) return
      hoveredTurnId = turnId
      redraw()
    },
    setPalette(nextPalette) {
      palette = nextPalette
      const tile = createHatchPattern(palette.wait)
      waitPattern = typeof tile === "string" ? tile : ctx.createPattern(tile, "repeat")
      redraw()
    },
    setRunning(next) {
      if (next === running) return
      running = next
      if (running) {
        lastDraw = -Infinity
        frame = requestAnimationFrame(tick)
      } else {
        cancelAnimationFrame(frame)
        frozenAt = performance.now()
        draw(frozenAt)
      }
    },
    setPaused(next) {
      if (next === paused) return
      paused = next
      if (paused) {
        frozenAt = performance.now()
        draw(frozenAt)
      } else {
        lastDraw = -Infinity
      }
    },
    reset() {
      for (const ring of rings.values()) ring.clear()
      vad.clear()
      frozenAt = performance.now()
      redraw()
    },
    dispose() {
      cancelAnimationFrame(frame)
      resize.disconnect()
      for (const meter of meters.values()) meter.dispose()
      meters.clear()
    },
  }
}
