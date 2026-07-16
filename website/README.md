# Dory website

This Vite and React project builds the public Dory site for GitHub Pages. It serves both the human product page and static agent documentation.

```sh
npm ci
npm run lint
npm run build
npm run preview
```

The build is written to `../docs-build` and deployed by `.github/workflows/pages.yml`.

Machine-readable entry points live in `public/llms.txt`, `public/llms-full.txt`, `public/agent-guide.json`, and `public/docs/`. Keep their stable, preview, experimental, and deferred labels aligned with `dory agent guide --json` and the root README.
