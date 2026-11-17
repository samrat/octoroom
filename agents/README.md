# octoroom_agents

AI participants for Octoroom rooms. An agent is an `Octoroom.Worker` whose
process runs a voice pipeline: it hears the tracks the room's policy gives
it and speaks on a track the policy routes like any other. Octoroom itself
ships no AI ([D5](../docs/decisions.md#d5-octoroom-ships-no-ai)); this
package is where it lives.

Status: **phase 1** of [docs/proposal-agents.md](../docs/proposal-agents.md)
plus part of phase 3: a cascaded agent (Silero VAD → Soniox → an LLM
through ReqLLM → Inworld) that hears any number of people, each through
their own VAD and speech-to-text, and answers when addressed by name.
`use Octoroom.Agent`, `agent/3` and client APIs come in later phases.

```elixir
def workers(%{participants: []}), do: []

def workers(room) do
  [
    worker("assistant", Octoroom.Agent.Worker,
      inputs: Enum.map(room.participants, &mic/1),
      outputs: ["assistant"],
      args: %{name: "Assistant", instructions: "You help a team on a call. Be brief."}
    )
  ]
end
```

`examples/call` has an agent lab at `/lab/<room>` for trying it: switch
between the cascaded and half-cascaded pipelines and between the name gate
and a decision model (`gate: :decision`), and watch each turn's decision. Keys come from the
environment: `SONIOX_API_KEY`, `GOOGLE_API_KEY` (Gemini, the default LLM)
and `INWORLD_API_KEY`. See `Octoroom.Agent.Worker` for the args, what it
emits, and how it reports latency.

## Where the code came from

The pipeline (frames, processors, the pure `Pipeline.Core`, providers,
tools) is copied from Subvocal, an earlier experiment, and renamed under
`Octoroom.Agent`. Each phase copies what it needs and changes it freely;
nothing goes back. The list is in
[decisions.md](../docs/decisions.md#where-the-code-came-from).

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
