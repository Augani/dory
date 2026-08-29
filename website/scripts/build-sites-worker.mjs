import { cp, mkdir, rm, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const output = resolve(root, 'dist')
const client = resolve(output, 'client')
const server = resolve(output, 'server')

await rm(client, { recursive: true, force: true })
await mkdir(client, { recursive: true })
await mkdir(server, { recursive: true })
await cp(resolve(root, '..', 'docs-build'), client, { recursive: true })
await writeFile(resolve(server, 'index.js'), `export default {
  async fetch(request, env) {
    if (env.ASSETS && typeof env.ASSETS.fetch === 'function') {
      return env.ASSETS.fetch(request)
    }
    return new Response('Dory site assets are unavailable.', { status: 503 })
  },
}\n`)
