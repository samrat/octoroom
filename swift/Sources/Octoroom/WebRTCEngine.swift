import AVFoundation
@_exported import OctoroomCore
@preconcurrency import WebRTC

/// The WebRTC media engine: peer connections, the microphone and the camera.
/// One engine can serve many rooms; it owns a peer connection factory.
@MainActor
public final class WebRTCEngine: MediaEngine {
  public let factory: RTCPeerConnectionFactory

  /// - Parameter speaker: on iOS, play through the loudspeaker (as video
  ///   calls do) rather than the earpiece.
  public init(speaker: Bool = true) {
    Self.initializeOnce
    // WebRTC's default is playAndRecord in voiceChat mode (the earpiece).
    // videoChat mode routes to the loudspeaker and allows Bluetooth by
    // itself. The iOS 26 simulator's CoreAudio deadlocks (and aborts the
    // app) when capture starts in videoChat mode, so the simulator keeps
    // WebRTC's default; it plays through the Mac's output either way.
    #if os(iOS) && !targetEnvironment(simulator)
      if speaker {
        let config = RTCAudioSessionConfiguration.webRTC()
        config.mode = AVAudioSession.Mode.videoChat.rawValue
        RTCAudioSessionConfiguration.setWebRTC(config)
      }
    #endif
    factory = RTCPeerConnectionFactory(
      encoderFactory: RTCDefaultVideoEncoderFactory(),
      decoderFactory: RTCDefaultVideoDecoderFactory())
  }

  private static let initializeOnce: Void = { RTCInitializeSSL() }()

  public func makePeerConnection(iceServers: [IceServer]) throws -> any PeerConnection {
    let config = RTCConfiguration()
    config.iceServers = iceServers.map {
      RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
    }
    config.bundlePolicy = .maxBundle
    config.sdpSemantics = .unifiedPlan
    // Gather once: candidates found after the offer is sent are still
    // checked against Cloudflare's, but networks changing later aren't
    // followed (Cloudflare takes no trickle ICE).
    config.continualGatheringPolicy = .gatherOnce
    return try WebRTCPeerConnection(factory: factory, configuration: config)
  }

  public func openLocalMedia(audio: Bool, video: Bool) async throws -> [Source: any LocalMediaTrack] {
    var media: [Source: any LocalMediaTrack] = [:]
    if audio { media[.mic] = try await openMicrophone() }
    if video { media[.camera] = try await openCamera() }
    return media
  }

  /// The microphone. WebRTC captures from the default input once the track is sent.
  public func openMicrophone() async throws -> MicrophoneTrack {
    guard await AVAudioApplication.requestRecordPermission() else {
      throw OctoroomError.media("microphone access denied")
    }
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    let source = factory.audioSource(with: constraints)
    return MicrophoneTrack(track: factory.audioTrack(with: source, trackId: UUID().uuidString))
  }

  public func openCamera() async throws -> any LocalMediaTrack {
    try await openCamera(position: .front)
  }

  /// A camera: the front or back one on iOS, the default one on macOS.
  public func openCamera(
    position: AVCaptureDevice.Position, width: Int32 = 1280, height: Int32 = 720, fps: Int = 30
  ) async throws -> CameraTrack {
    guard await AVCaptureDevice.requestAccess(for: .video) else {
      throw OctoroomError.media("camera access denied")
    }
    let devices = RTCCameraVideoCapturer.captureDevices()
    guard let device = devices.first(where: { $0.position == position }) ?? devices.first else {
      throw OctoroomError.media("no camera")
    }
    let source = factory.videoSource()
    let track = factory.videoTrack(with: source, trackId: UUID().uuidString)
    let capturer = RTCCameraVideoCapturer(delegate: source)
    let camera = CameraTrack(track: track, capturer: capturer, position: device.position)
    try await camera.start(device: device, width: width, height: height, fps: fps)
    return camera
  }

  /// A video track the app feeds frames to: a screen share from ReplayKit
  /// or ScreenCaptureKit, a rendered view, a file.
  public func makeFrameTrack(screenCast: Bool = true) -> FrameTrack {
    let source = factory.videoSource(forScreenCast: screenCast)
    let track = factory.videoTrack(with: source, trackId: UUID().uuidString)
    return FrameTrack(track: track, source: source)
  }
}

// MARK: - peer connection

@MainActor
final class WebRTCPeerConnection: NSObject, PeerConnection {
  let pc: RTCPeerConnection
  var onConnectionStateChange: ((PeerConnectionState) -> Void)?
  private var gatheringWaiters: [() -> Void] = []
  private var candidateWaiters: [(Bool) -> Void] = []
  private var closed = false
  private let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

  init(factory: RTCPeerConnectionFactory, configuration: RTCConfiguration) throws {
    guard
      let pc = factory.peerConnection(
        with: configuration, constraints: constraints, delegate: nil)
    else { throw OctoroomError.connectionFailed("couldn't create a peer connection") }
    self.pc = pc
    super.init()
    pc.delegate = self
  }

  var connectionState: PeerConnectionState { PeerConnectionState(pc.connectionState) }

  var signalingState: SignalingState {
    switch pc.signalingState {
    case .stable: .stable
    case .haveLocalOffer: .haveLocalOffer
    case .haveRemoteOffer: .haveRemoteOffer
    case .haveLocalPrAnswer: .haveLocalPranswer
    case .haveRemotePrAnswer: .haveRemotePranswer
    case .closed: .closed
    @unknown default: .closed
    }
  }

  var localSDP: String? { pc.localDescription?.sdp }

  var transceivers: [any Transceiver] { pc.transceivers.map(WebRTCTransceiver.init) }

  func addTransceiver(sending track: any LocalMediaTrack) throws -> any Transceiver {
    guard let rtc = (track as? WebRTCTrackProviding)?.rtcTrack else {
      throw OctoroomError.media("not a WebRTC track")
    }
    let init_ = RTCRtpTransceiverInit()
    init_.direction = .sendOnly
    init_.streamIds = [UUID().uuidString]
    guard let transceiver = pc.addTransceiver(with: rtc, init: init_) else {
      throw OctoroomError.media("couldn't add a transceiver")
    }
    return WebRTCTransceiver(transceiver)
  }

  func addTransceiver(kind: MediaKind) throws -> any Transceiver {
    let init_ = RTCRtpTransceiverInit()
    init_.direction = .sendOnly
    guard let transceiver = pc.addTransceiver(of: kind == .audio ? .audio : .video, init: init_) else {
      throw OctoroomError.media("couldn't add a transceiver")
    }
    return WebRTCTransceiver(transceiver)
  }

  func createOffer() async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      pc.offer(for: constraints) { sdp, error in
        if let sdp { continuation.resume(returning: sdp.sdp) } else { continuation.resume(throwing: error ?? OctoroomError.media("createOffer failed")) }
      }
    }
  }

  func createAnswer() async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      pc.answer(for: constraints) { sdp, error in
        if let sdp { continuation.resume(returning: sdp.sdp) } else { continuation.resume(throwing: error ?? OctoroomError.media("createAnswer failed")) }
      }
    }
  }

  func setLocalDescription(_ type: SDPType, sdp: String) async throws {
    let description = RTCSessionDescription(type: RTCSdpType(type), sdp: sdp)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      pc.setLocalDescription(description) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  func setRemoteDescription(_ type: SDPType, sdp: String) async throws {
    let description = RTCSessionDescription(type: RTCSdpType(type), sdp: sdp)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      pc.setRemoteDescription(description) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  func iceGatheringComplete(timeout: Duration) async {
    if closed || pc.iceGatheringState == .complete { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      var done = false
      let finish = {
        guard !done else { return }
        done = true
        continuation.resume()
      }
      gatheringWaiters.append(finish)
      Task {
        try? await Task.sleep(for: timeout)
        finish()
      }
    }
  }

  func firstIceCandidate(timeout: Duration) async -> Bool {
    if closed { return false }
    if hasCandidate { return true }
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      var done = false
      let finish = { (found: Bool) in
        guard !done else { return }
        done = true
        continuation.resume(returning: found)
      }
      candidateWaiters.append(finish)
      Task {
        try? await Task.sleep(for: timeout)
        finish(false)
      }
    }
  }

  private var hasCandidate: Bool {
    pc.iceGatheringState == .complete
      || (pc.localDescription?.sdp.contains("\na=candidate:") ?? false)
  }

  private func wakeCandidateWaiters(_ found: Bool) {
    let waiters = candidateWaiters
    candidateWaiters = []
    for waiter in waiters { waiter(found) }
  }

  fileprivate func candidateGathered() {
    if hasCandidate { wakeCandidateWaiters(true) }
  }

  func stats() async -> [StatsEntry] {
    let report: [StatsEntry] = await withCheckedContinuation { continuation in
      pc.statistics { report in
        let entries = report.statistics.values.map { stat in
          StatsEntry(
            type: stat.type,
            kind: stat.values["kind"] as? String,
            mid: stat.values["mid"] as? String,
            trackIdentifier: stat.values["trackIdentifier"] as? String,
            audioLevel: (stat.values["audioLevel"] as? NSNumber)?.doubleValue)
        }
        continuation.resume(returning: entries)
      }
    }
    return report
  }

  func close() {
    closed = true
    pc.delegate = nil
    pc.close()
    let waiters = gatheringWaiters
    gatheringWaiters = []
    for waiter in waiters { waiter() }
    wakeCandidateWaiters(false)
  }

  fileprivate func gatheringChanged(_ state: RTCIceGatheringState) {
    guard state == .complete else { return }
    wakeCandidateWaiters(true)
    let waiters = gatheringWaiters
    gatheringWaiters = []
    for waiter in waiters { waiter() }
  }
}

extension WebRTCPeerConnection: RTCPeerConnectionDelegate {
  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState
  ) {
    let state = PeerConnectionState(newState)
    Task { @MainActor in self.onConnectionStateChange?(state) }
  }

  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState
  ) {
    Task { @MainActor in self.gatheringChanged(newState) }
  }

  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState
  ) {}
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
  nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState
  ) {}
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
    Task { @MainActor in self.candidateGathered() }
  }
  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]
  ) {}
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

@MainActor
final class WebRTCTransceiver: Transceiver {
  let transceiver: RTCRtpTransceiver

  init(_ transceiver: RTCRtpTransceiver) {
    self.transceiver = transceiver
  }

  var mid: String? {
    let mid = transceiver.mid
    return mid.isEmpty ? nil : mid
  }

  var receiverTrack: (any RemoteMediaTrack)? {
    transceiver.receiver.track.map(WebRTCRemoteTrack.init)
  }

  func clearSenderTrack() { transceiver.sender.track = nil }
  func stop() { transceiver.stopInternal() }
}

extension PeerConnectionState {
  init(_ state: RTCPeerConnectionState) {
    switch state {
    case .new: self = .new
    case .connecting: self = .connecting
    case .connected: self = .connected
    case .disconnected: self = .disconnected
    case .failed: self = .failed
    case .closed: self = .closed
    @unknown default: self = .failed
    }
  }
}

extension RTCSdpType {
  init(_ type: SDPType) {
    switch type {
    case .offer: self = .offer
    case .answer: self = .answer
    case .rollback: self = .rollback
    }
  }
}

// MARK: - tracks

/// A track backed by a WebRTC track: what `VideoView` renders.
@MainActor
public protocol WebRTCTrackProviding {
  var rtcTrack: RTCMediaStreamTrack { get }
}

extension WebRTCTrackProviding {
  public var videoTrack: RTCVideoTrack? { rtcTrack as? RTCVideoTrack }
}

@MainActor
public final class WebRTCRemoteTrack: RemoteMediaTrack, WebRTCTrackProviding {
  public let rtcTrack: RTCMediaStreamTrack

  init(_ track: RTCMediaStreamTrack) {
    self.rtcTrack = track
  }

  public var id: String { rtcTrack.trackId }
  public var kind: MediaKind { rtcTrack.kind == kRTCMediaStreamTrackKindVideo ? .video : .audio }

  public func setVolume(_ volume: Double) {
    // RTCAudioSource's volume runs 0...10, with 1 as unchanged.
    (rtcTrack as? RTCAudioTrack)?.source.volume = max(0, min(volume, 10))
  }
}

@MainActor
public final class MicrophoneTrack: LocalMediaTrack, WebRTCTrackProviding {
  public let track: RTCAudioTrack
  public private(set) var isLive = true
  public var rtcTrack: RTCMediaStreamTrack { track }

  init(track: RTCAudioTrack) {
    self.track = track
  }

  public var id: String { track.trackId }
  public var kind: MediaKind { .audio }
  public var isEnabled: Bool {
    get { track.isEnabled }
    set { track.isEnabled = newValue }
  }

  public func stop() {
    isLive = false
    track.isEnabled = false
  }
}

@MainActor
public final class CameraTrack: LocalMediaTrack, WebRTCTrackProviding {
  public let track: RTCVideoTrack
  public let capturer: RTCCameraVideoCapturer
  public let position: AVCaptureDevice.Position
  public private(set) var isLive = true
  public var rtcTrack: RTCMediaStreamTrack { track }

  init(track: RTCVideoTrack, capturer: RTCCameraVideoCapturer, position: AVCaptureDevice.Position) {
    self.track = track
    self.capturer = capturer
    self.position = position
  }

  public var id: String { track.trackId }
  public var kind: MediaKind { .video }
  public var isEnabled: Bool {
    get { track.isEnabled }
    set { track.isEnabled = newValue }
  }

  /// Starts (or switches) capture on `device`, at the format nearest to
  /// `width`x`height`.
  public func start(device: AVCaptureDevice, width: Int32, height: Int32, fps: Int) async throws {
    let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
    let format = formats.min { a, b in
      distance(a, width, height) < distance(b, width, height)
    }
    guard let format else { throw OctoroomError.media("the camera has no formats") }
    let maxFps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
    let rate = min(fps, Int(maxFps))
    let capturer = self.capturer
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      capturer.startCapture(with: device, format: format, fps: rate) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  private func distance(_ format: AVCaptureDevice.Format, _ width: Int32, _ height: Int32) -> Int32 {
    let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    return abs(d.width - width) + abs(d.height - height)
  }

  public func stop() {
    guard isLive else { return }
    isLive = false
    capturer.stopCapture()
  }
}

/// A video track the app feeds frames to. `push` can be called from any thread.
@MainActor
public final class FrameTrack: LocalMediaTrack, WebRTCTrackProviding {
  public let track: RTCVideoTrack
  public nonisolated let sink: FrameSink
  public private(set) var isLive = true
  /// Called once when the track stops, by `stop()` or by its capture ending.
  public var onStop: (() -> Void)?
  public var rtcTrack: RTCMediaStreamTrack { track }

  init(track: RTCVideoTrack, source: RTCVideoSource) {
    self.track = track
    self.sink = FrameSink(source: source)
  }

  public var id: String { track.trackId }
  public var kind: MediaKind { .video }
  public var isEnabled: Bool {
    get { track.isEnabled }
    set { track.isEnabled = newValue }
  }

  public nonisolated func push(_ pixelBuffer: CVPixelBuffer, rotation: RTCVideoRotation = ._0, timestampNs: Int64? = nil) {
    sink.push(pixelBuffer, rotation: rotation, timestampNs: timestampNs)
  }

  public func stop() {
    guard isLive else { return }
    isLive = false
    let onStop = self.onStop
    self.onStop = nil
    onStop?()
  }
}

/// Hands frames to a WebRTC video source, from any thread.
public final class FrameSink: @unchecked Sendable {
  private let source: RTCVideoSource
  private let capturer: RTCVideoCapturer

  init(source: RTCVideoSource) {
    self.source = source
    self.capturer = RTCVideoCapturer(delegate: source)
  }

  public func push(_ pixelBuffer: CVPixelBuffer, rotation: RTCVideoRotation = ._0, timestampNs: Int64? = nil) {
    let time = timestampNs ?? Int64(CACurrentMediaTime() * 1_000_000_000)
    let frame = RTCVideoFrame(
      buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: rotation, timeStampNs: time)
    source.capturer(capturer, didCapture: frame)
  }
}

extension RemoteTrack {
  /// The WebRTC video track to render, for a video track.
  public var videoTrack: RTCVideoTrack? { (media as? WebRTCTrackProviding)?.videoTrack }
}

extension LocalTrack {
  public var videoTrack: RTCVideoTrack? { (media as? WebRTCTrackProviding)?.videoTrack }
}

extension RoomClient {
  /// A room client on the WebRTC engine.
  public convenience init(
    socket: PhoenixSocket, topic: String, params: JSONValue = [:], audio: Bool = true,
    video: Bool = false, engine: WebRTCEngine = WebRTCEngine()
  ) {
    self.init(socket: socket, topic: topic, params: params, engine: engine, audio: audio, video: video)
  }
}
