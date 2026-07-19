# Dory v0.4 research report

**Research snapshot:** 18 July 2026
**Dory baseline reviewed:** `a711b8e` plus the current uncommitted low-port/Doctor work
**Scope:** OrbStack, Colima/Lima, Docker Desktop, Rancher Desktop, Podman Desktop, GitHub issues,
official release notes/documentation, Hacker News, Reddit, Docker forums, and the current Dory
repository.

## Executive decision

Make v0.4 the **trust release**, with the agent sandbox graduating from preview as its clearest new
product story.

Dory already covers an unusually broad surface: Docker, Compose, Kubernetes, Linux machines and
desktops, snapshots, migration, verified backup/restore, local domains and HTTPS, LAN/Tailscale,
Auto-Idle, repair, MCP, and isolated agent VMs. Adding another broad subsystem now would increase
the number of seams that need qualification. The market evidence points in the opposite direction:
developers are most frustrated when a runtime looks healthy but its socket, mounts, network, or
forwarding are broken; when an update makes data appear lost; or when recovery advice starts with
deleting the VM.

The best v0.4 promise is:

> Dory tells the truth about its state, repairs the failed layer without destroying data, survives
> hostile development workloads, and gives coding agents a real VM with enforceable boundaries.

**Implementation status, 19 July 2026:** the P0 contracts, all six core-v0.4 items, and all three
“if capacity remains” items in this report are now implemented in source with offline/unit coverage.
The post-0.4 items have bounded design records only. v0.4 is still a release **NO-GO** until a clean
notarized candidate produces the physical, long-duration, compatibility, migration, backup,
performance, and upgrade evidence listed below; source completion is not binary qualification.

Before feature work, fix the current contract gaps around migration capacity, USB availability,
release evidence, and security boundaries. Then spend the main v0.4 effort on sandbox enforcement,
stage-level readiness and self-healing, corporate networking, transactional upgrades, and public
performance/reliability evidence.

Do **not** make a full Podman engine, arbitrary ISO boot, MCP catalog, audio, nested virtualization,
or full L2 bridging a v0.4 requirement. Those are valid later bets, but they are not more important
than proving the product already shipped.

## How to read the evidence

- Open GitHub issues with recent reproductions are the strongest evidence used here. An open issue
  is not proof that every user is affected.
- Reaction counts are a snapshot and measure interest, not market size or implementation priority.
- Forum posts are qualitative corroboration. They are useful for language and sentiment, but weaker
  than reproducible tracker reports.
- Competitor issue volume is not a defect-rate comparison: products have different user counts,
  disclosure policies, and tracker hygiene.
- The maintainer confirmed on 18 July, and again on 19 July, that every Dory GitHub issue is fixed.
  Those reports are therefore historical regression signals only. They are not an engineering
  backlog and do not need issue-closing work; the matching behavior still belongs in exact-candidate
  release validation.

## What developers repeatedly complain about

| Pain | Current evidence | What users actually want | Dory implication |
|---|---|---|---|
| A VM says “running,” but the engine is unusable | [Colima #1564](https://github.com/abiosoft/colima/issues/1564) reports a running VM with no Docker socket; [Colima #629](https://github.com/abiosoft/colima/issues/629), [Lima #1609](https://github.com/lima-vm/lima/issues/1609), [Rancher Desktop #1274](https://github.com/rancher-sandbox/rancher-desktop/issues/1274), and [Docker Desktop #142](https://github.com/docker/desktop-feedback/issues/142) show startup, sleep/wake, tunnel, and Resource Saver failures. | Readiness that means the CLI works; a precise failing stage; bounded recovery that preserves state. | Expose VM, guest agent, mounts, network, engine, host socket/context, and Kubernetes as separate readiness stages. Repair only the failed stage. |
| File sharing becomes incorrect or exhausts the host | OrbStack [#2347](https://github.com/orbstack/orbstack/issues/2347) and [#2592](https://github.com/orbstack/orbstack/issues/2592) report FD exhaustion, especially on external mounts; [#2561](https://github.com/orbstack/orbstack/issues/2561) reports missed watcher events/stale metadata; Colima [#1258](https://github.com/abiosoft/colima/issues/1258), [#1341](https://github.com/abiosoft/colima/issues/1341), and [#1569](https://github.com/abiosoft/colima/issues/1569) cover permissions, hot reload, and a 28 GB `fseventsd` incident. | Correct `stat`, rename, unlink, locks, permissions, and hot reload under real concurrency—without a reboot. | Keep Dory's narrow FSEvents roots and correctness gates. Add agent-style tree walks, external APFS, FD slopes, watcher storms, and failure containment to the exact release campaign. |
| VPN, DNS, routes, and forwarding silently break | OrbStack [#702](https://github.com/orbstack/orbstack/issues/702), [#710](https://github.com/orbstack/orbstack/issues/710), [#2334](https://github.com/orbstack/orbstack/issues/2334), and [#2272](https://github.com/orbstack/orbstack/issues/2272); Colima [#1551](https://github.com/abiosoft/colima/issues/1551), [#392](https://github.com/abiosoft/colima/issues/392), and [#583](https://github.com/abiosoft/colima/issues/583); Lima [#4520](https://github.com/lima-vm/lima/issues/4520). | Predictable host/guest/container paths, real client IP where promised, and automatic reconciliation after DHCP, VPN, interface, or sleep changes. | Dory's source-preserving LAN is strategically strong. Prove it on physical peers, add a corporate-connectivity profile, and make route/DNS/proxy provenance visible. |
| Idle CPU, memory, battery, or disk grows mysteriously | OrbStack [#2251](https://github.com/orbstack/orbstack/issues/2251), [#1842](https://github.com/orbstack/orbstack/issues/1842), [#1331](https://github.com/orbstack/orbstack/issues/1331), and [#2030](https://github.com/orbstack/orbstack/issues/2030); Colima [#1543](https://github.com/abiosoft/colima/issues/1543); Rancher Desktop [#2398](https://github.com/rancher-sandbox/rancher-desktop/issues/2398) and [#1942](https://github.com/rancher-sandbox/rancher-desktop/issues/1942). | Attribution, an early warning, safe reclaim, and confidence that “8 TB” or “100 GB” does not mean that many physical bytes are consumed. | Show host physical footprint, guest used/cache/reclaimable memory, FD/thread counts, disk logical/allocated/reclaimable/max, and the process responsible for sustained load. |
| Updates regress behavior or make data appear lost | OrbStack [#2531](https://github.com/orbstack/orbstack/issues/2531), [#2522](https://github.com/orbstack/orbstack/issues/2522), [#2537](https://github.com/orbstack/orbstack/issues/2537), and migration reports [#1146](https://github.com/orbstack/orbstack/issues/1146) / [#1585](https://github.com/orbstack/orbstack/issues/1585); Docker Desktop networking regressions are echoed in [this forum thread](https://forums.docker.com/t/docker-desktop-4-30-0-file-sharing-update-doesnt-work-possible-bug/141350). | Preflight, a known-good snapshot, post-update smoke test, and one-click rollback. | Turn Dory's existing backup/verification primitives into a transactional app/component/data-schema upgrade contract. Do not make reinstall the normal upgrade story. |
| Destructive shortcuts are too easy | OrbStack [#2539](https://github.com/orbstack/orbstack/issues/2539) contains reports of multi-year machines deleted with `Cmd-Delete` and no confirmation. | Exact scope, confirmation, recoverability, and a path back when possible. | Dory already confirms machine deletion and preserves data on uninstall. Audit every keyboard, context-menu, GUI, CLI, migration, prune, component, and missing-drive path to keep that advantage. |
| Docker compatibility is subtly incomplete | Rancher Desktop [#2609](https://github.com/rancher-sandbox/rancher-desktop/issues/2609), Podman Desktop [#13814](https://github.com/podman-desktop/podman-desktop/issues/13814) / [#11294](https://github.com/podman-desktop/podman-desktop/issues/11294), and OrbStack amd64 regressions such as [#2588](https://github.com/orbstack/orbstack/issues/2588) show failures in Testcontainers, Dev Containers, Compose, file editing, and emulation. | A tested compatibility contract, not a generic “Docker compatible” statement. | Publish version-pinned green/red evidence for Compose, Buildx, Testcontainers, Dev Containers, SDKs, LocalStack, Supabase, `act`, Tilt/Skaffold, and native/amd64 builds. |
| Agent tools need safer isolation | OrbStack [#2295](https://github.com/orbstack/orbstack/issues/2295) has roughly 226 reactions for Docker-style sandboxes; [OrbStack's architecture](https://docs.orbstack.dev/architecture) says its isolated machines share a kernel and are not a full-VM boundary against malicious code. | One sandbox per workspace, explicit mounts, controlled network, safe credentials, TTL, rollback, and understandable persistence. | Dory is already ahead with a dedicated VM and no default host shares. Enforced outbound policy and a threat model are the missing pieces that can turn this into a v0.4 headline. |

### What users still praise

The report should not mistake complaint mining for the whole market.

- OrbStack is repeatedly praised for speed, native polish, automatic domains, low-friction Docker
  compatibility, and its Linux-machine experience. Its [official release history](https://docs.orbstack.dev/release-notes)
  shows the breadth users now expect, and [Hacker News](https://news.ycombinator.com/item?id=41421846)
  contains strong compile-time and responsiveness praise.
- Colima is valued for being open, scriptable, lightweight, CLI/YAML-driven, and not requiring a
  dashboard. WordPress's [April 2026 proposal](https://make.wordpress.org/meta/2026/04/18/docker-colima/)
  described a strong five-to-six-month experience.
- Users tolerate a commercial license when the everyday loop is materially faster. Dory being
  open source, local, and broad will not compensate for slower builds, confusing recovery, or an
  engine that feels less polished.

The product bar is therefore **Colima's simplicity plus OrbStack's perceived speed and polish,
with stronger recovery, data safety, openness, and agent isolation**.

## What developers ask competitors to add

Reaction counts below were checked on 18 July 2026 and are directional.

| Request | Demand signal | Dory status | Recommendation |
|---|---:|---|---|
| [Podman support](https://github.com/orbstack/orbstack/issues/88) | ~632 reactions | Dory can detect/manage an external Podman socket and migrate from it, but does not ship a true Podman/rootless backend. | Do not add a second engine in v0.4. Improve the external-Podman story and interview requesters about rootless/security versus CLI preference before committing to a backend. |
| [Custom VM images](https://github.com/orbstack/orbstack/issues/11) | ~462 reactions | Dory offers managed Alpine, Debian, Ubuntu, and Kali profiles; arbitrary images/modules are outside the contract. | Best candidate for v0.5. Start with a safe cloud-image or OCI/rootfs import plus guest-agent/driver preflight, not arbitrary ISO installation. |
| [Docker-style agent sandbox](https://github.com/orbstack/orbstack/issues/2295) | ~226 reactions | Dory already has a dedicated sandbox VM, scoped mounts, TTL, rollback, JSON, and MCP, but `outbound` is not narrowly enforced. | Graduate this in v0.4. It is high demand and mostly built. |
| [MCP Gateway/catalog](https://github.com/orbstack/orbstack/issues/2056) | ~93 reactions | Dory's MCP server controls Dory; it is not a tool catalog/gateway for third-party MCP servers. | Keep the distinction explicit. Consider catalog discovery/config synchronization after the sandbox is stable. |
| [Bridged/L2 networking](https://github.com/orbstack/orbstack/issues/342) | ~91 reactions | Dory's routed, source-preserving LAN access covers web-service/client-IP cases, not every multicast/mDNS/appliance use case. | Research mDNS relay or bounded bridged profiles later; do not let it delay network hardening. |
| [GUI Linux apps](https://github.com/orbstack/orbstack/issues/3) | ~57 reactions | Dory already ships managed Xfce desktops. | Covered. Improve proof, startup, display, and update quality instead of adding more distributions. |
| [GPU acceleration](https://github.com/orbstack/orbstack/issues/1818) | ~47 reactions | Venus/Vulkan is experimental. | Stabilize and benchmark before promoting. Do not market a general GPU contract yet. |
| [Nested virtualization](https://github.com/orbstack/orbstack/issues/1504) | ~29 reactions | Not a current contract. | Later/niche. |
| [Remote Docker GUI](https://github.com/orbstack/orbstack/issues/222) | ~16 reactions | Dory handles local external/custom Unix sockets; remote SSH work is partly present internally but not a normal product flow. | A reasonable later extension, but external demand is weaker than sandbox/custom images. |
| [Build activity/history](https://github.com/orbstack/orbstack/issues/816) | ~17 reactions | Dory streams build work but has no clear persistent build-history product surface. | Good bounded “if capacity” feature: active/history, step timing, cancellation, logs, and cache usage. |

## Dory audit: what is already strong

Dory should explicitly preserve and prove these advantages:

- One self-contained Docker engine with bundled Docker 29 CLI/API, Compose, Buildx, and BuildKit.
- Native container, image, volume, network, Compose, Kubernetes, and machine workflows.
- Managed Linux servers and graphical Debian/Ubuntu/Kali desktops, which cover a prominent OrbStack
  request already.
- Transactional migration from the main Mac runtimes, including volumes, networks/IPAM, writable
  layers, ports, and desired states.
- A managed sparse data drive with growth to 2 TiB, external APFS support, backup, verify, restore,
  and uninstall preservation.
- Linux-machine snapshots, clone, import, and export.
- Localhost publishing, automatic/custom domains, trusted HTTPS, custom bridge subnet, and opt-in
  source-preserving LAN/Tailscale access.
- Narrow FSEvents roots, file-watch recovery, bind-mount correctness gates, FD/capacity tests, and
  advisory-lock coverage already represented in the repository.
- Auto-Idle, targeted repair, dry-run cleanup, redacted support bundles, waits, events, and JSON
  schemas.
- Dedicated agent VMs with no host shares by default, explicit mounts, TTL, rollback, and MCP.
- No account, no telemetry, GPL source, signed/notarized artifacts, a release manifest, and SBOM.
- Signed, removable components with explicit size review and no workload deletion on removal.

The competitive opportunity is not to claim that these exist. It is to make their evidence easy to
inspect and make failure recovery obviously safer than a reset/recreate workflow.

## Genuine current-tree gaps before v0.4

These are independent of the fixed GitHub issues.

### P0.1 — Migration must honor a grown data disk

Migration admission hard-codes 120 GiB usable in
[`MigrationStrictInventory.swift`](Dory/Runtime/MigrationStrictInventory.swift#L57),
[`MigrationStrictCapacity.swift`](Dory/Runtime/MigrationStrictCapacity.swift#L102), and the UI model
in [`MigrationAssistant.swift`](Dory/Runtime/MigrationAssistant.swift#L98). The data disk itself can
grow from 128 GiB to 2 TiB in
[`DockerDataDisk.swift`](dory-core-swift/Sources/DoryOperations/DockerDataDisk.swift#L50).

Result: a user can safely grow Dory to 256 GiB or 2 TiB and still have a large import falsely
rejected at roughly the original 120 GiB floor.

**Fix:** read the selected drive's configured and guest-visible capacity plus current Docker usage;
calculate the safety margin from those facts; offer safe growth in preflight; and test a migration
that exceeds 120 GiB without allocating a huge physical fixture.

Implementation update (2026-07-18): migration admission now derives configured, guest-visible,
used, available, and safety-margin bytes from the selected data drive, offers bounded sparse growth
when needed, and has synthetic above-120-GiB admission coverage without allocating that physical
fixture. Exact-selection migration applies the same calculation only to the selected dependency
closure.

### P0.2 — Make USB truthful or finish it

The README and compatibility guide say USB/IP scan, attach, detach, and replay are available. The
shipping raw-HV engine deliberately throws `guestAgentRPCUnavailable` before attach/detach in
[`EngineMode.swift`](Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift#L653).

**Fix one of two ways:**

1. implement the versioned guest `vhci` RPC and qualify physical devices, restart replay, ownership,
   detach, sleep/wake, and failure cleanup; or
2. disable/relabel the controls and document the current code as host-side scaffolding.

Do not carry the current availability claim into v0.4 unchanged.

Implementation update (2026-07-18): option 2 is complete. Host USB discovery remains supported,
but attach, detach, and replay are disabled and fail closed in the app, CLI, compatibility map, and
agent guide. No guest USB/IP or physical-device claim is made.

### P0.3 — Restore continuously enforced release evidence

Dory has an unusually deep set of competitor-derived scripts, but the current public proof loop is
disconnected:

- `.github/workflows/tests.yml` runs Rust, gvproxy, Swift, app, and disconnected UI suites.
- `scripts/test.sh` does not run the CLI/Doctor/release/competitor-derived contract suites despite
  the README saying it covers CLI contracts and public-repository checks.
- `scripts/ci-test.sh` contains those deeper gates but is not called by the tracked workflow.
- Its competitor gate currently exits 66 because `COMPETITOR_ISSUE_COVERAGE.md` and
  `RELEASE_READINESS.md` were removed while the script still requires them.
- The UI suite explicitly avoids starting the engine, so green UI tests are not installed-runtime
  evidence.

**Fix:** split qualification into three visible tiers:

1. **PR CI:** hermetic unit, CLI/Doctor schemas, safety rails, packaging contracts, and offline
   competitor-derived regressions.
2. **Nightly physical Mac:** installed app, real engine, bind mounts, ports, migration fixtures,
   external drive, sleep/wake, and network transitions.
3. **Release candidate:** exact notarized DMG/Homebrew/Sparkle artifact plus long-duration and
   physical-network gates, with retained manifests and raw results.

Either restore the strategy/readiness documents as maintained inputs or convert the tests to a
tracked machine-readable manifest. A test should not depend on documentation removed from the
public tree.

Implementation update (2026-07-19): the public macOS workflow now runs the full offline contract
suite, including security, destructive-action, release-output, data-drive, competitor-derived,
compatibility, and app tests. Dedicated security, Intel-engine, Pages, pre-publication,
exact-candidate, performance, and physical/duration release jobs are explicit. Readiness and
competitor coverage documents are tracked inputs. The release keeps digest-covered performance and
reliability evidence as permanent matching GitHub Release assets; temporary Actions artifacts are
not the publication record.

### P0.4 — Close the fixed-issue evidence loop

The current worktree contains the low-port replacement and real port 80/443 Doctor probes. Treat
all fixed Dory GitHub reports similarly: reproduce the historical behavior against the exact signed
candidate and retain the result. The maintainer confirms every Dory GitHub issue is already fixed;
this is regression validation, not issue-closing or reimplementation work.

For low ports specifically, cover IPv4/IPv6, another process or account already owning 80/443,
LAN/Tailscale opt-in, connection churn, half-close, sleep/wake, and reconcile races. Expose the
active listener/bind failure in passive network status instead of relying only on an active curl.

Implementation update (2026-07-19): source and offline regression contracts cover the historical
Dory report set, including real standard-port ingress and passive bind provenance. Promotion to
`FULL` remains deliberately blocked on the exact signed candidate wherever the case needs physical
network, sleep/wake, or external-media evidence.

### P0.5 — Audit the Docker control-plane boundary

The guest starts dockerd on its Unix socket **and** unauthenticated
`tcp://0.0.0.0:2375` in
[`EngineMode.swift`](Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift#L942) and
[`guest/initfs/init`](guest/initfs/init#L138). The host's supported Docker path is a same-user Unix
socket relayed over vsock, which is good, and Dory avoids forwarding 2375 to host localhost. The
remaining question is whether an untrusted workload can reach the guest's all-interface 2375
listener through `docker0` or another guest interface.

This report does not assert exploitability without a topology test. It does require a negative
release gate: an ordinary container and LAN peer must not be able to reach the Docker control plane.
If either can, remove the TCP listener, bind it to a dedicated unreachable interface, or add a
fail-closed guest firewall rule. Docker API access is root-equivalent inside the engine VM.

Implementation update (2026-07-18): dockerd now listens only on its private guest Unix socket. The
supported host path remains the same-user `0600` socket and private vsock relay. Static and live
negative gates require an ordinary container and LAN peer to fail when reaching a Docker control
endpoint.

### P0.6 — Reduce avoidable app privileges

The GUI app receives JIT, unsigned-executable-memory, and virtualization entitlements in
[`Dory.entitlements`](Dory/Dory.entitlements#L5), while virtualization runs in narrowly scoped
helpers and the old app-owned VZ backend is retired. Validate a signed build without them, then
remove entitlements the GUI no longer needs.

Also harden the per-user doryd XPC boundary for mutating machine, storage, remote, and network
methods. At minimum validate peer UID; use a signed-client requirement or scoped capability where
it materially reduces risk. This is defense in depth, not a confirmed privilege escalation.

Implementation update (2026-07-18): the GUI no longer carries virtualization, JIT, or
unsigned-executable-memory entitlements; virtualization is confined to signed VMM helpers. doryd
requires the effective user and, in production, Dory's signing/team identity before exporting its
XPC surface, with fail-closed source and unit contracts.

### P0.7 — Add dependency vulnerability policy

Pinned actions, lockfiles, signatures, and an SBOM are strong foundations. The repository currently
has no visible Dependabot/Renovate, dependency-review, CodeQL, `cargo audit`, or `cargo deny`
configuration. Add scheduled review and a release policy for known high/critical vulnerabilities,
with explicit, time-bounded exceptions when no safe update exists.

Implementation update (2026-07-18): weekly Dependabot, pull-request dependency review, Swift and
TypeScript CodeQL, Rust and npm vulnerability audits, and fail-closed source security contracts are
connected to public workflows. High/critical findings block rather than silently downgrade to a
warning.

## Recommended v0.4 scope

### Must ship 1 — Graduate the agent sandbox

Keep the dedicated VM, explicit mounts, rollback, TTL, JSON, and MCP. Add:

- enforceable `none`, allowlisted outbound, and full network modes;
- explicit DNS behavior and blocks for link-local metadata, private LAN, host services, and loopback
  unless individually granted;
- non-root default execution with an explicit elevation path;
- read-only workspace default, with per-path read/write grants;
- ephemeral secret and SSH-agent grants with no raw secret in manifests, logs, or snapshots;
- CPU, memory, disk, process, and wall-time caps;
- persistence semantics: disposable versus named/reused workspace;
- a kill switch and crash-safe TTL cleanup;
- an inspectable run manifest and a concise threat model;
- tests from inside the sandbox proving denied paths are actually denied.

Implementation update (2026-07-18): this scope is now implemented in the CLI, doryd, VMM, guest
agent, kernel contract, MCP surface, public documentation, and exact-candidate release harness. The
enforcement boundary and residual risks are documented in
[`SANDBOX_THREAT_MODEL.md`](SANDBOX_THREAT_MODEL.md); physical negative/positive proof is retained by
[`scripts/sandbox-security-gate.sh`](scripts/sandbox-security-gate.sh). The old preview wording below
is retained only where it describes the repository state observed during the original research.

At research time, `outbound` honestly reported `networkPolicyEnforced=false`; that honesty was
retained until the implementation and inside-VM gate became real. The supported contract now
reports the enforced allowlist mode rather than silently reinterpreting the old label.

### Must ship 2 — Stage-level readiness and self-healing

Model and expose:

`app → doryd → VM process → guest agent → mounts/data disk → network → dockerd → host socket/context → Kubernetes`

Each stage needs a reason-coded state, start/end timing, deadline, and repair owner. Replace the
50 ms promotion polling path with event/condition-driven transitions where practical. A running VM
must never be the sole evidence that Docker is ready.

Recovery should reconnect or replace a dead socket/forwarder, reapply an owned route, restart a
failed guest service, or reselect a temporarily missing data drive without deleting images,
volumes, or machines. The UI and CLI should show the exact mutation before applying it.

Implementation update (2026-07-18): the nine ordered stages are now a versioned
`dev.dory.readiness` contract in doryd, `dory readiness --json`, and the Health screen. Cold start,
wake, and recovery independently prove the helper process, bounded guest-agent RPC, selected data
mount, default route and resolver, dockerd `/version`, host socket/context, and optional Kubernetes
`/readyz`. Timings, deadlines, reason codes, repair ownership, and the non-destructive mutation are
included per stage. The old 50 ms promotion polling is replaced by lifecycle transition waiters.
Socket-forwarder replacement, guest-agent reconnect, dockerd-only restart, owned-route reconcile,
and data-drive identity revalidation retain the VM and durable workloads. Static CI and installed
candidate proof live in [`scripts/staged-readiness-resource-gate.sh`](scripts/staged-readiness-resource-gate.sh).

### Must ship 3 — Corporate connectivity as a product surface

Doctor already detects several proxy mismatches, but remediation often tells users to edit
`~/.docker/config.json` manually. Build one guided, reversible profile that separates:

- macOS system/PAC proxy;
- dockerd pull proxy;
- BuildKit build proxy;
- default container proxy and `NO_PROXY`;
- registry mirrors/insecure registries;
- corporate CA provenance and trust scope;
- VPN split-DNS servers, CNAME/SOA behavior, and subnet collisions.

Reconcile after DHCP, interface, VPN, Tailscale exit-node, and sleep/wake changes. Show which DNS,
route, proxy, and CA each successful or failed probe actually used.

Implementation update (2026-07-18): this is now a versioned
`dev.dory.corporate-connectivity` profile in Settings > Network and
`dory network corporate sample|plan|apply|status|disable`. The model keeps macOS system/PAC,
dockerd, BuildKit, and container consumers explicit; because Docker has one
`proxies.default` value for BuildKit and default container injection, contradictory values fail
validation instead of being silently collapsed. Docker client updates preserve unrelated keys and
restore the exact prior value only while Dory still owns the applied digest. The managed guest
receives proxy, mirror/insecure-registry, and digest-pinned CA material through authenticated RPC on
tmpfs; a changed effective digest restarts only dockerd with live-restore. A privileged container
cannot persist a root-sourced boot file through the Docker data disk.

The reconciler fingerprints the macOS Dynamic Store resolver/route/interface state and runs after
startup, DHCP/interface/VPN/exit-node changes, and explicit sleep/wake. Split-DNS probes query the
declared server directly for SOA, CNAME, A, and AAAA behavior. Registry probes record the explicit
DNS server, resolved route/interface/gateway, selected proxy, and the actual temporary CA bundle
used. Active bridge/VPN collisions fail closed. Static CI and the two-phase physical transition
campaign live in
[`scripts/corporate-connectivity-gate.sh`](scripts/corporate-connectivity-gate.sh).

### Must ship 4 — Transactional upgrade and rollback

The product has signed Sparkle updates and verified data-drive backups, but public upgrade guidance
still centers on uninstall/reinstall. Define one in-place contract:

1. verify free space, component compatibility, drive availability, schema path, and signatures;
2. record last-known-good app/components/config and take or reference a verified data snapshot;
3. update atomically;
4. run socket, Docker API, volume marker, port, and optional Kubernetes smoke tests;
5. roll back app/components/config automatically on failure without downgrading durable data
   blindly;
6. provide an export/recovery route if schema rollback is unsafe.

Implementation update (2026-07-19): `DoryUpgradeTransaction` now provides an owner-only durable
journal for candidate identity, readable schema intervals, preflight, verified snapshot references,
activation, next-launch smoke, rollback, and recovery-required states. Sparkle feed signing and the
Ed25519 enclosure declaration are checked separately from final archive validation. The journal is
armed before Sparkle takes control. Dory quiesces the engine, records the exact prior app/config and
current plus previous verified component generations, and tests Docker API, an immutable volume
marker, the pre-existing container and published port, plus Kubernetes when enabled. A failed smoke
restores the exact prior app/config/component generation only while durable data remains readable;
it never guesses at a schema downgrade. Unsafe rollback writes an owner-only recovery export. The
Updates screen and `dory upgrade status|recovery --json` expose the state. A physical clean-user gate
installs a same-team, Ed25519-signed higher-build fault candidate, activates a second signed
component generation, interrupts at the required smoke, and must prove automatic last-known-good
rollback without changing the volume marker, container, or port before publication.

### Must ship 5 — Resource and storage trust

Add one compact diagnostics surface for:

- macOS physical footprint and process attribution;
- guest used, cache, reclaimable, and configured ceiling;
- file-service FD count, thread count, watcher roots, queue/backpressure, and trend;
- logical, allocated, used, reclaimable, and maximum disk bytes;
- current network routes, resolver provenance, forwards, PF/UTUN ownership, and port conflicts;
- per-stage startup/wake latency.

Alert on a trend before the runtime wedges. A healthy share should not require a full engine restart,
and disk compaction/prune must preview exact objects and estimated recovery before mutation.

Implementation update (2026-07-18): the Health/doctor surface now reports whole-process macOS
physical footprint plus per-process PID/name/FD/thread attribution; guest used/cache/reclaimable/free
memory and its configured ceiling; guest data-filesystem total/used/available; sparse data-disk
logical/allocated/maximum bytes; conservative object-named Docker reclaim estimates; and owned DNS,
resolver, route, low-port, PF, and UTUN facts including bind failures. `dory-hv` publishes a private,
versioned host-share record with its dynamically narrowed watcher roots, pending/maximum queue,
rescan state, delivered/failed batches, and collapse counters. doryd warns on three-sample monotonic
FD, thread, watcher-backlog, or footprint growth before a hard limit. Cleanup remains preview-only
without `--apply`, and the static/live candidate gate requires the full surface.

## Performance: where Dory can become faster

Historical Dory evidence is unusually candid but is no longer present in the simplified public
tree. The last tracked benchmark document at
[`e0448c3`](https://github.com/Augani/dory/blob/e0448c3d6352b4d811296bbd10cdc8d64ffc3eef/BENCHMARKS.md)
recorded:

- a resource-matched cold-registry npm tie: Dory 2.264 s, OrbStack 2.267 s, Colima 2.313 s;
- bind-mounted npm initially about 75% behind OrbStack, then narrowed through correctness/kernel
  work to roughly 3% in the required interleaved protocol, with overlapping distributions;
- a July 8 synthetic snapshot where Dory's CPU and 2,000-file paths were slower than OrbStack and
  Colima, while container-to-container throughput was higher;
- no defensible idle-memory winner.

Those results are useful engineering history, not current v0.3.2/v0.4 release evidence.

### Rebaseline before optimizing

Run the exact signed candidate on one physical Mac with only one engine active at a time, plus a
resource-matched interleaved campaign. Retain raw artifacts, hardware/macOS facts, versions, image
digests, resource settings, temperatures/power mode, failures, and distribution—not screenshots.

Use at least:

- real Rails/Bundler, npm/pnpm, and Composer dependency installs on bind mounts;
- cold and cached multi-stage BuildKit builds, native arm64 and amd64;
- framework hot reload with atomic-save, create, rename, delete, and large tree walks;
- Compose stack to health, Testcontainers readiness, and teardown;
- warm container lifecycle plus cold start and post-idle wake;
- external DNS/TCP/TLS transfers on a controlled endpoint;
- internal and external APFS mounts;
- idle/active CPU, physical memory, reclaim, FD/thread count, battery/thermal, and disk growth.

Correctness failures invalidate timings. Use a target such as “median within 10% with overlapping
distributions” for parity claims, not a single fastest sample. If Dory loses, publish the gap and
optimize the dominant end-to-end wait.

Implementation update (2026-07-19): [`PERFORMANCE_QUALIFICATION.md`](PERFORMANCE_QUALIFICATION.md)
is now the stable public method and deliberately reports v0.4 as unqualified until the candidate
campaign runs. `benchmark-developer-workflows.sh` adds position-balanced, offline, exact-lock
Rails/Bundler, pnpm, and Composer bind workflows to the existing npm, registry, external-network,
and isolated-engine harnesses. `qualify-release-performance.sh` requires a dedicated clean physical
account, immutable images, matched resources, controlled HTTPS endpoints, the exact notarized app,
and destructive confirmation; it runs isolated/default plus matched/interleaved Dory, OrbStack, and
Colima campaigns, fails on skips or correctness errors, verifies cleanup, and emits a digest-covered
`Dory-<version>-performance-evidence.zip`. The release workflow blocks publication, re-verifies the
candidate/SBOM/manifest binding, and attaches that ZIP to the matching GitHub Release. No new v0.4
performance number is claimed before that physical artifact exists.

### Specific optimization candidates

- Instrument cold start by helper launch, kernel boot, rootfs/data-disk mount, guest agent, dockerd,
  socket publication, and first API success; eliminate polling and repeated work from the slowest
  phase.
- Keep correctness-first VirtioFS work. Add create/mkdir syscall and kick-collision profiles only
  after an exact release rebaseline identifies them as dominant.
- The HTTP proxy and new low-port forwarder use a detached OS thread per accepted connection, with
  budgets up to 256. Measure thread/FD/memory/latency under churn; move to Network.framework or a
  bounded event loop if that model becomes the bottleneck.
- Split guest compute, VirtioFS, FSEvents, disk flush, network, and idle-loop CPU in diagnostics so
  an “800% helper” report immediately identifies the subsystem.
- Consolidate the 4,000+ line Python Doctor into typed shared Swift/Rust probes over time, leaving a
  thin CLI. This reduces subprocess cost and contract drift.
- Remove the retired app-owned engine path after one final migration/recovery gate and split very
  large coordinator files. A single production architecture will make startup, entitlement, and
  recovery work easier to optimize.

## Exact v0.4 release gates

The earlier tracked readiness matrix at
[`e0448c3`](https://github.com/Augani/dory/blob/e0448c3d6352b4d811296bbd10cdc8d64ffc3eef/RELEASE_READINESS.md)
recorded several physical/duration gates as not yet closed at that snapshot. The current repository
contains harnesses for many of them, but no current public, retained exact-v0.3.2 result set was found.
That does not prove the tests never ran; it means v0.4 should make the evidence visible again.

Block v0.4 until the exact notarized candidate passes:

1. clean install and in-place upgrade through DMG, Homebrew, and Sparkle, preserving a versioned
   volume/container/machine/Kubernetes fixture;
2. all previously fixed Dory reports, including the real 80/443 ingress path;
3. eight-hour resource/file/API soak with no correctness error or linear FD/thread/FSEvents-memory
   growth;
4. more than 24 hours on one unchanged published TCP connection, while a managed machine also
   reaches Docker and an external endpoint;
5. five physical sleep/wake cycles with engine, machine session, mounts, DNS, routes, VPN, and ports;
6. physical external APFS bind I/O, unplug/missing-drive refusal, remount/recovery, locks, capacity,
   FD stability, and backup/restore verification;
7. physical corporate split DNS, PAC/manual proxy, MITM CA, VPN connect/disconnect, and Tailscale
   exit-node/subnet-route churn;
8. physical LAN/Tailscale TCP and UDP with verified original source IP, overlap handling, restart,
   unpublish, and complete PF/route cleanup;
9. macOS 14 VZ fallback and the current macOS raw-HV path, including SSH-agent restart replay;
10. native and amd64 BuildKit/runtime fixtures, Compose, Dev Containers, Testcontainers, LocalStack,
    Supabase, `act`, Tilt/Skaffold, and k3s API stability;
11. migration above 120 GiB after safe data-disk growth, plus interruption and source-nonmutation;
12. sandbox negative tests for mounts, secrets, private/LAN/metadata addresses, DNS, TTL, rollback,
    and resource caps;
13. Docker control-plane negative access from an ordinary container and LAN peer;
14. interrupted app/component update and automatic last-known-good rollback;
15. destructive keyboard/menu/CLI action audit with explicit confirmation or recoverable undo.

Every artifact should identify source commit, app/helper/kernel/rootfs/component hashes, host facts,
test configuration, start/end time, and raw results. Missing hardware/network inputs should produce a
visible unqualified claim, not a silent skip.

## Prioritized work order

### Now, before the v0.4 branch expands

1. Fix dynamic migration capacity.
2. Resolve USB claim versus implementation.
3. Reconnect the hermetic competitor/release gates to public CI and restore a maintained evidence
   manifest.
4. Exact-artifact regression-test the behavior described by Dory's already-fixed historical reports.
5. Prove containers cannot reach unauthenticated dockerd TCP; fix if reachable.
6. Remove unnecessary GUI entitlements, harden XPC peers, and add dependency scanning.

### Core v0.4

7. Graduate the sandbox with enforced egress, non-root default, safe secrets, caps, and threat model.
8. Add reason-coded staged readiness, event-driven waits, and targeted self-healing.
9. Ship guided corporate proxy/CA/VPN/DNS configuration and reconciliation.
10. Ship transactional update preflight, smoke test, and last-known-good rollback.
11. Add resource/FD/watcher/disk/network attribution and early warnings.
12. Publish exact, reproducible performance and long-duration qualification artifacts.

### If capacity remains

13. Add build activity/history and cache visibility. **Implemented:** Dory now has a Build Activity
    surface for Dory-launched Buildx work, durable history, cache usage, logs, and cancellation.
14. Add partial migration selection and a completeness report, retaining transactionality.
    **Implemented:** users can select an exact object set; dependencies are closed automatically;
    capacity, collision, portability, transfer, rollback, and final source-completeness checks apply
    only where appropriate; the completion report proves selected, imported, verified, and deliberately
    omitted objects. Omitted source objects are re-inventoried before success so partial import cannot
    conceal concurrent source drift.
15. Finish durable scheduled backups with retention and periodic restore verification; do not ship
    the existing model scaffolding without a scheduler and recovery proof. **Implemented:** doryd owns
    an owner-only crash-recoverable schedule database, creates and re-import-verifies local
    `.dorymachine` recovery bundles, performs a disposable boot check on the first and configured
    periodic runs, atomically publishes only verified archives, and retains only scheduler-owned
    snapshots/archives. The app and `dory machine backup` commands expose scheduling, status, run-now,
    and disable controls. Remote or S3 backup is not claimed.

### Design now, likely ship after v0.4

16. Safe custom cloud-image/OCI-rootfs import.
17. MCP tool catalog/gateway distinct from Dory's control MCP.
18. Remote Docker/workspace UI over SSH with persistence, offline/reconnect behavior, key management,
    conflict UX, and a threat model.
19. Manual/bulk image update checks with health-verified rollback.
20. mDNS/multicast or bounded bridged profiles for appliance/HomeKit workloads.
21. Stabilized Venus/Vulkan GPU contract.

The implementation deltas, threat models, promotion gates, and recommended order for items 16–21
are now captured in [`POST_V0.4_PRODUCT_DESIGNS.md`](POST_V0.4_PRODUCT_DESIGNS.md). These are design
records, not 0.4 capability claims.

### Defer unless Dory users produce stronger evidence

- full Podman/rootless engine backend;
- arbitrary ISO installation and custom kernel modules;
- audio passthrough;
- nested virtualization;
- custom Kubernetes CNI or multi-node clusters;
- static machine IPs where stable names solve the workflow;
- CRIU parity;
- Intel releases before dedicated physical qualification.

## Product and documentation cleanup

- Publish one current architecture document: app, doryd, raw-HV helper, macOS 14 VZ fallback,
  guest agent, dataplane, network helper, data drive, and trust boundaries.
- Update the ContainerizationEngine and Rust READMEs, which still contain retired/prototype
  architecture language, and quarantine or remove orphan source paths after confirming no build
  dependency.
- Make every public capability one of **supported**, **preview with exact limitation**, or
  **unavailable**. USB currently violates this rule; sandbox outbound correctly reports its limit.
- Keep benchmark and qualification results in a stable public location, separate from strategy prose
  that may be simplified later.
- Validate links and capability claims in CI.
- Do not describe `scripts/test.sh` as covering contracts it does not execute.

Implementation update (2026-07-19): [`ARCHITECTURE.md`](ARCHITECTURE.md) is now the production
source of truth for Dory.app, doryd, raw-HV, Sonoma VZ, the shared Rust dataplane/guest protocol,
gvproxy/network helper, data drive, updates, and trust boundaries. The ContainerizationEngine,
Rust, and Swift READMEs no longer describe a future re-platform. The two excluded, unreferenced
prototype paths (`ContainerizationVMEngine` and `dory-vmboot`) were removed after confirming they
were neither SwiftPM targets nor build dependencies. The app's environment escape hatch to the
retired app-owned engine was removed; external/custom Docker sockets remain explicit backends.
README capabilities now use supported/preview/unavailable language, transactional upgrade guidance
replaces uninstall/reinstall, performance evidence has a stable contract, and `scripts/test.sh` is
described only as the suite selector it actually is.

## Source index

### OrbStack

- Official: [documentation](https://docs.orbstack.dev/),
  [architecture](https://docs.orbstack.dev/architecture),
  [release notes](https://docs.orbstack.dev/release-notes), and
  [FAQ](https://docs.orbstack.dev/faq).
- Filesystem/resources: [#2251](https://github.com/orbstack/orbstack/issues/2251),
  [#1842](https://github.com/orbstack/orbstack/issues/1842),
  [#2347](https://github.com/orbstack/orbstack/issues/2347),
  [#2592](https://github.com/orbstack/orbstack/issues/2592),
  [#2561](https://github.com/orbstack/orbstack/issues/2561),
  [#2112](https://github.com/orbstack/orbstack/issues/2112),
  [#1342](https://github.com/orbstack/orbstack/issues/1342),
  [#1331](https://github.com/orbstack/orbstack/issues/1331), and
  [#2030](https://github.com/orbstack/orbstack/issues/2030).
- Networking/lifecycle: [#342](https://github.com/orbstack/orbstack/issues/342),
  [#814](https://github.com/orbstack/orbstack/issues/814),
  [#710](https://github.com/orbstack/orbstack/issues/710),
  [#702](https://github.com/orbstack/orbstack/issues/702),
  [#2334](https://github.com/orbstack/orbstack/issues/2334),
  [#2272](https://github.com/orbstack/orbstack/issues/2272),
  [#2468](https://github.com/orbstack/orbstack/issues/2468), and
  [#2531](https://github.com/orbstack/orbstack/issues/2531).
- Safety/features: [#2539](https://github.com/orbstack/orbstack/issues/2539),
  [#88](https://github.com/orbstack/orbstack/issues/88),
  [#11](https://github.com/orbstack/orbstack/issues/11),
  [#2295](https://github.com/orbstack/orbstack/issues/2295),
  [#2056](https://github.com/orbstack/orbstack/issues/2056),
  [#1818](https://github.com/orbstack/orbstack/issues/1818), and
  [#488](https://github.com/orbstack/orbstack/issues/488).

### Colima, Lima, and adjacent runtimes

- Colima lifecycle/network: [#1564](https://github.com/abiosoft/colima/issues/1564),
  [#629](https://github.com/abiosoft/colima/issues/629),
  [#1551](https://github.com/abiosoft/colima/issues/1551),
  [#392](https://github.com/abiosoft/colima/issues/392), and
  [#583](https://github.com/abiosoft/colima/issues/583).
- Colima filesystem/resources: [#1569](https://github.com/abiosoft/colima/issues/1569),
  [#1543](https://github.com/abiosoft/colima/issues/1543),
  [#1258](https://github.com/abiosoft/colima/issues/1258),
  [#1341](https://github.com/abiosoft/colima/issues/1341), and
  [#83](https://github.com/abiosoft/colima/issues/83).
- Colima releases: [v0.9.0](https://github.com/abiosoft/colima/releases/tag/v0.9.0),
  [v0.10.0](https://github.com/abiosoft/colima/releases/tag/v0.10.0),
  [v0.10.2](https://github.com/abiosoft/colima/releases/tag/v0.10.2), and
  [v0.10.3](https://github.com/abiosoft/colima/releases/tag/v0.10.3).
- Lima: [#1609](https://github.com/lima-vm/lima/issues/1609),
  [#4520](https://github.com/lima-vm/lima/issues/4520),
  [#3604](https://github.com/lima-vm/lima/issues/3604),
  [#4053](https://github.com/lima-vm/lima/issues/4053), and
  [#3775](https://github.com/lima-vm/lima/issues/3775).
- Rancher Desktop: [#1274](https://github.com/rancher-sandbox/rancher-desktop/issues/1274),
  [#9839](https://github.com/rancher-sandbox/rancher-desktop/issues/9839),
  [#2259](https://github.com/rancher-sandbox/rancher-desktop/issues/2259),
  [#2398](https://github.com/rancher-sandbox/rancher-desktop/issues/2398), and
  [#2609](https://github.com/rancher-sandbox/rancher-desktop/issues/2609).
- Podman Desktop: [#17249](https://github.com/podman-desktop/podman-desktop/issues/17249),
  [#13814](https://github.com/podman-desktop/podman-desktop/issues/13814),
  [#11294](https://github.com/podman-desktop/podman-desktop/issues/11294),
  [#3311](https://github.com/podman-desktop/podman-desktop/issues/3311), and
  [#12830](https://github.com/podman-desktop/podman-desktop/issues/12830).
- Docker Desktop: [release notes](https://docs.docker.com/desktop/release-notes/),
  [#142](https://github.com/docker/desktop-feedback/issues/142),
  [#204](https://github.com/docker/desktop-feedback/issues/204),
  [#195](https://github.com/docker/desktop-feedback/issues/195), and
  [#168](https://github.com/docker/desktop-feedback/issues/168).

### Forums and qualitative corroboration

- [OrbStack discussion and praise on Hacker News](https://news.ycombinator.com/item?id=41421846).
- [OrbStack user discussion on Reddit](https://www.reddit.com/r/docker/comments/193juvr/has_anyone_tried_orbstack/).
- [Colima freeze/recreate report on Reddit](https://www.reddit.com/r/docker/comments/1cr5y0h).
- [File synchronization and runtime discussion on Hacker News](https://news.ycombinator.com/item?id=38137630).
- [Docker Desktop file-sharing regression discussion](https://forums.docker.com/t/docker-desktop-4-30-0-file-sharing-update-doesnt-work-possible-bug/141350).
- [WordPress Colima proposal and positive counterexample](https://make.wordpress.org/meta/2026/04/18/docker-colima/).

## Final recommendation

The strongest v0.4 launch is not “Dory has more checkboxes.” It is:

1. the current claims are true on the exact artifact;
2. a broken seam is identified and repaired without deleting the environment;
3. files, memory, network, updates, migration, and long-lived connections remain correct under
   stress;
4. agent execution has a real VM boundary with enforced mount, network, credential, and lifetime
   controls; and
5. Dory publishes the raw evidence.

That position attacks the most painful recurring weaknesses across every competitor while leaning on
work Dory has already done. Custom images are the best next expansion after that foundation is real.
