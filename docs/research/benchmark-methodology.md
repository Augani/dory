# Dory Cross-Engine Benchmark Methodology

This document describes how Dory's published performance comparisons are produced. The goal is a
**reproducible, defensible** measurement of Dory against OrbStack, Docker Desktop, and Apple
Container on a single Apple-silicon Mac, so that every marketing number links back to a raw log a
skeptical reader can regenerate.

The scripts live in [`scripts/bench/`](../../scripts/bench). Nothing here fabricates numbers: a
`--dry-run` mode prints the exact commands the suite would execute so the methodology can be audited
before any live run.

## What we measure

1. **Idle memory** per engine, plus the **marginal memory per idle container** at 0, 1, 5, and 10
   idle containers.
2. **Container-to-container (C2C) network throughput**: steady-state TCP bandwidth between two
   containers on one Mac.
3. **Filesystem performance** in three storage modes: bind-mounted host directory, named volume,
   and the container's in-VM native filesystem.

## Engines under test

| Engine | Interface used | Notes |
|---|---|---|
| Dory | Docker API over `~/.dory/dory.sock` | One shared Linux VM for all containers. |
| OrbStack | Docker API over `~/.orbstack/run/docker.sock` | One shared VM. |
| Docker Desktop | Docker API over `~/.docker/run/docker.sock` | One shared VM (LinuxKit). |
| Apple Container | `container` CLI (`/opt/homebrew/bin/container`) | **One lightweight VM per container.** No Docker socket; measured through its own CLI. |

Apple Container's per-container-VM model is the reason it is measured through a different code path
and why some comparisons (notably named volumes and C2C networking) are architecturally different
rather than strictly apples-to-apples. Those differences are called out inline in the results and in
the sections below, not hidden.

## Core principles (why the numbers are defensible)

- **Fixed iterations, medians over N runs.** Every measurement runs N times (default 3; network uses
  12 samples) and we report the **median**, which is robust to a single warm/cold outlier. Raw
  per-run values are always written to a TSV so mean/min/max can be recomputed.
- **Cold vs warm are labeled.** Images are pulled *before* any timed run so image download never
  pollutes a measurement (a "warm" start). Where cold-start matters it is a separate, explicitly
  labeled measurement; timed runs never silently mix the two.
- **Machine specs recorded.** Each run captures `hw.model`, `hw.memsize`, `hw.ncpu`,
  `machdep.cpu.brand_string`, and `sw_vers` into `machine-spec.txt` in the results directory. A
  result without its machine spec is not publishable.
- **Every number is traceable.** `summary.md` tables are derived purely from the sibling `*.tsv`
  files in the same `bench-results/<timestamp>/` directory, and each table links to its raw TSV.
- **Only our resources are touched.** Every container/volume/network the suite creates carries the
  label `dev.dory.bench=<run-id>`; cleanup removes only labeled resources (Apple Container has no
  label filter, so it is cleaned by a unique name prefix instead). This mirrors
  [`scripts/readiness.sh`](../../scripts/readiness.sh).
- **Settle windows.** A configurable settle wait (default 12s) brackets each memory measurement so
  VM background activity quiesces before and after the workload is applied.

## 1. Memory: `scripts/bench/memory.sh`

For each engine and each container count in {0, 1, 5, 10}:

1. Clean up any prior bench resources and settle.
2. Record a baseline: host used memory via `vm_stat` (`(pages active + wired + compressed) ×
   page size`) and the aggregate RSS of the engine's host-side processes via `ps -axo rss,args`.
3. Start N idle containers (`alpine sleep infinity`; no ports, no workload). For Docker engines these
   land in the shared VM; for Apple Container each `container run` spins its own VM.
4. Settle, then record the peak of the same two metrics.
5. Report `system_delta = peak − baseline` and `process_rss_delta` likewise.

**Two metrics, deliberately.** `system_delta` (vm_stat) is what a user actually feels: it includes
the VM's growth, page cache, and helper processes. `process_rss_delta` attributes memory to named
engine processes and is a cross-check. The 0-container run establishes each engine's **idle
footprint**; counts 1/5/10 divide their delta by N to derive **marginal cost per idle container**.

Per-engine process match patterns (overridable via env vars):

- Dory: `Dory|dory-vm|dory-vmboot|containermanagerd`
- OrbStack: `OrbStack`
- Docker Desktop: `Docker|com.docker`
- Apple Container: `container-runtime-linux|container-network-vmnet|containerization|com.apple.container`

This vm_stat math and the RSS-pattern approach are shared with `scripts/readiness.sh` and the
existing `scripts/benchmark.sh` so the two suites are directly comparable.

## 2. Network: `scripts/bench/network.sh`

Two containers on one user-defined bridge network; one runs `iperf3 -s`, the other runs `iperf3 -c`
for a single TCP stream. We take **12 back-to-back 10-second samples** and report the median
receiver-side Gbps (parsed from `iperf3 -J`). iperf3 comes from `networkstatic/iperf3` when
pullable; otherwise it is installed into alpine via `apk`.

**Apple Container caveat (documented, not hidden):** Apple Container has no `docker network create`.
Two `container run` instances communicate over Apple's **vmnet**-backed networking, so the traffic is
host-routed between two separate VMs rather than crossing an in-VM veth bridge. This is a genuine
architectural difference. Apple's row is labeled `vmnet(host-routed)` versus `bridge(in-vm-veth)` for
the shared-VM engines, and the two should not be read as a like-for-like veth comparison.

## 3. Filesystem: `scripts/bench/filesystem.sh`

Three storage modes, identical workload in each so results are comparable:

- **bind**: a host directory bind-mounted into the container. On macOS engines this crosses the
  host↔VM boundary and is the path users complain about.
- **volume**: a named Docker volume backed by the VM's block store.
- **native**: the container's own writable layer inside the VM (in-VM native FS).

Workload (run inside the container via a single portable `sh -c` script):

1. **write**: create N small files (default 2000 × 4 KiB) and `sync`.
2. **read**: read all N files back (`cat > /dev/null`).
3. **extract**: build a git-clone-sized tree (~40 dirs × 50 files), tar it, and time the
   `tar -x` extract (many small files + directory creation, the metadata-heavy path).
4. **fio** (optional): if `fio` is present in the image, a 4k randrw job is recorded for a
   defensible bandwidth number. The tar/small-file workload always runs so results exist without fio.

Each mode is timed over N runs (default 3); the median wall-time per phase is reported.

**Apple Container caveat:** bind and native modes are measured through its CLI. Named-volume
semantics differ, so the **volume** mode is marked N/A for Apple Container rather than reported as a
misleading zero.

## Reproducing

Requires macOS on Apple silicon with the target engines installed and running (their Docker sockets
present; Apple Container's `container` CLI on `PATH`). This cannot run on GitHub-hosted runners:
they are VMs without nested virtualization.

```sh
# Review what will run, execute nothing:
scripts/bench/run-all.sh --engines dory,orbstack,docker-desktop,apple --dry-run

# Live run (writes bench-results/<timestamp>/):
scripts/bench/run-all.sh --engines dory,orbstack,docker-desktop,apple

# A single benchmark / single engine:
scripts/bench/memory.sh    --engine dory --counts 0,1,5,10 --runs 3
scripts/bench/network.sh   --engine orbstack --samples 12 --duration 10
scripts/bench/filesystem.sh --engine apple --files 2000 --runs 3
```

Outputs land in `bench-results/<timestamp>/`:

- `machine-spec.txt`: hardware + OS disclosure for this run.
- `memory.tsv`, `network.tsv`, `filesystem.tsv`: every raw sample plus `MEDIAN` rows.
- `logs/<bench>-<engine>.log`: full stdout/stderr of each sub-benchmark.
- `summary.md`: the human-readable comparison tables, each linking to its raw TSV.

### Tunables (environment variables)

| Variable | Default | Purpose |
|---|---|---|
| `DORY_SOCK`, `ORBSTACK_SOCK`, `DOCKER_DESKTOP_SOCK` | per-engine defaults | Override engine sockets. |
| `BENCH_CONTAINER_BIN` | `container` on PATH | Apple Container CLI path. |
| `BENCH_RUNS` | `3` | Runs per measurement (median). |
| `BENCH_SETTLE` | `12` | Settle seconds around memory measurements. |
| `BENCH_ALPINE_IMAGE` | `alpine:latest` | Idle / filesystem workload image. |
| `BENCH_IPERF_IMAGE` | `networkstatic/iperf3:latest` | Network workload image. |
| `BENCH_NET_SAMPLES` / `BENCH_NET_DURATION` | `12` / `10` | Network samples and per-sample seconds. |
| `BENCH_FS_FILES` / `BENCH_FS_FILE_KIB` | `2000` / `4` | Small-file count and size. |
| `DRY_RUN` | `0` | `1` prints planned commands and executes nothing. |

## Hardware disclosure template

Publish results only alongside a filled-in block like this (auto-captured in `machine-spec.txt`):

```
Model:            <hw.model, e.g. Mac15,3>
Chip:             <machdep.cpu.brand_string, e.g. Apple M3 Pro>
CPU cores:        <hw.ncpu>  (physical <hw.physicalcpu> / logical <hw.logicalcpu>)
Memory:           <hw.memsize_gb> GB
macOS:            <sw.productName> <sw.productVersion> (<sw.buildVersion>)
Docker client:    <docker version --format {{.Client.Version}}>
Apple Container:  <container --version>
Engine versions:  Dory <x>, OrbStack <y>, Docker Desktop <z>
Date (UTC):       <captured_utc>
```

## Known limitations

- Single-machine, single-run-at-a-time. Engines are stateful; run each with the others idle (use
  `--stop-orbstack` for isolation) and repeat the full suite to establish run-to-run variance.
- Numbers are specific to the disclosed hardware/OS/engine versions. Do not extrapolate across chips.
- Apple Container's networking and volume semantics differ by design (see caveats above); treat those
  rows as characterizing a different architecture, not as head-to-head with the shared-VM engines.
- `iperf3` single-stream measures steady-state bandwidth, not latency or connection-setup cost.

---

## First live run: 2026-07-02 (Dory only; M-series Mac; single machine)

Engine: dory (OrbStack/Docker Desktop apps not running → skipped; iperf3 image pull failed → C2C skipped).

| Metric | Result | Read |
|---|---|---|
| Idle memory | +13.6 MB engine RSS for 3 idle alpine (~4.5 MB/container); system delta negative = noise | Low host footprint corroborated |
| Bind-mount FS, 2k files | bind 0.195s vs in-container 0.264s (0.74×) | Bind ≥ as fast as overlay |
| Bind-mount FS, 20k files | bind 0.188s vs in-container 2.452s (0.08×) | **SUSPECT (see caveat)** |

### CAVEAT: do NOT publish the 0.08× / "13× faster" figure
Bind-mount wall time was ~flat (0.195s→0.188s) as file count went 2k→20k, while in-container scaled
~10×. Flat-under-load is the signature of **write-back-cached virtiofs**: the in-guest timer returns
before writes are durably flushed to the host, so bind time is undercounted. Before any FS-speed
claim, a rigorous benchmark must: (1) force durability (fsync/`sync` that actually crosses the
virtiofs boundary, or measure host-side completion), (2) add a TRUE native baseline (same op run
directly on macOS, no container/VM), (3) use realistic workloads (`npm install`, `git status` on a
large tree, tar-extract), (4) median-of-N with warm cache disclosed. HONEST current claim: Dory's
bind mount is **not slower** than its own overlay fs (unlike Docker Desktop's documented penalty);
magnitude TBD. This is WS-E's charter.

### C2C networking: MEASURED 2026-07-02 (Dory)
**Dory container-to-container throughput: median 114.16 Gbps** (5 back-to-back iperf3 single-stream
runs; samples 111.54 / 113.67 / 114.16 / 114.40 / 115.01 Gbps, ±1.5% spread). Two containers on one
user-defined bridge network inside Dory's shared VM; `iperf3 -s` ↔ `iperf3 -c -t 5 -J`, receiver-side
Gbps. Reproduce: `BENCH_IPERF_IMAGE=taoyou/iperf3-alpine:latest scripts/benchmark-compare.sh --engines
dory --metrics network`.

Root cause of the earlier "pull failed": the harness default `networkstatic/iperf3:latest` is
**x86-only (no arm64 manifest)**. It can never pull on Apple Silicon, the only platform Dory runs on,
so this probe silently SKIP'd for every user. Fixed: `benchmark-compare.sh` now defaults to the
multi-arch `taoyou/iperf3-alpine:latest` (Entrypoint `iperf3`, iperf 3.11, arm64).

**Honest framing for #6:** 114 Gbps is co-located-containers-in-one-VM throughput (memory-bandwidth
bound, loopback-class): the structural advantage of Dory's shared engine. The research claim that
Apple's Container is "~5× slower C2C" is from a **single external source**; we have NOT re-measured
Apple Container here (its per-container-VM design has no `docker network` and routes over host vmnet,
so it isn't a like-for-like bridge comparison). Publish Dory's 114 Gbps as a measured Dory number; do
NOT publish a "5× vs Apple" multiplier until Apple Container's C2C is measured on the same machine.
