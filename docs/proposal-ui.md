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

A third piece, the **dock**, is a call toolbar for apps that already exist:
a call that sits on top of the app's own pages and stays connected as the
user navigates, like a Slack huddle. It reuses the room's parts, not its
full-page layout. See [Dock for existing apps](#dock-for-existing-apps).

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

## Dock for existing apps

The room and agent layouts are pages. Most Phoenix apps that add calls
want the call next to their own UI instead: a team edits a document or a
pipeline sheet and talks over it, and the agent's tools change what's on
the screen ([the collaboration call](proposal-agents.md#the-four-use-cases)).
This is where Octoroom differs most from the hosted SDKs, and the dock is how
a demo shows it.

### Staying connected across pages

The dock is only useful if the call survives navigation. In LiveView, a
`live_render(@socket, Octoroom.UI.DockLive, id: "octo-dock", sticky: true)`
in the root layout is a nested LiveView that isn't remounted on
`live_navigate` between LiveViews in the same `live_session`. The hook, its
`RoomClient` and the peer connection live there and survive. A full page
load (a dead view, a different `live_session`, a reload) still tears the
call down. The client's resume token brings it back, but with a gap, so
the docs should say which navigations keep the call.

The dock LiveView takes the room id and the user from the session. The app
decides when it shows, for example in a project page's room, with no UI
when there's no call.

### Floating: when it's good and when it's bad

Floating call controls are an established pattern: Slack huddles, Meet and
Zoom's mini windows, and Discord's voice panel all do it. They become bad
UX when they:

- **cover content the user needs**, such as a fixed corner over a "Save"
  button or a table's last column;
- **can't be moved or shrunk**;
- **fight the app's layers**, appearing above modals, under sticky headers,
  or over toasts;
- **take focus or keyboard shortcuts** from the page.

The dock avoids those:

- **Collapsed by default**: a pill with participants' avatars (each with
  a speaking ring), mic toggle, a timer and leave. About 48 px tall.
- **Expanded on click**: a small strip of video tiles plus the full control
  bar, still well under a third of the viewport. Screen shares open a
  larger draggable window, or pop out with the browser's Picture-in-Picture.
- **Draggable, snapping to the four corners and bottom centre.** The
  position is remembered per user in `localStorage`.
- **Inline mode**: `<.call_dock mode={:inline}>` renders the same controls
  as a normal element, for apps that would rather put the call in a header
  or sidebar than float it. It's the same component, with no position:
  fixed.
- **Layering**: `--octo-dock-z` defaults below typical modal z-indexes,
  and the dock honours `inert` on its container, so app modals cover it.
- **No global shortcuts by default.** Optional ones (mute with a key) are
  off unless the app turns them on.
- **Mobile**: collapsed into a bottom bar above the safe area, with no
  dragging.

### Agent in the dock

An agent in the call is another avatar in the pill, with the agent
visualizer instead of a speaking ring, and its captions or replies show as
a short line above the pill. The phase-3 agent states drive it, as in the
agent layout.

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
5. **The dock, with a collaboration demo.** `<.call_dock>` as a sticky
   LiveView, floating and inline modes, and `examples/collab`: a small
   LiveView app (a shared list or sheet) with the dock, and an agent whose
   tool edits the list while everyone watches it change.
   *Done when* the call survives `live_navigate` between two pages with no
   audio gap, the dock never covers the app's modal, and an agent tool call
   updates every participant's page.
6. **Prove it with another demo.** The interpretation demo (milestone 6) is
   built on the package with no CSS of its own. Whatever it needs that the
   package doesn't have, the package gains. After that, document the
   package in its README and stop calling it unstable.

Phases 1 and 3 share only the foundation, so 3 can start once phase 1's
shared components exist. Phase 5 needs phase 1's tiles and control bar and
phase 3's agent states.

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
- **Dock across full page loads**: is a resumed call after a reload good
  enough, or should the docs push apps to keep call pages in one
  `live_session`? Two tabs of the same app are two participants today.
  Should the dock notice and offer to move the call?
- **Tailwind users**: is overriding custom properties enough, or should
  components take a `class` attribute everywhere so daisyUI apps can add
  their own utilities?
