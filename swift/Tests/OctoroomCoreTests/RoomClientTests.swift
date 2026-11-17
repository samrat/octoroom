import Foundation
import Testing
@testable import OctoroomCore

@MainActor
func until(_ what: String = "condition", timeout: Duration = .seconds(2), _ check: () -> Bool) async throws {
  let deadline = ContinuousClock.now + timeout
  while !check() {
    if ContinuousClock.now > deadline { throw TimedOut(description: "timed out waiting for \(what)") }
    try await Task.sleep(for: .milliseconds(2))
  }
}

@MainActor
final class Harness {
  let server = FakeServer()
  let engine = FakeEngine()
  let socket: PhoenixSocket
  let room: RoomClient
  var events: [RoomClient.Event] = []
  private var listener: Task<Void, Never>?

  init(video: Bool = false) {
    socket = PhoenixSocket(
      endpoint: URL(string: "wss://example.test/socket")!, params: { ["token": "secret"] },
      heartbeatInterval: .seconds(3600), reconnectAfter: { _ in .milliseconds(5) },
      transport: server.factory())
    room = RoomClient(
      socket: socket, topic: "room:lobby", params: ["name": "ada"], engine: engine, video: video)
    let stream = room.events()
    listener = Task { [weak self] in
      for await event in stream { self?.events.append(event) }
    }
  }

  static let joinReply: JSONValue = [
    "participant_id": "p1",
    "participants": [["id": "p1", "meta": ["name": "ada"], "tracks": [:]]],
    "ice_servers": [["urls": "stun:stun.cloudflare.com:3478"]],
    "resume_token": "token-1",
    "resumed": false,
  ]

  /// Joins and answers the whole handshake the way the server does.
  func join() async throws {
    let joining = Task { try await room.join() }
    let join = try await server.next("phx_join")
    server.reply(join, Self.joinReply)
    try await publishMedia()
    try await joining.value
  }

  /// Answers a `publish`: Cloudflare's answer, the connection, `connected`.
  func publishMedia() async throws {
    let publish = try await server.next("publish")
    server.reply(publish, ["sdp": "cloudflare answer"])
    try await until("the answer applied") { engine.pc.remoteSDP == "cloudflare answer" }
    engine.pc.setState(.connected)
    server.reply(try await server.next("connected"))
  }

  func push(_ event: String, _ payload: JSONValue) {
    server.push("room:lobby", event, payload)
  }
}

@MainActor
@Suite struct RoomClientTests {
  @Test func joinPublishesTheMic() async throws {
    let h = Harness()
    let joining = Task { try await h.room.join() }

    let join = try await h.server.next("phx_join")
    #expect(join.topic == "room:lobby")
    #expect(join.payload == ["name": "ada"])
    #expect(h.server.current.url.absoluteString == "wss://example.test/socket/websocket?token=secret&vsn=2.0.0")
    h.server.reply(join, Harness.joinReply)

    let publish = try await h.server.next("publish")
    #expect(publish.payload["mids"] == ["mic": "l0"])
    #expect(publish.payload["sdp"] == "offer 1")
    #expect(h.engine.pc.iceServers == [IceServer(urls: ["stun:stun.cloudflare.com:3478"])])
    h.server.reply(publish, ["sdp": "cloudflare answer"])
    try await until { h.engine.pc.remoteSDP == "cloudflare answer" }
    #expect(h.room.state == .joining)
    h.engine.pc.setState(.connected)
    h.server.reply(try await h.server.next("connected"))

    try await joining.value
    #expect(h.room.state == .joined)
    #expect(h.room.participantId == "p1")
    #expect(h.room.participants.map(\.id) == ["p1"])
    #expect(h.room.localTracks[.mic] != nil)
    #expect(h.room.resumeToken == "token-1")
  }

  @Test func joinWithVideoPublishesTheCameraToo() async throws {
    let h = Harness(video: true)
    let joining = Task { try await h.room.join() }
    h.server.reply(try await h.server.next("phx_join"), Harness.joinReply)
    let publish = try await h.server.next("publish")
    #expect(publish.payload["mids"] == ["mic": "l0", "camera": "l1"])
    joining.cancel()
    h.room.leave()
  }

  @Test func aRejectedJoinThrowsAndResets() async throws {
    let h = Harness()
    let joining = Task { try await h.room.join() }
    h.server.reply(try await h.server.next("phx_join"), ["reason": "room_full"], status: "error")
    await #expect(throws: OctoroomError.rejected("room_full")) { try await joining.value }
    #expect(h.room.state == .idle)
    #expect(h.engine.opened.isEmpty)
  }

  @Test func renegotiateAnswersAndTracksPlay() async throws {
    let h = Harness()
    try await h.join()

    let remote = h.engine.pc.addRemote(mid: "r1", kind: .audio)
    h.push("renegotiate", ["op_id": 7, "sdp": "cloudflare offer"])
    let answer = try await h.server.next("answer")
    #expect(answer.payload == ["op_id": 7, "sdp": "answer to cloudflare offer"])
    // Signaling is serial: the tracks below wait for this reply.
    h.server.reply(answer)

    h.push(
      "tracks",
      [
        "added": [
          [
            "mid": "r1", "track": "p2/mic", "kind": "audio", "source": "mic",
            "participant_id": "p2", "worker_id": nil, "gain": 0.5,
          ]
        ],
        "removed": [],
      ])
    try await until("the track") { h.room.tracks.count == 1 }
    let track = h.room.tracks[0]
    #expect(track.source == .mic)
    #expect(track.participantId == "p2")
    #expect(remote.volume == 0.5)

    h.push("gain", ["mid": "r1", "gain": 0.2])
    try await until("the gain") { h.room.tracks.first?.gain == 0.2 }
    #expect(remote.volume == 0.2)

    h.push("tracks", ["added": [], "removed": ["r1"]])
    try await until("the removal") { h.room.tracks.isEmpty }
  }

  @Test func aResetKeepsUnchangedTracksAndDropsTheRest() async throws {
    let h = Harness()
    try await h.join()
    let a = h.engine.pc.addRemote(mid: "r1", kind: .audio)
    h.engine.pc.addRemote(mid: "r2", kind: .video)
    func info(_ mid: String, _ track: String, _ kind: String) -> JSONValue {
      ["mid": .string(mid), "track": .string(track), "kind": .string(kind), "participant_id": "p2", "gain": 1]
    }
    h.push("tracks", ["added": [info("r1", "p2/mic", "audio"), info("r2", "p2/camera", "video")], "removed": []])
    try await until { h.room.tracks.count == 2 }
    a.volume = 0.3

    h.push("tracks", ["reset": true, "added": [info("r1", "p2/mic", "audio")], "removed": []])
    try await until { h.room.tracks.count == 1 }
    #expect(h.room.tracks[0].mid == "r1")
    // Unchanged, so not set up again.
    #expect(a.volume == 0.3)
  }

  @Test func publishingTheCameraGoesThroughThePushQueue() async throws {
    let h = Harness()
    try await h.join()

    let publishing = Task { try await h.room.startCamera() }
    let request = try await h.server.next("publish_tracks")
    #expect(request.payload == ["sources": ["camera"]])

    h.push("push", ["op_id": 3, "sources": ["camera"]])
    let offer = try await h.server.next("push_offer")
    #expect(offer.payload["op_id"] == 3)
    #expect(offer.payload["mids"] == ["camera": "l1"])
    h.server.reply(offer, ["sdp": "push answer"])
    h.server.reply(try await h.server.next("connected"))
    h.server.reply(request)
    try await publishing.value
    #expect(h.room.localTracks[.camera] != nil)

    let stopping = Task { await h.room.stop(.camera) }
    let unpublish = try await h.server.next("unpublish")
    #expect(unpublish.payload == ["source": "camera"])
    h.server.reply(unpublish)
    await stopping.value
    #expect(h.room.localTracks[.camera] == nil)
    let camera = h.engine.opened.last!
    #expect(!camera.isLive)
    let transceiver = h.engine.pc.all.first { $0.mid == "l1" }!
    #expect(transceiver.cleared)
  }

  @Test func aRejectedPublishUnpublishesLocally() async throws {
    let h = Harness()
    try await h.join()
    let publishing = Task { try await h.room.startCamera() }
    h.server.reply(try await h.server.next("publish_tracks"), ["reason": "not_allowed"], status: "error")
    await #expect(throws: OctoroomError.rejected("not_allowed")) { try await publishing.value }
    #expect(h.room.localTracks[.camera] == nil)
    #expect(!h.engine.opened.last!.isLive)
  }

  @Test func publishingTwiceIsAnError() async throws {
    let h = Harness()
    try await h.join()
    await #expect(throws: OctoroomError.invalidState("mic is already published")) {
      try await h.room.publish([.mic: FakeLocalTrack(kind: .audio)])
    }
  }

  @Test func closeStopsTransceiversAndOffers() async throws {
    let h = Harness()
    try await h.join()
    h.engine.pc.addRemote(mid: "r1", kind: .audio)
    h.engine.pc.addRemote(mid: "r2", kind: .audio)
    h.push("close", ["op_id": 9, "mids": ["r1"]])
    let offer = try await h.server.next("close_offer")
    #expect(offer.payload["op_id"] == 9)
    h.server.reply(offer, ["sdp": "close answer"])
    try await until { h.engine.pc.remoteSDP == "close answer" }
    let stopped = h.engine.pc.all.filter(\.stopped).compactMap(\.mid)
    #expect(stopped == ["r1"])
  }

  @Test func muteTellsTheServer() async throws {
    let h = Harness()
    try await h.join()
    h.room.setMuted(true)
    let mute = try await h.server.next("mute")
    #expect(mute.payload == ["source": "mic", "muted": true])
    #expect(h.room.isMuted)
    #expect(h.room.localTracks[.mic]?.muted == true)
    #expect(h.engine.opened[0].isEnabled == false)
  }

  @Test func roomEventsUpdateParticipants() async throws {
    let h = Harness()
    try await h.join()
    h.push("room_event", ["type": "joined", "participant": ["id": "p2", "meta": [:], "tracks": [:]]])
    try await until { h.room.participants.count == 2 }
    h.push(
      "room_event",
      ["type": "published", "participant": ["id": "p2", "meta": [:], "tracks": ["camera": ["kind": "video", "muted": true]]]])
    try await until { h.room.participants.last?.track(.camera)?.muted == true }
    h.push("room_event", ["type": "left", "participant": ["id": "p2", "meta": [:], "tracks": [:]]])
    try await until { h.room.participants.count == 1 }
  }

  @Test func reconnectingResumesWithTheToken() async throws {
    let h = Harness()
    try await h.join()
    h.push("resume_token", ["token": "token-2"])
    h.room.setMuted(true)
    h.server.reply(try await h.server.next("mute"))

    h.server.current.drop()
    try await until("reconnecting") { h.events.contains { if case .reconnecting = $0 { true } else { false } } }

    let rejoin = try await h.server.next("phx_join")
    #expect(rejoin.payload == ["name": "ada", "resume_token": "token-2"])
    var reply = Harness.joinReply
    if case .object(var o) = reply {
      o["resumed"] = true
      o["resume_token"] = "token-3"
      reply = .object(o)
    }
    h.server.reply(rejoin, reply)

    // The server adopts the session but not the mute flags: they're sent again.
    let mute = try await h.server.next("mute")
    #expect(mute.payload == ["source": "mic", "muted": true])
    #expect(h.engine.peers.count == 1)
    #expect(h.room.resumeToken == "token-3")
    #expect(h.events.contains { if case .reconnected(resumed: true) = $0 { true } else { false } })
  }

  @Test func nothingToResumePublishesAgain() async throws {
    let h = Harness()
    try await h.join()
    h.engine.pc.addRemote(mid: "r1", kind: .audio)
    h.push("tracks", ["added": [["mid": "r1", "track": "p2/mic", "kind": "audio", "gain": 1]], "removed": []])
    try await until { h.room.tracks.count == 1 }

    h.server.current.drop()
    h.server.reply(try await h.server.next("phx_join"), Harness.joinReply)
    try await h.publishMedia()
    #expect(h.engine.peers.count == 2)
    #expect(h.engine.peers[0].closed)
    #expect(h.room.tracks.isEmpty)
    #expect(h.room.state == .joined)
  }

  @Test func republishStartsANewSession() async throws {
    let h = Harness()
    try await h.join()
    h.push("republish", ["reason": "room_restarted"])
    try await h.publishMedia()
    #expect(h.engine.peers.count == 2)
  }

  @Test func theServerClosingTheChannelLeaves() async throws {
    let h = Harness()
    try await h.join()
    h.server.push("room:lobby", "phx_close", [:])
    try await until("left") { h.events.contains { if case .left(.closed) = $0 { true } else { false } } }
    #expect(h.room.state == .idle)
    #expect(h.engine.pc.closed)
    #expect(!h.engine.opened[0].isLive)
  }

  @Test func leaveSendsPhxLeave() async throws {
    let h = Harness()
    try await h.join()
    h.room.leave()
    let leave = try await h.server.next("phx_leave")
    #expect(leave.topic == "room:lobby")
    #expect(h.room.state == .idle)
    #expect(h.room.participants.isEmpty)
  }

  @Test func levelsReadStats() async throws {
    let h = Harness()
    try await h.join()
    h.engine.pc.addRemote(mid: "r1", kind: .audio)
    h.push("tracks", ["added": [["mid": "r1", "track": "p2/mic", "kind": "audio", "source": "mic", "participant_id": "p2", "gain": 1]], "removed": []])
    try await until { h.room.tracks.count == 1 }
    h.engine.pc.stats = [
      StatsEntry(type: "inbound-rtp", kind: "audio", mid: "r1", audioLevel: 0.4),
      StatsEntry(type: "media-source", kind: "audio", trackIdentifier: h.engine.opened[0].id, audioLevel: 0.7),
    ]
    let levels = await h.room.levels()
    #expect(levels.remote == ["p2": 0.4])
    #expect(levels.local == 0.7)
  }
}
