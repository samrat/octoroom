# Octoroom

Voice and video rooms for Phoenix apps. Cloudflare Realtime SFU carries the
media; your app decides who is in a room, who hears and sees whom, and which
server-side participants (AI agents, recorders, interpreters, bots) join.

Status: browser-to-browser rooms with server-side routing, server-side
workers that join over WebRTC, and rooms that survive restarts and deploys.
Browsers can also publish a camera and a screen share, routed by the same
policy; workers stay audio-only.

Docs: [architecture](docs/architecture.md) describes how it works today,
the [decision log](docs/decisions.md) records why and what was tried first,
and the [roadmap](docs/roadmap.md) holds what isn't built yet.

Your server needs no public media endpoint, open ports or TURN server: each
worker's media connection is one it opens to Cloudflare, so it needs
outbound UDP. Building `ex_webrtc` needs the system's libsrtp
(`brew install srtp`, or `libsrtp2-dev` on Debian/Ubuntu) and

```elixir
config :bundlex, :disable_precompiled_os_deps, apps: [:ex_libsrtp]
```

in your app's config: the precompiled libsrtp links a libcrypto that isn't
on the default path.

Try it: [examples/agent](examples/agent) is one person talking to a voice
agent, and times its replies; [examples/meet](examples/meet) is a video call
with four AI assistants; [examples/call](examples/call) is a LiveView group
call with video and the testing tools.

Native apps join the same rooms with the Swift client for iOS and macOS:
see [swift/README.md](swift/README.md).

## Tests

```sh
bin/test            # Elixir, the browser client (Node 22+) and the Swift client
bin/test all        # also builds the iOS example app (needs xcodegen)
bin/test swift js   # just those
```

None of the suites needs Cloudflare or the network.
