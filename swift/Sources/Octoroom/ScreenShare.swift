import Foundation
@preconcurrency import WebRTC

#if os(iOS)
  @preconcurrency import ReplayKit
#elseif os(macOS)
  @preconcurrency import ScreenCaptureKit
#endif

// Screen sharing. On iOS this shares the app's own screen (ReplayKit in-app
// capture; sharing the whole device needs a broadcast upload extension,
// which can feed a `FrameTrack` itself). On macOS it shares the main
// display through ScreenCaptureKit, which asks for the Screen Recording
// permission. Screen audio isn't published from native clients.

extension RoomClient {
  /// Shares the screen as `screen`. Stopping from the system UI unpublishes it.
  public func shareScreen(engine: WebRTCEngine) async throws {
    let track = engine.makeFrameTrack(screenCast: true)
    let capture = try await ScreenCapture.start(sink: track.sink)
    track.onStop = { capture.stop() }
    capture.onEnded = { [weak self, weak track] in
      Task { @MainActor in
        track?.stop()
        await self?.stop(.screen)
      }
    }
    do {
      try await publish([.screen: track], owned: true)
    } catch {
      track.stop()
      throw error
    }
  }

  /// Shares the screen with the client's own engine, when it's a `WebRTCEngine`.
  public func shareScreen() async throws {
    guard let engine = engine as? WebRTCEngine else {
      throw OctoroomError.invalidState("shareScreen() needs a WebRTCEngine")
    }
    try await shareScreen(engine: engine)
  }
}

final class ScreenCapture: NSObject, @unchecked Sendable {
  var onEnded: (@Sendable () -> Void)?
  private let sink: FrameSink

  private init(sink: FrameSink) {
    self.sink = sink
  }

  #if os(iOS)
    static func start(sink: FrameSink) async throws -> ScreenCapture {
      let capture = ScreenCapture(sink: sink)
      let recorder = RPScreenRecorder.shared()
      guard recorder.isAvailable else { throw OctoroomError.media("screen recording isn't available") }
      recorder.isMicrophoneEnabled = false
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        recorder.startCapture(
          handler: { [weak capture] sampleBuffer, type, error in
            guard type == .video, error == nil, let capture,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return }
            capture.sink.push(pixelBuffer)
          },
          completionHandler: { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
          })
      }
      return capture
    }

    func stop() {
      RPScreenRecorder.shared().stopCapture { _ in }
    }
  #elseif os(macOS)
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "octoroom.screen")

    static func start(sink: FrameSink) async throws -> ScreenCapture {
      let capture = ScreenCapture(sink: sink)
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      guard let display = content.displays.first else { throw OctoroomError.media("no display") }
      let filter = SCContentFilter(display: display, excludingWindows: [])
      let config = SCStreamConfiguration()
      config.width = display.width * 2
      config.height = display.height * 2
      config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
      config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
      let stream = SCStream(filter: filter, configuration: config, delegate: capture)
      try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
      try await stream.startCapture()
      capture.stream = stream
      return capture
    }

    func stop() {
      let stream = self.stream
      self.stream = nil
      stream?.stopCapture { _ in }
    }
  #endif
}

#if os(macOS)
  extension ScreenCapture: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
      guard type == .screen, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
      // ScreenCaptureKit repeats idle frames without an image; those have no buffer.
      sink.push(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
      onEnded?()
    }
  }
#endif
