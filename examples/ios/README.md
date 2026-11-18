# Octoroom iOS call demo

A SwiftUI group call on the Swift client. It joins the same rooms as
[examples/call](../call)'s browsers, so a phone, a simulator and browser
tabs can all be in one call.

```sh
cd examples/call && mix run --no-halt      # the server, on 127.0.0.1:4300
cd examples/ios && xcodegen generate       # brew install xcodegen
open OctoroomCall.xcodeproj                # run on a simulator or a phone
```

The simulator reaches the server on `127.0.0.1`. A phone needs the Mac's
LAN address in the Socket URL field, and the server must listen on it
(its `http: [ip: ...]` in `config/config.exs`).

The simulator has no camera, so the app publishes a moving test pattern
as the camera instead. Its audio goes through the Mac's mic and speakers.

Agents in the room are listed with their state (listening, thinking,
speaking, waiting) and the chosen one's transcript, and you can type to
them: examples/call's assistant (turn it on from the agent lab), or
[examples/meet](../meet)'s two, with meet's socket URL
(`ws://127.0.0.1:4000/socket`) and room name. In the simulator, mute
before typing: the Mac's mic hears the agent's reply from its speakers,
which interrupts it.
