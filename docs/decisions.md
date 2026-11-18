# Octoroom decision log

Why Octoroom is built the way it is: each decision, what led to it, and what
it replaced. Some entries describe code that no longer exists. For how
things work now, read [architecture.md](architecture.md); for what isn't
built, [roadmap.md](roadmap.md).

How to read an entry:

- **Current** decisions still hold, and architecture.md describes their
  result.
- **Superseded** decisions were built and later replaced. Their code is
  gone. They stay here because their findings shaped what replaced them.
- Entries are in the order the work happened. All of it is dated 2026-11-17
  unless an entry says otherwise.
- Measurements live in [Evidence](#evidence) at the end, and entries point
  to them.

When you make a new decision, add an entry at the end of the decisions with
the next number, and change the status of anything it supersedes. Update
architecture.md in the same change.

## Timeline

| Step                         | What was built                                                                                   | Commit    |
| ---------------------------- | ------------------------------------------------------------------------------------------------ | --------- |
| Milestones 1–2               | Primitives ported from Subvocal; browser-to-browser rooms: room server, reconciler, channel, JS client. | `f76d3f8` |
| Milestone 3                  | Workers, on Cloudflare's WebSocket adapters: outlets, inlets, worker supervision.                | `71771a6` |
| Inlet hold                   | Inlets held to real time.                                                                        | `ec38599` |
| Milestone 5 (robustness)     | Store, resume tokens, recovery, retries, telemetry. Built before milestone 4, so on adapters.    | `a04c0d9` |
| Milestone 4                  | Workers moved from WebSocket adapters to WebRTC peers. Adapter code removed.                     | `3e01fa5` |
| Video steps 1–2              | Publications per source; cameras, screen shares and mute in browsers.                            | `5acfc60` |
| Swift client                 | A port of the browser client for iOS and macOS.                                                  | `7871b60` |
| Agents phase 1               | `agents/` (`octoroom_agents`): Subvocal's cascaded pipeline as a worker. Separate output rates in core. | uncommitted |

## Index

| #                                                                    | Decision                                                  | Status                |
| -------------------------------------------------------------------- | --------------------------------------------------------- | --------------------- |
| [D1](#d1-cloudflare-realtime-sfu-is-the-only-media-plane)            | Cloudflare Realtime SFU is the only media plane           | Current               |
| [D2](#d2-routing-is-a-pure-policy-and-a-reconciler)                  | Routing is a pure policy and a reconciler                 | Current               |
| [D3](#d3-the-room-server-is-the-single-writer)                       | The room server is the single writer                      | Current               |
| [D4](#d4-one-cloudflare-session-per-browser)                         | One Cloudflare session per browser                        | Current, open question |
| [D5](#d5-octoroom-ships-no-ai)                                       | Octoroom ships no AI                                      | Current, amended by D37 |
| [D6](#d6-gain-is-applied-in-the-listeners-client)                    | Gain is applied in the listener's client                  | Current               |
| [D7](#d7-closing-a-subscription-is-client-offered)                   | Closing a subscription is client-offered                  | Current               |
| [D8](#d8-a-track-is-live-when-its-publisher-reports-connected)       | A track is live when its publisher reports connected      | Current               |
| [D9](#d9-events-go-through-a-registry)                               | Events go through a Registry                              | Current               |
| [D10](#d10-workers-connect-through-websocket-adapters)               | Workers connect through WebSocket adapters                | Superseded by D24     |
| [D11](#d11-worker-media-lives-apart-from-the-worker)                 | Worker media lives apart from the worker                  | Current               |
| [D12](#d12-the-room-server-restarts-crashed-workers)                 | The room server restarts crashed workers                  | Current               |
| [D13](#d13-per-room-supervisor-with-the-room-server-first)           | Per-room supervisor with the room server first            | Superseded by D20     |
| [D14](#d14-workers-are-reconciled-by-a-second-pure-diff)             | Workers are reconciled by a second pure diff              | Current               |
| [D15](#d15-outlets-pace-to-real-time)                                | Outlets pace to real time                                 | Current               |
| [D16](#d16-inlets-are-held-to-real-time)                             | Inlets are held to real time                              | Current               |
| [D17](#d17-recover-by-adopting-sessions-through-resume-tokens)       | Recover by adopting sessions through resume tokens        | Current               |
| [D18](#d18-the-store-holds-room-records-and-no-participant-state)    | The store holds room records and no participant state     | Current               |
| [D19](#d19-adapter-records-and-a-janitor-that-closes-adapters)       | Adapter records and a janitor that closes adapters        | Superseded by D24     |
| [D20](#d20-the-room-server-is-the-last-child)                        | The room server is the last child                         | Current               |
| [D21](#d21-a-dropped-connection-is-not-a-leave)                      | A dropped connection is not a leave                       | Current               |
| [D22](#d22-stale-worker-output-pulls-are-closed-and-pulled-again)    | Stale worker output pulls are closed and pulled again     | Current               |
| [D23](#d23-retries-and-giving-up)                                    | Retries and giving up                                     | Current               |
| [D24](#d24-workers-move-to-webrtc-peers)                             | Workers move to WebRTC peers                              | Current               |
| [D25](#d25-each-peer-makes-its-own-cloudflare-calls)                 | Each peer makes its own Cloudflare calls                  | Current               |
| [D26](#d26-peers-come-and-go-with-media)                             | Peers come and go with media                              | Current               |
| [D27](#d27-no-startup-check-for-outbound-udp)                        | No startup check for outbound UDP                         | Current               |
| [D28](#d28-host-candidates-only-with-workarounds-for-cloudflare)     | Host candidates only, with workarounds for Cloudflare     | Current               |
| [D29](#d29-libsrtp-comes-from-the-system)                            | libsrtp comes from the system                             | Current, open question |
| [D30](#d30-crashed-inlets-and-outlets-back-off)                      | Crashed inlets and outlets back off                       | Current               |
| [D31](#d31-publications-are-a-map-keyed-by-source)                   | Publications are a map keyed by source                    | Current               |
| [D32](#d32-publishing-after-joining-is-server-paced)                 | Publishing after joining is server-paced                  | Current               |
| [D33](#d33-unpublish-closes-pulls-first)                             | Unpublish closes pulls first                              | Current               |
| [D34](#d34-mute-is-a-flag-and-not-an-unpublish)                      | Mute is a flag and not an unpublish                       | Current               |
| [D35](#d35-remote-video-gets-no-element)                             | Remote video gets no element                              | Current               |
| [D36](#d36-the-swift-client-is-a-port-of-the-browser-client)         | The Swift client is a port of the browser client          | Current               |
| [D37](#d37-agents-are-a-package-in-this-repository-copied-from-subvocal) | Agents are a package in this repository, copied from Subvocal | Current           |
| [D38](#d38-a-worker-can-speak-at-another-rate-than-it-hears)         | A worker can speak at another rate than it hears          | Current               |
| [D39](#d39-an-agent-runs-a-front-end-per-speaker)                    | An agent runs a front end per speaker                     | Current               |
| [D40](#d40-a-decision-model-hears-each-turn-and-the-agent-may-wait-for-the-floor) | A decision model hears each turn, and the agent may wait for the floor | Current |
| [D42](#d42-clients-send-their-offer-at-the-first-ice-candidate) | Clients send their offer at the first ICE candidate | Current |

## Removed code

Names that appear in old commits and in superseded entries below, and no
longer exist:

| Name                                             | Was                                                                 | Removed by |
| ------------------------------------------------ | ------------------------------------------------------------------- | ---------- |
| `Octoroom.Plug`                                  | The WebSocket endpoint Cloudflare dialed for each adapter.          | D24        |
| `Octoroom.Adapter`, `Octoroom.Adapter.Socket`    | Adapter bookkeeping and the socket handler for one adapter.         | D24        |
| `Octoroom.Cloudflare.Packet`                     | Hand-rolled protobuf codec for the adapters' PCM `Packet`.          | D24        |
| Adapter calls in `Octoroom.Cloudflare`           | `adapters/websocket/new` and `close`.                               | D24        |
| `config :octoroom, public_ws_url:`               | The public `wss://` URL Cloudflare dialed.                          | D24        |
| The store's `:adapters` table                    | Adapter ids recorded so a later run could close them.               | D24        |
| The janitor's adapter sweep                      | Closed adapters whose room wasn't running.                          | D24        |
| `plug`, `websock_adapter` dependencies           | For `Octoroom.Plug`.                                                | D24        |
| Telemetry `[:octoroom, :adapter, :create]`       | Became `[:octoroom, :peer, :connect]`.                              | D24        |
| A participant's `mic` field in the room server   | `:none \| :publishing \| :pending \| :live`, one track per participant. | D31    |
| The room server as the supervisor's first child  | The process order of milestone 3.                                   | D20        |

## Decisions

### The draft

#### D1. Cloudflare Realtime SFU is the only media plane

**Status:** Current.

**Decision.** Cloudflare Realtime SFU carries all media. It has only
sessions and tracks, and no rooms, roles or policy, so every decision stays
in the app's processes. Octoroom doesn't run or self-host an SFU.

**Consequences.** Clients and workers each open their own connection to
Cloudflare, so the app needs no media endpoint, no inbound ports and no TURN
server. Congestion control happens inside the SFU; Octoroom gets whatever
Cloudflare does. Cloudflare has no SIP, so phone callers need a bridge (see
[roadmap.md](roadmap.md#telephony)).

#### D2. Routing is a pure policy and a reconciler

**Status:** Current.

**Context.** With LiveKit, custom routing is an event handler per kind of
change (joined, left, role changed), each calling subscription and
permission APIs in the right order. With RealtimeKit's role presets, routing
such as "only the agent hears the coach" can't be expressed.

**Decision.** The room module answers two questions as pure functions of
room state: `workers/1` (who should be running) and `subscriptions/2` (what
should this listener hear). A pure reconciler diffs that against the actual
state and emits operations, as LiveView diffs a render.

**Consequences.** A room module has no event handling. Joins, leaves,
reconnects and metadata changes all re-run the policy. The policy and the
reconciler test without Cloudflare. The callbacks must be fast, because they
run on every change.

#### D3. The room server is the single writer

**Status:** Current.

**Decision.** One process per room evaluates the policy, runs the
reconciler and owns the track directory and every client session. Cloudflare
HTTP calls run in tasks and report back as messages. Each session has an
operation queue with one operation in flight, and queued pulls and closes
are merged into one call. The channel never calls Cloudflare.

**Why.** Cloudflare allows one offer/answer exchange per session at a time,
and a pull can take ~8 s. A single writer makes ordering unambiguous; tasks
keep slow calls from blocking joins. Keeping Cloudflare away from the
channel is what makes routing server-authoritative.

**Consequences.** A crash in the room server takes the room's in-memory
state with it, which D17 recovers. The room server has grown to hold the
client-session queue as well; see
[handoff-room-hardening.md](handoff-room-hardening.md) for known weak spots.

#### D4. One Cloudflare session per browser

**Status:** Current, with an open question.

**Decision.** Each client has one session: its published tracks are pushed
into it, and every subscription is pulled into it.

**Consequences.** Every new subscription renegotiates the whole connection.
Separate publish and subscribe sessions would make subscription churn
cheaper and isolate the mic. Renegotiation time in a 10-person room hasn't
been measured; see [roadmap.md](roadmap.md#open-questions).

#### D5. Octoroom ships no AI

**Status:** Current. Its plan for an adapter inside Subvocal is superseded
by [D37](#d37-agents-are-a-package-in-this-repository-copied-from-subvocal):
agents live in a separate package in this repository.

**Decision.** Octoroom has no speech-to-text, LLM or text-to-speech code and
depends on no voice-agent library. AI participants implement
`Octoroom.Worker` and live outside this repository. The first integration
planned is an adapter in Subvocal that turns an agent or a one-way pipeline
(STT → translate → TTS) into a worker.

**Consequences.** The worker contract has to give AI workers what they need
without naming AI: real-time pacing, `flush` for barge-in, per-input streams
labelled by participant, and `emit` for captions.

#### D6. Gain is applied in the listener's client

**Status:** Current. The mechanism changed while building milestones 1–2.

**Decision.** `gain/2` on a subscription is applied in the listener's
client. Cloudflare forwards each track unchanged.

**History.** The draft planned a Web Audio `GainNode` per remote track. The
code uses each remote track's `<audio>` element `volume` (0–1) instead. It
is equivalent for this range, and it avoids Chrome's need to attach a WebRTC
stream to a media element before Web Audio can read it.

**Consequences.** A gain change is a channel message with no Cloudflare call
and no renegotiation. A modified client can ignore gain, so gain isn't an
access control: a listener that shouldn't hear a track must not be
subscribed to it.

### Milestones 1–2: browser-to-browser rooms

Checked against real Cloudflare: [E1](#e1-milestones-12-against-real-cloudflare).

#### D7. Closing a subscription is client-offered

**Status:** Current.

**Context.** The draft had the server close pulls on its own. Cloudflare's
`tracks/close` takes the client's offer, made after `transceiver.stop()`.

**Decision.** The server sends `close {mids, op_id}`, the client stops the
transceivers and offers, and the server relays Cloudflare's answer. The
server still decides what is closed. A client that doesn't answer any
signaling request within 15 s is removed from the room.

**Why the timeout.** Otherwise Cloudflare and the client disagree about the
session indefinitely, and that session's queue is stuck.

#### D8. A track is live when its publisher reports connected

**Status:** Current.

**Context.** Pulling a track with no packets fails after ~8 s with
`empty_track_error`. The room needs to know when a client's track has
packets.

**Decision.** The client sends `connected` when its peer connection is up,
and its published tracks then count as `:live`. A pull that still hits
`empty_track_error` is retried with backoff (0.5 s, 1 s, 2 s, ...) and given
up after five tries until the track is published again. Pull results are
per track: a batched pull can partly fail, the offer covers the tracks
Cloudflare added, and the failed ones are retried.

**Consequences.** A client that lies only delays others hearing it.

**Later.** A pushed track that has never sent a packet is forgotten:
after 60 s, pulls of it fail with `not_found_track_error` even once it is
sending, so a meet agent that first spoke a minute in was never heard. One
packet once the connection is up keeps it pullable through 60 s of
silence (checked against real Cloudflare), so an outlet sends a frame of
silence as soon as it has its sink, and goes live then.

#### D9. Events go through a Registry

**Status:** Current. The draft said Phoenix PubSub.

**Decision.** `Octoroom.subscribe/1` registers in a duplicate-key `Registry`
(`Octoroom.Events`), and events are dispatched to it.

**Why.** The notes from the time say only "for now". A likely reason, not
recorded: it needs no dependency and no PubSub server name in config, and
v1 is single-node.

**Consequences.** Subscribers must be on the room's node. Beyond the
draft's joined and left, the room also sends `{:published, participant}` and
`{:subscriptions, participant_id, track_names}`, and `Octoroom.Room.state/1`
returns who hears what, which the demo renders. Speaking events from the
draft were never built.

### Milestone 3: workers

Checked against real Cloudflare: [E2](#e2-milestone-3-against-real-cloudflare).

#### D10. Workers connect through WebSocket adapters

**Status:** Superseded by [D24](#d24-workers-move-to-webrtc-peers). The code
is gone.

**Decision.** Cloudflare's WebSocket adapters connected workers. Cloudflare
converted each track to and from PCM and dialed a WebSocket on the app
(`Octoroom.Plug`, at `public_ws_url`). An egress adapter per worker input
delivered PCM frames; an ingest adapter per output took them. The developer
wrote no WebRTC, and neither did Octoroom.

**What was built on it.**

- Inlets owned their egress adapter's socket; outlets owned an ingest
  adapter. Each ingest adapter had its own Cloudflare session, with track
  names `"out-" <> base64url(name)` (the naming survived into D24).
- Adapters were created in one batched call per reconcile, after the owning
  outlet or inlet had registered its id, because Cloudflare may dial before
  the HTTP response returns. An adapter whose owner stopped in the meantime
  was closed at once.
- Without `public_ws_url`, workers still ran, but no adapters were created
  and the room logged an error once.

**What it taught** (all observed 2026-11-17):

- **Cloudflare dials the endpoint while creating an adapter.** If it can't
  connect, `POST /adapters/websocket/new` answers 503 `internal_error` for
  each track when the host is unreachable, and 503
  `websocket_handshake_failed` when it answers without upgrading. An
  unreachable `public_ws_url` therefore looked like a Cloudflare outage.
  `Octoroom.Plug` logged every request it refused, since these otherwise
  left no trace on the server.
- Closing adapters takes at most 4 per request.
- Closing an adapter id answers 200 whether or not it exists, so there is no
  way to tell whether a dead adapter is still billed ([E3](#e3-recovery-spike)).
- After the app's side drops, Cloudflare redials an adapter every 1–3 s for
  ~14 s, then stops.
- Egress delivered ~0.56% more audio than real time (see D16).
- `cloudflared` quick tunnels apply `~/.cloudflared/config.yml`'s ingress
  rules when that file exists, which can answer every request with 404;
  `--config /dev/null` avoids it.

The costs that led to replacing it are in D24.

#### D11. Worker media lives apart from the worker

**Status:** Current.

**Decision.** A worker's outlets and inlets are processes under the room's
media supervisor, not under the worker. An inlet forwards frames to its
worker by registered name.

**Why.** An outlet holds its track's live status and paces audio. If it
died with the worker, a worker crash would unpublish the track and every
listener would renegotiate. The draft had egress recreated when a worker
crashed; making inlets processes that address the worker by name avoids
that too.

**Consequences.** A worker crash is a gap in audio, with 0 renegotiations
(measured in [E2](#e2-milestone-3-against-real-cloudflare) and
[E5](#e5-milestone-4-against-real-cloudflare)). Under D24 the worker's peer
joined the inlets and outlets under the media supervisor.

#### D12. The room server restarts crashed workers

**Status:** Current.

**Decision.** Workers are temporary children of the room's workers
supervisor. The room server monitors them, and a crash becomes a
`{:worker, id}` failure with the same backoff as pulls (0.5 s, 1 s, ...,
given up after five). A worker that ran 30 s before crashing starts its
backoff afresh. `{:worker_down, id, reason}` goes to the room's subscribers.

**Why not a supervisor restart strategy.** Not recorded at the time. A
likely reason: the reconciler already decides which workers should exist,
and a supervisor that restarted them too would race with it.

#### D13. Per-room supervisor with the room server first

**Status:** Superseded by [D20](#d20-the-room-server-is-the-last-child). The
supervisor remains; the order changed.

**Decision.** Milestones 1–2 had `Octoroom.Room.Server` directly under
`Octoroom.RoomSupervisor`. Milestone 3 added `Octoroom.Room.Supervisor`
(`rest_for_one`): the room server first, then a media supervisor, then a
workers supervisor. The room server was a `significant` child, so when it
stopped the room shut down, and it trapped exits so its `terminate/2` could
close every adapter the room still held.

**What went wrong.** On shutdown, children stop in reverse order, so the
media supervisor stopped before the room server. The server then saw each
adapter's owner die, closed each adapter in a task, and shutdown killed the
tasks. D20 reversed the order.

#### D14. Workers are reconciled by a second pure diff

**Status:** Current.

**Decision.** `Reconciler.diff_workers/2` sits next to `diff/2`. It produces
`stop_inlet`, `stop_outlet`, `stop_worker`,
`start_worker`/`restart_worker`/`update_worker`, `start_outlet` and
`start_inlet`, in that order. Worker specs are reconciled first on every
reconcile, so `room.workers` is current when `subscriptions/2` runs. Joining
reconciles too, so a participant's workers start before its mic is live.

**History.** The draft had one list of operations with `update_worker_io`.
Splitting inlets and outlets into their own operations followed from D11.

#### D15. Outlets pace to real time

**Status:** Current.

**Context.** Cloudflare forwards packets as they arrive, so audio sent ahead
of real time would still play after a barge-in.

**Decision.** An outlet sends one 20 ms frame per 20 ms tick and nothing
when its queue is empty; `flush` empties the queue. Audio that comes due
before the track can be sent is dropped rather than held, as a live stream
would be. The clock stops when the queue runs dry and restarts on the next
`play`. A lag over 100 ms restarts the clock rather than sending a burst.

**Consequences.** After a flush, at most one frame plus the network is
already on its way. A stalled node loses the stalled time instead of
bursting: a busy machine showed this as queue growth
([E5](#e5-milestone-4-against-real-cloudflare)). A producer that makes
exactly as much audio as it plays, with no lead, underruns at startup while
timers settle.

#### D16. Inlets are held to real time

**Status:** Current. Commit `ec38599`.

**Context.** In milestone 3 the recorder wrote 60.41 s of audio in 60.08 s
of wall time: egress delivered ~0.56% more audio than real time. A worker
that plays its input back built latency without bound, about 20 s per hour.

**Decision.** Each inlet has a token bucket: 20 ms of audio per 20 ms,
holding up to 300 ms for bursts. Frames that find it empty are dropped, and
`Room.state/1` reports the count per input.

**Evidence.** Re-measured the same way: the recording ran +0.02% (120.18 s
in 120.15 s), the echo's queue stayed at 260 ms for over a minute, and
inlets dropped 20 of ~3,470 frames (0.58%). After D24 the surplus was still
there (~0.45–0.59%), so it wasn't the adapters'; the browser's sending side
is the likely source ([E5](#e5-milestone-4-against-real-cloudflare)).

**Consequences.** Dropping is blunt: about one 20 ms frame every 3.6 s,
wherever it falls. Dropping during silence, or resampling, would be smoother
if it turns out to be audible.

### Robustness (milestone 5)

Built ahead of milestone 4, so it ran on the WebSocket adapters. What was
adapter-specific went with them (D19). Everything else carried over to
WebRTC workers unchanged. Checked against real Cloudflare:
[E3](#e3-recovery-spike) and [E4](#e4-restarting-the-node-mid-call-on-adapters).

#### D17. Recover by adopting sessions through resume tokens

**Status:** Current.

**Context.** A deploy, a node crash and a room server crash all lose the
room's in-memory state, but clients' media keeps flowing through Cloudflare.
The spike ([E3](#e3-recovery-spike)) showed that `GET /sessions/:id` returns
everything the room server keeps per subscription, that a client session
lives as long as its peer connection, and that a closed one reports
disconnected within a minute.

**Decision.** Adopt, don't reset. The join reply carries an encrypted
resume token with the room id, participant id, Cloudflare session id and
`join/2` metadata. A reconnecting client rejoins with it; the new room
server reads the session back and takes Cloudflare's view as the actual
state. Then it reconciles as usual. Mics are named `<participant id>/mic` at
Cloudflare so a pulled track says whose it is.

**Rejected.** Persisting participants and subscriptions in the store: it
would have to stay consistent with Cloudflare and with who is actually
connected. Resetting every session after a restart: everyone would
renegotiate and hear a gap.

**Consequences.** No browser renegotiates if the reads agree. A resume
skips `join/2`, so the token's metadata is trusted for its max age. Worker
memory stays the developer's job; workers get `ctx.resumed` to know.

#### D18. The store holds room records and no participant state

**Status:** Current. One table was removed by D24.

**Decision.** `Octoroom.Store` is a key-value behaviour (`get`, `put`,
`delete`, `all`). Each start of a room server is a run, with its id as the
room's registry value. A room record left in the store means the previous
run didn't stop cleanly, so the new one recovers: it takes the assigns,
holds ghosts for the grace period, and passes `ctx.resumed: %{gone_ms: ms}`
to workers it starts in that window (`gone_ms` from a 5 s heartbeat on the
record). The record is deleted only when the room stops because its last
participant left.

`Octoroom.Store.ETS` is the default: ETS, snapshotted to a file after a
50 ms batch and on shutdown. The snapshot is read without `:safe`, because
it holds the app's own atoms (assign keys), which don't exist yet that early
in boot.

**History.** The store first had two tables, `:rooms` and `:adapters`
(D19). Ecto and Redis implementations were planned and not built.

#### D19. Adapter records and a janitor that closes adapters

**Status:** Superseded by [D24](#d24-workers-move-to-webrtc-peers). The code
is gone.

**Context.** Adapters were billed until closed, redials couldn't be counted
on after a restart, and Cloudflare couldn't say whether an adapter id was
still open ([E3](#e3-recovery-spike)).

**Decision.** Adapters were recorded in the store before Cloudflare was
asked to create them and deleted once closed. `Octoroom.Janitor` (first
sweep 5 s after boot, then every minute) closed those whose room wasn't
running on this node with that run. Adapter calls were split into batches of
4, and a failed later batch closed the ones already created.

**What remains.** The janitor still deletes room records older than a
resume token's max age. With WebRTC workers there is nothing to close: a
worker's session ends with its peer connection.

#### D20. The room server is the last child

**Status:** Current. Supersedes
[D13](#d13-per-room-supervisor-with-the-room-server-first).

**Decision.** The per-room supervisor's order is media supervisor, workers
supervisor, room server. The room server stops first on shutdown.

**Why.** Originally so that it could close the room's adapters
synchronously in `terminate/2` while their owners were alive (see D13 for
what happened before). Adapters are gone, and the order still earns its
place: the server doesn't watch the room's media die one by one and react to
each.

**Consequences.** With `rest_for_one`, a media or workers supervisor that
dies takes the room server with it, which shuts the room down; clients then
resume into a new run. The room server isn't restarted by its supervisor.

#### D21. A dropped connection is not a leave

**Status:** Current.

**Decision.** A channel that exits with any `{:shutdown, _}` except
`{:shutdown, :left}`, or with `:shutdown`, is a disconnect: Phoenix uses
`{:shutdown, :closed}` for a closed transport and `{:shutdown, :restart}`
when draining sockets at shutdown. The participant stays for a grace
period, and a signaling request it missed is sent again when it resumes.
Closing a tab would look the same, so the JS client leaves on `pagehide`.
When the room server crashes while the channel stays up, the channel
resumes on its own from the resume data it keeps.

**History.** The grace period was 15 s at first. In one run a background
tab took 37 s after the node was back to rejoin, because Chrome throttles
timers in hidden tabs, Phoenix's reconnect backoff included, up to once a
minute. The other participant lost that tab's mic for ~10 s. The default is
now 60 s ([E4](#e4-restarting-the-node-mid-call-on-adapters)).

#### D22. Stale worker output pulls are closed and pulled again

**Status:** Current.

**Context.** A worker output's track and session die with the node. After a
restart, listeners still hold pulls of the dead tracks.

**Decision.** An adopted pull of a worker output is marked `stale`. The
reconciler closes it and pulls the track again from its new session once
it's live. This is the normal `:pending` → `:live` path, but the stale pull
has to go first.

#### D23. Retries and giving up

**Status:** Current.

**Decision.** Two layers. The HTTP client retries 429, 502, 503 and 504 for
every call, and transport errors only for calls that are safe to repeat: 3
attempts with 200 ms doubling. Above it, the room backs off per failing
thing and, after five tries, gives up and broadcasts
`{:error, what, reason}`.

**Cloudflare facts found on the way.** `GET` on a disconnected session
answers 410, and on an unknown one 500.

**Known gap.** The draft said the reconciler tries a given-up operation
again on the next trigger. The code keeps it given up until something
clears its counter. See
[handoff-room-hardening.md](handoff-room-hardening.md).

### Milestone 4: WebRTC workers

Checked against real Cloudflare: [E5](#e5-milestone-4-against-real-cloudflare).

#### D24. Workers move to WebRTC peers

**Status:** Current. Supersedes
[D10](#d10-workers-connect-through-websocket-adapters) and
[D19](#d19-adapter-records-and-a-janitor-that-closes-adapters).

**Context.** The adapters worked ([E2](#e2-milestone-3-against-real-cloudflare)).
What they cost:

- **A public URL.** Cloudflare had to dial the app, so every deployment
  needed a reachable `wss://` endpoint, and local development needed a
  tunnel. An unreachable URL looked like a Cloudflare outage.
- **Latency.** The adapter path was ~170 ms slower than a server-side WebRTC
  peer in comparable runs of Subvocal's spike.
- **Bandwidth.** Each adapter carried 20 ms frames of 48 kHz stereo PCM in a
  protobuf `Packet`: ~1.5 Mbit/s each way, against ~32–64 kbit/s for Opus.
- **Clustering.** Cloudflare dialed a URL that any node behind a load
  balancer might answer, so a cluster would need sticky routing or media
  forwarded between nodes.
- **Audio only, in beta.**
- **Billing state.** Adapters were billed until closed and couldn't be
  queried, so the room needed a store of adapter ids and a janitor (D19).
- **Delivery quirks.** Ingest played audio as fast as it arrived, and egress
  over TCP was bursty (gaps of 18 ms at p50 and 107 ms at p99).

**Decision.** Each worker gets an `ex_webrtc` peer connection to Cloudflare
and its own session (`Octoroom.Peer`). Inlets take RTP through a jitter
buffer and Opus decode; outlets encode Opus and packetize RTP. The adapter
code was removed (see [Removed code](#removed-code)).

**What WebRTC costs instead.**

- **Outbound UDP.** Cloudflare is ICE-lite with public addresses, so the
  app's peer opens every connection and replies return through the same NAT
  mapping. A host that blocks outbound UDP (some corporate networks,
  Kubernetes with strict egress rules) can't run workers. Whether Cloudflare
  accepts ICE over TCP as a fallback is unverified.
- **A media stack in the app.** DTLS, SRTP and Opus run in the BEAM node
  through NIFs (see D29).
- **CPU.** One Opus decode per worker input and one encode per output, work
  Cloudflare used to do.

**Kept from the adapter work.** Outlet pacing and `flush` (D15), the inlet
hold (D16), and the worker contract, which didn't change. The peer
connection sits behind `Octoroom.Peer.Media`, so another transport could
plug in without the worker or the room server changing.

**Built details.**

- Inlets decode with one Opus decoder per channel count, picked per packet
  from the TOC byte: the Opus NIF refuses packets whose channel count
  differs from the decoder's, and browsers send mono. Mono is upmixed to
  room PCM. Packets go through `ExWebRTC.RTP.JitterBuffer` (50 ms) first;
  undecodable ones are counted and dropped.
- Outlets encode 20 ms Opus frames (VoIP, automatic bitrate) and send RTP
  with their own sequence numbers and timestamps. After the queue runs dry,
  the next packet's timestamp moves on by the time that passed and sets the
  marker bit. An outlet gets its sink from the peer only once the connection
  is up, so its first packet reaches Cloudflare.
- Tests use `Octoroom.Test.FakePeerMedia`: placeholder SDP, and PCM moved
  through `FakeCloudflare`, which delivers a frame pushed on a track to
  every session that pulled it.

**Result.** `examples/call` runs with no tunnel. The echo's round trip fell
by ~110–240 ms.

#### D25. Each peer makes its own Cloudflare calls

**Status:** Current. The transport plan had the room server make them.

**Decision.** `Octoroom.Peer` owns a worker's Cloudflare session: an
operation queue that batches pushes, pulls and closes, Cloudflare calls in
tasks, SDP in-process. The room server decides what to push, pull and
close, hears back as `{:peer_result, worker_id, pid, result}`, and ignores
results from a peer it has replaced. A push, renegotiation or close that
fails leaves the connection's signaling state unknown, so the peer stops and
the room starts the worker's media afresh, with backoff.

**Why.** Not recorded at the time. A likely reason: the SDP and the
session's one-exchange-at-a-time rule live with the peer connection, so the
peer can negotiate in-process without a round trip through the room server
per step.

**Consequences.** Two operation queues now exist, one in the room server for
client sessions and one in the peer. They duplicate each other.

#### D26. Peers come and go with media

**Status:** Current.

**Decision.** A worker gets a peer when its first inlet or outlet starts and
loses it when its last one stops; tracks of a peer that's stopping aren't
closed one by one. A worker that crashes keeps its peer, inlets and
outlets. A peer that stops takes its worker's inlets and outlets with it;
listeners' pulls of its outputs close, and everything comes back through the
normal reconcile. Peers trap exits so stopping one closes its peer
connection properly.

**Evidence.** Cloudflare reported an abruptly killed session disconnected
only after ~40 s. With peers trapping exits, a stopped node's worker
sessions reported disconnected within ~6 s.

#### D27. No startup check for outbound UDP

**Status:** Current. Replaces a check planned in the transport decision.

**Context.** The plan was to check at startup that the app can reach
Cloudflare over UDP and fail with a clear error if it can't.

**Decision.** No check at boot. A peer whose connection isn't up 10 s after
its first negotiation, or whose ICE fails, logs an error saying workers need
outbound UDP to Cloudflare and stops. The room retries with backoff and
gives up after five tries.

**Why.** Failing the app's boot on a network problem would take browser
calls down with it, and they don't need the server's UDP.

#### D28. Host candidates only, with workarounds for Cloudflare

**Status:** Current.

**Decision.** The peer gathers host candidates only, with no STUN, and uses
aggressive nomination. Cloudflare learns the app's public address from the
connectivity checks. Extra `ExWebRTC.PeerConnection` options come from
`config :octoroom, :webrtc, [...]`; some hosts need them, such as Fly.io's
ICE IP filter.

**Evidence.** In a spike both directions connected ~250 ms after the
answer. Regular nomination took ~12 s in Subvocal's spike.

**Cloudflare quirks handled in `Octoroom.Peer.WebRTC`.**

- Applying Cloudflare's offer as a session's first negotiation starts ICE
  checks before Cloudflare has the answer, and they fail for good. The
  offer's candidates are held back until `renegotiate` succeeds.
- Later offers repeat candidates `ex_webrtc` already has (it warns on each),
  so they're always stripped.
- Once every m-line is rejected, Cloudflare's answer has no
  `a=group:BUNDLE`, which `ex_webrtc` refuses. An empty one is put back.

#### D29. libsrtp comes from the system

**Status:** Current, with an open question.

**Context.** Users shouldn't have to install native libraries. On macOS,
libopus comes precompiled, but `ex_libsrtp`'s precompiled libsrtp links a
libcrypto Homebrew doesn't put on the default path, and fails to load.

**Decision.** Apps build against the system's libsrtp (`brew install srtp`,
or `libsrtp2-dev` on Debian/Ubuntu) with
`config :bundlex, :disable_precompiled_os_deps, apps: [:ex_libsrtp]`, as
Subvocal already does. `ex_dtls` builds against the system's OpenSSL.

**Open.** Linux (glibc and musl, x86-64 and ARM) is unchecked. A fixed
precompiled build upstream would make install a plain `mix deps.get`.

#### D30. Crashed inlets and outlets back off

**Status:** Current.

**Context.** Without backoff, an inlet crashing on every packet restarted,
and renegotiated, about every 300 ms.

**Decision.** Crashed inlets and outlets back off like failed pulls.
Failure counts for a worker's peer and outputs reset when its peer connects
or an output is pushed.

### Video (steps 1–2)

The full plan had five steps; the rest are in
[roadmap.md](roadmap.md#video). Checked with the fake Cloudflare
(`test/octoroom/video_test.exs`), against an in-page fake SFU (a second peer
connection playing the room server's side), and against real Cloudflare:
[E6](#e6-video-against-real-cloudflare).

#### D31. Publications are a map keyed by source

**Status:** Current.

**Context.** Each participant had exactly one track: the room server
hardcoded `"mic"`, and a participant's
`mic: :none | :publishing | :pending | :live` allowed a single `publish`.
That field ran through the room server, the reconciler and recovery, so it
was changed before anything shipped.

**Decision.** Following LiveKit, a participant has `media` (its session:
`:none`, `:publishing`, `:adopting`, `:pending`, `:live`) plus `tracks`:
source => `%{status: :pending | :live | :closing, mid, muted}`. Sources are
`mic`, `camera`, `screen` and `screen_audio`. Every published track is named
`"<id>/<source>"` at Cloudflare too, so adoption finds all of a
participant's sources by name. `Octoroom.Track` has a `kind`, and the
`tracks` payload carries `kind` and `source`.

**Why sources and not free-form names.** A source is easier for policy and
permissions to refer to.

**Consequences.** `Octoroom.Participant` gained `tracks`.
`default_subscriptions/2` now includes every source of every other
participant; sources nobody publishes are never in the directory, so they
cost nothing. `Room.state/1` keeps `mic` and adds `media` and `tracks`.
`join/2` metadata may carry `publish: [sources]`, like LiveKit's
`canPublishSources`.

#### D32. Publishing after joining is server-paced

**Status:** Current.

**Context.** A client can't send its own offer for a new camera whenever it
likes: the server may be waiting on that client's answer to a pull, and
each would wait on the other.

**Decision.** `publish_tracks` only asks. The request joins the session's
queue, and on its turn the server sends `push` and the client offers, as
`close` already worked. The first `publish`, which creates the session,
still carries its offer and may hold several sources.

#### D33. Unpublish closes pulls first

**Status:** Current.

**Decision.** The track leaves the directory at once, so the reconciler
closes everyone's pulls of it. The publisher's own close waits until no
participant pulls it. The client stops sending (`replaceTrack(null)`) and
stops the camera right away, so the camera light goes off before the
bookkeeping is done.

**Why.** Whether Cloudflare minds a local track closing under active pulls
is unverified, so Octoroom doesn't ask it.

#### D34. Mute is a flag and not an unpublish

**Status:** Current.

**Decision.** A muted track keeps its transceiver, and subscribers see a
`muted` flag (`{:updated, participant}`). No reconcile, no renegotiation.
Muting the camera uses `track.enabled = false`, so the browser sends black
frames and the track stays pullable. `replaceTrack(null)` would stop packets
and stall new pulls (see D8). A restarted room adopts tracks unmuted, and
the client sends its mute flags again when it resumes.

**Evidence.** With the camera paused, the subscriber kept decoding black
frames (74 in 5 s), its pull stayed healthy, and video came back at once on
resume ([E6](#e6-video-against-real-cloudflare)).

#### D35. Remote video gets no element

**Status:** Current.

**Decision.** The browser client creates no element for remote video:
`tracks()` carries a `stream` for the app's own `<video>`. Audio (mic,
screen audio, worker outputs) still plays in hidden `<audio>` elements, and
`gain/2` raises for video.

**Why.** Not recorded at the time. A likely reason: where video goes on
the page is the app's layout, and audio has none.

### Clients

#### D36. The Swift client is a port of the browser client

**Status:** Current. Commit `7871b60`.

**Decision.** The Swift client for iOS and macOS speaks the same channel
protocol as `octoroom.mjs`, so the server needs no changes and native apps
join the same rooms under the same policy. See
[swift/README.md](../swift/README.md). Checked end to end against Cloudflare
with video.

### Agents

Following [proposal-agents.md](proposal-agents.md).

#### D37. Agents are a package in this repository, copied from Subvocal

**Status:** Current. Phase 1 of the proposal.

**Decision.** `agents/` holds `octoroom_agents`, which depends on
`octoroom`. Octoroom core still has no STT, LLM or TTS code (D5). Subvocal
was an unreleased experiment and isn't developed further: its pipeline
core, processors, providers and tools are copied into `Octoroom.Agent.*`
as each phase needs them, and nothing goes back. An agent is
`Octoroom.Agent.Worker`, a worker hosting the pipeline core in its own
process, in place of Subvocal's Membrane runner.

**Phase 1 changes on the way in.** `source` (the input track) on audio,
speaking and transcription frames. `ToolExecutor` keeps only `:inline`,
since tools run next to the app. One provider each: Soniox, ReqLLM (Gemini
by default) and Inworld. `Spec` lost isolation, composites, Gemini Live and
`describe/1`; `Spec.cascaded/2` raises for audio input and Smart Turn
rather than ignoring them. `req_llm` is the released 1.30, not Subvocal's
git pin. See [Where the code came from](#where-the-code-came-from).

**Consequences.** No Membrane: the outlet paces, so the agent hands audio
over as fast as TTS makes it, and an interruption is one `flush`. A crashed
agent keeps its track (D11). The agent hears one input until phase 3's
per-speaker front end.

#### D38. A worker can speak at another rate than it hears

**Status:** Current.

**Decision.** `use Octoroom.Worker, audio: [rate: 16_000, channels: 1,
output: [rate: 24_000]]`. `output:` defaults to the input format, so
existing workers are unchanged.

**Why.** Speech-to-text takes 16 kHz and TTS produces 24 kHz. Resampling in
the agent would have cost a resampler and TTS quality, while
`Worker.Server` already converted each direction separately.

#### D39. An agent runs a front end per speaker

**Status:** Current. Part of the proposal's phase 3, built early for the
call assistant.

**Decision.** `Octoroom.Agent.Worker` holds one pipeline core per input
(`vad -> stt -> turns`) and one back end (`context` onwards), from
`Spec.cascaded_split/2`. Inputs come and go without a restart. Finished
turns go to the back end as `Transcription`s with `speaker` (from `join/2`
metadata) and `respond`. `Context` labels them `[speaker]` and keeps
`respond: false` turns in the history without replying. `respond:` is
`:always` with one input and `:addressed` with more (the agent's name, or a
follow-up from the person it last answered within 10 s). Only that person
interrupts. Nothing is mixed.

**Why not `per_source/3`.** The proposal's composite stage needs
`Pipeline.Composite` and dynamic branches. Cores per input in the host
needed neither, and the front ends run no tasks or timers, so their
messages need no routing. STT sockets now send their pid, and each STT
stage takes only its own socket's events.

**Found on the way.** A browser sends no packets while its mic is
digitally silent, and Soniox closes a stream after ~20 s without audio
(408), after which the STT stage stayed deaf. The Soniox socket now sends a
keepalive after 5 s without audio, and the STT stage reconnects with
backoff (1, 2, 5, 10 s) after an error or a dropped socket.

**Open.** One STT stream per participant for as long as they're in the
call, even when silent; VAD-gating it is the proposal's cost question.
The 10 s follow-up window catches "thanks" and remarks to others; it may
want to be shorter, or skip acknowledgements.

#### D40. A decision model hears each turn, and the agent may wait for the floor

**Status:** Current. The proposal's model gate (phase 5) and half-cascaded
pipeline (phase 6), built early for the agent lab.

**Decision.** With `gate: :decision`, each front end runs
`Processors.Decisions` (adapted from Subvocal's `VocalCues`): the turn's
audio goes to `google:gemini-decision-1` with two questions, who the
speaker is talking to (assistant, a person, the group, nobody) and whether
an assistant could answer. The call starts at the speaker's VAD stop and
the turn is held up to 1.5 s for it. The gate stays name and follow-up
first, then reads the decision: reply at an assistant probability of 0.7;
wait 2.5 s from 0.35, or for an open question at least 0.7 answerable, and
reply only if nobody starts talking in that time; otherwise listen. A
follow-up now also covers the person it's answering before that reply is
done, since Smart Turn splits "Assistant." from the question after it.

Half-cascaded (`backend: %{stt: false}`) runs `vad -> AudioTurns` (Smart
Turn) per speaker and puts a `Transcriber` in front of the back end's
context. Audio turns reach the LLM after a `[speaker]` text part; the
transcript replaces the audio in the history when it arrives.

**Changes on the way.** Front ends get their own task host, with ids tagged
by input. Front-end turn stages no longer push `Interruption`: an
interruption inside a front end killed the decision call, so the worker
turns `UserStartedSpeaking` into an interruption of the back end when the
speaker may interrupt. `STTTurns` forwards the transcript it was given (it
used to rebuild it, dropping fields like `decision`). `req_llm` is back on
Subvocal's git pin: 1.30 has `evaluate/4` but no Google decisions adapter.

**Evidence.** On synthesized speech, warm calls took 430–860 ms; the first
took 4.5 s, so the stage warms the connection when it starts. "Did you see
the game last night?" came back person 0.75 (assistant 0.06); "Assistant,
what is the capital of France?" assistant 0.81; "Does anyone know the
capital of Australia?" group 0.80, answerable 0.87, and in the lab it waited
2.5 s and answered.

**Ideas from elsewhere, not built.** pipecat's "kitchen table" demo
(jptaylor/pipecat-one-pipeline-two-characters) routes with Typesafe's Jev
on text, starts replies on a confident partial read and drops them if the
final read disagrees, weights toward whoever was addressed last, and only
lets a speaker interrupt after two words so a laugh doesn't.

#### D42. Clients send their offer at the first ICE candidate

**Status:** Current. Replaces the clients' wait for ICE gathering to
finish.

**Context.** The browser and Swift clients waited for ICE gathering to
complete, up to 2 s, before sending their offer, reading "Cloudflare takes
no trickle ICE" as "send every candidate". Join telemetry
([E8](#e8-where-a-join-spends-its-time)) showed gathering never completing:
both joins measured waited out the full 2 s, 60% of the time to connected.
Some interface's STUN request never gets an answer (an IPv6 or VPN
interface is the usual cause), so gathering never finishes.

**Decision.** The offer goes as soon as the local description has a first
candidate, or after 100 ms without one. Gathering carries on after it's
sent. This works because Cloudflare is ICE-lite: the client sends the
connectivity checks, from whatever candidates it has (later STUN and TURN
ones included), to the candidates in Cloudflare's answer, and Cloudflare
learns the client's address from those checks. Workers already rely on
this with host candidates only
([D28](#d28-host-candidates-only-with-workarounds-for-cloudflare)). The
short wait for one candidate is there because it isn't known whether
Cloudflare accepts an offer with none.

**Open.** Not yet checked against real Cloudflare: `ice_ms` should drop to
near 0 without `connect_ms` growing by the same amount. A network that
needs TURN is unchecked.

## Where the code came from

Milestone 1 ported code from Subvocal (`lib/subvocal/transport/cloudflare_sfu/`),
renamed, with its tests:

| Subvocal module                        | Became                                     | Still exists                                                              |
| -------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------- |
| `CloudflareSFU.API`                    | `Octoroom.Cloudflare.HTTP`                 | Yes. Error mapping for top-level and per-track errors.                    |
| `CloudflareSFU.Packet`                 | `Octoroom.Cloudflare.Packet`               | No (D24). Hand-rolled protobuf for three fields.                          |
| `CloudflareSFU.AdapterSocket`, `.Plug` | `Octoroom.Adapter.Socket`, `Octoroom.Plug` | No (D24). Ingest sockets needed `timeout: :infinity`.                     |
| `CloudflareSFU.Audio`                  | `Octoroom.Audio`                           | Yes, generalized to any rate and channel count a worker asks for.         |
| `CloudflareSFU` (signaling)            | Room server and reconciler                 | Yes. Single-peer logic became multi-peer; the ingest "wait for first frames" handshake became track status. |
| `subvocal.mjs` `connectCloudflare`     | `octoroom.mjs`                             | Yes. Full-SDP gathering with no trickle, plus timeouts.                   |

The peer (D24) started from Subvocal's WebRTC transport
(`lib/subvocal/transport/webrtc*`), which runs `ex_webrtc` and
`membrane_opus_plugin` with ICE options for Fly.io.

Agents phase 1 (D37) copied from Subvocal at `c12431f`, renamed
`Subvocal.*` → `Octoroom.Agent.*`, with their tests:

| Subvocal modules | Changes |
| ---------------- | ------- |
| `Frame`, `Frames` | `source` on audio, speaking and transcription frames. |
| `Processor`, `Processor.StateMachine` | None. |
| `Pipeline.Core`, `Host`, `Test` | Docs only. |
| `Pipeline.Spec` | No isolation, composites, Gemini Live or `describe/1`; `cascaded/2` builds only the STT-turns chain. |
| `Processors.VAD`, `STT`, `STTTurns` | Stamp `source`. STT is Soniox only. |
| `Processors.Context`, `LLM`, `Tools`, `TextChunker`, `TTS`, `AssistantCollector` | `Tools` drops the owner executor. |
| `Tool`, `ToolCall`, `ToolResult`, `ToolDispatcher`, `ToolAdapters.*` | None. |
| `ToolExecutor` | `:inline` only. |
| `VAD`, `VAD.Silero` and `silero_vad.onnx` | Model path under `:octoroom_agents`. |
| `ConversationEvents`, `Audio.PCM`, `Backend.Cascaded` | Default STT is Soniox. |
| `Cascaded.LLM`, `ReqLLMChat`, `AudioTurn`, `SonioxSocket`, `Inworld`, `TextToSpeech`, `TextChunker` | Dispatchers cut to the copied providers. `AudioTurn` came early because `Context` uses it. |

`Pipeline.Local` was the model for `Octoroom.Agent.Worker`.

For D40: `Processors.AudioTurns`, `Processors.Transcriber`,
`TurnDetection.SmartTurn` and its two models came over with `source` and an
`interrupt: false` option; `Processors.VocalCues` became
`Processors.Decisions`, answering who a turn is for instead of how it
sounded.

Also read before writing the reconciler: Software Mansion's archived
`membrane_rtc_engine` and `fishjam`, Elixir room engines with their own SFU,
for their room, peer and track bookkeeping.

## Evidence

Runs against real Cloudflare. Each describes the code as it was at that
step.

### E1. Milestones 1–2 against real Cloudflare

`examples/call`, two and then three browser tabs on one Mac: joining
(getUserMedia → published and connected) took ~1.1 s; every participant
heard every other with no packet loss; after a leave Cloudflare closed the
pull and reused the mid for the next one.

### E2. Milestone 3 against real Cloudflare

On WebSocket adapters (D10). `examples/call` on a Mac, reached through a
`cloudflared` quick tunnel, with the built-in browser joining with the test
tone. One run:

| Check                                   | Result                                                                                                                                                                    |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Echo goes live, only its owner hears it | Yes: pulled into the owner's session once its first frame was sent.                                                                                                       |
| Echo delay                              | 2.45–2.58 s, from beep onsets on the mic against the echo (2 s + ~500 ms). Muting left exactly two echo beeps in flight.                                                  |
| Flush                                   | No echo for 2.8 s after flushing, as expected when the 2 s held is dropped.                                                                                               |
| Pacing                                  | Metronome: 1,499 frames in 30.0 s, then 10,314 frames over ~3.4 min with the queue flat at 80 ms. Underruns: 27 in the first 20 s, then one more every couple of minutes. |
| Recorder                                | Valid 16 kHz mono WAV, 220.5 s; kept writing through every other change.                                                                                                  |
| Worker crash                            | Killed the echo worker: restarted after the 0.5 s backoff, same mids in the browser, 0 renegotiations, output stayed live (underruns +5 during the gap).                  |
| Cleanup                                 | Open adapter WebSockets through the tunnel: 4 → 2 after Echo off → 0 after leaving, and still 0 after 20 s. Cloudflare dialed each adapter once and never redialed.       |

Findings: the 0.56% egress surplus (D16), startup underruns (D15), and
Cloudflare dialing the endpoint during creation (D10).

The milestone's bar was: the echo's delay ~2 s plus the adapter round trip;
after 5 minutes a flat outlet queue and WAVs matching wall-clock time; a
killed worker restarted with its output track live and no browser
renegotiation; and adapters closed after the toggle or a leave.

### E3. Recovery spike

The three Cloudflare behaviours recovery depends on (D17), checked with
`examples/call` run as a named node (so its room state could be read over
RPC), two built-in-browser tabs sending the test tone, and a `cloudflared`
quick tunnel for the adapters.

| Question                                                   | Answer                                                                                                                                                                                                                                                                                                            |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Does `GET /sessions/:id` return enough to adopt a session? | **Yes.** Each track has `location` (`local` for a push, `remote` for a pull), `trackName`, `mid` and `status` (`active`/`inactive`); a pull also has the source `sessionId`. That's everything the room server keeps per subscription.                                                                            |
| How long does a browser session survive with no API calls? | **As long as its peer connection.** After the node was stopped, a session was still `active` 11 minutes later with no API calls, and the browser kept sending audio the whole time. Another participant's two browsers kept hearing each other until one of them left. A pull whose source left turns `inactive`. |
| What happens to a session whose peer connection closed?    | `GET` answers `session_error`, "Session appears to be disconnected", within a minute. Recovery can treat that as "this participant is gone".                                                                                                                                                                      |
| When an adapter's WebSocket drops, does Cloudflare redial? | **Briefly.** After `kill -9` of the node, Cloudflare redialed both adapters (an echo's ingest and egress) every 1–3 s for ~14 s, then stopped. The ingest adapter's session answered `session_error` (disconnected) at once, so its output track is dead to listeners.                                            |
| Can we tell whether a dead adapter is still billed?        | **No.** `POST /adapters/websocket/close` answers 200 with the ids echoed back for adapters already dropped _and_ for an id that never existed.                                                                                                                                                                    |

Consequences:

- **Adopt sessions from `GET`** (D17). Resume tokens plus session read-back
  are enough.
- **Don't count on redials.** A restart that's back within ~14 s could catch
  them, but a deploy usually isn't. This was the case for closing every
  previous run's adapter ids unconditionally (D19). With WebRTC workers it
  no longer matters.
- **A worker output's track and session die with the node** (D22).

### E4. Restarting the node mid-call, on adapters

Two built-in-browser tabs in `examples/call` (one playing recorded speech as
its mic, one the test tone) with an echo, the metronome and captions on:

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

- **Background tabs reconnect late**, which moved the grace period from 15 s
  to 60 s (D21).
- **Cloudflare redials a dead adapter for ~14 s**, as the spike found: a
  node back within that window saw the previous run's egress adapters dial
  `Octoroom.Plug`, which refused them, and recovery closed them.

The demo gained Phoenix Presence (who has the room open and who's in the
call) and a captioner worker that streams each mic to Soniox and `emit`s
captions. Presence updates on every load, since after a restart the page can
come back before its participant does.

### E5. Milestone 4 against real Cloudflare

On WebRTC peers (D24). `examples/call` on a Mac with **no tunnel** (only
Cloudflare credentials), one built-in-browser tab sending the test tone,
checked the same way as milestone 3:

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
  isn't the adapters'. The node's monotonic clock, OS clocks and system time
  agreed to 50 µs over 20 s, so it isn't the BEAM's clock either; the
  browser's sending side is the likely source. The hold keeps recordings
  exact.
- **CPU contention shows up as queue growth.** An earlier 5-minute window,
  during which the test suite ran eight times on the same machine, had the
  metronome's queue grow 140 → 1,060 ms and the recording run 0.33% short:
  stalls longer than 100 ms restart an outlet's clock instead of bursting,
  and lose that time. On an idle machine both were exact. A busy production
  node would see the same, so outlet stalls are worth a telemetry event.

### E6. Video against real Cloudflare

Two tabs of `examples/call` in one Chromium, with test patterns (640×360 at
15 fps):

- Joining with mic and camera in one publish: each tab decodes the other's
  camera at 640 px within a few seconds.
- **Pause** (`track.enabled = false`): the subscriber kept decoding black
  frames (74 in 5 s), its pull stayed healthy, and video came back at once
  on resume. This answered the plan's open question of whether a pull stays
  healthy when its track goes quiet after it went live (D34).
- **Camera off, then on again mid-call:** the subscriber's pull closed, then
  the new push was pulled and decoded at ~15 fps, with no
  `empty_track_error` or retry in the log.
- **Screen share** (a 1280×720 canvas through `publish({screen: track})`)
  arrived at 1280 px. `getDisplayMedia` itself wasn't exercised.
- **Receive video off/on** (a `subscriptions/2` change): the listener went
  down to the mic alone, and back to camera and screen.
- **Restart:** the peer connections that failed after a node kill in this
  run were the test's fault, not Octoroom's: `lsof -ti tcp:4300 | xargs kill`
  also killed the browser's network service, which carries WebRTC's UDP.
  Restart checks must kill the BEAM by its pid (or
  `lsof -ti tcp:4300 -sTCP:LISTEN`); killed that way, media keeps flowing.
  A restart with video publications wasn't repeated.
- Still open: how many video pulls one browser session handles before
  simulcast is needed.

### E7. Agents phase 1 against real providers, server side

`agents/bench/turn_latency.exs`: a question synthesized by Inworld, fed to
`Octoroom.Agent.Worker` in 20 ms frames at real time, with Soniox
(`stt-rt-v5`), Gemini (`gemini-3.5-flash`, minimal reasoning, streaming)
and Inworld (`inworld-tts-2`, 24 kHz). Times are ms from the end of speech
(the VAD's stop minus its 300 ms of silence), on a Mac:

| Question                            | Transcript | First LLM text | First audio to the outlet |
| ----------------------------------- | ---------- | -------------- | ------------------------- |
| What is the capital of France?      | 552        | 3,360          | 3,877                     |
| How many legs does a spider have?   | 1,817      | 4,805          | 5,328                     |
| Name a primary colour.              | 790        | 4,310          | 4,536                     |
| What is two plus two?               | 637        | 5,561          | 6,077                     |

Findings:

- **The LLM dominates**: 2.8–4.9 s from the final transcript to Gemini's
  first text. TTS adds 0.2–0.5 s and STT endpointing 0.5–1.8 s. The room
  path isn't in these numbers; the browser measurement in `examples/call`
  adds it.
- **A pause mid-question splits the turn.** "What is the capital of
  France? Answer in one word." became two turns: the second interrupted
  the first reply. Phase 3's turn rules, or Smart Turn, are where that
  belongs.

### E8. Where a join spends its time

Two joins of `examples/meet` (a browser and two agents, on a Mac), with
the join telemetry and `Octoroom.Telemetry.attach_default_logger/1`.
Times in ms:

| Join   | Connected | Channel | getUserMedia | ICE gathering   | Publish | Connect | Agent output live | Hears someone |
| ------ | --------- | ------- | ------------ | --------------- | ------- | ------- | ----------------- | ------------- |
| First  | 3,486     | –       | –            | 2,012 (timeout) | 413     | 627     | 16,769            | 17,672        |
| Second | 3,259     | 16      | 378          | 2,007 (timeout) | 387     | 466     | 23,907            | 24,141        |

The first join republished after a resume, so its client didn't time the
channel join or getUserMedia.

Findings:

- **ICE gathering never completed**; the 2 s timeout ended it each time
  (fixed by [D42](#d42-clients-send-their-offer-at-the-first-ice-candidate)).
- **Hearing someone waits for an agent's first reply.** With only agents
  in the room, nothing can be pulled until an agent speaks, because a
  worker's output is `:pending` until its first packet. The first reply
  then also waits for its pull and renegotiation. The second join's
  reply was late because a TTS chunk timed out (17.8 s to audio).
- **A quiet output can't be pulled.** One agent's output went live 57 s
  in, after a short reply. The listener's pull failed five times with
  `not_found_track_error` while the agent was quiet, and the room gave up.
