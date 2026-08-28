# Dory operational website

This Vite and React project builds Dory's GitHub Pages trust surface at
`https://augani.github.io/dory/`. It publishes the signed Sparkle feed,
component catalog, and static agent/operations documentation. The canonical
human product site is `https://usedory.dev/`; changing that domain does not
move the update or component trust endpoints used by installed Dory builds.
The marketing-site source and deployment state are maintained separately and
are intentionally excluded from this public repository.

```sh
npm ci
npm run lint
npm run build
npm run preview
```

The build is written to `../docs-build` and deployed by `.github/workflows/pages.yml`.

Machine-readable entry points live in `public/llms.txt`, `public/llms-full.txt`, `public/agent-guide.json`, and `public/docs/`. Keep their stable, preview, experimental, and deferred labels aligned with `dory agent guide --json` and the root README.
