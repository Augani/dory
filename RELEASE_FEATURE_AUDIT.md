# Dory Apple Silicon release feature audit

Last updated: 2026-07-14

This is the single implementation-review ledger for Dory's first public release. It covers the
Apple Silicon product only. Intel hosts are a later roadmap item and must not be implied by the v1
app, package metadata, or documentation.

`RELEASE_READINESS.md` remains the evidence log for exact artifacts and physical qualification.
`COMPETITOR_ISSUE_COVERAGE.md` remains the traceability matrix from known competitor failures to
Dory release gates. Neither document closes a feature in this ledger by itself.

## Completion rule

A feature is complete only when every applicable box in its section is checked:

- implementation and public behavior have been read end to end;
- invalid input, cancellation, crash, restart, concurrency, and cleanup paths are covered;
- durable/transient data ownership, permissions, privacy, and security boundaries are explicit;
- focused tests cover the contract and the full local suite remains green;
- UI, CLI, diagnostics, accessibility, and documentation describe the behavior accurately;
- the exact release artifact has the required retained evidence, or the item is explicitly marked
  as an external physical gate that cannot be produced on the development Mac.

Comments that explain invariants, compatibility boundaries, or non-obvious safety decisions stay.
Stale comments, comments that merely restate code, disabled code, and obsolete compatibility paths
are removed as their owning feature is reviewed. Cosmetic churn outside the active feature is out
of scope so each fix remains reviewable.

## Current release state

- [x] Build 23 is classified as diagnostic evidence, not a release candidate, after the repeated
  Linux-machine resize exposed an invalid storage attachment following forced shutdown.
- [x] Build 23 is also rejected because its re-signed Sparkle app differs from the direct-app SBOM;
  current release code preserves one exact signed app tree across both delivery paths.
- [x] The build 23 installation and all clean-test Dory user state were removed; OrbStack and Colima
  are stopped.
- [x] Superseded build 21 and build 22 directories were removed (6.9 GB reclaimed).
- [x] Build 23 evidence and `guest/out` are retained for the machine-lifecycle investigation.
- [ ] All feature sections below are complete.
- [ ] One new final-source Apple Silicon candidate is built, signed, notarized, and qualified.
- [ ] No P0/P1 defects remain open and every public claim is backed by exact evidence.

## 1. Distribution, install, update, and removal

- [x] Release/version metadata has one owner and cannot publish stale commit, version, build, hash,
  architecture, or appcast data.
- [x] Developer ID signing, hardened runtime, entitlements, nested-code inventory, notarization,
  stapling, Gatekeeper, SBOM, DMG, ZIP, and update-archive validation fail closed.
- [ ] Direct DMG installation and Homebrew Cask installation work from a clean account with normal
  quarantine and install only Apple Silicon payloads.
- [ ] Sparkle replaces and relaunches the prior app, preserves user data/settings, validates the
  complete installed tree, and uses a same-team atomic replacement with a verified fallback
  restoration path.
- [x] Ordinary uninstall removes the app/runtime integration but preserves the selected Dory drive;
  explicit zap/reset behavior is unambiguous and tested.
- [x] Packaging scripts, workflows, Homebrew tap, README, appcast, and release notes agree.
- [ ] Exact-candidate evidence is retained for both install paths and the real Sparkle path.

## 2. App onboarding, daemon lifecycle, and durable drive

- [x] First launch from an empty account creates exactly one supported v1 layout and does not adopt
  unreleased/foreign Dory state.
  Local source evidence: schema-2 `provisioning` -> `ready` selection publication is resumable on
  either side of drive publication; the exact signed helper passed both interruption points and
  rejected a mismatched drive without replacing either identity. Pre-release records, foreign
  bundles, symlinks, hard links, oversized records, unsafe permissions, and concurrent mutation
  fail closed; the full 354-test core suite passed after removing a diagnostics reread race.
- [x] App, `doryd`, launchd, `dory-hv`, gvproxy, dataplane, and CLI ownership boundaries match
  `ARCHITECTURE.md` with no competing lifecycle owner.
  Local source evidence: signed LaunchAgent helper/resource paths fail closed; app and CLI Dory
  selection cannot fall back to an external or legacy app-owned engine; the headless archive keeps
  private state and process cleanup under `~/.dory/standalone`; ordinary stop/start teardown and
  supervised recovery publish one deterministic owner. The 358-test core suite and 57 focused app
  tests passed, together with the competitor-release and CLI doctor regression gates.
- [x] Always-on, manual, auto-idle, and battery-saver start/wake/sleep behavior is deterministic,
  including concurrent cold-wake clients, app quit/relaunch, daemon crash, and host restart.
  Local source evidence: doryd persists each confirmed running/sleeping transition in lifecycle
  order, restores it for idle-capable modes, always starts Always On, and does not overwrite a
  running intent during terminal shutdown. The daemon remains available after app quit by default;
  explicit opt-out removes its owned LaunchAgent so it stays off at the next login. Battery Saver's
  five-minute cap, policy rollback, idle blockers, stop/wake races, and coalesced wake behavior are
  covered. The full 361-test core suite, 36 focused signed app tests, competitor-release gate, and
  CLI doctor gate passed.
- [x] The selected `.dorydrive` is the sole durable workload store; transient runtime replacement,
  lock contention, missing/replaced drives, permissions, capacity, grow, trim, and relocation fail
  safely without formatting or shadow data.
  Local source evidence: managed-drive and APFS identity gates passed; a real VM preserved a named
  volume across sparse 16 -> 128 -> 256 GiB growth, rejected live growth under the drive lease,
  forced an offline ext4 preen before resize, and published resize/trim evidence.
- [x] App/CLI status, health, repair, logs, and errors identify the failing owner and offer a bounded
  recovery action without reporting requested state as applied state.
  Local source evidence: idle status now joins persisted policy to doryd's live DockerTier state and
  lifecycle history comes only from confirmed engine transitions. App and CLI mutations publish only
  the daemon-confirmed response, preserve the previous value on rejection, and surface its exact
  error. Recovery instructions use installed commands; missing-socket repair fails until doryd
  actually recreates it. Swift and CLI incident writers share a private cross-process lock, reject
  linked files, bound reads, and retain the newest 500 records. The full 364-test core suite, 26
  focused app tests, CLI diagnostics suite, and competitor-release gate passed.
- [ ] Clean install, persistence, crash recovery, uninstall-preserves-data, and alternate-drive
  evidence is retained for the exact candidate.

## 3. Docker Engine API and object lifecycle

- [x] Containers: create/start/stop/kill/restart/pause/exec/logs/attach/wait/health/stats/remove and
  named Linux signal behavior are Docker-compatible and deadline bounded.
  Local source evidence: doryd's Rust dataplane preserves every dockerd route, query, response, and
  streaming boundary except the documented shared-VM create rewrite and bounded host-port start
  preflight. An unavailable/malformed preflight inspection now blocks start instead of failing open,
  while dockerd's own non-200 start errors remain authoritative. The 42-test dataplane suite covers
  named signals, timeout/delete flags, wait/log/stats queries, attach/exec hijack half-close, create
  bounds, keep-alive reuse, and preflight failure. The exact-candidate competitor gate now requires a
  bounded create/start/pause/unpause/interactive-exec/logs/stats/restart/stop/kill/attach/wait/remove
  campaign in addition to named-signal, healthcheck, churn, and backpressure proofs.
- [x] Images: pull/load/save/import/export/tag/inspect/history/remove/prune, multi-platform defaults,
  archive integrity, registry auth, interrupted upload, and default-storage accounting are sound.
  Shipping doryd forwards native dockerd image APIs without translation; the Docker-backed fallback
  now also proxies bounded image metadata/auth/prune/storage requests with their exact target,
  headers, body, status, and flags. Focused Xcode coverage passes all 13 shim server tests. Two
  disposable live Dory runs pass the strengthened private-registry and destructive-prune gates:
  digest-pinned registry pull, rejected anonymous access, login, authenticated pull/run, BuildKit
  auth and secret non-leakage, push, inspect/history, save/load identity, tag/remove, filtered prune,
  active-resource survival, unused-resource removal, cache removal, and owned credential/object
  cleanup. Exact release qualification and publication now require and semantically re-verify those
  manifests with source, fixture, Docker, Buildx, and archive hashes. Existing mandatory gates add
  unqualified arm64 multi-platform selection and storage reconciliation, strict stdout save-tar EOF,
  missing-parent hard-link import/export, and real ECR interrupted-upload resume/repeated PUT/repull.
- [x] Volumes: create/copy/inspect/list/remove/prune, labels/options, ownership, restart persistence,
  collision handling, and in-use safety are sound.
  Shipping doryd preserves native dockerd volume requests. The Docker-backed fallback now proxies
  bounded volume targets, queries, headers, bodies, statuses, and errors without reducing them to the
  UI model. The focused 13-test shim suite proves exact list/create/inspect/delete/prune forwarding.
  A disposable live engine and the integrated competitor gate passed exact driver/options/labels,
  filtered listing, same-name idempotency without mutation, fresh-root emptiness, persisted marker
  bytes, bounded in-use rejection, 1 MiB host-to-volume-to-host copy, API liveness, explicit removal,
  and deletion persistence after engine restart. The mandatory destructive gate separately proves
  active volume bytes survive unfiltered prune while unused volumes are removed, and managed-drive,
  growth, and migration gates cover restart persistence, capacity changes, metadata, and collisions.
- [x] Networks: bridge/DNS/search/aliases/IPAM/options/fixed ports/connect/disconnect/remove/prune and
  restart persistence are sound.
  Shipping doryd forwards native dockerd network APIs; the Docker-backed fallback preserves exact
  list/create/inspect/connect/disconnect/delete/prune targets, queries, bodies, statuses, and errors.
  Focused Swift coverage now exercises the entire rich proxy contract, and the 846-test app suite
  passes. The integrated live gate proves bridge options, internal/attachable flags, explicit
  subnet/range/gateway/auxiliary IPAM, labels and exact filters, duplicate-name and overlapping-subnet
  rejection without metadata mutation, static-IP alias connect, active-endpoint remove rejection,
  disconnect/delete, and published-port liveness. Its separate DNS path keeps primary and two alias
  names network-scoped with the same IP after stop/start. Managed-drive persistence preserves the
  network identity across transient-runtime replacement; unfiltered prune preserves attached networks
  and removes unused ones; cleanup stays deleted after engine restart. Native IPv6, LAN source-IP,
  VPN, physical sleep, and privileged host networking remain explicitly owned by section 6.
- [ ] Cleanup is ownership-scoped and idempotent; failure or cancellation cannot delete unrelated
  objects or leave retry-blocking partial state.
- [ ] Concurrent API/backpressure, restart churn, FD/resource bounds, error mapping, and unsupported
  API/options have focused and exact-artifact coverage.

## 4. Compose and BuildKit/buildx

- [ ] Compose v2 project lifecycle, dependency order, health, profiles, environment, bind/volume/
  network semantics, logs, restart continuity, `down`, and exact cleanup are covered.
- [ ] BuildKit/buildx handles concurrent builds, cache, secrets, SSH mounts, large Dockerfiles,
  cancellation, daemon restart, multi-stage builds, and supported non-native execution.
- [ ] Bundled plugins are version/digest bound, discovered on every supported install path, and do
  not depend on another container product.
- [ ] Failure messages distinguish Docker API, build executor, registry, guest, and host-share
  faults without leaking credentials.
- [ ] Exact-candidate Compose and BuildKit evidence is retained.

## 5. Host filesystem sharing and bind mounts

- [ ] Path lookup, replacement, symlinks, hard links, permissions, virtual UID/GID, read-only mounts,
  nested binds, anonymous child volumes, special files, and unsupported mount options are correct.
- [ ] Host-to-guest and guest-to-host coherence, inotify/FSEvents recovery, overflow, sleep/wake,
  atomic replacement, restrictive modes, and project-root observation are correct.
- [ ] POSIX range locks and BSD `flock` implement independent-owner conflict, blocking, interrupt,
  conversion, unlock, process-death, release, and connection-reset semantics.
- [ ] No whole-home/whole-`/Volumes` watcher, descriptor leak, unbounded queue, blocking FIFO lookup,
  DAX bypass, or stale response publication path remains.
- [ ] Internal and physical external APFS drive behavior has focused coverage; physical disconnect,
  reconnect, capacity, and endurance proof remains explicitly separate.
- [ ] Exact-candidate bind, lock, 10,000-operation FD, and long-soak evidence is retained.

## 6. Container networking, domains, ports, and recovery

- [ ] Loopback-only and all-interface published TCP/UDP, port conflicts, restart/unpublish cleanup,
  host/container reachability, and source-address behavior are deterministic.
- [ ] DNS, search domains, `host.docker.internal`, `*.dory.local`, TLS, resolver files, proxy state,
  default routes, MTU, VPN split DNS, and subsystem repair are bounded and idempotent.
- [ ] IPv4/IPv6 claims match implementation: dual-stack host localhost and native guest/container
  IPv6 are not conflated.
- [ ] Sleep/wake, Wi-Fi changes, VPN changes, Tailscale/exit-node churn, helper/engine crash, and
  24-hour connection behavior have explicit recovery contracts.
- [ ] Privileged networking changes are narrowly authorized, reference counted, restored exactly,
  and never leave PF/routes/forwarding/resolvers behind.
- [ ] Exact-candidate local evidence is retained; corporate VPN, peer LAN/Tailscale, native IPv6,
  physical sleep, and 25-hour proof are marked external until executed on matching hardware.

## 7. Linux machines

- [ ] Names, paths, sockets, images, architecture, CPU/memory/disk limits, create/update/delete,
  start/readiness/stop/restart, and concurrent operations have one validated contract.
- [ ] Graceful guest shutdown uses a real guest service and bounded host protocol; timeout fallback
  cannot race a new VZ attachment or corrupt/reuse storage.
- [ ] Repeated resource reconfiguration preserves disk contents and survives every stop/start; the
  build 23 `VZErrorDomain Code=2` storage-attachment failure has a focused regression.
- [ ] Exec, interactive shell, SSH, mounts, provisioning, cloud-init/user setup, k8s-lab, snapshots,
  import/export, and error recovery are reviewed and tested.
- [ ] Machine networking to host, Docker, LAN, and Internet; port forwarding; sleep/wake; and cleanup
  are reviewed for raw HV and macOS 14 VZ paths.
- [ ] Signed custom-image trust, unsupported-image behavior, guest-agent compatibility, USB/GPU
  scope, and Apple Silicon-only claims are explicit.
- [ ] Exact-candidate resource/provisioning and physical sleep/network evidence is retained.

## 8. Import, backup, restore, and drive relocation

- [ ] OrbStack/Colima/Docker discovery reports every supported image, writable layer, volume,
  network, container definition/state, port, and dependency before mutation.
- [ ] Plan -> quiesce -> stage -> verify -> publish -> validate uses stable source identity,
  immutable plan digest, exclusive mutation lease, durable journal, exact inventory, and legal
  resumable/cancellable transitions.
- [ ] Capacity, collision, active-volume, fixed-port, image-tag, sparse extent, metadata, external
  volume identity, and target-drive checks fail before writes unless explicitly resolved.
- [ ] Cancellation, crash, truncated/corrupt chunks, source changes, target changes, partial publish,
  retry, rollback, and cleanup cannot lose source data or unrelated target data.
- [ ] Backup/verify/restore and drive relocation preserve sparse allocation, hard links, xattrs,
  ACLs, ownership, modes, times, object inventory, and no-overwrite guarantees.
- [ ] Exact-candidate real competitor import and clean-v1 backup/restore evidence is retained;
  external-volume and Migration Assistant/Time Machine proof is separately identified.

## 9. Developer tool compatibility

- [ ] Stable CLI installation, Docker context/socket selection, shell integration, Compose/buildx
  discovery, `dory open`, `dory doctor`, and copy-paste recipes work from both install paths.
- [ ] Dev Containers, Testcontainers/Ryuk, `act`, LocalStack, Supabase, Tilt Compose, Tilt/Skaffold
  Kubernetes, and supported registry workflows are version/digest pinned and clean up exactly.
- [ ] Kubernetes tooling and nested k3s use reachable kubeconfig/context, health/rollout checks,
  loopback-only exposure, and deterministic teardown.
- [ ] Compatibility detection never silently falls back to OrbStack, Colima, or Docker Desktop and
  never widens a listener or socket permission to make a test pass.
- [ ] Recipes, diagnostics, docs, and exact-candidate gates agree.

## 10. Diagnostics, recovery, and support

- [ ] Health classification covers app/daemon/engine/agent/Docker API/network/domain/port/drive/
  filesystem/resource faults with stable severity and actionable ownership.
- [ ] Doctor and support bundles use deadlines, redact secrets/private keys/tokens/private network
  details, avoid unbounded logs, and cannot mutate the system unless repair is explicitly requested.
- [ ] Repair is serialized, idempotent, subsystem-scoped, workload-aware, and reports partial or
  failed outcomes truthfully.
- [ ] Logs rotate or are bounded; crash/restart loops, evidence directories, temporary files, test
  drives, stale sockets, and obsolete release outputs have explicit cleanup policy.
- [ ] UI and CLI expose the same state and recovery contract; tests cover degraded and failed paths.

## 11. UI, settings, menu bar, and accessibility

- [ ] Onboarding, main navigation, containers, Compose, machines, health, settings, sheets, tables,
  empty/loading/error states, destructive confirmation, and menu bar flows match live behavior.
- [ ] Every async action prevents accidental duplication, remains cancellable where appropriate,
  survives view dismissal, and presents applied state or a specific failure.
- [ ] Keyboard navigation, focus order, labels, VoiceOver semantics, contrast, Dynamic Type/text
  clipping, reduced motion, window sizing, and launch performance are reviewed.
- [ ] Settings validation, persistence, partial application, reset, and daemon reconciliation are
  tested; no preference changes a different runtime owner behind the user's back.
- [ ] UI automation runs from a correctly signed runner and covers first launch plus critical
  lifecycle/failure paths without test-only code in the public app.

## 12. Security, privacy, dependencies, and supply chain

- [ ] XPC, Unix sockets, files, helpers, launchd services, privileged networking, SSH agent, image
  manifests, update signatures, and drive locks validate peer/user/path/owner/mode/symlink inputs.
- [ ] Secrets, registry credentials, SSH material, tokens, signing keys, private network data, logs,
  diagnostics, and retained release evidence follow least privilege and redaction rules.
- [ ] Downloads and bundled dependencies are version/digest pinned, reproducible where claimed,
  license/SBOM complete, architecture checked, and rejected on stale or changed provenance.
- [ ] No unsafe development entitlement, test bundle, runner-local path, disabled verification,
  permissive listener, arbitrary code path, or foreign-engine fallback ships.
- [ ] Threat-sensitive parsers and state transitions have adversarial tests and bounded inputs.

## 13. Public scope, documentation, and market claims

- [ ] README, app UI, CLI help, compatibility matrix, architecture, machine-image contract, Homebrew
  metadata, website, changelog, and release notes describe the same Apple Silicon v1 product.
- [ ] Intel is clearly later; unsupported GUI VM, native IPv6, file-share performance, benchmark,
  GPU/USB, and competitor-parity claims are not implied.
- [ ] Competitor issue rows link each advertised behavior to a mandatory gate and distinguish code
  completeness, exact-artifact certification, endurance, and unavailable physical infrastructure.
- [ ] “Best in market” or numeric superiority appears only when a reproducible same-host campaign
  supports the exact claim; known weaknesses and limitations remain honest.
- [ ] Historical/superseded candidate prose is archived or labeled so it cannot be mistaken for the
  final candidate.

## Irreducible external qualification

These do not justify incomplete code. They remain release blockers until the matching environment
exists and the final candidate passes:

- [ ] Five real sleep/wake cycles with associated Wi-Fi and a corporate split-DNS VPN.
- [ ] Dedicated marked external APFS drive disconnect/reconnect, ownership, capacity, checksum,
  lock, persistence, and endurance campaign through both install paths.
- [ ] Physical LAN and Tailscale peers, exit-node churn, and source-address cleanup on raw HV and VZ.
- [ ] Native container IPv6 on the declared macOS version, if retained as a v1 claim.
- [ ] Eight-hour resource/file/API endurance and 90,000-second same-connection/network campaign on
  the exact final candidate while continuously on AC power.
- [ ] Dedicated GitHub runner labels/secrets/variables and final publication workflow dry run.
