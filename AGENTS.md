# AGENTS.md - Octoroom Development Guide

## Project Overview

Octoroom is an Elixir/Phoenix monorepo for programmable voice, video, and AI
agent rooms backed by Cloudflare Realtime SFU. Cloudflare carries WebRTC media
while the host Phoenix app owns room state, auth, routing policies, and
server-side workers.

The repository ships two lockstep-versioned Hex packages plus browser and
native Apple clients:

- `octoroom` (root) — room server, policy reconciler, Cloudflare Realtime SFU
  client, localhost dev SFU (`Octoroom.Cloudflare.Local`), server-side WebRTC
  workers, and the zero-npm browser client (`priv/static/octoroom.mjs`).
- `octoroom_agents` (`agents/`) — voice and vision AI participants (cascaded
  `VAD -> STT -> LLM -> TTS` pipelines, local ONNX VAD/turn-detection/TTS,
  Gemini Live, OpenAI Live, and `priv/static/octoroom_agents.mjs`).
- `swift/` — native iOS 17+ and macOS 14+ SwiftPM SDK (`OctoroomCore`,
  `Octoroom`, `OctoroomAgents`).
- `examples/` — standalone Phoenix and iOS apps (`call`, `agent`, `meet`,
  `vision`, `ios`).

## Common Commands

Run Elixir commands from the repo root for `octoroom` and from `agents/` for
`octoroom_agents`.

- `mix quality` (or `mix q`) — format check, `compile --warnings-as-errors`,
  `credo --only warning,consistency`, `test` (and `test.js` at root)
- `bin/test` — run Elixir, agents, browser JS (Node 22+), and Swift suites
- `bin/test swift js` — run a subset of suites
- `mix docs` — build ExDoc output in `doc/` (run in root and `agents/`)
- `bin/check-docs` — verify lockstep version, Hex dep safety, generated docs,
  and links across both packages
- `mix hex.audit` — audit locked dependencies for security advisories

When developing unreleased `octoroom` changes locally while working in
`agents/`, set `OCTOROOM_LOCAL=1` so `agents/mix.exs` resolves `:octoroom`
against `..` instead of Hex:

```sh
(cd agents && OCTOROOM_LOCAL=1 mix deps.get && OCTOROOM_LOCAL=1 mix quality)
```

## Testing

- Elixir tests live under `test/` (root) and `agents/test/`, using fake
  Cloudflare and fake speech/LLM providers with zero network access.
- Browser JS tests live under `test/js/*.test.mjs`.
- Swift tests live under `swift/Tests/`.
- Add tests for every change to public behavior.

## Documentation

- `README.md` (root) and `agents/README.md` are the HexDocs landing pages.
  Link to repository files and examples using full GitHub URLs so links work on
  both GitHub and HexDocs.
- `docs/` holds internal development and operational guides (such as
  `docs/releasing.md`) and is not packaged into Hex tarballs. Do not link to
  `docs/` from packaged READMEs or `@moduledoc`s.

## Release Hygiene

- `octoroom` and `octoroom_agents` are released in lockstep under the same
  `@version` and a single `vX.Y.Z` Git tag.
- Use clear, scoped commit messages (Conventional Commits recommended, e.g.
  `feat(agents): add provider:model shorthand`, `fix(local): stabilize SDP origin`).
- Always publish `octoroom` to Hex before `octoroom_agents`.
- Run `mix quality` (root and `agents/`), `mix docs` (root and `agents/`),
  `bin/check-docs`, and `mix hex.build` before publishing.
- Follow [docs/releasing.md](docs/releasing.md) for the full release checklist.
