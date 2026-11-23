# Agent

One person talking to one voice agent, in a plain Phoenix app: `mix phx.new
agent --app hello --no-ecto --no-mailer --no-dashboard`, plus Octoroom. It's
the smallest Octoroom agent there is, and it measures how long the agent
takes to answer, as heard in the browser.

What Octoroom adds to the generated app:

- [lib/hello/room.ex](lib/hello/room.ex): `Hello.Room`. The agent joins
  with the person, hears their mic and answers every turn; the person
  hears only the agent.
- [lib/hello/assistant.ex](lib/hello/assistant.ex): `Hello.Assistant`, the
  agent: a system prompt, a greeting, and its providers (Soniox for
  speech-to-text, Nemotron through OpenRouter, AssemblyAI's voice).
- [lib/hello/booking.ex](lib/hello/booking.ex) and
  [lib/hello/booking/script.ex](lib/hello/booking/script.ex):
  `Hello.Booking`, a second agent that books appointments from a script
  instead of an LLM, and the processor that runs the script. It's the
  example of writing your own pipeline stage: a decision model judges each
  turn against the questions of the script's current state, and the script
  picks what to say. Start the app with `HELLO_AGENT=booking` to talk to
  it; [test/hello/booking_test.exs](test/hello/booking_test.exs) runs a
  booking with no audio or providers.
- [lib/hello_web/channels](lib/hello_web/channels): a channel for signaling
  (`use Octoroom.Phoenix.Channel`) and the socket it's on.
- [assets/js/agent.js](assets/js/agent.js): the `Agent` hook. It joins with
  Octoroom's browser client, shows the agent's state and transcript with
  `octoroom_agents.mjs`, sends what you type, and times each reply.
- [lib/hello_web/live/agent_live.ex](lib/hello_web/live/agent_live.ex): the
  page, and the latency table. Each page load is its own room.

## Run it

Put a Cloudflare Realtime SFU app's credentials and the agent's keys in
`.env` here (gitignored) or the environment:

```sh
OCTOROOM_CLOUDFLARE_APP_ID=...
OCTOROOM_CLOUDFLARE_APP_SECRET=...
SONIOX_API_KEY=...
OPENROUTER_API_KEY=...
ASSEMBLY_AI_API_KEY=...
NUANCE_API_KEY=... # optional, for Nuance Live video avatar personas
```

```sh
mix setup
mix phx.server
```

Open <http://localhost:4000> and press Join. Use headphones: with speakers,
the agent's voice leaks into your mic and sounds like you talking.
Building needs the system's libsrtp (`brew install srtp`); see the
[Octoroom README](../../README.md).

## Measuring latency

Each reply gets a row, in milliseconds from the end of your speech:

- **STT**, **LLM**, **TTS**: measured by the agent (its `{:latency, ...}`
  event): when the final transcript, the first LLM text and the first
  audio for the outlet were ready. The end of speech is when the agent's
  VAD heard it, on the server.
- **Heard**: measured in the tab, from the last loud sample of what it sent
  to the first loud sample of the agent's voice. This is the number a
  person feels.

The **recorded questions** play a WAV into the tab's mic track instead of
your voice, so runs can be compared, and work with no microphone (or with
the mic blocked). They're in `priv/static/questions/`; `Hello.Questions`
records them again.

### 2026-11-19, on a Mac, Chrome

Eight recorded questions, one at a time:

| Median (range)    | STT           | LLM           | TTS              | Heard              |
| ----------------- | ------------- | ------------- | ---------------- | ------------------ |
| ms from speech end | 464 (341–622) | 772 (559–842) | 1,043 (833–1,210) | 1,605 (1,411–1,719) |

- **About 560 ms (446–688) is between the outlet and the ear**: the trip
  in to the agent, which the server's clock doesn't see, and the trip out.
  `examples/call`'s echo puts the round trip through Cloudflare at about
  350 ms, so roughly 200 ms is unaccounted for: the outlet, the browser's
  jitter buffer, or the two ends dating the end of speech differently.
- **The agent itself is quick**: Soniox ends the turn in about 0.45 s,
  Nemotron's first text follows about 0.2 s later, and AssemblyAI's first
  audio 0.3 s after that.
- **The greeting doesn't wait for the listener.** It starts 100 ms after
  the agent does (`initial_text/1`), and only the LLM's time hides that the
  browser may not be pulling the agent's track yet. In one run its first
  sound reached the tab 21 ms after the track did. Nothing was clipped in
  the runs checked, but nothing makes sure of it.
