# Octoroom call demo

A group call with a mic check, in one LiveView page. Browsers send and
receive audio through Cloudflare Realtime SFU; the LiveView renders what the
room server knows: who is in the room, whose mic is live, who hears whom,
and which workers run.

The room is `Call.Room` in [lib/call.ex](lib/call.ex). Everyone hears
everyone, and three workers from [lib/workers.ex](lib/workers.ex) show what
milestone 3 adds:

- **Echo on:** a private `Call.DelayEcho` plays you back two seconds late.
  Only you hear it. **Flush my echo** drops the two seconds it holds;
  **Crash my echo** kills the worker, which the room restarts while your
  echo track stays published.
- **Metronome on:** `Call.Metronome` beeps once a second for the whole room.
  It makes audio by the wall clock, so its outlet queue should stay short
  and flat; watch the Queued and Underruns columns.
- **Record:** `Call.Recorder` writes every mic to its own WAV file and
  reports seconds recorded per person. People joining don't restart it.
- **Captions on:** `Call.Captioner` streams every mic to Soniox's real-time
  speech-to-text and `emit`s captions, which the page shows as they arrive.
  Needs `SONIOX_API_KEY`; without it the button is hidden.

"Here now" uses Phoenix Presence: how many pages have the room open, and
who of them is in the call.

## Run it

You need a Cloudflare Realtime SFU app (dashboard: Realtime → SFU). Put its
credentials in `.env` here (gitignored) or the environment:

```sh
OCTOROOM_CLOUDFLARE_APP_ID=...
OCTOROOM_CLOUDFLARE_APP_SECRET=...
```

```sh
mix deps.get
mix run --no-halt
```

Open <http://localhost:4300> in two tabs or browsers, and join in both.
`/r/<name>` opens another room. Tick **test tone instead of mic** to send a
beep at a per-tab pitch instead of your microphone (useful in one browser,
where two mics would feed back).

### Workers need a public URL

Cloudflare reaches workers by dialing WebSockets on this server
(`Octoroom.Plug` at `/octoroom`), so it needs a public `wss://` URL. Without
one the call works and workers run, but nobody hears them. For a try-out,
a Cloudflare quick tunnel will do:

```sh
cloudflared tunnel --config /dev/null --protocol http2 --url http://localhost:4300
```

`--config /dev/null` matters if you have `~/.cloudflared/config.yml` for a
named tunnel: otherwise cloudflared applies that file's ingress rules to the
quick tunnel, and every request (Cloudflare's adapter dials included) gets
its catch-all 404. `--protocol http2` avoids QUIC, which some networks block.

Then start the app with the tunnel's host:

```sh
OCTOROOM_PUBLIC_WS_URL=wss://<random>.trycloudflare.com/octoroom mix run --no-halt
```

The tunnel makes the whole app public, including the page that creates
Cloudflare sessions on your account; stop it when you're done.

### What to check

- **Echo delay:** clap with your echo on; you should hear it about 2.5 s
  later (2 s plus ~500 ms for the round trip through two adapters).
- **Pacing:** with the metronome on for 5 minutes, Queued stays flat and
  Underruns stops climbing; recording for 5 minutes gives WAVs about
  5 minutes long.
- **Restart:** Crash my echo, then speak: the echo comes back after about
  half a second, and the browser doesn't renegotiate.
- **Cleanup:** after Echo off or leaving, the worker's adapters are closed
  (the server logs any close that fails).
- **Server restart:** with people in the call, stop the server (Ctrl-C
  twice, or `kill -9` for a crash) and start it again. Audio between people
  keeps flowing while it's down; the page says it's reconnecting, then
  "resumed the same session" with no new peer connection. Workers go quiet
  and come back, and the room's buttons (metronome, recording, captions)
  are as they were. Rooms are kept in `OCTOROOM_STORE` (a file; the system
  temp directory by default), and a restart within 10 minutes resumes them.
