import Foundation

public enum MediaKind: String, Codable, Sendable {
  case audio
  case video
}

/// What a participant publishes. Each participant publishes at most one
/// track per source.
public enum Source: String, Codable, Sendable, CaseIterable {
  case mic
  case camera
  case screen
  case screenAudio = "screen_audio"

  public var kind: MediaKind {
    switch self {
    case .mic, .screenAudio: .audio
    case .camera, .screen: .video
    }
  }
}

/// A published source as other participants see it.
public struct PublishedTrack: Codable, Sendable, Hashable {
  public var kind: MediaKind
  public var muted: Bool
}

/// Someone in the room: its id, the metadata the room's `join/2` returned,
/// and the sources it publishes that are flowing.
public struct Participant: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var meta: JSONValue
  /// Keyed by source name ("mic", "camera", "screen", "screen_audio").
  public var tracks: [String: PublishedTrack]

  public init(id: String, meta: JSONValue = [:], tracks: [String: PublishedTrack] = [:]) {
    self.id = id
    self.meta = meta
    self.tracks = tracks
  }

  public func track(_ source: Source) -> PublishedTrack? { tracks[source.rawValue] }

  enum CodingKeys: CodingKey { case id, meta, tracks }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    meta = try c.decodeIfPresent(JSONValue.self, forKey: .meta) ?? [:]
    tracks = try c.decodeIfPresent([String: PublishedTrack].self, forKey: .tracks) ?? [:]
  }
}

/// A room event: someone joined, left, or changed (published, muted, ...).
public struct RoomEvent: Sendable, Hashable {
  public var type: String
  public var participant: Participant
}

/// A server-side participant (an AI agent, a recorder) this client sees:
/// it's subscribed to one of the worker's outputs. `state` and
/// `attributes` are whatever the worker set as its presence.
public struct Worker: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  /// Its audio outputs' track names.
  public var outputs: [String]
  /// Its data-only outputs' names.
  public var data: [String]
  public var state: String?
  public var attributes: JSONValue

  public init(
    id: String, outputs: [String] = [], data: [String] = [], state: String? = nil,
    attributes: JSONValue = [:]
  ) {
    self.id = id
    self.outputs = outputs
    self.data = data
    self.state = state
    self.attributes = attributes
  }

  enum CodingKeys: CodingKey { case id, outputs, data, state, attributes }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    outputs = try c.decodeIfPresent([String].self, forKey: .outputs) ?? []
    data = try c.decodeIfPresent([String].self, forKey: .data) ?? []
    state = try c.decodeIfPresent(String.self, forKey: .state)
    attributes = try c.decodeIfPresent(JSONValue.self, forKey: .attributes) ?? [:]
  }
}

/// An event from a worker's `notify:`, on one of its outputs this client
/// is subscribed to.
public struct WorkerEvent: Sendable, Hashable {
  public var worker: String
  public var output: String
  public var type: String
  public var data: JSONValue

  public init(worker: String, output: String, type: String, data: JSONValue) {
    self.worker = worker
    self.output = output
    self.type = type
    self.data = data
  }
}

/// What the server says about a track it pulled into this session.
public struct TrackInfo: Codable, Sendable, Hashable {
  public var mid: String
  /// The room-scoped track name: "<participant id>/<source>", or a worker output's name.
  public var track: String
  public var kind: MediaKind
  /// Nil for a worker's output.
  public var source: Source?
  public var participantId: String?
  public var workerId: String?
  public var gain: Double

  enum CodingKeys: String, CodingKey {
    case mid, track, kind, source, gain
    case participantId = "participant_id"
    case workerId = "worker_id"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    mid = try c.decode(String.self, forKey: .mid)
    track = try c.decode(String.self, forKey: .track)
    kind = try c.decodeIfPresent(MediaKind.self, forKey: .kind) ?? .audio
    // An unknown source reads as none rather than failing the whole event.
    source = (try? c.decodeIfPresent(String.self, forKey: .source)).flatMap { $0.flatMap(Source.init) }
    participantId = try c.decodeIfPresent(String.self, forKey: .participantId)
    workerId = try c.decodeIfPresent(String.self, forKey: .workerId)
    gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1
  }

  public init(
    mid: String, track: String, kind: MediaKind, source: Source?, participantId: String?,
    workerId: String? = nil, gain: Double = 1
  ) {
    self.mid = mid
    self.track = track
    self.kind = kind
    self.source = source
    self.participantId = participantId
    self.workerId = workerId
    self.gain = gain
  }
}

/// A track this client receives. Audio plays by itself; show a video's
/// `media` in a `VideoView`.
@MainActor
public struct RemoteTrack: Identifiable {
  public let info: TrackInfo
  public let media: any RemoteMediaTrack

  public nonisolated var id: String { info.mid }
  public var mid: String { info.mid }
  public var kind: MediaKind { info.kind }
  public var source: Source? { info.source }
  public var participantId: String? { info.participantId }
  public var workerId: String? { info.workerId }
  public var gain: Double { info.gain }
}

/// A source this client publishes.
@MainActor
public struct LocalTrack {
  public let source: Source
  public let media: any LocalMediaTrack
  public let muted: Bool
}

public struct IceServer: Codable, Sendable, Hashable {
  public var urls: [String]
  public var username: String?
  public var credential: String?

  public init(urls: [String], username: String? = nil, credential: String? = nil) {
    self.urls = urls
    self.username = username
    self.credential = credential
  }

  enum CodingKeys: CodingKey { case urls, username, credential }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    if let one = try? c.decode(String.self, forKey: .urls) {
      urls = [one]
    } else {
      urls = try c.decode([String].self, forKey: .urls)
    }
    username = try c.decodeIfPresent(String.self, forKey: .username)
    credential = try c.decodeIfPresent(String.self, forKey: .credential)
  }
}

/// Audio levels (0...1) from WebRTC stats.
public struct AudioLevels: Sendable, Hashable {
  public var local: Double = 0
  /// By participant id.
  public var remote: [String: Double] = [:]

  public init(local: Double = 0, remote: [String: Double] = [:]) {
    self.local = local
    self.remote = remote
  }
}

/// Capture parameters requested by the server for a video source.
public struct CaptureConfig: Codable, Sendable, Hashable {
  public var fps: Double
  public var maxDimension: Int
  public var quality: Double

  public init(fps: Double = 1.0, maxDimension: Int = 1024, quality: Double = 0.75) {
    self.fps = fps
    self.maxDimension = maxDimension
    self.quality = quality
  }

  enum CodingKeys: String, CodingKey {
    case fps, quality
    case maxDimension = "max_dimension"
  }
}

/// A JPEG snapshot captured from a local video track.
public struct CapturedFrame: Sendable, Hashable {
  public var data: Data
  public var mimeType: String
  public var width: Int?
  public var height: Int?

  public init(data: Data, mimeType: String = "image/jpeg", width: Int? = nil, height: Int? = nil) {
    self.data = data
    self.mimeType = mimeType
    self.width = width
    self.height = height
  }
}
