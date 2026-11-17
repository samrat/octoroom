import Foundation

public enum OctoroomError: Error, Equatable, LocalizedError {
  /// The server replied with an error; `reason` is its reason, e.g. "room_full".
  case rejected(String)
  /// No reply in time. Carries what timed out.
  case timedOut(String)
  /// The channel left or closed before the reply came.
  case channelClosed
  /// The call doesn't fit the client's state, e.g. publishing before joining.
  case invalidState(String)
  /// The media connection to Cloudflare failed.
  case connectionFailed(String)
  /// The server removed this client from the room.
  case removed
  /// Capturing media failed (a missing device, a denied permission).
  case media(String)

  public var errorDescription: String? {
    switch self {
    case .rejected(let reason): reason
    case .timedOut(let what): "\(what) timed out"
    case .channelClosed: "the channel closed"
    case .invalidState(let message): message
    case .connectionFailed(let message): message
    case .removed: "removed from the room"
    case .media(let message): message
    }
  }
}
