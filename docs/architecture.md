# Octoroom architecture

How Octoroom works today. Everything here describes code in this
repository.

- Why it is built this way, what was tried first and what was measured:
  [decisions.md](decisions.md). Links like
  [D24](decisions.md#d24-workers-move-to-webrtc-peers) point to the decision
  behind a paragraph.
- What isn't built yet (simulcast, video for workers, phone callers,
  clustering) and the open questions: [roadmap.md](roadmap.md).

Built so far: rooms where browsers and native apps hear and see each other
under a server-side policy, server-side audio workers that join over WebRTC,
and rooms that survive restarts and deploys.

## Summary

Octoroom is an Elixir library for multi-party voice and video rooms in
Phoenix apps. Cloudflare Realtime SFU carries the media. The app's own
processes make every decision:

- who may join
- who hears and sees whom
- which server-side participants (bots, AI agents, recorders, interpreters)
  run in the room

By default everyone in a room hears and sees everyone else, and a room
module only says who may join. When a room needs different routing, the
developer overrides one function that answers "what should this listener
hear now?" Octoroom then works out which Cloudflare calls turn the current
state into that answer, in the same way LiveView diffs a new render against
the old one and patches only what changed. A join, a leave, a reconnect or a
change of language are all handled by re-running that function, so the room
module contains no event handling.

The developer doesn't need to know WebRTC. Server-side participants join a
room the way browsers do, over WebRTC to Cloudflare, and the app needs no
public endpoint for media, no inbound ports and no TURN server: every media
connection is one that a browser or the app opens to Cloudflare. The server
only needs outbound UDP.

## Goals

- Rooms with up to about 20 participants, and any number of server-side
  workers, in a Phoenix app that exposes nothing for media.
- A room API small enough for someone who has built a Phoenix chat room. A
  basic room is one callback, `join/2`. `workers/1` and `subscriptions/2` are
  optional overrides.
- Server-side participants as supervised Elixir processes that read and write
  PCM, with no WebRTC in the developer's code.
- Server-authoritative media routing. A client can only receive what the
  server's policy subscribes it to.
- Room events that a LiveView can render.
- Testable without Cloudflare. The policy and the reconciler are pure, and
  the Cloudflare client and the worker peer connection each sit behind a
  behaviour.

## Non-goals

- **No AI.** Octoroom has no speech-to-text, LLM or text-to-speech code and
  no dependency on any voice-agent library. AI participants are workers that
  the app or an integration provides
  ([D5](decisions.md#d5-octoroom-ships-no-ai)). `octoroom_agents`, in
  `agents/`, is that integration
  ([D37](decisions.md#d37-agents-are-a-package-in-this-repository-copied-from-subvocal)).
- Running or self-hosting an SFU. Cloudflare is the only media plane.
- Broadcast to thousands of passive listeners. HLS or MoQ fit that better.

## Developer experience

Three rooms, from simplest to most involved: a plain group call, live
interpretation, and a support call with a private coach, a silent supervisor
and a recorder. All three share the same config, channel and client.

### Config

```elixir
# config/runtime.exs
config :octoroom,
  cloudflare: [
    app_id: System.fetch_env!("OCTOROOM_CLOUDFLARE_APP_ID"),
    app_secret: System.fetch_env!("OCTOROOM_CLOUDFLARE_APP_SECRET")
  ]
```

There's no endpoint to mount and no public URL: workers' media connections
are outbound, so a worker runs the same on a laptop behind NAT as in
production.

Optional keys:

| Key               | Default                                  | Sets                                                                                   |
| ----------------- | ---------------------------------------- | -------------------------------------------------------------------------------------- |
| `:store`          | `{Octoroom.Store.ETS, []}`               | Where room records live (see [`Octoroom.Store`](#octoroomstore)).                      |
| `:resume_max_age` | `600` (seconds)                          | How long a resume token is accepted: the longest outage a room survives.               |
| `:janitor`        | enabled, sweeps every minute             | `Octoroom.Janitor`'s options; `:room_ttl_ms` should match `:resume_max_age`.           |
| `:webrtc`         | `[]`                                     | Extra `ExWebRTC.PeerConnection` options for worker peers (e.g. Fly.io's ICE IP filter). |
| `:ice_servers`    | Cloudflare's STUN server                 | The ICE servers sent to clients in the join reply.                                     |

Building `ex_webrtc` needs the system's libsrtp; see the
[README](../README.md) and
[D29](decisions.md#d29-libsrtp-comes-from-the-system).

### The room callbacks

| Callback                        | Required | Default                                 | Answers                                                             |
| ------------------------------- | -------- | --------------------------------------- | ------------------------------------------------------------------- |
| `join(params, socket)`          | yes      |                                         | May this client join, and with what metadata?                       |
| `mount(room_id)`                | no       | `{:ok, %{}}`                            | Runs once when the room process starts. Returns the room's assigns. |
| `workers(room)`                 | no       | `[]`                                    | Which server-side participants should be running now?               |
| `subscriptions(listener, room)` | no       | `default_subscriptions(listener, room)` | What should this listener hear and see now?                         |

`default_subscriptions/2` returns every source of every other participant
(mic, camera, screen share and its audio) plus every worker output track.
Sources nobody publishes are never pulled, so they cost nothing. It stays
callable from an override, so a room can start from the default and add or
remove tracks.

`workers/1` and `subscriptions/2` must be pure and fast: they run after
every room change, once per listener for `subscriptions/2`. They read only
`room` (`%Octoroom.Room{}`), which holds the participants in join order (id,
`join/2` metadata and the sources each publishes), the current worker specs
and the room's own assigns. Anything else they need goes into metadata or
assigns first.

Helpers imported by `use Octoroom.Room`:

| Helper                                      | Returns                                                                                          |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `mic(p)`                                    | That participant's mic track.                                                                    |
| `camera(p)`, `screen(p)`, `screen_audio(p)` | That participant's camera, screen share and screen audio.                                        |
| `track(name)`                               | A track by room-scoped name, e.g. a worker output `"alice/ja"`.                                  |
| `gain(track, 0.0..1.0)`                     | The same audio track, played at that volume in the listener's client. Raises for video.          |
| `others(room, participant)`                 | Every participant except that one.                                                               |
| `default_subscriptions(listener, room)`     | The default policy, described above.                                                             |
| `worker(id, module, opts)`                  | A worker spec with `inputs:`, `outputs:` and `args:`. Inputs are audio; raises for a video input. |

Changing a room from outside (a LiveView, a controller):

| Function                                              | Does                                                        |
| ----------------------------------------------------- | ----------------------------------------------------------- |
| `Octoroom.Room.update_meta(room_id, participant_id, fun)` | Updates a participant's metadata, then reconciles.          |
| `Octoroom.Room.assign(room_id, key, value)`           | Sets a room assign (persisted to the store), then reconciles. |
| `Octoroom.Room.refresh(room_id)`                      | Re-runs the policy, for policies that read outside state.   |
| `Octoroom.Room.state(room_id)`                        | A snapshot: assigns, each participant's publications and what it receives, workers, outputs. |

### Example 1: a group call

Everyone hears and sees everyone. This is the entire room module:

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
[pending tracks](#cloudflare-constraints-the-reconciler-respects)).
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
  so Octoroom pulls the new input into the recorder's session. Adding an
  input doesn't restart the worker (see [the reconcile loop](#the-reconcile-loop)).

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

### Channel and clients

```elixir
# user_socket.ex
channel "room:*", MyAppWeb.RoomChannel

defmodule MyAppWeb.RoomChannel do
  use Octoroom.Phoenix.Channel, room: MyApp.InterpretRoom
end
```

The room id is the topic after its first `:`, so `"room:support:1234"` is
room `"support:1234"`.

```js
import { RoomClient } from "octoroom";

const room = new RoomClient({
  socket,
  topic: `room:${id}`,
  params: { lang: "ja" },
});
room.on("participants", (list) => render(list));
room.on("workers", (list) => render(list)); // workers it's subscribed to, e.g. agents
room.on("worker_event", ({ worker, type, data }) => show(worker, type, data));
await room.join(); // asks for the mic, publishes it, plays what the policy subscribes
room.setMuted(true);
await room.send("assistant", { text: "add Acme to the sheet" }); // to a worker that hears it
await room.leave();
```

The browser client is an ES module, `priv/static/octoroom.mjs`. Audio (mics,
screen audio, worker outputs) plays in hidden `<audio>` elements. Remote
video gets no element: `tracks()` carries a `stream` for the app's own
`<video>` ([D35](decisions.md#d35-remote-video-gets-no-element)).

The Swift client for iOS and macOS ([swift/README.md](../swift/README.md))
is a port of the browser client and speaks the same channel protocol.

### Room events

`Octoroom.subscribe(room_id, scope: scope)` sends the subscribing process
`{:octoroom, room_id, event}` messages
([D44](decisions.md#d44-workers-reach-clients-through-their-outputs)):

- `scope: {:participant, id}`: what that participant's client is sent, as
  Elixir terms. For a process that renders the room for one user, such as
  a LiveView. The id isn't checked; pass the one your code authenticated.
- `scope: :room`: every event below, for trusted code that acts for no
  user (a recorder, analytics, an admin view).

Both go through a `Registry` (`Octoroom.Events`), so they reach processes
on this node ([D9](decisions.md#d9-events-go-through-a-registry)), survive
the room server restarting, and may be made before the room exists.

| Event                                        | When                                                                               |
| -------------------------------------------- | ---------------------------------------------------------------------------------- |
| `{:joined, participant}`, `{:left, participant}` | A participant joined or left.                                                  |
| `{:updated, participant}`                    | Its metadata changed, or a source it publishes was muted, unmuted or unpublished.  |
| `{:published, participant}`                  | A source it publishes is live at Cloudflare.                                       |
| `{:disconnected, participant}`               | Its connection dropped; it is kept for the grace period.                           |
| `{:subscriptions, participant_id, track_names}` | What it now receives.                                                           |
| `{:output_live, track_name}`                 | A worker output sent its first packet.                                             |
| `{:worker_event, worker_id, event}`          | Whatever a worker `emit`s. `scope: :room` only.                                    |
| `{:worker, op, presence}`                    | A worker this participant now sees (`:added`), whose presence changed (`:updated`), or that it no longer sees (`:removed`). `scope: :room` gets `:updated` only. |
| `{:worker_notify, worker_id, output, type, data}` | A worker's `notify:` on an output the participant is subscribed to. `scope: :room` gets those not sent to one participant. |
| `{:worker_down, worker_id, reason}`          | A worker crashed (the room restarts it).                                           |
| `{:error, what, reason}`                     | The room gave up on something after five tries (see [Failure and cleanup](#failure-and-cleanup)). |

`{:disconnected, _}`, `{:subscriptions, _, _}`, `{:output_live, _}`,
`{:worker_event, _, _}`, `{:worker_down, _, _}` and `{:error, _, _}` are
`scope: :room` only. Clients receive the first four as `room_event` channel
messages, and the two worker events as `worker` and `worker_event` (see
[Workers and clients](#workers-and-clients)).

## Concepts

| Term            | Meaning                                                                                                                                              |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Room**        | A named set of participants and workers, run by one `Octoroom.Room.Server` process. Started on first join and stopped when its last participant leaves. |
| **Participant** | A connected client. Has an id, the metadata from `join/2`, and the sources it publishes.                                                             |
| **Source**      | What a participant can publish, at most one track each: `mic`, `camera`, `screen`, `screen_audio`.                                                   |
| **Worker**      | A server-side participant: a supervised process that receives PCM from input tracks and sends PCM to output tracks. Audio only.                      |
| **Track**       | A room-scoped name such as `"alice/mic"`, `"alice/camera"` or a worker output `"alice/ja"`. Its kind (`:audio` or `:video`) follows from the name.   |
| **Policy**      | The room module's `workers/1` and `subscriptions/2` (or their defaults): pure functions of room state that give the desired state.                   |
| **Reconciler**  | Diffs desired against actual state and produces operations. Pure; the room server executes its output.                                               |
| **Run**         | One start of a room server. A room that is recovered after a crash or restart is the same room in a new run.                                         |

## Mapping onto Cloudflare

Cloudflare Realtime SFU has only sessions and tracks. A session is one
`RTCPeerConnection`. A track is pushed into a session (`location: "local"`)
or pulled into a session from another session (`location: "remote"`), and is
addressed by `(sessionId, trackName)`. Octoroom maps its concepts onto that
model as follows.

- **Each client has one session**
  ([D4](decisions.md#d4-one-cloudflare-session-per-browser)). Each source it
  publishes is pushed as a track named `"<participant id>/<source>"`, the
  same as its room-scoped name, so a session read back from Cloudflare says
  whose tracks it holds. Every subscription is pulled into the same session
  as another transceiver. Each push, pull or close changes that peer
  connection's SDP and needs a renegotiation.
- **Each worker with media has one session too.** The worker's peer process
  (`Octoroom.Peer`) holds an `ex_webrtc` peer connection to Cloudflare. The
  worker's inputs are pulled into that session, the same call a client
  subscription uses, and its outputs are pushed from it, named
  `"out-" <> base64url(name)` at Cloudflare. The room server decides what to
  push, pull and close; the peer makes its own session's Cloudflare calls and
  does the SDP in-process, so changing a worker's inputs costs one HTTP call
  and a local renegotiation, with no client round trip.
- **Track directory.** The room server derives
  `track name -> :pending | :live` and
  `track name -> {session_id, cf_track_name}` from its participants'
  publications and its outlets.

### Cloudflare constraints the reconciler respects

- `POST /sessions/new` must have **no body**; even `{}` returns a 400.
- **Empty tracks can't be pulled.** Cloudflare holds a pull of a track with no
  packets for ~8 s, then fails with `empty_track_error`. A subscription to a
  `:pending` track waits until the track is `:live`. A client's tracks are
  live once the client reports its peer connection is up
  ([D8](decisions.md#d8-a-track-is-live-when-its-publisher-reports-connected));
  a worker output is live when its outlet sends its first packet.
- Cloudflare is ICE-lite, and it takes a complete SDP with no trickle ICE.
  It needs none of a client's candidates, though: the client sends the
  connectivity checks and Cloudflare learns its address from them. Clients
  send their offer at the first candidate (or after 100 ms) and keep
  gathering
  ([D42](decisions.md#d42-clients-send-their-offer-at-the-first-ice-candidate)).
- Only one offer/answer exchange can be in flight per session. Changes to a
  session are **serialized** and **batched**: several pulls go in one
  `tracks/new` call and need one renegotiation.
- **Closing a track needs the client's offer**, made after it stops the
  transceiver ([D7](decisions.md#d7-closing-a-subscription-is-client-offered)).
- **A session ends with its peer connection.** Once a peer connection
  closes, `GET` on its session answers 410 within a minute. After a crash
  there is nothing at Cloudflare to close.

## Processes

```
Octoroom.Supervisor (one_for_one)
├── Registry (Octoroom.Registry)                 rooms, supervisors, workers and outlets by id
├── Registry (Octoroom.Events)                   room event subscribers
├── Task.Supervisor (Octoroom.TaskSupervisor)    Cloudflare HTTP calls
├── Octoroom.Store.ETS (or the configured store) room records that outlive the node
├── DynamicSupervisor (Octoroom.RoomSupervisor)
│   └── per room: Octoroom.Room.Supervisor (rest_for_one, temporary)
│       ├── DynamicSupervisor (media)            one Peer per worker, plus its inlets and outlets
│       ├── DynamicSupervisor (workers)          the developer's workers
│       └── Octoroom.Room.Server                 state, policy, reconciler, Cloudflare calls
└── Octoroom.Janitor                             deletes room records nobody can resume
```

Per client, the Phoenix channel process (from `Octoroom.Phoenix.Channel`)
handles signaling for that client's session and monitors the room server.

- **The room server is the single writer**
  ([D3](decisions.md#d3-the-room-server-is-the-single-writer)). Policy
  evaluation, reconciliation and the track directory all live in one process,
  so ordering is never in doubt. Cloudflare HTTP calls run in tasks, so a
  slow pull (up to ~8 s) doesn't block joins or leaves. Results come back as
  messages, are applied to the actual state, and trigger another reconcile.
- **The room server is the last child and a `significant` one**
  ([D20](decisions.md#d20-the-room-server-is-the-last-child)). Being last, it
  stops first on shutdown instead of watching the room's media die one by
  one. Being significant, when it stops (its last participant left, or it
  crashed) the whole room shuts down. The supervisor doesn't restart it:
  clients resume into a new run, which recovers the room (see
  [Restarts and deploys](#restarts-and-deploys)).
- **Peers, inlets, outlets and workers are temporary children.** The room
  server starts, monitors and restarts them as its reconciler decides, with
  backoff ([D12](decisions.md#d12-the-room-server-restarts-crashed-workers)).
- **Media is separate from workers**
  ([D11](decisions.md#d11-worker-media-lives-apart-from-the-worker)). A
  worker's peer, inlets and outlets live under the media supervisor, not
  under the worker. If a worker crashes and restarts, its peer connection and
  output tracks stay up, so listeners keep their subscription and hear a gap,
  not a renegotiation.
- **Per-session operation queues.** The room server keeps one queue per
  client session; each worker's peer keeps its own. Only the head operation
  is in flight, and queued pulls and closes are merged into one call when it
  is sent.
- **The channel never calls Cloudflare.** It relays SDP between the client
  and the room server, which owns every client session. This is what makes
  routing server-authoritative.

## The reconcile loop

Every reconcile runs two pure diffs, workers first, so `room.workers` is
current when `subscriptions/2` runs
([D14](decisions.md#d14-workers-are-reconciled-by-a-second-pure-diff)).

```elixir
specs = room_module.workers(room)
worker_ops = Octoroom.Reconciler.diff_workers(specs, actual_workers)

desired = Map.new(live_participants, &{&1.id, room_module.subscriptions(&1, room)})
ops = Octoroom.Reconciler.diff(desired, actual_subscriptions)
```

Worker operations, in the order they're applied. Tear-down comes first.

1. `{:stop_inlet, {worker_id, input}}`: no longer an input, or its track is
   gone.
2. `{:stop_outlet, name}`: no longer any worker's output.
3. `{:stop_worker, id}`: no longer in the specs.
4. `{:start_worker, spec}`, `{:restart_worker, spec}` and
   `{:update_worker, spec}` (see below).
5. `{:start_outlet, name, worker_id}`: an output with no outlet. The outlet's
   track is pushed from the worker's peer and is `:pending` until its first
   packet.
6. `{:start_inlet, {worker_id, input}}`: an input whose track is `:live`,
   pulled into the worker's session. Inlets of pending tracks wait.

A worker gets its peer when its first inlet or outlet starts and loses it
when its last one stops
([D26](decisions.md#d26-peers-come-and-go-with-media)).

Subscription operations, per participant whose connection is up:

1. `{:close_subscription, participant, track}`: open, but no longer desired,
   no longer published, or stale (pulled from a session that's gone).
2. `{:open_subscription, participant, track, %{gain: g}}`: desired and
   `:live`. Subscriptions to `:pending` tracks wait and are reconsidered when
   a track goes live.
3. `{:update_subscription, participant, track, %{gain: g}}`: a gain change.
   This is client-side only and sent as a `gain` channel message, with no
   Cloudflare call and no wait in the queue.

Subscriptions with an operation in flight are left alone; the diff after
that operation settles picks them up. Per session, a queued publish or
unpublish goes first, then closes, then pulls.

Reconcile triggers: a join, a leave, a metadata change
(`Octoroom.Room.update_meta/3`), a room assigns change
(`Octoroom.Room.assign/3`), a track going live, an operation finishing or
failing, a retry timer, the end of a recovery grace period, and an explicit
`Octoroom.Room.refresh/1`.

Worker identity is the id string from `worker/3`. When a spec with the same
id comes back changed:

- **Inputs changed:** inlets are added or removed, and the worker gets
  `handle_info({:octoroom, :inputs, names}, state)`. It isn't restarted, so a
  recorder or a group agent can follow people joining and leaving.
- **Outputs changed:** outlets are added or removed, and the worker gets
  `{:octoroom, :outputs, names}`. No restart.
- **Module or args changed:** the worker is restarted. Outlets whose names
  are unchanged are kept, so listeners don't renegotiate.

## Publishing

A participant publishes up to one track per source: `mic`, `camera`,
`screen` and `screen_audio`
([D31](decisions.md#d31-publications-are-a-map-keyed-by-source)). The room
server keeps, per participant, the state of its session (`media`: `:none`,
`:publishing`, `:adopting`, `:pending`, `:live`) and its publications
(`tracks`: source => `%{status: :pending | :live | :closing, mid, muted}`).
Policies and clients see the live ones in `participant.tracks` (source =>
`%{kind, muted}`).

- **First publish.** The client's `publish` carries its offer and may hold
  several sources. It creates the session and pushes the tracks. They are
  `:pending` until the client sends `connected`.
- **Publishing later is server-paced**
  ([D32](decisions.md#d32-publishing-after-joining-is-server-paced)). Turning
  a camera on mid-call is `publish_tracks`, which only asks. The request
  joins the session's queue, and on its turn the server sends `push` and the
  client offers.
- **Unpublish closes pulls first**
  ([D33](decisions.md#d33-unpublish-closes-pulls-first)). The track leaves
  the directory at once, so the reconciler closes everyone's pulls of it; the
  publisher's own track closes once nobody pulls it.
- **Mute is not unpublish**
  ([D34](decisions.md#d34-mute-is-a-flag-and-not-an-unpublish)). A muted
  track keeps its transceiver and subscribers see `muted: true`. Nothing
  reconciles or renegotiates. A muted camera sends black frames
  (`track.enabled = false`), so the track stays pullable.
- **Permissions.** `join/2` metadata may carry `publish: [sources]`; without
  it every source is allowed. The room server refuses any other source.

## Signaling protocol (channel ⇄ client)

The client holds one `RTCPeerConnection` to Cloudflare. The server tells it
what each transceiver is.

| Direction       | Message          | Payload                                                                                                             |
| --------------- | ---------------- | ------------------------------------------------------------------------------------------------------------------- |
| client → server | join             | The app's params, plus `resume_token` after a reconnect.                                                            |
| join reply      |                  | `{participant_id, participants, workers, ice_servers, resumed, resume_token}`; `workers` are those it sees now.     |
| client → server | `publish`        | `{sdp: offer, mids: {mic: "0", camera: "1"}}`: creates the session. The reply is `{sdp: answer}`.                   |
| client → server | `connected`      | `{}` once the peer connection is up (and again after each `push`), so what it published is flowing and can be pulled. |
| client → server | `publish_tracks` | `{sources: ["camera"]}` once the session exists; replied to once Cloudflare has the tracks.                         |
| server → client | `push`           | `{op_id, sources}`: this session's turn to add those transceivers.                                                  |
| client → server | `push_offer`     | `{op_id, sdp, mids}`; the reply is `{sdp: answer}`.                                                                 |
| client → server | `unpublish`      | `{source}`: every pull of it closes, then the server sends `close` for its mid.                                     |
| client → server | `mute`           | `{source, muted}`; others see `participant.tracks[source].muted`.                                                   |
| server → client | `renegotiate`    | `{sdp: offer, op_id}`: Cloudflare's offer after a pull.                                                             |
| client → server | `answer`         | `{sdp, op_id}`                                                                                                      |
| server → client | `close`          | `{mids, op_id}`: stop these transceivers.                                                                           |
| client → server | `close_offer`    | `{sdp, op_id}`, the offer made after stopping them; the reply is `{sdp: answer}`.                                   |
| server → client | `tracks`         | `{added: [{mid, track, kind, source, participant_id, worker_id, gain}], removed: [mid]}`. With `reset: true`, `added` is the complete list and the client drops everything else. |
| server → client | `gain`           | `{mid, gain}`                                                                                                       |
| server → client | `room_event`     | `{type, participant}` for joined, left, updated and published.                                                      |
| server → client | `resume_token`   | `{token}`: a fresh token when the session is created or the metadata changes.                                       |
| server → client | `republish`      | `{reason}`: the client's Cloudflare session is gone, so it starts its media over and publishes again.               |
| server → client | `worker`         | `{op: "added" \| "updated" \| "removed", worker: {id, outputs, data, state, attributes}}` (just `{id}` when removed). |
| server → client | `worker_event`   | `{worker, output, type, data}`, from the worker's `notify:`.                                                        |
| client → server | `worker_message` | `{worker, payload}`, `payload` an object. Refused with `too_large`, `no_worker`, `not_allowed` or `rate_limited`.   |

`op_id` ties an answer to the operation that asked for it, so a late answer
after a reconnect is rejected instead of applied to the wrong state. The
client applies `tracks` only after the matching renegotiation completes, so
mids always refer to transceivers that exist.

A client message with a known event but a body of the wrong shape (a
`mids` that isn't a map of strings, a non-string `sdp`) gets the error reply
`{reason: "bad_payload"}`; an unknown event gets `unknown_event`. See
[Bad input](#bad-input).

A client that doesn't answer a signaling request within 15 s is removed from
the room, rather than left with Cloudflare and the client disagreeing. A
disconnected client is exempt: the request is sent again when it resumes.

Gain is applied in the client: each remote audio track's `<audio>` element
`volume` in the browser
([D6](decisions.md#d6-gain-is-applied-in-the-listeners-client)). Cloudflare
forwards each track unchanged.

## Workers

```elixir
@callback init(args :: term, ctx :: Octoroom.Worker.Context.t()) :: {:ok, state} | {:ok, state, actions} | {:stop, reason}
@callback handle_audio(input :: String.t(), pcm :: binary, state) :: {:ok, state} | {:ok, state, actions}
@callback handle_info(msg :: term, state) :: {:ok, state} | {:ok, state, actions}   # optional
@callback terminate(reason, state) :: any                                          # optional

# actions
play: {output, pcm}      # queued on the outlet, paced to real time; :default is the first output
flush: output            # drop queued, unplayed audio (barge-in); the worker then gets
                         # {:octoroom, :flushed, output, dropped_ms} in handle_info/2
emit: event              # broadcast {:worker_event, worker_id, event} to scope: :room subscribers
notify: {output, type, data}   # an event for the clients subscribed to output (audio or data);
                               # with a participant id as a 4th element, for that one only
presence: %{state: s, attributes: a}   # what clients show for this worker
```

- `use Octoroom.Worker, audio: [rate: 16_000, channels: 1]` picks the PCM
  format the worker sees: s16le at a rate dividing 48 kHz, 1 or 2 channels.
  The default is the room's own format, 48 kHz stereo. The worker plays in
  the same format unless `output: [rate: ..., channels: ...]` gives another
  ([D38](decisions.md#d38-a-worker-can-speak-at-another-rate-than-it-hears)).
- `ctx` contains the room id, the worker id, input and output names, the
  room's participant list at start, and `resumed` (`%{gone_ms: ms}` when the
  room is recovering, otherwise nil). The worker can call
  `Octoroom.Room.state/1` for anything newer.
- `Octoroom.Worker.send(room_id, id, message)` reaches a worker's
  `handle_info/2` from outside, for example to flush from a LiveView.
- `worker(id, module, data: ["notes"])` gives a worker data-only outputs:
  names that `subscriptions/2` lists like tracks but that carry no media,
  for a worker with something to tell clients and nothing to play.
- Workers are plain processes, so a worker can delegate its media to
  anything: a Membrane pipeline, a Pythonx model, or a voice-agent library's
  session. That's how AI integrations plug in. What Octoroom guarantees them
  without knowing about AI: real-time pacing, `flush` for barge-in, per-input
  streams labelled by participant, and `emit` for captions and transcripts.

### Workers and clients

A worker reaches clients through its outputs
([D44](decisions.md#d44-workers-reach-clients-through-their-outputs)). A
participant sees an output once it's subscribed to it: an audio output when
its pull is open, a data output as soon as `subscriptions/2` lists it
(before its media is up, with no call to Cloudflare). After each reconcile
the room server compares what each participant sees with the last pass:

- the worker gets `{:octoroom, :subscribed | :unsubscribed, participant_id,
  output}` in `handle_info/2` (and `:subscribed` for everyone again after a
  restart), so it can catch a new subscriber up with a `notify:` to them;
- the client gets `worker` `added` or `removed`, and the latest presence of
  every worker it sees in its join and resume replies.

`notify:` events go to the subscribers of their output (the first, by
default); `presence:` goes to the subscribers of any of the worker's
outputs. Payloads are checked as JSON in the worker, which crashes on a bad
one rather than a client's channel. A restarted worker's `state` is nil
until it sets it again; its `attributes` are kept.

A client may message a worker (`worker_message`, `room.send/2`) only if one
of the worker's inputs is its track, and the room's optional `message/3`
callback agrees. Payloads over `worker_messages: [max_bytes:]` (16 KB) are
refused in the channel; each participant has a token bucket per worker
(`per_second: 10`, `burst: 20`). The worker gets `{:octoroom, :message,
participant_id, payload}`.

`octoroom_agents` builds on this: agents set their state as presence, send
`transcript`, `transcript_snapshot` and `error` events, and answer typed
`{text}` messages. `agents/priv/static/octoroom_agents.mjs` and the Swift
`OctoroomAgents` product decode them.

### Worker media transport

Workers' media runs over WebRTC
([D24](decisions.md#d24-workers-move-to-webrtc-peers)). Each worker with
media gets:

- **A peer** (`Octoroom.Peer`). It owns the `ex_webrtc` peer connection and
  the worker's Cloudflare session
  ([D25](decisions.md#d25-each-peer-makes-its-own-cloudflare-calls)). It
  answers Cloudflare's offers after a pull, makes offers for pushes and
  closes, and routes RTP between the connection and the worker's inlets and
  outlets. The room server tells it what to push, pull and close
  (`Peer.push/4`, `pull/4`, `close/2`) and hears back as
  `{:peer_result, worker_id, pid, result}`; the peer carries it out one
  offer/answer exchange at a time, batching requests that queue up. Its
  Cloudflare calls run in tasks, so it keeps routing RTP while one is
  pending. A push, renegotiation or close that fails leaves the connection's
  signaling state unknown, so the peer stops and the room starts the worker's
  media afresh, with backoff. Peers trap exits, so stopping one closes its
  peer connection and Cloudflare sees the session end within seconds.
- **An inlet per live input** (`Octoroom.Inlet`). RTP goes through a 50 ms
  jitter buffer and an Opus decoder straight to the worker's format (libopus
  resamples; [D43](decisions.md#d43-inlets-decode-to-the-workers-format)),
  is held to real time, and sent to the worker 20 ms at a time by
  registered name, tagged with its format, so a restarted worker picks up
  the same streams. When a restart brings a module that hears in another
  format, the room tells the inlet, and the worker drops the few frames
  still in the old one. The decoder is picked per packet by channel count,
  because browsers send mono. The hold is a token bucket: 20 ms of audio per 20 ms,
  up to 300 ms saved for bursts; frames that find it empty are dropped, and
  `Room.state/1` reports the count per input
  ([D16](decisions.md#d16-inlets-are-held-to-real-time)).
- **An outlet per output** (`Octoroom.Outlet`). It queues the worker's PCM
  and sends one 20 ms Opus frame per 20 ms tick, and nothing when the queue
  is empty. `flush` empties the queue, so at most one frame plus the network
  is already on its way, and tells the worker how many ms it dropped: an
  agent uses that to know how much of its reply was heard. Audio that comes due before the connection is up is
  dropped, as a live stream would be. The clock stops when the queue runs
  dry; a lag over 100 ms restarts it rather than sending a burst. The first
  packet sent tells the room server the track is live.
  `Octoroom.Outlet.stats/2` reports queued ms, frames sent and dropped, and
  underruns ([D15](decisions.md#d15-outlets-pace-to-real-time)).

Inlets and outlets are separate processes so that decoding and encoding
spread over schedulers instead of queueing behind the peer.

Connectivity: the peer gathers host candidates only (no STUN) with
aggressive nomination, and Cloudflare learns the app's public address from
the connectivity checks, so NAT needs no configuration
([D28](decisions.md#d28-host-candidates-only-with-workarounds-for-cloudflare)).
A peer whose connection isn't up 10 s after its first negotiation, or whose
ICE fails, logs an error saying workers need outbound UDP to Cloudflare and
stops; the room retries with backoff and gives up after five tries. There is
no check at boot
([D27](decisions.md#d27-no-startup-check-for-outbound-udp)).

The peer connection sits behind `Octoroom.Peer.Media`
(`Octoroom.Peer.WebRTC` by default). Tests use a fake that moves PCM
in-process, and another transport would plug in there without the worker or
the room server changing.

## Failure and cleanup

| Event                        | Handling                                                                                                                                                                                                                             |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Client leaves                | The channel exits with `{:shutdown, :left}` and the participant is removed. The reconciler closes subscriptions to it and stops workers that no longer appear in `workers/1`. The browser client leaves on `pagehide`.                |
| Client's connection drops    | Any other shutdown of the channel is a disconnect, not a leave ([D21](decisions.md#d21-a-dropped-connection-is-not-a-leave)). The participant stays for the grace period (60 s) and its subscriptions stay as they are. If it resumes, it gets a `tracks` reset and any request it missed again. If not, it is removed as a leave. |
| Client ignores signaling     | Removed after 15 s (see [Signaling protocol](#signaling-protocol-channel--client)).                                                                                                                                                  |
| Bad client payload           | Refused with a `bad_payload` reply, by the channel and again by the room server, so it can't crash the room. See [Bad input](#bad-input).                                                                                           |
| Room callback raises         | `workers/1` or `subscriptions/2` raising, throwing, exiting or returning the wrong shape keeps its last good answer, and is logged, broadcast and emitted as telemetry. See [Bad input](#bad-input).                                  |
| Worker crashes               | The room server restarts it with backoff and broadcasts `{:worker_down, id, reason}`. Its peer, inlets, outlets and tracks survive, so nothing at Cloudflare changes. A worker that ran 30 s before crashing starts its backoff afresh. |
| Inlet or outlet crashes      | Its track is closed at the peer and the reconciler starts it again, with backoff ([D30](decisions.md#d30-crashed-inlets-and-outlets-back-off)).                                                                                       |
| Worker peer stops or fails   | It takes its worker's inlets and outlets with it. Listeners' pulls of its outputs close, and everything comes back on a new session through the normal reconcile, with backoff.                                                       |
| Worker peer doesn't connect  | After 10 s (or when ICE fails) it logs that workers need outbound UDP and stops; the room retries with backoff.                                                                                                                       |
| Cloudflare call fails        | The HTTP client retries 429, 502, 503 and 504 for every call, and transport errors only for `GET`s: 3 attempts, 200 ms doubling. A pull that still fails, including `empty_track_error`, is retried by the room with backoff. Pull results are per track, so a batched pull can partly succeed. |
| Room server crashes          | The whole room shuts down. Each channel sees it and resumes its participant into a new run, which recovers the room as after a deploy.                                                                                                |
| Node restarts or deploys     | See [Restarts and deploys](#restarts-and-deploys).                                                                                                                                                                                   |
| Leaked sessions              | None to clean up. A session ends when its peer connection closes, including when the node dies. `Octoroom.Janitor` only deletes room records no resume token can reach any more.                                                      |

**Backoff and giving up** ([D23](decisions.md#d23-retries-and-giving-up)).
The room server counts failures per thing: a participant's pull of a track,
a worker, or a piece of worker media (peer, inlet, outlet). Each failure
waits 0.5 s, 1 s, 2 s and so on. At the fifth, the room stops retrying,
logs a warning and broadcasts `{:error, what, reason}`. The count clears
when the thing shows it works again: the track is published again, the peer
connects, the output is pushed or goes live, the input is pulled. Until
then it stays given up.

### Bad input

The room server is the room's single writer, and when it crashes the whole
room restarts and recovers (see [Restarts and deploys](#restarts-and-deploys)).
That's right for real crashes, but a malformed client message or a bug in
app code could trigger it at will, and a raising policy would raise again on
every reconcile after recovery, so the room would loop. So both are refused
at the boundary where they come in.

- **Client payloads.** The channel checks each event's body (`sdp` and
  `op_id` strings, `mids` a map of string to string, `sources` a list of
  strings, `source` a string) and replies `bad_payload` otherwise, instead
  of the misleading `unknown_event`. The room server checks the same shapes
  again before handling a request, since it's also called without a channel
  (`Octoroom.Room.join/4` is public), and replies `{:error, :bad_payload}`;
  a malformed `mute`, which has no reply, is dropped. Values of the right
  shape that are still wrong (an unknown source, a stale `op_id`) are
  refused further in.
- **Join metadata.** `check_sources/2` reads the metadata's `:publish` (or
  `"publish"`, so an app passing client params through as metadata lets a
  client set it). A join refuses metadata that isn't a map, or a `publish`
  that isn't a list, with `{:error, {:bad_meta, meta}}` (a room started just
  for that join stops again, unless it's recovering), and `update_meta/3`
  refuses it as a bad return. Metadata that gets past both (resume data that
  didn't come from a join) is refused publishing.
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

## Restarts and deploys

A deploy, a node crash and a room server crash all lose the room's in-memory
state. They don't lose the room: most of it lives at Cloudflare and in the
clients, and Octoroom rebuilds the rest from there
([D17](decisions.md#d17-recover-by-adopting-sessions-through-resume-tokens)).

### What survives

| Piece                                                              | Lives in                | When the node goes away                                                                                                        |
| ------------------------------------------------------------------ | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Client ⇄ Cloudflare media (people hearing and seeing each other)   | Cloudflare              | **Keeps working.** The server isn't in that path.                                                                              |
| Each client's Cloudflare session and the tracks pulled into it     | Cloudflare              | Keeps working, as long as the peer connection stays up.                                                                        |
| Phoenix channel (signaling)                                        | The node                | Drops. The client reconnects on its own, with backoff.                                                                         |
| Room server state: participants, track directory, operation queues | The node's memory       | Lost, then rebuilt (below).                                                                                                    |
| Worker processes and their in-memory state                         | The node                | Lost. Workers are restarted.                                                                                                   |
| Worker peer connections and their Cloudflare sessions              | The node and Cloudflare | Drop. The sessions end within a minute, so worker output tracks are dead to listeners. Nothing is left to close.               |
| Room assigns                                                       | `Octoroom.Store`        | Survive.                                                                                                                       |

### Recovery

1. **Resume tokens.** The join reply carries a resume token: an encrypted
   `Phoenix.Token` with the room id, participant id, Cloudflare session id
   and the participant's `join/2` metadata (encrypted, so the client can't
   read the metadata either). When the channel reconnects, the client
   rejoins with it; `join/2` isn't called again. The token stops a client
   from claiming another client's session. Its max age is the longest outage
   a room survives (default 10 minutes). The server pushes a fresh one when
   the session is created and when metadata changes.
2. **Runs.** Each start of a room server is a run. A room record left in the
   store means the previous run didn't stop cleanly, so the new run
   recovers: it takes the assigns from the record instead of calling
   `mount/1`, and starts a grace period. The record is deleted only when the
   room stops because its last participant left.
3. **Resume has three cases.**
   - The room kept running and still has the participant (only its
     connection dropped): its process is replaced, and it gets the full list
     of what it receives.
   - The participant never published: it starts over as a new join with the
     same id and metadata.
   - The room restarted: **adopt, don't reset.** The participant is re-added
     with the metadata from its token, and its Cloudflare session is read
     back (`GET` session state). The pushed tracks named
     `"<id>/<source>"` become its publications, live and unmuted (the
     client sends its mute flags again). The pulled tracks become its open
     subscriptions, with their mids. The server then sends `tracks` with
     `reset: true`, and the client keeps what matches and drops the rest:
     Cloudflare wins. If the session is gone, the server sends `republish`.
4. **Grace period.** For 60 s after recovery, participants who haven't
   resumed yet don't count as having left: pulls of their tracks ("ghosts")
   are held. When the window ends, anyone who hasn't come back is gone, and
   the pulls close. Workers that depend on them start when they come back.
5. **Reconcile as usual.** For people, desired and actual state normally
   already match, so no renegotiation happens and nobody hears a gap.
6. **Workers restart** with new peers, so new sessions, inlets and outlets.
   An adopted pull of a worker output is marked stale: the reconciler closes
   it and pulls the track again from its new session once it's live
   ([D22](decisions.md#d22-stale-worker-output-pulls-are-closed-and-pulled-again)).
   Listeners hear the worker go quiet for a few seconds. Workers started in
   the grace period get `ctx.resumed: %{gone_ms: ms}`, from a 5 s heartbeat
   on the room record, so they can tell a fresh start from a recovery.

The result: people don't notice, workers drop out for a few seconds, and
nothing leaks.

A client that comes back without a valid token (expired, or the page
reloaded) joins as a new participant. Its old Cloudflare session dies on its
own when that peer connection closes.

When only the room server crashes, the channel stays up and resumes on its
own from the resume data it keeps.

### What stays the developer's job

Worker memory. An agent's conversation so far lives in the worker process,
and Octoroom can't snapshot it. A worker that needs to survive restarts
persists its own state, e.g. conversation history in the app's database
keyed by room id, and reloads it when `ctx.resumed` is set.

### `Octoroom.Store`

A key-value behaviour (`get`, `put`, `delete`, `all`, plus `child_spec`)
with one table ([D18](decisions.md#d18-the-store-holds-room-records-and-no-participant-state)):

- `:rooms`: room id => `%{run, assigns, updated_at}`. Written when a room
  server starts, when its assigns change and on its heartbeat.

The store holds no participant state and no worker sessions. Participants
come back through their resume tokens, and worker sessions end with their
peer connections.

`Octoroom.Store.ETS` is the only implementation: an ETS table, snapshotted
to a file (`octoroom-<node>.store` in the temp directory unless configured)
50 ms after a write. That is enough for one node that restarts in place. A
deploy that replaces the machine needs a store outside it, which an app can
provide by implementing the behaviour.

`Octoroom.Janitor` sweeps 5 s after boot and then every minute, and deletes
records of rooms that aren't running and whose `updated_at` is older than a
resume token's max age. Past that, the record would only make a new room
with the same id think it's recovering.

## Security

- Cloudflare credentials stay on the server. Clients never see a Cloudflare
  session id other than in their own SDP.
- Only the room server and worker peers call Cloudflare, so a client cannot
  pull a track the policy didn't grant, even with a modified client.
- `join/2` runs the app's authorization; the socket's `connect/3` handles
  socket auth as usual. A resume skips `join/2` and trusts the token's
  metadata for the token's max age.
- Resume tokens are encrypted with the endpoint's `secret_key_base` and
  bound to the room id.
- Nothing listens for media. Clients and worker peers both connect out to
  Cloudflare, so there's no media endpoint to protect.

## Telemetry

`Octoroom.Telemetry` lists the events: Cloudflare requests, peer connects,
pulls, room starts, stops and recoveries, participant joins, resumes and
leaves, worker starts and exits, failures, room callback (policy) errors
and janitor sweeps.

Joins are timed step by step, to see where the time to a working call
goes. `[:octoroom, :participant, :connected]` splits a join into what the
server saw (before the publish arrived, creating the session and pushing,
connecting) and, when the client sends them with `connected`, what the
client measured (the channel join, getUserMedia, the wait for a first ICE
candidate and whether it timed out, the publish round trip, ICE and DTLS).
The browser client sends them and also emits them as a `timings` event.
`[:octoroom, :participant, :first_pull]` marks when a participant first
hears someone, and `[:octoroom, :outlet, :live]` when a worker's output
first sends audio, before which nobody can pull it.
`Octoroom.Telemetry.attach_default_logger/1` logs a line for each.

## Testing

- `Octoroom.Reconciler.diff/2` and `diff_workers/2` are pure and tested as
  desired plus actual state in, operations out, with table tests and
  property tests.
- `Octoroom.Cloudflare` is a behaviour. `Octoroom.Cloudflare.HTTP` uses
  `Req`, and tests use `Octoroom.Test.FakeCloudflare`, an in-memory fake that
  models sessions, tracks, pending and live states, and the
  `empty_track_error` rule.
- Audio conversion, the inlet and outlet pacing get unit tests. Room and
  worker tests run the real `Octoroom.Peer` over
  `Octoroom.Test.FakePeerMedia`, which uses placeholder SDP and moves PCM
  through the fake Cloudflare, so they need no UDP.
- `Octoroom.Test.Client` plays a client's side of the signaling protocol in
  room, recovery and video tests.
- The bad-input cases in `test/octoroom/room_test.exs` drive the room server
  directly, and `test/octoroom/phoenix/channel_test.exs` calls the channel's
  `__handle_in__/3` with a stand-in socket whose "room server" is the test
  process.
- The browser client has tests with a fake `RTCPeerConnection` (`test/js`),
  and the Swift client has its own with fakes (`swift/Tests`).

## Dependencies

| Dep                    | Why                                                                                                                        | Optional                                                    |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `req`                  | Cloudflare API                                                                                                             | no                                                          |
| `jason`                | JSON                                                                                                                       | no                                                          |
| `telemetry`            | Metrics                                                                                                                    | no                                                          |
| `ex_webrtc`            | Worker peer connections. Its DTLS and SRTP use NIFs; libsrtp comes from the system.                                        | no                                                          |
| `membrane_opus_plugin` | Only its Opus NIFs (`Membrane.Opus.{Encoder,Decoder}.Native`), for inlets and outlets. It downloads a precompiled libopus. | no                                                          |
| `phoenix`              | `Octoroom.Phoenix.Channel`                                                                                                 | yes. Without it, the core still runs: `Octoroom.Room.join/4` takes any process as a participant. |

## Where things are

| Path                               | Holds                                                                          |
| ---------------------------------- | ------------------------------------------------------------------------------ |
| `lib/octoroom/room.ex`             | The room behaviour, policy helpers and the functions for running rooms.        |
| `lib/octoroom/room/server.ex`      | The room server.                                                               |
| `lib/octoroom/room/supervisor.ex`  | The per-room supervisor.                                                       |
| `lib/octoroom/reconciler.ex`       | Both pure diffs.                                                               |
| `lib/octoroom/phoenix/channel.ex`  | The channel: signaling relay and resume tokens.                                |
| `lib/octoroom/worker.ex`, `worker/server.ex` | The worker behaviour and the process that runs a worker module.      |
| `lib/octoroom/peer.ex`, `peer/webrtc.ex` | A worker's peer and its `ex_webrtc` implementation.                      |
| `lib/octoroom/inlet.ex`, `outlet.ex`, `audio.ex` | Worker media.                                                    |
| `lib/octoroom/cloudflare.ex`, `cloudflare/http.ex` | The Cloudflare behaviour and its HTTP client.                  |
| `lib/octoroom/store.ex`, `store/ets.ex`, `janitor.ex` | Room records.                                               |
| `priv/static/octoroom.mjs`         | The browser client.                                                            |
| `swift/`                           | The Swift client.                                                              |
| `examples/call`                    | A LiveView group call with video, a private echo, a metronome, a recorder and captions. |
| `examples/ios`                     | An iOS app that joins the same rooms.                                          |
| `examples/meet`                    | A LiveView video call with two agents, their state and a box to type to them.  |
