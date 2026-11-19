# Octoroom roadmap

What isn't built yet, and the questions still open. Nothing in this file
describes code that exists. For how Octoroom works today, read
[architecture.md](architecture.md); for why, [decisions.md](decisions.md).

Module and function names here (`Octoroom.Phone.Plug`, `quality/2`,
`handle_video/3`) are proposals.

## Milestones left

Milestones 1–5, video steps 1–2 and the Swift client are done (see the
[timeline](decisions.md#timeline)).

6. **Interpretation demo**, on `octoroom_agents` rather than a Subvocal
   adapter (Example 2 in [architecture.md](architecture.md#example-2-live-interpretation);
   phase 2 of [proposal-agents.md](proposal-agents.md#phases)). Agents phase 1
   (a cascaded agent as a worker) is built, and measured through a room in
   [examples/agent](../examples/agent#measuring-latency): 1.6 s from the end
   of speech to the reply heard in the browser, of which about 560 ms is
   between the agent's outlet and the ear.
7. **Phone callers** (see [Telephony](#telephony)): Twilio Media Streams,
   `kind: :phone` participants backed by a bridge worker with mixing, the
   phone router, DTMF events and outbound `dial`. The demo is Example 3
   with the customer on a phone. Done when a phone and a browser hear each
   other through `subscriptions/2`, the coach stays inaudible to the
   phone, mouth-to-ear latency both ways is measured, and hanging up
   closes the bridge's peer.
8. **Later:** the rest of [Video](#video), SIP, [clustering](#distribution).

Room hardening (crash paths in the room server found in review) has its own
brief: [handoff-room-hardening.md](handoff-room-hardening.md).

## Smaller gaps

Things the first draft promised that the code doesn't do:

- **A greeting that waits for its listener.** An agent's `initial_text/1`
  starts 100 ms after the agent does, whether or not anyone is pulling its
  track yet; only the LLM's time keeps the first words from being lost
  ([examples/agent](../examples/agent#measuring-latency)). It could start
  when the first subscriber's pull is live.
- **The room path's extra 200 ms.** A reply takes about 560 ms from the
  agent's outlet to the browser's ear, against about 350 ms for a round
  trip through Cloudflare (`examples/call`'s echo). Find where the rest goes.
- **Speaking events.** No `:speaking` event exists. See the open question
  below on where levels should come from.
- **Events over Phoenix PubSub.** Events go through a local `Registry`
  ([D9](decisions.md#d9-events-go-through-a-registry)), so subscribers must
  be on the room's node.
- **Store implementations.** Only `Octoroom.Store.ETS` exists. Ecto
  (Postgres) and Redis stores, for deploys that replace the machine or for
  clusters, were planned.
- **Configurable room lifetime.** A room stops when its last participant
  leaves. See the open question below.
- **Retrying after giving up.** The draft said the reconciler tries a
  given-up operation again on the next trigger; the code keeps it given up
  until its counter clears
  ([D23](decisions.md#d23-retries-and-giving-up)).
- **Smoother inlet hold.** Dropping during silence, or resampling, instead
  of dropping whichever frame finds the bucket empty
  ([D16](decisions.md#d16-inlets-are-held-to-real-time)).
- **Telemetry for outlet stalls**
  ([E5](decisions.md#e5-milestone-4-against-real-cloudflare)).
- **A Playwright test** for two browsers in one room.
- **npm package.** The browser client is `priv/static/octoroom.mjs`;
  publishing it to npm as `octoroom` comes later.
- **A restart with video publications** against real Cloudflare wasn't
  repeated after the test's own mistake
  ([E6](decisions.md#e6-video-against-real-cloudflare)).

## Video

Built: publications per source, camera and screen publishing, mute, and
remote video in the clients (steps 1–2; see
[Publishing](architecture.md#publishing)). Workers are audio-only. What's
left, from cheapest to most expensive: bandwidth control in bigger rooms,
then workers that see or produce video.

### Bandwidth: simulcast and quality as policy

With 20 people all watching each other, each browser downloads 19 video
streams. That needs simulcast: cameras publish two or three layers (for
example quarter, half and full resolution), and each subscription chooses
one. The default would be simulcast on for cameras and off for screen
shares, which favor one sharp layer. Cloudflare's pull API has simulcast
options; check its current parameters before building on them.

Quality would be a subscription option, set by policy like gain:

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

Workers already speak WebRTC, so a worker could pull a camera track the same
way it pulls a mic. What video adds for workers is decoding, not
networking. Today `worker/3` raises for a video input.

Most AI uses of video don't need a decoded stream. Several have cheaper
options:

| Need                                           | Without decoding video on the server                                                                                                                                                                                              |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A vision agent looks at a participant's camera | That participant's browser grabs a frame, about once a second or when the participant starts speaking, and uploads a JPEG over the channel. The worker receives it in `handle_info/2`. Vision models want snapshots, not streams. |
| Recording                                      | Each browser records its own tracks with `MediaRecorder` and uploads chunks. Quality depends on the client, and a crash or early leave loses the end of that participant's recording.                                             |
| An avatar agent                                | The browser draws the avatar. The worker `emit`s mouth-shape timings or animation events alongside its audio, and no video track exists.                                                                                          |

The upload options have one cost: the client decides what it sends, which
breaks [server-authoritative routing](architecture.md#security) for that
input. That's fine for "the agent sees my camera" and wrong for "a moderator
watches everyone". The upload has to be opted into per worker input, and
the docs need to say it's client-supplied.

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

Steps 1 and 2 are done.

3. Simulcast, `quality/2` and publisher-side layer pausing.
4. Frame upload over the channel for vision workers.
5. Video inlets and outlets with `handle_video/3`, when a use case can't
   trust the client.

## Telephony

Phone callers in a room, e.g. Example 3 with the customer on a phone
instead of a browser.

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
It brings back `plug` and `websock_adapter` as optional dependencies.

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
  (see [Worker media transport](architecture.md#worker-media-transport)),
  which is the buffering a mixer needs.
- **Pacing and barge-in.** Audio from the phone is already real time and
  goes through the outlet as usual. Audio to the phone is paced the same
  way. Whether each provider plays early audio as fast as it arrives, as
  Cloudflare does, needs checking. `flush` on the caller's output also sends
  the provider's clear message (Twilio's `clear`).
- **DTMF** becomes a room event, `{:dtmf, participant_id, digit}`. The room
  module still has no event handling: the app reacts (for example with
  `update_meta`), and the policy re-runs.
- **Call status** (`:dialing`, `:ringing`, `:active`, `:ended`) is in the
  participant's metadata, so a LiveView can show it.
- **Outbound calls.** `Octoroom.Phone.dial(room_id, number, meta)` calls the
  provider's REST API with the stream URL. The participant appears with
  status `:dialing`. A room that a call dials out from may have no browsers
  yet, which depends on the room lifetime [open question](#open-questions).
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
- **Security.** The webhook and stream endpoint check the provider's
  signature and a single-use stream token.
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
- a SIP bridge worker, whose room side is the normal worker peer, so only
  the SIP and RTP side is new.

Either one keeps `kind: :phone`, the router and the policy unchanged.

## Distribution

Octoroom is single-node today. Things that change for a cluster:

- Room lookup moves to `:pg` or Horde, so any node's channel can find the
  room server. Events move off the local `Registry`.
- The store has to be shared (Postgres or Redis).
- Media needs no routing. Worker peers connect out from the node that owns
  the room, so a load balancer never has to find the right node for media.
- Phone streams (see [Telephony](#telephony)) are the exception: the
  provider dials in, so the stream URL encodes the owning node for sticky
  routing, or the endpoint forwards frames to the owning node.

### Deploys without a worker gap

In a cluster, a node being shut down can drain: Phoenix's socket drainer
moves clients to other nodes gradually, and rooms are handed off with their
state (Horde-style). Workers would then restart on the new node before the
old one stops, and only the switch to the new worker peers would be
audible.

## Open questions

- **Session per browser vs. per direction.** One session per browser means
  every new subscription renegotiates the whole connection
  ([D4](decisions.md#d4-one-cloudflare-session-per-browser)). Separate
  publish and subscribe connections (two sessions) make subscription churn
  cheaper and isolate the mic. Measure renegotiation time in a 10-person
  room before deciding.
- **Video pulls per session.** How many video pulls does one browser session
  handle before simulcast is needed?
- **Mixing.** A listener in a room of 15 pulls 14+ tracks. A server-side
  mixer worker that produces one track per listener is possible, but costs
  an Opus decode per input and an encode per listener on the app's nodes.
  When does it pay off? Phone participants need a mix regardless (see
  [Telephony](#telephony)), so the mixer gets built there first.
- **Phone providers.** Do Twilio, Telnyx and Vonage play audio sent ahead
  of real time as it arrives, like Cloudflare does, or buffer it? That
  decides whether audio to the phone needs pacing and how much a `clear`
  has to drop.
- **Speaking indicators.** Use client-side audio levels reported over the
  channel (cheap, spoofable), or levels computed by a worker (trustworthy,
  but needs a pull and an Opus decode per participant)?
- **Room lifetime.** Should empty rooms linger beyond the recovery grace
  period, and should rooms be startable from the server with no clients,
  e.g. a scheduled event with a bot waiting?
- **Worker sessions: one per worker or one per room?** One per worker
  isolates crashes and renegotiations. One per room means fewer peer
  connections, but every worker change in the room waits in one queue.
  Octoroom has one per worker; measure peer connection cost in a room with
  20 workers.
- **Native libraries.** Linux (glibc and musl, x86-64 and ARM) is unchecked,
  and the libsrtp step on macOS is still needed
  ([D29](decisions.md#d29-libsrtp-comes-from-the-system)).
- **No outbound UDP.** Does Cloudflare accept ICE over TCP? If it does,
  that's the fallback for hosts that block UDP; if not, those hosts can't
  run workers.
- **Unpublishing under active pulls.** Does Cloudflare mind a local track
  closing while others pull it? Octoroom avoids asking
  ([D33](decisions.md#d33-unpublish-closes-pulls-first)).
- **Cloudflare API drift.** Pin the session and track fields we depend on
  in the fake, so drift shows up as one failing integration test.
- **Name collisions.** Check that `octoroom` is free on Hex and npm before
  the first release.
