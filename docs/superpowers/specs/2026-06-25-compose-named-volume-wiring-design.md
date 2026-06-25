# Compose named-volume wiring

Date: 2026-06-25
Status: Approved (design)

## Problem

`ComposeEngine.up` creates the project's networks (`ensureProjectNetwork` →
`<project>_<net>`) but does nothing for volumes. Declared top-level `volumes:` are never created,
and a service's named-volume references are passed to the runtime verbatim, missing the
`<project>_` prefix Docker Compose applies. So `docker compose up` with named volumes does not
match Docker behavior, and `down` cannot remove them.

## Goal

Mirror the network handling for volumes: create declared named volumes on `up`, prefix service
references to them, and remove them on `down -v`.

## Design

### Helpers (parallel to `networkName` / `networkLabels` / `ensureProjectNetwork`)
- `volumeName(_ project, _ vol) -> "\(project.name)_\(vol)"`
- `volumeLabels(_ project, volume:) ->` `projectLabels` + `["com.docker.compose.volume": vol]`
- `ensureProjectVolume(name:labels:)` → `runtime.createVolume(name:driver:labels:driverOptions:)`,
  swallowing an "already exists" error (same `isAlreadyExists` style as networks) so re-`up` is idempotent.

### `up`
Before starting services, for each `name` in `project.volumes`, call
`ensureProjectVolume(name: volumeName(project, name), labels: volumeLabels(project, volume: name))`.

### `spec(for:in:)`
Replace `spec.volumes = service.volumes` with a rewrite: for each `source:target[:mode]`, if
`source` is a declared named volume (`project.volumes.contains(source)`), rewrite to
`volumeName(project, source):target[:mode]`. A ref with no `:` (anonymous, e.g. `/data`), a bind
mount (`./host:/data`, `/abs:/data`), or an undeclared source passes through unchanged. Source is
the substring before the first `:`.

### `down(removeVolumes: Bool = false)`
After removing containers and networks, when `removeVolumes` is true, remove each
`volumeName(project, vol)` (swallowing not-found). Default `false` matches `docker compose down`
(which keeps named volumes); `true` matches `down -v`. Existing callers keep the default.

## Out of scope

- `external: true` volumes — `project.volumes` is just names (no external flag) without a model
  change; all declared volumes are treated as project-managed.
- Long-form `type: volume` mounts (handled elsewhere as mounts); only short-form string volume
  references are rewritten.

## Testing (TDD — `ComposeEngineTests` mock already records `volumeCreateRequests`/`volumesRemoved`)

- `up` creates `<project>_<vol>` for each declared volume with `com.docker.compose.project` +
  `com.docker.compose.volume` labels.
- A service ref to a declared named volume is prefixed; bind mount, anonymous, and undeclared
  refs are unchanged (assert the `spec.volumes` the runtime receives).
- "already exists" on volume create is swallowed (re-`up` does not throw).
- `down(removeVolumes: true)` removes `<project>_<vol>`; `down()` (default) removes none.
