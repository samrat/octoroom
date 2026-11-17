import SwiftUI
@preconcurrency import WebRTC

/// Shows a video track: a remote one from `room.tracks`, or a local one
/// from `room.localTracks` (mirrored by default, like a mirror).
///
///     ForEach(room.tracks.filter { $0.kind == .video }) { track in
///       VideoView(track)
///     }
///     if let camera = room.localTracks[.camera] { VideoView(camera) }
public struct VideoView: View {
  private let track: RTCVideoTrack?
  private let mirrored: Bool
  private let fill: Bool

  public init(_ track: RemoteTrack, fill: Bool = true) {
    self.track = track.videoTrack
    self.mirrored = false
    self.fill = fill
  }

  public init(_ track: LocalTrack, mirrored: Bool = true, fill: Bool = true) {
    self.track = track.videoTrack
    self.mirrored = mirrored
    self.fill = fill
  }

  public init(rtcTrack: RTCVideoTrack?, mirrored: Bool = false, fill: Bool = true) {
    self.track = rtcTrack
    self.mirrored = mirrored
    self.fill = fill
  }

  public var body: some View {
    Renderer(track: track, fill: fill)
      .scaleEffect(x: mirrored ? -1 : 1, y: 1)
      .clipped()
  }
}

#if os(iOS)
  private struct Renderer: UIViewRepresentable {
    let track: RTCVideoTrack?
    let fill: Bool

    func makeUIView(context: Context) -> RTCMTLVideoView {
      let view = RTCMTLVideoView(frame: .zero)
      view.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
      return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
      view.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
      context.coordinator.attach(track, to: view)
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
      coordinator.attach(nil, to: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
  }
#elseif os(macOS)
  private struct Renderer: NSViewRepresentable {
    let track: RTCVideoTrack?
    let fill: Bool

    func makeNSView(context: Context) -> RTCMTLNSVideoView {
      RTCMTLNSVideoView(frame: .zero)
    }

    func updateNSView(_ view: RTCMTLNSVideoView, context: Context) {
      context.coordinator.attach(track, to: view)
    }

    static func dismantleNSView(_ view: RTCMTLNSVideoView, coordinator: Coordinator) {
      coordinator.attach(nil, to: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
  }
#endif

@MainActor
private final class Coordinator {
  private var track: RTCVideoTrack?

  func attach(_ track: RTCVideoTrack?, to view: RTCVideoRenderer) {
    guard track !== self.track else { return }
    self.track?.remove(view)
    self.track = track
    track?.add(view)
  }
}
