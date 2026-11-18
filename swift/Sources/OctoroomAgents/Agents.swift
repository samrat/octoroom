import Foundation
import Observation
import OctoroomCore

// Octoroom agents on top of RoomClient, a port of
// agents/priv/static/octoroom_agents.mjs.
//
//   let agents = Agents(room: room)
//   agents.agents                        // [Agent]: id, name, description, state
//   agents.transcript("assistant")       // [TranscriptItem]
//   try await agents.say("add Acme to the sheet", to: "assistant")
//
// An agent is a worker the room shows this client (it's subscribed to the
// agent's voice, or to its data output if it has no voice) whose presence
// has a `name`, as every `Octoroom.Agent` sets. Each agent's transcript
// starts from the snapshot it sends when this client starts seeing it.

@MainActor
@Observable
public final class Agents {
  public enum State: String, Sendable {
    case listening, thinking, speaking
    /// Holding a turn, to see if someone else answers it.
    case waiting
  }

  public struct Agent: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    /// Nil until the agent has said, or for a state this version doesn't know.
    public var state: State?
  }

  /// One conversation item: something a person said (or typed), or a reply.
  public struct TranscriptItem: Codable, Identifiable, Hashable, Sendable {
    public var messageId: String
    /// "user" or "assistant".
    public var role: String
    public var text: String
    /// A reply: "playing", then "completed", or "interrupted" with only what
    /// was heard.
    public var status: String?
    public var interrupted: Bool?
    /// Who said it, for a person's item.
    public var speaker: String?
    public var sequence: Int?

    public var id: String { messageId }

    enum CodingKeys: String, CodingKey {
      case role, text, status, interrupted, speaker, sequence
      case messageId = "message_id"
    }
  }

  public struct AgentError: Hashable, Sendable {
    public var agent: String
    public var stage: String
    public var fatal: Bool
  }

  public private(set) var agents: [Agent] = []
  public private(set) var transcripts: [String: [TranscriptItem]] = [:]
  /// The last error an agent reported.
  public private(set) var lastError: AgentError?

  @ObservationIgnored public let room: RoomClient
  @ObservationIgnored nonisolated(unsafe) private var listener: Task<Void, Never>?

  public init(room: RoomClient) {
    self.room = room
    let events = room.events()
    onWorkers(room.workers)
    listener = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        switch event {
        case .workers(let workers): self.onWorkers(workers)
        case .workerEvent(let event): self.onEvent(event)
        default: break
        }
      }
    }
  }

  deinit { listener?.cancel() }

  /// An agent's transcript so far.
  public func transcript(_ agentId: String) -> [TranscriptItem] { transcripts[agentId] ?? [] }

  /// Types `text` to an agent, as this participant. Returns once the agent
  /// has it; throws `OctoroomError.rejected` with the server's reason.
  public func say(_ text: String, to agentId: String) async throws {
    try await room.send(to: agentId, ["text": .string(text)])
  }

  private func onWorkers(_ workers: [Worker]) {
    let list = workers.compactMap { w -> Agent? in
      guard let name = w.attributes["name"]?.stringValue else { return nil }
      return Agent(
        id: w.id, name: name, description: w.attributes["description"]?.stringValue,
        state: w.state.flatMap(State.init))
    }
    let ids = Set(workers.map(\.id))
    if transcripts.keys.contains(where: { !ids.contains($0) }) {
      transcripts = transcripts.filter { ids.contains($0.key) }
    }
    if list != agents { agents = list }
  }

  private func onEvent(_ event: WorkerEvent) {
    switch event.type {
    case "transcript_snapshot":
      transcripts[event.worker] = (try? event.data["items"]?.decode([TranscriptItem].self)) ?? []
    case "transcript":
      guard let item = try? event.data.decode(TranscriptItem.self) else { return }
      var items = transcript(event.worker)
      if let i = items.firstIndex(where: { $0.messageId == item.messageId }) {
        items[i] = item
      } else {
        items.append(item)
      }
      transcripts[event.worker] = items
    case "error":
      lastError = AgentError(
        agent: event.worker, stage: event.data["stage"]?.stringValue ?? "?",
        fatal: event.data["fatal"]?.boolValue ?? false)
    default:
      break
    }
  }
}
