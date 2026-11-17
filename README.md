# Octoroom

Voice rooms for Phoenix apps. Cloudflare Realtime SFU carries the audio; your
app decides who is in a room, who hears whom, and which server-side
participants (AI agents, recorders, interpreters, bots) join.

Status: milestones 1–5 of [docs/design.md](docs/design.md): browser-to-browser
rooms with server-side routing, server-side workers that join over WebRTC,
and rooms that survive restarts and deploys.

Your server needs no public media endpoint, open ports or TURN server: each
worker's media connection is one it opens to Cloudflare, so it needs
outbound UDP. Building `ex_webrtc` needs the system's libsrtp
(`brew install srtp`, or `libsrtp2-dev` on Debian/Ubuntu) and

```elixir
config :bundlex, :disable_precompiled_os_deps, apps: [:ex_libsrtp]
```

in your app's config: the precompiled libsrtp links a libcrypto that isn't
on the default path.

Try it: [examples/call](examples/call) is a LiveView group call.

This project lives inside the Subvocal repository for now and will move to its
own repository. It must not depend on Subvocal.
