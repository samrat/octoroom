# Octoroom

Voice rooms for Phoenix apps. Cloudflare Realtime SFU carries the audio; your
app decides who is in a room, who hears whom, and which server-side
participants (AI agents, recorders, interpreters, bots) join.

Status: milestones 1 and 2 of [docs/design.md](docs/design.md): browser-to-browser
rooms with server-side routing. No server-side workers yet.

Try it: [examples/call](examples/call) is a LiveView group call.

This project lives inside the Subvocal repository for now and will move to its
own repository. It must not depend on Subvocal.
