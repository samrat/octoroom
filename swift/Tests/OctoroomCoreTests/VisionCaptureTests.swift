import Foundation
import Testing
@testable import OctoroomCore

@MainActor
@Suite struct VisionCaptureTests {
  private let sampleJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])

  private func joinRoom(
    initialCapture: JSONValue = ["sources": [:]],
    capture: Bool = true
  ) async throws -> (RoomClient, FakeServer, FakeLocalTrack) {
    let server = FakeServer()
    let socket = PhoenixSocket(
      endpoint: URL(string: "wss://example.com/socket")!, transport: server.factory())
    let engine = FakeEngine()
    let mic = FakeLocalTrack(kind: .audio)
    let cam = FakeLocalTrack(kind: .video)
    cam.snapshotFrame = CapturedFrame(data: sampleJPEG, width: 640, height: 360)

    let room = RoomClient(
      socket: socket, topic: "room:vision", engine: engine,
      media: [.mic: mic, .camera: cam], capture: capture)

    let joinTask = Task { try await room.join() }
    let joinMsg = try await server.next("phx_join")
    server.reply(joinMsg, [
      "participant_id": "alice",
      "participants": [["id": "alice", "meta": [:], "tracks": [:]]],
      "ice_servers": [],
      "resume_token": "tok",
      "workers": [],
      "capture": initialCapture,
    ])
    let pub = try await server.next("publish")
    server.reply(pub, ["sdp": "answer"])
    engine.pc.setState(.connected)
    let conn = try await server.next("connected")
    server.reply(conn)
    _ = try await joinTask.value
    return (room, server, cam)
  }

  @Test func autoCapturesOnServerDirectiveAndPausesOnMuteOrOptOut() async throws {
    let (room, server, _) = try await joinRoom()
    #expect(room.capturing.isEmpty)

    server.push("room:vision", "capture", [
      "sources": [
        "camera": ["fps": 2.0, "max_dimension": 768, "quality": 0.75]
      ]
    ])

    let frame = try await server.next("video_frame")
    #expect(frame.payload["source"]?.stringValue == "camera")
    #expect(frame.payload["mime_type"]?.stringValue == "image/jpeg")
    #expect(frame.payload["width"]?.doubleValue == 640)
    #expect(frame.payload["height"]?.doubleValue == 360)
    #expect(frame.payload["data"]?.stringValue == sampleJPEG.base64EncodedString())
    server.reply(frame)
    #expect(room.capturing == [.camera])

    // Muting pauses capture immediately.
    room.mute(.camera, true)
    #expect(room.capturing.isEmpty)

    // Unmuting resumes capture.
    room.mute(.camera, false)
    #expect(room.capturing == [.camera])
    let frame2 = try await server.next("video_frame")
    server.reply(frame2)

    // Client-side opt-out pauses capture even with active directive.
    room.setCaptureEnabled(false)
    #expect(room.capturing.isEmpty)

    room.setCaptureEnabled(true)
    #expect(room.capturing == [.camera])

    // Empty directive stops capture.
    server.push("room:vision", "capture", ["sources": [:]])
    #expect(room.capturing.isEmpty)

    room.leave()
  }

  @Test func honorsInitialCaptureDirectiveAndOptOutConstructor() async throws {
    let directive: JSONValue = [
      "sources": ["camera": ["fps": 1.0, "max_dimension": 768, "quality": 0.75]]
    ]

    let (room, server, _) = try await joinRoom(initialCapture: directive, capture: true)
    let frame = try await server.next("video_frame")
    #expect(frame.payload["source"]?.stringValue == "camera")
    server.reply(frame)
    #expect(room.capturing == [.camera])
    room.leave()
    #expect(room.capturing.isEmpty)

    let (optedOut, server2, _) = try await joinRoom(initialCapture: directive, capture: false)
    #expect(optedOut.capturing.isEmpty)
    #expect(!(await server2.sends("video_frame", within: .milliseconds(80))))
    optedOut.leave()
  }
}
