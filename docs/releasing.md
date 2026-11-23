# Releasing Octoroom

`octoroom` and `octoroom_agents` are versioned and tagged in lockstep under a
single `vX.Y.Z` tag. Releases are published manually from a maintainer terminal
using Hex 2.7+ OAuth (`mix hex.user auth`).

## Versioning policy

- `@version` in `mix.exs` and `agents/mix.exs` must always match.
- `agents/mix.exs` defaults to `{:octoroom, "~> #{@version}"}` so Hex builds
  never ship a `:path` dependency.
- `examples/{agent,meet,vision}/mix.exs` keep `{:octoroom, path: "../..", override: true}`
  so local examples always compile against the monorepo checkout.
- During development of unreleased `octoroom` changes, run `agents/` commands
  with `OCTOROOM_LOCAL=1`.

## 1. Prepare the release commit

1. Bump `@version` in both `mix.exs` and `agents/mix.exs`.
2. Ensure no stale lockfile advisories remain where upstream fixes exist:
   ```sh
   mix hex.audit
   (cd agents && mix hex.audit)
   ```
3. Run the full quality checks and build docs for both packages:
   ```sh
   mix quality
   (cd agents && OCTOROOM_LOCAL=1 mix quality)
   mix docs
   (cd agents && OCTOROOM_LOCAL=1 mix docs)
   bin/check-docs
   ```
   *(Optionally run `bin/test` to include the Swift suite as well.)*
4. Dry-run the Hex tarballs and inspect the packaged file lists and sizes:
   ```sh
   mix hex.build
   rm -f octoroom-*.tar
   (cd agents && mix hex.build && rm -f octoroom_agents-*.tar)
   ```
   Verify `agents/priv/` stays well below Hex's 8 MB tarball limit.
5. Commit and push `main`.

## 2. Publish to Hex (order matters)

Ensure no stale `HEX_API_KEY` environment variable overrides your Hex OAuth
session (`unset HEX_API_KEY`). If publishing fails with
`insufficient scope for this action`, re-authorize:

```sh
mix hex.user deauth
mix hex.user auth
```

Publish **`octoroom` first**:

```sh
mix hex.publish
```

Wait until `octoroom` appears in the Hex index (`mix hex.info octoroom`), then
publish **`octoroom_agents`** against the published `octoroom` version:

```sh
cd agents
mix deps.get
mix test
mix hex.publish
```

## 3. Tag and verify

Create and push the annotated release tag so HexDocs `source_ref: "vX.Y.Z"`
links resolve on GitHub:

```sh
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin main vX.Y.Z
```

Verify both packages after publishing:

- `https://hex.pm/packages/octoroom` and `https://hexdocs.pm/octoroom`
- `https://hex.pm/packages/octoroom_agents` and `https://hexdocs.pm/octoroom_agents`
- Click a `</>` source link in both HexDocs sites to confirm it opens the right
  file at tag `vX.Y.Z` on GitHub.
