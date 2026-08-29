import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { sites } from '@openai/sites-vite-plugin'
import { fileURLToPath, URL } from 'node:url'

// Served from https://augani.github.io/dory/ (a project-pages subpath). CI publishes
// ../docs-build directly with GitHub Pages Actions. Relative asset URLs keep the
// build portable regardless of the path depth it's served under.
export default defineConfig({
  plugins: [react(), sites()],
  base: './',
  build: {
    outDir: '../docs-build',
    emptyOutDir: true,
    rollupOptions: {
      input: {
        main: fileURLToPath(new URL('./index.html', import.meta.url)),
        experience: fileURLToPath(new URL('./experience/index.html', import.meta.url)),
      },
    },
  },
})
