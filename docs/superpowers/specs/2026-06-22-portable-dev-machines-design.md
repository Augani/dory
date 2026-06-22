# Design: Portable Dev Machines (Phase 1)

Date: 2026-06-22
Branch: feat/live-refresh-and-docker-routing
Status: Approved (pending spec review)

## Context

Dory now creates fast, reproducible Linux "machines" — systemd containers in the local
engine, one per distro/version/arch, created and managed via `MachineService` over
`any ContainerRuntime`. They are usable (shell, persistence, real IP, x86 emulation) but
**ephemeral and non-portable**: you cannot capture a machine's state, reproduce it, share it
with a teammate, or move it to another Mac.

This is Phase 1 of a larger product roadmap — "your dev machine, everywhere":

| Phase | Ships | This spec |
|---|---|---|
| **1. Portable dev machines** (local) | snapshot, clone, export/import, dev recipes, machine settings | **YES** |
| 2. S3 backup & restore | push/pull snapshots to S3, restore on any Mac | future |
| 3. Remote access (Tailscale-style) | reach a running machine from anywhere | future |
| 4. Cloud agent spins | burst machines to AWS, safe agent sandboxes | future |
| 5. iOS companion | manage machines from phone | future |

Phase 1 establishes the **snapshot primitive** that every later phase reuses: Phase 2 is
"snapshot → upload/download → restore"; Phase 3 rides the running machine. Nothing built here
is throwaway.

## Goals

- Capture a machine's full state as a portable, restorable snapshot.
- Clone a machine into an identical copy ("fork my environment", "clone the senior's machine").
- Export a machine to a single `.dorymachine` file and import it on another Mac.
- One-click "baked" dev environments (Ruby, Node.js, Java, Go, Python) with the toolchain
  pre-installed.
- Per-machine resource settings: CPU, RAM, mounted host folders, exposed ports.

## Non-goals (Phase 1)

- S3 / cloud transport (Phase 2). Export/import is local file only.
- Remote access / networking beyond the existing local engine (Phase 3).
- AI-agent isolation / credential proxy / egress firewall (Phase 4).
- Capturing *running process state* in a snapshot. A snapshot captures the filesystem
  (installed tools + files); services restart fresh on clone/restore. This is correct and
  expected for dev machines and matches how OrbStack/Docker images work.
- Live editing of a running machine's CPU/RAM without recreation (we recreate from a fresh
  auto-snapshot — see Machine settings).

## Architecture: one primitive, four features

A Dory machine is a labeled container (`dory.machine=<family>`). The **snapshot primitive** is
a commit of that container into a portable OCI image. Every Phase-1 feature is that image moved
through a different transport, so the bulk of the code is shared.

```
            machine container (dory-machine-<name>)
                        │  commit  (POST /commit)
                        ▼
   snapshot image  dory-snapshot/<machine>:<stamp>   ── labels carry identity ──┐
        │                    │                                                   │
   run new (clone)     save  │ (GET /images/get)                                 │
        ▼                    ▼                                                   │
   new machine        <name>.dorymachine  ──  load (POST /images/load)  ── importable template
```

### Snapshot identity (image labels)

Every snapshot image carries labels so it is fully self-describing (export/import need no
sidecar):

- `dory.machine` = distro family (e.g. `ubuntu`)
- `dory.machine.version`, `dory.machine.arch`, `dory.machine.boot` (`systemd`/`shell`)
- `dory.snapshot.of` = source machine name
- `dory.snapshot.created` = ISO-8601 (passed in from Swift; the engine clock is fine but we
  set it explicitly from the host)
- `dory.snapshot.note` = optional user note
- `dory.recipe` = recipe id if the machine was built from a dev recipe (e.g. `node`)

## Feature 1 — Snapshot + Clone

**Snapshot:** `POST /commit?container=dory-machine-<name>&repo=dory-snapshot/<name>&tag=<stamp>`
with a JSON body carrying `Labels`. The commit captures the machine's writable layer (installed
packages + files) into an image. `<stamp>` is a host-generated short id (no `Date.now()` in
engine; Swift supplies it).

**List snapshots:** `GET /images/json?filters={"label":["dory.snapshot.of"]}` → map to
`MachineSnapshot` (id, machine, note, created, size, distro/version/arch from labels). A
per-machine **Snapshots** sheet lists them newest-first.

**Clone / restore:** create a new machine container from a snapshot image. Reuse the existing
`MachineService.createContainer` path but with `image = snapshot.imageRef` and the machine
metadata recovered from the snapshot's labels (so the clone is tagged a proper machine).
- "Clone" = pick a snapshot (or "current state" → auto-snapshot first) → new machine with a new
  name.
- "Restore" = clone back into a machine of the same name (stop+replace the existing container
  from the snapshot, keeping the name).

## Feature 2 — Export / Import (`.dorymachine`)

**Export:** snapshot first (if exporting a live machine), then `GET /images/<tag>/get` returns
the image tar (docker-save format). Stream it to a user-chosen `<machine>.dorymachine` file via
`NSSavePanel`. The file IS an OCI image tar; its labels carry all metadata.

**Import:** `NSOpenPanel` → read the `.dorymachine` → `POST /images/load` (body = tar). Validate
it carries a `dory.machine` label (reject non-Dory tars with a clear message). The loaded image
appears as an importable template the user can clone into a running machine.

## Feature 3 — Dev recipes

A **recipe** is a distro base + a vetted dev-toolchain install layer. v1 recipes (all on the
Ubuntu 24.04 base, both arches): **Ruby, Node.js, Java, Go, Python**.

- `DevRecipe { id, display, icon, install: String }` — `install` is the RUN body appended to the
  distro Dockerfile.
- `MachineImageBuilder` gains an optional `recipe` param: when set, the built image tag becomes
  `dory-recipe/<recipeId>-<arch>` and the Dockerfile appends the recipe's `RUN` after the base
  systemd setup. Cached per (recipe, arch) like distro images.
- The New Machine picker gains a **Dev environment** control: *Plain OS* (default) or a recipe.
  Choosing a recipe sets the build to the recipe image. The machine is labeled `dory.recipe=<id>`.

Recipe install bodies (apt-based, Ubuntu) — vetted, minimal, non-interactive:
- **node**: NodeSource LTS + npm + yarn/pnpm via corepack.
- **python**: `python3 python3-pip python3-venv pipx`.
- **go**: official Go tarball to `/usr/local/go`, on PATH.
- **java**: `default-jdk maven gradle`.
- **ruby**: `ruby-full build-essential` + bundler.

(Exact commands are specified in the implementation plan; each must be `-y`/non-interactive and
clean apt lists.)

## Feature 4 — Machine settings

Per-machine resources, set at create (New Machine "Advanced" disclosure) and editable:
- **CPU** (`HostConfig.NanoCpus`), **RAM** (`HostConfig.Memory`).
- **Mounted host folders** (`HostConfig.Binds`, `host:guest`) — virtiofs into the machine, the
  OrbStack file-sharing model.
- **Exposed ports** (`HostConfig.PortBindings` + `ExposedPorts`).

`createBody` is extended to emit these. Editing CPU/RAM/mounts/ports of an existing machine
requires a container recreate; we do it safely: **auto-snapshot → remove → recreate from the
snapshot with new settings → start**, so no work is lost. Stored defaults: 4 CPU / 4 GB unless
overridden (matches current).

## UI surface

- **MachineCard**: an overflow (`•••`) menu → Snapshot, Snapshots…, Clone, Export…, Edit…,
  Delete. Keep the primary Start/Stop + Terminal buttons as-is.
- **SnapshotsSheet** (per machine): list snapshots (note, time, size) with Restore / Clone /
  Export / Delete each, and a "Take snapshot" button with an optional note.
- **NewMachineSheet**: add a **Dev environment** picker (Plain OS / recipes) and an **Advanced**
  disclosure (CPU, RAM, folders, ports). The recipe/arch/settings flow into `createMachine`.
- **Toolbar**: an "Import machine…" secondary action on the Machines section (via the existing
  `MainColumnView` secondary-button slot, like Images' "Build").
- New `AppSheet` cases: `.machineSnapshots`, `.editMachine` (or reuse a detail). Import uses a
  file panel directly (no sheet).

## New plumbing

`ContainerRuntime` (+ `DockerEngineRuntime` impl, no-ops elsewhere):
- `func commit(containerID: String, repo: String, tag: String, labels: [String: String]) async throws -> String`
- `func saveImage(reference: String) -> AsyncStream<Data>` (GET `/images/<ref>/get`)
- `func loadImage(tar: Data) async throws` (POST `/images/load`)

`MachineService`:
- `snapshot(machine:note:) async throws -> MachineSnapshot`
- `listSnapshots(for machineName: String?) async -> [MachineSnapshot]`
- `cloneFromSnapshot(_ snapshot:, newName:) async throws`
- `restore(snapshot:) async throws` (replace same-named machine)
- `export(snapshot:, to fileURL:) async throws`
- `importMachine(from fileURL:) async throws -> MachineSnapshot`
- `createBody` / `create` gain `recipe: DevRecipe?`, `cpus: Int?`, `memory: UInt64?`,
  `mounts: [(host,guest)]`, `ports: [(host,guest)]`.

Models: `MachineSnapshot { id, imageRef, machineName, note, createdISO, sizeBytes, distro, version, arch }`,
`DevRecipe { id, display, icon, install }` (+ static catalog).

## Error handling

- A failed commit/save/load surfaces the engine's error verbatim; no partial machine is created
  (the snapshot image either exists or it does not — verified via inspect after commit).
- Import validates the tar carries a `dory.machine` label; a non-Dory file gets a clear
  "Not a Dory machine file" message rather than a silent load.
- Export checks free disk space vs the image size (from `/images/<ref>/json`) before writing;
  on failure, the partial file is removed.
- Settings-edit recreate is transactional: if recreate fails after remove, we re-run from the
  auto-snapshot so the machine is never lost.
- All long operations (snapshot/export/import/recipe-build) report staged progress through the
  existing `creatingMachine`-style progress sheet pattern.

## Testing

Pure-logic Swift Testing units (the established pattern):
- `DevRecipe` catalog + Dockerfile-layer generation per recipe.
- Snapshot label encode/decode round-trip (`MachineSnapshot` ⇄ image labels).
- `.dorymachine` import validation (accept Dory-labeled, reject plain image tar).
- `createBody` settings mapping (NanoCpus/Memory/Binds/PortBindings shapes).
- Snapshot list mapping from a fixed `/images/json` JSON fixture.

Integration (manual, live engine, as we did for builds): snapshot a machine → clone it →
verify the clone has the same installed tools; export → import on the same engine under a new
name → run; build a Node recipe machine → `node -v` works; create with 2 CPU / 2 GB + a mounted
folder + a published port → verify limits, the folder is visible inside, and the port is
reachable.

## Files

Added:
- `Dory/Runtime/Machines/MachineSnapshot.swift` (model + label codec)
- `Dory/Runtime/Machines/DevRecipe.swift` (catalog + layer generation)
- `Dory/Features/Machines/SnapshotsSheet.swift`

Modified:
- `Dory/Runtime/ContainerRuntime.swift` (+ commit/saveImage/loadImage, default no-ops)
- `Dory/Runtime/Docker/DockerEngineRuntime.swift` (implement them)
- `Dory/Runtime/Machines/MachineService.swift` (snapshot/clone/export/import; settings+recipe in create)
- `Dory/Runtime/Machines/MachineImageBuilder.swift` (recipe layer)
- `Dory/Models/AppStore.swift` (orchestration, file panels, progress, import toolbar action)
- `Dory/Models/Models.swift` (`AppSheet` cases; any `Machine` additions)
- `Dory/Features/Machines/MachinesView.swift` (card overflow menu)
- `Dory/Features/Sheets/NewMachineSheet.swift` (Dev environment + Advanced settings)
- `Dory/Features/Main/MainColumnView.swift` (Machines "Import…" secondary action)

The Xcode project uses `PBXFileSystemSynchronizedRootGroup`, so added/removed files need no
`project.pbxproj` edits.

## Implementation decomposition (for the plan)

1. Runtime: `commit` / `saveImage` / `loadImage` (+ tests for request shapes).
2. `MachineSnapshot` model + label codec + `MachineService.snapshot`/`listSnapshots` (units).
3. Clone / restore from snapshot.
4. Export / import `.dorymachine` (+ validation).
5. `DevRecipe` catalog + builder recipe layer (units) + picker "Dev environment".
6. Machine settings (createBody + Advanced UI) + settings-edit recreate.
7. UI: SnapshotsSheet + card overflow menu + Import toolbar action.
8. End-to-end verification on the live engine.

## Risks

- **Commit image size / time** for large machines (apt caches, etc.). Mitigate: recipes clean
  apt lists; document that snapshots are layered (dedup) so incremental snapshots are cheap.
- **`.dorymachine` portability across arches**: an arm64 snapshot won't run on an Intel Mac and
  vice-versa. The file's `arch` label is checked on import; cross-arch import offers to run under
  emulation (reuses Phase-0 arch support) or warns.
- **Settings-edit recreate** is the one destructive-ish path; the auto-snapshot-before-recreate
  makes it safe, but must be implemented transactionally (covered in error handling).
