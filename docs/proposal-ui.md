# Proposal: Octoroom UI

Status: **proposal; nothing is built.** Written 2026-11-18. Module, component
and hook names (`Octoroom.UI`, `<.call_stage>`, `OctoStage`) are proposals.
For what exists today, read [architecture.md](architecture.md).

## Summary

A small package, `octoroom_ui`, that gives every Octoroom demo the same look:
Phoenix function components, one plain CSS file and one JS module of
LiveView hooks. It has two layouts on a shared foundation:

- **Room**: a group call that looks like the calls people already use, with a
  tile grid, a spotlight for screen shares, and a bottom control bar.
- **Agent**: a 1:1 conversation with an AI participant, with a large agent
  presence, a small self-view and the transcript.

An agent in a group call uses the room layout, and the agent gets a tile that
uses the agent visualizer. Neither layout tries to adapt into the other.

The package is pulled out of real demos rather than designed up front.
`examples/call` is rebuilt on it first, then a new 1:1 agent example, and
the API counts as unstable until a third demo (interpretation, milestone 6)
uses it unchanged.

## Why

- **Demos should look alike.** Each new demo currently gets its own UI, and
  `examples/call` is a debug console more than a call.
- **Starter apps are how UI kits get adopted.** As of November 2026, npm
  downloads show `@livekit/components-react` installed alongside
  `livekit-client` at about 31%, Pipecat's `voice-ui-kit` alongside its client
  at about 40%, and Cloudflare RealtimeKit's UI at about 25%. Each of these
  grew 10–65× over the year, mostly from agent starters. Agora's kit, which
  had no starter apps behind it, is at 0.5%. Demos built on the package
  double as Octoroom's starter apps.
- **No neutral library exists.** Every Meet-style kit we found is tied to
  its vendor's SDK. The video-specific logic is small: a layout table,
  stable ordering, tile states and audio-unlock handling.

## Goals and non-goals

Goals:

- A demo looks finished with about 20 lines of HEEx and no CSS of its own.
- It works in a LiveView app with no asset build: an importmap entry, a
  `<link>` and `Plug.Static`, just as `octoroom.mjs` is served today.
- Apps that use Tailwind or daisyUI can restyle it by overriding CSS custom
  properties, with no fork.
- Light and dark themes, and it stays usable at phone width.

Non-goals for now:

- React, Vue or web-component builds.
- Swift UI components. The iOS example stays as it is.
- A hosted "prebuilt" iframe.
- Chat, reactions, hand raising, backgrounds and recording UI.

## Package shape

`ui/` is a path package next to `agents/`, depending on `octoroom` and not on
`octoroom_agents`. The agent components take plain assigns, so an app shapes
the agent's events itself. Core stays headless, matching
[D5](decisions.md#d5-octoroom-ships-no-ai) in spirit.

```
ui/
  lib/octoroom/ui.ex             # use Octoroom.UI → imports the components
  lib/octoroom/ui/room.ex        # call_stage, tile, control_bar, participant_list, prejoin
  lib/octoroom/ui/agent.ex       # agent_session, agent_presence, transcript
  lib/octoroom/ui/shared.ex      # icon_button, device_menu, pill, panel, inspector
  priv/static/octoroom-ui.css
  priv/static/octoroom-ui.mjs    # hooks; imports RoomClient from "octoroom"
```

In the app:

```elixir
plug Plug.Static, at: "/assets/octoroom-ui", from: {:octoroom_ui, "priv/static"}
```

```js
import {hooks as OctoroomUI} from "octoroom-ui"
new LiveSocket("/live", Socket, {hooks: {...OctoroomUI}})
```

## Who renders what

LiveView renders the tiles and everything around the video. JS only puts
media into slots and measures the grid.

- **The server renders tile chrome** from the room state the LiveView already
  loads: names, which sources a participant publishes, whether they're muted,
  whether they're an agent. Tiles are keyed by participant id, so LiveView
  diffs them like any list.
- **Each tile has a `phx-update="ignore"` media slot**
  (`<div data-octo-slot={id}>`). The `OctoStage` hook attaches `<video>`
  elements for `RoomClient`'s `tracks` there and removes them when tracks go
  away. Remote audio isn't attached to tiles: one hidden audio renderer plays
  every remote track, so audio keeps playing when a tile is off-screen.
- **The hook sets `--octo-cols` and `--octo-rows`** on the grid from a
  `ResizeObserver`, and CSS grid lays out the tiles.
- **Speaking state is client-side**, from `RoomClient.levels()`, which reads
  `getStats` audio levels, polled about every 150 ms. Above a threshold with a
  short hold, the hook sets `data-speaking` on the tile, and CSS draws the
  ring. Nothing goes over the channel. (A worker-computed level is still an
  open question in the [roadmap](roadmap.md#open-questions). The UI can
  switch to it later without changing the markup.)

That split keeps demos in Elixir: a demo adds an agent badge or a custom
pill in HEEx, not in JS.

## Shared foundation

- **Tokens**: `--octo-bg`, `--octo-surface`, `--octo-fg`, `--octo-muted`,
  `--octo-accent`, `--octo-danger`, `--octo-speaking`, `--octo-radius`, and a
  space scale, defined on `:root` with a dark theme under
  `prefers-color-scheme` and `[data-theme]`. The call stage is dark in both
  themes, as in other call apps.
- **`<.icon_button>`**: round, with toggled and danger variants. Icons are
  inline SVG in the component, with no icon font.
- **`<.control_bar>`**: slots for left (room name, time), centre (mic,
  camera, share, more) and right (panel toggles). `<.leave_button>` is red.
- **`<.device_menu>`**: mic, camera and speaker selection. It lists devices
  after permission is granted and follows `devicechange`.
- **`<.audio_visualizer>`**: bars driven by a level. Used by the agent
  presence, by agent tiles in a room, and by the mic check.
- **`<.transcript>`**: final and partial lines with speaker names. Used for
  captions in a room and for the conversation in the agent layout.
- **`<.panel>`**: a side panel. On a phone it becomes a bottom sheet.
- **`<.inspector>`**: a slide-out drawer for internals (routing, workers,
  queues, latency, agent decisions). Every demo puts its debugging here, so
  the main view stays a call. The current `examples/call` tables move into
  it.
- **`StartAudio` behaviour**: if the browser blocks autoplay, an "Allow
  audio" button covers the stage until the user clicks it.

## Room layout

```heex
<.call_stage id="stage" room={@room} participants={@participants} me={@me}>
  <:tile_badge :let={p}><.pill :if={p.kind == :worker}>AI</.pill></:tile_badge>
  <:controls><.icon_button ... /></:controls>
  <:panel name="people"><.participant_list participants={@participants} /></:panel>
  <:panel name="captions"><.transcript lines={@captions} /></:panel>
</.call_stage>
```

- **Grid**: LiveKit's approach, which is simple and holds up: a table of
  layouts (1×1; 2×1 landscape or 1×2 portrait; 2×2 from 560 px wide; 3×3
  from 700 px; 4×4 from 960 px). Pick the smallest layout that fits the
  participant count for the container's orientation, and drop to a smaller
  one when the container is too narrow. Tiles are 16:9 with
  `object-fit: cover`, and screen shares use `contain`.
- **Overflow**: when there are more participants than the layout's tiles, the
  last tile becomes "+N others". Pagination comes later.
- **Order**: screen shares first, then you, then everyone else in join
  order. Active speakers are pulled onto the visible tiles with the fewest
  swaps (LiveKit's "visually stable" ordering) once overflow exists. Until
  then, order doesn't change while someone is speaking.
- **Tile states**: video; camera off (initials on a colour derived from the
  participant id); video paused; connecting; muted mic icon; speaking ring;
  name at the bottom left; slots for badges.
- **Spotlight**: a screen share or a pinned tile takes the stage, and the
  others move to a strip on the right (bottom on a phone). Clicking a tile
  pins it.
- **Self-view**: mirrored, and labelled "You".
- **`<.prejoin>`**: name, camera preview, mic level, device menus and a join
  button. It replaces the current "join with camera" checkbox.

## Agent layout

```heex
<.agent_session id="session" state={@agent_state} level_from="assistant"
                transcript={@conversation} connected={@connected}>
  <:inspector><.latency_table rows={@latency} /></:inspector>
</.agent_session>
```

- **`<.agent_presence>`**: a large visualizer centred on the stage, with
  states `:connecting`, `:listening`, `:thinking` and `:speaking`, each with
  its own motion. Its level comes from the agent's audio track, client-side.
- **Self-view**: a small corner tile when the camera is on, otherwise a mic
  level next to the controls.
- **Transcript**: on the side on desktop, collapsible below on a phone.
- **Controls**: connect or end, mic, camera, and an inspector toggle.
- **Mapping events to state**: `octoroom_agents` already emits
  `{:transcription, ...}`, `{:conversation, ...}`, `{:waiting, ...}`,
  `{:latency, ...}` and `{:status, "Thinking"}`. It doesn't emit an explicit
  listening/thinking/speaking state. Phase 3 adds `{:agent, {:state, s}}`
  to the agent worker: a small change, and the honest source for the
  presence. Until then the example derives the state from those events and
  from the agent's audio level.

## Phases

Each phase ends with a demo that looks right in the browser at desktop and
phone widths, in both themes.

1. **Foundation and room layout, by rebuilding `examples/call`.**
   Scaffold `ui/` with the tokens, shared components, `OctoStage`, the grid,
   tile states, speaking ring, control bar, spotlight for screen shares and
   the start-audio overlay. `/` and `/r/:room` become the call. The current
   page's internals (publishes, workers, recorder, metronome, echo, the
   "receive video" policy toggle) move into the inspector. Nothing the
   current page can do is lost.
   *Done when* the call has 1, 2, 4 and 9 participants (test tabs with the
   existing tone and test pattern), a screen share switches to spotlight and
   back, muting and speaking show on the right tiles, and the README's
   feature list still works.
2. **Pre-join and devices.** `<.prejoin>`, `<.device_menu>`, and switching
   devices mid-call through `RoomClient`. Switching devices needs a
   `RoomClient` method (replacing a sender's track), which is a small change
   to core.
   *Done when* you can join with a chosen mic and camera, and switch both
   mid-call without anyone else seeing a renegotiation glitch.
3. **Agent layout and a 1:1 agent example.** `examples/agent`: one person
   and `Call.Assistant`-style agent with `respond: :always`. Add
   `{:agent, {:state, s}}` to the worker.
   *Done when* the presence follows the agent's state with no visible lag,
   the transcript streams, and the inspector shows per-turn latency.
4. **Agents in a room.** Agent tiles in the room layout with the agent
   visualizer and AI badge, and captions in the shared transcript. The
   `examples/call` assistant uses them.
5. **Prove it with a third demo.** The interpretation demo (milestone 6) is
   built on the package with no CSS of its own. Whatever it needs that the
   package doesn't have, the package gains. After that, document the
   package in its README and stop calling it unstable.

Phases 1 and 3 share only the foundation, so 3 can start once phase 1's
shared components exist.

## Open questions

- **Name**: `octoroom_ui` as a package, `Octoroom.UI` as a module? It
  could also live inside `octoroom` itself, since it adds no dependencies.
  A separate package keeps core's surface small and lets the UI change
  faster.
- **Overflow and pagination**: is "+N others" enough for the demos, or do
  we need pages (or a scrolling strip) before phase 5?
- **Speaking source**: client levels are spoofable, which doesn't matter for
  a ring on the screen, but would matter if the server ever acted on them.
  See the roadmap's speaking-indicators question.
- **Agent visual**: bars, an orb, or something more Octoroom-specific? It's
  the most visible part of the agent demo.
- **Tailwind users**: is overriding custom properties enough, or should
  components take a `class` attribute everywhere so daisyUI apps can add
  their own utilities?
