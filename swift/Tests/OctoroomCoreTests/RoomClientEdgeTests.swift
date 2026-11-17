import Foundation
import Testing
@testable import OctoroomCore

// Failure paths and races: what happens when a step is rejected, times
// out, or the client leaves part way.

@MainActor
@Suite struct RoomClientEdgeTests {
  @Test func aRejectedPushOfferRollsBackAndStopsTheTransceiver() async throws {
    let h = Harness()
    try await h.join()
    let publishing = Task { try await h.room.startCamera() }
    let request = try await h.server.next("publish_tracks")
    h.push("push", ["op_id": 1, "sources": ["camera"]])
    h.server.reply(try await h.server.next("push_offer"), ["reason": "cloudflare_error"], status: "error")

    try await until("the error event") {
      h.events.contains { if case .error(OctoroomError.rejected("cloudflare_error")) = $0 { true } else { false } }
    }
    #expect(h.engine.pc.signalingState == .stable)
    #expect(h.engine.pc.all.last!.stopped)
    #expect(await !h.server.sends("connected"))

    // The server gives up on the publish too.
    h.server.reply(request, ["reason": "cloudflare_error"], status: "error")
    await #expect(throws: OctoroomError.rejected("cloudflare_error")) { try await publishing.value }
    #expect(h.room.localTracks[.camera] == nil)
  }

  @Test func aSourceThatEndedWhileQueuedOffersNothing() async throws {
    let h = Harness()
    try await h.join()
    let publishing = Task { try await h.room.startCamera() }
    let request = try await h.server.next("publish_tracks")
    // The capture ends (a screen share stopped from the system UI) before
    // the server gets to it: the push offers an empty transceiver, which
    // the server then unpublishes.
    h.engine.opened.last!.stop()
    h.push("push", ["op_id": 1, "sources": ["camera"]])
    let offer = try await h.server.next("push_offer")
    #expect(offer.payload["mids"] == ["camera": "l1"])
    #expect(h.engine.pc.all.last!.sending == nil)
    h.server.reply(offer, ["sdp": "answer"])
    h.server.reply(try await h.server.next("connected"))
    h.server.reply(request)
    try await publishing.value
  }

  @Test func stopWaitsForAPendingPublish() async throws {
    let h = Harness()
    try await h.join()
    let publishing = Task { try await h.room.startCamera() }
    let request = try await h.server.next("publish_tracks")
    let stopping = Task { await h.room.stop(.camera) }
    // Unpublishing before the server has the source would race it.
    #expect(await !h.server.sends("unpublish", within: .milliseconds(50)))

    h.server.reply(request)
    try await publishing.value
    h.server.reply(try await h.server.next("unpublish"))
    await stopping.value
    #expect(h.room.localTracks[.camera] == nil)
  }

  @Test func aPublishCaughtByARepublishKeepsItsTracks() async throws {
    let h = Harness()
    try await h.join()
    let publishing = Task { try await h.room.startCamera() }
    // The session is being published again from scratch, the camera included.
    h.server.reply(try await h.server.next("publish_tracks"), ["reason": "republishing"], status: "error")
    try await publishing.value
    #expect(h.room.localTracks[.camera] != nil)
  }

  @Test func aFailedConnectionFailsTheJoin() async throws {
    let h = Harness()
    let joining = Task { try await h.room.join() }
    h.server.reply(try await h.server.next("phx_join"), Harness.joinReply)
    h.server.reply(try await h.server.next("publish"), ["sdp": "answer"])
    try await until { h.engine.pc.remoteSDP == "answer" }
    h.engine.pc.setState(.failed)

    await #expect(throws: OctoroomError.connectionFailed("connection to Cloudflare failed")) {
      try await joining.value
    }
    #expect(h.room.state == .idle)
    #expect(h.engine.pc.closed)
    #expect(!h.engine.opened[0].isLive)
    _ = try await h.server.next("phx_leave")
  }

  @Test func leavingWhileTheJoinIsUnansweredEndsTheJoin() async throws {
    let h = Harness()
    let joining = Task { try await h.room.join() }
    _ = try await h.server.next("phx_join")
    h.room.leave()
    await #expect(throws: OctoroomError.channelClosed) { try await joining.value }
    #expect(h.room.state == .idle)
    try await until { h.events.contains { if case .left(.left) = $0 { true } else { false } } }
    // One teardown, not a second one from the failed join.
    #expect(!h.events.contains { if case .left(.failed) = $0 { true } else { false } })
  }

  @Test func leavingAtThePermissionPromptStopsTheDevices() async throws {
    let h = Harness()
    var release: CheckedContinuation<Void, Never>?
    h.engine.beforeOpen = { await withCheckedContinuation { release = $0 } }
    let joining = Task { try await h.room.join() }
    h.server.reply(try await h.server.next("phx_join"), Harness.joinReply)
    try await until("the prompt") { release != nil }

    h.room.leave()
    release!.resume()
    await #expect(throws: OctoroomError.channelClosed) { try await joining.value }
    #expect(h.engine.opened.allSatisfy { !$0.isLive })
    #expect(h.engine.peers.isEmpty)
    #expect(h.room.localTracks.isEmpty)
  }

  @Test func aSecondJoinIsRefused() async throws {
    let h = Harness()
    try await h.join()
    await #expect(throws: OctoroomError.invalidState("can't join while joined")) { try await h.room.join() }
  }

  @Test func publishingBeforeJoiningIsRefused() async throws {
    let h = Harness()
    await #expect(throws: OctoroomError.invalidState("can't publish while idle")) {
      try await h.room.publish([.camera: FakeLocalTrack(kind: .video)])
    }
  }

  @Test func signalingIsSerial() async throws {
    let h = Harness()
    try await h.join()
    h.engine.pc.addRemote(mid: "r1", kind: .audio)
    h.push("renegotiate", ["op_id": 1, "sdp": "first"])
    h.push("close", ["op_id": 2, "mids": ["r1"]])
    let answer = try await h.server.next("answer")
    // The close waits for the renegotiation's reply.
    #expect(await !h.server.sends("close_offer", within: .milliseconds(50)))
    h.server.reply(answer)
    let close = try await h.server.next("close_offer")
    #expect(close.payload["op_id"] == 2)
  }

  @Test func aSignalingErrorDoesNotStallTheQueue() async throws {
    let h = Harness()
    try await h.join()
    h.push("renegotiate", ["op_id": 1, "sdp": "first"])
    h.server.reply(try await h.server.next("answer"), ["reason": "stale_op"], status: "error")
    h.push("renegotiate", ["op_id": 2, "sdp": "second"])
    let second = try await h.server.next("answer")
    #expect(second.payload["op_id"] == 2)
  }

  @Test func tracksWithoutATransceiverAreSkipped() async throws {
    let h = Harness()
    try await h.join()
    h.push("tracks", ["added": [["mid": "nope", "track": "p2/mic", "kind": "audio", "gain": 1]], "removed": []])
    h.engine.pc.addRemote(mid: "r1", kind: .audio)
    h.push("tracks", ["added": [["mid": "r1", "track": "p2/mic", "kind": "audio", "gain": 1]], "removed": []])
    try await until { h.room.tracks.count == 1 }
    #expect(h.room.tracks[0].mid == "r1")
  }
}

@MainActor
@Suite struct ChannelEdgeTests {
  func socket(_ server: FakeServer) -> PhoenixSocket {
    PhoenixSocket(
      endpoint: URL(string: "ws://localhost:4000/socket")!, heartbeatInterval: .seconds(3600),
      reconnectAfter: { _ in .milliseconds(5) }, transport: server.factory())
  }

  @Test func aChannelErrorRejoins() async throws {
    let server = FakeServer()
    let socket = socket(server)
    socket.connect()
    let channel = socket.channel("room:a")
    var errors = 0
    channel.onError { errors += 1 }
    channel.join { _ in }
    let join = try await server.next("phx_join")
    server.reply(join)
    try await until { channel.state == .joined }

    server.push("room:a", "phx_error", [:], joinRef: join.ref)
    #expect(errors == 1)
    #expect(channel.state == .errored)
    // Rejoins after a second, on the same connection.
    let rejoin = try await server.next("phx_join", timeout: .seconds(3))
    #expect(rejoin.ref != join.ref)
    #expect(server.transports.count == 1)
  }

  @Test func lifecycleMessagesFromAnOldJoinAreIgnored() async throws {
    let server = FakeServer()
    let socket = socket(server)
    socket.connect()
    let channel = socket.channel("room:a")
    var closed = false
    channel.onClose { closed = true }
    channel.join { _ in }
    server.reply(try await server.next("phx_join"))
    try await until { channel.state == .joined }

    server.push("room:a", "phx_close", [:], joinRef: "stale")
    #expect(!closed)
    #expect(channel.state == .joined)
  }

  @Test func aJoinThatTimesOutIsRetried() async throws {
    let server = FakeServer()
    let socket = socket(server)
    socket.connect()
    let channel = socket.channel("room:a")
    var results: [PhoenixChannel.JoinReply] = []
    channel.join(timeout: .milliseconds(20)) { results.append($0) }
    _ = try await server.next("phx_join")
    _ = try await server.next("phx_leave")
    try await until { results.count == 1 }
    #expect(results.first.map { if case .failure(.timedOut("join")) = $0 { true } else { false } } == true)
    let retry = try await server.next("phx_join", timeout: .seconds(3))
    server.reply(retry, ["ok": true])
    try await until { results.count == 2 }
    #expect(channel.state == .joined)
  }

  @Test func theSocketURLGetsWebsocketAndTheVersion() async throws {
    let server = FakeServer()
    for (endpoint, expected) in [
      ("ws://h/socket", "ws://h/socket/websocket?vsn=2.0.0"),
      ("ws://h/socket/", "ws://h/socket/websocket?vsn=2.0.0"),
      ("ws://h/socket/websocket", "ws://h/socket/websocket?vsn=2.0.0"),
      ("wss://h/socket?app=1", "wss://h/socket/websocket?app=1&vsn=2.0.0"),
    ] {
      let socket = PhoenixSocket(endpoint: URL(string: endpoint)!, params: [:], transport: server.factory())
      socket.connect()
      #expect(server.current.url.absoluteString == expected)
      socket.disconnect()
    }
  }

  @Test func disconnectingDoesNotReconnect() async throws {
    let server = FakeServer()
    let socket = socket(server)
    socket.connect()
    try await until { socket.isConnected }
    socket.disconnect()
    try await Task.sleep(for: .milliseconds(50))
    #expect(server.transports.count == 1)
    #expect(!socket.isConnected)
  }
}

@Suite struct ModelTests {
  @Test func trackInfoToleratesUnknownSourcesAndMissingFields() throws {
    let json: JSONValue = ["mid": "1", "track": "echo:out", "kind": "audio", "source": "hologram"]
    let info = try json.decode(TrackInfo.self)
    #expect(info.source == nil)
    #expect(info.participantId == nil)
    #expect(info.gain == 1)
  }

  @Test func iceServersTakeOneURLOrMany() throws {
    let one = try (["urls": "stun:a"] as JSONValue).decode(IceServer.self)
    let many = try (["urls": ["turn:b", "turn:c"], "username": "u", "credential": "p"] as JSONValue).decode(IceServer.self)
    #expect(one.urls == ["stun:a"])
    #expect(many.urls == ["turn:b", "turn:c"])
    #expect(many.username == "u")
  }

  @Test func participantsDefaultMetaAndTracks() throws {
    let p = try (["id": "p1"] as JSONValue).decode(Participant.self)
    #expect(p.meta == [:])
    #expect(p.tracks.isEmpty)
    let q = try (["id": "p2", "tracks": ["screen_audio": ["kind": "audio", "muted": false]]] as JSONValue)
      .decode(Participant.self)
    #expect(q.track(.screenAudio) == PublishedTrack(kind: .audio, muted: false))
  }

  @Test func jsonKeepsBoolsAndNumbersApart() throws {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":true,"b":1,"c":1.5,"d":null}"#.utf8))
    #expect(value == ["a": true, "b": 1, "c": 1.5, "d": nil])
  }
}
