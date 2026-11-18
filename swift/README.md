# Octoroom for Swift

A native client for iOS 17+ and macOS 14+, a port of the browser client
(`priv/static/octoroom.mjs`). It speaks the same channel protocol, so your
server needs no changes. An app joins the same rooms as browsers, under the
same `subscriptions/2` policy, and resumes the same way after a dropped
connection.

```swift
// Package.swift
.package(url: "https://github.com/<you>/octoroom.git", branch: "main")
// target dependency
.product(name: "Octoroom", package: "octoroom")
```

The package manifest sits at the repository root so SwiftPM can depend on
the repo. The sources live here in `swift/`. WebRTC comes from
[stasel/WebRTC](https://github.com/stasel/WebRTC), Google's build as an
xcframework.

## Use

```swift
import Octoroom
import SwiftUI

@MainActor
func makeRoom() -> RoomClient {
  let socket = PhoenixSocket(endpoint: URL(string: "wss://example.com/socket")!,
                             params: ["token": token])
  return RoomClient(socket: socket, topic: "room:lobby", params: ["name": "Ada"], video: true)
}

try await room.join()       // opens the mic (and camera), publishes, plays what the server subscribes
room.setMuted(true)
room.mute(.camera, true)    // sends black frames; nothing renegotiates
try await room.startCamera()
try await room.shareScreen()
await room.stop(.camera)
room.leave()
```

`RoomClient` is `@Observable`, so SwiftUI views read it directly:

```swift
struct CallView: View {
  let room: RoomClient

  var body: some View {
    ForEach(room.tracks.filter { $0.kind == .video }) { track in
      VideoView(track)                       // remote video
    }
    if let camera = room.localTracks[.camera] {
      VideoView(camera)                      // self view, mirrored
    }
    ForEach(room.participants) { p in
      Text(p.meta["name"]?.stringValue ?? p.id)
      if p.track(.camera)?.muted == true { Text("video paused") }
    }
  }
}
```

Remote audio plays by itself, at the gain the server sets. For anything
that isn't state, use `for await event in room.events()`. You get
`.roomEvent`, `.reconnecting`, `.reconnected(resumed:)`, `.connection`,
`.left(reason)` and `.error`. `await room.levels()` returns audio levels
for speaking indicators.

Workers the room shows this client (AI agents, say) are in `room.workers`,
with their presence (`state`, `attributes`); their events come as
`.workerEvent`, and `try await room.send(to: "assistant", ["text": "hi"])`
messages one. For `octoroom_agents` agents, `OctoroomAgents` does the
decoding:

```swift
import OctoroomAgents

let agents = Agents(room: room)              // @Observable
ForEach(agents.agents) { agent in            // id, name, description, state
  Text("\(agent.name): \(agent.state?.rawValue ?? "")")
}
ForEach(agents.transcript("assistant")) { item in Text(item.text) }
try await agents.say("add Acme to the sheet", to: "assistant")
```

## What differs from the browser client

- **Screen sharing** on iOS shares the app's own screen through ReplayKit's
  in-app capture. Sharing the whole device needs a broadcast upload
  extension, which can feed `engine.makeFrameTrack()` itself. On macOS,
  sharing uses ScreenCaptureKit for the main display and needs the Screen
  Recording permission.
- **No `screen_audio`.** Native clients don't publish screen audio.
- **Permissions.** Add `NSMicrophoneUsageDescription` and
  `NSCameraUsageDescription` to your Info.plist. The client asks for
  access when it opens each device.
- **Audio route.** On iOS, `WebRTCEngine(speaker: true)` (the default)
  plays through the loudspeaker, as video calls do. Pass `false` for the
  earpiece. The simulator always keeps WebRTC's default audio session: its
  CoreAudio deadlocks when capture starts in `videoChat` mode.
- **Leaving on quit.** Browsers say goodbye on `pagehide`. An app should
  call `room.leave()` when it's done with the call. Otherwise the server
  holds the participant for the resume grace period.
- **Your own media.** Pass `media: [.camera: track]` to publish tracks you
  make instead of opening the mic and camera. For example, use
  `engine.makeFrameTrack()` and push `CVPixelBuffer`s.

An example app is in [examples/ios](../examples/ios).

## Layout

- `OctoroomCore` has the Phoenix channels client, the room's signaling and
  the data types, behind a `MediaEngine` protocol. It has no WebRTC
  dependency, so its tests run against a fake socket and a fake media
  engine.
- `Octoroom` has the WebRTC engine, mic, camera and screen capture, and
  `VideoView`. It re-exports `OctoroomCore`.
- `OctoroomAgents` has `Agents`: the room's agents, their transcripts and
  typing to them, on top of `RoomClient` (a port of
  `agents/priv/static/octoroom_agents.mjs`).

```sh
bin/test swift   # or plain `swift test`, from the repository root
```
