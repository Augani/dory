# Dory Benchmarks

Dory publishes benchmarks as raw, reproducible runs, not screenshots. Every public number should
come with the machine spec, the command used, raw TSV/JSON output, and a note about which engines
were installed and running on the same Mac.

The main harness is [`scripts/benchmark-compare.sh`](scripts/benchmark-compare.sh). It compares Dory
against Docker Desktop, OrbStack, and Apple Container where those engines are present.

## What 0.3 Measures

| Metric | Why it matters | Harness |
|---|---|---|
| Idle memory | Shows the cost users feel when a container runtime is sitting in the background. | `--metrics memory` |
| CPU workload | Shows runtime/startup/scheduling overhead for the same repeated CPU-bound task. | `--metrics cpu` |
| Container-to-container network | Shows the shared-VM bridge path that real Compose stacks use. | `--metrics network` |
| Bind-mount filesystem | Shows the host-to-VM path used by editors, hot reload, and local source mounts. | `--metrics fs` |

Every run writes:

- `machine-spec.tsv`: Mac model, memory, CPU, macOS build, Docker client, Apple Container CLI,
  and the released Dory.app identity when `--dory-app` is used.
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
| Dory has measured roughly 122 MB for two idle containers versus roughly 574 MB as per-container VMs on the same Mac. | Legacy focused harness [`scripts/benchmark.sh`](scripts/benchmark.sh), retained for continuity. | Treat as Dory's own measurement until a fresh `benchmark-compare.sh` artifact is attached to the release. |
| Dory measured 114.16 Gbps median container-to-container throughput on one Apple-silicon Mac. | `BENCH_IPERF_IMAGE=taoyou/iperf3-alpine:latest scripts/benchmark-compare.sh --engines dory --metrics network` with 5 samples. | Do not claim a multiplier against Apple Container until Apple Container is re-measured on the same Mac. |
| Dory does not need to wake the heavy engine just because the app opens. | doryd/app tests attach to a sleeping daemon without calling `engineStart()`. | This supports the "idle means idle" UX claim. |

## Reproduce A Full Run

Run this on a physical Mac, not a GitHub-hosted macOS runner. Hosted macOS runners are VMs and do not
have the nested virtualization needed for this benchmark.

```sh
# Audit the work before touching any engine:
scripts/benchmark-compare.sh \
  --engines dory,orbstack,docker-desktop,apple-container \
  --metrics memory,cpu,network,fs \
  --dry-run

# Live cross-engine run against the installed release app:
BENCH_WORKDIR="$PWD/.benchmark-results" \
scripts/benchmark-compare.sh \
  --dory-app /Applications/Dory.app \
  --engines dory,orbstack,docker-desktop,apple-container \
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
| Apple silicon, macOS 26+ | `self-hosted`, `macOS`, `dory`, `apple-container` | Dory, Docker Desktop, OrbStack, Apple Container |
| Intel, macOS 14/15+ | `self-hosted`, `macOS`, `dory`, `intel` | Dory Intel beta, Docker Desktop, Colima/OrbStack where supported |

## Publication Rules

- Publish raw artifacts with every table.
- Disclose the Mac model, RAM, chip, macOS build, engine versions, and date.
- Report medians and keep the raw TSV rows.
- Do not mix cold image pulls into warm runtime numbers.
- Do not compare Apple Container networking as if it used Docker bridge semantics. It is
  host-routed between separate VMs.
- Do not publish Dory-vs-OrbStack or Dory-vs-Docker multipliers until those engines were measured
  on the same machine in the same run.
- Do not publish filesystem speed-up claims from write-back-cached bind mounts unless the workload
  includes a durability check.

The boring rule is the useful one: if a skeptical developer cannot rerun the exact command and see
the raw files, it is not a release benchmark yet.
