# Apple Silicon storage and migration architecture

Status: accepted for implementation on 2026-07-13.

This decision applies to the first public Apple Silicon release. Intel-host support is a later
track. Because Dory has no public users yet, the launch contract is allowed to replace development
layouts instead of carrying accidental compatibility forever.

## Product contract

Dory has one durable data drive and one replaceable runtime cache.

The data drive owns every byte a user reasonably expects to survive an app update, engine rebuild,
runtime reset, or Homebrew uninstall:

- Docker images, containers, writable layers, named volumes, custom networks, and BuildKit state;
- Kubernetes state;
- managed-machine disks, definitions, snapshots, and recipes; and
- Dory-created backup/export metadata.

The default drive is `~/Library/Application Support/Dory/Dory.dorydrive`. A user-selected drive is
a `.dorydrive` bundle on mounted local APFS storage under `/Volumes`. Sockets, PID files, bounded
logs, decompressed kernels, disposable root filesystems, and other reproducible boot assets remain
under `~/.dory` and may be replaced without affecting the drive.

The app, daemon, standalone launcher, raw Hypervisor.framework VMM, Virtualization.framework
fallback, doctor, migration assistant, release gates, and UI must all use the same storage library.
No component may reconstruct the policy with its own string-prefix check.

## Identity is not a path string

macOS can spell one filesystem location in more than one way. In particular, Foundation path
standardization may remove an initial `/private` only when the referenced ancestor already exists.
That means separately standardizing an existing home and a not-yet-created descendant can turn
`/private/tmp/home` into `/tmp/home` while leaving
`/private/tmp/home/Library/Application Support/Dory/Dory.dorydrive` unchanged. The two strings name
the same intended location but fail a prefix comparison.

Dory therefore uses three distinct concepts:

1. **Canonical location** — lexically normalize the absolute input, resolve the deepest existing
   ancestor through symlinks, then append the still-missing suffix. Derive the default drive from
   the canonical home; canonicalize overrides by the same algorithm.
2. **Drive identity** — a UUID stored in the drive manifest and used by runtime ownership records.
   A displayed or configured path can move; the drive identity cannot silently change.
3. **Volume identity** — for external drives, retain the mounted volume identity/bookmark alongside
   the last known path. A missing volume fails closed. Dory never creates `/Volumes/<name>` and
   accidentally writes a shadow copy onto the internal disk.

Path authorization is applied after canonicalization. The only internal location is the canonical
Dory Application Support directory. External locations must still resolve below `/Volumes`, be a
real mount root, and report local APFS. Privacy-protected Desktop, Documents, Downloads, iCloud,
and CloudStorage paths are rejected because a background daemon cannot inherit a transient UI
authorization reliably.

## On-disk contract

The launch bundle layout is:

```text
Dory.dorydrive/
  drive.json                 version, UUID, creation/product metadata
  drive.lock                 exclusive attachment and mutation lock
  engine/
    docker-data.ext4         bounded sparse ext4 store
    docker-data.json         logical size, filesystem geometry, integrity metadata
  kubernetes/                cluster-owned durable metadata not already in Docker
  machines/                  one self-describing bundle per managed machine
  snapshots/                 local snapshots explicitly created by the user
  exports/                   portable exports explicitly retained by the user
  operations/                crash-recovery journals for relocation/import/upgrade
```

The manifest is written atomically, fsynced, private to the user, and validated before any engine
attaches storage. A populated directory without a valid Dory manifest is never adopted. A second
engine cannot attach the same drive, even through a different path alias.

The selected-drive authority is a separate private, atomically published control record at
`~/Library/Application Support/Dory/data-drive-selection.json`. Its schema-2 `provisioning` →
`ready` transaction records the intended drive UUID before first creation, so a crash can resume
the same drive without adopting an unrelated bundle. The ready record stores the drive UUID,
external APFS volume UUID, last canonical path, and a minimal macOS bookmark. It does not live
under `~/.dory`: replacing every runtime socket, PID, log, kernel, and rootfs cache cannot make Dory
forget an external drive and initialize an empty default. A resolved bookmark is accepted only
after the drive and volume UUIDs match; a missing drive or same-name replacement volume fails
closed without creating a mount-point shadow.

`doryd` holds an exclusive lease on that authority record for its complete process lifetime. A
drive-selection command therefore cannot rewrite the path beneath an already-configured sleeping
daemon: it gracefully unloads the LaunchAgent (which stops Docker and machine VMs), locks both the
old and new drive identities, publishes the selection, restarts the same validated LaunchAgent,
and confirms XPC readiness. A standalone engine holding either drive makes the switch fail closed.

The Docker filesystem is a bounded sparse file, not an 8 TiB promise. The launch default is a
128 GiB logical ceiling. Settings and `dory data grow GIB` can increase it monotonically to 2 TiB;
out-of-range and shrink requests fail before the engine is interrupted. The CLI captures the exact
running-container set, stops the engine, grows under the drive lease, restarts the engine, and
starts only that captured set. Guest ext4 expands on the next boot. Guest discard maps to APFS hole
punching. Before an actual resize, the unmounted filesystem receives a forced `e2fsck` preen;
unsafe repair results fail boot, and the engine startup deadline bounds the check. Graceful shutdown
runs sync, unmount, and trim before the VM exits. Settings and `dory data capacity` report physical
allocation separately from logical capacity.

Raw sparse images are an implementation detail, not the backup format. OrbStack currently warns
users to delete or tar its 8 TiB image before Migration Assistant, and its tracker contains both a
2026 request for reliable Docker-data export/import and a migrated sparse-image truncation that
panicked at startup. Dory must not make users copy its raw disk by hand.

## State transitions

Every destructive-looking operation is a publish-after-verify transaction governed by the shared
[transactional data-operations contract](transactional-data-operations.md):

- **First creation:** build a sibling partial bundle, write and sync its manifest, create private
  subdirectories, then atomically publish it.
- **Development-layout adoption:** clone into a partial destination, verify the source and clone,
  publish the clone, and retain the source as rollback. Never move or edit the source.
- **Drive relocation:** stop and quiesce every owner, clone/copy to a partial destination, verify
  manifests plus sparse-disk geometry and allocated content, publish, switch the identity record,
  boot and probe, then offer removal of the old source only after success.
- **Upgrade:** record the pre-upgrade schema and engine geometry, perform an idempotent migration,
  and retain enough information to reopen the previous layout. An app update cannot silently start
  against an empty replacement drive.
- **Failure:** preserve source state, partial-operation journal, engine/guest logs, and a specific
  recovery action. Never translate corruption, an absent volume, or an unknown manifest into a
  fresh empty Docker store.

## Portable backup and competitor import

Dory provides two separate workflows because they solve different problems:

1. **Full Dory drive backup/restore** is offline and lossless. Its archive stores ordinary files
   plus sparse block extents as bounded chunks with per-chunk hashes and a top-level manifest. It
   never expands a 128 GiB sparse file into 128 GiB of zeros. Restore writes a partial drive,
   verifies every chunk and filesystem geometry, then publishes atomically.
2. **Docker-semantic export/import** is portable across engines. It exports OCI images, exact
   named-volume contents and metadata, custom network/IPAM definitions, container create specs and
   state, and writable-layer snapshots. Import is resumable and source-preserving. Containers are
   created only after every required image, network, and volume passes verification.

Competitor migration uses the semantic path, not another vendor's private disk format. The source
daemon remains authoritative, mutable source volumes require stopped writers, target conflicts
fail before mutation, partial target objects are removed, and retries are ownership-labelled and
idempotent. Images-only success is a failed migration when the selected containers or volumes were
not reproduced.

## Recovery and observability

`dory doctor`, Settings, and the standalone CLI show the same facts:

- canonical path, drive UUID, volume identity, mounted/read-write/local/APFS status;
- logical capacity, physical allocation, reclaimable estimate, and configured cap;
- manifest/schema status, engine filesystem geometry, last clean shutdown, and active owner;
- unfinished relocation/import/upgrade journal and the exact safe recovery action; and
- backup age and the fact that raw VM disks are not a portable backup.

The data drive is not silently deleted by uninstall, Homebrew `--zap`, reset, or failed import.
Cleanup targets labelled disposable caches and test homes only. User-owned drive deletion always
names the exact drive UUID/path and requires explicit confirmation.

## Mandatory launch gates

The exact signed/notarized Apple Silicon candidate must pass all of these from fresh and populated
drives:

- `/tmp` versus `/private/tmp`, symlinked-home, dot-component, and non-existing-descendant aliases
  resolve to one canonical location and one drive identity across every launcher/helper;
- protected/arbitrary home locations, remote/non-APFS volumes, missing external drives, unmarked
  populated bundles, and unwritable roots fail before VM attachment and create no shadow/partial;
- app, daemon, standalone, raw-HV, and VZ paths select the same drive and reject a concurrent second
  owner even through an alias;
- erasing all `~/.dory` state preserves selected-drive authority, an APFS volume rename is recovered
  through its bookmark, and a different volume mounted under the old name is rejected by UUID;
- images, containers, writable layers, volumes, networks, BuildKit, Kubernetes, and machines survive
  replacement of all runtime cache state plus app update/rollback;
- 16 GiB legacy disks grow sparsely to the configured ceiling, ext4 grows in the guest, trim returns
  physical blocks, capacity is reported honestly, and cap exhaustion is explicit;
- abrupt kill, host restart, graceful shutdown, disk-full, permission loss, truncated sparse tail,
  and interrupted creation/relocation/import never produce a silently empty store;
- full backup/restore and relocation preserve sparse allocation, identities, checksums, metadata,
  stopped/paused state, and rollback source; and
- real OrbStack and Docker Desktop imports preserve selected images, 64 MiB volume checksums,
  metadata/links, networks/IPAM, container definitions, writable layers, and state, with exact source
  and target inventories unchanged outside the selected migration.

Release evidence retains the exact app/helper/runtime hashes, drive manifest, operation summaries,
and failure logs. A development source run can validate the architecture but cannot promote a row
that explicitly requires the final notarized artifact or physical external media.

## Primary references and competitor evidence

- [Apple: Using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively)
- [Apple: URL path standardization behavior](https://developer.apple.com/documentation/foundation/nsurl/standardizingpath)
- [Apple: URL bookmarks](https://developer.apple.com/documentation/foundation/url)
- [Apple: document identifiers](https://developer.apple.com/documentation/foundation/urlresourcevalues/documentidentifier)
- [Apple: local-volume resource value](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeislocal)
- [Apple: raw VZ disk-image attachment](https://developer.apple.com/documentation/virtualization/vzdiskimagestoragedeviceattachment/init%28url%3Areadonly%3Acachingmode%3Asynchronizationmode%3A%29-36gc5)
- [OrbStack: Docker data export/import request #2354](https://github.com/orbstack/orbstack/issues/2354)
- [OrbStack: Migration Assistant sparse truncation #2472](https://github.com/orbstack/orbstack/issues/2472)
- [OrbStack FAQ: 8 TiB data image and Migration Assistant warning](https://docs.orbstack.dev/faq#why-is-there-an-8-tb-data-file)
- [Docker for Mac: update lost images, containers, and volumes #1175](https://github.com/docker/for-mac/issues/1175)
