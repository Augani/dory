# Dory performance qualification

Performance is a release-evidence contract, not a collection of local screenshots. Dory 0.4 does
not claim to be faster than OrbStack, Colima, or Docker Desktop until a retained run from the exact
notarized candidate satisfies this document. Historical July 2026 results remain useful engineering
context, but they are not current v0.4 evidence.

## Current public result

**Unqualified until the v0.4 candidate campaign runs.** The repository contains the harnesses and
publication gate; it intentionally contains no invented v0.4 numbers. The release job must attach
`Dory-<version>-performance-evidence.zip` to the matching GitHub Release. If that asset is absent,
all comparative performance claims remain unqualified.

## Evidence tiers

Performance work follows this order. A lower tier cannot rescue a failure in a higher tier.

1. **Correctness:** exact host/guest trees, dependency locks, service health, watcher events,
   container teardown, image execution, and durable markers must pass. A fast incorrect sample is
   discarded, not averaged.
2. **End-to-end developer waits:** dependency installation, application build, Compose or
   Testcontainers readiness, hot reload, container lifecycle, cold start, wake, and teardown.
3. **Resource experience:** attributable physical footprint, CPU, memory composition/reclaim, disk
   growth, FDs, threads, watcher backlog, battery, and thermal state.
4. **Subsystem diagnostics:** DNS/TCP/TLS phases, controlled transfers, Docker dataplane latency,
   guest compute, VirtioFS/FSEvents, block flush, network, and idle-loop activity. These locate a
   bottleneck; they are not a desktop-product ranking by themselves.

## Candidate identity and reproducibility

Every release campaign must record and verify:

- source commit, marketing version, build number, release-manifest digest, SBOM tree digest, update
  archive digest, app Team ID, and exact app/helper/kernel/rootfs/guest-agent/component hashes;
- Mac model, chip, RAM, macOS version/build, boot session, power source, low-power mode, thermal
  state, free disk, filesystem, and start/end timestamps;
- engine manager/server/API/kernel versions, architecture, vCPU, guest memory, disk ceiling,
  snapshotter/storage driver, mount mode, and every non-default setting;
- immutable image references and resolved RepoDigests, platform/variant, and ordered RootFS layers;
- exact lockfiles, fixture trees, controlled endpoint identity, command line, environment allowlist,
  harness digest, raw samples, engine order, correctness result, and cleanup result.

Images used for publication must be named with `@sha256:<digest>`. Network endpoints must be
credential-free controlled HTTPS endpoints with a fixed response size. A run is invalid if engines
resolve different content, architecture/CPU differ, guest memory differs by more than 5%, an input
is mutable, the Mac enters thermal throttling or low-power mode, or cleanup leaves run-owned state.

## Required campaign

Run on a dedicated physical Apple-silicon benchmark account. No developer workloads or unrelated
container engines may share that account.

### A. Isolated engine campaign

Install, configure, measure, stop, and purge one engine at a time. Run both:

- **matched:** 6 vCPU and 6 GiB ceiling for every engine;
- **default:** each product's documented fresh-install defaults, recorded exactly.

Measure Dory, OrbStack, and Colima. Dory must be the exact extracted notarized release candidate.
The isolated campaign covers cold start, post-idle wake, warm lifecycle, CPU, internal network,
bind/in-container filesystem work, idle and active footprint, reclaim after teardown, and disk
growth. It cannot claim same-session distribution parity because engines run sequentially.

### B. Interleaved matched campaign

Run all three engines with matched resources and rotate engine order every round. Use at least nine
rounds, so each engine occupies every timing position equally. Required workflows are:

- real npm and pnpm dependency installs with offline, engine-local caches and exact lock/tree checks;
- Rails/Bundler and Composer installs on bind-mounted projects with exact locks and autoload checks;
- cold and cached multi-stage BuildKit builds for native arm64 and `linux/amd64`;
- framework watcher behavior for in-place edit, atomic save, create, rename, delete, and a large tree;
- Compose stack to health, Testcontainers readiness, and teardown;
- warm create/start/exec/stop/remove plus cold engine start and post-idle wake;
- controlled external DNS/TCP/TLS and fixed-byte HTTPS at bounded concurrency;
- internal APFS and separately qualified external APFS bind paths.

The repository's current harnesses divide this work intentionally:

- `scripts/benchmark-user-workflows.sh` — matched, position-balanced npm, lifecycle, host edit,
  synthetic build, stack readiness, and reclaim evidence;
- `scripts/benchmark-developer-workflows.sh` — Rails/Bundler, pnpm, and Composer bind workflows;
- `scripts/benchmark-registry-npm.sh` — cold guest-local npm registry path;
- `scripts/benchmark-external-network.sh` — controlled guest-to-network DNS/TCP/TLS/transfers;
- `scripts/benchmark-campaign.sh` — destructive clean-account isolated/default campaign;
- `scripts/qualify-release-performance.sh` — exact-candidate orchestration, verification, redaction,
  digest manifest, and the release-attachable evidence ZIP.

### C. Reliability and growth

The same release must also publish `Dory-<version>-reliability-evidence.zip`, bound to the same
candidate, with the eight-hour resource/file/API endurance result and greater-than-24-hour
unchanged TCP-connection result. Report start/end process attribution, FDs, threads, watcher
queue/collapse/failure counters, guest memory, disk logical/allocated/used bytes, and Docker object
counts. Any correctness error or linear unbounded growth fails the release; it is not merely a
slower sample.

## Statistics and claims

- Keep every raw sample and report median, p25/p75, min/max, coefficient of variation, and position.
- Use a parity target of median within 10% with overlapping distributions. Describe that as parity,
  not a win.
- A comparative win requires a same-session matched run, overlapping-input proof, at least nine
  valid samples per engine, a median improvement greater than 10%, and non-overlapping bootstrap
  95% confidence intervals. Otherwise publish the measured gap or call it inconclusive.
- Footprint is attributable physical footprint of the full product process set. RSS of one helper,
  `vm_stat` deltas, and generic Virtualization.framework processes are diagnostic unless ownership
  is proven.
- Container-to-container throughput says nothing about the external guest network path. Synthetic
  file storms say nothing about Rails, npm, Composer, or browser HMR unless those workflows ran.
- Do not mix cold pulls with warm lifecycle, or cache generation with offline installation.

## Optimization decision gates

The following are candidates, not assumptions:

| Candidate | Instrument first | Change only when |
|---|---|---|
| Cold-start/wake path | helper launch, kernel boot, root/data mount, guest agent, dockerd, socket publication, first API | The exact campaign identifies one dominant stage or repeated/polling work. |
| VirtioFS create/mkdir or kick collisions | syscall/opcode latency, watcher correctness, host/guest tree checks | Bind developer workflows lose materially and the profile identifies this path without weakening coherence. |
| Thread-per-connection forwarding | accepted/active connections, FD/thread peak, latency, allocation, rejection count | Churn reaches the bounded worker budget or materially increases memory/tail latency; then move to Network.framework or a bounded event loop. |
| High helper CPU | guest compute, VirtioFS/FSEvents, disk flush, network, and idle-loop counters | Attributed samples identify the subsystem instead of treating aggregate helper CPU as a diagnosis. |
| Doctor startup/subprocess cost | probe duration, process launches, duplicated contract count | It affects a user-visible doctor/readiness budget; move that probe into shared typed Swift/Rust code. |

Correctness-first safeguards are not disabled to win a benchmark. Cache, writeback, watcher, or
durability changes require the complete file-coherence and interruption gates before their timing is
eligible.

## Published asset contract

`Dory-<version>-performance-evidence.zip` must contain:

- `manifest.json` with candidate identity, host facts, engine versions/settings, commands, start/end
  times, qualification state, and explicit unavailable rows;
- `sha256.txt` covering every other file in deterministic path order;
- unedited raw result directories from every harness;
- `summary.md` and `summary.json` generated only from the raw rows;
- cleanup and redaction reports.

`Dory-<version>-reliability-evidence.zip` must contain the durable completion record, raw eight-hour
and 25-hour evidence trees, a candidate-binding file, and `sha256.txt` covering every other file.
The Release also publishes the ZIP digest. The publication job verifies both evidence families
against the same source commit, run identity, build, release-manifest digest, and primary archive.

The release workflow re-verifies the performance ZIP and manifest after downloading them into the
publication job and re-verifies the duration completion record before packaging it. Publication is
blocked if a required workflow failed, silently skipped, used the wrong candidate, or lacks raw
evidence. GitHub Actions' temporary artifact is not the stable record; the matching GitHub Release
assets are.

## Historical context, not current evidence

The last retained strategy report records a July 2026 resource-matched cold-registry npm tie
(Dory 2.264 s, OrbStack 2.267 s, Colima 2.313 s), a bind-mounted npm gap that was reduced from about
75% to roughly 3% in the required interleaved protocol, stronger Dory container-to-container
throughput in one synthetic snapshot, and no defensible memory winner. Those results guided the
current harnesses. They must not be presented as v0.4 candidate results.
