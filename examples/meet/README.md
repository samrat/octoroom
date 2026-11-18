# Meet

A video call with two AI assistants, in a plain Phoenix app: `mix phx.new meet
--no-ecto --no-mailer --no-dashboard`, plus Octoroom. The layout, the core
components (`.button`, `.input`, `.header`, `.icon`) and the Tailwind/daisyUI
styling are the generator's own.

What Octoroom adds:

- [lib/meet/room.ex](lib/meet/room.ex): `Meet.Room`, the room's policy.
  Everyone hears and sees everyone, and two assistants join as soon as the
  first person does (`agents/2`). Both use the decision model
  (`gate: :decision`) on each turn's audio to tell whether someone's talking
  to them, so nobody has to say their names; their `name:` and
  `description:` let the model tell them apart.
- [lib/meet/assistant.ex](lib/meet/assistant.ex): the general assistant,
  with a tool that switches the page's theme.
- [lib/meet/atlas.ex](lib/meet/atlas.ex): Atlas, who only answers questions
  about capital cities. It adds its own question to the decision model
  (`questions/1`) and reads the answer in `decide/2`.
- [lib/meet_web/channels](lib/meet_web/channels): a channel for signaling
  (`use Octoroom.Phoenix.Channel`) and the socket it's on.
- [assets/js/call.js](assets/js/call.js): the `Call` hook, which joins with
  Octoroom's browser client and sends what you type to an assistant
  (`room.send/2`), and the `Video` hook for each tile.
- [lib/meet_web/live/room_live.ex](lib/meet_web/live/room_live.ex): the page.
  Tiles, the control bar and the transcript are rendered from the room
  server's state and the assistants' events. Each assistant's tile shows
  what it says it's doing (its presence: listening, thinking, speaking,
  waiting). Each turn in the transcript has a row per assistant: what it
  decided (replied, waited, listened), why, and every answer from the
  decision model, Atlas's own question included. The box under the
  transcript types to one assistant: it always answers, and the turn is
  marked "typed".

## Run it

Put a Cloudflare Realtime SFU app's credentials and the assistants' keys in
`.env` here (gitignored) or the environment:

```sh
OCTOROOM_CLOUDFLARE_APP_ID=...
OCTOROOM_CLOUDFLARE_APP_SECRET=...
SONIOX_API_KEY=...
GOOGLE_API_KEY=...
INWORLD_API_KEY=...
```

```sh
mix setup
mix phx.server
```

Open <http://localhost:4000> (or `/r/<name>` for another room). Use
headphones: the assistants' voices leaking into your mic sound like you.
Building needs the system's libsrtp (`brew install srtp`) and a Rust
toolchain (for Silero VAD); see the [Octoroom README](../../README.md).
