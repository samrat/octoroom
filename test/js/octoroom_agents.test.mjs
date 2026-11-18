// Tests for agents/priv/static/octoroom_agents.mjs, against a stand-in for
// RoomClient: only its "workers" and "worker_event" events, `workers` and
// send() are used.

import assert from "node:assert/strict"
import {test} from "node:test"

import {agents} from "../../agents/priv/static/octoroom_agents.mjs"

class FakeRoom {
  constructor(workers = []) {
    this.workers = workers
    this.listeners = {}
    this.sent = []
  }

  on(event, fn) {
    ;(this.listeners[event] ||= []).push(fn)
  }

  emit(event, payload) {
    if (event === "workers") this.workers = payload
    for (const fn of this.listeners[event] || []) fn(payload)
  }

  send(worker, payload) {
    this.sent.push([worker, payload])
    return Promise.resolve({})
  }
}

const ASSISTANT = {
  id: "assistant",
  outputs: ["assistant"],
  data: [],
  state: "listening",
  attributes: {name: "Assistant", description: "Helps the team."},
}
const ECHO = {id: "echo", outputs: ["p1/echo"], data: [], state: null, attributes: {}}

function recorded(ai) {
  const events = []
  for (const name of ["agents", "transcript", "error"]) ai.on(name, (p) => events.push([name, p]))
  return (name) => events.filter(([n]) => n === name).map(([, p]) => p)
}

test("lists the workers that are agents, as their presence changes", () => {
  const room = new FakeRoom([ECHO])
  const ai = agents(room)
  const emitted = recorded(ai)
  assert.deepEqual(ai.agents(), [])

  room.emit("workers", [ECHO, ASSISTANT])
  const listening = {id: "assistant", name: "Assistant", description: "Helps the team.", state: "listening"}
  assert.deepEqual(ai.agents(), [listening])

  // A change to a worker that isn't an agent changes nothing.
  room.emit("workers", [{...ECHO, state: "on"}, ASSISTANT])
  room.emit("workers", [ECHO, {...ASSISTANT, state: "thinking"}])
  room.emit("workers", [ECHO])

  assert.deepEqual(emitted("agents"), [[listening], [{...listening, state: "thinking"}], []])
})

test("starts from a room that already has agents", () => {
  const ai = agents(new FakeRoom([ASSISTANT]))
  assert.deepEqual(
    ai.agents().map((a) => a.id),
    ["assistant"],
  )
})

test("builds each agent's transcript from its snapshot and items", () => {
  const room = new FakeRoom([ASSISTANT])
  const ai = agents(room)
  const emitted = recorded(ai)
  const hi = {message_id: "m1", role: "user", text: "Hi", status: "completed", speaker: "Alice"}

  room.emit("worker_event", {worker: "assistant", output: "assistant", type: "transcript_snapshot", data: {items: [hi]}})
  assert.deepEqual(ai.transcript("assistant"), [hi])

  const reply = {message_id: "m2", role: "assistant", text: "Hello there.", status: "playing"}
  room.emit("worker_event", {worker: "assistant", type: "transcript", data: reply})
  // The same reply, cut off: replaced in place.
  const cut = {...reply, text: "Hello", status: "interrupted", interrupted: true}
  room.emit("worker_event", {worker: "assistant", type: "transcript", data: cut})

  assert.deepEqual(ai.transcript("assistant"), [hi, cut])
  assert.deepEqual(emitted("transcript").at(-1), {agent: "assistant", items: [hi, cut]})
  assert.equal(emitted("transcript").length, 3)

  // A new snapshot (the agent restarted) starts over.
  room.emit("worker_event", {worker: "assistant", type: "transcript_snapshot", data: {items: []}})
  assert.deepEqual(ai.transcript("assistant"), [])

  // An agent that goes away takes its transcript with it.
  room.emit("worker_event", {worker: "assistant", type: "transcript", data: hi})
  room.emit("workers", [])
  assert.deepEqual(ai.transcript("assistant"), [])
})

test("passes errors on, and say() types to an agent", async () => {
  const room = new FakeRoom([ASSISTANT])
  const ai = agents(room)
  const emitted = recorded(ai)

  room.emit("worker_event", {worker: "assistant", type: "error", data: {stage: "Llm", fatal: false}})
  assert.deepEqual(emitted("error"), [{agent: "assistant", stage: "Llm", fatal: false}])

  assert.deepEqual(await ai.say("assistant", "add Acme"), {})
  assert.deepEqual(room.sent, [["assistant", {text: "add Acme"}]])
})
