// Pure state & data model for Meet's multi-party Voice Timeline.
//
// Tracks:
// - Timestamped audio envelopes (`SampleRing`) per lane
// - Speech turns (with reply latency and backchannel annotations)
// - Assistant processing phases (`thinking` and `waiting` floor holds)
// - Active and completed speaker overlaps / barge-in cuts

export const HISTORY_MS = 40_000
export const DEFAULT_WINDOW_MS = 15_000
export const BACKCHANNEL_MAX_MS = 700
export const HANDOFF_MAX_MS = 15_000

/**
 * Circular buffer of `{t, v}` audio envelope samples (>34s even at 120Hz).
 * Uses typed arrays so per-frame sampling allocates zero objects.
 */
export class SampleRing {
  constructor(capacity = 4096) {
    this.capacity = capacity
    this.times = new Float64Array(capacity)
    this.values = new Float32Array(capacity)
    this.head = 0
    this.count = 0
  }

  push(time, value) {
    this.times[this.head] = time
    this.values[this.head] = value
    this.head = (this.head + 1) % this.capacity
    if (this.count < this.capacity) this.count++
  }

  /** Iterates samples in chronological order within `[fromTime, toTime]`. */
  forEachInRange(fromTime, toTime, fn) {
    if (this.count === 0) return
    const start = (this.head - this.count + this.capacity) % this.capacity
    for (let i = 0; i < this.count; i++) {
      const idx = (start + i) % this.capacity
      const t = this.times[idx]
      if (t < fromTime) continue
      if (t > toTime) break
      fn(t, this.values[idx])
    }
  }

  latest() {
    if (this.count === 0) return 0
    const idx = (this.head - 1 + this.capacity) % this.capacity
    return this.values[idx]
  }

  clear() {
    this.head = 0
    this.count = 0
  }
}

export function createTimelineState() {
  return {
    nextId: 1,
    /** Assistant phases: `{id, laneId, kind: "thinking" | "waiting", start, end}` */
    phases: [],
    /** Dashboard-style pipeline stage spans: `{id, laneId, kind, label, start, end, durationMs, firstOutputMs, status}` */
    stages: [],
    /** Speech turns: `{id, laneId, role, start, end, latencyMs, backchannel, label}` */
    turns: [],
    /** Overlaps where a person spoke over an assistant: `{id, agentId, userLaneId, start, end, cut}` */
    overlaps: [],
    /** Currently active speaking state per lane id. */
    speaking: {},
    /** Current server-reported assistant presence state per agent id. */
    agentStates: {},
    /** Most recent completed user turn-end awaiting a reply: `{laneId, at}` | null. */
    pendingHandoff: null,
  }
}

function prune(list, cutoff) {
  return list.filter((item) => item.end === null || item.end >= cutoff)
}

function findOpenTurn(turns, laneId) {
  for (let i = turns.length - 1; i >= 0; i--) {
    if (turns[i].laneId === laneId && turns[i].end === null) return turns[i]
  }
  return null
}

function findOpenAgentTurn(turns) {
  for (let i = turns.length - 1; i >= 0; i--) {
    if (turns[i].role === "agent" && turns[i].end === null) return turns[i]
  }
  return null
}

function closeOpenPhases(phases, laneId, at) {
  let changed = false
  const next = phases.map((p) => {
    if (p.laneId === laneId && p.end === null) {
      changed = true
      return {...p, end: at}
    }
    return p
  })
  return changed ? next : phases
}

function cleanShortLabel(text) {
  if (!text) return null
  const cleaned = text.trim().replace(/[.!?,…]+$/g, "").trim()
  if (!cleaned || cleaned.length > 22) return null
  return cleaned.toLowerCase()
}

/**
 * Pure event transition function for the Voice Timeline store.
 *
 * Events (timestamps in `performance.now()` ms):
 * - `{type: "reset", now}`
 * - `{type: "disconnected", now}`
 * - `{type: "agent-state", agentId, state, now}`
 * - `{type: "speech-start", laneId, role, at?, now}`
 * - `{type: "speech-end", laneId, role, at?, now}`
 * - `{type: "interruption", agentId, userLaneId?, now}`
 * - `{type: "reply-latency", agentId, audioMs, now}`
 * - `{type: "user-transcript", laneId, text, outcome, now}`
 */
export function applyTimelineEvent(state, event) {
  const now = event.now
  const at = event.at ?? now
  const cutoff = now - HISTORY_MS

  switch (event.type) {
    case "reset":
      return {...createTimelineState(), nextId: state.nextId}

    case "disconnected":
      return {
        ...state,
        phases: state.phases.map((p) => (p.end === null ? {...p, end: now} : p)),
        turns: state.turns.map((t) => (t.end === null ? {...t, end: now} : t)),
        overlaps: state.overlaps.map((o) => (o.end === null ? {...o, end: now} : o)),
        speaking: {},
        agentStates: {},
        pendingHandoff: null,
      }

    case "agent-state": {
      const {agentId, state: nextAgentState} = event
      const prevAgentState = state.agentStates[agentId]
      if (prevAgentState === nextAgentState) return state

      let phases = closeOpenPhases(state.phases, agentId, at)
      let nextId = state.nextId

      if (nextAgentState === "thinking" || nextAgentState === "waiting") {
        phases = [
          ...prune(phases, cutoff),
          {id: nextId++, laneId: agentId, kind: nextAgentState, start: at, end: null},
        ]
      }

      return {
        ...state,
        nextId,
        phases,
        agentStates: {...state.agentStates, [agentId]: nextAgentState},
      }
    }

    case "speech-start": {
      const {laneId, role} = event
      const existing = findOpenTurn(state.turns, laneId)
      if (existing) return state

      let nextId = state.nextId
      let turns = prune(state.turns, cutoff)
      let phases = prune(state.phases, cutoff)
      let overlaps = prune(state.overlaps, cutoff)
      let pendingHandoff = state.pendingHandoff

      if (role === "agent") {
        // Speaking finishes any open thinking/waiting phase on this assistant's track.
        phases = closeOpenPhases(phases, laneId, at)

        let latencyMs = null
        if (pendingHandoff && at >= pendingHandoff.at && at - pendingHandoff.at <= HANDOFF_MAX_MS) {
          latencyMs = Math.round(at - pendingHandoff.at)
          pendingHandoff = null
        }

        turns = [
          ...turns,
          {
            id: nextId++,
            laneId,
            role: "agent",
            start: at,
            end: null,
            latencyMs,
            backchannel: false,
            label: null,
          },
        ]
      } else {
        // User started speaking. Check whether an assistant currently holds the floor.
        const activeAgent = findOpenAgentTurn(turns)
        if (activeAgent) {
          overlaps = [
            ...overlaps,
            {
              id: nextId++,
              agentId: activeAgent.laneId,
              userLaneId: laneId,
              start: at,
              end: null,
              cut: false,
            },
          ]
        }

        turns = [
          ...turns,
          {
            id: nextId++,
            laneId,
            role: "user",
            start: at,
            end: null,
            latencyMs: null,
            backchannel: false,
            label: null,
          },
        ]
      }

      return {
        ...state,
        nextId,
        phases,
        turns,
        overlaps,
        speaking: {...state.speaking, [laneId]: true},
        pendingHandoff,
      }
    }

    case "speech-end": {
      const {laneId, role} = event
      const openTurn = findOpenTurn(state.turns, laneId)
      if (!openTurn) {
        return {...state, speaking: {...state.speaking, [laneId]: false}}
      }

      const endAt = Math.max(openTurn.start, at)
      let turns = state.turns
      let overlaps = state.overlaps
      let pendingHandoff = state.pendingHandoff

      if (role === "user") {
        const duration = endAt - openTurn.start
        // Did this user turn overlap an active assistant that kept going uninterrupted?
        const openOverlap = overlaps.find((o) => o.userLaneId === laneId && o.end === null)
        const overlappedAgentStillSpeaking =
          openOverlap && Boolean(findOpenTurn(turns, openOverlap.agentId))

        if (openOverlap && overlappedAgentStillSpeaking && !openOverlap.cut && duration <= BACKCHANNEL_MAX_MS) {
          // Brief non-interrupting remark: mark as backchannel and drop the overlap wash.
          overlaps = overlaps.filter((o) => o.id !== openOverlap.id)
          turns = turns.map((t) =>
            t.id === openTurn.id ? {...t, end: endAt, backchannel: true} : t,
          )
        } else {
          if (openOverlap) {
            overlaps = overlaps.map((o) =>
              o.id === openOverlap.id ? {...o, end: endAt, cut: true} : o,
            )
          }

          // Retroactively pair if a fast assistant already started replying before
          // the local silence tail expired.
          let pairedFastReply = false
          turns = turns.map((t) => {
            if (t.id === openTurn.id) return {...t, end: endAt}
            if (
              !pairedFastReply &&
              t.role === "agent" &&
              t.end === null &&
              t.latencyMs === null &&
              t.start >= endAt &&
              t.start - endAt <= HANDOFF_MAX_MS
            ) {
              pairedFastReply = true
              return {...t, latencyMs: Math.round(t.start - endAt)}
            }
            return t
          })

          if (!pairedFastReply) {
            pendingHandoff = {laneId, at: endAt}
          }
        }
      } else {
        // Assistant stopped speaking: close its turn and mark any active overlap as a cut.
        turns = turns.map((t) => (t.id === openTurn.id ? {...t, end: endAt} : t))
        overlaps = overlaps.map((o) =>
          o.agentId === laneId && o.end === null ? {...o, end: endAt, cut: true} : o,
        )
      }

      return {
        ...state,
        turns,
        overlaps,
        speaking: {...state.speaking, [laneId]: false},
        pendingHandoff,
      }
    }

    case "interruption": {
      const {agentId} = event
      let nextId = state.nextId
      let overlaps = prune(state.overlaps, cutoff)
      let matched = false

      overlaps = overlaps.map((o) => {
        if (o.agentId === agentId && (o.end === null || now - o.end < 1500)) {
          matched = true
          return {...o, end: o.end ?? now, cut: true}
        }
        return o
      })

      if (!matched) {
        const activeUser =
          event.userLaneId ||
          state.turns.findLast((t) => t.role === "user" && t.end === null)?.laneId ||
          state.pendingHandoff?.laneId ||
          null
        if (activeUser) {
          const userTurn = findOpenTurn(state.turns, activeUser)
          overlaps = [
            ...overlaps,
            {
              id: nextId++,
              agentId,
              userLaneId: activeUser,
              start: userTurn ? Math.max(userTurn.start, now - 1500) : now - 350,
              end: now,
              cut: true,
            },
          ]
        }
      }

      return {...state, nextId, overlaps}
    }

    case "reply-latency": {
      const {agentId, audioMs} = event
      if (typeof audioMs !== "number" || audioMs <= 0) return state

      // Fill latency on the assistant's current/most-recent reply turn if audio pairing missed it
      // (for example, a typed message or a very quiet utterance).
      let idx = -1
      for (let i = state.turns.length - 1; i >= 0; i--) {
        const t = state.turns[i]
        if (t.laneId === agentId && t.role === "agent" && now - t.start <= 3000) {
          idx = i
          break
        }
      }
      if (idx < 0 || state.turns[idx].latencyMs !== null) return state

      const turns = state.turns.map((t, i) =>
        i === idx ? {...t, latencyMs: Math.round(audioMs)} : t,
      )
      return {...state, turns}
    }

    case "user-transcript": {
      const {laneId, text, outcome} = event
      if (outcome && outcome !== "listen") return state
      const label = cleanShortLabel(text)
      if (!label) return state

      let idx = -1
      for (let i = state.turns.length - 1; i >= 0; i--) {
        const t = state.turns[i]
        if (
          t.laneId === laneId &&
          t.backchannel &&
          now - (t.end ?? t.start) <= 4500
        ) {
          idx = i
          break
        }
      }
      if (idx < 0) return state

      const turns = state.turns.map((t, i) => (i === idx ? {...t, label} : t))
      return {...state, turns}
    }

    case "stage-spans": {
      const incoming = event.spans
      if (!Array.isArray(incoming) || incoming.length === 0) return state
      const existing = prune(state.stages, cutoff)
      const seen = new Set(existing.map((s) => s.id))
      const added = []

      for (const raw of incoming) {
        const key = raw.id != null ? `srv:${raw.id}` : `loc:${state.nextId + added.length}`
        if (seen.has(key)) continue
        seen.add(key)
        const start = now - (raw.ago_start_ms ?? raw.duration_ms ?? 0)
        const end = Math.max(start, now - (raw.ago_end_ms ?? 0))
        added.push({
          id: key,
          laneId: raw.agent,
          kind: raw.kind || "llm",
          label: raw.label || raw.kind || "stage",
          start,
          end,
          durationMs: raw.duration_ms ?? Math.max(0, end - start),
          firstOutputMs: typeof raw.first_output_ms === "number" ? raw.first_output_ms : null,
          status: raw.status || "ok",
        })
      }

      if (added.length === 0) return state
      return {...state, stages: [...existing, ...added]}
    }

    default:
      return state
  }
}

/**
 * Returns the pipeline stages (STT, Decisions, Floor Wait, LLM, Tools, TTS, Live)
 * that belong to a given assistant reply turn, bounded by the previous reply on
 * that same lane so consecutive turns don't bleed together.
 */
export function stagesForTurn(state, turn, now = performance.now()) {
  if (!turn || turn.role !== "agent" || !state.stages?.length) return []

  let lowerBound = turn.start - Math.max((turn.latencyMs || 0) + 2500, 6000)
  for (const other of state.turns) {
    if (other.id === turn.id || other.laneId !== turn.laneId) continue
    const otherEnd = other.end ?? other.start
    if (otherEnd <= turn.start && otherEnd > lowerBound) {
      lowerBound = otherEnd
    }
  }
  const upperBound = (turn.end ?? now) + 500

  return state.stages
    .filter((s) => s.laneId === turn.laneId && s.end > lowerBound && s.start <= upperBound)
    .sort((a, b) => a.start - b.start)
}
