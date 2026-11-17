import Foundation

// A Phoenix channels client (the V2 JSON protocol), enough for Octoroom: one
// socket that reconnects with backoff and heartbeats, and channels that
// rejoin after the socket comes back, re-reading their join params each time
// (so a rejoin carries the latest resume token), buffer pushes while not
// joined, and time out pushes that get no reply. It follows phoenix.js's
// behaviour, so the server sees the same client either way.

/// The connection under a `PhoenixSocket`. The default is a
/// `URLSessionWebSocketTask`; tests use a fake.
@MainActor
public protocol SocketTransport: AnyObject {
  var onOpen: (() -> Void)? { get set }
  var onMessage: ((String) -> Void)? { get set }
  /// Called once when the connection closes or fails to open.
  var onClose: ((Error?) -> Void)? { get set }
  func connect()
  func send(_ text: String)
  func disconnect()
}

public typealias SocketTransportFactory = @MainActor (URL) -> any SocketTransport

@MainActor
public final class PhoenixSocket {
  public let endpoint: URL
  private let params: @MainActor () -> [String: String]
  private let makeTransport: SocketTransportFactory
  private let heartbeatInterval: Duration
  private let reconnectAfter: @Sendable (Int) -> Duration

  private var transport: (any SocketTransport)?
  private var channels: [PhoenixChannel] = []
  private var sendBuffer: [String] = []
  private var ref = 0
  private var pendingHeartbeat: String?
  private var heartbeatTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var reconnectTries = 0
  private var closedByUser = false
  private var openCallbacks: [() -> Void] = []
  private var closeCallbacks: [() -> Void] = []

  public private(set) var isConnected = false

  /// - Parameters:
  ///   - endpoint: the socket's URL, e.g. `wss://example.com/socket` (no `/websocket`).
  ///   - params: sent as query parameters on every connect, e.g. an auth token.
  public init(
    endpoint: URL,
    params: @escaping @MainActor () -> [String: String] = { [:] },
    heartbeatInterval: Duration = .seconds(30),
    reconnectAfter: @escaping @Sendable (Int) -> Duration = PhoenixSocket.defaultBackoff,
    transport: @escaping SocketTransportFactory = { URLSessionSocketTransport(url: $0) }
  ) {
    self.endpoint = endpoint
    self.params = params
    self.heartbeatInterval = heartbeatInterval
    self.reconnectAfter = reconnectAfter
    self.makeTransport = transport
  }

  public convenience init(
    endpoint: URL,
    params: [String: String],
    transport: @escaping SocketTransportFactory = { URLSessionSocketTransport(url: $0) }
  ) {
    self.init(endpoint: endpoint, params: { params }, transport: transport)
  }

  /// phoenix.js's: quick retries first, then every 5 s.
  public nonisolated static func defaultBackoff(_ tries: Int) -> Duration {
    let steps = [10, 50, 100, 150, 200, 250, 500, 1000, 2000]
    return .milliseconds(tries <= steps.count ? steps[max(tries - 1, 0)] : 5000)
  }

  public func connect() {
    closedByUser = false
    guard transport == nil else { return }
    let transport = makeTransport(socketURL())
    self.transport = transport
    transport.onOpen = { [weak self, weak transport] in
      guard let self, let transport, self.transport === transport else { return }
      self.didOpen()
    }
    transport.onMessage = { [weak self, weak transport] text in
      guard let self, let transport, self.transport === transport else { return }
      self.didReceive(text)
    }
    transport.onClose = { [weak self, weak transport] _ in
      guard let self, let transport, self.transport === transport else { return }
      self.didClose()
    }
    transport.connect()
  }

  public func disconnect() {
    closedByUser = true
    reconnectTask?.cancel()
    reconnectTask = nil
    let transport = self.transport
    didClose()
    transport?.disconnect()
  }

  /// A channel on this socket. `params` is read on every (re)join.
  public func channel(_ topic: String, params: @escaping @MainActor () -> JSONValue = { [:] })
    -> PhoenixChannel
  {
    let channel = PhoenixChannel(topic: topic, params: params, socket: self)
    channels.append(channel)
    return channel
  }

  public func onOpen(_ callback: @escaping () -> Void) { openCallbacks.append(callback) }
  public func onClose(_ callback: @escaping () -> Void) { closeCallbacks.append(callback) }

  // MARK: - internal

  func makeRef() -> String {
    ref += 1
    return String(ref)
  }

  func remove(_ channel: PhoenixChannel) {
    channels.removeAll { $0 === channel }
  }

  func send(joinRef: String?, ref: String?, topic: String, event: String, payload: JSONValue) {
    let message: JSONValue = [
      joinRef.map(JSONValue.string) ?? .null,
      ref.map(JSONValue.string) ?? .null,
      .string(topic), .string(event), payload,
    ]
    guard let data = try? JSONEncoder().encode(message), let text = String(data: data, encoding: .utf8)
    else { return }
    if isConnected, let transport {
      transport.send(text)
    } else {
      sendBuffer.append(text)
    }
  }

  private func socketURL() -> URL {
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
    if !components.path.hasSuffix("/websocket") {
      components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/")
        + "websocket"
    }
    var items = components.queryItems ?? []
    items += params().sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    items.append(URLQueryItem(name: "vsn", value: "2.0.0"))
    components.queryItems = items
    return components.url!
  }

  private func didOpen() {
    isConnected = true
    reconnectTries = 0
    pendingHeartbeat = nil
    let buffered = sendBuffer
    sendBuffer = []
    for text in buffered { transport?.send(text) }
    startHeartbeat()
    for callback in openCallbacks { callback() }
    for channel in channels { channel.socketOpened() }
  }

  private func didClose() {
    let wasOpen = isConnected || transport != nil
    transport?.onOpen = nil
    transport?.onMessage = nil
    transport?.onClose = nil
    transport = nil
    isConnected = false
    heartbeatTask?.cancel()
    heartbeatTask = nil
    pendingHeartbeat = nil
    guard wasOpen else { return }
    for channel in channels { channel.socketClosed() }
    for callback in closeCallbacks { callback() }
    if !closedByUser { scheduleReconnect() }
  }

  private func scheduleReconnect() {
    reconnectTask?.cancel()
    reconnectTries += 1
    let delay = reconnectAfter(reconnectTries)
    reconnectTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled, !self.closedByUser else { return }
      self.connect()
    }
  }

  private func startHeartbeat() {
    heartbeatTask?.cancel()
    let interval = heartbeatInterval
    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard let self, !Task.isCancelled, self.isConnected else { return }
        if self.pendingHeartbeat != nil {
          // No reply to the last one: the connection is dead even if the OS
          // hasn't noticed. Drop it and reconnect.
          let transport = self.transport
          self.didClose()
          transport?.disconnect()
          return
        }
        let ref = self.makeRef()
        self.pendingHeartbeat = ref
        self.send(joinRef: nil, ref: ref, topic: "phoenix", event: "heartbeat", payload: [:])
      }
    }
  }

  private func didReceive(_ text: String) {
    guard let data = text.data(using: .utf8),
      let message = try? JSONDecoder().decode(JSONValue.self, from: data),
      let parts = message.arrayValue, parts.count == 5,
      let topic = parts[2].stringValue, let event = parts[3].stringValue
    else { return }
    let joinRef = parts[0].stringValue
    let ref = parts[1].stringValue
    let payload = parts[4]

    if topic == "phoenix", event == "phx_reply", ref != nil, ref == pendingHeartbeat {
      pendingHeartbeat = nil
      return
    }
    for channel in channels where channel.topic == topic {
      channel.receive(event: event, payload: payload, ref: ref, joinRef: joinRef)
    }
  }
}

@MainActor
public final class PhoenixChannel {
  public enum State: Sendable { case closed, joining, joined, errored, leaving }

  /// The result of each join attempt: the reply's response, or why it failed.
  public typealias JoinReply = Result<JSONValue, OctoroomError>

  public let topic: String
  public private(set) var state: State = .closed
  private let params: @MainActor () -> JSONValue
  private weak var socket: PhoenixSocket?

  private var joinRef: String?
  private var joinTimeout: Duration = .seconds(10)
  private var joinHandler: ((JoinReply) -> Void)?
  private var joinTimer: Task<Void, Never>?
  private var rejoinTimer: Task<Void, Never>?
  private var rejoinTries = 0
  private var bindings: [String: [(JSONValue) -> Void]] = [:]
  private var errorCallbacks: [() -> Void] = []
  private var closeCallbacks: [() -> Void] = []
  private var buffer: [Outgoing] = []
  private var pending: [String: Pending] = [:]

  private struct Outgoing {
    let id: Int
    let event: String
    let payload: JSONValue
  }

  private final class Pending {
    let event: String
    let continuation: CheckedContinuation<JSONValue, Error>
    var timer: Task<Void, Never>?
    init(event: String, continuation: CheckedContinuation<JSONValue, Error>) {
      self.event = event
      self.continuation = continuation
    }
  }

  private var nextOutgoingId = 0
  private var buffered: [Int: Pending] = [:]

  init(topic: String, params: @escaping @MainActor () -> JSONValue, socket: PhoenixSocket) {
    self.topic = topic
    self.params = params
    self.socket = socket
  }

  /// Handles every server push of `event`.
  public func on(_ event: String, _ handler: @escaping (JSONValue) -> Void) {
    bindings[event, default: []].append(handler)
  }

  /// Called when the channel errors: its socket dropped, or the server's
  /// channel process crashed. It rejoins by itself.
  public func onError(_ callback: @escaping () -> Void) { errorCallbacks.append(callback) }

  /// Called when the channel closes: the server stopped it, or `leave()`.
  public func onClose(_ callback: @escaping () -> Void) { closeCallbacks.append(callback) }

  /// Joins, and rejoins whenever the connection comes back. `onReply` gets
  /// the result of every attempt, the first and each rejoin.
  public func join(timeout: Duration = .seconds(10), onReply: @escaping (JoinReply) -> Void) {
    precondition(state == .closed, "join called twice on \(topic)")
    joinTimeout = timeout
    joinHandler = onReply
    sendJoin()
  }

  /// Pushes an event and waits for the server's reply: its response on `ok`,
  /// `OctoroomError.rejected` on `error`. While not joined, the push waits
  /// in a buffer (its timeout running) and goes out once the channel joins.
  public func push(_ event: String, _ payload: JSONValue = [:], timeout: Duration = .seconds(10))
    async throws -> JSONValue
  {
    guard state != .closed, state != .leaving else { throw OctoroomError.channelClosed }
    return try await withCheckedThrowingContinuation { continuation in
      let entry = Pending(event: event, continuation: continuation)
      if canPush {
        send(entry, event: event, payload: payload, timeout: timeout)
      } else {
        nextOutgoingId += 1
        let id = nextOutgoingId
        buffer.append(Outgoing(id: id, event: event, payload: payload))
        buffered[id] = entry
        entry.timer = Task { [weak self] in
          try? await Task.sleep(for: timeout)
          guard let self, !Task.isCancelled, let entry = self.buffered.removeValue(forKey: id)
          else { return }
          self.buffer.removeAll { $0.id == id }
          entry.continuation.resume(throwing: OctoroomError.timedOut(event))
        }
      }
    }
  }

  /// Leaves the channel and stops rejoining it.
  public func leave() {
    guard state != .closed, state != .leaving else { return }
    rejoinTimer?.cancel()
    joinTimer?.cancel()
    let wasJoined = state == .joined
    state = .leaving
    if wasJoined, let socket {
      socket.send(joinRef: joinRef, ref: socket.makeRef(), topic: topic, event: "phx_leave", payload: [:])
    }
    close()
  }

  // MARK: - internal

  private var canPush: Bool { state == .joined && (socket?.isConnected ?? false) }

  private func send(_ entry: Pending, event: String, payload: JSONValue, timeout: Duration) {
    guard let socket else {
      entry.continuation.resume(throwing: OctoroomError.channelClosed)
      return
    }
    let ref = socket.makeRef()
    pending[ref] = entry
    entry.timer = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      guard let self, !Task.isCancelled, let entry = self.pending.removeValue(forKey: ref) else { return }
      entry.continuation.resume(throwing: OctoroomError.timedOut(event))
    }
    socket.send(joinRef: joinRef, ref: ref, topic: topic, event: event, payload: payload)
  }

  private func sendJoin() {
    guard let socket else { return }
    rejoinTimer?.cancel()
    joinTimer?.cancel()
    state = .joining
    let ref = socket.makeRef()
    joinRef = ref
    socket.send(joinRef: ref, ref: ref, topic: topic, event: "phx_join", payload: params())
    let timeout = joinTimeout
    joinTimer = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      guard let self, !Task.isCancelled, self.state == .joining, self.joinRef == ref else { return }
      // Tell the server to drop the late join, if it ever arrives, and try again.
      socket.send(joinRef: ref, ref: socket.makeRef(), topic: self.topic, event: "phx_leave", payload: [:])
      self.state = .errored
      self.joinHandler?(.failure(.timedOut("join")))
      self.scheduleRejoin()
    }
  }

  private func scheduleRejoin() {
    rejoinTimer?.cancel()
    rejoinTries += 1
    let steps: [Duration] = [.seconds(1), .seconds(2), .seconds(5)]
    let delay = rejoinTries <= steps.count ? steps[rejoinTries - 1] : .seconds(10)
    rejoinTimer = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled, self.state == .errored,
        self.socket?.isConnected ?? false
      else { return }
      self.sendJoin()
    }
  }

  func socketOpened() {
    rejoinTries = 0
    if state == .errored { sendJoin() }
  }

  func socketClosed() {
    rejoinTimer?.cancel()
    guard state == .joined || state == .joining else { return }
    joinTimer?.cancel()
    state = .errored
    for callback in errorCallbacks { callback() }
  }

  func receive(event: String, payload: JSONValue, ref: String?, joinRef: String?) {
    let lifecycle = ["phx_close", "phx_error", "phx_join", "phx_reply", "phx_leave"]
    if let joinRef, joinRef != self.joinRef, lifecycle.contains(event) { return }

    switch event {
    case "phx_reply":
      guard let ref else { return }
      if ref == self.joinRef, state == .joining {
        handleJoinReply(payload)
      } else if let entry = pending.removeValue(forKey: ref) {
        entry.timer?.cancel()
        let response = payload["response"] ?? .null
        if payload["status"]?.stringValue == "ok" {
          entry.continuation.resume(returning: response)
        } else {
          let reason = response["reason"]?.stringValue ?? "\(entry.event) failed"
          entry.continuation.resume(throwing: OctoroomError.rejected(reason))
        }
      }
    case "phx_error":
      guard state == .joined || state == .joining else { return }
      joinTimer?.cancel()
      state = .errored
      for callback in errorCallbacks { callback() }
      scheduleRejoin()
    case "phx_close":
      close()
    default:
      for handler in bindings[event] ?? [] { handler(payload) }
    }
  }

  private func handleJoinReply(_ payload: JSONValue) {
    joinTimer?.cancel()
    let response = payload["response"] ?? .null
    if payload["status"]?.stringValue == "ok" {
      state = .joined
      rejoinTries = 0
      let queued = buffer
      buffer = []
      for item in queued {
        guard let entry = buffered.removeValue(forKey: item.id) else { continue }
        entry.timer?.cancel()
        // The remaining time isn't tracked; give the flushed push a full timeout.
        send(entry, event: item.event, payload: item.payload, timeout: joinTimeout)
      }
      joinHandler?(.success(response))
    } else {
      state = .errored
      joinHandler?(.failure(.rejected(response["reason"]?.stringValue ?? "join failed")))
      scheduleRejoin()
    }
  }

  private func close() {
    guard state != .closed else { return }
    state = .closed
    joinTimer?.cancel()
    rejoinTimer?.cancel()
    for entry in pending.values {
      entry.timer?.cancel()
      entry.continuation.resume(throwing: OctoroomError.channelClosed)
    }
    pending = [:]
    for entry in buffered.values {
      entry.timer?.cancel()
      entry.continuation.resume(throwing: OctoroomError.channelClosed)
    }
    buffered = [:]
    buffer = []
    socket?.remove(self)
    for callback in closeCallbacks { callback() }
  }
}

/// The default transport: a `URLSessionWebSocketTask`.
@MainActor
public final class URLSessionSocketTransport: SocketTransport {
  public var onOpen: (() -> Void)?
  public var onMessage: ((String) -> Void)?
  public var onClose: ((Error?) -> Void)?

  private let url: URL
  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var closed = false

  public init(url: URL) {
    self.url = url
  }

  public func connect() {
    let delegate = Delegate(owner: self)
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    let task = session.webSocketTask(with: url)
    self.session = session
    self.task = task
    task.resume()
    receive(task)
  }

  public func send(_ text: String) {
    task?.send(.string(text)) { _ in }
  }

  public func disconnect() {
    task?.cancel(with: .normalClosure, reason: nil)
    finish(nil)
  }

  private func receive(_ task: URLSessionWebSocketTask) {
    Task { [weak self] in
      while true {
        do {
          let message = try await task.receive()
          guard let self, self.task === task else { return }
          switch message {
          case .string(let text): self.onMessage?(text)
          case .data(let data): if let text = String(data: data, encoding: .utf8) { self.onMessage?(text) }
          @unknown default: break
          }
        } catch {
          guard let self, self.task === task else { return }
          self.finish(error)
          return
        }
      }
    }
  }

  fileprivate func opened() {
    guard !closed else { return }
    onOpen?()
  }

  fileprivate func finish(_ error: Error?) {
    guard !closed else { return }
    closed = true
    task = nil
    session?.invalidateAndCancel()
    session = nil
    let onClose = self.onClose
    self.onClose = nil
    onClose?(error)
  }

  private final class Delegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    weak var owner: URLSessionSocketTransport?

    @MainActor init(owner: URLSessionSocketTransport) {
      self.owner = owner
    }

    func urlSession(
      _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
      didOpenWithProtocol protocol: String?
    ) {
      Task { @MainActor [weak owner] in owner?.opened() }
    }

    func urlSession(
      _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
      didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
      Task { @MainActor [weak owner] in owner?.finish(nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      Task { @MainActor [weak owner] in owner?.finish(error) }
    }
  }
}
