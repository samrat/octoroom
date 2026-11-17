# Handoff: stop bad input from crashing a room

Written 2026-11-17 after an architecture review of Octoroom on branch
`video` (clean tree at `5acfc60`). This is a brief for whoever picks up the
fix. Nothing has been changed yet.

## The task

Make `Octoroom.Room.Server` survive two kinds of bad input that currently
crash it:

1. malformed signaling payloads from a browser client
2. room-module callbacks (`workers/1`, `subscriptions/2`, the function
   given to `update_meta/3`) that raise or return garbage

Done means: each case below has a test that fails on `5acfc60` and passes
after the change, the room server stays up in all of them, and the existing
suite (`mix test`, 74 tests, about 3 s) still passes.

## Why it matters

The room server is the single writer for a room and a `significant`,
`:temporary` child of the room's supervisor
(`lib/octoroom/room/supervisor.ex`). When it crashes, the whole room shuts
down: every worker, peer, inlet and outlet stops. Clients then resume into a
new run, which recovers as after a deploy, so listeners lose every worker
for a few seconds and workers lose their in-memory state.

That recovery is a deliberate design choice for real crashes (see
"Restarts and deploys" in `docs/architecture.md`). The problem is that one client
or one bug in app code can trigger it at will, and a raising policy
re-triggers it on every reconcile after recovery, so the room loops.

## Confirmed crash paths

All three were reproduced by running them; the room server exited each time.

| # | Trigger | Where it raises | Error |
| - | ------- | --------------- | ----- |
| 1 | client sends `publish_tracks` with `sources: [{}]` | `handle_cast({:publish_tracks, ...})`, `Enum.map(sources, &to_string/1)`, `lib/octoroom/room/server.ex:362` | `Protocol.UndefinedError` (String.Chars) |
| 2 | client sends `publish` with `mids` that isn't a map (e.g. a string) | `handle_cast({:publish, ...})`, `Map.new(mids, ...)`, `server.ex:331` | `Protocol.UndefinedError` (Enumerable) |
| 3 | `subscriptions/2` raises (e.g. `listener.meta.lang` on metadata without `:lang`) | `reconcile/1`, `server.ex:853-862` | whatever the callback raised |

Reproduction (prints the exit reason for each):

```bash
MIX_ENV=test mix run -e '
defmodule R do
  use Octoroom.Room
  def join(_, _), do: {:ok, %{}}
end
defmodule Bad do
  use Octoroom.Room
  def join(_, _), do: {:ok, %{}}
  def subscriptions(l, _room), do: [l.meta.lang]
end
Logger.configure(level: :none)
watch = fn server, label ->
  ref = Process.monitor(server)
  fn -> receive do {:DOWN, ^ref, _, _, reason} -> IO.inspect(elem(reason, 0), label: label) after 1000 -> IO.puts(label <> ": survived") end end
end
{:ok, r, s} = Octoroom.Room.join(R, "t1", %{})
w = watch.(s, "sources"); Octoroom.Room.Server.publish_tracks(s, r.participant_id, [%{}], nil); w.()
{:ok, r, s} = Octoroom.Room.join(R, "t2", %{})
w = watch.(s, "mids"); Octoroom.Room.Server.publish(s, r.participant_id, "sdp", "notamap", nil); w.()
{:ok, r, s} = Octoroom.Room.join(Bad, "t3", %{})
w = watch.(s, "policy")
:sys.replace_state(s, fn st -> put_in(st.participants[r.participant_id].media, :pending) end)
Octoroom.Room.Server.connected(s, r.participant_id); w.()
'
```

## Same class, found by reading (not run)

Cover these in the same change; they share the two root causes.

- `push_offer` with a non-map `mids`: `Map.new(mids, ...)` at `server.ex:395`.
- `workers/1` raising: called first thing in `reconcile/1` (`server.ex:854`).
- The `update_meta/3` function raising: `fun.(p.meta)` at `server.ex:267`.
  This one runs inside a `GenServer.call`, so today the caller (often a
  LiveView) crashes too.
- Callbacks returning the wrong shape. `subscriptions/2` returning anything
  but a list of `%Octoroom.Track{}` or strings fails in
  `Reconciler.normalize/1`; `workers/1` returning maps without `:id`,
  `:module`, `:inputs`, `:outputs`, `:args` fails in
  `Reconciler.diff_workers/2` or `apply_worker_op/2`. Both run in the room
  server.
- `mount/1` raising or returning something other than `{:ok, map}` fails in
  `init/1` (`server.ex:159`). That fails the join rather than a running
  room, so it's lower priority; decide whether a clear error is worth it.

The worker callbacks (`handle_audio/3` and friends) are fine: they run in
`Octoroom.Worker.Server`, and the room restarts a crashed worker with
backoff.

## Suggested approach

Two boundaries, one fix each. Treat this as a starting point and adjust if
the code suggests something better.

### Client payloads

The channel is the trust boundary:
`Octoroom.Phoenix.Channel.__handle_in__/3`
(`lib/octoroom/phoenix/channel.ex:119-169`). Only `mute`, `unpublish` and
`publish_tracks` have guards today, and `publish_tracks` checks the list but
not its elements.

- Validate shapes there: `sdp` and `op_id` are binaries, `mids` is a map of
  binary to binary, `sources` is a list of binaries, `source` is a binary.
  Reply `{:error, %{reason: "bad_payload"}}` otherwise. The existing
  catch-all clause replies `unknown_event`, which is misleading for a known
  event with a bad body.
- `Room.Server`'s functions are also called without the channel (tests use
  `Octoroom.Test.Client`, and `Octoroom.Room.join/4` is public), so the
  server shouldn't rely on the channel alone. Give the affected casts a
  cheap shape check that replies `{:error, :bad_payload}` through the usual
  `reply/3` path instead of raising.

Values that pass the shape check but are wrong (an unknown source, a stale
`op_id`, a mid that doesn't exist) are already handled: `check_sources/2`,
`with_op/6` and Cloudflare's own errors.

### Policy callbacks

Wrap every call into the room module made from the room server, catching
raises, throws and exits, and validate the returned shape. On failure, keep
the last good answer rather than acting on a bad one:

- `workers/1` fails: keep `state.worker_specs` as it is.
- `subscriptions/2` fails for one listener: leave that listener's
  subscriptions alone for this reconcile. The simplest way is to make its
  desired list equal what it currently holds, with current gains, so the
  diff produces no ops for it. Other listeners still reconcile. Note that
  `Reconciler.diff/2` closes a subscription whose track left the directory
  regardless of what's desired, which is the behaviour you want here.
- `update_meta/3` function fails: don't change the metadata, and reply
  `{:error, ...}` to the caller. This changes the function's return type
  from always `:ok` or `{:error, :no_participant}`; update its doc.

Make each failure visible, because a silently frozen policy is hard to
debug:

- `Logger.error` with the callback name, room id and formatted exception
  with stacktrace. Reconcile runs on every room change, so avoid logging
  the same failure on every pass (for example, log when the error changes).
- Broadcast `{:error, {:policy, callback}, reason}` with
  `Octoroom.broadcast/2`, matching the existing `{:error, what, reason}`
  events from `fail/3`.
- A telemetry event, added to `Octoroom.Telemetry.events/0` and its
  moduledoc.

## Tests

- Room tests live in `test/octoroom/room_test.exs`. Its `setup` starts
  `Octoroom.Test.FakeCloudflare`, and the `join/4`, `publish/2` and
  `accept_pull/2` helpers there drive a participant through
  `Octoroom.Test.Client`, which forwards everything the server sends as
  `{:client, name, message}`.
- For each case: monitor `client.server`, send the bad input, assert the
  expected error reply or event, and `refute_receive {:DOWN, ...}`. For the
  policy cases, also assert that a second, healthy participant still gets
  its subscriptions, and that workers already running stay running.
- The channel has no tests today (Phoenix is an optional dependency). If
  testing `__handle_in__/3` directly is awkward, cover the server-side
  checks and say so in your report.

## Constraints

- Don't change the reconciler's public contract or the signaling protocol
  beyond adding the error reply.
- Keep to the codebase's style: comments explain why, moduledocs describe
  current behaviour. `mix format` before finishing.
- Describe the new behaviour in `docs/architecture.md`, and add an entry to
  `docs/decisions.md` for each decision made (next free number).
- Leave committing to the user.

## Out of scope: other review findings

Recorded so they aren't rediscovered. None has been started, and all come
from reading the code rather than running it.

1. **The room server blocks on its children.** `stop_child/3`
   (`server.ex:1387`) calls `DynamicSupervisor.terminate_child/2`
   synchronously, so a worker with a slow `terminate/2` stalls the room's
   signaling for up to 5 s. `Room.state/1` calls each inlet's `stats/1`
   synchronously too.
2. **Operations can hang.** `run/4` (`server.ex:1728`) and `Peer.task/3`
   only `rescue` exceptions. If a task exits or throws, no result arrives,
   and the in-flight stages (`:pulling`, `:pushing`, `:renegotiating`,
   `:closing`) have no timer.
3. **Giving up is permanent.** After `@max_failures`, `may_retry?/3`
   (`server.ex:1060`) stays false until an unrelated event clears the
   counter. The first draft said the reconciler retries on the next
   trigger (see D23 in `docs/decisions.md`).
4. **Resume skips `join/2`.** The resume token carries the metadata
   (roles, `publish` rights) for 10 minutes; someone who left or was kicked
   can resume with it.
5. **`Room.Server` is 1,777 lines.** The browser-session operation queue
   duplicates the one in `Octoroom.Peer`; a per-participant session module
   would shrink it and make the stages unit-testable.
6. **Unbounded worker mailbox.** `Inlet.forward/2`
   (`lib/octoroom/inlet.ex:107`) sends PCM without checking whether the
   worker keeps up.
7. **Inlets ignore RTP timestamps**, so lost packets shorten the audio
   instead of becoming silence, and multi-track recordings drift apart.
8. **Test gaps.** `priv/static/octoroom.mjs` has no tests; the reconciler
   has no property tests, though the design promises them.
9. **Join race.** `call_starting/5` (`lib/octoroom/room.ex:202`) retries
   for about 40 ms while a stopping room's supervisor shuts down; a slower
   teardown fails the join.
