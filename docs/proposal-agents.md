# Proposal: Octoroom agents

Status: **proposal; phase 1 is built** (see [D37](decisions.md#d37-agents-are-a-package-in-this-repository-copied-from-subvocal)),
part of phase 3: per-speaker front ends, speaker labels, `respond:` and
interruption by the addressee ([D39](decisions.md#d39-an-agent-runs-a-front-end-per-speaker)),
and, early, the model-based addressing gate with a floor wait and the
half-cascaded pipeline ([D40](decisions.md#d40-a-decision-model-hears-each-turn-and-the-agent-may-wait-for-the-floor)). Written 2026-11-17. Module and
function names (`Octoroom.Agent`, `agent/3`, `respond:`) are proposals. For
what exists today, read [architecture.md](architecture.md).

The LiveKit comparison is from memory of LiveKit Agents 1.x, not re-read
for this document. Check it before quoting it anywhere.

## Summary

An Octoroom agent is an AI participant: it hears the tracks the room's
policy gives it, speaks on a track the policy routes like any other, calls
tools that are plain functions in the Phoenix app, and shows up in clients
with a name, a state and transcripts.

The proposal has three parts:

1. **Agents are workers.** An agent is an `Octoroom.Worker` whose process
   runs a pipeline of frame processors. A room declares it in `workers/1` with
   `agent/3`. There is no agent server, no dispatch API and no job queue:
   the policy is the dispatch.
2. **A new package, `octoroom_agents`,** holds the agent layer. It depends
   on `octoroom` and not on Subvocal. Subvocal was an experiment and
   isn't developed further; its pipeline runtime, processors, providers
   and tools are **copied in as each phase needs them** and changed for
   rooms, the way milestone 1 ported Subvocal's Cloudflare code
   ([Where the code came from](decisions.md#where-the-code-came-from)).
   Octoroom core still ships no AI
   ([D5](decisions.md#d5-octoroom-ships-no-ai)).
3. **Core grows five AI-free features** that agents need and that other
   workers can use: separate input and output rates, playback feedback from
   outlets, worker presence, policy-scoped worker events to clients, and
   client messages to workers.

What Octoroom can offer that LiveKit Agents doesn't: agents in multi-party
rooms with exact speaker attribution, private agents (a coach only one
person hears) as a two-line policy, and tools that run inside the app with
its Repo, PubSub and LiveViews in reach.

## The four use cases

These drive the design. Each one needs something a 1:1 voice agent doesn't.

| Use case | What the agent does | What it needs beyond a 1:1 voice agent |
| --- | --- | --- |
| **Meeting notetaker** | Hears everyone, never speaks unless asked, writes notes and action items. | N speakers with names attached to their words. No reply at each end of turn. History that survives a deploy. |
| **Collaboration call** | A team is on a call and asks the agent to do things, e.g. "add a row for Acme to the pipeline sheet". | Knowing when it is being addressed. Tools that change app state, with the caller's identity for authorization. LiveViews updating as tools run. |
| **AI receptionist** | Greets a visitor, answers questions, then brings a human in and steps back. | 1:1 turn-taking at first, then a handoff that changes who hears whom. Later, a phone caller ([Telephony](roadmap.md#telephony)). |
| **Gemini decision model** | Listens and answers calibrated questions about the audio (Subvocal's `VocalCues` already does this per turn): is the customer frustrated, was the agent addressed, is this a question. | An agent with no voice at all, whose output is events and room metadata. The same model as the "was I addressed?" gate for the other three. |

## What LiveKit Agents is, and what carries over

| LiveKit Agents | Octoroom agents |
| --- | --- |
| Agent server: a separate process pool that registers with LiveKit and receives jobs. | None. Agents are supervised processes in the app's node, under the room's supervisor. |
| Dispatch: automatic for every room, or explicit by agent name through an API or token. | `workers/1` returns `agent(...)`. Changing a room assign adds, removes or swaps an agent on the next reconcile. |
| The agent joins as a participant with `kind = AGENT`. | The agent is a worker with presence (see [Core changes](#core-changes)). |
| `AgentSession` with STT, LLM, TTS, VAD and turn detection, or a realtime model. | A pipeline spec: `Spec.cascaded/2`, `Spec.gemini_live/1`, or the agent's own. |
| `Agent`: instructions and tools. Handoff by returning another `Agent` from a tool. | `use Octoroom.Agent`: callbacks modelled on `Subvocal.Agent`. Handoff as a tool return, or as a policy change. |
| `RoomIO` links the session to one participant. Multi-user is left to the developer. | Every input arrives labelled by participant. Multi-party is the default case. |
| Subscriptions and permissions set imperatively. | `inputs:` for what the agent hears, `subscriptions/2` for who hears it. |
| Transcripts over text streams, text input over a chat topic, RPC to clients, `lk.agent.state` attribute. | Worker events to clients scoped by policy, client messages to workers, presence state. |
| Tools run in the agent process, away from the app. They reach the app over HTTP or RPC. | Tools are functions in the app. |

## Developer experience

### An agent

```elixir
defmodule MyApp.Assistant do
  use Octoroom.Agent

  @impl true
  def backend(_ctx), do: Octoroom.Agent.Backend.Cascaded.new(%{stt: %{provider: :soniox}})

  @impl true
  def instructions(ctx) do
    "You are an assistant in a team call for workspace #{ctx.args.workspace_id}. " <>
      "Several people are speaking; each line is prefixed with the speaker's name."
  end

  @impl true
  def tools(_ctx), do: [MyApp.SheetTools.add_row(), MyApp.SheetTools.update_cell()]
end
```

`ctx` is the worker's context plus `args`: room id, agent id, the
participants and `resumed`. The callbacks follow `Subvocal.Agent`, with
`ctx` in place of channel params. `pipeline/1` is available for a custom
spec.

### In a room

```elixir
defmodule MyApp.TeamRoom do
  use Octoroom.Room
  import Octoroom.Agent, only: [agent: 3]

  @impl true
  def join(_params, socket),
    do: {:ok, %{user_id: socket.assigns.user.id, name: socket.assigns.user.name}}

  @impl true
  def workers(room) do
    [
      agent("assistant", MyApp.Assistant,
        hears: Enum.map(room.participants, &mic/1),
        respond: :addressed,
        args: %{workspace_id: room.assigns.workspace_id}
      )
    ]
  end
end
```

`agent/3` returns an ordinary worker spec: module `Octoroom.Agent.Worker`,
inputs from `hears:`, one output track named after the id (`"assistant"`).
The default `subscriptions/2` already includes worker outputs, so everyone
hears it. People joining and leaving change `hears:`, which adds and removes
inlets without restarting the agent (existing behaviour).

Options:

| Option | Values | Default | Meaning |
| --- | --- | --- | --- |
| `hears:` | audio tracks | required | The agent's inputs. |
| `respond:` | `:always`, `:addressed`, `:never` | `:always` with one input, `:addressed` with more | When an end of turn starts a reply. See [Turn-taking](#turn-taking-in-a-group). |
| `interrupt:` | `:anyone`, `:addressee`, `:nobody` | `:addressee` | Whose speech stops the agent mid-reply. |
| `voice:` | boolean | `true` | `false` gives the agent no output track. |
| `name:`, `attributes:` | string, map | id, `%{}` | Presence shown to clients. |
| `args:` | term | `%{}` | Passed to the agent's callbacks. Changing it restarts the agent. |

From outside the room:

```elixir
Octoroom.Agent.say(room_id, "assistant", "Recording has started.")
Octoroom.Agent.prompt(room_id, "assistant", "Summarize the last five minutes.")
Octoroom.Agent.interrupt(room_id, "assistant")
```

### The use cases as code

**Notetaker.** No voice. Its tool writes to the database and broadcasts
through the app's PubSub, so a LiveView shows notes as they are taken.

```elixir
agent("notes", MyApp.NoteTaker,
  hears: Enum.map(room.participants, &mic/1), respond: :never, voice: false)
```

With `respond: :never` the model never runs at end of turn. `NoteTaker`
overrides `handle_transcript/3` (an optional callback, called with each
finalized, speaker-labelled item) to prompt itself every few minutes or
when the call ends.

**Collaboration call.** The `MyApp.TeamRoom` above. A tool handler receives
who asked:

```elixir
def add_row(%{"sheet" => sheet, "values" => values}, ctx) do
  user = MyApp.Accounts.get_user!(ctx.speaker.meta.user_id)

  with :ok <- MyApp.Sheets.authorize(user, sheet),
       {:ok, row} <- MyApp.Sheets.add_row(sheet, values) do
    {:ok, %{row: row.index}}
  end
end
```

`ctx.speaker` is the participant whose turn triggered the call. The sheet's
LiveView updates through whatever `MyApp.Sheets` already broadcasts. Nothing
in Octoroom is involved.

**Receptionist.** The stage is a room assign, and the handoff is a tool that
changes it:

```elixir
def workers(%{assigns: %{stage: :reception}} = room),
  do: [agent("reception", MyApp.Receptionist, hears: visitor_mic(room), respond: :always)]

def workers(%{assigns: %{stage: :with_staff}} = room),
  do: [agent("notes", MyApp.NoteTaker, hears: all_mics(room), respond: :never, voice: false)]

# in MyApp.Receptionist's tools
def fetch_human(_args, ctx) do
  MyApp.Staff.page(ctx.room_id)                       # staff member joins from a LiveView
  Octoroom.Room.assign(ctx.room_id, :stage, :with_staff)
  {:ok, %{status: "someone is joining"}}
end
```

The reconciler stops the receptionist and starts the notetaker. While the
receptionist is waiting, `subscriptions/2` can keep the staff member silent
to the visitor until they choose to speak, the same way Example 3's
supervisor barges in.

**Decision model.** A silent agent whose pipeline is VAD, turns and a
decision stage. It emits answers and can write them to metadata, which
re-runs the policy:

```elixir
agent("mood", MyApp.Mood, hears: [mic(customer)], respond: :never, voice: false)

# MyApp.Mood
def pipeline(_ctx) do
  processor(:vad, Processors.VAD, isolate: true)
  |> processor(:turns, Processors.AudioTurns)
  |> processor(:decide, Processors.Decisions,
       questions: [frustrated: "Does the speaker sound frustrated?"])
end

def handle_decision(%{frustrated: true}, ctx),
  do: Octoroom.Room.update_meta(ctx.room_id, ctx.speaker.id, &Map.put(&1, :escalate, true))
```

`Processors.Decisions` is Subvocal's `VocalCues` with its output as a frame
instead of a transcript annotation. With `escalate: true` in metadata, `workers/1` can
add a coach and `subscriptions/2` can let a supervisor in, with no event
handling in the room module.

## Design

### An agent is a worker running the pipeline core

Subvocal separates its pipeline logic (`Subvocal.Pipeline.Core`, pure) from
the process that hosts it (`Runner` in Membrane, `Local` as a plain
GenServer, `Test`). `octoroom_agents` copies the core and writes its own
host, `Octoroom.Agent.Worker`, about the size of `Pipeline.Local`:

| Worker side | Pipeline side |
| --- | --- |
| `handle_audio(input, pcm, state)` | `Core.push(%InputAudio{audio: pcm, source: input})` |
| `{:output, %OutputAudio{}}` command | `play: {:default, audio}` |
| `{:interrupted, _}` command | `flush: :default` |
| `{:notify, event}` command, conversation items | `emit: event` |
| `handle_info/2` | `Host.handle_message/3` for tasks and timers, then `Core.info/3` |
| `{:octoroom, :inputs, names}` | A frame that adds or removes per-speaker branches |

Consequences:

- **One process per agent**, keeping Subvocal's "one process per call"
  decision. Interruption stays a single step.
- **No Membrane.** Subvocal's `PlaybackQueue` and `Realtimer` exist to pace
  audio. The outlet already paces to real time and `flush` already empties
  it ([D15](decisions.md#d15-outlets-pace-to-real-time)), so the agent
  hands audio over as fast as TTS produces it. The copied modules mention
  Membrane only in comments, so the package doesn't depend on it.
- **A worker crash keeps the track.** The agent's peer and outlet live under
  the media supervisor
  ([D11](decisions.md#d11-worker-media-lives-apart-from-the-worker)), so a
  crashed agent is a few seconds of silence for listeners and no
  renegotiation.
- **The interpretation demo (milestone 6) falls out.** A one-way
  STT → translate → TTS pipeline is the same host with no turn stage, and
  no longer needs an adapter on the Subvocal side.

### Many speakers into one conversation

Subvocal's pipeline takes one audio stream. A room gives the agent one
stream per participant, which is better than what a mixed stream offers: the
SFU has already separated the speakers, so attribution is exact and needs no
diarization.

Two modes, chosen by the backend:

- **Per-speaker front end (cascaded backends, the default).** Each input
  gets its own VAD, STT and turn stages. Their transcripts merge into one
  context, each tagged with the speaker. `Context` renders them as
  `[Priya] can you add Acme to the sheet`. This is a new composite stage,
  `per_source/3`, that routes frames by `source` and creates and drops
  branches as inputs change. `InputAudio`, `Transcription` and the
  speaking frames get a required `source` field, which a copy can do
  without keeping a 1:1 path working.
- **Mixed (Gemini Live, and half-cascaded).** A realtime model has one audio
  input, so the agent mixes its inputs first. The model hears everyone and
  attribution is whatever it can infer from voices. The mixer is the one the
  phone bridge needs ([Telephony](roadmap.md#telephony)), built once.
  **No mixer is needed before phase 6.** Phase 1 has one input, and the
  per-speaker front end never mixes. Whichever of Gemini Live and phone
  callers comes first builds it.

Cost: per-speaker mode holds one STT stream per input. The front end sends
audio to STT only while that speaker's VAD is open, with pre-roll, so a
quiet participant costs a VAD and nothing else. This needs checking against
each STT provider's handling of gaps.

### Turn-taking in a group

In a 1:1 call, the user finishing a sentence means the agent should answer.
In a group, people mostly talk to each other. Every finalized turn goes into
the context regardless, so the agent always knows what was said. `respond:`
decides whether a turn also starts a reply:

- **`:always`.** Every end of turn starts a reply. Right for one input:
  the receptionist, a support bot.
- **`:addressed`.** A gate decides per turn. Three gates, cheapest first,
  each a processor the agent can replace:
  1. the agent's name or a configured phrase in the transcript;
  2. the turn follows the agent's own reply within a few seconds, from the
     person it was talking to (a follow-up needs no name);
  3. a decision model asked "is this addressed to the assistant?" with the
     turn's audio and the last few lines. This is the Gemini decision model
     use case as infrastructure.
- **`:never`.** Replies start only from `Octoroom.Agent.say/3`,
  `prompt/3`, or the agent's own code.

Three more rules for groups:

- **Interruption.** `interrupt: :addressee` (default) stops the agent only
  when the person it is answering speaks. `:anyone` suits small calls.
  Two colleagues talking over the agent don't cut it off by default.
- **The floor.** A reply that isn't an answer to a direct request (a
  non-blocking tool result, a `prompt/3`) waits until no input's VAD is
  open. This generalizes the `:when_idle` scheduling of the copied
  `Tools` stage from one speaker to all of them.
- **Concurrent turns.** Two people can finish at once. Turns are committed
  in the order they end, and one reply answers what is pending.

An agent never hears itself: its output isn't among its inputs unless the
policy puts it there. Two agents that hear each other can loop, so
`hears:` should list mics, and the docs should say so.

### What the agent heard and said

The outlet knows what it queued, sent and dropped. Subvocal's runner only
estimates playback from bytes sent (open question 1 in its
`docs/pipelines.md`), and its conversation events don't truncate
interrupted text. With two small messages from the outlet (see
[Core changes](#core-changes)), the agent knows when its speech started and
finished and how much a flush dropped, so the history holds what listeners
heard.

### Text, state and transcripts in clients

Three things reach clients, all through core features that carry no AI:

- **Presence.** Each agent appears in the client's room state with `id`,
  `name`, `attributes` and `state` (`listening`, `thinking`, `speaking`,
  plus whatever the worker sets).
- **Transcripts and events.** The agent emits conversation items (Subvocal's
  existing [contract](../../subvocal/docs/conversation-events.md), plus
  `speaker`). They reach clients under the audio policy: **an event tied to
  a track goes only to participants subscribed to that track.** The coach's
  words reach the agent's browser and not the customer's, with no second
  policy to write and no way for the two to disagree.
- **Messages to the agent.** `room.send("assistant", {text: "..."})` from a
  client becomes a user turn with that participant as speaker. A client may
  message a worker only if the worker hears it. A room can narrow that with
  an optional `message/3` callback.

Client API, in the browser and Swift clients:

```js
room.on("agents", (list) => render(list));           // [{id, name, state, attributes}]
room.on("transcript", (item) => append(item));       // {agent, speaker, role, text, status}
room.send("assistant", { text: "add Acme to the sheet" });
```

### Tools

Tool handlers run inline in the agent's process on the app's node, so they
call the app directly. Subvocal's `:owner` mode, which sends calls to a
channel process, isn't copied. The handler
context adds `room_id`, `agent_id`, `speaker` and `participants`. Three
things follow from where they run:

- **Authorization uses the speaker.** `join/2` metadata is server-set, so
  `ctx.speaker.meta.user_id` can be trusted the way `socket.assigns` is.
  In mixed mode there is no speaker, and tools that need one should refuse.
- **Room control is a function call.** `Octoroom.Room.assign/3` and
  `update_meta/3` from a tool re-run the policy. "Mute Sam for the
  recorder", "bring in billing" and "leave the call" need no new API.
- **Slow tools.** Blocking tools with progress speech and non-blocking
  tools with `:interrupt`, `:when_idle` and `:silent` results come over
  with the `Tools` stage.

### Handoffs

Two kinds, and they compose:

- **Inside one agent.** A tool returns `{:handoff, MyApp.Billing}`. The
  worker swaps instructions and tools and keeps the history and the voice,
  as Subvocal's server protocol does with `session.update`. Nothing
  restarts.
- **Through the policy.** A tool changes a room assign, and `workers/1`
  returns a different agent. This is the receptionist. It can also change
  the voice, the backend, who hears the agent and who the agent hears. The
  new agent starts with the history only if both share a conversation (next
  section).

### History, crashes and deploys

Octoroom restarts a crashed worker and tells a worker when the room is
recovering, but worker memory is the developer's job
([What stays the developer's job](architecture.md#what-stays-the-developers-job)).
For agents the package does that job behind one behaviour:

```elixir
@callback load(conversation_id) :: [item]
@callback append(conversation_id, item) :: :ok
```

- The conversation id defaults to `{room_id, agent_id}`. Agents given the
  same `conversation:` option share a history, which is how a policy
  handoff carries context.
- The default store is ETS on the node, enough for worker crashes and
  policy handoffs. An Ecto store covers deploys. A notetaker should use it.
- On start the agent loads its history. When `ctx.resumed` is set it does
  not greet again.

## Core changes

All five are useful without AI, which is the test for whether they belong in
core under D5.

| Change | Why agents need it | Size |
| --- | --- | --- |
| **Separate input and output rates.** `use Octoroom.Worker, audio: [rate: 16_000, channels: 1, output: [rate: 24_000]]`. | The pipeline takes 16 kHz and produces 24 kHz. Today a worker has one format for both. | Small: `Worker.Server` converts each direction already. |
| **Outlet feedback.** `{:octoroom, :flushed, output, dropped_ms}` and `{:octoroom, :drained, output}` to the worker's `handle_info/2`. | Knowing what was played, for history and for `speaking` state. | Small. |
| **Worker presence.** `worker/3` takes `presence: %{name:, attributes:}`. A worker action `presence: map` updates it. Clients get the list in the join reply and changes as `room_event`. | Showing the agent in the UI with its state. Also a recorder's "recording" indicator. | Medium: room server state, channel, both clients. |
| **Worker events to clients, scoped by track.** `emit: {event, track: name}` forwards to participants subscribed to that track. Plain `emit` stays server-only. | Transcripts and captions. Already a [roadmap gap](roadmap.md#smaller-gaps). | Medium. |
| **Client messages to workers.** A `message` channel event delivered to the worker's `handle_info/2` with the sender's participant. | Typed input to an agent. | Small, plus the authorization rule. |

Not needed for a first version, but agents make them more pressing:
speaking events (the per-speaker VADs produce trustworthy ones as a side
effect, which answers that
[open question](roadmap.md#open-questions) for rooms with an agent), room
lifetime for rooms where an agent waits alone, and frame upload for vision
([Video for workers](roadmap.md#video-for-workers)).

## What is copied from Subvocal

Subvocal was an experiment and was never released. Agent development
continues in `octoroom_agents`, and Subvocal is only a source to copy from.
Nothing is ported back, so the two drifting apart costs nothing.

`octoroom_agents` lives in this repository under `agents/` with its own
`mix.exs` and depends on `octoroom`. Modules are renamed under
`Octoroom.Agent` (`Octoroom.Agent.Pipeline.Core`, `Octoroom.Agent.Frames`,
`Octoroom.Agent.Processors.VAD`).

The copy is **incremental**. Each phase brings over what it needs, with the
tests for those modules, and changes it freely. Subvocal's `lib/` at
`c12431f` has about 7,400 lines worth taking eventually and about 2,900
that never come over.

| When | Subvocal modules | Changes on the way in |
| --- | --- | --- |
| **Phase 1** (one speaker) | `Frame`, `Frames`, `Processor`, `Processor.StateMachine`; `Pipeline.Core`, `Host`, `Spec`, `Test`; processors `VAD`, `STT`, `STTTurns`, `Context`, `LLM`, `Tools`, `TextChunker`, `TTS`, `AssistantCollector`; `Tool*` and `ToolAdapters.*`; `VAD.Silero` and its model; `ConversationEvents`; `Backend.Cascaded`; one STT, one LLM and one TTS provider from `Cascaded.*` | `source` on audio, transcription and speaking frames from the start. `ToolExecutor` keeps `:inline` only. Comments about Membrane hosts rewritten. |
| **Phase 3** (groups) | `Pipeline.Composite`, `Switch`, `Isolated`, `Subscriptions`; `Processors.SmartTurn`, `TurnDetection.SmartTurn` and its models | New `per_source/3` composite. `Context` labels speakers, `Tools` passes `speaker`, conversation items get `speaker`. New `Addressed` gate. |
| **Phase 5** (decisions) | `Processors.VocalCues`, `AudioTurns`, `Transcriber` | `VocalCues` also becomes `Decisions`. |
| **Phase 6 or when wanted** | `Processors.GeminiLive`, `GeminiLive.*`, `Backend.GeminiLive`; the remaining `Cascaded.*` providers; `Python`, `Python.Processor`, `Cascaded.Woof` | Mixed-input mode for Gemini Live. Python behind an optional Pythonx dependency. |

A module can move earlier if a phase turns out to need it; the table is the
expected order, not a rule.

Never copied:

| Left behind | Why |
| --- | --- |
| `Subvocal.Pipeline`, `Pipeline.Runner`, `Pipeline.Local`, `Audio.PlaybackQueue` | The Membrane host and its pacing. `Octoroom.Agent.Worker` replaces them. |
| `Transport.*` (WebRTC, WebSocket, Cloudflare SFU) | Octoroom's peers, inlets and outlets are the transport. |
| `Phoenix.*`, `Agent`, `AgentSpec` | Channel-per-session signaling. `use Octoroom.Agent` and the worker context replace them. |
| The browser and Swift voice clients, the server protocol | Octoroom has its own clients and no server mode. A 1:1 voice agent is a room with one person and one agent. |

Dependencies: phase 1 brings `req_llm`, `websockex`, `ortex` and
`nimble_options`. `membrane_core`, `membrane_webrtc_plugin` and the
Membrane audio plugins never come. Two things to sort out before a Hex
release: Subvocal pins `req_llm` to a git commit for the Gemini Decisions
API (only phase 5 needs that, so phase 1 can use a released version if one
works), and `ortex` needs a Rust toolchain or a precompiled NIF on every
target.

`decisions.md` gets a row per module group in "Where the code came from"
as each one lands, and D5's plan for an adapter inside Subvocal is marked
superseded.

## Testing

- `Octoroom.Agent.Test` runs an agent with the copied stages' fake providers
  (`request:`, `synthesize:`, `predict:`) over `FakePeerMedia`, so a test
  scripts "Priya says X, Sam says Y" as transcripts per input and asserts
  on replies, tool calls and what each client receives.
- The addressing gates and the floor rule are pure processors, tested with
  the copied `Pipeline.Test` harness as frames in and effects out.
- One integration test against real Cloudflare and real providers measures
  latency (below).

## Phases

1. **One speaker.** Create `agents/`, copy the phase 1 modules, and run a
   cascaded agent as a worker in `examples/call`, hearing one mic. Needs
   separate rates (or resampling in the worker until core has them). **Measure** end of user speech to first
   agent audio in the browser, with Subvocal's direct WebRTC transport as
   the reference number.
   The inlet adds a 50 ms jitter buffer and the outlet 20 ms frames; the
   rest is unknown. If the number is bad, the fix is in the room path
   (jitter buffer, pacing), since there is no other transport to fall back
   to.
2. **Package v0.** `use Octoroom.Agent`, `agent/3`, inline tools with
   `speaker`, `say/3`, `prompt/3`, outlet feedback, history store. The
   receptionist works end to end with a browser visitor. Milestone 6's
   interpreter runs on the same host.
3. **Groups.** `source` frames, `per_source/3`, speaker-labelled context,
   `respond:` and `interrupt:`, the floor rule. The notetaker and the
   collaboration call work.
4. **Clients.** Presence, scoped events, client messages, and the JS and
   Swift APIs. A demo LiveView with a shared sheet, a transcript pane and an
   agent tile. (Built as worker events in core,
   [D44](decisions.md#d44-workers-reach-clients-through-their-outputs); the
   demo is `examples/meet`, without the shared sheet.)
5. **Decisions.** `Processors.Decisions`, the model-based addressing gate,
   and the mood example.
6. **Later.** Mixed mode with Gemini Live, an Ecto history store, vision
   through frame upload, a phone caller talking to the receptionist
   (after roadmap milestone 7).

## Open questions

- **Worker or participant?** The roadmap makes a phone caller "a participant
  to the policy and a worker underneath". Agents could be the same, so
  `mic(agent)` and `subscriptions(agent, room)` work. This proposal keeps
  agents as workers: `workers/1` reads `room.participants`, so agents that
  appear there make the list depend on itself, and every existing policy
  that loops over participants would start including agents. Revisit when
  phone participants are built, since presence may want one shape for both.
- **Latency.** Phase 1 measures it. How much over direct WebRTC is
  acceptable for a 1:1 receptionist, and what is the first thing to cut if
  it is too much: the inlet's 50 ms jitter buffer, or the outlet's pacing?
- **STT cost in large rooms.** Is VAD-gated streaming per speaker acceptable
  at 15 participants, or does the agent need a "hear the active speakers
  only" mode driven by the policy?
- **Default for `respond:` with several inputs.** `:addressed` is safer but
  the first gate (name spotting) depends on STT getting the name right.
  What should the fallback be when the model gate is not configured?
- **Mixed-mode tools.** Refuse speaker-dependent tools, or attribute to the
  loudest input when the turn ended?
- **Transcripts of people.** Scoping by track covers who may read a
  transcript. It doesn't cover consent to being transcribed. Should
  presence carry a standard "this agent transcribes" attribute that clients
  show by default?
- **Two agents in one room.** The floor rule is per agent. Do agents need to
  see each other's speaking state to avoid talking over one another?
