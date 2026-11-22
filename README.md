# Octoroom

Programmable voice, video, and AI agent rooms for Phoenix, backed by Cloudflare
Realtime SFU.

Cloudflare carries the media; your Phoenix app owns the room. Your server needs
no public media endpoint, open inbound ports, or TURN server—each worker opens
an outbound WebRTC connection to Cloudflare. Live calls survive server restarts
and deploys without renegotiation.

Includes [`octoroom_agents`](agents/README.md) (voice and vision AI agents), a
zero-npm browser client, and a native [Swift SDK](swift/README.md) for iOS and
macOS.

## What it looks like

A room is a module with pure routing callbacks (`workers/1`, `subscriptions/2`):

```elixir
defmodule MyApp.CallRoom do
  use Octoroom.Room
  import Octoroom.Agent, only: [agent: 3]

  @impl true
  def join(%{"name" => name}, _socket), do: {:ok, %{name: name}}

  @impl true
  def workers(%{participants: []}), do: []

  def workers(room) do
    [
      agent("assistant", MyApp.Assistant,
        name: "Assistant",
        hears: Enum.map(room.participants, &mic/1),
        sees: Enum.flat_map(room.participants, &[camera(&1), screen(&1)]),
        respond: :addressed,
        args: %{workspace: room.assigns.workspace}
      )
    ]
  end

  # Defaults to default_subscriptions/2: every other participant's mic, camera,
  # and screen share, plus every worker's audio and data outputs.
end
```

An AI participant is an `Octoroom.Worker` whose pipeline can be cascaded
(`VAD → STT → LLM → TTS`, including local ONNX TTS) or speech-to-speech
(Gemini Live, OpenAI Live):

```elixir
defmodule MyApp.Assistant do
  use Octoroom.Agent

  alias Octoroom.Agent.Pipeline.Spec

  @impl true
  def instructions(ctx),
    do: "You are a voice assistant on a call for #{ctx.args.workspace}. Be brief."

  @impl true
  def tools(_ctx), do: [MyApp.Tools.set_theme()]

  @impl true
  def pipeline(_ctx) do
    Spec.default(
      stt: "soniox:stt-rt-v6",
      llm: "google:gemini-3.5-flash",
      tts: "tiny_voca:tiny-voca"
    )
    # Pass a keyword list for stage options, or use speech-to-speech:
    # Spec.gemini_live(model: "gemini-3.8-live", voice: "Puck")
    # Spec.openai_live(model: "gpt-live-1.1", voice: "marin", delegation: [model: "gpt-5.4-mini"])
  end
end
```

Tools run in the agent's process inside your Phoenix app—broadcast to LiveViews
over PubSub, query Ecto, or enforce app permissions directly.

## Why this architecture

- **Cloudflare Realtime SFU as a commodity media pipe.** Outbound UDP only—no
  SFU cluster to operate, no TURN server, no open ports. Cloudflare bills
  egress only ($0.05/GB after 1,000 GB/month free) with no per-minute SFU or
  participant fees (~27,000 hours of 1-on-1 audio-only voice agent calls fit in
  the free tier).
- **App-owned multi-party routing.** `subscriptions/2` decides who hears and
  sees whom (including per-track gain, whisper tracks, and data-only worker
  outputs). `workers/1` reconciles server-side participants as people join and
  leave; multiple AI agents can share a room with per-speaker VAD/STT front
  ends and a decision model that chooses who answers.
- **Survives restarts and deploys.** Signed resume tokens let reconnecting
  clients adopt their existing Cloudflare session with no WebRTC renegotiation.
  Workers checkpoint state with `save:`, restart with backoff on crashes, and
  keep output tracks published while restarting.
- **Accurate interruption accounting and observability.** Barge-in (`flush`)
  reports exact `dropped_ms` from the paced Opus outlet so conversation history
  keeps only what listeners actually heard. Structured `:telemetry` spans drive
  LiveDashboard waterfalls and the browser Voice Timeline.
- **Offline tests.** The Elixir, browser JS, and Swift suites run against a
  fake Cloudflare SFU and fake providers with zero network access.

## Repository layout

| Path                          | Description                                                                                                                                                                                                                                              |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`lib/`](lib)                 | Core `octoroom` package: room server, policy reconciler, Cloudflare Realtime SFU client (plus localhost-only `Octoroom.Cloudflare.Local` for dev), server-side WebRTC workers, and browser client (`priv/static/octoroom.mjs`).                          |
| [`agents/`](agents/README.md) | `octoroom_agents`: cascaded voice + vision pipelines (`Silero` VAD, `SmartTurn`, Soniox/AssemblyAI/Reson8 STT, ReqLLM, Inworld/AssemblyAI/OpenAI/local `TinyVoca` ONNX TTS), Gemini Live, OpenAI Live (WebRTC + sideband WS), and `octoroom_agents.mjs`. |
| [`swift/`](swift/README.md)   | Native iOS 17+ and macOS 14+ SwiftPM SDK (`OctoroomCore`, `Octoroom`, `OctoroomAgents`).                                                                                                                                                                 |
| [`examples/`](examples)       | Standalone Phoenix and iOS apps demonstrating each capability.                                                                                                                                                                                           |

## Try it

Building needs the system `libsrtp` library (see [Requirements](#requirements)).

1. **[`examples/call`](examples/call)** _(zero accounts or keys needed)_: LiveView group video call with echo, metronome, and recording workers. Runs against `Octoroom.Cloudflare.Local` by default on localhost, or against real Cloudflare Realtime SFU when credentials are set.
2. **[`examples/vision`](examples/vision)** _(Cloudflare + `GOOGLE_API_KEY` in Gemini Live mode)_: talk to an agent that sees your camera and shared screen, switching between Cascaded (`TinyVoca` local TTS) and Gemini Live mid-call.
3. **[`examples/agent`](examples/agent)**: 1-on-1 voice agent that times each turn end-to-end as heard in the browser, plus a deterministic scripted booking agent (`Hello.Booking`).
4. **[`examples/meet`](examples/meet)**: group video call with multiple AI assistants, decision-model routing, and the live Voice Timeline latency waterfall.
5. **[`examples/ios`](examples/ios)**: native iOS app joining the same rooms.

## How it compares

| Alternative                  | How Octoroom differs                                                                                                                                                                                                                                                             |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **LiveKit / Daily**          | Octoroom avoids hosted video/chat SaaS lock-in and per-minute SFU billing—room state, auth, and routing stay in your Phoenix app while Cloudflare carries the media. Tradeoff: you host your own app server, and SIP/server-side recording aren't built in yet.                  |
| **Pipecat / LiveKit Agents** | Octoroom is built for multi-party, multi-agent rooms inside your web app rather than spawning a separate Python worker process per 1-on-1 call. Octoroom's vision uses lightweight client-captured frames (`sees:`) for VLM context, not high-FPS server-side YOLO/CV pipelines. |
| **Membrane / Fishjam**       | Octoroom offloads SFU fan-out to Cloudflare so you write room policies and agents instead of operating media-server pipelines.                                                                                                                                                   |

## Requirements

Building `ex_webrtc` requires the system's `libsrtp`:

```sh
brew install srtp          # macOS
apt install libsrtp2-dev   # Debian / Ubuntu
```

Add this to your app's `config/config.exs` (the precompiled `ex_libsrtp` links
a `libcrypto` that isn't on the default path):

```elixir
config :bundlex, :disable_precompiled_os_deps, apps: [:ex_libsrtp]
```

In `octoroom_agents`, `Silero` VAD, `SmartTurn`, and `TinyVoca` run on ONNX
Runtime via precompiled NIFs (`onnxruntime`).

## Tests

```sh
bin/test            # Elixir, agents, the browser client (Node 22+), and the Swift client
bin/test all        # also builds the iOS example app (needs xcodegen)
bin/test swift js   # just those
```

None of the suites needs Cloudflare or the network.

## Status

Early (`0.1.0`, pre-Hex). Working today: browser and Swift rooms, server-side
routing policies, deploy/restart survival, cascaded and speech-to-speech
voice/vision agents, and local ONNX VAD/turn-detection/TTS.

Not built yet: multi-node room clustering, SIP/PSTN telephony, and server-side
recording/egress.

Building voice/video rooms or AI voice agents in production—or interested in
SIP, recording, or commercial support? Reach out at [mail@samrat.me](mailto:mail@samrat.me).
