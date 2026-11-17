import CoreVideo
import Foundation
import Testing
@testable import Octoroom
@preconcurrency import WebRTC

// The WebRTC adapter against real WebRTC: two peer connections in this
// process, one sending a frame track to the other over loopback.

final class FrameCounter: NSObject, RTCVideoRenderer, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var frames: Int { lock.withLock { count } }
  func setSize(_ size: CGSize) {}
  func renderFrame(_ frame: RTCVideoFrame?) { if frame != nil { lock.withLock { count += 1 } } }
}

func pixelBuffer(_ shade: Int) -> CVPixelBuffer {
  var buffer: CVPixelBuffer?
  CVPixelBufferCreate(
    nil, 320, 240, kCVPixelFormatType_32BGRA,
    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
  CVPixelBufferLockBaseAddress(buffer!, [])
  memset(CVPixelBufferGetBaseAddress(buffer!)!, Int32(shade % 256), CVPixelBufferGetDataSize(buffer!))
  CVPixelBufferUnlockBaseAddress(buffer!, [])
  return buffer!
}

@MainActor
func until(_ what: String, timeout: Duration = .seconds(10), _ check: () -> Bool) async throws {
  let deadline = ContinuousClock.now + timeout
  while !check() {
    if ContinuousClock.now > deadline { Issue.record("timed out waiting for \(what)"); return }
    try await Task.sleep(for: .milliseconds(10))
  }
}

@MainActor
@Suite(.serialized) struct WebRTCEngineTests {
  let engine = WebRTCEngine()

  /// Offer from `a`, answer from `b`, both with their candidates (no trickle, as with Cloudflare).
  func negotiate(_ a: any PeerConnection, _ b: any PeerConnection) async throws {
    try await a.setLocalDescription(.offer, sdp: try await a.createOffer())
    await a.iceGatheringComplete(timeout: .seconds(2))
    try await b.setRemoteDescription(.offer, sdp: a.localSDP!)
    try await b.setLocalDescription(.answer, sdp: try await b.createAnswer())
    await b.iceGatheringComplete(timeout: .seconds(2))
    try await a.setRemoteDescription(.answer, sdp: b.localSDP!)
  }

  @Test func videoFlowsBetweenTwoPeers() async throws {
    let a = try engine.makePeerConnection(iceServers: [])
    let b = try engine.makePeerConnection(iceServers: [])
    defer { a.close(); b.close() }
    var states: [PeerConnectionState] = []
    a.onConnectionStateChange = { states.append($0) }

    let track = engine.makeFrameTrack(screenCast: false)
    let sender = try a.addTransceiver(sending: track)
    #expect(sender.mid == nil)
    try await negotiate(a, b)
    #expect(sender.mid == "0")
    #expect(a.localSDP?.contains("a=sendonly") == true)
    #expect(a.localSDP?.contains("a=candidate") == true)

    try await until("connected") { a.connectionState == .connected && b.connectionState == .connected }
    try await until("the connected callback") { states.contains(.connected) }

    let receiver = try #require(b.transceivers.first { $0.mid == "0" }?.receiverTrack)
    #expect(receiver.kind == .video)
    let counter = FrameCounter()
    let video = try #require((receiver as? WebRTCTrackProviding)?.videoTrack)
    video.add(counter)

    let sink = track.sink
    let feeder = Task.detached {
      var i = 0
      while !Task.isCancelled {
        sink.push(pixelBuffer(i))
        i += 8
        try? await Task.sleep(for: .milliseconds(33))
      }
    }
    defer { feeder.cancel() }
    try await until("frames at the receiver") { counter.frames >= 5 }

    let stats = await b.stats()
    #expect(stats.contains { $0.type == "inbound-rtp" && $0.kind == "video" && $0.mid == "0" })
  }

  @Test func aDisabledTrackKeepsItsTransceiver() async throws {
    let track = engine.makeFrameTrack()
    #expect(track.isEnabled)
    track.isEnabled = false
    #expect(!track.isEnabled)
    #expect(track.isLive)
    var stopped = 0
    track.onStop = { stopped += 1 }
    track.stop()
    track.stop()
    #expect(!track.isLive)
    #expect(stopped == 1)
  }

  @Test func anOfferRollsBack() async throws {
    let a = try engine.makePeerConnection(iceServers: [])
    defer { a.close() }
    let t = try a.addTransceiver(kind: .audio)
    try await a.setLocalDescription(.offer, sdp: try await a.createOffer())
    #expect(a.signalingState == .haveLocalOffer)
    try await a.setLocalDescription(.rollback, sdp: "")
    #expect(a.signalingState == .stable)
    t.stop()
  }

  @Test func stoppedTransceiversLeaveTheNextOffer() async throws {
    let a = try engine.makePeerConnection(iceServers: [])
    let b = try engine.makePeerConnection(iceServers: [])
    defer { a.close(); b.close() }
    let t = try a.addTransceiver(sending: engine.makeFrameTrack())
    try await negotiate(a, b)
    t.stop()
    let offer = try await a.createOffer()
    // A stopped m-section is offered with port 0.
    #expect(offer.contains("m=video 0 "))
  }

  @Test func closingEndsTheWaitForGathering() async throws {
    let a = try engine.makePeerConnection(iceServers: [])
    _ = try a.addTransceiver(kind: .video)
    try await a.setLocalDescription(.offer, sdp: try await a.createOffer())
    let start = ContinuousClock.now
    // Closed mid-wait (the client left), and closed before waiting: both
    // return at once rather than after the timeout.
    Task { a.close() }
    await a.iceGatheringComplete(timeout: .seconds(5))
    await a.iceGatheringComplete(timeout: .seconds(5))
    #expect(ContinuousClock.now - start < .seconds(2))
  }
}
