# octoroom_agents

AI participants for Octoroom rooms. An agent is an `Octoroom.Worker` whose
process runs a voice pipeline: it hears the tracks the room's policy gives
it and speaks on a track the policy routes like any other. Octoroom itself
ships no AI ([D5](../docs/decisions.md#d5-octoroom-ships-no-ai)); this
package is where it lives.

Status: phases 1 and 3 of [docs/proposal-agents.md](../docs/proposal-agents.md),
and the start of phase 2: a cascaded agent (Silero VAD → Soniox → an LLM
through ReqLLM → Inworld) that hears any number of people, each through
their own VAD and speech-to-text, and answers when addressed by name. An
agent is a module, added to a room with `agent/3`:

```elixir
defmodule MyApp.Assistant do
  use Octoroom.Agent

  @impl true
  def instructions(ctx), do: "You're on a team call for #{ctx.args.workspace}. Be brief."

  @impl true
  def tools(_ctx), do: [MyApp.Sheets.add_row()]
end

# in the room
def workers(room) do
  [
    agent("assistant", MyApp.Assistant,
      hears: Enum.map(room.participants, &mic/1),
      respond: :addressed,
      args: %{workspace: room.assigns.workspace}
    )
  ]
end
```

With `gate: :decision`, a decision model hears each turn. The module's
`questions/1` and `decide/2` can ask it more and decide from the answers
("only questions about capital cities"), and `agents/2` puts several
agents in one room, each told apart by name and `description:`
([D41](../docs/decisions.md#d41-the-app-asks-the-decision-model-its-own-questions-and-several-agents-share-a-room)).

Tool handlers get `speaker`, the participant who asked. From outside the
room, `Octoroom.Agent.say/3`, `prompt/3` and `interrupt/2`. The history
holds what people heard: an interrupted reply is cut where its audio
stopped, using the outlet's flush report (see
`Octoroom.Agent.Processors.AssistantCollector`). Still to come in phase 2:
the outlet's `:drained` message, the history store, and the receptionist
example.

### Gemini Live

An agent can also be one speech-to-speech model, Gemini Live, instead of
STT, an LLM and TTS:

```elixir
def backend(_ctx), do: %Octoroom.Agent.Backend.GeminiLive{voice: "Puck"}
```

It has one audio input, so the agent mixes everyone it hears into it, and
the model takes its own turns: `respond:` and `gate:` don't apply, and it
tells speakers apart only by voice. Typing to it, `prompt/3`, tools,
presence and transcripts work as for the cascaded agent, and a restarted
agent resumes its Gemini session. The key is
`GOOGLE_API_KEY`. `Octoroom.Agent.Worker`'s moduledoc has what's
different.

`examples/call` has an agent lab at `/lab/<room>` for trying it: switch
between the cascaded, half-cascaded and Gemini Live pipelines and between the name gate
and a decision model (`gate: :decision`), and watch each turn's decision. Keys come from the
environment: `SONIOX_API_KEY`, `GOOGLE_API_KEY` (Gemini, the default LLM)
and `INWORLD_API_KEY`. See `Octoroom.Agent.Worker` for the args, what it
emits, and how it reports latency.

## Clients

Agents show up in clients through Octoroom's worker events
([D44](../docs/decisions.md#d44-workers-reach-clients-through-their-outputs)):
each one's state (listening, thinking, speaking, waiting), its transcript,
and a box to type to it. `priv/static/octoroom_agents.mjs` does it in the
browser, and the Swift package's `OctoroomAgents` product on iOS and macOS:

```js
import { agents } from "octoroom_agents";

const ai = agents(room); // a RoomClient
ai.on("agents", (list) => render(list)); // [{id, name, description, state}]
ai.on("transcript", ({ agent, items }) => render(agent, items));
await ai.say("assistant", "add Acme to the sheet");
```

A typed message is always answered, whatever `respond:` and the gate say.
`examples/meet` and `examples/ios` show both.

## Speech providers

Speech-to-text and text-to-speech go through two small behaviours,
`Octoroom.Agent.STT` (a streaming session process that sends
`{:stt, pid, event}` to its owner) and `Octoroom.Agent.TTS` (`stream/3` or
`synthesize/2`). A backend names a provider and model in one string, and
the provider fills in its own defaults:

```elixir
def backend(_ctx), do: %{stt: "soniox:stt-rt-v6", tts: "inworld:inworld-tts-2"}
```

Built in: STT from Soniox (`soniox`, the default), AssemblyAI
(`assembly_ai`) and Reson8 (`reson8`, `rumble-2` by default), and TTS from
Inworld (`inworld`, the default), AssemblyAI (`assembly_ai`) and OpenAI
(`openai`). Keys come from `SONIOX_API_KEY`, `ASSEMBLY_AI_API_KEY`,
`RESON8_API_KEY`, `INWORLD_API_KEY` and `OPENAI_API_KEY`. Inworld and
AssemblyAI speak over their WebSockets, one connection per agent: each
Inworld reply is a context on it, and AssemblyAI answers replies in order
on one session, whose voice and sample rate are fixed when it connects. To
add one, implement the behaviour and register it, or pass the module as
`:provider`:

```elixir
config :octoroom_agents, stt_providers: [acme: MyApp.AcmeSTT], tts_providers: [acme: MyApp.AcmeTTS]
```

## Building

Silero VAD runs on ONNX Runtime through `ortex`, which needs a Rust
toolchain. Octoroom's own WebRTC stack needs the system's libsrtp
(`brew install srtp`).

```sh
mix deps.get
mix test
```

The tests use fake providers and Octoroom's fake Cloudflare. To measure a
turn against real providers, with no room or browser:

```sh
SONIOX_API_KEY=... GOOGLE_API_KEY=... INWORLD_API_KEY=... mix run bench/turn_latency.exs
```
