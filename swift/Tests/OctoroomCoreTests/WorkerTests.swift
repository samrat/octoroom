import Foundation
import Testing
@testable import OctoroomAgents
@testable import OctoroomCore

@MainActor
@Suite struct WorkerTests {
  static let coach: JSONValue = ["id": "coach", "outputs": [], "data": ["coach"], "state": nil, "attributes": [:]]
  static let echo: JSONValue = ["id": "echo", "outputs": ["p1/echo"], "data": [], "state": nil, "attributes": [:]]

  @Test func theJoinReplyListsWorkersAndPushesKeepThemCurrent() async throws {
    let h = Harness()
    try await h.join(Harness.joinReply(workers: [Self.coach]))
    #expect(h.room.workers.map(\.id) == ["coach"])
    #expect(h.room.workers[0].data == ["coach"])

    h.push("worker", ["op": "added", "worker": Self.echo])
    try await until { h.room.workers.map(\.id) == ["coach", "echo"] }

    // Updated in place; an update for a worker it doesn't see is ignored.
    h.push("worker", ["op": "updated", "worker": ["id": "ghost", "state": "speaking"]])
    h.push(
      "worker",
      ["op": "updated", "worker": ["id": "coach", "data": ["coach"], "state": "listening", "attributes": ["name": "Coach"]]])
    try await until { h.room.workers.first?.state == "listening" }
    #expect(h.room.workers.map(\.id) == ["coach", "echo"])
    #expect(h.room.workers[0].attributes["name"] == "Coach")

    h.push("worker", ["op": "removed", "worker": ["id": "coach"]])
    try await until { h.room.workers.map(\.id) == ["echo"] }

    h.room.leave()
    #expect(h.room.workers.isEmpty)
  }

  @Test func workerEventsComeThrough() async throws {
    let h = Harness()
    try await h.join()
    h.push("worker_event", ["worker": "coach", "output": "coach", "type": "tip", "data": ["text": "slow down"]])
    try await until {
      h.events.contains {
        if case .workerEvent(let e) = $0 { e == WorkerEvent(worker: "coach", output: "coach", type: "tip", data: ["text": "slow down"]) } else { false }
      }
    }
  }

  @Test func sendMessagesAWorkerAndThrowsTheServersReason() async throws {
    let h = Harness()
    try await h.join()

    let sent = Task { try await h.room.send(to: "assistant", ["text": "hi"]) }
    let message = try await h.server.next("worker_message")
    #expect(message.payload == ["worker": "assistant", "payload": ["text": "hi"]])
    h.server.reply(message)
    _ = try await sent.value

    let refused = Task { try await h.room.send(to: "coach", ["text": "hi"]) }
    h.server.reply(try await h.server.next("worker_message"), ["reason": "not_allowed"], status: "error")
    await #expect(throws: OctoroomError.rejected("not_allowed")) { try await refused.value }
  }

  @Test func agentsListsAgentsAndBuildsTheirTranscripts() async throws {
    let h = Harness()
    let assistant: JSONValue = [
      "id": "assistant", "outputs": ["assistant"], "data": [], "state": "listening",
      "attributes": ["name": "Assistant", "description": "Helps."],
    ]
    try await h.join(Harness.joinReply(workers: [Self.echo, assistant]))
    let agents = Agents(room: h.room)

    // The echo has no name: not an agent.
    #expect(agents.agents == [Agents.Agent(id: "assistant", name: "Assistant", description: "Helps.", state: .listening)])

    let hi: JSONValue = ["message_id": "m1", "role": "user", "text": "Hi", "status": "completed", "speaker": "Ada"]
    h.push("worker_event", ["worker": "assistant", "output": "assistant", "type": "transcript_snapshot", "data": ["items": [hi]]])
    try await until { agents.transcript("assistant").map(\.text) == ["Hi"] }

    h.push(
      "worker_event",
      ["worker": "assistant", "output": "assistant", "type": "transcript",
       "data": ["message_id": "m2", "role": "assistant", "text": "Hello there.", "status": "playing"]])
    h.push(
      "worker_event",
      ["worker": "assistant", "output": "assistant", "type": "transcript",
       "data": ["message_id": "m2", "role": "assistant", "text": "Hello", "status": "interrupted", "interrupted": true]])
    try await until { agents.transcript("assistant").last?.status == "interrupted" }
    #expect(agents.transcript("assistant").map(\.text) == ["Hi", "Hello"])
    #expect(agents.transcript("assistant")[0].speaker == "Ada")

    h.push("worker", ["op": "updated", "worker": ["id": "assistant", "state": "thinking", "attributes": ["name": "Assistant"]]])
    try await until { agents.agents.first?.state == .thinking }

    h.push("worker_event", ["worker": "assistant", "output": "assistant", "type": "error", "data": ["stage": "LLM", "fatal": false]])
    try await until { agents.lastError == Agents.AgentError(agent: "assistant", stage: "LLM", fatal: false) }

    // Typing goes to the agent as a `{text}` message.
    let said = Task { try await agents.say("add Acme", to: "assistant") }
    let message = try await h.server.next("worker_message")
    #expect(message.payload == ["worker": "assistant", "payload": ["text": "add Acme"]])
    h.server.reply(message)
    try await said.value

    // It goes away, and its transcript with it.
    h.push("worker", ["op": "removed", "worker": ["id": "assistant"]])
    try await until { agents.agents.isEmpty }
    #expect(agents.transcript("assistant").isEmpty)
  }
}
