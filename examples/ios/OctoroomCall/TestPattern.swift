import CoreGraphics
import CoreVideo
import Foundation
import Octoroom

/// A moving test pattern published as the camera where there's no camera
/// (the simulator): colour bars, a sweeping line and the time.
enum TestPattern {
  @MainActor
  static func start(engine: WebRTCEngine) -> FrameTrack {
    let track = engine.makeFrameTrack(screenCast: false)
    let sink = track.sink
    let task = Task.detached(priority: .userInitiated) {
      var frame = 0
      while !Task.isCancelled {
        if let buffer = draw(frame) { sink.push(buffer) }
        frame += 1
        try? await Task.sleep(for: .milliseconds(66))
      }
    }
    track.onStop = { task.cancel() }
    return track
  }

  private static let colors: [(CGFloat, CGFloat, CGFloat)] = [
    (0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75), (0, 0.75, 0),
    (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75),
  ]

  private static func draw(_ frame: Int) -> CVPixelBuffer? {
    let width = 640, height = 480
    var buffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
      let buffer
    else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard
      let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }

    let bar = CGFloat(width) / CGFloat(colors.count)
    for (i, c) in colors.enumerated() {
      ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
      ctx.fill(CGRect(x: CGFloat(i) * bar, y: 0, width: bar + 1, height: CGFloat(height)))
    }
    // A white line sweeping across, so motion (and freezes) are obvious.
    let x = CGFloat((frame * 8) % width)
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: x, y: 0, width: 12, height: CGFloat(height)))
    // A ticking block in the corner: one step per second.
    let second = (frame / 15) % 10
    ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    ctx.fill(CGRect(x: 20, y: 20, width: 220, height: 40))
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: 24 + CGFloat(second) * 21, y: 24, width: 18, height: 32))
    return buffer
  }
}
