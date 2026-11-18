// Octoroom agents in the browser, on top of Octoroom's RoomClient.
//
//   import {RoomClient} from "octoroom"
//   import {agents} from "octoroom_agents"
//
//   const room = new RoomClient({socket, topic: `room:${id}`})
//   const ai = agents(room)
//   ai.on("agents", (list) => render(list))              // [{id, name, description, state}]
//   ai.on("transcript", ({agent, items}) => render(agent, items))
//   ai.on("error", ({agent, stage, fatal}) => warn(agent, stage))
//   await room.join()
//   await ai.say("assistant", "add Acme to the sheet")
//
// An agent here is a worker the room shows this client (it's subscribed to
// the agent's voice, or to its data output if it has no voice) whose
// presence has a `name`, as every `Octoroom.Agent` sets. `state` is
// "listening", "thinking", "speaking" or "waiting" (holding a turn to see
// if someone else answers), or null until the agent has said.
//
// Each agent's transcript is a list of items, in the order they started:
// {message_id, role ("user" or "assistant"), text, status, speaker, ...}.
// A spoken reply is listed once its text is done with status "playing",
// then "completed", or "interrupted" with only what was heard. When this
// client starts seeing an agent, the agent sends what was said before, and
// the list starts from that.
//
// say() rejects with the server's reason: "not_allowed" if the agent
// doesn't hear this participant, "rate_limited", "too_large" or
// "no_worker". A typed message is always answered.

export function agents(room) {
  return new Agents(room)
}

export class Agents {
  constructor(room) {
    this.room = room
    this.listeners = {}
    this.list = []
    this.transcripts = new Map() // agent id => items
    room.on("workers", (workers) => this.onWorkers(workers))
    room.on("worker_event", (event) => this.onEvent(event))
    this.onWorkers(room.workers || [])
  }

  on(event, fn) {
    ;(this.listeners[event] ||= []).push(fn)
    return () => (this.listeners[event] = this.listeners[event].filter((f) => f !== fn))
  }

  emit(event, payload) {
    for (const fn of this.listeners[event] || []) {
      try {
        fn(payload)
      } catch (error) {
        console.error(error)
      }
    }
  }

  /** The agents this client sees. */
  agents() {
    return this.list
  }

  /** An agent's transcript so far. */
  transcript(agentId) {
    return this.transcripts.get(agentId) || []
  }

  /**
   * Types `text` to an agent, as this participant. Resolves once the agent
   * has it.
   */
  say(agentId, text) {
    return this.room.send(agentId, {text})
  }

  onWorkers(workers) {
    const list = workers
      .filter((w) => typeof w.attributes?.name === "string")
      .map((w) => ({
        id: w.id,
        name: w.attributes.name,
        description: w.attributes.description ?? null,
        state: w.state,
      }))

    for (const id of this.transcripts.keys()) {
      if (!workers.some((w) => w.id === id)) this.transcripts.delete(id)
    }
    if (same(list, this.list)) return
    this.list = list
    this.emit("agents", list)
  }

  onEvent({worker, type, data}) {
    if (type === "transcript_snapshot") {
      this.setTranscript(worker, data.items || [])
    } else if (type === "transcript") {
      const items = this.transcript(worker)
      const at = items.findIndex((item) => item.message_id === data.message_id)
      this.setTranscript(
        worker,
        at === -1 ? [...items, data] : items.map((item, i) => (i === at ? {...item, ...data} : item)),
      )
    } else if (type === "error") {
      this.emit("error", {agent: worker, ...data})
    }
  }

  setTranscript(agent, items) {
    this.transcripts.set(agent, items)
    this.emit("transcript", {agent, items})
  }
}

function same(a, b) {
  return (
    a.length === b.length &&
    a.every((x, i) => x.id === b[i].id && x.name === b[i].name && x.description === b[i].description && x.state === b[i].state)
  )
}
