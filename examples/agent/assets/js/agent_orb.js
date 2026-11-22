// Headless Canvas 2D radial audio-reactive Agent Presence Orb.
//
// Zero framework coupling: feed it presence state (`idle`, `joining`,
// `listening`, `thinking`, `waiting`, `speaking`) and normalized 0..1 audio
// levels for agent and user, and it animates a smooth HiDPI frequency ring.

const DEFAULT_PALETTE = {
  agent: "#818cf8",
  agentAccent: "#38bdf8",
  user: "#34d399",
  thinking: "#f59e0b",
  idle: "#64748b",
}

export function createAgentOrb(canvas, options = {}) {
  const ctx = canvas.getContext("2d")
  if (!ctx) throw new Error("Canvas 2D is unavailable")

  let size = 176
  let state = "idle"
  let glyph = options.glyph || "A"
  let targetAgent = 0
  let targetUser = 0
  let smoothAgent = 0
  let smoothUser = 0
  let palette = {...DEFAULT_PALETTE}
  let frame = 0
  let running = true

  const reducedMotion =
    typeof matchMedia === "function" ? matchMedia("(prefers-reduced-motion: reduce)") : null

  function resize() {
    const rect = canvas.getBoundingClientRect()
    const next = Math.round(Math.min(rect.width || 176, rect.height || 176))
    size = next > 0 ? next : 176
    const dpr = window.devicePixelRatio || 1
    canvas.width = Math.round(size * dpr)
    canvas.height = Math.round(size * dpr)
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
  }

  const ro = new ResizeObserver(() => resize())
  ro.observe(canvas)
  resize()

  function draw(now) {
    const t = now / 1000
    smoothAgent += (targetAgent - smoothAgent) * (targetAgent > smoothAgent ? 0.35 : 0.14)
    smoothUser += (targetUser - smoothUser) * (targetUser > smoothUser ? 0.35 : 0.14)

    ctx.clearRect(0, 0, size, size)
    const cx = size / 2
    const cy = size / 2
    const scale = size / 176

    const isSpeaking = state === "speaking" || smoothAgent > 0.06
    const isThinking = state === "thinking" || state === "waiting" || state === "joining"
    const isIdle = state === "idle"
    const userTalking = !isSpeaking && smoothUser > 0.08

    const ringColor = isThinking
      ? palette.thinking
      : isSpeaking
        ? palette.agent
        : userTalking
          ? palette.user
          : isIdle
            ? palette.idle
            : palette.agent

    // Ambient halo
    const breath = reducedMotion?.matches ? 0 : Math.sin(t * (isThinking ? 4.2 : 1.9)) * 4
    const haloR = (54 + smoothAgent * 24 + smoothUser * 8 + breath) * scale
    const halo = ctx.createRadialGradient(cx, cy, 16 * scale, cx, cy, haloR + 16 * scale)
    halo.addColorStop(0, ringColor)
    halo.addColorStop(1, "transparent")

    ctx.save()
    ctx.globalAlpha = isSpeaking ? 0.34 : isThinking ? 0.25 : userTalking ? 0.22 : isIdle ? 0.09 : 0.15
    ctx.fillStyle = halo
    ctx.beginPath()
    ctx.arc(cx, cy, haloR + 16 * scale, 0, Math.PI * 2)
    ctx.fill()
    ctx.restore()

    // Radial frequency ticks around the core
    const barCount = 40
    const baseR = 45 * scale
    const rot = reducedMotion?.matches ? 0 : isThinking ? t * 1.45 : isIdle ? t * 0.08 : t * 0.22

    ctx.save()
    ctx.lineCap = "round"
    ctx.lineWidth = 2.4 * scale

    for (let i = 0; i < barCount; i++) {
      const a = (i / barCount) * Math.PI * 2 + rot
      const wave = 0.5 + 0.5 * Math.sin(i * 0.65 + t * 8.2) * Math.cos(i * 0.35 - t * 4.8)
      let amp = 2.5
      if (isSpeaking) {
        amp = 4 + Math.max(smoothAgent, 0.25) * 23 * (0.42 + 0.58 * wave)
      } else if (isThinking) {
        amp = 3.5 + 9 * Math.pow(0.5 + 0.5 * Math.sin(i * 0.35 - t * 6), 2)
      } else if (userTalking) {
        amp = 3 + smoothUser * 10 * (0.4 + 0.6 * wave)
      } else if (!isIdle) {
        amp = 2.5 + 1.5 * Math.sin(i * 0.4 + t * 2)
      }

      const r1 = baseR
      const r2 = baseR + amp * scale
      ctx.strokeStyle = isSpeaking && i % 2 === 0 ? palette.agentAccent : ringColor
      ctx.globalAlpha = isSpeaking ? 0.9 : isThinking ? 0.75 : userTalking ? 0.7 : isIdle ? 0.25 : 0.4
      ctx.beginPath()
      ctx.moveTo(cx + Math.cos(a) * r1, cy + Math.sin(a) * r1)
      ctx.lineTo(cx + Math.cos(a) * r2, cy + Math.sin(a) * r2)
      ctx.stroke()
    }
    ctx.restore()

    // Solid inner orb
    const coreR = (37 + smoothAgent * 3.5) * scale
    const coreGrad = ctx.createLinearGradient(cx - coreR, cy - coreR, cx + coreR, cy + coreR)
    if (isIdle) {
      coreGrad.addColorStop(0, palette.idle)
      coreGrad.addColorStop(1, palette.idle)
    } else if (isThinking) {
      coreGrad.addColorStop(0, palette.thinking)
      coreGrad.addColorStop(1, palette.agent)
    } else {
      coreGrad.addColorStop(0, palette.agent)
      coreGrad.addColorStop(1, palette.agentAccent)
    }

    ctx.save()
    ctx.globalAlpha = isIdle ? 0.55 : 1
    ctx.beginPath()
    ctx.arc(cx, cy, coreR, 0, Math.PI * 2)
    ctx.fillStyle = coreGrad
    ctx.fill()

    // Center letter initial
    ctx.fillStyle = "#ffffff"
    ctx.globalAlpha = isIdle ? 0.8 : 0.96
    ctx.font = `700 ${Math.round(28 * scale)}px -apple-system, BlinkMacSystemFont, sans-serif`
    ctx.textAlign = "center"
    ctx.textBaseline = "middle"
    ctx.fillText(glyph, cx, cy + 1)
    ctx.restore()
  }

  function loop(now) {
    draw(now)
    if (running) frame = requestAnimationFrame(loop)
  }
  frame = requestAnimationFrame(loop)

  return {
    setState(next) {
      state = next || "idle"
    },
    setGlyph(next) {
      glyph = next || "A"
    },
    setLevels(agentLevel, userLevel) {
      targetAgent = Math.min(1, Math.max(0, agentLevel || 0))
      targetUser = Math.min(1, Math.max(0, userLevel || 0))
    },
    setPalette(next) {
      palette = {...DEFAULT_PALETTE, ...next}
    },
    dispose() {
      running = false
      cancelAnimationFrame(frame)
      ro.disconnect()
    },
  }
}
