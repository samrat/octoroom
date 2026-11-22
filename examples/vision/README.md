# Vision

One person talking to a voice agent that can see their camera and shared screen,
in a plain Phoenix app (`mix phx.new vision --no-ecto --no-mailer --no-dashboard`),
plus Octoroom and `octoroom_agents`.

## What Octoroom adds

- [lib/vision/room.ex](lib/vision/room.ex): `Vision.Room` adds `sees:` alongside
  `hears:` so the room pushes capture directives for camera and screen share.
- [lib/vision/cascaded_assistant.ex](lib/vision/cascaded_assistant.ex): cascaded
  vision agent (Soniox STT → Gemini Flash → local TinyVoca TTS) that attaches the
  latest camera/screen snapshots to each spoken or typed turn.
- [lib/vision/gemini_assistant.ex](lib/vision/gemini_assistant.ex): Gemini Live
  speech-to-speech agent that streams ~1 fps JPEG frames over `realtimeInput.video`.
- [assets/js/vision.js](assets/js/vision.js): joins with `RoomClient`, toggles
  camera/screen share and client-side vision pause (`setCaptureEnabled`), and
  displays the live `capture` indicator (`AI sees: camera, screen`).
- [lib/vision_web/live/vision_live.ex](lib/vision_web/live/vision_live.ex): switches
  between Cascaded and Gemini Live mid-call and shows the latest JPEG frame the
  agent received.

## Run it

Put a Cloudflare Realtime SFU app's credentials and provider keys in `.env` here
(gitignored) or the environment:

```sh
OCTOROOM_CLOUDFLARE_APP_ID=...
OCTOROOM_CLOUDFLARE_APP_SECRET=...
GOOGLE_API_KEY=...
SONIOX_API_KEY=... # needed for Cascaded mode
```

```sh
mix setup
mix phx.server
```

Open <http://localhost:4000>, click **Join**, turn on **Camera** or **Share screen**,
and ask the agent what it sees. Use headphones so the agent's voice doesn't leak
back into your mic.
