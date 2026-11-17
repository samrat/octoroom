import Foundation
import Testing
@testable import OctoroomCore

@MainActor
@Suite struct PhoenixSocketTests {
  func socket(_ server: FakeServer, heartbeat: Duration = .seconds(3600)) -> PhoenixSocket {
    PhoenixSocket(
      endpoint: URL(string: "ws://localhost:4000/socket")!, heartbeatInterval: heartbeat,
      reconnectAfter: { _ in .milliseconds(5) }, transport: server.factory())
  }

  @Test func pushesWaitForTheJoinAndGetReplies() async throws {
    let server = FakeServer()
    let socket = socket(server)
    socket.connect()
    let channel = socket.channel("room:a")
    channel.join { _ in }
    let pushing = Task { try await channel.push("hello", ["n": 1]) }
    let join = try await server.next("phx_join")
    #expect(await !server.sends("hello", within: .milliseconds(30)))

    server.reply(join)
    let hello = try await server.next("hello")
    #expect(hello.joinRef == join.ref)
    server.reply(hello, ["n": 2])
    #expect(try await pushing.value == ["n": 2])
  }

  @Test func errorRepliesThrowTheReason() async throws {
    let server = FakeServer()
    let socket = socket(server)
    socket.connect()
    let channel = socket.channel("room:a")
    channel.join { _ in }
    server.reply(try await server.next("phx_join"))
    let pushing = Task { try await channel.push("hello") }
    server.reply(try await server.next("hello"), ["reason": "nope"], status: "error")
    await #expect(throws: OctoroomError.rejected("nope")) { try await pushing.value }
  }

  @Test func pushesTimeOut() async throws {
    let server = FakeServer()
    let socket = socket(server)
    socket.connect()
    let channel = socket.channel("room:a")
    channel.join { _ in }
    server.reply(try await server.next("phx_join"))
    await #expect(throws: OctoroomError.timedOut("hello")) {
      try await channel.push("hello", timeout: .milliseconds(20))
    }
  }

  @Test func aMissedHeartbeatReconnects() async throws {
    let server = FakeServer()
    let socket = socket(server, heartbeat: .milliseconds(20))
    socket.connect()
    let channel = socket.channel("room:a")
    var replies = 0
    channel.join { _ in replies += 1 }
    server.reply(try await server.next("phx_join"))
    // Nobody answers heartbeats: after two intervals the socket gives up on
    // the connection, opens a new one, and the channel rejoins on it.
    let rejoin = try await server.next("phx_join", timeout: .seconds(1))
    #expect(server.transports.count == 2)
    server.reply(rejoin)
    try await until { replies == 2 }
    #expect(channel.state == .joined)
  }

  @Test func leftChannelsFailTheirPushes() async throws {
    let server = FakeServer()
    let socket = socket(server)
    socket.connect()
    let channel = socket.channel("room:a")
    channel.join { _ in }
    server.reply(try await server.next("phx_join"))
    let pushing = Task { try await channel.push("hello") }
    _ = try await server.next("hello")
    channel.leave()
    await #expect(throws: OctoroomError.channelClosed) { try await pushing.value }
    await #expect(throws: OctoroomError.channelClosed) { try await channel.push("again") }
  }
}
