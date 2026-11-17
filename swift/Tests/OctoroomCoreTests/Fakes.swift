import Foundation
@testable import OctoroomCore

struct TimedOut: Error, CustomStringConvertible {
  let description: String
}

/// A message the client sent: [join_ref, ref, topic, event, payload].
struct Sent {
  let joinRef: String?
  let ref: String?
  let topic: String
  let event: String
  let payload: JSONValue
}

/// Stands in for the server's end of the WebSocket. Every connection the
/// socket opens is a new `FakeTransport`; the server sees them all.
@MainActor
final class FakeServer {
  var transports: [FakeTransport] = []
  private var sent: [Sent] = []
  private var cursor = 0

  var current: FakeTransport { transports.last! }

  func factory() -> SocketTransportFactory {
    { [unowned self] url in
      let transport = FakeTransport(url: url, server: self)
      self.transports.append(transport)
      return transport
    }
  }

  func record(_ text: String) {
    let parts = try! JSONDecoder().decode(JSONValue.self, from: text.data(using: .utf8)!).arrayValue!
    let message = Sent(
      joinRef: parts[0].stringValue, ref: parts[1].stringValue, topic: parts[2].stringValue!,
      event: parts[3].stringValue!, payload: parts[4])
    if message.event != "heartbeat" { sent.append(message) }
  }

  /// The next message the client sends with `event`, skipping others.
  func next(_ event: String, timeout: Duration = .seconds(2)) async throws -> Sent {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      while cursor < sent.count {
        let message = sent[cursor]
        cursor += 1
        if message.event == event { return message }
      }
      try await Task.sleep(for: .milliseconds(2))
    }
    throw TimedOut(description: "no \(event) from the client")
  }

  /// Whether the client sends `event` within `timeout`.
  func sends(_ event: String, within timeout: Duration = .milliseconds(100)) async -> Bool {
    (try? await next(event, timeout: timeout)) != nil
  }

  func reply(_ message: Sent, _ response: JSONValue = [:], status: String = "ok") {
    deliver(
      joinRef: message.joinRef, ref: message.ref, topic: message.topic, event: "phx_reply",
      payload: ["status": .string(status), "response": response])
  }

  func push(_ topic: String, _ event: String, _ payload: JSONValue, joinRef: String? = nil) {
    deliver(joinRef: joinRef, ref: nil, topic: topic, event: event, payload: payload)
  }

  func deliver(joinRef: String?, ref: String?, topic: String, event: String, payload: JSONValue) {
    let message: JSONValue = [
      joinRef.map(JSONValue.string) ?? .null, ref.map(JSONValue.string) ?? .null, .string(topic),
      .string(event), payload,
    ]
    current.onMessage?(String(data: try! JSONEncoder().encode(message), encoding: .utf8)!)
  }
}

@MainActor
final class FakeTransport: SocketTransport {
  var onOpen: (() -> Void)?
  var onMessage: ((String) -> Void)?
  var onClose: ((Error?) -> Void)?
  let url: URL
  unowned let server: FakeServer
  var autoOpen = true

  init(url: URL, server: FakeServer) {
    self.url = url
    self.server = server
  }

  func connect() {
    guard autoOpen else { return }
    Task { @MainActor in self.onOpen?() }
  }

  func send(_ text: String) { server.record(text) }
  func disconnect() {}

  /// The connection drops.
  func drop() { onClose?(nil) }
}

@MainActor
final class FakeEngine: MediaEngine {
  var peers: [FakePeer] = []
  var opened: [FakeLocalTrack] = []
  var pc: FakePeer { peers.last! }

  func makePeerConnection(iceServers: [IceServer]) throws -> any PeerConnection {
    let peer = FakePeer(iceServers: iceServers)
    peers.append(peer)
    return peer
  }

  func openLocalMedia(audio: Bool, video: Bool) async throws -> [Source: any LocalMediaTrack] {
    var media: [Source: any LocalMediaTrack] = [:]
    if audio { media[.mic] = track(.audio) }
    if video { media[.camera] = track(.video) }
    return media
  }

  func openCamera() async throws -> any LocalMediaTrack { track(.video) }

  private func track(_ kind: MediaKind) -> FakeLocalTrack {
    let track = FakeLocalTrack(kind: kind)
    opened.append(track)
    return track
  }
}

@MainActor
final class FakeLocalTrack: LocalMediaTrack {
  let id = UUID().uuidString
  let kind: MediaKind
  var isEnabled = true
  var isLive = true

  init(kind: MediaKind) { self.kind = kind }
  func stop() { isLive = false }
}

@MainActor
final class FakeRemoteTrack: RemoteMediaTrack {
  let id = UUID().uuidString
  let kind: MediaKind
  var volume: Double = 1

  init(kind: MediaKind) { self.kind = kind }
  func setVolume(_ volume: Double) { self.volume = volume }
}

@MainActor
final class FakeTransceiver: Transceiver {
  var mid: String?
  let sending: (any LocalMediaTrack)?
  var receiverTrack: (any RemoteMediaTrack)?
  var stopped = false
  var cleared = false

  init(mid: String?, sending: (any LocalMediaTrack)?, receiving: (any RemoteMediaTrack)? = nil) {
    self.mid = mid
    self.sending = sending
    self.receiverTrack = receiving
  }

  func clearSenderTrack() { cleared = true }
  func stop() { stopped = true }
}

@MainActor
final class FakePeer: PeerConnection {
  let iceServers: [IceServer]
  var connectionState: PeerConnectionState = .new
  var signalingState: SignalingState = .stable
  var localSDP: String?
  var remoteSDP: String?
  var all: [FakeTransceiver] = []
  var transceivers: [any Transceiver] { all }
  var onConnectionStateChange: ((PeerConnectionState) -> Void)?
  var closed = false
  var nextMid = 0
  var offers = 0
  var stats: [StatsEntry] = []

  init(iceServers: [IceServer]) { self.iceServers = iceServers }

  func addTransceiver(sending track: any LocalMediaTrack) throws -> any Transceiver {
    add(FakeTransceiver(mid: nil, sending: track))
  }

  func addTransceiver(kind: MediaKind) throws -> any Transceiver {
    add(FakeTransceiver(mid: nil, sending: nil))
  }

  private func add(_ t: FakeTransceiver) -> FakeTransceiver {
    all.append(t)
    return t
  }

  /// A receiving transceiver, as a remote offer from Cloudflare adds.
  @discardableResult
  func addRemote(mid: String, kind: MediaKind) -> FakeRemoteTrack {
    let track = FakeRemoteTrack(kind: kind)
    all.append(FakeTransceiver(mid: mid, sending: nil, receiving: track))
    return track
  }

  func createOffer() async throws -> String {
    offers += 1
    return "offer \(offers)"
  }

  func createAnswer() async throws -> String { "answer to \(remoteSDP ?? "")" }

  func setLocalDescription(_ type: SDPType, sdp: String) async throws {
    switch type {
    case .offer:
      // Mids are assigned when the offer is applied, as in browsers.
      for t in all where t.mid == nil {
        t.mid = "l\(nextMid)"
        nextMid += 1
      }
      signalingState = .haveLocalOffer
      localSDP = sdp
    case .answer:
      signalingState = .stable
      localSDP = sdp
    case .rollback:
      signalingState = .stable
    }
  }

  func setRemoteDescription(_ type: SDPType, sdp: String) async throws {
    remoteSDP = sdp
    signalingState = type == .offer ? .haveRemoteOffer : .stable
  }

  func iceGatheringComplete(timeout: Duration) async {}

  func stats() async -> [StatsEntry] { stats }

  func close() { closed = true }

  func setState(_ state: PeerConnectionState) {
    connectionState = state
    onConnectionStateChange?(state)
  }
}
