import Foundation

// The media side of the client, as protocols: the `Octoroom` module
// implements them with WebRTC, tests with fakes. They mirror the parts of
// the browser's RTCPeerConnection API that the room client uses.

public enum PeerConnectionState: String, Sendable {
  case new, connecting, connected, disconnected, failed, closed
}

public enum SignalingState: String, Sendable {
  case stable, haveLocalOffer, haveRemoteOffer, haveLocalPranswer, haveRemotePranswer, closed
}

public enum SDPType: String, Sendable {
  case offer, answer, rollback
}

/// One entry of a stats report: its type ("inbound-rtp", "media-source", ...)
/// and the values the room client reads.
public struct StatsEntry: Sendable {
  public var type: String
  public var kind: String?
  public var mid: String?
  public var trackIdentifier: String?
  public var audioLevel: Double?

  public init(
    type: String, kind: String? = nil, mid: String? = nil, trackIdentifier: String? = nil,
    audioLevel: Double? = nil
  ) {
    self.type = type
    self.kind = kind
    self.mid = mid
    self.trackIdentifier = trackIdentifier
    self.audioLevel = audioLevel
  }
}

/// Makes peer connections and captures local media.
@MainActor
public protocol MediaEngine: AnyObject {
  func makePeerConnection(iceServers: [IceServer]) throws -> any PeerConnection
  /// The microphone, and the camera with `video`.
  func openLocalMedia(audio: Bool, video: Bool) async throws -> [Source: any LocalMediaTrack]
  func openCamera() async throws -> any LocalMediaTrack
}

@MainActor
public protocol PeerConnection: AnyObject {
  var connectionState: PeerConnectionState { get }
  var signalingState: SignalingState { get }
  /// The local description's SDP, with the candidates gathered so far.
  var localSDP: String? { get }
  var transceivers: [any Transceiver] { get }
  /// Called on every connection state change.
  var onConnectionStateChange: ((PeerConnectionState) -> Void)? { get set }

  /// A sendonly transceiver sending `track`.
  func addTransceiver(sending track: any LocalMediaTrack) throws -> any Transceiver
  /// A sendonly transceiver sending nothing.
  func addTransceiver(kind: MediaKind) throws -> any Transceiver
  func createOffer() async throws -> String
  func createAnswer() async throws -> String
  func setLocalDescription(_ type: SDPType, sdp: String) async throws
  func setRemoteDescription(_ type: SDPType, sdp: String) async throws
  /// Returns when ICE gathering completes, or after `timeout`.
  func iceGatheringComplete(timeout: Duration) async
  func stats() async -> [StatsEntry]
  func close()
}

@MainActor
public protocol Transceiver: AnyObject {
  var mid: String? { get }
  var receiverTrack: (any RemoteMediaTrack)? { get }
  /// Stops sending without renegotiating (`replaceTrack(null)`).
  func clearSenderTrack()
  func stop()
}

/// A track this client captures and publishes.
@MainActor
public protocol LocalMediaTrack: AnyObject {
  var id: String { get }
  var kind: MediaKind { get }
  /// A disabled track keeps sending: silence, or black frames.
  var isEnabled: Bool { get set }
  /// False once stopped (by `stop()`, or by its capture ending).
  var isLive: Bool { get }
  /// Stops capturing (and turns the camera light off).
  func stop()
}

/// A track this client receives.
@MainActor
public protocol RemoteMediaTrack: AnyObject {
  var id: String { get }
  var kind: MediaKind { get }
  /// Playback volume for audio, 0...1 (and above, to amplify). Ignored for video.
  func setVolume(_ volume: Double)
}
