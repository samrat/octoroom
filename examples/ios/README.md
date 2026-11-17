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
