# Octoroom design

Status: **milestones 1 and 2 implemented** (2026-11-17). See
[Implementation notes](#implementation-notes-milestones-12) for where the code
differs from this draft.

## Summary

Octoroom is an Elixir library for multi-party voice rooms in Phoenix apps.
Cloudflare Realtime SFU carries the media. The app's own processes make every
decision:

- who may join
- who hears whom
- which server-side participants (bots, AI agents, recorders, interpreters)
  run in the room

By default everyone in a room hears everyone else, and a room module only
says who may join. When a room needs different routing, the developer
overrides one function that answers "what should this listener hear right
now?" Octoroom then works out which Cloudflare calls turn the current state
into that answer, in the same way LiveView diffs a new render against the
old one and patches only what changed. A join, a leave, a reconnect or a
change of language are all handled by re-running that function, so the room
module contains no event handling.

The developer doesn't need to know WebRTC. The server doesn't need UDP ports,
a TURN server or a media stack: browsers speak WebRTC to Cloudflare, and
Cloudflare reaches server-side participants over `wss://`.

## Goals

- Audio rooms with up to about 20 participants, and any number of server-side
  workers, in a Phoenix app with only HTTPS exposed.
- A room API small enough for someone who has built a Phoenix chat room. A
  basic room is one callback, `join/2`. `workers/1` and `subscriptions/2` are
  optional overrides for rooms that need them.
- Server-side participants as supervised Elixir processes that read and write
  PCM, with no WebRTC in the developer's code.
- Server-authoritative media routing. A client can only hear what the
  server's policy subscribes it to.
- Room events (joins, leaves, speaking, worker output) on PubSub, so a
  LiveView can render them.
- Testable without Cloudflare. The policy and the reconciler are pure, and
  the Cloudflare client sits behind a behaviour.

## Non-goals

- **No AI.** Octoroom has no speech-to-text, LLM or text-to-speech code and no
  dependency on any voice-agent library. AI participants come from
  integrations; see [AI integrations](#ai-integrations).
- Running or self-hosting an SFU. Cloudflare is the only media plane.
- Large video rooms (simulcast layer selection, active-speaker video). Video
  tracks should pass through, but v1 doesn't tune for them.
- Native mobile SDKs in v1. The browser client comes first.
- Broadcast to thousands of passive listeners. HLS or MoQ fit that better.

## Independence from Subvocal

Octoroom starts in the Subvocal repository and will move to its own. Rules
until then:

- No dependency on Subvocal, in either direction, at the code level. Octoroom
  must compile and test on its own (`cd octoroom && mix test`).
- Code taken from Subvocal's Cloudflare SFU transport is **copied and
  renamed**, not shared. The pieces worth porting are listed in
  [Prior work](#prior-work).
- Names, env vars and config keys use the `octoroom` / `OCTOROOM_` prefix.
- Subvocal agents join rooms through an adapter that lives in Subvocal (or in
  a small `octoroom_subvocal` package). Octoroom never mentions Subvocal.

## Developer experience

Three rooms, from simplest to most involved: a plain group call, the
interpretation demo from the pitch, and a support call with a private coach,
a silent supervisor and a recorder. All three share the same config, channel
and client.

### Config

```elixir
# config/runtime.exs
config :octoroom,
  cloudflare: [
    app_id: System.fetch_env!("OCTOROOM_CLOUDFLARE_APP_ID"),
    app_secret: System.fetch_env!("OCTOROOM_CLOUDFLARE_APP_SECRET")
  ],
  # Public wss:// URL where Octoroom.Plug is mounted. Cloudflare dials it.
  public_ws_url: System.fetch_env!("OCTOROOM_PUBLIC_WS_URL")
```

```elixir
# endpoint.ex: serves the WebSockets Cloudflare dials for server-side workers
plug Octoroom.Plug, path: "/octoroom"
```

### The room callbacks

| Callback | Required | Default | Answers |
| --- | --- | --- | --- |
| `join(params, socket)` | yes | | May this client join, and with what metadata? |
| `mount(room_id)` | no | `{:ok, %{}}` | Runs once when the room process starts. Returns the room's assigns. |
| `workers(room)` | no | `[]` | Which server-side participants should be running now? |
| `subscriptions(listener, room)` | no | `default_subscriptions(listener, room)` | What should this listener hear now? |

`default_subscriptions/2` returns every other participant's mic plus every
worker output track. That's "everyone hears everyone", the equivalent of
LiveKit's `autoSubscribe: true`. It stays callable from an override, so a
room can start from the default and add or remove tracks.

`workers/1` and `subscriptions/2` must be pure and fast: they run after
every room change, once per listener for `subscriptions/2`. They read only
`room`, which holds the participants (id plus `join/2` metadata), the
running workers and the room's own assigns. Anything else they need goes
into metadata or assigns first.

Helpers imported by `use Octoroom.Room`:

| Helper | Returns |
| --- | --- |
| `mic(participant)` | That participant's mic track. |
| `track(name)` | A track by room-scoped name, e.g. a worker output `"alice/ja"`. |
| `gain(track, 0.0..1.0)` | The same track, played at that volume. Applied in the listener's browser. |
| `others(room, participant)` | Every participant except that one. |
| `worker(id, module, opts)` | A worker spec with `inputs:`, `outputs:` and `args:`. |

### Example 1: a group call

Everyone hears everyone. This is the entire room module:

```elixir
defmodule MyApp.TeamRoom do
  use Octoroom.Room

  @impl true
  def join(_params, socket), do: {:ok, %{user_id: socket.assigns.user_id}}
end
```

Joins, leaves and reconnects are handled by the default
`subscriptions/2`. Adding an AI note-taker that everyone can hear is one
more callback; its output track is picked up by the default subscriptions:

```elixir
  @impl true
  def workers(room),
    do: [worker("notes", MyApp.NoteTaker, inputs: Enum.map(room.participants, &mic/1), outputs: ["notes"])]
```

### Example 2: live interpretation

Each participant picks a language. Each speaker gets one interpreter per
*other* language in the room, and listeners hear the interpretation in their
own language with the original voice quietly underneath.

```elixir
defmodule MyApp.InterpretRoom do
  use Octoroom.Room

  # Runs in the joining client's channel process. The returned map becomes the
  # participant's metadata, visible to workers/1 and subscriptions/2.
  @impl true
  def join(%{"lang" => lang}, socket) when lang in ~w(en ja es),
    do: {:ok, %{user_id: socket.assigns.user_id, lang: lang}}

  def join(_params, _socket), do: {:error, :bad_lang}

  # Re-run on every room change. Octoroom starts and stops workers to match,
  # keyed by id: when the last Japanese speaker leaves, every "...:ja"
  # interpreter disappears from this list and is stopped.
  @impl true
  def workers(room) do
    for speaker <- room.participants,
        lang <- languages(room) -- [speaker.meta.lang] do
      worker("interp:#{speaker.id}:#{lang}", MyApp.Interpreter,
        inputs: [mic(speaker)],
        outputs: ["#{speaker.id}/#{lang}"],
        args: %{from: speaker.meta.lang, to: lang}
      )
    end
  end

  # For each other person in the room: if they speak my language, hear them
  # directly; otherwise hear their interpreter, with their real voice ducked.
  @impl true
  def subscriptions(listener, room) do
    Enum.flat_map(others(room, listener), fn speaker ->
      if speaker.meta.lang == listener.meta.lang do
        [mic(speaker)]
      else
        [track("#{speaker.id}/#{listener.meta.lang}"), mic(speaker) |> gain(0.15)]
      end
    end)
  end

  defp languages(room), do: room.participants |> Enum.map(& &1.meta.lang) |> Enum.uniq()
end
```

Interpreter tracks only become audible once they're sending audio (see
[pending tracks](#cloudflare-constraints-the-reconciler-has-to-respect)).
Until then the listener hears just the ducked original.

### Example 3: a support call with a coach, a supervisor and a recorder

The room has three roles:

- **customer:** hears the agent only.
- **agent:** hears the customer, plus an AI coach that suggests replies.
  The customer never hears the coach.
- **supervisor:** listens silently to everything, including the coach. They
  can "barge in" from a LiveView button, at which point the customer and the
  agent hear them too. While a supervisor is barged in, the coach goes quiet
  for the agent.

A recorder worker hears the customer, the agent and any barged-in supervisor,
but never the coach, so the recording holds what the customer heard plus the
agent's side.

```elixir
defmodule MyApp.SupportRoom do
  use Octoroom.Room

  # Room ids look like "support:1234" (from the channel topic "room:support:1234").
  @impl true
  def mount("support:" <> ticket_id), do: {:ok, %{ticket_id: ticket_id}}

  @impl true
  def join(%{"ticket_id" => ticket_id}, socket) do
    user = socket.assigns.current_user

    case MyApp.Support.role_for(user, ticket_id) do
      {:ok, role} -> {:ok, %{user_id: user.id, role: role, barged_in: false}}
      :error -> {:error, :forbidden}
    end
  end

  @impl true
  def workers(room) do
    customer = by_role(room, :customer)
    agent = by_role(room, :agent)

    coach =
      if customer && agent do
        [worker("coach", MyApp.Coach,
           inputs: [mic(customer), mic(agent)],
           outputs: ["coach"],
           args: %{ticket_id: room.assigns.ticket_id}
         )]
      else
        []
      end

    recorder = [
      worker("recorder", MyApp.Recorder,
        inputs: room.participants |> Enum.filter(&audible_to_customer?/1) |> Enum.map(&mic/1),
        args: %{ticket_id: room.assigns.ticket_id}
      )
    ]

    coach ++ recorder
  end

  @impl true
  def subscriptions(%{meta: %{role: :customer}} = listener, room) do
    for p <- others(room, listener), audible_to_customer?(p), do: mic(p)
  end

  def subscriptions(%{meta: %{role: :agent}} = listener, room) do
    voices = for p <- others(room, listener), audible_to_customer?(p), do: mic(p)
    if supervisor_barged_in?(room), do: voices, else: [track("coach") | voices]
  end

  # The supervisor hears everything: the default, which includes the coach.
  def subscriptions(%{meta: %{role: :supervisor}} = listener, room),
    do: default_subscriptions(listener, room)

  defp audible_to_customer?(%{meta: %{role: role}}) when role in [:customer, :agent], do: true
  defp audible_to_customer?(%{meta: %{role: :supervisor, barged_in: barged_in}}), do: barged_in

  defp supervisor_barged_in?(room), do: Enum.any?(room.participants, &(&1.meta[:barged_in] == true))

  defp by_role(room, role), do: Enum.find(room.participants, &(&1.meta.role == role))
end
```

Barging in is a metadata change from the supervisor's LiveView:

```elixir
def handle_event("barge_in", _params, socket) do
  :ok = Octoroom.Room.update_meta(socket.assigns.room_id, socket.assigns.participant_id, &%{&1 | barged_in: true})
  {:noreply, socket}
end
```

That one call changes three things, and none of them is written as a step:

- The customer's and the agent's subscriptions now include the supervisor's
  mic, so Octoroom pulls it into both sessions.
- The agent's subscriptions no longer include `"coach"`, so Octoroom closes
  that track in the agent's session.
- The recorder's inputs now include the supervisor's mic. Its spec changed,
  so Octoroom adds an egress adapter for the new input. (Adding an input
  doesn't restart the worker; see [the reconcile loop](#the-reconcile-loop).)

The coach worker keeps running throughout, so it has the full context if
the supervisor drops out again.

Done with LiveKit, the same behaviour is an event handler for each of
"customer joined", "agent joined", "supervisor joined", "barge-in" and
"barge-out", each calling `UpdateSubscriptions` and the permissions APIs for
the right participants in the right order, plus code that starts and stops
the coach and recorder agents. With RealtimeKit's role presets, the
coach-only-for-the-agent routing can't be expressed at all.

### A worker

Worker code that isn't AI, to show the contract. This one plays back
everything it hears, two seconds late.

```elixir
defmodule MyApp.DelayEcho do
  use Octoroom.Worker, audio: [rate: 16_000, channels: 1]

  @impl true
  def init(_args, _ctx), do: {:ok, :queue.new()}

  @impl true
  def handle_audio(_input, pcm, q) do
    q = :queue.in(pcm, q)

    if :queue.len(q) > 100 do
      {{:value, out}, q} = :queue.out(q)
      {:ok, q, play: {:default, out}}
    else
      {:ok, q}
    end
  end
end
```

### Channel and client

```elixir
# user_socket.ex
channel "room:*", MyAppWeb.RoomChannel

defmodule MyAppWeb.RoomChannel do
  use Octoroom.Phoenix.Channel, room: MyApp.InterpretRoom
end
```

```js
import {RoomClient} from "octoroom"

const room = new RoomClient({socket, topic: `room:${id}`, params: {lang: "ja"}})
room.on("participants", (list) => render(list))
await room.join()          // asks for the mic, publishes it, plays what the policy subscribes
room.setMuted(true)
await room.leave()
```

For LiveView, `Octoroom.subscribe(room_id)` sends the subscribing process
`{:octoroom, room_id, event}` messages: `:joined`, `:left`, `:speaking`,
`:worker_event` (whatever a worker chooses to emit, e.g. captions).

## Concepts

| Term | Meaning |
| --- | --- |
| **Room** | A named set of participants and workers, run by one `Octoroom.Room.Server` process. Created on first join and stopped when its last client leaves (configurable). |
| **Participant** | A connected client. Has an id, the metadata from `join/2`, and the tracks it publishes (`mic` in v1). |
| **Worker** | A server-side participant: a supervised process that receives PCM from input tracks and sends PCM to output tracks. |
| **Track** | A room-scoped name such as `"alice/mic"` or `"alice/ja"`. Octoroom maps it to Cloudflare's `(sessionId, trackName)`. |
| **Policy** | The room module's `workers/1` and `subscriptions/2` (or their defaults): pure functions of room state that give the desired state. |
| **Reconciler** | Diffs desired against actual state and produces Cloudflare operations. Pure; the room server executes its output. |

## Mapping onto Cloudflare

Cloudflare Realtime SFU has only sessions and tracks. A session is one
`RTCPeerConnection`. A track is pushed into a session (`location: "local"`)
or pulled into a session from another session (`location: "remote"`), and is
addressed by `(sessionId, trackName)`. Octoroom maps its concepts onto that
model as follows.

- **Each browser has one session.** Its mic is pushed as track `mic`, and
  every subscription is pulled into the same session as another transceiver.
  Each pull or close changes that peer connection's SDP and needs a
  renegotiation.
- **Worker inputs use egress adapters.** For each `(worker, input track)`,
  `POST /adapters/websocket/new` with `location: "remote"`, the source
  `sessionId`/`trackName`, `outputCodec: "pcm"` and an endpoint URL on
  `Octoroom.Plug`. Cloudflare dials in and streams PCM.
- **Worker outputs use ingest adapters.** For each output track, an adapter
  with `location: "local"` and `inputCodec: "pcm"`. Cloudflare dials in,
  accepts PCM and publishes it as a track in a session it creates; the
  response carries that `sessionId`.
- **Track directory.** The room server keeps
  `track name -> {session_id, cf_track_name, status}`, where status is
  `:pending` (declared, not yet flowing) or `:live`.

### Adapter wire format (measured in Subvocal's spike, 2026-11-16)

- Each WebSocket message is a protobuf `Packet` (sequence number, timestamp,
  payload) carrying 20 ms of PCM: 48 kHz, stereo, s16le, 3,840 bytes. That's
  ~1.5 Mbit/s each way per adapter.
- Cloudflare plays ingest audio **as fast as it arrives**. Anything sent ahead
  of real time will play even after a barge-in. Octoroom paces every output to
  real time and lets the worker flush unplayed audio (see [Workers](#workers)).
- Egress delivery over TCP is bursty: gaps between frames were 18 ms at p50
  and 107 ms at p99. That's fine for speech-to-text; anything played straight
  through needs a jitter buffer.
- The adapter path added ~170 ms over a server-side WebRTC peer in comparable
  runs. This is the price of having no UDP. See
  [Worker media transport](#worker-media-transport).

### Cloudflare constraints the reconciler has to respect

- `POST /sessions/new` must have **no body**; even `{}` returns a 400.
- **Empty tracks can't be pulled.** Cloudflare holds a pull of a track with no
  packets for ~8 s, then fails with `empty_track_error`. A subscription to a
  `:pending` track stays queued until the track's first packet. For
  browsers, that's when Cloudflare reports the track; for ingest adapters,
  it's when Octoroom sends its first frame.
- Cloudflare is ICE-lite, and it takes a complete SDP with no trickle ICE.
  Browsers gather host candidates and send the full offer. (Server-side
  `ex_webrtc` peers needed aggressive nomination; that's only relevant for
  the future WebRTC worker transport.)
- Only one offer/answer exchange can be in flight per session. Changes to a
  session must be **serialized** and **batched**: several pulls go in one
  `tracks/new` call and need one renegotiation.
- Adapters are billed until closed. Closing them is Octoroom's job (see
  [Failure and cleanup](#failure-and-cleanup)).

## Processes

```
Octoroom.Supervisor
├── Registry (Octoroom.Registry)                 rooms, adapter sockets, outlets by id
├── Octoroom.Store                               room records and adapter ids that outlive the node
├── Octoroom.Janitor                             closes adapters from dead rooms and old runs
├── DynamicSupervisor (Octoroom.RoomSupervisor)
│   └── per room: Supervisor (rest_for_one)
│       ├── Octoroom.Room.Server                 state, policy, reconciler, Cloudflare calls
│       ├── Task.Supervisor                      Cloudflare HTTP calls
│       ├── DynamicSupervisor (outlets)          one Outlet per worker output track
│       └── DynamicSupervisor (workers)          the developer's workers
└── Task.Supervisor (Octoroom.TaskSupervisor)
```

Per client, the Phoenix channel process (from `Octoroom.Phoenix.Channel`)
handles signaling for that client's session and monitors the room server.

Decisions:

- **The room server is the single writer.** Policy evaluation, reconciliation
  and the track directory all live in one process, so ordering is never in
  doubt. Cloudflare HTTP calls run in tasks, so a slow pull (up to ~8 s)
  doesn't block joins or leaves. Results come back as messages, are applied
  to the actual state, and trigger another reconcile.
- **Outlets are separate from workers.** An `Outlet` owns an ingest adapter's
  socket, paces audio to real time and holds the track's live status. If a
  worker crashes and restarts, its output track stays published, so
  listeners keep their subscription and hear a gap, not a renegotiation.
- **Per-session operation queues.** The room server keeps one queue per
  browser session. Only the head operation is in flight, and the queued
  pulls and closes are merged into one call when it is sent.
- **The channel never calls Cloudflare.** It relays SDP between the client
  and the room server, which owns every session. This is what makes routing
  server-authoritative.

## The reconcile loop

```elixir
desired = %{
  workers: room_module.workers(room),
  subscriptions: Map.new(room.participants, &{&1.id, room_module.subscriptions(&1, room)})
}

ops = Octoroom.Reconciler.diff(desired, actual)   # pure
```

Operations, in the order they're applied:

1. `{:close_subscription, participant, track}` and
   `{:stop_worker, id}`. Tear down first so capacity and billing go down
   before they go up.
2. `{:start_worker, spec}` and `{:update_worker_io, id, added, removed}`
   (see below for when a changed spec is an update and when it's a restart).
   Starting a worker starts it, starts an outlet per output
   (ingest adapter, status `:pending`), and creates an egress adapter per
   input that is `:live`.
3. `{:open_subscription, participant, track, opts}` for `:live` tracks.
   Subscriptions to `:pending` tracks wait and are reconsidered when a track
   goes live.
4. `{:update_subscription, participant, track, opts}` for gain changes. This
   is client-side only and sent as a channel message, with no Cloudflare
   call.

Reconcile triggers: a join, a leave, a metadata change
(`Octoroom.Room.update_meta/3`), a room assigns change
(`Octoroom.Room.assign/3`), a track going live, an operation finishing
or failing, and an explicit `Octoroom.Room.refresh/1` for policies that read
outside state. Triggers that arrive while operations are in flight are
coalesced: the reconciler runs again once the current batch returns.

Worker identity is the id string from `worker/3`. When a spec with the same
id comes back changed:

- **Inputs changed:** inlets are added or removed (egress adapters created or
  closed), and the worker gets `handle_info({:octoroom, :inputs, names},
  state)`. It isn't restarted, so a recorder or a group agent can follow
  people joining and leaving.
- **Outputs changed:** outlets are added or removed. No restart.
- **Module or args changed:** the worker is restarted. Outlets whose names
  are unchanged are kept, so listeners don't renegotiate.

## Signaling protocol (channel ⇄ client)

The client holds one `RTCPeerConnection` to Cloudflare. The server tells it
what each transceiver is.

| Direction | Message | Payload |
| --- | --- | --- |
| join reply | | `{participant_id, ice_servers, participants, resume_token}` (no `resume_token` until milestone 4) |
| client → server | join with `resume_token` | `{resume_token, mids: {mid => track}}` after a reconnect (see [Restarts and deploys](#restarts-and-deploys)) |
| server → client | `resume_token` | a refreshed token after a metadata change |
| server → client | `resync` | `{tracks: [{mid, track, participant_id, gain}]}` when the client's view disagreed with Cloudflare's |
| client → server | `publish` | `{sdp: offer, mids: {mic: "0"}}` |
| server → client | reply | `{sdp: answer}` |
| client → server | `connected` | `{}` once the peer connection is up, so the mic is flowing and can be pulled |
| server → client | `renegotiate` | `{sdp: offer, op_id}` (Cloudflare's offer after a pull or close) |
| client → server | `answer` | `{sdp, op_id}` |
| server → client | `close` | `{mids, op_id}`: stop these transceivers |
| client → server | `close_offer` | `{sdp, op_id}`, the offer made after stopping them; the reply is `{sdp: answer}` |
| server → client | `tracks` | `{added: [{mid, track, participant_id, gain}], removed: [mid]}` |
| server → client | `gain` | `{mid, gain}` |
| server → client | `room_event` | joins, leaves, speaking, worker events |

`op_id` ties an answer to the operation that asked for it, so a late answer
after a reconnect is rejected instead of applied to the wrong state. The
client applies `tracks` only after the matching renegotiation completes, so
mids always refer to transceivers that exist.

Gain is applied in the browser with a Web Audio `GainNode` per remote track.
Cloudflare forwards each track unchanged.

## Workers

```elixir
@callback init(args :: term, ctx :: Octoroom.Worker.Context.t()) :: {:ok, state}
@callback handle_audio(input :: String.t(), pcm :: binary, state) :: {:ok, state} | {:ok, state, actions}
@callback handle_info(msg :: term, state) :: {:ok, state} | {:ok, state, actions}   # optional
@callback terminate(reason, state) :: any                                          # optional

# actions
play: {output, pcm}      # queued on the outlet, paced to real time
flush: output            # drop queued, unplayed audio (barge-in)
emit: event              # broadcast {:worker_event, worker_id, event} to the room
```

- `use Octoroom.Worker, audio: [rate: 16_000, channels: 1]` picks the PCM
  format the worker sees. Octoroom converts to and from the adapter's
  48 kHz stereo, using the same converters as Subvocal's transport.
- `ctx` contains the room id, the worker id, input and output names, and the
  room's participant list at start. The worker can call `Octoroom.Room.state/1`
  for anything newer.
- Workers are plain processes, so a worker can delegate its media to anything:
  a Membrane pipeline, a Pythonx model, or a voice-agent library's session.
  That's how AI integrations plug in.
- Outlet pacing: an outlet sends one 20 ms frame per 20 ms tick from its queue
  and sends nothing when the queue is empty. `flush` empties the queue. The
  bound on what is already playing at Cloudflare is therefore one frame plus
  the network.

### Worker media transport

v1 uses Cloudflare's WebSocket adapters only: no UDP, ~170 ms slower. Keep
the worker contract media-agnostic so a later `transport: :webrtc` option can
run a worker's I/O over an `ex_webrtc` peer connection to Cloudflare
(Opus, lower latency, needs UDP egress) without the worker changing. The
outlet and inlet abstraction is where that split goes.

## AI integrations

Octoroom ships with no AI. Integrations implement `Octoroom.Worker` and live
outside this repository:

- **Subvocal:** an adapter in Subvocal turns an agent or a one-way pipeline
  (STT → translate → TTS) into a worker. This is how the interpretation demo
  gets its interpreter.
- Anything else that can take and produce PCM: a recorder writing per-track
  WAV/Opus files, a moderation classifier, a music bot.

Octoroom guarantees things that matter for AI workers without knowing
about AI: real-time pacing, `flush` for barge-in, per-input streams labelled
by participant (so a group agent knows who is talking), and `emit` for
captions and transcripts.

## Security

- Cloudflare credentials stay on the server. Clients never see a Cloudflare
  session id other than their own SDP.
- Only the room server calls Cloudflare, so a client cannot pull a track the
  policy didn't grant, even with a modified client.
- `join/2` runs the app's authorization; the channel's `connect/3` handles
  socket auth as usual.
- Adapter endpoint URLs are `<public_ws_url>/<role>/<random 128-bit id>`. The
  id is registered only while its inlet or outlet lives, and unknown ids get
  a 404. The deployment should expose only that path publicly, or at least
  rate-limit it.

## Failure and cleanup

| Event | Handling |
| --- | --- |
| Client disconnects | The channel's `terminate` (or the room server's monitor) removes the participant. The reconciler closes its subscriptions and stops workers whose inputs are gone. Cloudflare closes the browser session on its own when ICE fails. |
| Worker crashes | Its supervisor restarts it. The outlet and its track survive. Egress adapters are tied to the worker's inlet and are recreated. |
| Cloudflare call fails | Retried with backoff and capped. After the cap, the operation is dropped, `{:error, ...}` is emitted to the room, and the reconciler tries again on the next trigger. |
| Pull of a pending track times out | Shouldn't happen, because pulls wait for `:live`. If it does, the track goes back to `:pending`. |
| Room server crashes | The room supervisor is `rest_for_one`, so workers and outlets restart with it. The new room server recovers the room as after a deploy (see [Restarts and deploys](#restarts-and-deploys)). |
| Node restarts or deploys | See [Restarts and deploys](#restarts-and-deploys). |
| Leaked adapters | Every adapter id is written to `Octoroom.Store` with its room id and the run that created it, before Cloudflare is asked to create it. A janitor closes adapters whose room no longer exists or whose run has been replaced. Leaked adapters cost money, so this is v1 scope, not polish. |

## Restarts and deploys

A deploy, a node crash and a room server crash all lose the room's in-memory
state. They don't lose the room: most of it lives at Cloudflare and in the
browsers, and Octoroom rebuilds the rest from there.

### What survives

| Piece | Lives in | When the node goes away |
| --- | --- | --- |
| Browser ⇄ Cloudflare media (people hearing each other) | Cloudflare | **Keeps working.** The server isn't in that path. |
| Each browser's Cloudflare session and the tracks pulled into it | Cloudflare | Keeps working, as long as the peer connection stays up. |
| Phoenix channel (signaling) | The node | Drops. The Phoenix JS client reconnects on its own, with backoff. |
| Room server state: participants, track directory, operation queues | The node's memory | Lost, then rebuilt (below). |
| Worker processes and their in-memory state | The node | Lost. Workers are restarted. |
| Adapter WebSockets | The node | Drop. Worker audio stops. |
| Adapters at Cloudflare | Cloudflare | Stay open and billed until closed, unless Cloudflare closes them when the socket drops (to verify). |
| Adapter ids, room assigns, run id | `Octoroom.Store` | Survive. |

### Recovery

1. **Resume tokens.** The join reply carries a resume token: a signed
   `Phoenix.Token` with the room id, participant id, Cloudflare session id and
   the participant's `join/2` metadata. When the channel reconnects, the
   client rejoins with it. The signature stops a client from claiming
   another client's session. The token's max age is the longest outage a room
   survives (default 10 minutes). The client refreshes it when metadata
   changes.
2. **Adopt, don't reset.** The new room server takes the room's assigns from
   the store and starts a new *run* (an id recorded in the store). Each
   resuming client is re-added with the metadata from its token. Its
   Cloudflare session is read back (`GET` session state) and adopted: the
   tracks Cloudflare reports become the actual state, with their mids. The
   client also sends its current mid → track map, which must agree with
   Cloudflare's. If it doesn't, Cloudflare wins and the client is told to
   resync.
3. **Grace period.** For a configurable window after recovery (default 15 s),
   participants who haven't resumed yet don't count as having left: their
   subscriptions and the workers that depend on them are kept. When the
   window ends, anyone who hasn't come back is removed as an ordinary leave.
4. **Reconcile as usual.** For people, desired and actual state normally
   already match, so no renegotiation happens and nobody hears a gap.
5. **Workers restart** with new inlets and outlets, and so new adapters.
   Their output tracks are `:pending` until their first frame, then listeners
   pull them again. Listeners hear the worker go quiet for a few seconds.
   Workers start with `ctx.resumed: %{gone_ms: ms}` so they can tell a fresh
   start from a recovery.
6. **Close the previous run's adapters.** Everything in the store under an
   older run of this room is closed at Cloudflare and deleted. If adapters
   turn out to be redialable (see open questions), this step can reuse them
   instead.

The result: people don't notice, workers drop out for a few seconds, and
nothing leaks.

A client that comes back without a valid token (expired, or the browser
reloaded) joins as a new participant. Its old Cloudflare session dies on its
own when that peer connection closes.

### What stays the developer's job

Worker memory. An agent's conversation so far lives in the worker process,
and Octoroom can't snapshot it. A worker that needs to survive restarts
persists its own state, e.g. conversation history in the app's database
keyed by room id, and reloads it when `ctx.resumed` is set.

### `Octoroom.Store`

A behaviour with a small surface: room records (assigns, current run id) and
adapter records (`adapter_id, room_id, run_id, created_at`). It's written
before the Cloudflare call that creates an adapter, so a crash between the
two leaves a record the janitor can resolve.

- Default: ETS plus a DETS or file snapshot, enough for one node that
  restarts in place.
- Optional: Ecto (Postgres) and Redis implementations, for deploys that
  replace the machine or for clusters.

The store holds no participant state. Participants come back through their
resume tokens, so the store never has to be consistent with who is in the
room.

### Later: deploys without a worker gap

In a cluster, a node being shut down can drain: Phoenix's socket drainer
moves clients to other nodes gradually, and rooms are handed off with their
state (Horde-style). Workers would then restart on the new node before the
old one stops, and only the adapter switch-over would be audible. This
belongs with [Distribution](#distribution).

## Distribution

v1 is single-node. Things that change for a cluster:

- Room lookup moves to `:pg` or Horde, so any node's channel can find the
  room server.
- Cloudflare dials a public URL that a load balancer may send to any node.
  Either encode the owning node in the adapter URL and use sticky routing, or
  have `Octoroom.Plug` forward the socket's frames to the owning node over
  distribution. The second costs ~1.5 Mbit/s of cluster traffic per adapter.
  Decide this before v2.

## Testing

- `Octoroom.Reconciler.diff/2` gets property and table tests: desired plus
  actual state in, operations out.
- `Octoroom.Cloudflare` is a behaviour. The default implementation uses
  `Req`, and tests use an in-memory fake that models sessions, tracks,
  pending and live states, and the `empty_track_error` rule.
- The packet codec, audio conversion and pacing get unit tests, ported from
  Subvocal's.
- Integration tests against real Cloudflare are tagged `:cloudflare` and
  excluded by default. They need `OCTOROOM_PUBLIC_WS_URL` reachable from the
  internet.
- The JS client gets tests with a fake `RTCPeerConnection`. A Playwright test
  for two browsers in one room comes later.

## Dependencies

| Dep | Why | Optional |
| --- | --- | --- |
| `req` | Cloudflare API | no |
| `plug`, `websock_adapter` | `Octoroom.Plug` and adapter sockets | no |
| `jason` | JSON | no |
| `phoenix`, `phoenix_pubsub` | `Octoroom.Phoenix.Channel`, room events | yes. Without them, the core still runs and events go through `Registry`. |
| `telemetry` | Metrics for Cloudflare calls, reconcile ops and outlet underruns | no |

The browser client is an ES module in `priv/static/octoroom.mjs`, published to
npm later as `octoroom`.

## Prior work

Code to port from Subvocal (`lib/subvocal/transport/cloudflare_sfu/`),
renamed, with its tests:

| Subvocal module | Becomes | Notes |
| --- | --- | --- |
| `CloudflareSFU.API` | `Octoroom.Cloudflare.HTTP` | Error mapping for top-level and per-track errors. |
| `CloudflareSFU.Packet` | `Octoroom.Cloudflare.Packet` | Hand-rolled protobuf for three fields. |
| `CloudflareSFU.AdapterSocket`, `.Plug` | `Octoroom.Adapter.Socket`, `Octoroom.Plug` | Ingest sockets need `timeout: :infinity`. |
| `CloudflareSFU.Audio` | `Octoroom.Audio` | Generalize to any rate and channel count a worker asks for. |
| `CloudflareSFU` (signaling) | Room server and reconciler | The single-peer logic becomes multi-peer; the ingest "wait for first frames" handshake becomes track status. |
| `subvocal.mjs` `connectCloudflare` | `octoroom.mjs` | Full-SDP gathering with no trickle, plus timeouts. |

Also worth reading before writing the reconciler: Software Mansion's archived
`membrane_rtc_engine` and `fishjam`. They're Elixir room engines with their
own SFU, and their room, peer and track bookkeeping is a useful reference.

## Implementation notes (milestones 1–2)

Where the code differs from the draft above, and why:

- **Closing a subscription is client-offered.** Cloudflare's `tracks/close`
  takes the client's offer made after `transceiver.stop()`, so the server
  sends `close {mids, op_id}`, the client stops the transceivers and offers,
  and the server relays Cloudflare's answer. The server still decides what
  is closed. A client that doesn't answer any signaling request within 15 s
  is removed from the room, rather than left with Cloudflare and the browser
  disagreeing.
- **"Mic is live" comes from the client.** The client sends `connected` when
  its peer connection is up; the mic track then counts as `:live`. A pull
  that still hits `empty_track_error` is retried with backoff (0.5 s, 1 s,
  2 s, ...) and given up after five tries until the track is published
  again. A client that lies only delays others hearing it.
- **Pull results are per track.** A batched pull can partly fail; the offer
  covers the tracks Cloudflare added, and the failed ones are retried.
- **Room processes:** `Octoroom.Room.Server` sits directly under
  `Octoroom.RoomSupervisor`, and Cloudflare calls run under
  `Octoroom.TaskSupervisor`. The per-room `rest_for_one` supervisor arrives
  with workers and outlets in milestone 3.
- **Events go through `Registry`** (`Octoroom.Events`), not Phoenix PubSub,
  for now. `Octoroom.subscribe/1` also sends `{:published, participant}` and
  `{:subscriptions, participant_id, track_names}`, and
  `Octoroom.Room.state/1` returns who hears what, which the demo renders.
- **Gain** uses each remote track's `<audio>` element `volume` (0–1), which
  is equivalent to a `GainNode` for this range and avoids Chrome's need to
  attach WebRTC streams to a media element before Web Audio can read them.
- **Measured against real Cloudflare** with the `examples/call` demo, two
  and then three browser tabs on one Mac: joining (getUserMedia → published
  and connected) took ~1.1 s; every participant heard every other with no
  packet loss; after a leave Cloudflare closed the pull and reused the mid
  for the next one.

## Milestones

1. **Port the primitives.** Cloudflare client behind a behaviour with a fake,
   packet codec, adapter Plug and socket, audio conversion. Ported tests pass.
2. **Browser-to-browser rooms.** Room server, reconciler (participants and
   subscriptions only), channel, JS client. Two browsers hear each other,
   and leave/rejoin works. No workers.
3. **Workers.** Outlets with pacing and flush, inlets, worker supervision, the
   `DelayEcho` example, pending→live handling for worker outputs.
4. **Robustness.** Store, janitor, retries, resume tokens and recovery
   (restart the node mid-call: people keep talking, workers come back),
   telemetry, a LiveView demo app with Presence and captions from `emit`.
5. **Interpretation demo**, with the Subvocal adapter on the Subvocal side.
6. **Later:** WebRTC worker transport, clustering, video pass-through, Swift
   client.

## Open questions

- **Session per browser vs. per direction.** One session per browser means
  every new subscription renegotiates the whole connection. Separate publish
  and subscribe connections (two sessions) make subscription churn cheaper
  and isolate the mic. Measure renegotiation time in a 10-person room before
  deciding.
- **Mixing.** A listener in a room of 15 pulls 14+ tracks. A server-side
  mixer worker that produces one track per listener is possible, but costs
  adapter bandwidth both ways. When does it pay off?
- **Recovery depends on three Cloudflare behaviours to verify** with a spike
  before milestone 4:
  - Does session state (`GET` on a session) return enough to adopt it: track
    names, mids and status?
  - When an adapter's WebSocket drops, does Cloudflare redial the same URL,
    close the adapter, or keep billing a dead adapter? If it redials, workers
    could keep their adapters across a restart.
  - How long does a browser's session survive with no API calls at all?
    Expected: as long as the peer connection is up.
- **Speaking indicators.** Use client-side audio levels reported over the
  channel (cheap, spoofable), or levels computed by a worker (trustworthy,
  but needs an adapter per participant)?
- **Room lifetime.** Should empty rooms linger beyond the recovery grace
  period, and should rooms be startable from the server with no clients,
  e.g. a scheduled event with a bot waiting?
- **Cloudflare API drift.** The adapter API was in beta when the spike ran.
  Pin the fields we depend on in the fake, so drift shows up as one failing
  integration test.
- **Name collisions.** Check that `octoroom` is free on Hex and npm before
  the first release.
