# Proposal: worker events for clients

Workers become visible to clients: their presence, their events, and
messages back to them, all scoped by the room's policy. `octoroom_agents` builds
agent state, transcripts and typed messages on top. This is phase 4
("Clients") of [proposal-agents.md](proposal-agents.md#phases), narrowed to
what core needs.

Names (`notify:`, `presence:`, `data:`, `worker_message`) are proposals.

## Decisions

Settled in discussion on 2026-11-18. When this is built, they go into
decisions.md as one entry
([D44](decisions.md#d44-workers-reach-clients-through-their-outputs)).

1. **Scope follows subscriptions.** A worker's events reach only the
   participants subscribed to the output they're tagged with. The coach's
   words reach the agent's browser and never the customer's, with no second
   policy to write.
2. **Core knows workers, not agents.** Core carries presence, opaque events
   and messages. `octoroom_agents` owns the shapes (agent state, transcript
   items) and ships the typed client helpers. Shapes that change often stay
   out of core's protocol, and the Swift client in particular.
3. **Messages come only from participants the worker hears.** A client may
   message a worker only if one of its tracks is among the worker's inputs.
   An optional room callback, `message/3`, can narrow that further.
4. **Presence is scoped like events.** A client sees a worker in its room
   state only while it's subscribed to one of the worker's outputs.
5. **Late joiners get the latest presence only.** Core keeps each worker's
   current presence and sends it on subscribe or resume. Events are
   fire-and-forget. A worker that wants history replayed sends the new
   subscriber a snapshot, and core tells it when one arrives.
6. **Events name an output.** They go to the subscribers of their output
   (the first output by default). Presence goes to the subscribers of any
   output. Spanish listeners get Spanish captions and French listeners get
   French ones.
7. **Data-only outputs, over Phoenix.** A worker with nothing to play (a
   notetaker, a captioner) declares data outputs. `subscriptions/2` lists
   them like tracks. They never touch Cloudflare: events and presence go
   over the channel each client already has open.
8. **`subscribe/2` replaces `subscribe/1`.** `scope: {:participant, id}` gets
   exactly what that participant's channel gets. `scope: :room` gets
   everything, for trusted code that doesn't act for a user (recorders,
   analytics, admin views). Every caller has to choose, so unscoped access
   is never an accident.
9. **Inbound limits in core.** A size cap and a rate limit per participant
   per worker, configurable.
10. **Agents answer typed messages regardless of the gate.** Messaging a
    worker by id is already addressing it. The message still enters the
    shared history with the sender as speaker.
11. **The first version includes Swift.** That means core, the JS client,
    the Swift client, the agents shapes with helpers for both clients, meet
    on scoped subscribe, and the iOS example.

## Design

### Worker API (core)

```elixir
# in workers/1
worker("notes", MyApp.Notetaker, inputs: mics, data: ["notes"])
worker("interp", MyApp.Interpreter, inputs: [mic(host)], outputs: ["interp/es", "interp/fr"])
```

- **`data:` on `worker/3`**: names of data-only outputs. They share the
  track namespace (so they can't collide with track names) but are never
  pushed, pulled or put in the track directory. `default_subscriptions/2`
  includes them, next to audio outputs.
- **New actions** (`Octoroom.Worker`):
  - `notify: {output | :default, type, data}`: sends a client event, where
    `type` is a string and `data` a JSON-encodable map. It goes to the
    channels and scoped subscribers of that output's subscribers, and to
    `scope: :room` subscribers.
  - `notify: {output | :default, type, data, participant_id}`: the same,
    for one subscriber only. Dropped if that participant isn't subscribed.
    This is how a worker sends a snapshot.
  - `presence: %{state: String.t() | nil, attributes: map}`: replaces the
    worker's presence. It's kept by the room server and pushed to everyone
    who can see the worker.
  - `emit: term` is unchanged: server-side only, `scope: :room` subscribers
    only, any term. Workers keep it for debugging events (decisions,
    latency).
- **New messages to `handle_info/2`:**
  - `{:octoroom, :message, participant_id, payload}`: a client message that
    passed the permission check and the limits.
  - `{:octoroom, :subscribed, participant_id, output}` and
    `{:octoroom, :unsubscribed, participant_id, output}`: who can see what.
    This is the trigger for snapshots.

`notify` and `presence` go to the room server, which owns subscriptions,
not to `Octoroom.broadcast` as `emit` does
([worker/server.ex:118](../lib/octoroom/worker/server.ex)). The worker
server sends `{:worker_notify, id, ...}` and `{:worker_presence, id, ...}`
casts.

### Room server (core)

- **Data subscriptions.** `subscriptions/2` results are split by name:
  names that are data outputs of current worker specs go to a new
  `p.data_subs` (a `MapSet`). The rest go to the reconciler as today. Data
  subs are diffed in the room server, not in `Octoroom.Reconciler`, because
  they have no operations, only bookkeeping. They're computed for every
  participant with a channel, even before its media is up.
- **Who sees what.** A participant sees output `o` when it has
  `p.subs[o].status == :open` (audio) or `o in p.data_subs` (data). It sees
  worker `w` when it sees any of `w`'s outputs. After each reconcile step
  that changes this, the server pushes presence additions and removals and
  sends the worker `:subscribed` and `:unsubscribed`.
- **Presence storage.** `state.workers[id].presence`, kept across worker
  restarts (a restart clears it to `nil` state and keeps the last
  attributes until the worker sets new ones), and removed with the worker.
  It's included in `Room.state/1`.
- **Fan-out.** `notify` loops over participants who see the output and
  `signal`s each channel. It also sends to scoped subscribers registered as
  that participant, and to the `scope: :room` Registry. Participants with
  `pid: nil` (disconnected) get nothing; their resume reply carries current
  presence.
- **Messages.** `handle_cast({:worker_message, participant_id, worker_id,
payload, ref})`:
  1. the worker exists and is running, otherwise `no_worker`;
  2. one of the participant's track names is in the worker spec's inputs,
     and `module.message(sender, worker_id, room)` (if defined) returns
     true, otherwise `not_allowed`;
  3. the token bucket for `{participant_id, worker_id}` has a token,
     otherwise `rate_limited`;
  4. it sends `{:octoroom, :message, participant_id, payload}` to the
     worker and replies `:ok`.
- **Limits.** `config :octoroom, worker_messages: [max_bytes: 16_384,
per_second: 10, burst: 20]`. The size check happens in the channel,
  before the payload reaches the room server (`too_large`). Buckets live in
  room server state and are dropped when the participant leaves.

### Subscriptions (core)

```elixir
Octoroom.subscribe(room_id, scope: :room)              # today's behavior, Registry-backed
Octoroom.subscribe(room_id, scope: {:participant, id}) # what that participant's channel gets
```

- `scope: :room` keeps the `Octoroom.Events` Registry. It gets room events,
  `emit`, every `notify` and every presence change.
- `scope: {:participant, id}` registers in the same Registry, with the
  scope as the entry's value. The room server computes each event's
  recipients and dispatches to the matching entries
  (`Octoroom.deliver/3`). Because it uses the Registry, a subscription
  survives room crashes, can be made before the room or the participant
  exists, and is cleaned up when the subscriber exits. It receives
  `{:octoroom, room_id, event}` with the same events the channel pushes,
  as Elixir terms: room events,
  `{:worker, :added | :updated | :removed, presence}`, and
  `{:worker_notify, worker_id, output, type, data}` (not `:worker_event`,
  which stays the 3-tuple `emit` sends to `scope: :room`). It also receives them
  while the participant is disconnected. The participant id in `scope:`
  is trusted (server code can pass any id), and the docs say so.
- `subscribe/1` is removed. Callers: meet's `room_live.ex`, the `call`
  example's `call.ex` and `lab.ex`, core and agents tests.

### Channel protocol (core)

Server → client, added:

- the join and resume replies gain `workers`: the presence of every worker
  this participant sees;
- `worker`: `{op: "added" | "updated" | "removed", worker: {id, outputs,
data, state, attributes}}`;
- `worker_event`: `{worker, output, type, data}`.

Client → server, added:

- `worker_message`: `{worker, payload}`. It replies `ok`, or an error with
  `not_allowed`, `no_worker`, `too_large` or `rate_limited`. Shapes are
  checked in `Octoroom.Phoenix.Channel` like other events (`bad_payload`).

### JS client (`priv/static/octoroom.mjs`)

```js
room.on("workers", (list) => render(list))        // [{id, outputs, data, state, attributes}]
room.on("worker_event", ({worker, output, type, data}) => ...)
await room.send("assistant", {text: "add Acme to the sheet"})
```

`this.workers` is kept like `this.participants`: replaced from join and
resume replies, patched by `worker` pushes.

### Swift client (`swift/Sources/OctoroomCore`)

- `Models.swift`: a `Worker` struct (`id`, `outputs`, `data`, `state`,
  `attributes: [String: JSONValue]`).
- `RoomClient.swift`: `Event.workers([Worker])` and
  `Event.workerEvent(worker:output:type:data:)`, handlers next to
  `onRoomEvent`, and `func send(to worker: String, _ payload: JSONValue)
async throws`.
- Tests in `OctoroomCoreTests` with the existing `Fakes.swift`.

### Agents (`agents/`)

- **Outputs.** `agent/3` gives an agent without a voice a data output named
  after its id (today it gets no outputs at all), so text-only agents can
  be seen.
- **Presence.** Name and description in `attributes`. `state` is one of
  `listening`, `thinking`, `speaking` and `waiting`, set from transitions
  the worker already tracks (`:waiting`, `:follow_up`, first audio played,
  reply done).
- **Events.** Conversation items
  ([conversation_events.ex](../agents/lib/octoroom/agent/conversation_events.ex))
  become `notify: {:default, "transcript", item}` with `speaker` added. So
  do agent errors (`"error"`). Decisions and latency stay on `emit` for the
  lab and other server-side views.
- **Snapshots.** On `{:octoroom, :subscribed, pid, _}`, the agent sends
  that participant its recent transcript items (`notify/4`), capped at a
  configurable count.
- **Messages.** `{:octoroom, :message, from, %{"text" => text}}` becomes a
  user turn with `speaker: from`, answered regardless of `respond:` and
  `gate:`, the same path `prompt/3` takes, plus the speaker. Other payload
  shapes are ignored and logged at debug.
- **Client helpers.** `agents/priv/static/octoroom_agents.mjs`:
  `agents(room)` returns an emitter with `on("agents")`,
  `on("transcript")` and `say(id, text)`, built only on the core JS API. A
  Swift `OctoroomAgents` product in `Package.swift` does the same: typed
  `Agent` and `TranscriptItem`, decoded from `Worker` and `workerEvent`.

### Examples

- **meet**: `Octoroom.subscribe(room_id, scope: {:participant, me.id})` once the participant
  is known, and the transcript built from `transcript` events. Until then
  it keeps `scope: :room`.
- **iOS** (`examples/ios`): an agent tile showing state, a transcript
  list, and a text field that calls `send`.

## Steps

Each step is one commit, with tests passing.

1. **`subscribe/2`.** Add `scope: :room`, remove `subscribe/1`, update the
   callers. Scoped subscribers (`scope: {:participant, id}`) get the room
   events that participant's channel gets. Tests: a scoped subscriber gets
   the same room events as the channel and none of the room-wide ones; an
   unknown scope raises. (Done 2026-11-18.)
2. **Data outputs.** `data:` in `worker/3`, spec validation
   (`worker_spec?`), `p.data_subs`, `default_subscriptions/2`, and
   `Room.state/1` showing them. Tests: a data name in `subscriptions/2`
   never reaches Cloudflare (the fake sees no pull) and is recorded for a
   participant whose media isn't up. (Done 2026-11-18.)
3. **Presence and scoped events.** The `presence:` and `notify:` actions,
   visibility tracking, `:subscribed` and `:unsubscribed`, channel pushes,
   join and resume replies. Tests: the coach example (the customer gets
   neither presence nor events from the coach worker); per-output scoping
   with two outputs; resume carries presence; a worker restart keeps
   attributes. (Done 2026-11-18. As built: visibility is recomputed at the
   end of each reconcile into `state.seen`; `scope: :room` subscribers get
   untargeted `notify`s and `{:worker, :updated, _}` but no `:added` or
   `:removed`, which are per participant; `notify` and `presence` payloads
   are checked as JSON in the worker, which crashes on a bad one rather
   than the channel.)
4. **Messages.** The `worker_message` channel event, the permission check,
   `message/3`, size and rate limits. Tests: each error reason; an allowed
   message arrives with the sender's id. (Done 2026-11-18. As built:
   "hears" means one of the worker's inputs is the sender's track, whether
   or not it's live yet; refused messages don't spend a token; the payload
   must be a JSON object; `worker_messages:` can also be passed in the room
   opts.)
5. **JS client.** `workers`, `worker_event`, `send`. Checked by hand in
   `examples/call` until the Playwright test from the roadmap exists.
   (Done 2026-11-18, with Node tests against the fake channel in
   `test/js/room_client.test.mjs`. Checked by hand in `examples/meet`
   rather than `examples/call`, after step 6: assistant tiles show their
   presence, and a box types to an assistant with `room.send/2`.)
6. **Agents.** Presence, `transcript` events, snapshots, typed messages,
   text-only data output, and `octoroom_agents.mjs`. meet moves to scoped
   subscribe. Tests in `agents/test` with the fake providers. (Done
   2026-11-18, except meet: its transcript panel shows each turn's
   decision and latency, which stay server-side `emit`s, so it stays on
   `scope: :room`. As built: the snapshot is a `transcript_snapshot` event
   rather than one `transcript` per item; `Worker.Context` gained `data`;
   the helper's tests are `test/js/octoroom_agents.test.mjs`, so `bin/test
   js` runs them.)
7. **Swift.** Core client changes, the `OctoroomAgents` product, and the
   iOS example. (Done 2026-11-18. Checked in the simulator against meet:
   both assistants listed with their state, and typing to Atlas gets a
   spoken, transcribed answer.)
8. **Docs.** architecture.md (the worker contract, the channel protocol),
   the D44 entry in decisions.md, and the roadmap's "Worker events to
   clients" gap removed. (Done 2026-11-18, with a "Workers and clients"
   section in architecture.md and a "Clients" section in the agents
   README.)

Steps 5 and 7 depend only on the protocol from steps 3 and 4. Step 6
depends on steps 3 and 4 for the server side, and on step 5 for the JS
helper.

## Open questions

- **Typing to a worker that hears no one.** Under decision 3, a text-only
  chat agent with no inputs can't be messaged by anyone, and `message/3`
  can only narrow. Should `message/3`, when defined, replace the default
  rule rather than narrow it?
- **High-rate events.** Streaming partial transcripts could mean tens of
  pushes a second per listener. Should core coalesce events per output, or
  should agents send only finished items (as `ConversationEvents` does
  today)?
- **Events during `:opening`.** An audio subscription that's still
  opening doesn't see the worker yet, so events in that window are lost.
  The snapshot covers transcripts. Is anything else affected?
- **Room crash recovery.** A recovered room starts with no `seen`, so a
  client re-gets `added` for what it still sees, but never `removed` for a
  worker it saw before the crash and no longer does. The channel could
  push the full list after its own resume (`room_down/3`).
- **Changed outputs.** A worker whose outputs or data outputs change while
  a participant keeps seeing it sends no `updated`, so the client's
  `outputs` and `data` go stale until the next presence change.
- **Clustering.** Both scopes use the local Registry, so subscribers must
  be on the room's node. Moving events to Phoenix PubSub (roadmap) means a
  topic per room plus one per participant.
