import Foundation
import Observation

// The Octoroom room client, a port of priv/static/octoroom.mjs: same channel
// protocol, same behaviour.
//
// One peer connection to Cloudflare carries what this client publishes
// (sendonly: mic, camera, screen, screen_audio) and every track the server
// pulls into this session. The server decides what this client hears: it
// sends Cloudflare's offers (`renegotiate`), asks for transceivers to be
// closed (`close`), and then says which mid is which track (`tracks`).
// Publishing more later goes through the server's queue too: the server
// asks for an offer (`push`) when it's this session's turn. Signaling is
// serialized: one exchange at a time.
//
// Reconnecting: the server hands out a resume token (refreshed with
// `resume_token`). When the socket reconnects, the channel rejoins with it
// and the server takes this client back as the same participant with the
// same Cloudflare session: the peer connection stays up the whole time, so
// audio keeps flowing. If there was nothing to resume, the client publishes
// again on a new peer connection.

@MainActor
@Observable
public final class RoomClient {
  public enum State: String, Sendable { case idle, joining, joined }

  /// Why the client left: `leave()` was called, the server removed it, or
  /// `join()` failed. Either way it can join again.
  public enum LeaveReason: String, Sendable { case left, closed, failed }

  public enum Event: Sendable {
    case state(State)
    case participants([Participant])
    case roomEvent(RoomEvent)
    /// The remote tracks changed: read `tracks`.
    case tracks
    /// What this client publishes changed: read `localTracks`.
    case local
    case connection(PeerConnectionState)
    case reconnecting
    case reconnected(resumed: Bool)
    case left(LeaveReason)
    case error(any Error)
  }

  /// How long the offer waits for a first ICE candidate. See `connectMedia`.
  public static let iceCandidateWait: Duration = .milliseconds(100)
  public static let connectTimeout: Duration = .seconds(15)
  public static let pushTimeout: Duration = .seconds(30)

  // MARK: observable state

  public private(set) var state: State = .idle
  public private(set) var participantId: String?
  public private(set) var participants: [Participant] = []
  /// Tracks this client receives, in the order they arrived.
  public private(set) var tracks: [RemoteTrack] = []
  /// What this client publishes.
  public private(set) var localTracks: [Source: LocalTrack] = [:]
  public private(set) var connectionState: PeerConnectionState = .new
  public private(set) var isMuted = false

  // MARK: configuration

  @ObservationIgnored public let socket: PhoenixSocket
  @ObservationIgnored public let topic: String
  @ObservationIgnored public let engine: any MediaEngine
  @ObservationIgnored private let params: JSONValue
  @ObservationIgnored private let providedMedia: [Source: any LocalMediaTrack]?
  @ObservationIgnored private let audio: Bool
  @ObservationIgnored private let video: Bool

  // MARK: internals

  @ObservationIgnored private var channel: PhoenixChannel?
  @ObservationIgnored private var pc: (any PeerConnection)?
  @ObservationIgnored private var iceServers: [IceServer] = []
  @ObservationIgnored public private(set) var resumeToken: String?
  @ObservationIgnored private var local: [Source: LocalEntry] = [:]
  @ObservationIgnored private var queueTail: Task<Void, Never>?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var joinWaiter: JoinWaiter?
  @ObservationIgnored private var connectionWaiters: [UUID: (PeerConnectionState?) -> Bool] = [:]
  @ObservationIgnored private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]

  private final class LocalEntry {
    let media: any LocalMediaTrack
    let owned: Bool
    var muted = false
    var transceiver: (any Transceiver)?
    var ready: Task<JSONValue, Error>?

    init(media: any LocalMediaTrack, owned: Bool, ready: Task<JSONValue, Error>? = nil) {
      self.media = media
      self.owned = owned
      self.ready = ready
    }
  }

  private final class JoinWaiter {
    var continuation: CheckedContinuation<JSONValue, Error>?
    var joined = false
  }

  /// - Parameters:
  ///   - socket: a Phoenix socket; `join()` connects it if it isn't.
  ///   - topic: e.g. "room:lobby".
  ///   - params: passed to the room's `join/2`.
  ///   - engine: the media engine (`WebRTCEngine()` from the Octoroom module).
  ///   - media: publish these instead of opening the mic (and camera).
  ///   - audio: open the microphone on join.
  ///   - video: also open and publish the camera on join.
  public init(
    socket: PhoenixSocket, topic: String, params: JSONValue = [:], engine: any MediaEngine,
    media: [Source: any LocalMediaTrack]? = nil, audio: Bool = true, video: Bool = false
  ) {
    self.socket = socket
    self.topic = topic
    self.params = params
    self.engine = engine
    self.providedMedia = media
    self.audio = audio
    self.video = video
  }

  /// A new stream of this client's events. Each call gets its own stream.
  public func events() -> AsyncStream<Event> {
    let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
    let id = UUID()
    subscribers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.subscribers[id] = nil }
    }
    return stream
  }

  private func emit(_ event: Event) {
    for continuation in subscribers.values { continuation.yield(event) }
  }

  private func setState(_ state: State) {
    self.state = state
    emit(.state(state))
  }

  // MARK: - joining and leaving

  /// Joins the room: opens the mic (and camera), publishes them, and plays
  /// what the server subscribes this client to. Returns the join reply.
  @discardableResult
  public func join() async throws -> JSONValue {
    guard state == .idle else { throw OctoroomError.invalidState("can't join while \(state)") }
    setState(.joining)
    // `leave()` mid-join tears down and bumps the generation: this join
    // then stops at its next step instead of carrying on with a dead client.
    let generation = self.generation

    do {
      socket.connect()
      // A closure, so a rejoin sends the latest resume token.
      let channel = socket.channel(topic) { [weak self] in self?.joinParams() ?? [:] }
      self.channel = channel
      bind(channel)

      let waiter = JoinWaiter()
      joinWaiter = waiter
      let reply = try await withCheckedThrowingContinuation { continuation in
        waiter.continuation = continuation
        channel.join(timeout: Self.pushTimeout) { [weak self] result in
          guard let self else { return }
          switch result {
          case .success(let reply):
            if waiter.joined {
              self.onRejoined(reply)
            } else if let continuation = waiter.continuation {
              waiter.joined = true
              waiter.continuation = nil
              continuation.resume(returning: reply)
            }
          case .failure(let error):
            if let continuation = waiter.continuation {
              waiter.continuation = nil
              continuation.resume(throwing: error)
            }
          }
        }
      }
      try checkCurrent(generation)
      onJoinReply(reply)

      try await openLocalMedia(generation)
      try await connectMedia()
      try checkCurrent(generation)
      setState(.joined)
      return reply
    } catch {
      if self.generation == generation { teardown(.failed) }
      throw error
    }
  }

  /// Leaves the room and stops what this client captured.
  public func leave() {
    guard state != .idle else { return }
    teardown(.left)
  }

  private func checkCurrent(_ generation: Int) throws {
    if self.generation != generation { throw OctoroomError.channelClosed }
  }

  private func joinParams() -> JSONValue {
    guard let token = resumeToken, case .object(var object) = params else { return params }
    object["resume_token"] = .string(token)
    return .object(object)
  }

  private func bind(_ channel: PhoenixChannel) {
    channel.on("renegotiate") { [weak self] p in self?.serially { try await $0.onRenegotiate(p) } }
    channel.on("close") { [weak self] p in self?.serially { try await $0.onClose(p) } }
    channel.on("push") { [weak self] p in self?.serially { try await $0.onPush(p) } }
    channel.on("tracks") { [weak self] p in self?.serially { try $0.onTracks(p) } }
    channel.on("gain") { [weak self] p in
      guard let mid = p["mid"]?.stringValue, let gain = p["gain"]?.doubleValue else { return }
      self?.setGain(mid: mid, gain: gain)
    }
    channel.on("room_event") { [weak self] p in self?.onRoomEvent(p) }
    channel.on("resume_token") { [weak self] p in
      if let token = p["token"]?.stringValue { self?.resumeToken = token }
    }
    channel.on("republish") { [weak self] _ in self?.serially { try await $0.restartMedia() } }
    channel.onError { [weak self] in
      if self?.state == .joined { self?.emit(.reconnecting) }
    }
    channel.onClose { [weak self, weak channel] in
      guard let self, let channel, self.channel === channel else { return }
      self.teardown(.closed)
    }
  }

  private func onJoinReply(_ reply: JSONValue) {
    participantId = reply["participant_id"]?.stringValue
    participants = (try? reply["participants"]?.decode([Participant].self)) ?? []
    iceServers = (try? reply["ice_servers"]?.decode([IceServer].self)) ?? []
    resumeToken = reply["resume_token"]?.stringValue
    emit(.participants(participants))
  }

  private func onRejoined(_ reply: JSONValue) {
    onJoinReply(reply)
    let resumed = reply["resumed"]?.boolValue ?? false
    emit(.reconnected(resumed: resumed))
    // A restarted server adopts the session but not the mute flags.
    if resumed {
      for (source, entry) in local where entry.muted {
        Task { _ = try? await self.push("mute", ["source": .string(source.rawValue), "muted": true]) }
      }
    }
    // Nothing to resume (the token expired, or the session was never
    // published): start over as a new participant.
    if !resumed && state == .joined { serially { try await $0.restartMedia() } }
  }

  // The mic (and the camera, with `video`), provided or opened by the engine.
  private func openLocalMedia(_ generation: Int) async throws {
    let owned = providedMedia == nil
    let media: [Source: any LocalMediaTrack]
    if let providedMedia {
      media = providedMedia
    } else {
      media = try await engine.openLocalMedia(audio: audio, video: video)
      // Left while the engine was opening devices (e.g. at a permission prompt).
      if self.generation != generation {
        for track in media.values { track.stop() }
        throw OctoroomError.channelClosed
      }
    }
    for (source, track) in media { local[source] = LocalEntry(media: track, owned: owned) }
    if local.isEmpty { throw OctoroomError.media("nothing to publish: no audio or video track") }
    emitLocal()
  }

  // A peer connection to Cloudflare with every local source published on it.
  private func connectMedia() async throws {
    let pc = try engine.makePeerConnection(iceServers: iceServers)
    self.pc = pc
    pc.onConnectionStateChange = { [weak self, weak pc] state in
      guard let self, let pc, self.pc === pc else { return }
      self.connectionState = state
      self.emit(.connection(state))
      self.connectionWaiters = self.connectionWaiters.filter { !$0.value(state) }
      if state == .failed { self.emit(.error(OctoroomError.connectionFailed("connection failed"))) }
    }

    let entries = Source.allCases.compactMap { source in local[source].map { (source, $0) } }
    for (_, entry) in entries { entry.transceiver = try pc.addTransceiver(sending: entry.media) }
    try await pc.setLocalDescription(.offer, sdp: try await pc.createOffer())
    // Cloudflare is ICE-lite: this client sends the connectivity checks,
    // from whatever candidates it has, to the ones in Cloudflare's answer,
    // and Cloudflare learns this client's address from them. So the offer
    // needn't carry every candidate, and gathering carries on after it's
    // sent. Waiting for gathering to finish cost the full timeout whenever
    // some interface's STUN never answered. The offer waits only for a first
    // candidate, briefly, in case one with none is refused.
    _ = await pc.firstIceCandidate(timeout: Self.iceCandidateWait)

    var mids: [String: JSONValue] = [:]
    for (source, entry) in entries { mids[source.rawValue] = entry.transceiver?.mid.map(JSONValue.string) ?? .null }
    let reply = try await push("publish", ["sdp": .string(pc.localSDP ?? ""), "mids": .object(mids)])
    try await pc.setRemoteDescription(.answer, sdp: reply["sdp"]?.stringValue ?? "")
    try await peerConnected(pc, timeout: Self.connectTimeout)
    _ = try await push("connected")
    for (source, entry) in entries where entry.muted {
      Task { _ = try? await self.push("mute", ["source": .string(source.rawValue), "muted": true]) }
    }
  }

  // The server lost this client's session: publish again on a new one.
  private func restartMedia() async throws {
    guard !local.isEmpty else { return }
    clearRemote()
    pc?.close()
    pc = nil
    try await connectMedia()
  }

  private func peerConnected(_ pc: any PeerConnection, timeout: Duration) async throws {
    if pc.connectionState == .connected { return }
    let id = UUID()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      // Returns true when it has resumed the continuation; it's removed then.
      connectionWaiters[id] = { state in
        switch state {
        case .connected:
          continuation.resume()
        case .failed:
          continuation.resume(throwing: OctoroomError.connectionFailed("connection to Cloudflare failed"))
        case nil:
          continuation.resume(throwing: OctoroomError.channelClosed)
        default:
          return false
        }
        return true
      }
      Task { [weak self] in
        try? await Task.sleep(for: timeout)
        guard let self, self.connectionWaiters.removeValue(forKey: id) != nil else { return }
        continuation.resume(throwing: OctoroomError.timedOut("connection to Cloudflare"))
      }
    }
  }

  private func clearRemote() {
    tracks = []
    emit(.tracks)
  }

  private func teardown(_ reason: LeaveReason) {
    generation += 1
    queueTail = nil
    if let continuation = joinWaiter?.continuation {
      joinWaiter?.continuation = nil
      continuation.resume(throwing: OctoroomError.channelClosed)
    }
    joinWaiter = nil
    let waiters = connectionWaiters
    connectionWaiters = [:]
    for waiter in waiters.values { _ = waiter(nil) }

    clearRemote()
    pc?.close()
    pc = nil
    connectionState = .closed
    for entry in local.values where entry.owned { entry.media.stop() }
    local = [:]
    emitLocal()
    let channel = self.channel
    self.channel = nil
    if reason != .closed { channel?.leave() }
    participants = []
    participantId = nil
    resumeToken = nil
    isMuted = false
    emit(.participants([]))
    emit(.left(reason))
    if reason == .closed { emit(.error(OctoroomError.removed)) }
    setState(.idle)
  }

  // MARK: - publishing

  /// Mutes or unmutes the mic.
  public func setMuted(_ muted: Bool) {
    isMuted = muted
    mute(.mic, muted)
  }

  /// Mutes or unmutes a published source. The track keeps its transceiver
  /// and keeps sending (silence, or black frames), so nothing renegotiates;
  /// other participants see `participant.track(source)?.muted`.
  public func mute(_ source: Source, _ muted: Bool) {
    guard let entry = local[source] else { return }
    entry.muted = muted
    entry.media.isEnabled = !muted
    if source == .mic { isMuted = muted }
    if state == .joined {
      Task { _ = try? await self.push("mute", ["source": .string(source.rawValue), "muted": .bool(muted)]) }
    }
    emitLocal()
  }

  /// Turns the camera on: a track you give, or one the engine opens.
  public func startCamera(_ track: (any LocalMediaTrack)? = nil) async throws {
    if let track { return try await publish([.camera: track]) }
    let camera = try await engine.openCamera()
    try await publish([.camera: camera], owned: true)
  }

  /// Publishes tracks by source, e.g. `[.camera: track]`, after joining.
  /// With `owned`, the tracks are stopped when unpublished.
  public func publish(_ tracks: [Source: any LocalMediaTrack], owned: Bool = false) async throws {
    guard state == .joined else { throw OctoroomError.invalidState("can't publish while \(state)") }
    if let taken = tracks.keys.first(where: { local[$0] != nil }) {
      throw OctoroomError.invalidState("\(taken.rawValue) is already published")
    }

    let sources = Source.allCases.filter { tracks[$0] != nil }
    let request = Task { try await self.push("publish_tracks", ["sources": .array(sources.map { .string($0.rawValue) })]) }
    for source in sources {
      local[source] = LocalEntry(media: tracks[source]!, owned: owned, ready: request)
    }
    emitLocal()

    do {
      _ = try await request.value
    } catch {
      // The session is being published again from scratch, these included.
      if case .rejected("republishing") = error as? OctoroomError { return }
      for source in sources {
        guard let entry = local[source], entry.ready == request else { continue }
        local[source] = nil
        if owned { entry.media.stop() }
      }
      emitLocal()
      throw error
    }
  }

  /// Stops publishing a source: everyone's pulls of it close, then its transceiver does.
  public func stop(_ source: Source) async {
    guard let entry = local[source] else { return }
    _ = try? await entry.ready?.value
    guard local[source] === entry else { return }
    // Stop sending now (and turn the camera light off); the server closes
    // the transceiver once nobody pulls the track any more.
    entry.transceiver?.clearSenderTrack()
    if entry.owned { entry.media.stop() }
    local[source] = nil
    emitLocal()
    if state == .joined { _ = try? await push("unpublish", ["source": .string(source.rawValue)]) }
  }

  private func emitLocal() {
    var result: [Source: LocalTrack] = [:]
    for (source, entry) in local {
      result[source] = LocalTrack(source: source, media: entry.media, muted: entry.muted)
    }
    localTracks = result
    emit(.local)
  }

  /// Audio levels (0...1) per remote participant and for the local mic.
  public func levels() async -> AudioLevels {
    var result = AudioLevels()
    guard let pc else { return result }
    let micId = local[.mic]?.media.id
    for entry in await pc.stats() where entry.kind == "audio" {
      if entry.type == "inbound-rtp", let mid = entry.mid,
        let track = tracks.first(where: { $0.mid == mid }), track.source == .mic,
        let participantId = track.participantId
      {
        result.remote[participantId] = entry.audioLevel ?? 0
      } else if entry.type == "media-source", entry.trackIdentifier == micId {
        result.local = entry.audioLevel ?? 0
      }
    }
    return result
  }

  // MARK: - signaling

  private func serially(_ fn: @escaping (RoomClient) async throws -> Void) {
    let previous = queueTail
    let generation = self.generation
    queueTail = Task { [weak self] in
      await previous?.value
      guard let self, self.generation == generation else { return }
      do {
        try await fn(self)
      } catch {
        if self.generation == generation { self.emit(.error(error)) }
      }
    }
  }

  private func requirePC() throws -> any PeerConnection {
    guard let pc else { throw OctoroomError.invalidState("no peer connection") }
    return pc
  }

  private func onRenegotiate(_ p: JSONValue) async throws {
    let pc = try requirePC()
    try await pc.setRemoteDescription(.offer, sdp: p["sdp"]?.stringValue ?? "")
    try await pc.setLocalDescription(.answer, sdp: try await pc.createAnswer())
    _ = try await push("answer", ["op_id": p["op_id"] ?? .null, "sdp": .string(pc.localSDP ?? "")])
  }

  // The server's turn for this client to publish more: add the sources'
  // transceivers and offer them.
  private func onPush(_ p: JSONValue) async throws {
    let pc = try requirePC()
    let sources = (p["sources"]?.arrayValue ?? []).compactMap { $0.stringValue }
    var added: [(String, any Transceiver)] = []
    for name in sources {
      let source = Source(rawValue: name)
      let entry = source.flatMap { local[$0] }
      // Stopped while queued: publish nothing and let the server unpublish it.
      let transceiver: any Transceiver
      if let entry, entry.media.isLive {
        transceiver = try pc.addTransceiver(sending: entry.media)
      } else {
        transceiver = try pc.addTransceiver(kind: source?.kind ?? .audio)
      }
      entry?.transceiver = transceiver
      added.append((name, transceiver))
    }

    do {
      try await pc.setLocalDescription(.offer, sdp: try await pc.createOffer())
      var mids: [String: JSONValue] = [:]
      for (name, t) in added { mids[name] = t.mid.map(JSONValue.string) ?? .null }
      let reply = try await push(
        "push_offer",
        ["op_id": p["op_id"] ?? .null, "sdp": .string(pc.localSDP ?? ""), "mids": .object(mids)])
      try await pc.setRemoteDescription(.answer, sdp: reply["sdp"]?.stringValue ?? "")
    } catch {
      if pc.signalingState == .haveLocalOffer { try? await pc.setLocalDescription(.rollback, sdp: "") }
      for (_, t) in added { t.stop() }
      throw error
    }
    // The server pulls them for others once they flow.
    _ = try await push("connected")
  }

  private func onClose(_ p: JSONValue) async throws {
    let pc = try requirePC()
    let mids = Set((p["mids"]?.arrayValue ?? []).compactMap { $0.stringValue })
    for t in pc.transceivers where t.mid.map(mids.contains) ?? false { t.stop() }
    try await pc.setLocalDescription(.offer, sdp: try await pc.createOffer())
    let reply = try await push("close_offer", ["op_id": p["op_id"] ?? .null, "sdp": .string(pc.localSDP ?? "")])
    try await pc.setRemoteDescription(.answer, sdp: reply["sdp"]?.stringValue ?? "")
  }

  private func onTracks(_ p: JSONValue) throws {
    var added = try p["added"]?.decode([TrackInfo].self) ?? []
    var removed = Set((p["removed"]?.arrayValue ?? []).compactMap { $0.stringValue })

    // After a reconnect the server sends everything this client hears: drop
    // what it didn't mention, and keep what's unchanged playing as it is.
    if p["reset"]?.boolValue == true {
      let now = Dictionary(added.map { ($0.mid, $0) }, uniquingKeysWith: { _, last in last })
      removed = Set(tracks.filter { now[$0.mid]?.track != $0.info.track }.map(\.mid))
      added = added.filter { info in tracks.first(where: { $0.mid == info.mid })?.info.track != info.track }
    }

    var next = tracks.filter { !removed.contains($0.mid) }
    let transceivers = pc?.transceivers ?? []
    for info in added {
      guard let media = transceivers.first(where: { $0.mid == info.mid })?.receiverTrack else { continue }
      // Audio plays by itself; video is for the app to show.
      if info.kind == .audio { media.setVolume(info.gain) }
      next.removeAll { $0.mid == info.mid }
      next.append(RemoteTrack(info: info, media: media))
    }
    tracks = next
    emit(.tracks)
  }

  private func setGain(mid: String, gain: Double) {
    guard let index = tracks.firstIndex(where: { $0.mid == mid }) else { return }
    var info = tracks[index].info
    info.gain = gain
    let media = tracks[index].media
    if info.kind == .audio { media.setVolume(gain) }
    tracks[index] = RemoteTrack(info: info, media: media)
    emit(.tracks)
  }

  private func onRoomEvent(_ p: JSONValue) {
    guard let type = p["type"]?.stringValue,
      let participant = try? p["participant"]?.decode(Participant.self)
    else { return }
    switch type {
    case "joined":
      participants = participants.filter { $0.id != participant.id } + [participant]
    case "left":
      participants = participants.filter { $0.id != participant.id }
    default:
      participants = participants.map { $0.id == participant.id ? participant : $0 }
    }
    emit(.roomEvent(RoomEvent(type: type, participant: participant)))
    emit(.participants(participants))
  }

  private func push(_ event: String, _ payload: JSONValue = [:]) async throws -> JSONValue {
    guard let channel else { throw OctoroomError.channelClosed }
    return try await channel.push(event, payload, timeout: Self.pushTimeout)
  }
}
