# Octoroom call demo

A group video call with a mic check, in one LiveView page. Browsers send and
receive audio and video through Cloudflare Realtime SFU; the LiveView renders
what the room server knows: who is in the room, what each person publishes,
who receives what, and which workers run.

The room is `Call.Room` in [lib/call.ex](lib/call.ex). Everyone hears and
sees everyone:

- **Camera on/off** publishes and unpublishes your camera. Turning it on
  after joining is a new publish on the same peer connection; off closes
  everyone's pulls of it, then its transceiver. Tick **join with camera** to
  publish it with the mic.
- **Pause video** mutes the camera: it keeps its transceiver and sends black
  frames, nothing renegotiates, and others see "Video paused".
- **Share screen** publishes a screen, window or tab, with its audio when the
  browser offers it. The browser's own "Stop sharing" unpublishes it.
- **Receive video: off** is a policy change, not a client setting:
  `subscriptions/2` leaves cameras and screens out for you, so the server
  closes those pulls and your browser stops downloading them.
- The **Publishes** column shows each person's sources and whether they're
  muted.

Three workers from [lib/workers.ex](lib/workers.ex) show what milestone 3
adds:

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

The **agent lab** at `/lab` (or `/lab/<room>`, the same room as
`/r/<room>`) tries out the call assistant from `octoroom_agents`
([agents/](../../agents)): one voice agent that hears every mic, each
through its own front end, and that everyone hears. Join from the lab,
turn the assistant on, and:

- **Pipeline:** cascaded (Soniox transcribes each person, the LLM reads
  text) or half-cascaded (each turn is recorded, Smart Turn decides when it
  ends, and the LLM hears the audio; a transcript follows).
- **Deciding to answer:** its name ("Assistant"), or a follow-up from the
  person it just answered; or the decision model, which also asks
  `gemini-decision-1` who each turn is for and whether it can answer. Above
  a threshold it replies; in between it waits a couple of seconds and
  replies only if nobody else speaks. The thresholds, the wait and the
  follow-up window are sliders. Changing a setting restarts the assistant.
- **What it heard and decided:** every turn with its outcome (reply, wait,
  listen), why, and the model's numbers; every reply with its latency. Pills
  show when it's waiting for someone else to answer, and when the last
  person it answered can carry on without its name.
- Use headphones: with speakers, its voice leaks into your mic. Needs
  `SONIOX_API_KEY`, `GOOGLE_API_KEY` and `INWORLD_API_KEY` in `.env` or the
  environment.

The call page links to the lab and keeps the echo, metronome, recording,
captions and the workers table under **Testing tools**.

"Here now" uses Phoenix Presence: how many pages have the room open, and
who of them is in the call.

## Run it

You need a Cloudflare Realtime SFU app (dashboard: Realtime → SFU). Put its
credentials in `.env` here (gitignored) or the environment:

```sh
OCTOROOM_CLOUDFLARE_APP_ID=...
OCTOROOM_CLOUDFLARE_APP_SECRET=...
# Optional: captions (Soniox), and the assistant (all three).
SONIOX_API_KEY=...
GOOGLE_API_KEY=...
INWORLD_API_KEY=...
```

```sh
mix deps.get
mix run --no-halt
```

Open <http://localhost:4300> in two tabs or browsers, and join in both.
`/r/<name>` opens another room. Tick **test tone instead of mic** to send a
beep at a per-tab pitch instead of your microphone (useful in one browser,
where two mics would feed back), and **test pattern instead of camera** to
send a moving pattern with your name and a clock instead of your camera.

### Workers connect out over UDP

Each worker reaches Cloudflare through its own WebRTC peer connection,
which this server opens: no public URL, tunnel or open port is needed, only
outbound UDP. `ex_webrtc` needs the system's libsrtp to build
(`brew install srtp` on macOS, `libsrtp2-dev` on Debian/Ubuntu).

### What to check

- **Video:** two tabs with test patterns: each shows the other's pattern
  with a ticking clock. Pause, resume, camera off and on again, and screen
  sharing should each show up in the other tab within a second, and Pause
  should not renegotiate (no new pull in the Hears column).
- **Receive video off:** the other person's camera disappears from your
  Hears column and your grid; on again brings it back.

- **Echo delay:** clap with your echo on; you should hear it about 2.35 s
  later (2 s plus ~350 ms for the round trip through Cloudflare and back).
- **Pacing:** with the metronome on for 5 minutes, Queued stays flat and
  Underruns stops climbing; recording for 5 minutes gives WAVs about
  5 minutes long.
- **Restart:** Crash my echo, then speak: the echo comes back after about
  half a second, and the browser doesn't renegotiate.
- **Cleanup:** after Echo off or leaving, the worker's peer stops; its
  Cloudflare session ends with its peer connection.
- **Server restart:** with people in the call, stop the server (Ctrl-C
  twice, or `kill -9` for a crash) and start it again. Audio between people
  keeps flowing while it's down; the page says it's reconnecting, then
  "resumed the same session" with no new peer connection. Workers go quiet
  and come back, and the room's buttons (metronome, recording, captions)
  are as they were. Rooms are kept in `OCTOROOM_STORE` (a file; the system
  temp directory by default), and a restart within 10 minutes resumes them.
