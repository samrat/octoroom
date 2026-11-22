import {describe, it} from "node:test"
import assert from "node:assert/strict"
import {
  HISTORY_MS,
  SampleRing,
  applyTimelineEvent,
  createTimelineState,
  stagesForTurn,
} from "../../assets/js/voice_timeline_store.js"
import {computeTrackLayout} from "../../assets/js/voice_timeline_canvas.js"

const apply = (events, initial = createTimelineState()) =>
  events.reduce(applyTimelineEvent, initial)

describe("SampleRing", () => {
  it("stores and queries timestamped samples chronologically across wrap-around", () => {
    const ring = new SampleRing(4)
    ring.push(100, 0.1)
    ring.push(200, 0.2)
    ring.push(300, 0.3)
    ring.push(400, 0.4)
    ring.push(500, 0.5)

    const seen = []
    ring.forEachInRange(250, 500, (t, v) => seen.push([t, Math.round(v * 10) / 10]))
    assert.deepEqual(seen, [
      [300, 0.3],
      [400, 0.4],
      [500, 0.5],
    ])
    assert.equal(Math.round(ring.latest() * 10) / 10, 0.5)
  })
})

describe("applyTimelineEvent", () => {
  it("records assistant thinking/waiting phases and pairs reply latency after a user turn", () => {
    const state = apply([
      {type: "speech-start", laneId: "p1", role: "user", at: 1000, now: 1000},
      {type: "speech-end", laneId: "p1", role: "user", at: 2200, now: 2650},
      {type: "agent-state", agentId: "assistant", state: "thinking", at: 2300, now: 2300},
      {type: "agent-state", agentId: "atlas", state: "waiting", at: 2350, now: 2350},
      {type: "speech-start", laneId: "assistant", role: "agent", at: 2840, now: 2840},
      {type: "speech-end", laneId: "assistant", role: "agent", at: 4500, now: 4850},
      {type: "agent-state", agentId: "atlas", state: "listening", at: 3000, now: 3000},
    ])

    const thinking = state.phases.find((p) => p.laneId === "assistant" && p.kind === "thinking")
    const waiting = state.phases.find((p) => p.laneId === "atlas" && p.kind === "waiting")
    assert.ok(thinking)
    assert.equal(thinking.start, 2300)
    assert.equal(thinking.end, 2840)
    assert.ok(waiting)
    assert.equal(waiting.end, 3000)

    const reply = state.turns.find((t) => t.laneId === "assistant")
    assert.ok(reply)
    assert.equal(reply.latencyMs, 640)
    assert.equal(reply.end, 4500)
  })

  it("retroactively pairs fast S2S replies that start before the user's silence window expires", () => {
    const state = apply([
      {type: "speech-start", laneId: "p1", role: "user", at: 1000, now: 1000},
      {type: "speech-start", laneId: "openai", role: "agent", at: 2280, now: 2280},
      {type: "speech-end", laneId: "p1", role: "user", at: 2000, now: 2450},
    ])

    const reply = state.turns.find((t) => t.laneId === "openai")
    assert.ok(reply)
    assert.equal(reply.latencyMs, 280)
  })

  it("marks brief non-interrupting utterances as backchannels and attaches short transcript labels", () => {
    const state = apply([
      {type: "speech-start", laneId: "assistant", role: "agent", at: 2000, now: 2000},
      {type: "speech-start", laneId: "p1", role: "user", at: 2600, now: 2600},
      {type: "speech-end", laneId: "p1", role: "user", at: 2950, now: 3400},
      {type: "user-transcript", laneId: "p1", text: "Mm-hmm.", outcome: "listen", now: 3600},
      {type: "speech-end", laneId: "assistant", role: "agent", at: 4600, now: 4950},
    ])

    const bc = state.turns.find((t) => t.laneId === "p1")
    assert.ok(bc)
    assert.equal(bc.backchannel, true)
    assert.equal(bc.label, "mm-hmm")
    assert.equal(state.overlaps.length, 0)
  })

  it("marks overlaps as cuts when an assistant stops or emits an interruption", () => {
    const state = apply([
      {type: "speech-start", laneId: "atlas", role: "agent", at: 1000, now: 1000},
      {type: "speech-start", laneId: "p1", role: "user", at: 1800, now: 1800},
      {type: "speech-end", laneId: "atlas", role: "agent", at: 2100, now: 2450},
    ])

    assert.equal(state.overlaps.length, 1)
    assert.equal(state.overlaps[0].agentId, "atlas")
    assert.equal(state.overlaps[0].userLaneId, "p1")
    assert.equal(state.overlaps[0].cut, true)
    assert.equal(state.overlaps[0].end, 2100)
  })

  it("ingests dashboard waterfall stage spans with TTFT/TTFB and deduplicates by id", () => {
    const state = apply([
      {
        type: "stage-spans",
        now: 10_000,
        spans: [
          {
            id: "s-1",
            agent: "assistant",
            kind: "llm",
            label: "llm (nemotron-3.5-lightning)",
            ago_start_ms: 420,
            ago_end_ms: 20,
            duration_ms: 400,
            first_output_ms: 210,
            status: "ok",
          },
          {
            id: "s-1",
            agent: "assistant",
            kind: "llm",
            label: "llm (nemotron-3.5-lightning)",
            ago_start_ms: 420,
            ago_end_ms: 20,
            duration_ms: 400,
            first_output_ms: 210,
            status: "ok",
          },
        ],
      },
    ])

    assert.equal(state.stages.length, 1)
    assert.equal(state.stages[0].laneId, "assistant")
    assert.equal(state.stages[0].start, 9580)
    assert.equal(state.stages[0].end, 9980)
    assert.equal(state.stages[0].firstOutputMs, 210)
  })

  it("prunes old completed turns past the history buffer", () => {
    const t0 = 1000
    const tLate = t0 + HISTORY_MS + 5000
    const state = apply([
      {type: "speech-start", laneId: "p1", role: "user", at: t0, now: t0},
      {type: "speech-end", laneId: "p1", role: "user", at: t0 + 500, now: t0 + 500},
      {type: "speech-start", laneId: "p1", role: "user", at: tLate, now: tLate},
    ])

    assert.equal(state.turns.length, 1)
    assert.equal(state.turns[0].start, tLate)
  })
  it("matches only the stages belonging to a hovered assistant turn", () => {
    const state = apply([
      {
        type: "stage-spans",
        now: 3000,
        spans: [
          {id: "old-llm", agent: "assistant", kind: "llm", label: "llm", ago_start_ms: 400, ago_end_ms: 100, duration_ms: 300},
        ],
      },
      {type: "speech-start", laneId: "assistant", role: "agent", at: 3000, now: 3000},
      {type: "speech-end", laneId: "assistant", role: "agent", at: 4000, now: 4000},
      {
        type: "stage-spans",
        now: 9000,
        spans: [
          {id: "new-stt", agent: "assistant", kind: "stt", label: "stt", ago_start_ms: 500, ago_end_ms: 350, duration_ms: 150},
          {id: "new-llm", agent: "assistant", kind: "llm", label: "llm", ago_start_ms: 350, ago_end_ms: 50, duration_ms: 300, first_output_ms: 140},
          {id: "atlas-stt", agent: "atlas", kind: "stt", label: "stt", ago_start_ms: 500, ago_end_ms: 350, duration_ms: 150},
        ],
      },
      {type: "speech-start", laneId: "assistant", role: "agent", at: 9000, now: 9000},
      {type: "speech-end", laneId: "assistant", role: "agent", at: 10_200, now: 10_200},
    ])

    const secondTurn = state.turns[1]
    const matched = stagesForTurn(state, secondTurn, 10_500)
    assert.deepEqual(
      matched.map((s) => s.id),
      ["srv:new-stt", "srv:new-llm"],
    )
  })
})

describe("computeTrackLayout", () => {
  it("groups assistants above people with a divider between groups", () => {
    const layout = computeTrackLayout([
      {id: "assistant", label: "Assistant", role: "agent"},
      {id: "atlas", label: "Atlas", role: "agent"},
      {id: "p1", label: "Ada (you)", role: "user"},
    ])

    assert.equal(layout.tracks.length, 3)
    assert.equal(layout.tracks[0].height, layout.tracks[2].height)
    assert.ok(layout.dividerY > layout.tracks[1].top + layout.tracks[1].height)
    assert.ok(layout.dividerY < layout.tracks[2].top)
  })
})
