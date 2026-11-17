# Octoroom call demo

A group call in one LiveView page. Browsers send and receive audio through
Cloudflare Realtime SFU; the LiveView renders what the room server knows:
who is in the room, whose mic is live, and who hears whom.

The room is `Call.Room` in [lib/call.ex](lib/call.ex), the whole policy:
`join/2` takes a name, and everyone hears everyone.

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

No public URL is needed: nothing here makes Cloudflare dial the server.
That starts with workers (milestone 3).
