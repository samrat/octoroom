import Octoroom
import SwiftUI

struct JoinView: View {
  @Bindable var call: CallModel

  var body: some View {
    NavigationStack {
      Form {
        Section("Server") {
          TextField("Socket URL", text: $call.server)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
          TextField("Room", text: $call.roomName)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        Section("You") {
          TextField("Name", text: $call.name)
          Toggle("Join with camera", isOn: $call.withCamera)
        }
        Section {
          Button {
            Task { await call.join() }
          } label: {
            HStack {
              Text(call.joining ? "Joining…" : "Join")
              if call.joining { Spacer(); ProgressView() }
            }
          }
          .disabled(call.joining || call.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let error = call.error {
          Section { Text(error).foregroundStyle(.red) }
        }
      }
      .navigationTitle("Octoroom")
    }
  }
}

struct CallView: View {
  let call: CallModel
  let room: RoomClient

  private var videos: [RemoteTrack] { room.tracks.filter { $0.kind == .video } }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          videoGrid
          participantList
          if let error = call.error {
            Text(error).font(.footnote).foregroundStyle(.red)
          }
          logView
        }
        .padding()
      }
      .safeAreaInset(edge: .bottom) { controls }
      .navigationTitle(call.roomName)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Text(room.connectionState.rawValue)
            .font(.caption)
            .foregroundStyle(room.connectionState == .connected ? .green : .orange)
        }
      }
    }
  }

  private var videoGrid: some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
      if let camera = room.localTracks[.camera] {
        tile(label: call.usingTestPattern ? "You (test pattern)" : "You", paused: camera.muted) {
          VideoView(camera, mirrored: !call.usingTestPattern)
        }
      }
      ForEach(videos) { track in
        let paused = room.participants.first { $0.id == track.participantId }?
          .track(track.source ?? .camera)?.muted ?? false
        tile(label: "\(call.name(of: track.participantId)) · \(track.source?.rawValue ?? "video")", paused: paused) {
          VideoView(track, fill: track.source != .screen)
        }
      }
    }
  }

  private func tile<V: View>(label: String, paused: Bool, @ViewBuilder video: () -> V) -> some View {
    ZStack(alignment: .bottomLeading) {
      video()
        .frame(maxWidth: .infinity)
        .aspectRatio(4 / 3, contentMode: .fit)
        .background(.black)
      if paused {
        Text("Video paused").font(.caption).foregroundStyle(.white)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.black)
      }
      Text(label)
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(6)
    }
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private var participantList: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("In the room (\(room.participants.count))").font(.headline)
      ForEach(room.participants) { p in
        let me = p.id == room.participantId
        let level = me ? call.levels.local : (call.levels.remote[p.id] ?? 0)
        HStack {
          Circle()
            .fill(level > 0.05 ? Color.green : Color.secondary.opacity(0.3))
            .frame(width: 10, height: 10)
          Text((p.meta["name"]?.stringValue ?? p.id) + (me ? " (you)" : ""))
          Spacer()
          Text(sources(p)).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func sources(_ p: Participant) -> String {
    Source.allCases.compactMap { source in
      p.track(source).map { source.rawValue + ($0.muted ? " (muted)" : "") }
    }.joined(separator: ", ")
  }

  private var logView: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Events").font(.headline)
      ForEach(Array(call.log.suffix(8).enumerated()), id: \.offset) { _, line in
        Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
      }
    }
  }

  private var controls: some View {
    let camera = room.localTracks[.camera]
    return HStack(spacing: 12) {
      control(room.isMuted ? "mic.slash.fill" : "mic.fill", room.isMuted ? "Unmute" : "Mute", active: room.isMuted) {
        room.setMuted(!room.isMuted)
      }
      control(camera == nil ? "video.slash" : "video.fill", camera == nil ? "Camera" : "Cam off", active: camera != nil) {
        Task { await call.toggleCamera() }
      }
      control("pause.rectangle", camera?.muted == true ? "Resume" : "Pause", active: camera?.muted == true) {
        room.mute(.camera, !(camera?.muted ?? false))
      }
      .disabled(camera == nil)
      control("rectangle.on.rectangle", room.localTracks[.screen] == nil ? "Share" : "Stop", active: room.localTracks[.screen] != nil) {
        Task { await call.shareScreen() }
      }
      control("phone.down.fill", "Leave", active: false, tint: .red) {
        call.leave()
      }
    }
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity)
    .background(.bar)
  }

  private func control(_ icon: String, _ label: String, active: Bool, tint: Color = .accentColor, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 4) {
        Image(systemName: icon).font(.title3)
        Text(label).font(.caption2)
      }
      .frame(width: 60, height: 50)
      .foregroundStyle(active ? .white : tint)
      .background(active ? tint : tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
  }
}
