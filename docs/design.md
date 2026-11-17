# Octoroom design

Status: **milestones 1–5 implemented** (2026-11-17), plus browser video
(steps 1–2 of [Video](#video); see [Implementation notes (video)](#implementation-notes-video)). Workers run over
WebRTC (milestone 4, see [Transport decision](#transport-decision-2026-11-17)
and [Implementation notes (milestone 4)](#implementation-notes-milestone-4)),
checked against real Cloudflare. Milestone 3 and robustness (milestone 5)
were built first, on Cloudflare's WebSocket adapters, and checked against
real Cloudflare then; see [Milestone 3 against real Cloudflare](#milestone-3-against-real-cloudflare-2026-11-17)
and [Implementation notes (robustness)](#implementation-notes-robustness).
See [Implementation notes](#implementation-notes-milestones-13) for where the
code differs from this draft, and [Implementation notes (bad input)](#implementation-notes-bad-input)
for how a room survives malformed client messages and failing callbacks.

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

The developer doesn't need to know WebRTC. Server-side participants join a
room the way browsers do, over WebRTC to Cloudflare at browser latency, and
the app needs no public endpoint for media, no inbound ports and no TURN
server: every media connection is one that a browser or the app opens to
Cloudflare. The server only needs outbound UDP, which most hosts allow.

## Goals

- Audio rooms with up to about 20 participants, and any number of server-side
  workers, in a Phoenix app that exposes nothing for media: no public media
  endpoint, no inbound ports, no TURN server. The server needs outbound UDP
  to Cloudflare.
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
- Video beyond browsers in v1. Browsers publish cameras and screen shares;
  simulcast and video for workers are later steps of [Video](#video).
- Native mobile SDKs beyond the Swift client in v1.
- Broadcast to thousands of passive listeners. HLS or MoQ fit that better.

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
  ]
```

That's all. There's no endpoint to mount and no public URL: workers' media
connections are outbound, so a worker runs the same on a laptop behind NAT
as in production. At startup Octoroom checks that it can reach Cloudflare
over UDP and fails with a clear error if it can't (see
[Worker media transport](#worker-media-transport)).

### The room callbacks

| Callback                        | Required | Default                                 | Answers                                                             |
| ------------------------------- | -------- | --------------------------------------- | ------------------------------------------------------------------- |
| `join(params, socket)`          | yes      |                                         | May this client join, and with what metadata?                       |
| `mount(room_id)`                | no       | `{:ok, %{}}`                            | Runs once when the room process starts. Returns the room's assigns. |
| `workers(room)`                 | no       | `[]`                                    | Which server-side participants should be running now?               |
| `subscriptions(listener, room)` | no       | `default_subscriptions(listener, room)` | What should this listener hear now?                                 |

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

| Helper                      | Returns                                                                   |
| --------------------------- | ------------------------------------------------------------------------- |
| `mic(participant)`          | That participant's mic track.                                             |
| `camera(p)`, `screen(p)`, `screen_audio(p)` | That participant's camera, screen share and screen audio (published when it turns them on). |
| `track(name)`               | A track by room-scoped name, e.g. a worker output `"alice/ja"`.           |
| `gain(track, 0.0..1.0)`     | The same audio track, played at that volume. Applied in the listener's browser. Raises for video. |
| `others(room, participant)` | Every participant except that one.                                        |
| `worker(id, module, opts)`  | A worker spec with `inputs:`, `outputs:` and `args:`.                     |

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
_other_ language in the room, and listeners hear the interpretation in their
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
  so Octoroom pulls the new input into the recorder's session. (Adding an
  input doesn't restart the worker; see [the reconcile loop](#the-reconcile-loop).)

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
import { RoomClient } from "octoroom";

const room = new RoomClient({
  socket,
  topic: `room:${id}`,
  params: { lang: "ja" },
});
room.on("participants", (list) => render(list));
await room.join(); // asks for the mic, publishes it, plays what the policy subscribes
room.setMuted(true);
await room.leave();
```

For LiveView, `Octoroom.subscribe(room_id)` sends the subscribing process
`{:octoroom, room_id, event}` messages: `:joined`, `:left`, `:speaking`,
`:worker_event` (whatever a worker chooses to emit, e.g. captions).

## Concepts

| Term            | Meaning                                                                                                                                                           |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Room**        | A named set of participants and workers, run by one `Octoroom.Room.Server` process. Created on first join and stopped when its last client leaves (configurable). |
| **Participant** | A connected client. Has an id, the metadata from `join/2`, and the tracks it publishes (`mic` in v1).                                                             |
| **Worker**      | A server-side participant: a supervised process that receives PCM from input tracks and sends PCM to output tracks.                                               |
| **Track**       | A room-scoped name such as `"alice/mic"` or `"alice/ja"`. Octoroom maps it to Cloudflare's `(sessionId, trackName)`.                                              |
| **Policy**      | The room module's `workers/1` and `subscriptions/2` (or their defaults): pure functions of room state that give the desired state.                                |
| **Reconciler**  | Diffs desired against actual state and produces Cloudflare operations. Pure; the room server executes its output.                                                 |

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
- **Each worker has one session too.** The worker's peer process holds an
  `ex_webrtc` peer connection to Cloudflare. The worker's inputs are pulled
  into that session (`location: "remote"`), the same call a browser
  subscription uses, and its outputs are pushed from it (`location:
"local"`). The room server decides what to push, pull and close; the
  peer makes its own session's Cloudflare calls and does the SDP
  in-process, so changing a worker's inputs costs one HTTP call and a local
  renegotiation, with no client round trip.
- **Track directory.** The room server keeps
  `track name -> {session_id, cf_track_name, status}`, where status is
  `:pending` (declared, not yet flowing) or `:live`.

### Transport decision (2026-11-17)

Milestones 1–3 connect workers through Cloudflare's WebSocket adapters:
Cloudflare converts each track to and from PCM and dials a WebSocket on the
app (`Octoroom.Plug`). It works (see
[Milestone 3 against real Cloudflare](#milestone-3-against-real-cloudflare-2026-11-17)),
but workers move to WebRTC peers, and the adapters go.

What the adapters cost:

- **A public URL.** Cloudflare has to dial the app, so every deployment needs
  a reachable `wss://` endpoint, and local development needs a tunnel. An
  unreachable URL shows up as Cloudflare answering 503 `internal_error`,
  which looks like an outage.
- **Latency.** The adapter path was ~170 ms slower than a server-side WebRTC
  peer in comparable runs of Subvocal's spike.
- **Bandwidth.** Each adapter carries 20 ms frames of 48 kHz stereo PCM in a
  protobuf `Packet`: ~1.5 Mbit/s each way, against ~32–64 kbit/s for Opus.
- **Clustering.** Cloudflare dials a URL that any node behind a load balancer
  may answer, so a cluster would need sticky routing or media forwarded
  between nodes.
- **Audio only, in beta.** Adapters carry PCM audio only, and the API was in
  beta when the spike ran.
- **Billing state.** Adapters are billed until closed, and closing an id
  answers 200 whether or not it exists (see
  [Recovery spike](#recovery-spike-2026-11-17)), so the room needs a store of
  adapter ids and a janitor.
- **Delivery quirks.** Ingest plays audio as fast as it arrives, and egress
  over TCP is bursty (gaps of 18 ms at p50 and 107 ms at p99).

What WebRTC costs instead:

- **Outbound UDP.** Cloudflare is ICE-lite with public addresses, so the
  app's peer opens every connection and replies return through the same NAT
  mapping: no inbound ports and no TURN server. A host that blocks outbound
  UDP (some corporate networks, Kubernetes with strict egress rules) can't
  run workers until it allows UDP to Cloudflare. Whether Cloudflare accepts
  ICE over TCP as a fallback is unverified.
- **A media stack in the app.** DTLS, SRTP and Opus run in the BEAM node
  through NIFs. Users must not have to install native libraries, so these
  need precompiled binaries (see [Open questions](#open-questions)).
- **CPU.** One Opus decode per worker input and one encode per output, work
  Cloudflare used to do.

Kept from the adapter work:

- **Outlet pacing and `flush`.** Cloudflare forwards packets as they arrive
  whatever the transport, so audio sent ahead of real time still plays after
  a barge-in.
- **Holding inlets to real time.** The 0.56% surplus measured in milestone 3
  may be the adapter's own, but sender clocks drift too and need the same
  guard.
- **The worker contract**, which doesn't change.

### Cloudflare constraints the reconciler has to respect

- `POST /sessions/new` must have **no body**; even `{}` returns a 400.
- **Empty tracks can't be pulled.** Cloudflare holds a pull of a track with no
  packets for ~8 s, then fails with `empty_track_error`. A subscription to a
  `:pending` track stays queued until the track's first packet. For
  browsers, that's when Cloudflare reports the track; for worker outputs,
  it's when the outlet sends its first packet.
- Cloudflare is ICE-lite, and it takes a complete SDP with no trickle ICE.
  Browsers gather host candidates and send the full offer. Server-side
  `ex_webrtc` peers needed aggressive nomination to connect (found in
  Subvocal's spike).
- Only one offer/answer exchange can be in flight per session. Changes to a
  session must be **serialized** and **batched**: several pulls go in one
  `tracks/new` call and need one renegotiation.
- **A session ends with its peer connection.** Once a peer connection
  closes, `GET` on its session answers `session_error` within a minute (see
  [Recovery spike](#recovery-spike-2026-11-17)). After a crash there is
  nothing at Cloudflare to close.

## Processes

```
Octoroom.Supervisor
├── Registry (Octoroom.Registry)                 rooms, peers, inlets and outlets by id
├── Octoroom.Store                               room assigns that outlive the node
├── DynamicSupervisor (Octoroom.RoomSupervisor)
│   └── per room: Supervisor (rest_for_one)
│       ├── Octoroom.Room.Server                 state, policy, reconciler, Cloudflare calls
│       ├── DynamicSupervisor (media)            one Peer per worker, plus its inlets and outlets
│       └── DynamicSupervisor (workers)          the developer's workers
└── Task.Supervisor (Octoroom.TaskSupervisor)    Cloudflare HTTP calls
```

Per client, the Phoenix channel process (from `Octoroom.Phoenix.Channel`)
handles signaling for that client's session and monitors the room server.

Decisions:

- **The room server is the single writer.** Policy evaluation, reconciliation
  and the track directory all live in one process, so ordering is never in
  doubt. Cloudflare HTTP calls run in tasks, so a slow pull (up to ~8 s)
  doesn't block joins or leaves. Results come back as messages, are applied
  to the actual state, and trigger another reconcile.
- **Media is separate from workers.** A worker's peer, inlets and outlets
  live under the media supervisor, not under the worker. An outlet paces
  audio to real time and holds its track's live status. If a worker crashes
  and restarts, its peer connection and output tracks stay up, so listeners
  keep their subscription and hear a gap, not a renegotiation.
- **Per-session operation queues.** The room server keeps one queue per
  Cloudflare session, browser or worker. Only the head operation is in flight, and the queued
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
   Starting a worker starts its peer (a new Cloudflare session), the
   worker, an outlet per output (a pushed track, `:pending` until its first
   packet) and an inlet per `:live` input (a pull into the worker's
   session).
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

- **Inputs changed:** inlets are added or removed (pulls into the worker's
  session opened or closed), and the worker gets `handle_info({:octoroom, :inputs, names},
state)`. It isn't restarted, so a recorder or a group agent can follow
  people joining and leaving.
- **Outputs changed:** outlets are added or removed. No restart.
- **Module or args changed:** the worker is restarted. Outlets whose names
  are unchanged are kept, so listeners don't renegotiate.

## Signaling protocol (channel ⇄ client)

The client holds one `RTCPeerConnection` to Cloudflare. The server tells it
what each transceiver is.

| Direction       | Message                  | Payload                                                                                                      |
| --------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------ |
| join reply      |                          | `{participant_id, ice_servers, participants, resume_token}` (no `resume_token` until milestone 4)            |
| client → server | join with `resume_token` | `{resume_token, mids: {mid => track}}` after a reconnect (see [Restarts and deploys](#restarts-and-deploys)) |
| server → client | `resume_token`           | a refreshed token after a metadata change                                                                    |
| server → client | `resync`                 | `{tracks: [{mid, track, participant_id, gain}]}` when the client's view disagreed with Cloudflare's          |
| client → server | `publish`                | `{sdp: offer, mids: {mic: "0", camera: "1"}}`: creates the session |
| server → client | reply                    | `{sdp: answer}`                                                                                              |
| client → server | `connected`              | `{}` once the peer connection is up (and again after each `push`), so what it published is flowing and can be pulled |
| client → server | `publish_tracks`         | `{sources: ["camera"]}` once the session exists; replied to once Cloudflare has the tracks |
| server → client | `push`                   | `{op_id, sources}`: this session's turn to add those transceivers |
| client → server | `push_offer`             | `{op_id, sdp, mids}`; the reply is `{sdp: answer}` |
| client → server | `unpublish`              | `{source}`: every pull of it closes, then the server sends `close` for its mid |
| client → server | `mute`                   | `{source, muted}`; others see `participant.tracks[source].muted` |
| server → client | `renegotiate`            | `{sdp: offer, op_id}` (Cloudflare's offer after a pull or close)                                             |
| client → server | `answer`                 | `{sdp, op_id}`                                                                                               |
| server → client | `close`                  | `{mids, op_id}`: stop these transceivers                                                                     |
| client → server | `close_offer`            | `{sdp, op_id}`, the offer made after stopping them; the reply is `{sdp: answer}`                             |
| server → client | `tracks`                 | `{added: [{mid, track, kind, source, participant_id, gain}], removed: [mid]}` |
| server → client | `gain`                   | `{mid, gain}`                                                                                                |
| server → client | `room_event`             | joins, leaves, speaking, worker events                                                                       |

`op_id` ties an answer to the operation that asked for it, so a late answer
after a reconnect is rejected instead of applied to the wrong state. The
client applies `tracks` only after the matching renegotiation completes, so
mids always refer to transceivers that exist.

A client message with a known event but a body of the wrong shape (a
`mids` that isn't a map of strings, a non-string `sdp`) gets the error reply
`{reason: "bad_payload"}`; an unknown event gets `unknown_event`.

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
  format the worker sees. Octoroom decodes Opus (48 kHz) and converts to
  that format, and converts back before encoding.
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

Workers' media runs over WebRTC (see
[Transport decision](#transport-decision-2026-11-17)). Each worker gets:

- **A peer** (`Octoroom.Peer`). It owns the `ex_webrtc` peer connection and
  the worker's Cloudflare session. It answers Cloudflare's offers after a
  pull, makes offers for pushes and closes, and routes RTP between the
  connection and the worker's inlets and outlets. The room server tells it
  what to push, pull and close (`Peer.push/4`, `pull/4`, `close/2`) and
  hears back as `{:peer_result, ...}`; the peer carries it out against its
  own session, one offer/answer exchange at a time, batching requests that
  queue up. Its Cloudflare calls run in tasks, so it keeps routing RTP
  while one is pending.
- **An inlet per input.** A jitter buffer for the RTP stream, Opus decode,
  conversion to the worker's format and the hold to real time. It sends the
  worker 20 ms of PCM at a time by registered name, so a restarted worker
  picks up the same streams.
- **An outlet per output.** The queue, pacing and `flush` as before, then
  Opus encode and RTP packetization. Its track is `:pending` until its first
  packet goes out.

Inlets and outlets are separate processes so that decoding and encoding
spread over schedulers instead of queueing behind the peer.

Connectivity: the peer gathers host candidates only (no STUN) and
Cloudflare learns the app's public address from the connectivity checks,
so NAT needs no configuration. Extra `ExWebRTC.PeerConnection` options come
from `config :octoroom, :webrtc, [...]`; some hosts need them, such as
Fly.io's ICE IP filter (`ExWebRTC.ICE.FlyIpFilter`, as Subvocal's
`Subvocal.Transport.WebRTC.ICEOptions` sets it). A peer whose connection
isn't up 10 s after its first negotiation, or whose ICE fails, logs an
error saying workers need outbound UDP to Cloudflare and stops; the room
retries with backoff and gives up after five tries. (This replaces the
startup check planned earlier: failing the app's boot on a network problem
would take browser calls down with it.)

The peer connection sits behind `Octoroom.Peer.Media`. Tests use a fake
(`Octoroom.Test.FakePeerMedia`) that moves PCM in-process, and another
transport (another SFU, or WebSocket adapters if a deployment can't use
UDP) would plug in there without the worker or the room server changing.

## Video

Steps 1 and 2 of [Order](#order) are built (see
[Implementation notes (video)](#implementation-notes-video)); the rest is
the plan. Video falls into three parts, from cheapest to most expensive:
browser-to-browser video, bandwidth control in bigger rooms, and workers
that see or produce video.

### Transport

- **Browser video needs nothing new on the server.** Browsers already speak
  WebRTC to Cloudflare, and a camera is one more track on the peer
  connection each browser already has. The server only signals.
- **Workers already speak WebRTC** (see
  [Worker media transport](#worker-media-transport)), so a worker pulls a
  camera track the same way it pulls a mic. What video adds for workers is
  decoding, not networking.

### Publications

Today each participant has exactly one track: the room server hardcodes
`"mic"`, and a participant's `mic: :none | :publishing | :pending | :live`
allows a single `publish`. Video replaces that with a map of publications
keyed by source, following LiveKit:

```elixir
tracks: %{"mic" => :live, "camera" => :pending, "screen" => :none}
```

- **Sources** are `mic`, `camera`, `screen` and `screen_audio`. A source
  is easier for policy and permissions to refer to than a free-form name.
  Room-scoped names stay `"<participant>/<source>"`.
- **Publish and unpublish at any time.** Turning the camera on or starting a
  screen share is a new `publish` (a pushed track and one renegotiation).
  Stopping is an unpublish, which closes every pull of that track. Both go
  through the per-session operation queue like any other change.
- **What a participant may publish** comes from `join/2` metadata, like
  LiveKit's `canPublishSources`. The room server rejects any other source.
- **Mute is not unpublish.** A muted track keeps its transceiver, the
  publisher stops sending, and subscribers see a `muted` flag. Nothing
  renegotiates. Muting the camera uses `track.enabled = false` (the browser
  sends black frames, so the track stays pullable), not
  `replaceTrack(null)`, which stops packets and would stall new pulls (see
  `empty_track_error` in [Cloudflare constraints](#cloudflare-constraints-the-reconciler-has-to-respect)).
  _To verify:_ does a pull stay healthy when its track goes quiet after it
  went live?

Room API additions: `camera(p)` and `screen(p)` next to `mic(p)`.
`Octoroom.Track` gains `kind` (`:audio` or `:video`). `gain/2` applies only
to audio, and video gets `quality/2` (below). The `tracks` channel payload
carries `kind` and `source`, so the client knows whether to create a media
element for audio or for video.

### Bandwidth: simulcast and quality as policy

With 20 people all watching each other, each browser downloads 19 video
streams. That needs simulcast: cameras publish two or three layers (for
example quarter, half and full resolution), and each subscription chooses
one. The default is simulcast on for cameras and off for screen shares,
which favor one sharp layer. Cloudflare's pull API has simulcast options;
check its current parameters before building on them.

Quality is a subscription option, set by policy like gain:

```elixir
def subscriptions(listener, room) do
  speaker = room.assigns.active_speaker

  for p <- others(room, listener), track <- [mic(p), camera(p)] do
    if track.kind == :video and p.id != speaker, do: quality(track, :low), else: track
  end
end
```

- **Changing a layer must not renegotiate.** The active speaker changes
  every few seconds, and `subscriptions/2` reruns each time. The reconciler
  keeps pulls stable and emits `{:update_subscription, ...}` for a layer
  change, just as it does for gain. Closing and re-pulling would mean an SDP
  round trip on every speaker change.
- **Unwatched layers are paused at the publisher** (LiveKit calls this
  dynacast). The room server already knows which layers every subscription
  uses, because it computes them. The reconciler emits
  `{:set_layers, publisher, source, active_layers}`, and the publisher's
  client applies it with `RTCRtpSender.setParameters` (`active: false` on
  unused encodings). If nobody watches the full-resolution layer, nobody
  encodes or uploads it. This needs nothing from Cloudflare.
- **The client may lower quality but never raise it** (LiveKit's adaptive
  stream, bounded by the server). The policy sets the maximum layer per
  subscription. The client may ask for a lower one when the `<video>`
  element is small or hidden. It can never go above the cap or receive a
  track the policy didn't grant.
- **Congestion** (bandwidth estimation per subscriber, dropping layers by
  priority) happens inside the SFU. Octoroom gets whatever Cloudflare does
  and can't add it from outside.

### Video for workers

Most AI uses of video don't need a decoded stream. Several have cheaper
options:

| Need                                           | Without decoding video on the server                                                                                                                                                                                              |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A vision agent looks at a participant's camera | That participant's browser grabs a frame, about once a second or when the participant starts speaking, and uploads a JPEG over the channel. The worker receives it in `handle_info/2`. Vision models want snapshots, not streams. |
| Recording                                      | Each browser records its own tracks with `MediaRecorder` and uploads chunks. Quality depends on the client, and a crash or early leave loses the end of that participant's recording.                                             |
| An avatar agent                                | The browser draws the avatar. The worker `emit`s mouth-shape timings or animation events alongside its audio, and no video track exists.                                                                                          |

The upload options have one cost: the client decides what it sends, which
breaks [server-authoritative routing](#security) for that input. That's fine
for "the agent sees my camera" and wrong for "a moderator watches
everyone". The upload has to be opted into per worker input, and the docs
need to say it's client-supplied.

When a worker needs real video (trusted inputs, server-side compositing,
high-quality recording), it pulls the track into its peer like audio:

- **Input:** the inlet's peer receives VP8 or H.264 over RTP. A recorder can
  write RTP straight into WebM or MKV with no decoding. Anything else decodes
  through Membrane or FFmpeg NIFs (Xav). Decoding is the real cost here, not
  networking.
- **Worker API:** `use Octoroom.Worker, video: [fps: 1, format: :rgb]` and
  `handle_video(input, frame, state)`, next to `handle_audio/3`. Most workers
  want the latest frame on demand rather than every frame, so inlets keep
  only the latest decoded frame and drop the rest, and a worker can ask for
  that frame when it needs one.
- **Output:** a `play_video` action for avatars or generated video, encoded
  and paced by the outlet the same way audio is.

Only inlets and outlets learn about video. The peer and the reconciler
already handle any track.

### Order

1. Map of publications in the room server, `kind` and `source` in `Track`
   and the `tracks` payload. Do this before v1 ships, because the single
   mic field spreads through the room server, the reconciler and recovery.
2. Camera and screen publishing, mute, `<video>` rendering in the client.
3. Simulcast, `quality/2` and publisher-side layer pausing.
4. Frame upload over the channel for vision workers.
5. Video inlets and outlets with `handle_video/3`, when a use case can't
   trust the client.

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

## Telephony

Not in v1. This section records the plan for phone callers in a room, e.g.
Example 3 with the customer on a phone instead of a browser.

A 1:1 call between a phone and an AI agent doesn't need Octoroom: a voice
agent library can talk to the phone service directly. Octoroom is for calls
with several parties, such as a caller, a human agent in a browser, a
private coach, a supervisor and a recorder.

### Telephony and the SFU are separate

Cloudflare Realtime SFU has no SIP or phone network support, so a phone call
can't reach a room through Cloudflare. Something has to bridge the call in
as one more participant. Room policy doesn't care how a participant's audio
arrives, so telephony lives at the edge and the reconciler stays the same.
The one thing the SFU can't do for a phone leg is **mixing**: a phone call
carries one audio stream, so whatever the caller should hear has to be mixed
into one stream first.

### How LiveKit does it (read 2026-11-17)

From LiveKit's docs and the `livekit/sip` source:

- **SIP service.** A separate Go service that needs SIP on port 5060, RTP
  on UDP 10000–20000, a public IP, and the same Redis as `livekit-server`.
  For each call it joins the room as an ordinary WebRTC client through
  LiveKit's own Go server SDK:
  - it publishes the caller's voice as one Opus track;
  - it subscribes to every audio track in the room (auto-subscribe is off,
    but it subscribes on each `OnTrackPublished`), decodes each one, puts
    it through an optional jitter buffer per track and into one mixer, and
    encodes the mix to G.711 or G.722 for the phone.
    It has no routing of its own: the caller hears the whole room.
- **SIP participants** have `kind = SIP` and attributes such as
  `sip.callStatus` (`dialing`, `ringing`, `automation`, `active`, `hangup`),
  `sip.phoneNumber` and `sip.trunkID`.
- **DTMF** tones from the caller become `SipDTMF` data packets in the room;
  packets sent back are played to the phone as RFC 4733 events.
- **Inbound trunks and dispatch rules** decide which room a call joins:
  - _individual:_ a new room per caller;
  - _direct:_ one fixed room, with an optional PIN;
  - _callee:_ a room named after the dialed number.
    Rules can also set attributes and metadata and dispatch agents.
- **Outbound calls** use `CreateSIPParticipant`. **Transfers:** cold
  transfer via SIP REFER, and warm transfer with an agent's help.
  SIP REGISTER, SIPREC and video aren't supported.
- **Connectors** (Twilio, WhatsApp) bridge without SIP. The Twilio
  connector takes Twilio Media Streams over a WebSocket that LiveKit hosts,
  and the call joins as a participant with `kind = CONNECTOR`. It runs only
  on LiveKit Cloud, and the docs recommend SIP trunking for more features.

Sources: [telephony overview](https://docs.livekit.io/sip/),
[dispatch rules](https://docs.livekit.io/telephony/accepting-calls/dispatch-rule.md),
[SIP participant](https://docs.livekit.io/reference/telephony/sip-participant.md),
[self-hosting SIP](https://docs.livekit.io/transport/self-hosting/sip-server.md),
[Twilio connector](https://docs.livekit.io/telephony/connectors/twilio/),
[`livekit/sip`](https://github.com/livekit/sip) (`pkg/sip/room.go`,
`pkg/sip/media_codecs.go`).

### Plan: phone callers over the phone service's WebSocket

This is LiveKit's connector pattern, with the bridge running in the app's
own Phoenix server. Twilio Media Streams, Telnyx, Vonage and Plivo all
stream a call's audio over a WebSocket.

Phone callers are the one feature that needs a public endpoint: the
provider has to reach the app, both for its webhooks and for the call's
audio stream. That WebSocket comes from the phone provider and has nothing
to do with Cloudflare. The bridge's room side is an ordinary worker peer.

- **A phone caller is a participant to the policy and a worker underneath.**
  The caller appears in `room.participants` with `kind: :phone`, and
  `mic(caller)` and `subscriptions(caller, room)` work as they do for
  browsers. Example 3's `subscriptions/2` works unchanged when the
  customer phones in. Under the hood, the room server runs a bridge worker
  per phone participant:
  - **inputs:** the tracks `subscriptions(caller, room)` returns, pulled
    into the bridge's peer instead of a browser's;
  - **output:** `"<id>/mic"`, a track pushed from the bridge's peer and fed
    by the caller's audio.
    Routing stays server-authoritative, unlike LiveKit's SIP bridge, where
    the caller hears everything.
- **Routing a call to a room.** The phone service's webhook goes to
  `Octoroom.Phone.Plug`. It checks the provider's signature, then asks the
  app's router where the call goes. This is the counterpart of `join/2` and
  of LiveKit's dispatch rules:

  ```elixir
  # router.ex
  forward "/phone", Octoroom.Phone.Plug,
    provider: Octoroom.Phone.Twilio,
    router: MyApp.PhoneRouter

  defmodule MyApp.PhoneRouter do
    @behaviour Octoroom.Phone.Router

    @impl true
    def route(%{from: from, to: _to}) do
      case MyApp.Support.ticket_for_caller(from) do
        {:ok, ticket} ->
          {:ok, MyApp.SupportRoom, "support:#{ticket.id}",
           %{role: :customer, barged_in: false}}

        :error ->
          {:reject, :unknown_caller}
      end
    end
  end
  ```

  The plug answers with the provider's markup (TwiML `<Connect><Stream>`
  for Twilio), pointing at a stream URL with a signed, single-use token.

- **Mixing.** The bridge mixes its inputs into one stream at the phone's
  rate: 8 kHz μ-law for Twilio, 16 kHz linear PCM where the provider allows.
  Each inlet already runs a jitter buffer and holds its input to real time
  (see [Worker media transport](#worker-media-transport)), which is the
  buffering a mixer needs.
- **Pacing and barge-in.** Audio from the phone is already real time and
  goes through the outlet as usual. Audio to the phone is paced the same
  way. Whether each provider plays early audio as fast as it arrives, as
  Cloudflare does, needs checking. `flush` on the caller's output also sends
  the provider's clear message (Twilio's `clear`).
- **DTMF** becomes a room event, `{:dtmf, participant_id, digit}`, on PubSub.
  The room module still has no event handling: the app reacts (for example
  with `update_meta`), and the policy re-runs.
- **Call status** (`:dialing`, `:ringing`, `:active`, `:ended`) is in the
  participant's metadata, so a LiveView can show it.
- **Outbound calls.** `Octoroom.Phone.dial(room_id, number, meta)` calls the
  provider's REST API with the stream URL. The participant appears with
  status `:dialing`. A room that a call dials out from may have no browsers
  yet, which depends on [Room lifetime](#open-questions).
- **Hangup and transfer.** The stream closing means the participant left,
  and the normal reconcile cleans up. `Octoroom.Phone.hangup/2` ends a call
  through the provider's API. A warm transfer needs no telephony feature:
  the agent dials the third party into the room, talks to them, then
  leaves. A cold transfer is a provider API call that moves the call
  elsewhere, and the participant leaves.
- **Providers** sit behind `Octoroom.Phone.Provider`: webhook signature
  check, markup, stream wire format, dial, hangup, clear and transfer.
  Twilio first. Wire formats differ: Twilio sends JSON with base64 μ-law at
  8 kHz, while Vonage sends binary 16 kHz linear PCM.
- **Privacy.** Phone numbers are personal data. Unlike LiveKit's
  _individual_ dispatch rule, which puts the caller's number in the room
  name, Octoroom never puts numbers in room ids, track names or logs.

Costs:

- **Server work.** A phone participant costs one pushed track and one pull
  per track it hears: an Opus decode per pull, then a mix and a μ-law
  encode for the phone, and the reverse for the caller's voice. Fine for a
  support call. A conference with many callers would want one shared mix
  per group of callers who hear the same tracks (see the Mixing open
  question).
- **Latency.** Each direction adds a hop through the app on top of the
  phone network and the provider's own buffering. Measure it with a clap
  from a phone to a browser before promising conversational latency.

### Later: SIP

SIP trunks are needed for carriers that only offer SIP, for SIP REFER, and
for lower latency. Doing it the way LiveKit does needs a SIP and RTP stack
with inbound UDP ports, which breaks "no inbound ports". There are two ways
to get it:

- an external SIP-to-WebRTC gateway that joins rooms as a client;
- a SIP bridge worker, whose room side is the normal worker peer (see
  [Worker media transport](#worker-media-transport)), so only the SIP and
  RTP side is new.

Either one keeps `kind: :phone`, the router and the policy unchanged.

## Security

- Cloudflare credentials stay on the server. Clients never see a Cloudflare
  session id other than their own SDP.
- Only the room server calls Cloudflare, so a client cannot pull a track the
  policy didn't grant, even with a modified client.
- `join/2` runs the app's authorization; the channel's `connect/3` handles
  socket auth as usual.
- Nothing listens for media. Browsers and worker peers both connect out to
  Cloudflare, so there's no media endpoint to protect. Phone callers add
  the provider's webhook and stream endpoint (see [Telephony](#telephony)),
  which checks the provider's signature and a single-use stream token.

## Failure and cleanup

| Event                             | Handling                                                                                                                                                                                                                                       |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Client disconnects                | The channel's `terminate` (or the room server's monitor) removes the participant. The reconciler closes its subscriptions and stops workers whose inputs are gone. Cloudflare closes the browser session on its own when ICE fails.            |
| Worker crashes                    | The room server restarts it with backoff. Its peer, inlets, outlets and tracks survive, so nothing at Cloudflare changes.                                                                                                                      |
| Worker peer connection fails      | The peer is restarted with a new session. Its output tracks go back to `:pending`; listeners' pulls of the old tracks are closed and re-pulled once the new ones are live.                                                                     |
| Cloudflare call fails             | Retried with backoff and capped. After the cap, the operation is dropped, `{:error, ...}` is emitted to the room, and the reconciler tries again on the next trigger.                                                                          |
| Pull of a pending track times out | Shouldn't happen, because pulls wait for `:live`. If it does, the track goes back to `:pending`.                                                                                                                                               |
| Bad client payload                | Refused with a `bad_payload` reply, by the channel and again by the room server, so it can't crash the room. See [Implementation notes (bad input)](#implementation-notes-bad-input). |
| Room callback raises              | `workers/1` or `subscriptions/2` raising, throwing, exiting or returning the wrong shape keeps its last good answer, and is logged, broadcast and emitted as telemetry. See [Implementation notes (bad input)](#implementation-notes-bad-input). |
| Room server crashes               | The room supervisor is `rest_for_one`, so workers and outlets restart with it. The new room server recovers the room as after a deploy (see [Restarts and deploys](#restarts-and-deploys)).                                                    |
| Node restarts or deploys          | See [Restarts and deploys](#restarts-and-deploys).                                                                                                                                                                                             |
| Worker peer doesn't connect       | After 10 s (or when ICE fails) it logs that workers need outbound UDP to Cloudflare and stops; the room retries with backoff and gives up after five tries, broadcasting `{:error, {:peer, worker_id}, reason}`.                               |
| Leaked sessions                   | None to clean up. A worker's session ends when its peer connection closes, including when the node dies (Cloudflare reports it disconnected within a minute). `Octoroom.Janitor` only deletes room records no resume token can reach any more. |

## Restarts and deploys

A deploy, a node crash and a room server crash all lose the room's in-memory
state. They don't lose the room: most of it lives at Cloudflare and in the
browsers, and Octoroom rebuilds the rest from there.

### What survives

| Piece                                                              | Lives in                | When the node goes away                                                                                                        |
| ------------------------------------------------------------------ | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Browser ⇄ Cloudflare media (people hearing each other)             | Cloudflare              | **Keeps working.** The server isn't in that path.                                                                              |
| Each browser's Cloudflare session and the tracks pulled into it    | Cloudflare              | Keeps working, as long as the peer connection stays up.                                                                        |
| Phoenix channel (signaling)                                        | The node                | Drops. The Phoenix JS client reconnects on its own, with backoff.                                                              |
| Room server state: participants, track directory, operation queues | The node's memory       | Lost, then rebuilt (below).                                                                                                    |
| Worker processes and their in-memory state                         | The node                | Lost. Workers are restarted.                                                                                                   |
| Worker peer connections and their Cloudflare sessions              | The node and Cloudflare | Drop. The sessions turn disconnected within a minute, so worker output tracks are dead to listeners. Nothing is left to close. |
| Room assigns                                                       | `Octoroom.Store`        | Survive.                                                                                                                       |

### Recovery

1. **Resume tokens.** The join reply carries a resume token: an encrypted
   `Phoenix.Token` with the room id, participant id, Cloudflare session id and
   the participant's `join/2` metadata (encrypted, so the client can't read
   the metadata either). When the channel reconnects, the client rejoins
   with it. The token stops a client from claiming another client's session.
   Its max age is the longest outage a room survives (default 10 minutes).
   The server pushes a fresh one when the session is created and when
   metadata changes.
2. **Adopt, don't reset.** The new room server takes the room's assigns from
   the store. Each resuming client is re-added with the metadata from its
   token. Its Cloudflare session is read back (`GET` session state) and
   adopted: the tracks Cloudflare reports become the actual state, with
   their mids. Mics are named `<participant id>/mic` at Cloudflare, so a
   pulled track says whose mic it is. The server then sends the client the
   complete list of what it hears (`tracks` with `reset: true`), and the
   client keeps what matches and drops the rest: Cloudflare wins.
3. **Grace period.** For a configurable window after recovery (default 60 s;
   browsers can hold a background tab's reconnect back that long),
   participants who haven't resumed yet don't count as having left: pulls of
   their mics are held. When the window ends, anyone who hasn't come back is
   removed as an ordinary leave. Workers that depend on them start when they
   come back.
4. **Reconcile as usual.** For people, desired and actual state normally
   already match, so no renegotiation happens and nobody hears a gap.
5. **Workers restart** with new peers, so new sessions, inlets and
   outlets. Listeners' pulls of the old worker tracks are closed, and the
   new tracks are pulled once their first packet goes out. Listeners hear
   the worker go quiet for a few seconds. Workers start with
   `ctx.resumed: %{gone_ms: ms}` so they can tell a fresh start from a
   recovery.

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

A behaviour with a small surface: room records (the room's assigns and
run). Worker sessions need no records, because they end with their peer
connections. `Octoroom.Janitor` deletes room records older than a resume
token's max age.

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
old one stops, and only the switch to the new worker peers would be
audible. This
belongs with [Distribution](#distribution).

## Distribution

v1 is single-node. Things that change for a cluster:

- Room lookup moves to `:pg` or Horde, so any node's channel can find the
  room server.
- Media needs no routing. Worker peers connect out from the node that owns
  the room, so a load balancer never has to find the right node for media.
- Phone streams (see [Telephony](#telephony)) are the exception: the
  provider dials in, so the stream URL encodes the owning node for sticky
  routing, or the endpoint forwards frames to the owning node.

## Testing

- `Octoroom.Reconciler.diff/2` gets property and table tests: desired plus
  actual state in, operations out.
- `Octoroom.Cloudflare` is a behaviour. The default implementation uses
  `Req`, and tests use an in-memory fake that models sessions, tracks,
  pending and live states, and the `empty_track_error` rule.
- Audio conversion, the Opus round trip, the inlet's jitter buffer and
  outlet pacing get unit tests. Room and worker tests run the real
  `Octoroom.Peer` over a fake peer connection (`Octoroom.Test.FakePeerMedia`)
  that moves PCM in-process, so they need no UDP.
- Integration tests against real Cloudflare are tagged `:cloudflare` and
  excluded by default. They need Cloudflare credentials and outbound UDP,
  and no public URL or tunnel.
- The JS client gets tests with a fake `RTCPeerConnection`. A Playwright test
  for two browsers in one room comes later.

## Dependencies

| Dep                         | Why                                                                                                                        | Optional                                                                 |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| `req`                       | Cloudflare API                                                                                                             | no                                                                       |
| `ex_webrtc`                 | Worker peer connections. Its DTLS and SRTP use NIFs.                                                                       | no                                                                       |
| `membrane_opus_plugin`      | Only its Opus NIFs (`Membrane.Opus.{Encoder,Decoder}.Native`), for inlets and outlets. It downloads a precompiled libopus. | no                                                                       |
| `plug`, `websock_adapter`   | The phone provider's webhook and stream endpoint                                                                           | yes                                                                      |
| `jason`                     | JSON                                                                                                                       | no                                                                       |
| `phoenix`, `phoenix_pubsub` | `Octoroom.Phoenix.Channel`, room events                                                                                    | yes. Without them, the core still runs and events go through `Registry`. |
| `telemetry`                 | Metrics for Cloudflare calls, reconcile ops and outlet underruns                                                           | no                                                                       |

The browser client is an ES module in `priv/static/octoroom.mjs`, published to
npm later as `octoroom`.

## Prior work

Code to port from Subvocal (`lib/subvocal/transport/cloudflare_sfu/`),
renamed, with its tests:

| Subvocal module                        | Becomes                                    | Notes                                                                                                        |
| -------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| `CloudflareSFU.API`                    | `Octoroom.Cloudflare.HTTP`                 | Error mapping for top-level and per-track errors.                                                            |
| `CloudflareSFU.Packet`                 | `Octoroom.Cloudflare.Packet`               | Hand-rolled protobuf for three fields.                                                                       |
| `CloudflareSFU.AdapterSocket`, `.Plug` | `Octoroom.Adapter.Socket`, `Octoroom.Plug` | Ingest sockets need `timeout: :infinity`.                                                                    |
| `CloudflareSFU.Audio`                  | `Octoroom.Audio`                           | Generalize to any rate and channel count a worker asks for.                                                  |
| `CloudflareSFU` (signaling)            | Room server and reconciler                 | The single-peer logic becomes multi-peer; the ingest "wait for first frames" handshake becomes track status. |
| `subvocal.mjs` `connectCloudflare`     | `octoroom.mjs`                             | Full-SDP gathering with no trickle, plus timeouts.                                                           |

`Octoroom.Cloudflare.Packet`, `Octoroom.Adapter.Socket` and `Octoroom.Plug`
were ported for milestones 1–3 and go away in milestone 4. For the peer,
start from Subvocal's WebRTC transport (`lib/subvocal/transport/webrtc*`):
it runs `ex_webrtc` and `membrane_opus_plugin`, with ICE options for Fly.io.

Also worth reading before writing the reconciler: Software Mansion's archived
`membrane_rtc_engine` and `fishjam`. They're Elixir room engines with their
own SFU, and their room, peer and track bookkeeping is a useful reference.

## Implementation notes (milestones 1–3)

Where the code differs from the draft above, and why. Milestones 1–3
connect workers through WebSocket adapters, which
[the transport decision](#transport-decision-2026-11-17) replaces with
WebRTC in milestone 4. Notes about adapters, `public_ws_url` and
`Octoroom.Plug` describe that code until then; the rest still applies.

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

Milestone 3 (workers):

- **Inlets are processes**, one per (worker, live input), under the room's
  media supervisor next to the outlets. An inlet owns its egress adapter's
  socket and forwards frames to the worker by registered name, so a
  restarted worker picks up the same streams: egress adapters are _not_
  recreated when a worker crashes (the draft said they would be).
- **The room server restarts crashed workers**, not a supervisor's restart
  strategy. Workers are temporary children of the room's workers
  supervisor; the room server monitors them, and a crash becomes a
  `{:worker, id}` failure with the same backoff as pulls (0.5 s, 1 s, ...,
  given up after five). A worker that ran 30 s before crashing starts its
  backoff afresh. `{:worker_down, id, reason}` goes to the room's
  subscribers.
- **Per-room supervisor** (`Octoroom.Room.Supervisor`, `rest_for_one`): the
  room server, then a media supervisor (inlets and outlets), then a workers
  supervisor. Cloudflare calls still run under the global
  `Octoroom.TaskSupervisor`. The room server is a `significant` child, so
  when it stops the room shuts down; the server traps exits so its
  `terminate/2` closes every adapter the room still holds.
- **Reconciler:** `Reconciler.diff_workers/2` is a second pure diff next to
  `diff/2`. It produces `stop_inlet`, `stop_outlet`, `stop_worker`,
  `start_worker`/`restart_worker`/`update_worker`, `start_outlet` and
  `start_inlet`, in that order. Worker specs are reconciled first on every
  reconcile, so `room.workers` (the specs) is current when
  `subscriptions/2` runs. Joining now reconciles too, so a participant's
  workers start before its mic is live.
- **Adapters are created in one batched call per reconcile**, after the
  owning outlet or inlet has registered its id (Cloudflare may dial before
  the HTTP response returns). An outlet that sends its first frame before
  its adapter's response arrives is marked live when the response does.
  An adapter whose owner stopped in the meantime is closed at once.
- **Outlets drop audio that comes due before Cloudflare dials in**, rather
  than holding it, as a live stream would. The clock stops when the queue
  runs dry and restarts on the next `play`; a lag over 100 ms restarts it
  rather than sending a burst. `Octoroom.Outlet.stats/2` reports queued
  ms, frames sent and dropped, and underruns.
- **Ingest track names** at Cloudflare are `"out-" <> base64url(name)`;
  each ingest adapter gets its own Cloudflare session.
- **Worker events** (`emit`) go to `Octoroom.subscribe/1` subscribers as
  `{:worker_event, id, event}`, not to browsers over the channel yet.
  `Octoroom.Worker.send/3` reaches a worker's `handle_info/2` from outside,
  for example to flush from a LiveView.
- **`tracks` payloads** carry `worker_id` (nil for mics), and
  `participant_id` is nil for worker outputs.
- **Without `public_ws_url`** workers still run, but no adapters are
  created and the room logs an error once.
- **Cloudflare dials the endpoint while creating an adapter** (observed
  2026-11-17). If it can't connect, `POST /adapters/websocket/new` answers
  503 with `internal_error` / "Backend error" for each track, even for the
  spike's exact request. So an unreachable `public_ws_url` looks like a
  Cloudflare outage: the room retries with backoff and gives up after five
  tries, and the worker runs with its inputs waiting and no output status.
  This is why the owning outlet or inlet must be registered before the
  request goes out.

### Milestone 3 against real Cloudflare (2026-11-17)

`examples/call` on a Mac, reached through a `cloudflared` quick tunnel, with
the built-in browser joining with the test tone. One run:

| Check                                   | Result                                                                                                                                                                    |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Echo goes live, only its owner hears it | Yes: pulled into the owner's session once its first frame was sent.                                                                                                       |
| Echo delay                              | 2.45–2.58 s, from beep onsets on the mic against the echo (2 s + ~500 ms). Muting left exactly two echo beeps in flight.                                                  |
| Flush                                   | No echo for 2.8 s after flushing, as expected when the 2 s held is dropped.                                                                                               |
| Pacing                                  | Metronome: 1,499 frames in 30.0 s, then 10,314 frames over ~3.4 min with the queue flat at 80 ms. Underruns: 27 in the first 20 s, then one more every couple of minutes. |
| Recorder                                | Valid 16 kHz mono WAV, 220.5 s; kept writing through every other change.                                                                                                  |
| Worker crash                            | Killed the echo worker: restarted after the 0.5 s backoff, same mids in the browser, 0 renegotiations, output stayed live (underruns +5 during the gap).                  |
| Cleanup                                 | Open adapter WebSockets through the tunnel: 4 → 2 after Echo off → 0 after leaving, and still 0 after 20 s. Cloudflare dialed each adapter once and never redialed.       |

Findings:

- **Egress delivers ~0.56% more audio than real time.** The recorder wrote
  60.41 s of audio in 60.08 s of wall time; the page's audio clock matched
  its wall clock, and the conversion is exact. A worker that plays its input
  back (the echo) therefore built latency: its outlet queue grew 320 →
  500 ms in 30 s, about 20 s per hour. **Fixed** by holding each inlet to
  real time with a token bucket (20 ms of audio per 20 ms, holding up to
  300 ms for the bursty TCP leg; frames that find it empty are dropped, and
  `Room.state/1` reports the count per input). Re-measured the same way:
  the recording ran +0.02% (120.18 s in 120.15 s), the echo's queue stayed
  at 260 ms for over a minute, and inlets dropped 20 of ~3,470 frames
  (0.58%). Dropping is a blunt fix: about one 20 ms frame every 3.6 s,
  wherever it falls. Dropping during silence, or resampling, would be
  smoother if it turns out to be audible.
- **Startup underruns** come from the metronome making exactly 100 ms
  every 100 ms with no lead, so its queue touches empty while timers
  settle. A producer that wants no gaps should keep a little audio ahead.
- **Cloudflare dials the adapter endpoint while creating it.** If the
  dial fails, creation fails: 503 `internal_error` when the host is
  unreachable, 503 `websocket_handshake_failed` when it answers without
  upgrading. `Octoroom.Plug` now logs every request it refuses, since these
  otherwise leave no trace on the server.
- `cloudflared` quick tunnels apply `~/.cloudflared/config.yml`'s ingress
  rules when that file exists, which can answer every request with 404;
  `--config /dev/null` avoids it (see the demo's README).

### Recovery spike (2026-11-17)

The three Cloudflare behaviours [Recovery](#recovery) depends on, checked
with `examples/call` run as a named node (so its room state could be read
over RPC), two built-in-browser tabs sending the test tone, and a
`cloudflared` quick tunnel for the adapters.

| Question                                                   | Answer                                                                                                                                                                                                                                                                                                            |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Does `GET /sessions/:id` return enough to adopt a session? | **Yes.** Each track has `location` (`local` for a push, `remote` for a pull), `trackName`, `mid` and `status` (`active`/`inactive`); a pull also has the source `sessionId`. That's everything the room server keeps per subscription.                                                                            |
| How long does a browser session survive with no API calls? | **As long as its peer connection.** After the node was stopped, a session was still `active` 11 minutes later with no API calls, and the browser kept sending audio the whole time. Another participant's two browsers kept hearing each other until one of them left. A pull whose source left turns `inactive`. |
| What happens to a session whose peer connection closed?    | `GET` answers `session_error`, "Session appears to be disconnected", within a minute. Recovery can treat that as "this participant is gone".                                                                                                                                                                      |
| When an adapter's WebSocket drops, does Cloudflare redial? | **Briefly.** After `kill -9` of the node, Cloudflare redialed both adapters (an echo's ingest and egress) every 1–3 s for ~14 s, then stopped. The ingest adapter's session answered `session_error` (disconnected) at once, so its output track is dead to listeners.                                            |
| Can we tell whether a dead adapter is still billed?        | **No.** `POST /adapters/websocket/close` answers 200 with the ids echoed back for adapters already dropped _and_ for an id that never existed.                                                                                                                                                                    |

Consequences for recovery (milestone 5):

- **Adopt sessions from `GET`.** Resume tokens plus session read-back are
  enough; no browser renegotiates if the reads agree.
- **Don't count on redials.** A restart that's back within ~14 s could
  catch them, but a deploy usually isn't. This was the case for closing
  every previous run's adapter ids unconditionally. With WebRTC workers
  (see [Transport decision](#transport-decision-2026-11-17)) it no longer
  matters: worker sessions end with their peer connections.
- **A worker output's track and session die with the node**, so listeners'
  pulls of it must be closed and re-pulled once the new outlet is live (the
  normal `:pending` → `:live` path, but the stale pull has to go first).

### Implementation notes (milestone 4)

Workers' media moved from WebSocket adapters to one `ex_webrtc` peer
connection per worker (2026-11-17). What was built, and what differs from
[Worker media transport](#worker-media-transport) as first written:

- **`Octoroom.Peer`** owns a worker's Cloudflare session and makes its
  calls itself (the draft had the room server make them): an operation
  queue that batches pushes, pulls and closes, Cloudflare calls in tasks,
  SDP in-process. The room server decides what to push, pull and close,
  hears back as `{:peer_result, worker_id, pid, result}`, and ignores
  results from a peer it has replaced. A push, renegotiation or close that
  fails leaves the connection's signaling state unknown, so the peer stops
  and the room starts the worker's media afresh, with backoff.
- **Peers come and go with media.** A worker gets a peer when its first
  inlet or outlet starts and loses it when its last one stops; tracks of a
  peer that's stopping aren't closed one by one. A worker that crashes
  keeps its peer, inlets and outlets. A peer that stops takes its worker's
  inlets and outlets with it; listeners' pulls of its outputs close, and
  everything comes back through the normal reconcile. Peers trap exits so
  stopping one closes its peer connection properly: Cloudflare reported an
  abruptly killed session disconnected only after ~40 s.
- **Inlets** decode with one Opus decoder per channel count, picked per
  packet from the TOC byte: the Opus NIF refuses packets whose channel
  count differs from the decoder's, and browsers send mono. Mono is
  upmixed to room PCM (48 kHz stereo). Packets go through
  `ExWebRTC.RTP.JitterBuffer` (50 ms) first; undecodable ones are counted
  and dropped.
- **Outlets** encode 20 ms Opus frames (VoIP, automatic bitrate) and send
  RTP with their own sequence numbers and timestamps; after the queue runs
  dry, the next packet's timestamp moves on by the time that passed and
  sets the marker bit. An outlet gets its sink from the peer only once the
  connection is up, so its first packet reaches Cloudflare.
- **Crashed inlets and outlets back off** like failed pulls; without that,
  an inlet crashing on every packet restarted (and renegotiated) about
  every 300 ms. Failure counts for a worker's peer and outputs reset when
  its peer connects or an output is pushed.
- **Cloudflare quirks** handled in `Octoroom.Peer.WebRTC` (2026-11-17):
  applying Cloudflare's offer as a session's first negotiation starts ICE
  checks before Cloudflare has the answer, and they fail for good, so the
  offer's candidates are held back until `renegotiate` succeeds. Later
  offers repeat candidates ex_webrtc already has (it warns on each), so
  they're always stripped. Once every m-line is rejected, Cloudflare's
  answer has no `a=group:BUNDLE`, which ex_webrtc refuses; an empty one is
  put back.
- **No STUN.** Host candidates are enough against Cloudflare's ICE-lite
  SFU: in a spike both directions connected ~250 ms after the answer.
- **libsrtp from the system**: see [Open questions](#open-questions).
- **Gone:** `Octoroom.Plug`, `Octoroom.Adapter` and its socket,
  `Octoroom.Cloudflare.Packet`, the adapter calls in `Octoroom.Cloudflare`,
  `public_ws_url`, adapter records in the store, and the `plug` and
  `websock_adapter` dependencies. Telemetry's `[:octoroom, :adapter,
:create]` became `[:octoroom, :peer, :connect]`.
- **Tests** use `Octoroom.Test.FakePeerMedia`: placeholder SDP, and PCM
  moved through `FakeCloudflare`, which delivers a frame pushed on a track
  to every session that pulled it.

#### Milestone 4 against real Cloudflare (2026-11-17)

`examples/call` on a Mac with **no tunnel** (only Cloudflare credentials),
one built-in-browser tab sending the test tone, checked the same way as
milestone 3:

| Check                        | Result                                                                                                                                                                                                                                                                                                 |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Echo delay                   | 2.339–2.351 s from beep onsets on the mic against the echo (9 beeps), against 2.45–2.58 s on adapters: ~110–240 ms less, as the spike's ~170 ms predicted. The round trip on top of the 2 s held is now ~340 ms.                                                                                       |
| Pacing (5 min, machine idle) | Over 300.67 s of wall time the metronome sent 15,034 frames (300.68 s), queue flat at 1,040–1,060 ms, no new underruns; the recording grew 300.68 s.                                                                                                                                                   |
| Worker crash                 | Crash my echo: restarted, 0 renegotiations in the browser, output stayed live (underruns +5 during the gap).                                                                                                                                                                                           |
| Cleanup                      | Echo off: the browser closed its pull of the echo (one close), the echo's peer stopped, and its session reported disconnected. Stopping a peer now closes its connection, and a stopped node's worker sessions reported disconnected within ~6 s; before peers trapped exits, a killed one took ~40 s. |
| Server restart               | Stopped and restarted the node mid-call: the page resumed on the same peer connection; the echo and metronome came back on new sessions and were re-pulled (three offer/answer exchanges, all for worker outputs); the metronome assign survived.                                                      |

Findings:

- **Inputs still arrive faster than real time** (~0.45–0.59% of frames
  dropped by inlets' hold), close to the adapters' 0.56%, so the surplus
  isn't the adapters'. The node's monotonic clock, OS clocks and system
  time agreed to 50 µs over 20 s, so it isn't the BEAM's clock either; the
  browser's sending side is the likely source. The hold keeps recordings
  exact.
- **CPU contention shows up as queue growth.** An earlier 5-minute window,
  during which the test suite ran eight times on the same machine, had the
  metronome's queue grow 140 → 1,060 ms and the recording run 0.33% short:
  stalls longer than 100 ms restart an outlet's clock instead of bursting,
  and lose that time. On an idle machine both were exact. A busy production
  node would see the same, so outlet stalls are worth a telemetry event.

### Implementation notes (robustness)

Built ahead of milestone 4, so it ran on the WebSocket adapters. What was
adapter-specific went with them in milestone 4: adapter records in the store,
the janitor's adapter sweep (it still expires room records), closing a
previous run's adapters, and batching adapter calls. Everything else
carried over to WebRTC workers unchanged.

- **`Octoroom.Store`** is a key-value behaviour (`get`, `put`, `delete`,
  `all` over two tables, `:rooms` and `:adapters`) with `Octoroom.Store.ETS`
  as the default: ETS, snapshotted to a file (`octoroom-<node>.store` in the
  temp directory unless configured) after a 50 ms batch and on shutdown.
  The snapshot is read without `:safe`: it holds the app's own atoms (assign
  keys), which don't exist yet that early in boot.
- **Runs.** Each start of a room server is a run, with its id as the room's
  registry value. A room record left in the store means the previous run
  didn't stop cleanly, so the new one recovers: it takes the assigns, holds
  ghosts for the grace period, and passes `ctx.resumed: %{gone_ms: ms}` to
  workers it starts in that window (`gone_ms` from a 5 s heartbeat on the
  record). The record is deleted only when the room stops because its last
  participant left.
- **Adapters are recorded** before Cloudflare is asked to create them and
  deleted once closed. `Octoroom.Janitor` (first sweep 5 s after boot, then
  every minute) closes those whose room isn't running on this node with that
  run, and deletes room records older than the token's max age.
- **Dropped connections.** A channel that exits with any `{:shutdown, _}`
  except `{:shutdown, :left}`, or with `:shutdown`, is a disconnect, not a
  leave: Phoenix uses `{:shutdown, :closed}` for a closed transport and
  `{:shutdown, :restart}` when draining sockets at shutdown. The participant
  stays for the grace period; a signaling request it missed is sent again
  when it resumes. Closing a tab would look the same, so the JS client
  leaves on `pagehide`.
- **The channel resumes on its own** when the room server crashes, from
  the resume data it keeps.
- **The room server is the last child** of the room's supervisor, so it
  stops first on shutdown and closes the room's adapters synchronously in
  `terminate/2` while their owners are alive. Before, the media supervisor
  stopped first, the server closed each adapter in a task as its owner died,
  and shutdown killed the tasks.
- **Worker output pulls are stale after a restart**: their ingest sessions
  died with the node. The reconciler closes a subscription marked `stale`
  and pulls the track again from its new session once it's live.
- **Retries.** The HTTP client retries 429/502/503/504 for every call and
  transport errors only for calls that are safe to repeat (`GET`, closing
  adapters), 3 attempts with 200 ms doubling. When the room gives up on
  something after five tries it broadcasts `{:error, what, reason}`.
- **Telemetry:** `Octoroom.Telemetry` lists the events.
- **Cloudflare facts found on the way** (2026-11-17): closing adapters
  takes **at most 4 per request** ("Expecting at most 4 track in the
  request"), so adapter calls are split into batches of 4 and a failed later
  batch closes the ones already created; `GET` on a disconnected session
  answers **410**, and on an unknown one 500.
- **Demo** (`examples/call`): Phoenix Presence lists who has the room open
  and who's in the call; a captioner worker streams each mic to Soniox and
  `emit`s captions. Presence updates on every load, since after a restart
  the page can come back before its participant does.

Restarting the node mid-call against real Cloudflare (2026-11-17), two
built-in-browser tabs in `examples/call` (one playing recorded speech as its
mic, one the test tone) with an echo, the metronome and captions on:

| Check                           | `kill -9`, 9 s down                                                                               | `SIGTERM` (deploy)                                                    |
| ------------------------------- | ------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| People keep hearing each other  | Yes: both directions' inbound bytes grew steadily through the outage, no gap                      | Yes, through 28 s without a server (15 s of Phoenix draining sockets) |
| Clients resume the same session | Yes, 14.3 s and 15.8 s after the kill (about 5 s after the node was back); no new peer connection | Yes; no new peer connection                                           |
| Renegotiations                  | Only for worker outputs: one close and one pull each                                              | Same                                                                  |
| Workers come back               | Echo, metronome and captioner restarted; their tracks live and re-pulled within 3 s of the resume | Same                                                                  |
| Assigns survive                 | Yes (`metronome`, `captions`)                                                                     | Yes                                                                   |
| Nothing leaks                   | Previous runs' adapter records closed and gone; store holds only the current run                  | Every adapter closed before exit; the store kept only the room record |
| Everyone leaves                 | Store empty: room record deleted, adapters closed                                                 |                                                                       |

Findings:

- **Background tabs reconnect late.** In one run a tab took 37 s after the
  node was back to rejoin: Chrome throttles timers in hidden tabs, Phoenix's
  reconnect backoff included, up to once a minute. With the original 15 s
  grace period the other participant lost that tab's mic for ~10 s before it
  resumed and was pulled again. The default grace period is now 60 s.
- **Cloudflare redials a dead adapter for ~14 s**, as the spike found: a
  node back within that window sees the previous run's egress adapters dial
  `Octoroom.Plug`, which refuses them, and recovery closes them.

### Implementation notes (video)

Steps 1 and 2 of [Video](#video), built 2026-11-17. Checked with the fake
Cloudflare (`test/octoroom/video_test.exs`), against an in-page fake SFU (a
second peer connection playing the room server's side), and against real
Cloudflare (below).

- **Publications.** A participant's single `mic` field is now `media` (its
  session: `:none`, `:publishing`, `:adopting`, `:pending`, `:live`) plus
  `tracks`: source => `%{status: :pending | :live | :closing, mid, muted}`.
  The directory, adoption after a restart and ghosts all read `tracks`, and
  every published track is named `"<id>/<source>"` at Cloudflare too, so
  adoption finds all of a participant's sources by name. `Octoroom.Participant`
  gains `tracks` (live sources, with `kind` and `muted`), so policies and the
  client see what each participant publishes. `Room.state/1` keeps `mic`
  (the mic's status) and adds `media` and `tracks`.
- **Publishing later is server-paced.** A client can't send its own offer
  for a new camera whenever it likes: the server may be waiting on that
  client's answer to a pull, and each would wait on the other. So
  `publish_tracks` only asks; the request joins the session's queue, and on
  its turn the server sends `push` and the client offers, as `close` already
  worked. The first `publish` (which creates the session) still carries its
  offer, and may hold several sources.
- **Unpublish closes pulls first.** The track leaves the directory at once,
  so the reconciler closes everyone's pulls of it; the publisher's own close
  waits until no participant pulls it. Whether Cloudflare minds a local
  track closing under active pulls is unverified, so we don't ask it. The
  client stops sending (`replaceTrack(null)`) and stops the camera right
  away, so the camera light goes off before the bookkeeping is done.
- **Permissions.** `join/2` metadata may carry `publish: [sources]`; without
  it every source is allowed. Unknown sources are refused.
- **Mute** is a flag on the publication (`{:updated, participant}`), with no
  reconcile and no renegotiation. A restarted room adopts tracks unmuted, and
  the client sends its mute flags again when it resumes.
- **Client.** Remote video gets no element: `tracks()` carries a `stream`
  for the app's own `<video>`. Audio (mic, screen audio, worker outputs)
  still plays in hidden `<audio>` elements, and `gain/2` raises for video.
  `default_subscriptions/2` now includes every source of every other
  participant; sources nobody publishes are never in the directory, so they
  cost nothing.

#### Video against real Cloudflare (2026-11-17)

Two tabs of `examples/call` in one Chromium, with test patterns (640×360 at
15 fps):

- Joining with mic and camera in one publish: each tab decodes the other's
  camera at 640 px within a few seconds.
- **Pause** (`track.enabled = false`): the subscriber kept decoding black
  frames (74 in 5 s), its pull stayed healthy, and video came back at once
  on resume. This answers the *To verify* under [Publications](#publications).
- **Camera off, then on again mid-call:** the subscriber's pull closed, then
  the new push was pulled and decoded at ~15 fps, with no
  `empty_track_error` or retry in the log.
- **Screen share** (a 1280×720 canvas through `publish({screen: track})`)
  arrived at 1280 px. `getDisplayMedia` itself wasn't exercised.
- **Receive video off/on** (a `subscriptions/2` change): the listener went
  down to the mic alone, and back to camera and screen.
- **Restart:** the peer connections that failed after a node kill in this
  run were my test's fault, not Octoroom's: `lsof -ti tcp:4300 | xargs kill`
  also killed the browser's network service, which carries WebRTC's UDP.
  Restart checks must kill the BEAM by its pid (or
  `lsof -ti tcp:4300 -sTCP:LISTEN`); killed that way, media keeps flowing.
  A restart with video publications wasn't repeated.
- Still open: how many video pulls one browser session handles before
  simulcast (step 3) is needed.

### Implementation notes (bad input)

Built 2026-11-17. The room server is the room's single writer, and when it
crashes the whole room restarts and recovers (see [Restarts and
deploys](#restarts-and-deploys)). That's right for real crashes, but a
malformed client message or a bug in app code could trigger it at will,
and a raising policy did again on every reconcile after recovery, so the
room looped. Now both are refused at the boundary where they come in.

- **Client payloads.** The channel checks each event's body (`sdp` and
  `op_id` strings, `mids` a map of string to string, `sources` a list of
  strings, `source` a string) and replies `bad_payload` otherwise, instead
  of the misleading `unknown_event`. The room server checks the same shapes
  again before handling a request, since it's also called without a channel
  (`Octoroom.Room.join/4` is public), and replies `{:error, :bad_payload}`;
  a malformed `mute`, which has no reply, is dropped. Values of the right
  shape that are still wrong (an unknown source, a stale `op_id`) were
  already refused further in.
- **Room callbacks.** Every call from the room server into the room module
  catches raises, throws and exits and checks the result's shape, and a
  failure keeps the last good answer:
  - `workers/1`: the specs stay as they were, so running workers keep
    running. Their inlets and outlets still follow the directory.
  - `subscriptions/2`, per listener: its desired list is what it holds now,
    at its current gains, so the diff has nothing to do for it. Tracks that
    leave the directory still close. Other listeners reconcile as usual.
  - The function given to `update_meta/3` runs in the room server too: the
    metadata stays, and the caller gets `{:error, reason}` instead of
    crashing with the room.
  - `mount/1`: the room doesn't start, and the join fails with
    `{:error, {:mount_failed, reason}}` instead of a supervisor's
    `failed_to_start_child`.

  `reason` is the exception, `{:throw, value}`, `{:exit, reason}` or
  `{:bad_return, value}`. Each failure is logged (with the stacktrace),
  broadcast as `{:error, {:policy, callback}, reason}` and emitted as
  `[:octoroom, :policy, :error]`. Reconcile runs on every room change, so
  the room keeps the last pass's errors and reports one only when it starts
  or changes.
- **Tests:** the bad-input cases in `test/octoroom/room_test.exs` drive the
  room server directly, and `test/octoroom/phoenix/channel_test.exs` calls
  the channel's `__handle_in__/3` with a stand-in socket whose "room
  server" is the test process.

## Milestones

1. **Port the primitives.** Cloudflare client behind a behaviour with a fake,
   packet codec, adapter Plug and socket, audio conversion. Ported tests pass.
2. **Browser-to-browser rooms.** Room server, reconciler (participants and
   subscriptions only), channel, JS client. Two browsers hear each other,
   and leave/rejoin works. No workers.
3. **Workers.** Outlets with pacing and flush, inlets, worker supervision, the
   `DelayEcho` example, pending→live handling for worker outputs. Start with
   an output-only metronome worker (a beep a second) to check pacing before
   inlets exist. The demo is a "mic check" room in `examples/call`, with no AI:
   - **Private echo.** Each participant gets their own `DelayEcho` worker,
     whose output is in only that participant's `subscriptions/2`: you hear
     yourself 2 s late and nobody else does. This exercises per-participant
     workers started and stopped by `workers/1`, routing a worker output to
     one listener, and pending→live (the echo is audible only once frames
     flow).
   - **Echo on/off and Flush buttons** in the LiveView. The toggle is an
     `update_meta` that drops the worker from `workers/1`, so its adapters
     close. Flush cuts the queued 2 s off at once: the action AI workers need
     for barge-in.
   - **A shared recorder** that hears every mic, writes one WAV per input,
     and `emit`s seconds recorded per participant for the LiveView to show.
     It checks inputs labelled by participant, an input added on join
     without restarting the worker (the WAVs continue without a gap), and
     `emit` reaching the LiveView.

   Done when, against real Cloudflare:
   - the echo's delay measures ~2 s plus the adapter round trip (~500 ms,
     the spike's echo through two adapters), checked with a clap;
   - after 5 minutes the outlet queue length is flat and each WAV's length
     matches wall-clock time (no drift);
   - killing a worker process gets it restarted, while its output track
     stays live: listeners hear a gap, and browsers don't renegotiate;
   - after the toggle or a leave, Cloudflare shows the worker's adapters
     closed, so nothing keeps running or billing.

4. **WebRTC worker transport** (done 2026-11-17; see
   [Implementation notes (milestone 4)](#implementation-notes-milestone-4)).
   `Octoroom.Peer` with a session per worker,
   inlets with a jitter buffer and Opus decode, outlets with Opus encode,
   a clear error when outbound UDP is blocked, and the fake peer for tests. Then remove
   `public_ws_url`, `Octoroom.Plug`, `Adapter.Socket` and `Cloudflare.Packet`.
   Done when `examples/call` runs with no tunnel and passes milestone 3's
   checks against real Cloudflare again:
   - the echo's delay drops by roughly the ~170 ms the spike measured;
   - pacing and recording stay flat over 5 minutes;
   - killing a worker process gets it restarted with 0 renegotiations;
   - after the toggle or a leave, the worker's session reports disconnected.
5. **Robustness.** Store, retries, resume tokens and recovery (restart the
   node mid-call: people keep talking, workers come back), telemetry, a
   LiveView demo app with Presence and captions from `emit`.
6. **Interpretation demo**, with the Subvocal adapter on the Subvocal side.
7. **Phone callers** (see [Telephony](#telephony)): Twilio Media Streams,
   `kind: :phone` participants backed by a bridge worker with mixing, the
   phone router, DTMF events and outbound `dial`. The demo is Example 3
   with the customer on a phone. Done when a phone and a browser hear each
   other through `subscriptions/2`, the coach stays inaudible to the
   phone, mouth-to-ear latency both ways is measured, and hanging up
   closes the bridge's peer.
8. **Later:** video (see [Video](#video) for its order), SIP, clustering.
   A Swift client for iOS and macOS exists (see
   [swift/README.md](../swift/README.md)): a port of the browser client
   with the same protocol, checked end to end against Cloudflare with
   video (2026-11-17).

## Open questions

- **Session per browser vs. per direction.** One session per browser means
  every new subscription renegotiates the whole connection. Separate publish
  and subscribe connections (two sessions) make subscription churn cheaper
  and isolate the mic. Measure renegotiation time in a 10-person room before
  deciding.
- **Mixing.** A listener in a room of 15 pulls 14+ tracks. A server-side
  mixer worker that produces one track per listener is possible, but costs
  an Opus decode per input and an encode per listener on the app's nodes. When does it pay off? Phone participants
  need a mix regardless (see [Telephony](#telephony)), so the mixer gets
  built there first.
- **Phone providers.** Do Twilio, Telnyx and Vonage play audio sent ahead
  of real time as it arrives, like Cloudflare's ingest does, or buffer it?
  That decides whether audio to the phone needs pacing and how much a
  `clear` has to drop.
- **Speaking indicators.** Use client-side audio levels reported over the
  channel (cheap, spoofable), or levels computed by a worker (trustworthy,
  but needs a pull and an Opus decode per participant)?
- **Room lifetime.** Should empty rooms linger beyond the recovery grace
  period, and should rooms be startable from the server with no clients,
  e.g. a scheduled event with a bot waiting?
- **Worker sessions: one per worker or one per room?** One per worker
  isolates crashes and renegotiations. One per room means fewer peer
  connections, but every worker change in the room waits in one queue.
  Start with one per worker and measure peer connection cost in a room
  with 20 workers.
- **Native libraries.** On macOS (2026-11-17): libopus comes precompiled;
  `ex_libsrtp`'s precompiled libsrtp links a libcrypto Homebrew doesn't put
  on the default path and fails to load, so apps build against the system's
  libsrtp (`brew install srtp`, with
  `config :bundlex, :disable_precompiled_os_deps, apps: [:ex_libsrtp]`, as
  Subvocal already does); `ex_dtls` builds against the system's OpenSSL.
  Linux (glibc and musl, x86-64 and ARM) is unchecked. Getting rid of the
  libsrtp step (a fixed precompiled build upstream) would make install a
  plain `mix deps.get`.
- **No outbound UDP.** Does Cloudflare accept ICE over TCP? If it does,
  that's the fallback for hosts that block UDP; if not, those hosts can't
  run workers.
- **Cloudflare API drift.** Pin the session and track fields we depend on
  in the fake, so drift shows up as one failing integration test.
- **Name collisions.** Check that `octoroom` is free on Hex and npm before
  the first release.
