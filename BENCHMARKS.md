# Dory Benchmarks

Dory publishes benchmarks as raw, reproducible runs, not screenshots. Every public number should
come with the machine spec, the command used, raw TSV/JSON output, and a note about which engines
were installed and running on the same Mac.

The main harness is [`scripts/benchmark-compare.sh`](scripts/benchmark-compare.sh). It compares Dory
against Docker Desktop and OrbStack by default. Apple's separate `container` CLI can be added as an
optional competitor on macOS 26+ hosts, but it is not part of the default 0.3 release benchmark.

## User-Facing Benchmark Priority

Public product claims and optimization decisions must follow this order. A lower tier may explain a
result, but it cannot override a failure or regression in a higher tier.

1. **Correctness and reliability gates:** real package installs must finish, host and guest trees
   must match, recursive cleanup must succeed in one pass, containers must stop when requested, host
   edits must reach Linux watchers, images must execute under their configured user, and service
   stacks must become healthy. A failed gate means no performance result for that workflow.
2. **End-to-end developer workflows:** dependency install/reinstall on a bind-mounted project,
   framework hot reload after an editor-style host change, cold image pull plus verified execution,
   uncached and cached application builds, Compose-stack startup to readiness, warm container
   lifecycle, and project teardown. Timers include the Docker operation users wait for.
3. **Resource experience:** idle product footprint, memory under representative stacks, reclaim
   after teardown, sustained CPU overhead, battery/thermal impact, and disk growth/cleanup. Process
   attribution and repeated samples are mandatory for comparative claims.
4. **Component diagnostics:** DNS/TCP/TLS phases, fixed-byte transfers, FUSE opcode latency,
   container-to-container throughput, synthetic file storms, and checksums. Use these to locate an
   end-to-end bottleneck; do not market them as a better desktop experience by themselves.

Do not headline `touch`, raw iperf, sha256, or a single CDN request. Do not accept a fast failure,
partial output tree, stale cache, wrong-platform image, or unkillable container as a timing sample.
Every competitive run is same-session, resource-matched, position-balanced, immutable-input
verified, and keeps raw correctness evidence alongside timings.

## Nine-Round Workflow Comparison

The [workflow harness](scripts/benchmark-user-workflows.sh) is the stricter Dory/OrbStack/Colima
comparison for dependency-install and desktop file-sharing work. The publication run is:

    scripts/benchmark-user-workflows.sh --engines dory,orbstack,colima --rounds 9

It fails closed unless all engines report the same architecture and CPU count, their guest memory
totals are within 5% (configurable with BENCH_ENGINE_MEMORY_TOLERANCE_PCT), and every requested image
resolves to the same immutable RepoDigest, OS/architecture/variant tuple, and ordered RootFS layer
fingerprint. Docker image IDs remain diagnostic because classic and containerd image stores can expose
different IDs for the same immutable content. Nine rounds are position-balanced by cyclically rotating
engine order; the harness rejects a round count that is not a multiple of the engine count.

The npm fixture is isolated per engine. Each engine independently generates the comparison lock with
its own throwaway cache, and all lock hashes must match before one canonical lock is copied into the
projects. Each timed run removes node_modules through an untimed container on that engine's bind mount,
then confirms absence on both host and guest before running npm ci with both --offline and Docker
networking disabled. VM-local npm caches are separate and
warmed once per engine. CPU and memory limits are identical. The timer includes Docker
create/start/remove but excludes host/guest tree verification; exact lock hashes, dependency versions,
npm ls, executable symlinks, and host/guest file, directory, and symlink counts are required after
every sample.

Lifecycle numbers are warm-engine, warm-image container lifecycle numbers, not VM or daemon startup.
Build numbers are uncached synthetic overlay/snapshotter work with no network step, not an application
build. Host-edit polling is a bind-mount round trip. The untimed Node fs.watch gate proves delivery of
one in-place host content edit only; it does not claim create/delete/atomic-save coverage or
framework/browser HMR latency. Timed child commands use CLOCK_MONOTONIC. Raw round, position, image,
resource, app-binary, lock, and worktree provenance is retained under a unique run directory.

The two-service process-footprint rows are diagnostic only. They are one fixed-order observation,
process matching is approximate, privileged helpers can be unreadable, and a generic
Virtualization.framework XPC process cannot always be assigned to the correct product while several
VMs are running. Do not rank engines or publish a memory winner from those rows.

## External Network Comparison

The container-to-container iperf result does **not** measure Dory's external network path. Dory can
short-circuit traffic between containers inside its shared VM, while internet traffic crosses the
guest interface and `VirtioNet`/gvproxy. Use the separate
[`scripts/benchmark-external-network.sh`](scripts/benchmark-external-network.sh) harness for claims
about DNS, TCP, TLS, HTTPS downloads, or bounded-concurrency external transfers.

The harness requires an explicitly digest-pinned curl image and two HTTPS endpoints: a small probe
and a fixed-size download. The exact image must already be present in every engine; the harness uses
`--pull never`. Use an endpoint you control, choose a payload size the server returns without
content encoding or redirects, and do not embed credentials in either URL because both URLs are
written to provenance. Fixed-download traffic per engine is `rounds × (1 + 8 + 32) × bytes`, plus
the small handshake probes, so inspect the dry-run and calculate transfer cost before going live.
For example, substituting a real immutable digest and your own endpoints:

```sh
scripts/benchmark-external-network.sh \
  --engines dory,orbstack,colima \
  --rounds 9 \
  --image 'curlimages/curl@sha256:<64-hex-image-index-digest>' \
  --probe-url 'https://network-bench.example/probe' \
  --download-url 'https://network-bench.example/payload-1048576.bin' \
  --download-bytes 1048576 \
  --dry-run

# Remove --dry-run only after independently loading that exact image into every running engine
# and confirming all engines have the intended CPU and memory allocation.
```

The live preflight fails closed unless every requested engine is already reachable, uses the same
architecture and CPU count, has guest memory within 5%, exposes a bridge network, and resolves the
pinned image to the exact requested RepoDigest, platform tuple, and ordered RootFS layer fingerprint.
Store-dependent Docker image IDs are retained as diagnostics but are not compared. The harness never
invokes an engine start, stop, or configuration command. Rounds must be a multiple of the engine count.
Each workload rotates engine order independently, so every engine occupies every timing position
equally; workloads are interleaved rather than running one complete engine campaign at a time.

One fresh HTTPS connection yields raw curl timestamps for name lookup, connect, and TLS completion.
The reported DNS, TCP, and TLS phase durations are respectively `time_namelookup`,
`time_connect - time_namelookup`, and `time_appconnect - time_connect`; they are phase breakdowns of
the same request, not three protocol microbenchmarks. Fixed-byte requests run at concurrency 1, 8,
and 32. Payloads go to `/dev/null`, curl metadata uses a 16 MiB guest-local tmpfs, and no host share
is mounted. Curl configuration and proxy variables are disabled so these rows measure the direct
guest path; system-proxy discovery and compatibility require a separate test. A host
`CLOCK_MONOTONIC` timer surrounds each complete Docker command. Per-request curl timings and
host-wall batch throughput are both retained so container/CLI overhead is visible rather than
silently subtracted.

Every run retains:

- `run-manifest.tsv`: exact endpoints, expected codes/bytes, image digest, timeouts, limits, timer,
  host identity, script identity, and worktree state.
- `engine-provenance.tsv` and `image-provenance.tsv`: resource/network facts and exact resolved image
  identity for every engine.
- `samples.tsv`: host monotonic duration, container exit status, expected/observed curl rows, and the
  log path for every engine position.
- `curl-raw.tsv`: curl exit/error state, remote IP, HTTP status/version, byte count, transfer rate,
  and all raw DNS/connect/TLS/TTFB/total timestamps for every request.
- `metrics.tsv`: derived DNS/TCP/TLS phases, individual fixed-download rates, and verified-byte batch
  rates at concurrency 1/8/32.
- `run-status.tsv`: terminal pass/fail/interrupted state, exit reason, and best-effort cleanup outcome;
  preflight failures are terminal too and never remain mislabeled as running.

Treat CDN routing, resolver caches, ISP conditions, remote rate limiting, and time-of-day drift as
part of the evidence. Publish the endpoint identity and raw rows, rerun on more than one network,
and treat materially different remote-IP sets as a routing confound rather than a product result.
Do not turn a single-location result into a general networking claim.

## Cold Registry npm Comparison

Use [`scripts/benchmark-registry-npm.sh`](scripts/benchmark-registry-npm.sh) to isolate the combined
DNS/TCP/TLS, registry-transfer, and guest-local extraction path from bind-mount performance. It
requires an immutable digest-pinned Node image already present in every engine and fails closed unless
its platform and ordered RootFS layers match. Store-local image IDs remain diagnostic. It copies one identical
package/lock fixture into a fresh container, and runs `npm ci` with a fresh npm cache. Container CPU
and memory limits are identical, engine order rotates between rounds, and every successful sample
must pass `npm ls --all`. The raw artifact retains engine/image/resource provenance, monotonic timing,
npm logs, installed file counts, and per-engine medians. It does not start, stop, pull for, or
reconfigure an engine.

This is deliberately not a host-share benchmark. Use the workflow harness above for editor and
bind-mount claims, and do not infer general internet throughput from one npm registry fixture.

## What 0.3 Measures

| Metric | Why it matters | Harness |
|---|---|---|
| Idle memory | Shows the cost users feel when a container runtime is sitting in the background. | `--metrics memory` |
| CPU workload | Shows runtime/startup/scheduling overhead for the same repeated CPU-bound task. | `--metrics cpu` |
| Container-to-container network | Shows the shared-VM bridge path that real Compose stacks use. | `--metrics network` |
| External network | Separates DNS/TCP/TLS phases and fixed-byte HTTPS transfers through the guest network path. | `benchmark-external-network.sh` |
| Bind-mount filesystem | Shows the host-to-VM path used by editors, hot reload, and local source mounts. | `--metrics fs` |

Every run writes:

- `machine-spec.tsv`: Mac model, memory, CPU, macOS build, Docker client, optional Apple
  Container CLI, and the released Dory.app identity when `--dory-app` is used.
- `engine-versions.tsv`: per-engine interface, endpoint, server/CLI version, OS/kernel, and arch.
- `memory.tsv`, `cpu.tsv`, `network.tsv`, `filesystem.tsv`: raw per-metric data.
- `status.tsv`: pass, fail, and skip reasons per engine.
- `summary.md`: a publishable local table generated from the raw TSV files.
- `summary.json`: machine-readable aggregate for GitHub Actions artifacts and scripts.

## Current Local Evidence

These are the local measurements we can already stand behind. We should keep replacing this section
with fresh raw artifacts as 0.3 release candidates are rebuilt.

| Claim | Current evidence | Publication note |
|---|---|---|
| Dory uses one shared Linux VM for all containers. | Architecture and release bundle verification in [`COMPATIBILITY.md`](COMPATIBILITY.md). | This is a design fact and does not require a competitor run. |
| Dory does not yet have a defensible idle-memory win. | The legacy [`scripts/benchmark.sh`](scripts/benchmark.sh) used a noisy marginal `vm_stat` delta and compared Dory with Apple's per-container VM model, not total product footprint against OrbStack. | Do not publish the old roughly 122 MB / 4.7x claim. Use an attribution-safe, repeated memory campaign and publish its raw PID/process evidence. |
| Dory measured 97.77 Gbps median container-to-container throughput on one Apple-silicon Mac. | `BENCH_IPERF_IMAGE=taoyou/iperf3-alpine:latest scripts/benchmark-compare.sh --dory-app /Applications/Dory.app --engines dory --metrics memory,cpu,network,fs --memory-counts 0,1,3,5,10 --runs 3 --cpu-mb 256 --fs-files 2000`, raw run `.benchmark-results/20260708T184829Z-32856`. | Same-machine competitor runs are listed below; publish medians with the raw artifacts. |
| Dory does not need to wake the heavy engine just because the app opens. | doryd/app tests attach to a sleeping daemon without calling `engineStart()`. | This supports the "idle means idle" UX claim. |
| A July 11 copyless VirtioNet candidate did not produce a defensible cold-registry npm win over Colima. | Ten valid samples per engine in [`.codex-bench/registry-npm-copyless-20260711T000622Z`](.codex-bench/registry-npm-copyless-20260711T000622Z): Dory 2.347792 s median, Colima 2.286552 s; every sample installed exactly 6,910 files. | Dory was about 2.7% slower. The candidate was reverted and must not be marketed as an optimization. This run did not include OrbStack. |
| Dory and OrbStack were effectively tied on one resource-matched cold-registry npm fixture. | Twelve position-balanced valid samples per engine in [`.codex-bench/registry-npm-three-engine-matched-20260711T001912Z`](.codex-bench/registry-npm-three-engine-matched-20260711T001912Z): Dory 2.264312 s, OrbStack 2.266885 s, Colima 2.312905 s. All engines had 2 CPUs/~2 GiB, resolved the same immutable image platform and ordered layers, and installed exactly 6,910 files in every sample. | The Dory/OrbStack difference was about 0.11%, well inside run noise; publish this as a tie, not a win. Dory was about 2.1% faster than Colima on this local run. OrbStack was restored to its original 12-CPU/8-GiB configuration afterward. |

| The reported general “Dory takes 8 seconds on the same network” gap was not reproduced by a valid matched diagnostic. | [`.codex-bench/external-network-diagnostic-fixed-platform-20260711T020101Z`](.codex-bench/external-network-diagnostic-fixed-platform-20260711T020101Z) used the same executable arm64/v8 curl image, 2 CPUs/~2 GiB, exact 1 MiB payloads, and two balanced rounds. Dory was faster on handshake host wall (~0.26 s vs ~0.34 s) and concurrency-1 host wall (~0.29 s vs ~0.41 s). At concurrency 32, both engines varied from a few seconds to ~10 seconds. | Two rounds are diagnostic, not a publication campaign. The high-concurrency tail is materially confounded by the remote endpoint; use a controlled endpoint and more rounds before claiming a network winner. The harness now executes the image under its configured user before timing so an empty/wrong-platform snapshot cannot become a false win. |
| Bind-mounted npm is reliable after fixing concurrent handle lifetime and stable directory cookies, but remains slower than OrbStack. | Five consecutive Dory install/delete cycles in [`.codex-bench/npm-five-cycle-cookie-fixed-20260711T023530Z`](.codex-bench/npm-five-cycle-cookie-fixed-20260711T023530Z) each installed exactly 6,910 files and removed the tree in one pass. Four balanced matched samples in [`.codex-bench/bind-npm-cookie-fixed-matched-20260711T023643Z`](.codex-bench/bind-npm-cookie-fixed-matched-20260711T023643Z) measured Dory 3.662943 s versus OrbStack 2.091627 s with exact host/guest trees and zero cleanup remnants. | Reliability is a prerequisite and now passes this stress sample. Dory is still about 75% slower on this workload, so this is the highest-priority verified performance gap—not a win. |
| Two virtio-fs correctness bugs behind the intermittent EBADF/rm failures were root-caused and fixed on July 11. | `Virtqueue.push`'s return value (guest interrupt suppression) was misread as a failed publish, rolling back handle/lookup grants the guest had already received; and a host write to a sibling file sent `FUSE_NOTIFY_INVAL_ENTRY` for identity-unchanged directories, whose `d_invalidate` detaches container bind mounts. Both have regression tests. 20 and 15 consecutive stress cycles (host churn + concurrent guest stat storms + destructive reinstalls) pass with zero anomalies; a strace-verified reproduction of the tail-loss failure (`.codex-bench/npm-strace-20260711T041600Z`) passes 10/10 after the fix (`.codex-bench/npm-cofix-20260711T042155Z`). | These were Tier-1 correctness-gate failures; no performance number from earlier same-day candidate runs should be compared without noting them. |
| With correctness fixed plus a child-path index, getxattr ENOSYS latching, a 30 s coherent TTL (1 s negative dentries), the bind-npm gap narrowed from 75% to about 37%. | Solo five-cycle median 2.518 s (`.codex-bench/npm-negdent-20260711T045005Z`), every cycle exact host/guest trees and one-pass rm. Eight position-balanced interleaved samples per engine at 2 CPUs/~2 GiB with the same `node:22-alpine` digest: Dory 2.695 s vs OrbStack 1.972 s (`.codex-bench/ab-matched-20260711T053303Z`). Host-edit visibility gates: in-place edit and delete visible in ~120 ms via reverse invalidation; brand-new host files within ~1.06 s (the documented negative-dentry bound). | Still a loss, not a win — publish as progress only. The remaining levers are the out-of-tree `atomic_open` kernel patch (one round trip per create) and create-path syscall trimming. OrbStack was measured at its matched allocation and restored to 12 CPU/8 GiB afterward. |

## July 8, 2026 Local Snapshot

These runs were taken sequentially on the same Mac: Mac14,10, Apple M2 Pro, 16 GB RAM,
macOS 27.0 build 26A5368g, Darwin 27.0.0 arm64. Dory was measured from an installed
`/Applications/Dory.app` local benchmark build, version 0.3.1 build 2. OrbStack and Colima were
installed with Homebrew, run one at a time, then stopped.

| Engine | Docker server | CPU median, 256 MiB sha256 | C2C network median | Bind mount, 2000 files | In-container, 2000 files | Raw artifact |
|---|---:|---:|---:|---:|---:|---|
| Dory | 27.5.1 | 2.1020 s | 97.7721 Gbps | 0.6880 s | 0.7730 s | `.benchmark-results/20260708T184829Z-32856` |
| OrbStack | 29.4.0 | 1.7190 s | 90.1203 Gbps | 0.2220 s | 0.2970 s | `.benchmark-results/20260708T185520Z-45964` |
| Colima | 29.5.2 | 1.5750 s | 80.9901 Gbps | 0.1590 s | 0.2310 s | `.benchmark-results/20260708T185955Z-63870` |

The same runs also captured idle-memory rows for 0, 1, 3, 5, and 10 `alpine:latest` containers.
Those rows are preserved in each `memory.tsv`, but several system-memory and process-RSS deltas
went negative while macOS compressed/reclaimed pages. Do not publish a memory winner from this
snapshot without rerunning the memory metric under a quieter setup.

## Reproduce A Full Run

Run this on a physical Mac, not a GitHub-hosted macOS runner. Hosted macOS runners are VMs and do not
have the nested virtualization needed for this benchmark.

```sh
# Audit the work before touching any engine:
scripts/benchmark-compare.sh \
  --engines dory,orbstack,docker-desktop \
  --metrics memory,cpu,network,fs \
  --dry-run

# Live cross-engine run against the installed release app:
BENCH_WORKDIR="$PWD/.benchmark-results" \
scripts/benchmark-compare.sh \
  --dory-app /Applications/Dory.app \
  --engines dory,orbstack,docker-desktop \
  --metrics memory,cpu,network,fs \
  --memory-counts 0,1,3,5,10 \
  --runs 3 \
  --cpu-mb 256 \
  --fs-files 2000
```

For a Dory-only release candidate smoke:

```sh
BENCH_WORKDIR="$PWD/.benchmark-results" \
scripts/benchmark-compare.sh \
  --dory-app /Applications/Dory.app \
  --engines dory \
  --metrics memory,cpu,network,fs \
  --memory-counts 0,1,3
```

## GitHub Workflow

The [Benchmark workflow](.github/workflows/benchmark.yml) is manual and scheduled, but it only runs
on a self-hosted Mac labeled `self-hosted`, `macOS`, and `dory`. It uploads the full result directory
as a GitHub Actions artifact.

Recommended runner matrix for 0.3:

| Runner | Required labels | Engines |
|---|---|---|
| Apple silicon, macOS 15+ | `self-hosted`, `macOS`, `dory` | Dory, Docker Desktop, OrbStack |
| Apple silicon, macOS 26+ optional competitor run | `self-hosted`, `macOS`, `dory`, `apple-container` | Dory, Docker Desktop, OrbStack, Apple Container |
| Intel, macOS 14/15+ | `self-hosted`, `macOS`, `dory`, `intel` | Dory Intel beta, Docker Desktop, Colima/OrbStack where supported |

## Publication Rules

- Publish raw artifacts with every table.
- Disclose the Mac model, RAM, chip, macOS build, engine versions, and date.
- Report medians and keep the raw TSV rows.
- Do not mix cold image pulls into warm runtime numbers.
- Fail the comparison when engine CPU/guest-memory allocations or resolved image IDs differ.
- Do not compare Apple Container networking as if it used Docker bridge semantics. It is
  host-routed between separate VMs.
- Do not publish Dory-vs-OrbStack or Dory-vs-Docker multipliers until those engines were measured
  on the same machine in the same run.
- Do not publish filesystem speed-up claims from write-back-cached bind mounts unless the workload
  includes a durability check.
- Do not turn a narrow in-place fs.watch gate into a claim about atomic saves or end-to-end HMR.

The boring rule is the useful one: if a skeptical developer cannot rerun the exact command and see
the raw files, it is not a release benchmark yet.
