# Registry-backed `docker search` for translated backends

Date: 2026-06-25
Status: Approved (design)

## Problem

`docker search <term>` on Dory's translated backends (Apple `container`, mock) currently
returns matches from **local runtime images only** (`DockerShim.imageSearchResponse`), labelled
`"Local image <ref>"` with `star_count: 0`. Real `docker search` queries Docker Hub. This closes
that gap for translated backends while keeping Dory's local-image awareness.

The Docker backend already proxies `/images/search` verbatim to dockerd and is unaffected.

## Goal

On translated backends, return **Docker Hub results merged with the user's matching local
images** — local entries stay distinctly tagged so the user sees both — with graceful local-only
fallback when the registry is unreachable.

## Approach (chosen: A — shim owns the fetch)

The local-match logic already lives in `DockerShim`, and Docker Hub is the same target for every
translated backend, so the fetch is a single injectable collaborator used by the shim. Adding a
per-backend `searchRegistry` to `ContainerRuntime` (approach B) would duplicate identical behavior
across backends for no benefit.

## Components

- **`RegistryImageSearch`** — `protocol: Sendable` with
  `func search(term: String, limit: Int?) async throws -> [DockerImageSearchOut]`.
  Injected into `DockerShim`; tests pass a stub (no network).
- **`HubImageSearch`** — default implementation (`Sendable`). Performs
  `GET https://index.docker.io/v1/search?q=<term>&n=<limit>` via `URLSession.shared` with a ~5s
  timeout, decodes `{ results: [{ name, description, is_official, is_automated, star_count }] }`,
  maps 1:1 to `DockerImageSearchOut`. The `index.docker.io/v1/` base already appears in
  `DockerRegistry.swift`. The `com.apple.security.network.client` entitlement is already present.

## Wiring

`DockerShim` gains a stored property `let registrySearch: any RegistryImageSearch = HubImageSearch()`.
Because the property has a default, the synthesized memberwise initializer keeps every existing
`DockerShim(runtime:)` call-site working, and tests use `DockerShim(runtime:registrySearch:)`.

## Flow — `imageSearchResponse`

1. Compute local matches with the existing logic → entries tagged `description: "Local image <ref>"`.
2. If `runtime.kind != .mock`: `try registrySearch.search(term:limit:)`. Any throw / non-200 /
   decode failure → treat as empty (offline fallback). Mock stays local-only and never touches the
   network.
3. **Merge:** local matches first (so the user's own images surface), then Hub entries whose `name`
   is not already present locally. Dedup by `name`, local precedence — both visible, no duplicate rows.
4. Apply the existing `is-official` / `is-automated` / `stars` filters and `limit` to the merged list.
5. Encode as the Docker `/images/search` array.

## Error handling

Registry failure is non-fatal: the search silently falls back to local-only results (current
behavior). The endpoint never blocks indefinitely (timeout) and never returns an error because the
registry was unreachable.

## Testing (TDD, all via injected stub — no real network)

- Hub JSON maps correctly into `DockerImageSearchOut` (name/description/stars/official/automated).
- Merge: ordering (local first), dedup by name with local precedence, local tag preserved.
- Filters (`is-official=true`, `stars=3`) and `limit` apply to the merged list.
- Registry throws → result is local-only (fallback).
- `runtime.kind == .mock` → the stub's `search` is never called (records invocation).
- `HubImageSearch` URL/query construction (`q`, `n`) is built correctly from term + limit.

## Out of scope

Non-Hub registries (real `docker search` only queries the default registry), authenticated search,
and the other 🟡 parity items (volume wiring, compose merge tags, create-body flag tail, Apple
network connect/disconnect).
