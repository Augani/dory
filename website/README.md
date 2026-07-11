# Dory landing page

Source for [augani.github.io/dory](https://augani.github.io/dory) — React + TypeScript + Vite,
published by GitHub Pages Actions from the generated `../docs-build` artifact.

From the repository root (which is not itself an npm package):

```sh
npm --prefix website ci
npm --prefix website run dev     # local dev server with HMR
npm --prefix website run build   # typecheck and build into docs-build/
```

`npm run build` writes to `../docs-build` (gitignored). GitHub Pages uploads that
directory directly in `.github/workflows/pages.yml`; `docs/` is also ignored and kept
for local-only notes or stale build artifacts.
