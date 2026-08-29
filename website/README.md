# Dory website

This in-repository Vite and React project contains the canonical
`https://usedory.dev/` marketing site and its `/experience/` product tour. It
also builds Dory's operational GitHub Pages trust surface at
`https://augani.github.io/dory/`.

```sh
npm ci
npm run lint
npm run build
npm run preview
```

`npm run build` writes the static site to `../docs-build` for deployment by
`.github/workflows/pages.yml`, then packages the same output in `dist` for
OpenAI Sites. The repository-bound `.openai/hosting.json` identifies the Sites
project serving the canonical marketing domain.

GitHub Pages remains the authority for signed Sparkle update metadata,
component catalogs, and static agent and operations documentation. Changing
the marketing deployment does not move those trust endpoints used by installed
Dory builds.

Machine-readable entry points live in `public/llms.txt`, `public/llms-full.txt`, `public/agent-guide.json`, and `public/docs/`. Keep their stable, preview, experimental, and deferred labels aligned with `dory agent guide --json` and the root README.
