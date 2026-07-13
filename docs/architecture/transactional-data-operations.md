# Transactional data operations

Status: accepted for Apple Silicon implementation on 2026-07-13.

This contract governs competitor import, Dory-drive backup and restore, drive relocation, and
on-disk upgrades. It refines the [Apple Silicon storage contract](apple-silicon-storage.md).
Those workflows have different transfer formats, but they must not each invent their own locking,
journaling, verification, rollback, or definition of success.

## Research outcome

Competitor failures repeat the same architectural mistakes rather than isolated copy bugs:

- OrbStack migrations have crashed during inventory, reported empty sources that still contained
  data, produced zero-byte volumes, lost images, and recreated a container before its
  container-network dependency. A current migration crash regression remains open.
- Docker Desktop has forgotten a selected disk location after an update, making an intact data
  store appear lost. Other update failures have left raw disks unmountable.
- Colima backend and state-directory changes have made intact data inaccessible because the new
  runtime no longer understood or selected the old layout.
- OrbStack and Apple container sparse images have expanded, truncated, or blocked Time Machine and
  Migration Assistant. A multi-terabyte logical sparse file is not a usable backup contract.
- Docker and Apple container still require temporary-container workarounds for volume export. The
  Docker Engine API provides archive transport, but not a first-class volume export transaction.
- Rancher Desktop's snapshot design correctly treats stop/lock, durable in-progress state,
  completion markers, startup recovery, and incomplete-output pruning as one protocol.

Dory therefore uses one durable operation protocol:

```text
plan -> quiesce -> stage -> verify -> publish -> validate -> complete
```

No target is selected, attached, or presented as successfully migrated before verification.
Images imported while a selected volume or container failed is a failed operation, not partial
success.

## Scope and non-goals

The launch implementation supports Apple Silicon and local Docker-compatible engines reachable
through a Unix socket. It supports:

- a lossless offline Dory-drive backup, restore, and relocation;
- semantic import from OrbStack and Docker Desktop;
- local Docker volumes, bridge networks, and ordinary containers; and
- native arm64 plus the separately qualified amd64-container runtime.

The first release fails before writes for remote engines, external volume drivers, Swarm objects,
overlay/macvlan/ipvlan networks, checkpoint restore, or a dependency cycle. Bind-mounted host data
is validated and referenced at its canonical host path; it is not copied into a named volume.
Intel-host support is a later product track.

## Non-negotiable invariants

1. The source is authoritative and remains recoverable. Dory may stop a source workload only after
   explicit user confirmation and may create only operation-owned temporary objects there.
2. Inventory is strict. Failure to list, inspect, size, or classify any selected object stops the
   plan before target mutation.
3. The immutable plan contains the complete dependency closure. Selecting a container also selects
   its image, writable-layer snapshot, concrete named or anonymous volumes, custom networks, and
   container-mode dependencies.
4. One mutating operation owns a data drive at a time. The engine and data-drive locks compose in a
   fixed documented order; callers never acquire them in the opposite order.
5. Every external effect is recorded durably before it happens or is discoverable through a
   deterministic operation label afterward. Recovery never guesses from a name alone.
6. Staging is not publication. Operation-owned images, volumes, and networks may exist while an
   operation is incomplete, but no user container mounts or depends on them.
7. Verification reads the target back through the same public engine or drive boundary users will
   use. A successful write call is not proof of durable content.
8. Publication is monotonic and retryable. A crash at any instruction boundary has one documented
   action: resume, roll back operation-owned objects, or retain the prior source selection.
9. Completion is exact: every selected object is verified and every selected container reaches its
   declared final state, or the operation is not complete.
10. Dory never converts absent, corrupt, incompatible, or incompletely restored data into a fresh
    empty store.

## Durable control plane

### Locations

The canonical operation journal lives outside the replaceable runtime cache and outside the drive
that may be missing, moving, or under repair:

```text
~/Library/Application Support/Dory/
  operations/
    <operation UUID>.doryop/
      plan.json
      state.json
      events.ndjson
      specs/                 private content-addressed object specifications
      manifests/             source and verified-target manifests
      logs/                  bounded, redacted operation logs
```

A summary mirror is written to `<drive>/operations/<UUID>.json` whenever that drive is available.
The mirror is for audit and discovery; the control-plane journal is authoritative. Relocating or
restoring a drive therefore cannot relocate the only record needed to recover the operation.

The control directory is mode `0700`; regular files are mode `0600`, owned by the current user,
have one link, and are opened without following symlinks. Every path is canonicalized before use.
Raw registry credentials and auth headers are never persisted. Container configuration is private
because environment variables may contain secrets; UI and logs show keys and hashes, not values.

### Identity

Every operation has a random UUID and one of these kinds:

- `competitorImport`
- `driveBackup`
- `driveRestore`
- `driveRelocation`
- `driveUpgrade`

The plan binds the operation to immutable source and target authorities. A Dory drive uses its
drive UUID, APFS volume UUID when external, schema version, and canonical path. An engine uses its
daemon ID, API version, architecture, socket identity, and source product. Paths and display names
alone are never identities.

Engine objects created for an operation carry labels containing the Dory operation UUID, source
authority hash, object kind, original identity, and `staging` state. The journal records the exact
created IDs. A retry may adopt an object only when every ownership label matches. An unlabeled
same-name object is a conflict even if it appears empty.

### Journal durability

`plan.json` is immutable after publication. `state.json` is a versioned snapshot with a monotonic
revision. Each transition:

1. validates the prior revision and legal state transition;
2. writes the next snapshot to an exclusive sibling temporary file;
3. syncs the file, atomically renames it, and syncs the parent directory;
4. appends a redacted event and syncs it; and
5. updates the drive summary when available.

An event describes an intended or observed effect with a stable step ID. The implementation must
be able to replay or reconcile from `plan.json`, `state.json`, labels, and target inspection if the
last event append was interrupted. A corrupt latest state preserves prior files and enters
`needsRecovery`; it never initializes an unrelated operation.

### States

The durable phase is one of:

```text
planned
quiescing
staging
verifying
readyToPublish
publishing
validating
completed
```

Status is orthogonal to phase:

- `running`: the current owner may advance the operation;
- `interrupted`: no owner is active and an idempotent resume is available;
- `blocked`: source drift, capacity, conflict, or unsupported semantics requires a new plan or user
  action before any advance;
- `rollingBack`: operation-owned effects are being removed or the previous drive selection is
  being restored;
- `needsRecovery`: automatic reconciliation cannot prove which authority is safe;
- `failed`: no more automatic work remains, source is safe, and a specific retry/cleanup action is
  recorded; or
- `completed`: validation and completion-marker publication both succeeded.

`cancelled` is a terminal result, not permission to abandon target objects. Cancellation first
quiesces I/O, then rolls back operation-owned unpublished effects. A cancellation during drive
publication retains both drives and keeps the previously validated selection authoritative.

## Planning contract

Planning performs no target writes. It stores:

- source and target authority fingerprints;
- exact source inventory and inspection/configuration hashes;
- user selection and its computed dependency closure;
- supported, blocked, and deliberately excluded objects with reasons;
- normalized target names and collision decisions;
- source logical data, target free space, host free space, staging overhead, and safety margin;
- required capabilities and the result of read-only daemon/API probes;
- quiescence requirements and expected final workload states; and
- the exact success equation.

For Docker-semantic import, the closure includes:

- every selected tag and content-addressed image identity;
- a writable-layer snapshot for every selected container whose diff is non-empty;
- every mount backed by a named or Docker-generated anonymous volume;
- network driver, internal/attachable flags, options, IPAM subnet/gateway/range/options, aliases,
  and requested addresses;
- restart policy, healthcheck, command, entrypoint, environment, labels, user, working directory,
  capabilities, security options, resources, devices, mounts, ports, DNS, hosts, and logging
  configuration; and
- dependencies expressed by `network_mode: container:`, IPC/PID container modes, links, and
  volumes-from semantics.

Dependencies form a directed acyclic graph and are published in topological order. Cycles and
references outside the selection block planning. Compose labels are preserved, but Compose service
order is not treated as a substitute for actual engine dependencies.

The source inventory is re-read before quiescence and again before publication. A changed object
ID, configuration hash, volume usage, network contract, or container state is source drift. Resume
then requires a new plan; it cannot silently mix two points in time.

### Capability matrix

Dory records the negotiated Engine API version and parses all supported response shapes. For the
Apple Silicon launch it qualifies API 1.40 through 1.55, including both legacy `Volumes` and newer
`VolumeUsage.Items` disk-usage responses. Capability checks cover image save/load, container
archive GET/PUT, non-pausing commit, inspect fidelity, and ownership labels.

If the source has volumes but no suitable image, Dory loads a bundled, digest-pinned arm64 scratch
transfer image, creates stopped helper containers, and removes those operation-owned objects after
success or rollback. The helper contains no registry dependency, executable, `VOLUME`, or startup
requirement. Dory never chooses an arbitrary user image as an implicit transfer dependency.

## Quiescence contract

A filesystem transfer is not automatically an application-consistent backup. By default, a
container with writable layers or a read-write volume must be stopped before its bytes are
captured. Running and paused containers block the operation until the user explicitly stops them.
The plan records their original states so Dory can restore them after capture.

An advanced future crash-consistent mode may pause writers, but must be labelled as such and cannot
be presented as database-consistent. Application-aware hooks require their own qualification. A
read-only mount does not require stopping that reader if no selected writer can mutate the volume.

Drive backup, restore, relocation, and upgrade require the Dory engine and every drive owner to be
stopped, the guest filesystem cleanly unmounted, and discard/trim complete. The drive lock remains
held through publication or rollback.

## Staging and verification

### Semantic engine import

Images are transferred as Engine-compatible OCI/Docker archives and verified by content/config
digest plus required tag bindings. A deleted source tag uses a unique operation-owned reference;
it never temporarily reuses or overwrites a user's tag, and container commit uses `pause=false`
after source quiescence.

Networks and volumes are created with operation ownership and their final engine-visible names
because Docker has no rename primitive for them. They remain staging objects: no published
container references them. Existing unlabeled names are fail-before-write conflicts. An earlier
matching operation object may be resumed only after its contract is inspected and matched.

Volume transfer uses a created-but-never-started helper container and Engine archive GET/PUT. Dory
generates a deterministic manifest from the source archive and independently generates the same
manifest by reading the target archive back. The manifest covers each path's:

- byte content hash and size;
- regular file, directory, symbolic link, hard-link group, FIFO, or supported device type;
- mode, uid, gid, nanosecond modification time, and link target; and
- supported xattrs and ACL representation.

Archive paths containing `..`, absolute paths, escaping links, duplicate conflicting entries,
invalid UTF-8 policy cases, integer overflow, or unsupported metadata fail before extraction.
Sockets are never archived; a source socket is reported as a regenerated runtime object. Device
nodes require an explicit supported policy rather than silent conversion. Sparse files inside a
volume must preserve their logical length and data ranges or fail with an honest physical-space
expansion estimate; this is independently qualified against every supported source engine.

Only after every image, network, volume, and writable-layer snapshot in the closure verifies does
the journal enter `readyToPublish`.

### Full Dory-drive backup

A `.dorybackup` is not a tar of `docker-data.ext4`. It contains:

- a versioned top-level manifest and source drive identity;
- filesystem metadata for ordinary drive files;
- sparse-file logical sizes and ordered data/hole extents discovered with
  `SEEK_DATA`/`SEEK_HOLE` where supported;
- bounded, content-addressed chunks with length and cryptographic hashes; and
- a completion marker signed by the archive manifest hash.

Backup is written to a private sibling partial and published only after every chunk can be read
back and the full manifest verifies. An incomplete archive has no completion marker and is never
offered as restorable. On same-volume local snapshots, APFS `clonefile` may accelerate staging, but
the portable manifest remains the source of truth. Time Machine exclusion and backup guidance must
apply to raw Dory sparse disks and incomplete archives.

Restore creates a new partial `.dorydrive`, validates all paths and lengths before allocation,
reconstructs sparse extents without writing holes as zeroes, verifies every file and drive
geometry, then publishes the drive. Restore never writes into the currently selected drive.

### Drive relocation and upgrade

Relocation copies or APFS-clones the complete drive to a partial destination. Verification covers
the drive manifest, UUID policy, ordinary-file hashes, sparse logical lengths and allocated data
ranges, ext4 geometry, and clean shutdown marker. Dory then:

1. publishes the destination bundle;
2. atomically updates the separate selected-drive authority;
3. boots and probes the destination through the production engine path; and
4. marks completion while retaining the old source as rollback.

Failure before the successful boot probe keeps or restores the old selection. Dory never deletes
the source automatically; cleanup is a later explicit action naming its UUID and path.

An upgrade is a sequence of idempotent, versioned transforms. It first creates a verified local
rollback snapshot or refuses to proceed. Backend, partitioning, filesystem, and state-directory
changes are explicit schema steps with compatibility probes. An update may not switch to an empty
new layout merely because the old version is unknown.

## Publication and exact completion

Semantic import publishes containers only after dependency verification:

1. create every container stopped in topological order;
2. inspect and compare its normalized effective specification with the plan;
3. if any comparison fails, remove every container created by this publish attempt;
4. after all definitions match, restore stopped/running/paused states and validate health/state;
5. re-inventory source and target; and
6. publish the completion marker and report.

Fixed host ports are never silently remapped. If a planned port is occupied, the operation blocks
before container creation or records an explicitly approved `createdStoppedAwaitingPort` final
state. A full migration cannot call that deferred state complete unless it was part of the user's
accepted plan.

The completion equation is persisted in the plan and evaluated mechanically:

```text
selected object IDs
  == verified target mappings
  == post-publication target mappings

and

every final state == accepted planned final state

and

unselected source inventory == original unselected source inventory

and

unowned target inventory == original unowned target inventory
```

Counts are supporting information, not identity proof. The report lists each source ID, target ID,
verification manifest, final state, exclusion, warning, and rollback result. There is no generic
“partial completeness” release row: every declared support class is either qualified, explicitly
blocked before writes, or outside the launch contract.

## Crash recovery

Startup scans the control operation directory before attaching a data drive or starting an import.
It reconciles the last phase with locks and labelled objects:

| Interrupted phase | Automatic safe action |
| --- | --- |
| `planned` / `quiescing` | Recheck authority and inventory; resume or restore any Dory-stopped source state. |
| `staging` | Inspect operation-owned objects and manifests; resume the first incomplete step or roll them back. |
| `verifying` | Re-read staged data; never trust an unpersisted verification result. |
| `readyToPublish` | Recheck source drift and target ownership, then publish or roll back staging. |
| `publishing` | Reconcile every planned container by label and inspect; finish the set or remove the attempt. |
| `validating` | Keep the old drive/source authority, repeat production probes, and complete only on exact equality. |
| completion write | A valid completion marker wins; otherwise repeat validation and republish it idempotently. |

If both old and new drives appear attachable after relocation, the separate selection record and
last verified boot decide; Dory does not attach either by path guess. If neither can be proved safe,
the app enters `needsRecovery`, leaves both untouched, and names the evidence required for a user
choice.

## Required implementation order

1. Durable journal, state machine, secure filesystem primitives, lock ordering, and subprocess
   crash/failpoint tests.
2. One shared planner and exact completion model, then compatibility parsing for Engine API
   1.40–1.55.
3. Bundled transfer image plus deterministic archive manifest and adversarial extraction tests.
4. Semantic stage/verify/publish for images, volumes, networks, writable layers, and dependency-
   ordered containers.
5. Sparse chunk backup/restore and offline drive relocation using the same journal.
6. Upgrade transforms and startup recovery using the same reconciliation API.
7. UI/CLI progress, cancellation, recovery actions, and complete evidence reports.

Implementing UI-specific retries or another one-off migration cleanup before steps 1–3 is a design
regression.

## Release qualification matrix

Every failpoint is exercised in a fresh subprocess that is killed after the external effect but
before the next journal write, and after the journal write but before the effect. Recovery must be
idempotent across repeated kills.

Required classes include:

- journal partial writes, corrupt latest state, symlink/hard-link substitution, wrong ownership,
  concurrent owners, and lock-order contention;
- host full, target full, short writes, target disappearance, external-volume rename/unmount,
  wrong APFS volume under the old name, and source drift at every phase;
- Engine API 1.40–1.55 disk-usage shapes, lost socket, stalled archive streams, cancellation, and
  daemon restart;
- zero images with volumes, deleted tags, duplicate tags, anonymous volumes, same-name conflicts,
  zero-byte and multi-gigabyte volumes, and generated names;
- uid/gid/mode/time, symlinks, hard links, xattrs, ACLs, sparse files, FIFOs, sockets, device nodes,
  malicious tar traversal, duplicate paths, and link escapes;
- custom bridge IPAM, aliases and requested IPs, fixed ports, healthchecks, restart policies,
  privileged/security/resource settings, writable layers, and stopped/running/paused states;
- dependency chains for container network/IPC/PID modes, links, volumes-from, missing references,
  and cycles, including the Supabase-style failure where a dependent container appears first;
- sparse backup/restore on APFS, clone and cross-volume copy, interrupted backup/restore,
  truncated logical tails, bad chunks, incomplete completion markers, and old-source rollback;
- the entire current real OrbStack inventory, not just an owned Alpine fixture, plus a Docker
  Desktop inventory with the same semantic classes; and
- the exact signed/notarized Homebrew-installed Apple Silicon app, daemon, helpers, and bundled
  transfer image hashes.

The real-inventory gate may remain blocked on capacity or an unowned collision, but then it must
prove that planning reports every blocker before writes and leaves both inventories byte-for-byte
and identity-for-identity unchanged. Release requires a separate full successful inventory gate
with sufficient disposable storage.

## Primary sources

- [Docker volumes: back up, restore, or migrate data volumes](https://docs.docker.com/engine/storage/volumes/#back-up-restore-or-migrate-data-volumes)
- [Docker storage: direct host access to volume data is unsupported](https://docs.docker.com/engine/storage/)
- [Moby Engine API schema](https://github.com/moby/moby/blob/master/api/swagger.yaml)
- [Moby: volume export/import request #31417](https://github.com/moby/moby/issues/31417)
- [Moby: archive access through a created container #25245](https://github.com/moby/moby/issues/25245)
- [OrbStack: reliable Docker-data export/import #2354](https://github.com/orbstack/orbstack/issues/2354)
- [OrbStack: sparse disk truncated by Migration Assistant #2472](https://github.com/orbstack/orbstack/issues/2472)
- [OrbStack: migration dependency order failure #1431](https://github.com/orbstack/orbstack/issues/1431)
- [OrbStack: missing images and zero-byte volume #2412](https://github.com/orbstack/orbstack/issues/2412)
- [OrbStack: current migration crash regression #2533](https://github.com/orbstack/orbstack/issues/2533)
- [OrbStack: migration reports empty data #2364](https://github.com/orbstack/orbstack/issues/2364)
- [OrbStack: volume backup/restore #1941](https://github.com/orbstack/orbstack/issues/1941)
- [Docker Desktop: update reset selected disk location #2119](https://github.com/docker/for-mac/issues/2119)
- [Docker Desktop: update left raw disk unmountable #7834](https://github.com/docker/for-mac/issues/7834)
- [Colima: backend change made old data inaccessible #506](https://github.com/abiosoft/colima/issues/506)
- [Colima: state-directory move made data appear absent #875](https://github.com/abiosoft/colima/issues/875)
- [Apple container: sparse snapshots block Time Machine #404](https://github.com/apple/container/issues/404)
- [Apple container: volume-copy API request #895](https://github.com/apple/container/issues/895)
- [Rancher Desktop: snapshot/restore design epic #4236](https://github.com/rancher-sandbox/rancher-desktop/issues/4236)
