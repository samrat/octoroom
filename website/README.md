# Octoroom Website & Docs

Marketing site and documentation for Octoroom, built with [Astro](https://astro.build) and [Starlight](https://starlight.astro.build).

## Commands

Run from `website/`:

```sh
npm install
npm run dev       # local dev server at http://localhost:4321
npm run build     # production static build to ./dist/
npm run preview   # preview ./dist/ locally
npm run deploy    # build and deploy static assets to Cloudflare Workers
```

## Structure

- `src/pages/index.astro` — Custom landing page (`/`)
- `src/content/docs/docs/` — Starlight documentation pages (`/docs/...`)
- `src/styles/custom.css` — Custom Starlight theme variables and overrides
- `astro.config.mjs` — Sidebar navigation, branding, and Expressive Code config

## Notes

- Because `Package.swift` sits at the repository root, keep heavy binary media (demo videos, large screenshots) on external object storage (e.g. Cloudflare R2) rather than committing them to Git.
- Module-level Elixir API docs live on HexDocs (`octoroom` and `octoroom_agents`) and are linked from the sidebar.
