import Octoroom
import SwiftUI

// A group call against examples/call: join the same room as the browsers
// and hear and see each other. Run the server (`mix run --no-halt` in
// examples/call), then this app; the simulator reaches it on localhost.

@main
struct OctoroomCallApp: App {
  @State private var call = CallModel()

  var body: some Scene {
    WindowGroup {
      Group {
        if let room = call.room {
          CallView(call: call, room: room)
        } else {
          JoinView(call: call)
        }
      }
      .animation(.default, value: call.room == nil)
    }
  }
}

@MainActor
@Observable
final class CallModel {
  var server = "ws://127.0.0.1:4300/socket"
  var roomName = "lobby"
  var name = "iPhone"
  var withCamera = false
  var joining = false
  var error: String?
  var log: [String] = []
  var levels = AudioLevels()
  var usingTestPattern = false

  private(set) var room: RoomClient?
  private let engine = WebRTCEngine()
  private var listener: Task<Void, Never>?
  private var meter: Task<Void, Never>?

  func join() async {
    guard let url = URL(string: server) else { return error = "bad server URL" }
    error = nil
    joining = true
    defer { joining = false }

    let socket = PhoenixSocket(endpoint: url, params: [:])
    let room = RoomClient(
      socket: socket, topic: "room:\(roomName)", params: ["name": .string(name)], engine: engine)
    listen(room)
    do {
      try await room.join()
      self.room = room
      note("joined as \(room.participantId ?? "?")")
      if withCamera { await startCamera() }
      startMeter(room)
    } catch {
      self.error = "join failed: \(error.localizedDescription)"
      socket.disconnect()
    }
  }

  func leave() {
    guard let room else { return }
    room.leave()
    room.socket.disconnect()
    self.room = nil
    meter?.cancel()
    listener?.cancel()
    usingTestPattern = false
  }

  func toggleCamera() async {
    guard let room else { return }
    if room.localTracks[.camera] != nil {
      await room.stop(.camera)
      usingTestPattern = false
    } else {
      await startCamera()
    }
  }

  /// The camera, or a moving test pattern where there is none (the simulator).
  func startCamera() async {
    guard let room else { return }
    do {
      let track: any LocalMediaTrack
      do {
        track = try await engine.openCamera()
        usingTestPattern = false
      } catch OctoroomError.media("no camera") {
        track = TestPattern.start(engine: engine)
        usingTestPattern = true
        note("no camera here: sending a test pattern")
      }
      try await room.publish([.camera: track], owned: true)
    } catch {
      self.error = "camera: \(error.localizedDescription)"
    }
  }

  func shareScreen() async {
    guard let room else { return }
    if room.localTracks[.screen] != nil {
      await room.stop(.screen)
      return
    }
    do {
      try await room.shareScreen()
    } catch {
      self.error = "screen share: \(error.localizedDescription)"
    }
  }

  func name(of participantId: String?) -> String {
    guard let participantId else { return "worker" }
    let p = room?.participants.first { $0.id == participantId }
    return p?.meta["name"]?.stringValue ?? participantId
  }

  private func listen(_ room: RoomClient) {
    listener?.cancel()
    let events = room.events()
    listener = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        switch event {
        case .roomEvent(let e):
          self.note("\(e.participant.meta["name"]?.stringValue ?? e.participant.id) \(e.type)")
        case .reconnecting: self.note("reconnecting…")
        case .reconnected(let resumed): self.note(resumed ? "reconnected (resumed)" : "reconnected (new session)")
        case .connection(let state): self.note("media \(state.rawValue)")
        case .error(let error): self.error = error.localizedDescription
        case .left(let reason):
          self.note("left: \(reason.rawValue)")
          if reason == .closed { self.room = nil }
        default: break
        }
      }
    }
  }

  private func startMeter(_ room: RoomClient) {
    meter?.cancel()
    meter = Task { [weak self] in
      while !Task.isCancelled {
        let levels = await room.levels()
        self?.levels = levels
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
  }

  private func note(_ line: String) {
    log.append(line)
    if log.count > 30 { log.removeFirst() }
  }
}
