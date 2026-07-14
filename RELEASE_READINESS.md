# Dory 0.3.0 release readiness

Last updated: 2026-07-14

## Decision

**NO-GO for public release today.** The Apple Silicon candidate is signed, notarized, stapled, and
cryptographically qualified, but the release must not publish until the remaining physical
release-host, external-infrastructure, endurance, and exact clean-v1 gates below are complete.
Intel is a later roadmap phase and is not part of the Apple-Silicon-first release contract. This document
intentionally separates verified evidence from claims that still need proof.

**Architecture-first completion:** migration import is now wired to the durable operation protocol
shared by import, backup/restore, drive relocation, and upgrade. The shared `DoryOperations`
package is linked by both the app and daemon stack. Its private journal/state-machine provides
immutable plan digests, monotonic legal
transitions, a single mutation lease, atomic synced state, a recoverable append audit log, terminal
cancellation, drive-summary mirroring, and symlink/hard-link rejection. Its shared planner now
computes a deterministic full dependency closure and topological order from exact source
identities, binds target collision decisions and accepted final states, and evaluates completion
as exact verified/post-publication mappings plus unchanged unselected-source and unowned-target
inventories. Image-only evidence cannot complete a plan containing volumes, networks, writable
layers, or containers. The complete Swift package and non-UI app suites pass, and the Apple Silicon
app builds against this same package with Xcode 26.6. Volume inventory
preflight now uses a researched, strict compatibility decoder for Engine API 1.40–1.55: it accepts
legacy `Volumes`, transitional dual-shape, and current `VolumeUsage.Items` responses, rejects
conflicting or malformed successful responses, and never hides a malformed success through a
legacy fallback. Import preflight and execution now create, persist, execute, revalidate, publish,
and complete exact plans through the shared journal; partial success is not presented as a
completed import. The owned adversarial fixture proves the complete object classes rather than the
user's unrelated historical 79-volume, 14-container inventory. The accepted
[transactional data-operations contract](docs/architecture/transactional-data-operations.md)
is implemented as one plan → quiesce → stage → verify → publish → validate protocol with
exact dependency closure, pre-write source/target revalidation, durable ownership, rollback, and a
mechanical completeness equation. The real OrbStack-to-Dory gate now passes images, writable
layers, named volumes, networks, container definitions, stopped/running/paused state, fixed ports,
and exact source/target baseline restoration. Public release still requires these same bits to be
replayed through the exact notarized candidate on the physical release host.

**Clean-v1 scope:** Dory is being launched as a new product with no users, so unreleased Dory data
layouts are not compatibility targets or release fixtures. The v0.2 upgrade/rollback gate and
pre-launch state-adoption requirements have been removed. Competitor imports remain mandatory,
and the public v1 schema must support crash-safe backup, restore, relocation, and forward updates
after launch. The committed static Linux/arm64 transfer helper and deterministic scratch-image
archive now prove source-before/source-after equality plus exact repaired-target equality through
the real Docker archive boundary, and the application executor orchestrates that primitive through
the shared journal. Full `.dorybackup` creation and restore now use that journal too: backup holds
the production drive lock, discovers sparse extents with `SEEK_DATA`/`SEEK_HOLE`, deduplicates
bounded SHA-256 chunks, verifies read-back, and publishes with an exclusive rename plus completion
marker. Restore validates every path, length, chunk, and marker before allocation; reconstructs
holes without writing zero ranges; preserves links, xattrs, ACLs, ownership, modes, and nanosecond
times; rebinds external-volume identity; inventories the rebuilt drive; and never overwrites a
target. Eight adversarial tests cover busy-drive refusal, sparse and metadata fidelity, hard links,
deduplication, incomplete and corrupt archives, unsupported entries, no-overwrite behavior, and
crash resumption on both sides of publication. The real `dory data backup|verify|restore|use` CLI
gate also passes a sparse/xattr round trip. Exact notarized-candidate and physical cross-volume/
Time Machine campaigns remain release evidence gates.

**The signed `20260712T035458Z` app candidate is superseded for app release purposes.** Its
standalone engine completed the immutable eight-hour baseline, but the post-build
migration audit found release blockers in the app layer: a stale panel says volume data is not
copied, image-tag collisions are not preflighted, the deleted-tag snapshot fallback temporarily
reuses the user's source tag and accepts Docker's default source-container pause, archive I/O has
no idle timeout/cancel path, and recreated custom
networks lose IPAM/options. Partial-import ownership is also keyed only as generic `docker`, so a
retry needs a stable per-source identity before it can safely resume. The user's current OrbStack
inventory has three explicit custom subnet/gateway contracts. It also contains 15,656,752,870 bytes
across 79 named volumes while the Mac currently has only about 11–13 GiB free; volumes plus 38
tagged images cannot fit the superseded candidate's 16 GiB logical Docker disk. Eleven containers
also carry 497,029,428 bytes of writable-layer changes outside named volumes; current source now
sizes and snapshots those layers instead of silently recreating only their base images. The failed target
disk's clean ext4 filesystem has only 13,752,078,336 bytes free, about 1.9 GB less than the source
volumes alone, and the backing file is 99.02% physically allocated (17,144,496,128 of
17,314,086,912 bytes). This proves the old target cannot complete the requested import. Offline
target inspection also found 65 existing target volume entries, including 11 same-name collisions
with OrbStack. None carries a Dory migration-ownership label. Ten are provably empty, detached, and
will be adoptable while preserving labels only if the live daemon also reports matching local
driver/options. The one non-empty collision contains 31 logical bytes and remains a hard preflight
blocker until the user explicitly backs it up/resolves it. Current source surfaces that distinction
before writes and implements
fail-before-write target collisions, exact volume/network contracts, stable source
ownership, non-pausing unique snapshot tags, cancellable idle-bounded streams, exact volume-size
and host/target capacity preflight with the additional space-to-free shown explicitly, strict
all-object inventory, live-volume quiescence blocking,
container writable-layer sizing/snapshotting with running-change quiescence,
transactional partial-volume/container cleanup, rollback restoration of adopted empty-volume
metadata and replaced detached-network contracts, fixed-port deferral, and sparse 128 GiB data-disk growth with
guest ext4 expansion. Boot and graceful shutdown now issue `fstrim` through Dory's virtio-discard
path, returning deleted/free ext4 extents to APFS instead of leaving an old sparse file physically
full. Host validation also rejects invalid ext4 geometry before changing a file, and every guest
boot path now permits `mkfs.ext4` only for a host-proven unallocated blank; an existing ext4 mount
failure powers off instead of falling through to reformatting. Current worktree and isolated-runtime
proof now cover these fixes, including the 16→128 GiB disk gate and disposable two-engine
migration. A fresh Developer ID-signed 0.3.0/18 arm64 rehearsal from commit
`85775703c1eddb77925237fc93c46146ac6bfb8a` passes the complete build, package, recursive-signature,
payload, mounted-DMG, archive, and SBOM contracts. It is deliberately marked non-public and remains
historical evidence only; the current notarized candidate below supersedes it.

**Current Apple Silicon qualification candidate:** the public-shape 0.3.0/18 artifact set was built
from clean source commit `06e8c77592cc318e971529ada0ec3a93d67bb40a` with Xcode 26.6. Apple accepted
the main app (`429800ad-8ef4-484c-bba8-0553c6e09aa2`), signed DMG
(`e6fecfb6-3ea9-41b1-8e60-579bd5798333`), lite app
(`56b93cc4-bf4e-438a-b40c-0a8055094c92`), and self-contained Sparkle update
(`8ad229d6-488e-4c5a-b481-ba0c7d7951e5`). Every container is Developer ID signed with a secure
timestamp where applicable, every Apple ticket is stapled, and Gatekeeper identifies the app and
DMG as `Notarized Developer ID`. Independent release-output validation passes against the
schema-2 manifest, and the exact appcast archive's Ed25519 signature verifies against the public
key embedded in the shipped app. The qualification-only verification improvement at current commit
`5674a621` does not alter the candidate; the manifest intentionally remains bound to its exact
source commit. A release published after the remaining physical gates must be rebuilt and rebound
to the final release tag rather than representing this candidate as built from current HEAD.

## Verified locally

- The full non-UI app gate passes **814 tests in 110 suites** after the final migration, Compose,
  ephemeral-port preservation, and daemon-owned recovery changes.
- Compose GUI lifecycle is now delegated to the bundled official Compose v2 helper instead of a
  partial in-app parser/reconciler. Fourteen focused tests pass exact socket/environment isolation,
  native-label recovery, multi-file arguments, all-profile lifecycle, secret-safe failures,
  bounded concurrent output, timeout/cancellation, and shell-injection resistance. The strengthened
  disposable-engine campaign passes all 38 rows, including `.env`/`!reset` merge, completed and
  healthy dependencies, profile isolation, real orphan cleanup, bind/named-volume/custom/external
  networking, restart/start/stop/logs, data-safe `down`, and cleanup persistence. Qualification and
  publication now bind this proof to the exact Compose-helper digest as well as the Docker CLI.
- Recovery is now daemon-owned instead of a UI shell-out for live subsystems. Focused XPC and app
  tests pass DNS/domain listener restart, route re-derivation, guest-agent RPC recovery, Docker API
  fail-closed reporting, incident attribution, and invalid-target rejection. dory-hv now serializes
  ordinary and manually requested gvproxy port reconciliation; the CLI and Health screen use the
  same repair contract. `scripts/test-dory-doctor.sh`, `scripts/test-p0-smoke.sh`, the 26-test
  DorydClient suite, and the competitor-derived release-policy gate pass. The strict live P0 gate
  now requires successful attributed results for all six recovery targets, observes dory-hv's
  published-port reconciliation acknowledgement, and proves the published HTTP workload remains
  reachable afterward.
- The owned live OrbStack-to-Dory migration passed against both real engine sockets. It preserved:
  image availability, named-volume bytes, custom networking, environment, command/entrypoint,
  mounts, restart policy, and running state. It covers deleted tags, normalized cross-daemon image
  IDs, and a fully unavailable source image recovered through a temporary container snapshot.
- Migration refuses to overwrite same-name target volumes or networks that Dory does not own, and
  resumes only migration-labeled partial objects. Bare source-only image IDs are rebound to a
  portable Dory reference, and failed container start/pause restoration removes the container
  created by that attempt so the next retry is not blocked by its name.
- Historical Dory Core clone tests passed, but pre-launch Dory-disk adoption is no longer part of
  the product or release contract. Exclusive engine-state locking and fail-closed v1 drive
  validation remain required.
- The latest Dory Core run passed **320 tests with zero failures**. The latest
  ContainerizationEngine/DoryHV run passed **502 tests in 62 suites**, including attachment of the
  persistent Docker data disk on the macOS 14 VZ path, state-lock contention, published-port host-IP
  planning, and virtiofs ownership behavior.
- Linux-machine cards no longer claim allocated RAM is usage or display fabricated `0.0%` CPU.
  Running machines now sample guest `/proc` through the bounded guest-agent exec path every two
  seconds, while `dorydctl machine stats` exposes a strict versioned CPU, used/total memory,
  network, block-I/O, process, and uptime schema. Four focused parser/contract tests, 24 XPC/app
  lifecycle tests, the full Dory Core suite, the full 838-test app suite, and the offline
  competitor release-policy suite pass. The exact-candidate resource gate now validates live stats
  after every resource-changing restart.
- SSH-agent qualification now covers the separate BuildKit session path required by
  `RUN --mount=type=ssh`: a network-disabled build must receive the same sorted public identity
  digest as the host and ordinary Dory guest socket, while retaining neither key text nor private
  material. The disposable current-source raw-HV execution passed one ordinary client, eight
  concurrent clients, and the required BuildKit mount with the same digest; the throwaway agent
  identity and isolated 128 GiB sparse state were removed afterward. Retained evidence contains no
  key text:
  `~/.dory-new-gate-evidence/20260713T-buildkit-ssh-agent/20260713T022720Z-8891/manifest.txt`.
  Publication semantically rejects a missing required mount or divergent digest.
- The competitor runtime gate now additionally reproduces three live Apple-container gaps through
  Dory's real Docker API: Rails-style nested `.dockerignore` unignores, network-scoped aliases with
  stable stop/start IPs, and bounded byte-exact `docker cp` in both directions through a mounted
  named volume. The first expanded run also exposed a Dory host-watcher recovery defect: a
  guest-side `O_RDONLY` nudge of a host mode-0200 file could be rejected by the unprivileged macOS
  virtiofs server until reverse-invalidation recovery restarted the VM. The guest agent now selects
  non-truncating write access for write-only regular files and safely nudges the nearest live parent
  when neither access mode is permitted. Focused Rust tests preserve bytes and modes for mode-0200
  and mode-000 files. The latest raw-engine full-default campaign passed all 34 mandatory rows,
  including 2,000 published connections, 20 restarts, 10,000 bind operations with zero FD growth,
  1,000 restrictive hard-link reads, and four overlapping required-secret BuildKit sessions with
  isolated exact context bytes. It additionally proved a genuinely empty fresh named-volume root,
  exact defaulted Dockerfile ARG expansion, a zero-only stdout image-archive tail, and import/export
  of a deep hard link whose layer omitted every parent-directory entry. The campaign exposed and
  fixed the standalone launcher dropping `--amd64` on restart: Apple Silicon now defaults FEX on
  and persists CPU, memory, translation, GPU, LAN, and selected data-drive settings, so the same
  `dory-runc` container ID resumed after a plain stop/start. Exact cleanup and cleanup persistence
  passed. Evidence:
  `~/.dory-new-gate-evidence/20260713T-competitor-runtime-34-row-image-semantics/run`
  (archive SHA-256 `3063e81897a5e6d78710c2f91c62516dea4d4ba7de3e2e4bd36007bb87a8a63d`).
  Each behavior is a named publication-required row rather than an inferred dockerd claim.
- A subsequent standalone-runtime audit found that the launcher refreshed the bundled guest agent
  under `~/.dory/bin` while its own `safe` home share deliberately hid `.dory`, causing the guest to
  execute the stale rootfs agent after a release-runtime boot. The launcher now passes the exact
  bundle agent through dory-hv's read-only boot-config share. Bundle, launcher, staged, and running
  guest hashes now match while the different rootfs fallback is demonstrably not selected. The
  fixed standalone runtime passed all **23** rows, including full engine stop/start with unchanged
  container identity, state, and published port, and recorded zero watcher nudge failures or
  reverse-invalidation timeouts. The live bind-lock gate also passed cross-container BSD flock and
  POSIX range-lock exclusion, shared locks, contended Linux-compatible upgrade/retry, blocking
  wakeup, explicit unlock, non-overlapping ranges, and crash release. Its isolated qualifier now
  binds `HOME` to the shared engine tree and requires a real 64-hex digest of the resolved Docker
  CLI. Development evidence (not release-qualifying because the source tree is uncommitted):
  `~/.dory-new-gate-evidence/20260713T-standalone-agent-lock-fixes`.
- A live 2026-07-13 competitor-tracker delta exposed two additional reproducible gaps and both are
  now release-gated. First, Darwin rejected `F_SETFL(O_APPEND)` on the identity descriptor after a
  successful `open(O_CREAT|O_EXCL|O_RDONLY, 0000)`, so Dory returned `EACCES` after creating an
  inaccessible host orphan. HostFS now preserves the creating descriptor without the impossible
  append upgrade when no write bits exist; the exact non-root container creates mode 0000, verifies
  it, and unlinks it, while the complete cross-container lock gate still passes. Second, a fixed
  host port already owned by macOS could be accepted by guest dockerd and retried invisibly by the
  host forwarder. The dataplane now decodes the real chunked inspect response before container
  start, waits through one forwarder reconcile window, and returns a bounded Docker conflict while
  leaving the container stopped. The same start succeeds after the host owner releases the port.
  The expanded current-source campaign first passed **24** rows, including 2,000 connections at
  63→62 aggregate FDs, 20 restarts, full engine restart, and the new collision/recovery row.
  Integrity-checked development evidence:
  `~/.dory-new-gate-evidence/20260713T-mode-zero-statfs-fixes` and
  `~/.dory-new-gate-evidence/20260713T-host-port-collision-fix`.
  The first execution of a 25th cleanup/restart row exposed a real durability failure: the launcher
  signalled gvproxy at the same time as `dory-hv`, cutting the guest shutdown request off before
  dockerd could stop, sync, unmount its data drive, and power off. Deleted Docker objects could then
  reappear after restart. The launcher now keeps the state-owned gvproxy alive until `dory-hv`
  exits, then reaps it. Two focused deletion/restart cycles ended in `powerOff` with zero resurrected
  containers, volumes, or custom networks. The complete current-source **25-row** campaign then
  passed with 2,000 connections at 53→52 aggregate FDs, 20 restarts, two full engine restart paths,
  and the final owned containers, networks, volume, and build image still absent after restart.
  Integrity-checked development evidence:
  `~/.dory-new-gate-evidence/20260713T-cleanup-restart-25-row-fix`.
  A later GitHub delta added Apple container's ignored custom DNS-domain failure. The now-**27-row**
  campaign requires both default resolver search isolation and an explicit standard Docker
  `--dns-search dev.dory.test` entry with a valid nameserver. It also guards Apple container's
  cross-OS signal serialization failure by sending named `USR1` to both container init and a
  detached exec process, requiring both delivery markers while init and Docker stay live. The
  complete current-source rerun passed all 27 rows, 2,000 forwarded connections, 20 restarts, deliberate six-stream
  backpressure with all 12 control probes completing in 0.016 seconds, cleanup/restart durability,
  and three graceful `powerOff` events. Evidence:
  `~/.dory-new-gate-evidence/20260713T-competitor-runtime-27-row-signals`.
  The latest delta adds Apple container #1940's silently discarded virtiofs mount options. The
  **28-row** gate now requires unsupported Docker `:nosuid` syntax to fail promptly with an explicit
  validation error and no partial container, while supported `:ro` must remain `RW=false` in
  inspect, permit reads, reject writes, and leave the host unchanged. The complete current-source
  rerun passed all 28 rows, 2,000 connections with zero FD growth, 20 restarts, cleanup persistence,
  and four graceful `powerOff` events. Evidence:
  `~/.dory-new-gate-evidence/20260713T-competitor-runtime-28-row-mount-options` (archive SHA-256
  `2cad44e4c264dea5202de462df25bf15723f3c0c4939f00a998ace39f6db3b39`).
  The refreshed issue sweep then added Apple container's 16 KiB builder-transport limit and missing
  seccomp support. The **30-row** campaign builds and runs an image from a 65,582-byte Dockerfile,
  verifies the engine advertises seccomp, and applies a custom AArch64 profile that blocks
  `mkdir`/`mkdirat` while reads and Docker control traffic remain live. The complete rerun passed all
  30 rows with 2,000 connections, 20 restarts, and three graceful `powerOff` events. Evidence:
  `~/.dory-new-gate-evidence/20260713T-competitor-runtime-30-row-seccomp-large-dockerfile` (archive
  SHA-256 `bfc4c44b2f0da32c812efd1c39ca99361a2efb89ce63e820a38fbe4af20ed600`).
- Host-share capacity now has an explicit >16 TiB regression. Dory converts Darwin's native
  64-bit `fstatfs` fields directly into FUSE_STATFS and the focused test carries block and inode
  counts above `UInt32.max` without wrapping. Physical external-drive certification still remains
  mandatory because this Mac has no dedicated writable external test volume.
- The live competitor delta also found OrbStack's LAN/DNS stall during transient balloon pressure
  and a rare host `configd` watchdog reboot involving its helper network path, plus Apple
  container's non-healing route/NAT state after VPN or exit-node churn. Dory's raw-HV LAN and
  Sonoma VZ physical gates now keep 960 MiB resident while repeatedly requiring exact remote
  TCP/UDP source identity, responsive Docker DNS/API calls, and bounded macOS `configd` queries.
  Publication verifies the pressure dimensions and PASS fields rather than accepting an unmeasured
  claim. A disposable current-source raw-HV run then held 966.6 MiB resident for 20 fail-fast
  rounds while loopback publication, Docker API, bidirectional container DNS/TCP, and macOS
  `configd` stayed responsive; the pressure process remained running and was not OOM-killed, and
  shutdown ended in `powerOff`
  (`~/.dory-new-gate-evidence/20260713T-memory-pressure-local-20-round`). This validates the
  workload and local probes, not the physical claim: the real peers, Sonoma host, and extended
  host-network soak remain mandatory. The notarized physical sleep gate now additionally requires
  a real configured Tailscale exit node and three explicitly confirmed enable/disable rounds. Host,
  container, and Docker connectivity must remain live while the competing route is active, and the
  exact route/DNS/search/proxy/resolver contract must return after every disable. Publication
  semantically verifies all six churn rows, nonempty Tailscale status artifacts, empty recovery
  diffs, and a hash binding to the private exit-node input. This harness passes offline adversarial
  tests but cannot run here because this Mac has no configured exit node or release VPN.
- Lima's new unattended-start reports exposed one more standalone-supervisor gap: Dory already
  rejected recycled PID files and stale public sockets, but did not rediscover dory-hv or the
  dataplane if the exact helper survived while its PID file was lost. The launcher now matches only
  this HOME's private state/backend/public paths, repairs metadata for a healthy recovered pair,
  and gracefully replaces an incomplete pair; it also clears a stale backend socket and ignores
  zombie processes during its shutdown bound. Offline fixtures prove stale socket/PID cleanup,
  pidfile-less helper recovery, gvproxy cleanup, and that a foreign helper is untouched. A live
  disposable run repaired both deleted PID files without restart, then recovered from a deliberately
  SIGKILLed dataplane through guest `powerOff` and a new healthy Docker API; final shutdown was also
  `powerOff` (`~/.dory-new-gate-evidence/20260713T-stale-supervisor-self-heal`). The start row is now
  correctly a final-artifact blocker because the previously signed five-start candidate predates
  this change.
- Apple container's app-root reports exposed a narrower identity gap in the standalone launcher.
  If `data-drive.path` disappeared while both helpers and Docker remained healthy, an alternate
  `--data-drive` request could previously skip the mismatch check and be reported as already
  running. Recovery now binds the exact live dory-hv PID to this runtime's state/backend paths and
  the complete `--data-drive … --kernel` argument boundary before restoring metadata. The same
  drive repairs without restarting either helper; a different drive fails closed, stays absent,
  and leaves the original Docker API healthy. A read-only Application Support parent also exits
  normally with a path-specific permission error and no partial bundle. The current-source managed
  drive gate then preserved image, stopped-container definition, writable layer, named volume,
  custom network, and their bytes across total transient-runtime replacement, with both shutdowns
  ending in `powerOff`. Integrity-bound development evidence:
  `~/.dory-new-gate-evidence/20260713T-data-drive-identity-fix-final3/20260713T050610Z-3067`.
  The first disposable assembly used an obsolete seed rootfs and correctly failed its second boot
  because that image predated the required ext4 inspection/growth tools. The rebuilt pinned arm64
  guest image passes its provenance verifier and contains `dumpe2fs`, `resize2fs`, and `e2fsck`;
  only the current-asset rerun is counted.
- Selected-drive authority now lives outside replaceable `~/.dory` state and contains the drive
  UUID, external APFS volume UUID, canonical path, and a macOS bookmark. Seven adversarial store
  tests cover runtime-state deletion, missing and mismatched drives, relocation, corrupt records,
  symlinks, hard links, and recovery binding. A real two-image APFS gate renamed the selected
  volume, recovered the new path through the bookmark, rejected an impostor volume with the same
  visible name, and reaccepted the original by UUID. The live Docker gate then repeated the full
  image/container/layer/volume/network cycle, removed all runtime state, restarted without an
  explicit drive argument, and recovered the unchanged selection and workload bytes. These are
  current-source proofs; the same gates remain mandatory for the exact notarized artifact.
- Rust formatting, clippy with warnings denied, and workspace tests passed.
- Release-output, Sparkle key/signature, quarantine, cleanup, compatibility, readiness, benchmark
  safety, and deterministic transfer-image regression tests passed.
- The official `@devcontainers/cli` 0.87.0 passed against a disposable current-worktree engine:
  image resolution, create/start, exec, two-way workspace coherence, and exact object cleanup. This
  version-bound semantic evidence is now mandatory in the long release qualifier and publication
  verifier alongside Testcontainers 12.0.4.
- Checksum-pinned `act` 0.2.89 executed a real workflow on a digest-pinned runner through the same
  disposable engine. The host process used Dory's macOS socket while the runner mounted the
  daemon's guest-local socket; runner execution, two-way workspace coherence, and exact cleanup
  passed. This semantic evidence is also mandatory in release qualification.
- Digest-pinned LocalStack 4.14.0 passed health convergence, S3 bucket/object and SQS queue/message
  round-trips, and exact cleanup. A host `lsof` proof confirmed its requested dynamic port listened
  only on `127.0.0.1`, even though dockerd's normalized guest binding reports a wildcard. The
  release verifier now rejects LocalStack evidence without that non-LAN exposure proof.
- Checksum-pinned Tilt 0.37.5 passed a real `tilt ci` Docker Compose deployment, bounded Docker
  health convergence, two-way workspace coherence, `tilt down`, and exact cleanup. Its version and
  semantic proof set are now mandatory in release qualification.
- Checksum-pinned Supabase CLI 2.109.1 passed its complete default 12-container stack on a
  disposable Dory runtime. All services stayed running, all ten declared Docker healthchecks were
  healthy, Vector reached the guest-local Docker socket, migration/seed data round-tripped through
  Postgres and PostgREST, Auth and Storage were healthy, every published listener stayed host
  loopback-only, `supabase stop --no-backup` succeeded, and Docker objects returned to the exact
  empty baseline. This exposed and fixed pooled Docker-SDK creates bypassing rewrites after streamed
  image pulls; the semantic proof and exact CLI/archive version are now mandatory release evidence.
- Digest-pinned k3s 1.36.2 booted as a privileged nested control plane on the disposable candidate
  runtime. The candidate-bundled `kubectl` observed a Ready node on Linux 6.12.30-dory arm64;
  dynamic API and NodePort listeners stayed on host loopback. Checksum-pinned Skaffold 2.23.0
  deployed, stabilized, served HTTP, and deleted its namespace. Tilt 0.37.5 independently completed
  Kubernetes `tilt ci`, rollout, NodePort HTTP, and `tilt down --delete-namespaces`. The gate then
  restored zero containers, named volumes, and custom networks. Evidence:
  `~/.dory-final-candidate/current-worktree/evidence/kubernetes-tooling-cache-20260712T172920Z-78934/gate-rerun/manifest.txt`.
- The socket-level Auto-Idle proxy passed a 16-client cold-wake herd: every Docker request received
  a complete response, wake state converged, and the engine start command ran exactly once. This
  closes the untested thundering-herd path; final-candidate wake/sleep soak evidence remains.
- The UI test runner passes strict recursive code-signature verification and launches. The earlier
  “damaged” dialog was stale LaunchServices provenance, not an unsigned runner. After the one-time
  macOS UI-automation authorization was approved, the rebuilt `Dory UI Tests` scheme passed all
  eight tests on Apple Silicon: every primary section, create/pull sheet open and cancel,
  onboarding, settings tabs, appearance/theme controls, the machine resource UI's complete
  2→8→1 CPU and 2→16→1 GiB boundary cycle, launch smoke, and launch performance. Expanding
  Advanced now scrolls the controls above the fixed footer instead of leaving their click targets
  obscured. The current Xcode 26.6 rerun passed 8/8 with no failures or skips; five measured launches
  averaged 0.332 seconds with 9.537% relative standard deviation. The xcresult, source/test hashes,
  runner hash, and host/toolchain binding are retained at
  `~/.dory-ui-evidence/20260713T015331Z-xcode-26.6/manifest.txt`.
  Retained result:
  `~/.dory-final-candidate/current-worktree/evidence/ui-tests-20260712T231421Z-51894/result.xcresult`.
- Homebrew cask metadata is prepared and byte-identical in this repository and the sibling
  `homebrew-dory` tap. `brew style` passes. Strict audit is now a mandatory isolated `macos-15`
  workflow job: it downloads the immutable candidate, independently matches the ZIP to the exact
  arm64 SHA-256, stages that version/hash into the cask, runs `brew style` and strict audit, and
  retains commit/run/attempt-bound evidence that publication reparses. This Mac remains on Xcode
  26.6 as requested; Homebrew's Xcode 27 requirement on macOS 27 no longer blocks or changes the
  physical release host toolchain.
- Source-tree `git diff --check` passed, and live migration fixtures were absent from both engines
  after the smoke test.
- The live FD gate completed 25 owned create/start/wait/inspect/log/remove cycles. `doryd` remained
  at 37 descriptors and `dory-hv` at 32; no fixture containers remained. This is a focused
  regression, not a substitute for the required overnight soak.
- A disposable candidate soak exposed a supervisor edge case during forced shutdown: `dory-hv`
  exited but its reparented `gvproxy` child survived. Current source now reaps only a gvproxy command
  carrying both exact private state-socket paths, and the offline regression passes. The endurance
  harness also reserves 2 GiB of free space before each cycle so packaging cannot make evidence logs
  unwritable. The rebuilt exact runtime passed the forced-stop reproduction: after `dory-hv` was
  killed, `dory-engine stop` reaped the state-owned gvproxy and left no helper or socket. The latest
  rebuilt exact runtime repeated this in one second
  (`~/.dory-final-candidate/20260712T035458Z/forced-stop-gvproxy-gate.txt`). Earlier eight-hour runs
  were stopped after migration audits exposed a dangling-image leak and retry-blocking partial
  container edge; they are not counted. The later baseline completed **3,969 PASS cycles over
  exactly 28,800 seconds** with stable resource medians under
  `~/.dory-final-candidate/20260712T035458Z`; it is valuable stability evidence but is superseded by
  later app/release-gate source changes and is not final release evidence.
- A strict same-host Dory/OrbStack readiness run passed with **28 passes, 0 failures**. Both engines
  passed API/system-df, lifecycle/logs/exec/stats, copy/export, bind mounts, volumes, service DNS,
  published ports, BuildKit, Compose, save/load, and resource-update checks; Dory also passed its
  gvproxy VPN-coexistence probe. The run is stored under
  `~/.dory-readiness/20260711T184922Z-22449`.
- A second strict Dory/OrbStack run enabled host-file-to-inotify propagation and passed with
  **29 passes, 0 failures** on both engines (`~/.dory-readiness/20260711T185206Z-27556`).
- All committed guest assets converged and passed deterministic provenance verification: arm64
  headless, arm64 GPU, and amd64. Repeating the arm64 build reproduced the same fingerprint, and
  switching build contexts did not allow one variant to reuse another variant's outputs.
- The exact arm64 0.3.0/18 archive was rebuilt from those assets at clean commit
  `85775703c1eddb77925237fc93c46146ac6bfb8a`. The app and every nested executable, including
  `dory-dataplane-proxy` and `docker-buildx`, pass strict recursive Developer ID verification and
  the clean-Mac bundle/payload checks. All eight manifest artifacts independently match their
  recorded lengths and hashes; the ZIPs and runtime archive pass integrity checks; the mounted DMG
  contains the exact signed app; the SBOM matches the shipped tree; and no XCTest runner or bundle
  appears anywhere. `release-build/Dory-0.3.0-arm64.zip` is 446 MiB with SHA-256
  `70910a277f029f6e03f235cf5ca7821575c4e450573fc01b5bceda4441d2bcb2`; the standalone runtime is
  `7f61afd8aca4cdec45b52136e43bb4ce57493e83aa7abce576dfc8a2fb1533a6`; the DMG is
  `e24674fbcea9d0fc975134511dc117833178e12c8730ec4876d3a653670c2d67`; the lite ZIP is
  `77a8e8d7e3d73720666664b03d2288b49c93395a881d7c6b3d2643088d7926a1`; the app-update ZIP is
  `16414e4c4d7ec3d2f6867c908710b4db5c4d23aa8cf5de5bcbc40304560c2da8`; and the exact-tree SBOM is
  `dde985828413fe724acdc03466a28fb94fb77eaed2be3b1f8ac1c8a0620e98e6`. These are qualification
  artifacts, not distributable artifacts: the manifest is deliberately non-public and the app is
  not notarized or stapled.
- The superseding Apple Silicon public-shape candidate is fully notarized and stapled. Its final
  SHA-256 values are: app ZIP
  `b041287c895f205d8feeab2236eac46f56de863784ae5d2bd552cc2e3850df12`, signed DMG
  `cbb8f652f40a53ca1c66785cd0e1c108e3c4a1deb20e9feb3d59c54d8d379c15`, lite ZIP
  `3c1335141e315e7d52a1c0673eeb34a59bd120f2acd1feff468198263d26d862`, app-update ZIP
  `060372dd3cb2d7bcefd9336ff684a555a4cf32049829032506026ed62ab9b57f`, standalone runtime
  `3628fc4613db5bf42ac1ecb0151eba7c23b9aa6c7e844c16fc1a1b0c88e06e12`, and exact-tree SBOM
  `44c0eac3e9cae57f898973802ec5d5cb369e0a3d114f81d4f9591ff8d1cf935d`. The complete build log is
  `/tmp/dory-public-release-0.3.0-18-06e8c775.log`; independent output validation is retained at
  `/tmp/dory-final-release-output-validation-06e8c775.log`; and exact appcast/archive verification
  is retained at `/tmp/dory-final-sparkle-verification-06e8c775.log`.
- The real Sparkle install gate's safe build-only mode passed against that exact candidate. It
  independently revalidated the manifest-bound app-update ZIP, appcast, SBOM, embedded Ed25519
  key, notarized app, and exact app tree, then built and strictly verified the official
  `sparkle-cli` from the `Package.resolved`-pinned Sparkle 2.9.4 revision
  `b6496a74a087257ef5e6da1c5b29a447a60f5bd7`. The evidence correctly records
  `release_qualifying=false`: no install or relaunch was attempted in this active development
  account. The manifest records the exact update ZIP, appcast, release manifest, SBOM, and gate
  script hashes. It is retained at
  `/tmp/dory-sparkle-build-only-bound-20260714/20260714T071851Z-73452/evidence/manifest.txt`, SHA-256
  `0f2aca6c21be465c4bbbbec4a271f8ebfa884f7aea91831a9e12f80bae7b8f56`. The 338 MiB superseded
  DerivedData build and the earlier unbound proof were removed after the durable evidence was
  captured.
- The exact standalone runtime and Docker CLI from that notarized candidate passed the complete
  **34-row** competitor regression campaign in a fresh isolated 8 GiB/6-CPU engine with FEX
  enabled: 2,000 forwarded connections, 20 container restarts, deliberate six-stream proxy
  backpressure with twelve independent control probes, named signal delivery, host-port collision
  recovery, Compose and full-engine restart continuity, bind/special-file/FD/hard-link semantics,
  healthchecks, DNS/search isolation, named volumes and `docker cp`, concurrent BuildKit sessions,
  image archive/hard-link import, and post-restart cleanup persistence all passed. The retained
  manifest is explicitly bound to candidate source `06e8c77592cc318e971529ada0ec3a93d67bb40a`,
  Docker SHA-256 `2e3639bd136b38821b39ba532098ec86fb68874e86da9450c78e9c3f5dbcdfcf`,
  launcher SHA-256 `38cdba5d153be55871f5f06baa301c2b68d3fc4828aea9d63aa3ed39f30f2385`,
  and every runtime payload hash. Evidence is retained at
  `/tmp/dory-exact-runtime-evidence-20260714T064643Z`; manifest SHA-256 is
  `aeb84256209d52e4ddbdc245c62942c3f02452d1dda6d4c45d5e253baa5474bb` and result-table
  SHA-256 is `cb61f7372b8e75d14192751762ab8b72d350b3dbabf8a0c679902ab9b1d25224`.
  Qualification and publication now reject competitor evidence whose source commit differs from
  the immutable release manifest; ordinary development runs may still default to repository HEAD.
- Four additional standalone gates pass on those same exact candidate bits. Offline boot starts
  from the bundled compressed kernel/rootfs under dead proxies, then starts again after hiding both
  bundle sources with no host TCP dependency (manifest SHA-256
  `476264c4d4147a388cd9906558d5de1ba2ae469c075f628da8aa92c0388cd2f2`). The managed-drive gate
  preserves images, writable container layers, named volumes, and custom networks through total
  transient-runtime replacement while rejecting mismatched, missing, unwritable, concurrent, and
  alias attachments (summary SHA-256
  `074ad46e7099c338ec24a043748163336e5cb83ffeeb3f946db4a05d5846fd0b`). The growth gate safely
  expands a deliberately seeded 16 GiB ext4 image to a sparse 128 GiB image, reclaims allocation
  from 1,217,708,032 to 172,228,608 bytes through boot trim/discard, and preserves its named-volume
  marker across restart (summary SHA-256
  `73680260b620ad1ae09bd35fad4c215400132060c89fc986b548add19c1ca915`). The digest-pinned
  cross-container advisory-lock gate and disposable-key SSH-agent gate both pass; the latter proves
  one plus eight concurrent clients and a network-disabled required BuildKit mount using identical
  public-listing hashes, retains no key text, and binds the exact candidate Docker and Buildx hashes.
  Evidence is retained at `/tmp/dory-exact-offline-boot-20260714`,
  `/tmp/dory-exact-managed-drive-20260714`, `/tmp/dory-exact-data-growth-20260714`, and
  `/tmp/dory-exact-lock-ssh-evidence-20260714T070012Z`.
- A live migration reproduction now covers the user-visible failure where images imported but
  volumes and containers did not. The owned smoke imported image archives, named-volume bytes,
  networks, full create configuration, bind/volume mounts, stopped/running state, and an untagged
  container recovered through a temporary snapshot. Name collisions fail closed instead of
  overwriting unrelated target data. The same real OrbStack migration passed against the exact
  packaged runtime in a blank isolated home. The marker-based harness now requires an acknowledgement
  written only after the Docker fixture finishes, preventing a skipped XCTest from being reported as
  a live pass. A new real-OrbStack run reproduced the exact failure as a daemon-local committed
  image ID that Dory could not resolve after archive load. Writable-layer snapshots now fall back
  to Dory's unique preserved archive tag when the receiving daemon normalizes the image ID. The
  final real OrbStack run passed all **68 migration tests** and preserved the two named volumes,
  network, paused/stopped/running state, writable layer, fixed port, and exact source/target
  baselines. Its strict manifest records every production-path class as `PASS` under
  `/tmp/dory-live-strict-evidence-20260714/manifest.txt`, with the complete run in
  `/tmp/dory-live-strict-20260714-run18.log`.
  The earlier real
  fixture took 18.802 seconds, preserved volume bytes and container settings, returned both engines
  to their original image inventories, and produced
  `~/.dory-final-candidate/20260712T035458Z/live-orbstack-migration/Test-Dory-2026.07.12_03-47-12-+0000.xcresult`
  (copied out of disposable DerivedData before cache cleanup).
  A further regression now forces the deleted-tag/content-ID fallback while copying a named volume;
  it proves the source helper uses the still-valid immutable ID while the target helper uses the
  restored name, preventing an image-success/volume-failure split. If the target daemon normalizes
  that immutable ID, Dory binds the newly loaded dangling image directly and cleans failed-attempt
  candidates instead of leaking disk space or unnecessarily committing the source container. A
  bare source-only content ID is rebound under a valid portable Dory reference, while failed
  start/pause restoration removes only the new partial container so a retry is not name-blocked.
- Persistent engine disks now have two independent protections in current source: the headless
  launcher always supplies a private explicit state directory, and both raw-HV and VZ helpers take
  an exclusive lock before attaching storage. A live two-engine collision was rejected without
  harming the first VM; five isolated cold-start cycles completed in 10–13 seconds, stopped in 3
  seconds, leaked no helper, and left the active disk and protected stopped container unchanged.
  The final exact packaged runtime then rejected a second same-state VM while the first stayed
  healthy (`~/.dfc-final-evidence/state-lock-collision.txt`). The latest rebuilt signed runtime
  passed five fresh-home cycles with 7–14 second starts and 1 second stops at
  `~/.dfc5/20260712T035643Z-68876`.
- Current source also reads the ext4 superblock's declared filesystem length before attaching an
  existing Docker data disk. A disk whose sparse logical tail was truncated by macOS migration or a
  backup tool now fails closed with the actual and required byte lengths; focused valid, truncated,
  and invalid-disk tests pass. The exact packaged runtime rejected a 4,194,304-byte disk whose ext4
  superblock required 8,388,608 bytes before VM attachment; evidence is
  `~/.dory-final-candidate/20260712T030022Z/truncated-disk-gate.txt`.
- Exact-candidate virtiofs passed the Rancher Desktop bind-ownership reproduction: the guest saw
  UID/GID 999, another UID-999 container wrote successfully, and host APFS ownership stayed 501:20.
  Unit coverage includes refreshes, hard links, and host replacement.
- Current source now maps `/Volumes` into both app and standalone guests at the identical path and
  adds fail-fast host-FIFO, 10,000-open FD-stability, and restrictive hard-link runtime cases. The
  gate now requires an operator marker at the dedicated APFS volume root before it may unmount the
  device, rejects missing-drive shadow writes within ten seconds, remounts, and revalidates bytes
  and hard links. Publication still requires those cases on a writable physical external APFS
  drive; no such drive is attached to this Mac today.
- Machine resource updates now reject values outside the UI's 1–8 CPU / 1–16 GiB contract before
  stopping or mutating a machine. The focused 23-test MachineManager selection and 30-test app
  runtime-support suite pass. A new isolated exact-artifact gate cycles 1→8→2 CPUs and
  1→16→4 GiB while verifying guest resources and persistent disk state; it still needs a signed
  candidate with its daemon and machine assets running.
- Required Linux-machine provisioning no longer has a silent-success path. Nonzero and timed-out
  install/verify stages fail, unsupported recipes are rejected before creation, the app removes a
  newly created VM when setup fails, and the legacy container-machine path removes an incomplete
  machine instead of announcing readiness after identity setup failed. The focused Xcode 26.6 run
  passed all 36 machine-provisioning/client tests, including rollback. The exact-candidate machine
  gate now also installs `k8s-lab` and independently verifies `kubectl`, covering Lima #5225.
- The installed app passed a complete amd64 Node/npm BuildKit build/test/runtime smoke. This proves
  common non-native development workflows, not qemu-heavy SQL/Oracle/AVX workloads.
- The installed app network contract passed VPN, explicit DNS, registry IPv4, TCP, UDP, and host
  state preservation. Current source additionally proved TCP publishing on `127.0.0.1` and `[::1]`.
  The exact packaged standalone runtime uses the same Rust Docker-create dataplane and passed VPN,
  explicit DNS, registry IPv4, TCP, IPv6 localhost, UDP, and host-state preservation at
  `~/.dory-exact-candidate/20260712T012352Z/evidence/network-contract/20260712T012615Z-33591`.
  Exact-candidate external IPv6 and physical LAN/Tailscale source-IP certification remain open.
- LAN opt-in no longer risks widening an explicit loopback Docker binding after the guest-side
  compatibility rewrite. The dataplane records a spoof-resistant port-family intent label; live
  `lsof` evidence showed explicit TCP/UDP only on `127.0.0.1`, while a wildcard bind alone listened
  on the LAN wildcard.
- The live stale-bind reproduction passed same-inode shrink/grow/content refresh, atomic
  replacement, and guest-to-host truncation. The destructive isolated prune contract also passed:
  protected running state and volume bytes survived while unused containers, images, networks,
  volumes, and BuildKit cache were removed. Both gates were repeated against the exact packaged
  runtime (`~/.dory-exact-candidate/20260712T012352Z/home/evidence/bind-file-coherence/20260712T012700Z-34993`
  and `~/.dory-exact-candidate/20260712T012352Z/home/evidence/prune-safety/20260712T013219Z-42935`).
- The refreshed bind gate now covers Lima's space-containing mount-path failure and Apple
  container's intermittent direct single-file mount. A current-source disposable runtime kept a
  spaced directory bind and a direct file bind coherent through same-inode shrink/grow/content
  changes. On atomic replacement it matched native Linux exactly: the directory view followed the
  new pathname while the direct bind remained on its original inode; recreating the direct bind
  immediately attached the replacement. A write through the direct file truncated the host file,
  and 20 additional fresh container attachments read the exact final bytes. Shutdown ended in
  `powerOff`; development evidence is under
  `~/.dory-new-gate-evidence/20260713T-spaced-direct-bind-current-final`. This previously standalone
  gate is now part of final qualification, with retained verification of every phase, all host /
  directory / direct size and digest columns, image and Docker CLI identity, and result integrity.
- The standalone public-v1 runtime no longer discovers or imports pre-launch Dory data. A fresh
  isolated runtime proved zero initial containers and volumes before its prune fixtures were
  loaded. The supervisor also rejects planted non-socket paths and unrelated/recycled PID-file
  values.
- The final signed bundle now includes pinned Docker Buildx v0.34.1 and installs Buildx/Compose
  plugins without replacing regular files or third-party symlinks. Using only the candidate's
  bundled Docker and Buildx clients, the exact engine rejected an anonymous private-registry pull,
  accepted login, pulled and ran the image, authenticated a normal `docker build`, kept a random
  BuildKit secret out of image history, pushed, and survived save/load. Evidence:
  `~/.dory-exact-candidate/20260712T012352Z/home/evidence/final-bundle-private-registry/20260712T020743Z-61149`.
- The competitor-derived offline gate and `git diff --check` pass after the latest state-lock,
  binfmt, image-trust, network-contract, and ownership additions.
- The split release workflow passes YAML parsing and semantic Actions linting with the repository's
  self-hosted runner labels declared. Offline release tests reject an invalid source-commit
  binding, altered duration evidence, shortened/unnotarized completion records, a different workflow
  run or attempt, any changed candidate artifact, and a Homebrew SHA that differs from the qualified
  manifest. The long job retains no checkout credential and has no publication permission.
  Every workflow action is commit-pinned; the release and Intel workflows now initialize temporary
  paths through `RUNNER_TEMP` inside steps instead of using the invalid job-level `runner.temp`
  expression that would prevent those hardware jobs from starting.
- The exact-artifact qualifier now runs a disposable two-engine production migration before its
  competitor and duration gates. Retained, tamper-checked evidence is required for images, two
  named volumes, a 64 MiB checksum, metadata/symlink/hard-link preservation, custom IPAM, paused and
  stopped state, writable layers, fixed-port handoff, and exact source/target baseline restoration.
  The same qualifier pins Testcontainers 12.0.4 and requires Ryuk, dynamic-port, HTTP-wait, response,
  and cleanup evidence, plus version-bound Dev Containers, `act`, LocalStack, Tilt Compose,
  k3s/Skaffold/Tilt Kubernetes, and the full default Supabase stack. Offline tests reject recomputed
  hashes when migration, socket, loopback, workflow, Kubernetes NodePort-listener, or Supabase
  guest-socket proof is removed.

## Release blockers

- [x] Finish and converge the deterministic amd64 guest asset, then verify all committed arm64,
  arm64-GPU, and amd64 fingerprints and compressed artifacts.
- [x] Notarize and staple the exact signed 0.3.0/18 arm64 qualification candidate, then validate the
  final ZIP, signed DMG, lite ZIP, self-contained app-update ZIP, appcast, runtime archive, manifest,
  and SBOM. All four Apple submissions are accepted, every ticket validates, the app and DMG report
  `source=Notarized Developer ID`, the DMG has a secure-timestamped Developer ID signature, all
  manifest hashes match, and the exact app-update Ed25519 signature verifies against the public key
  embedded in the shipped app. The candidate is bound to source commit `06e8c775`; it must be
  rebuilt from the final tag after the remaining physical gates.
- [x] Build and validate the final-shape DMG locally with adequate scratch space. Its image checksum
  is valid, it mounts read-only with the signed Dory app and Applications link, the mounted app
  passes strict recursive code-signature validation, and the compatibility DMG is byte-identical.
  The DMG itself is now Developer ID signed with a secure timestamp, notarized, stapled, and
  independently accepted by Gatekeeper as `Notarized Developer ID`.
- [x] Run the exact notarized candidate's complete 34-row Docker/runtime competitor campaign and
  bind its retained evidence to the candidate source commit plus exact Docker, launcher, dory-hv,
  gvproxy, dataplane, kernel, rootfs, and guest-agent hashes. All rows passed and isolated runtime
  cleanup passed. The final tagged rebuild must repeat the same mandatory gate because release
  tooling and documentation commits followed this candidate build.
- [ ] Run the signed-candidate live smoke on a dedicated **physical Apple-silicon** release host
  with Gatekeeper assessments enabled. This development Mac has Gatekeeper assessment disabled and
  cannot provide that trust evidence.
- [ ] Configure repository variable `DORY_EXTERNAL_VOLUME_TEST_ROOT` to a dedicated writable
  directory on physical external APFS media attached to the release runner. Both direct-download
  and Sparkle candidates now fail closed unless that path passes real bidirectional bind I/O,
  restrictive hard links, 64-bit capacity reporting, FIFO fail-fast, 10,000-open FD stability, a 64 MiB checksum, and
  sleep/wake persistence. The operator must also create
  `<volume-root>/.dory-release-external-volume` containing exactly
  `DORY-DEDICATED-RELEASE-APFS-V1`; this is the explicit authorization for the gate to unmount,
  reject missing-drive/internal-shadow writes, and remount that whole dedicated volume.
- [ ] Repeat the exact-candidate cross-container bind advisory-lock gate through both clean
  notarized app paths and long qualification. The exact standalone candidate already passed, and
  current source plus 59 focused
  FUSE tests implement and prove owner-isolated POSIX ranges and BSD `flock`, `GETLK`, blocking
  acquisition, interrupt cancellation, partial unlock, flush/direct-release cleanup, and reset.
  Both notarized app paths and long qualification now require the digest-pinned live gate to prove
  shared/exclusive conflicts, contended upgrade/retry, disjoint ranges, blocking wakeup, explicit
  unlock, forced-container crash release, and mode-0000 exclusive-create/unlink through the real
  guest bind mount.
- [x] Implement Docker Desktop-compatible SSH-agent forwarding without passing host sockets through
  virtiofs. The raw-HV and macOS 14 VZ runtimes now bridge only the configured same-user agent over
  vsock to `/run/host-services/ssh-auth.sock`; host connects reject symlinks/wrong owners and have a
  two-second deadline. The rebuilt arm64 guest agent/rootfs passed provenance verification, and an
  isolated raw-HV live run passed one plus eight concurrent clients with only identity hashes
  retained at `~/.dory-new-gate-evidence/20260713T012556Z-ssh-agent-capped`.
- [ ] Repeat the SSH-agent gate through both exact notarized app paths and long qualification, and
  require fresh-boot plus restart proof on the physical macOS 14 VZ runner. The exact standalone
  candidate passed ordinary and eight-client concurrency plus the required BuildKit SSH mount with
  no retained key text. Publication now binds
  that evidence to `DORY_RELEASE_SSH_CLIENT_IMAGE` and rejects missing or mismatched identity/image
  digests.
- [x] Re-enable macOS UI automation for the rebuilt DoryUITests runner and pass the new machine
  resource-boundary flow. The focused regression and the complete eight-test scheme both passed
  with the Xcode 26.6 toolchain; the retained xcresult above is from the rebuilt runner.
- [ ] Run the exact signed-app machine resource/provisioning gate, which now executes from the clean
  physical candidate smoke, requires a real `k8s-lab` install plus independent `kubectl`
  verification, and hashes the candidate `dorydctl`, kernel, and rootfs. Source validation is green
  and the signed rehearsal contains these changes; exact notarized execution remains required.
- [ ] Run both exact notarized app paths from empty release accounts and prove the clean v1 drive,
  selected-drive authority, full Docker inventory, settings, stop/start persistence, crash
  recovery, and uninstall-without-data-loss contracts. No pre-release Dory state may be discovered
  or adopted. The exact standalone candidate already passed managed-drive persistence, total
  transient-state replacement, attachment locking, and fail-closed missing/mismatched/unwritable
  drive cases; this blocker now covers the two installed-app account paths and uninstall behavior.
- [ ] Roadmap after the Apple Silicon release: run physical Intel validation before publishing any
  Intel or universal artifact. It is not a blocker for the current arm64 release.
- [ ] Configure the dedicated GitHub release runners. A live API check on 2026-07-14 reports
  **zero** self-hosted runners. Release jobs require the `release`, `sonoma`, and `lan` label sets
  in addition to `[self-hosted, macOS, arm64, dory]`. The Apple-silicon release runner also needs at
  least 30 GiB free and a persistent HOME shared by the qualification and fresh-token publication
  jobs, continuous AC power, associated Wi-Fi, and narrowly configured passwordless access to
  `pmset relative wake`/`pmset sleepnow` for the five-cycle physical sleep gate. It must also be
  connected to the release corporate VPN with the configured split-DNS resolver and internal HTTPS
  probe reachable from macOS and containers; missing
  runner-local evidence fails closed.
- [x] Split exact-candidate qualification from publication in the release workflow. The candidate
  job now writes a schema-2 manifest bound to the full source commit, stages immutable artifacts,
  and cannot publish. A separate dedicated-runner job downloads those bits before its token expires,
  first requires the isolated 16→128 GiB growth/discard/persistence gate, disposable two-engine
  production migration, pinned Testcontainers/Ryuk compatibility, the full version-bound
  Dev Containers/`act`/LocalStack/Tilt/Skaffold/k3s/Supabase ecosystem gates, and bounded
  concurrent-backpressure/restart-churn/port-recovery gate plus the digest-pinned two-container
  bind advisory-lock gate, then runs the
  eight-hour endurance and 25-hour dual-path network gates concurrently, and writes an atomic
  runner-local completion record only after both pass. Publication starts in a later job with fresh
  credentials, re-downloads and rehashes the candidate, verifies every retained evidence digest,
  independently parses the growth, competitor, same-connection, managed-machine-to-Docker RTT,
  cycle, and resource-plateau
  results plus run/attempt/commit/duration binding, and now also requires a display-neutral
  `caffeinate -is` assertion with continuous AC-power samples spanning the 25-hour connection.
  It revalidates notarization and Sparkle, and only
  then creates the GitHub release. Offline workflow and fail-closed confirmation regressions pass; executing the path
  still depends on the dedicated release runner and the two duration gates below.
- [x] Reject development-only XCTest runners/test bundles and nonportable runner-local artifact
  paths from the public app, Sparkle archive, and schema-2 release manifest.
- [x] Configure the repository-scoped `HOMEBREW_TAP_DEPLOY_KEY` for `Augani/homebrew-dory`. The
  verified write-enabled public deploy key is installed on the tap and its private half is stored
  only as an encrypted Dory Actions secret; the broad personal OAuth token was not copied. Release
  preflight clones through authenticated SSH and performs a non-mutating dry-run branch push before
  any build starts.
- [ ] Configure the four physical-peer secrets (`DORY_LAN_PEER_SSH`, `DORY_LAN_HOST_IPV4`,
  `DORY_TAILSCALE_PEER_SSH`, `DORY_TAILSCALE_HOST_IPV4`). The digest-pinned
  `DORY_SOURCE_GATE_IMAGE`, `DORY_RELEASE_ALPINE_IMAGE`,
  `DORY_RELEASE_NONNATIVE_BUILD_IMAGE`, and `DORY_RELEASE_SSH_CLIENT_IMAGE` repository variables
  were configured and live-reverified on 2026-07-14; every reference contains an exact `@sha256:`
  digest. The ECR registry/repository/region and repository-scoped GitHub OIDC role variables are
  also configured and live-reverified; no long-lived AWS secret is required. Still set `DORY_CORPORATE_DNS_SERVER`,
  `DORY_CORPORATE_VPN_PROBE_HOST`, and `DORY_CORPORATE_VPN_PROBE_URL`; the URL must use the exact
  split-DNS hostname over HTTPS, `DORY_TAILSCALE_EXIT_NODE` for real exit-node route churn, plus
  `DORY_EXTERNAL_VOLUME_TEST_ROOT` for the marked physical APFS test volume. The live API check
  confirms the tap deploy key is configured, while the five environment-specific variables and
  four physical-peer secrets are absent; the six Developer ID, keychain, notarization, and Sparkle
  secret names are present. GitHub does not expose secret
  values, so the five-minute release preflight validates presence, image pinning, temporary AWS
  identity/repository access, and an authenticated dry-run tap push before any build starts.
- [ ] Execute the real Sparkle updater install/relaunch gate on the exact notarized candidate. The
  release workflow now builds the updater CLI from the `Package.resolved`-pinned Sparkle 2.9.4
  revision, feeds it the byte-identical signed archive, requires the running previous app to exit
  and a different candidate PID to relaunch, compares the complete installed app tree, revalidates
  Gatekeeper, preserves application-support and preference sentinels, restores the lower-build
  fixture, and returns the release account to its initial empty state. Its offline/fail-closed
  tests and pinned-tool build pass locally; exact-candidate execution still requires the clean
  release user with Gatekeeper enabled.
- [x] Pass the exact signed `Dory UI Tests` scheme after the user approved macOS's one-time
  UI-automation request. All eight tests passed with zero failures or skips, including the full
  CPU/memory boundary flow; the retained xcresult is bound to the Apple-Silicon host and records
  the launch-performance measurements. No authentication session was terminated or bypassed.
- [ ] Execute exact-candidate physical sleep/wake with host Wi-Fi/DNS/route integrity. The direct
  notarized-candidate workflow now schedules a 30-second hardware wake and performs five real
  sleeps under the explicit `SLEEP-AND-WAKE-THIS-MAC` token. It binds app/helper hashes and
  commit/run/attempt, and publication rejects short/no-op sleep, missing wake logs, failed cycles,
  changed route/DNS/proxy/resolver contracts, an inactive VPN, a missing configured corporate
  resolver, an unreachable internal HTTPS probe, or mismatched hashed private-network inputs. Each
  cycle also holds a real isolated Dory machine shell open before sleep, disconnects the client
  after wake, and must recover fresh exec plus stop/start with its disk marker intact. The verifier
  binds `dorydctl`, kernel, and rootfs hashes and rejects missing session/reconnect evidence or a
  wedged machine state. The dedicated runner must allow passwordless
  `pmset relative wake` and `pmset sleepnow`; this development Mac is never slept by offline tests.
- [ ] Complete the now-mandatory exact-candidate physical LAN and Tailscale peer gates on both raw
  HV and macOS 14 VZ for the implemented overlap-safe original-source IPv4 contract (TCP, UDP,
  loopback isolation, helper/engine restart, unpublish, PF/route/reference/forwarding cleanup). Also decide
  whether native container IPv6 is a 0.3 requirement; only dual-stack host localhost is proven.
- [ ] Complete an eight-hour resource/file/API soak on the exact final notarized candidate. The
  current source no longer registers whole-home or whole-`/Volumes` FSEvents roots: it observes
  only top-level roots actually resolved by bind traffic. The soak now also fails if host
  `fseventsd` grows by more than 128 MiB across disjoint median windows or ends above 25% median CPU.
  older-app run reached 1,077 successful cycles over about 4.6 hours but became invalid when its
  shell source changed while Bash was still reading it; it is not counted as release evidence. A
  later exact-candidate attempt reached 445 passes before disk exhaustion made its logs unwritable;
  it is also excluded. Two further runs were intentionally stopped when migration audits exposed a
  cross-daemon dangling-image leak and retry-blocking partial-container edge. The rebuilt signed,
  unnotarized candidate passed a three-cycle Compose-heavy plateau preflight. Its later baseline
  completed 3,969 passing cycles over exactly 28,800 seconds with a fail-closed reserve, but source
  changes after that run make it supporting rather than final release evidence.
- [ ] Complete the opt-in 90,000-second same-connection published-TCP, managed-machine-to-Docker
  RTT, and managed-machine outbound-TCP gate on the exact final candidate. This is longer than the
  normal endurance run by design: OrbStack
  [issue #2468](https://github.com/orbstack/orbstack/issues/2468) reports active connections dropping
  at exactly 24 hours, while [issue #2587](https://github.com/orbstack/orbstack/issues/2587) reports
  repeated 200/400 ms service round trips only after uptime. The gate therefore keeps the original
  TCP tuple while a Dory-shaped managed-machine container samples `host.docker.internal` and an
  independently resolved external IPv4 TCP endpoint every 30 seconds. This also covers Rancher
  Desktop #6943's VM-to-host packet drops: publication recomputes local p99/sustained latency plus
  the outbound failure rate and consecutive-failure run from separate raw TSVs. The new eight-second
  current-source run passed all eight local and external samples at
  `~/.dory-new-gate-evidence/20260713T-machine-outbound-short-live` (archive SHA-256
  `571363d475bcbbd5c2221f8777bd7c4596a6125d980d4f112e32a541c99cbaf6`), but cannot close the
  duration edge.
- [x] Remove remote-freshness coupling from cached engine boot. The standalone launcher now accepts
  the prepared local kernel when the compressed source asset is unavailable, but still fails closed
  when both are missing. The mandatory exact-candidate gate boots once from bundled compressed
  kernel/rootfs bytes under dead proxies, hides those source files only in a disposable APFS clone,
  and boots again from the unchanged prepared cache while recording zero host TCP dependencies.
  The exact notarized candidate passed both graceful phases at
  `/tmp/dory-exact-offline-boot-20260714/20260714T065230Z-57984/manifest.txt` (manifest SHA-256
  `476264c4d4147a388cd9906558d5de1ba2ae469c075f628da8aa92c0388cd2f2`), covering Lima #5188's
  cached-image/remote-HEAD failure class with exact runtime payload hashes.
- [x] Make default multi-platform pull/storage semantics publication-bound. The qualifier now starts
  with the digest-pinned fixture absent, pulls it without `--platform`, requires a Linux arm64 image
  and default arm64 container, and re-parses the retained `image inspect`, `/images/json`, and
  `/system/df` records. Image-list and system-df storage bytes must match exactly; Docker's different
  inspect-size definition must remain within a 16× bound and all layer bytes must be attributable to
  the one local image. Current-source evidence passed with a 3.245× cross-definition ratio at
  `~/.dory-new-gate-evidence/20260713T-default-arm64-image-current` (archive SHA-256
  `53482aa679d45644fc4169b17c9796b307e06af6cda86be7ce4fbcaf5608ae95`), covering Apple container
  #1537 without importing its all-platform unpack/storage-reporting failure.
- [x] Add the exact `linux/amd64` Nix 2.34.7 garbage-collection regression without Rosetta. The
  qualifier explicitly enables Dory's bundled non-native runtime, requires the digest-pinned
  image to be absent, pulls the amd64 manifest, creates an unreachable Nix store path, runs
  `nix-collect-garbage --delete-old`, proves that path was deleted, rechecks Docker API liveness,
  and removes the owned image. Current-source evidence passed at
  `~/.dory-new-gate-evidence/20260713T-nonnative-nix-gc-current` (archive SHA-256
  `90a302bc13141272b98801a898f18a6ff915cf25e9535a1dfee13ed6d7d15a5d`), covering OrbStack #2538
  and the no-Rosetta BuildKit expectation in Apple #1825. Exact notarized replay remains required.
- [x] Replace the qemu-user amd64 path with provenance-pinned FEX 2607 and cover Docker plus
  BuildKit's direct runc executor with Dory's fail-closed OCI wrapper. The fresh source-built gate
  pulled the exact digest-pinned Arch amd64 manifest and passed the unmodified
  `RUN pacman -Sy --noconfirm fzf`: alpm installed its nested seccomp filter, switched to the
  sandbox user, installed and ran fzf as x86_64, kept the Docker API live, and removed all owned
  artifacts. Evidence:
  `~/.dory-new-gate-evidence/20260713T-fex-production-final-source/20260713T084212Z-19899/manifest.txt`.
  The qualifier continues to forbid `--disable-sandbox`; final notarized-artifact replay remains
  mandatory.
- [x] Replace package-specific translator fixes with one nested-exec contract. The pinned FEX patch
  now delegates x86 shebangs to Linux binfmt, carries interpreter state only through exceptional
  self-exec, consumes private handoff variables, preserves `execveat` arguments plus null `argv`,
  normalizes merged-root paths, and retains guest seccomp through shell, `/usr/bin/env`, Python, and
  child-ELF transitions. The fresh conformance gate passed the same matrix in BuildKit, Docker run,
  and `docker exec` with only the production x86_64 `POCF` handler registered. The final FEX binary
  is `b862d2a4358b102b125ae50da357b189a5d4710a3be830ef3280cba400c7099b`; exact notarized replay
  remains mandatory alongside the OrbStack #2543 `mmdebstrap` and Apple #1628 pacman gates.
- [x] Make the FEX release input reproducible rather than merely hash-locked. Two forced-fresh
  317-step compilations produced byte-identical FEX/FEXServer binaries and the same 210-package
  inventory from source commit `1cc4b93e7a71c883ec021b71359f136394dc1f3c`, patch SHA-256
  `374eb59a207c0356f548295552f235c0eeadcdbac360a64b01535933a1af8f8a`, Ubuntu snapshot
  `20260713T120000Z`, and source epoch `1783039651`. The app bundler no longer probes the build Mac
  for qemu-user or injects unpinned translator bytes. The rebuilt initfs then passed generic
  BuildKit/run/exec and inherited-seccomp conformance, Nix 2.34.7 GC, Arch's default pacman sandbox,
  OrbStack #2543's exact mmdebstrap command plus a proc-less nested chroot, Node/npm/GNU-tar
  BuildKit and runtime, and all 34 container/volume/network/Compose/restart regression rows. Every
  gate returned the store to zero; prune plus graceful trim reduced the disposable data drive from
  about 11 GiB allocated to 1.1 GiB. Minimal retained evidence is at
  `~/.dory-new-gate-evidence/20260713T-deterministic-fex-final` (72 KiB). This certifies current
  source/runtime architecture, not the still-required notarized public artifact.
- [x] Make the dual-stack gvproxy derivative reproducible instead of letting the build host choose
  a floating Go compiler. The exact-candidate build exposed that `GOTOOLCHAIN=auto` had moved the
  binary hash while the source archive, Dory patch, and tests remained unchanged. The builder now
  requires checksum-database-verified Go 1.26.5, exact `go.mod`/`go.sum` hashes, a read-only module
  graph, fixed arm64/amd64 architecture levels and fat-header alignments, empty user Go
  flags/experiments, and the public Go proxy/sumdb. Three rebuilds produced byte-identical universal hash
  `bd9183f5dbe2bd27d7ea57f2f2dd4d5ce26487eeb1fa8c82cd81bad4df50e0c0`; the first two used
  independent empty toolchain/module/compiler caches, and the full DNS, switch, virtual-network,
  forwarder, and gvproxy tests passed. Release provenance and validation bind the toolchain,
  module files, both thin-slice hashes, and universal hash. Exact notarized-artifact replay remains
  mandatory.
- [x] Certify authenticated manifest PUT and interrupted large-layer upload recovery against real
  ECR on the exact notarized candidate. The first campaign exposed that the isolated credential
  directory also hid Dory's bundled Buildx plugin; the gate now binds and hashes the candidate's
  sibling plugin without retaining credentials. The rerun observed active upload progress, forced a
  nonzero interruption, resumed the 96 MiB layer, repeated the manifest PUT, repulled and ran the
  exact checksum, and proved local image, remote tag, isolated credentials, temporary repository,
  and runtime cleanup. Retained evidence is at
  `/tmp/dory-ecr-exact-evidence-20260714T062401Z/20260714T062417Z-27505/manifest.txt`. A persistent
  empty `dory-release-qualification` repository now has a one-day orphan lifecycle backstop, and
  GitHub uses a main/`v*`-restricted OIDC role scoped only to that repository; no long-lived AWS
  access keys are stored. IAM simulation proves exact-repository allow, other-repository deny, and
  unrelated-IAM deny, and all four GitHub release variables match the provisioned resources.
- [x] Rebuild the signed candidate with transactional migration/backup, daemon-owned recovery and
  Auto-Idle, state locking, virtiofs ownership, standalone dataplane, explicit legacy-state
  isolation, prune/bind-coherence gates, binfmt probe, IPv6 localhost, and bundled Buildx. The
  complete package/signature/inventory rehearsal is current; exact-runtime and physical campaigns
  remain separately tracked above because they must bind the notarized artifact.

## Market-claim guardrails

Do not publish “best in market” or blanket performance/memory superiority claims yet. Existing
evidence supports strong compatibility and migration claims, but some cold workflows are ties,
bind-mounted npm remains a measured weakness, and native IPv6, LAN/source-IP,
and exact-candidate endurance coverage are not complete. Publish only benchmark claims tied to
reproducible campaign output and named hardware.

## Public-release exit criteria

The decision changes to GO only when every release blocker above has an attached artifact, log, or
runner URL; the exact signed/notarized bits pass both clean-v1 live gates; the Homebrew
cask references those same immutable bits; and no P0/P1 failures remain open.
