# Phase 0A physical reference matrix

ADR-017 requires exact low, middle, and high physical Apple-silicon reference machines. A tier is
not frozen merely because a developer Mac is available, and an inventory receipt is not a
performance result.

## Current matrix

| Tier | Exact physical reference | State | Required next evidence |
|---|---|---|---|
| Low | Not frozen | Open stop gate | Named model/SoC/minimum RAM, supported macOS build, storage/display topology, signed inventory, and complete baseline campaign |
| Middle | Not frozen | Open stop gate | Same evidence; the available `Mac14,10` may be assigned only by the ADR-017 owners |
| High | Not frozen | Open stop gate | Named model/SoC/RAM, supported macOS build, storage/display topology, signed inventory, and complete baseline campaign |

## Available physical candidate

The signed 2026-08-30 engineering inventory establishes one available candidate:

- `Mac14,10` MacBook Pro;
- Apple M2 Pro, 8 performance plus 4 efficiency cores;
- 16 GiB unified memory;
- internal Apple Fabric solid-state root storage;
- macOS 27.0 build `26A5421a`, firmware and OS loader `20457.1.29`;
- AC power, low-power mode disabled, nominal thermal state at collection;
- built-in 4112 × 2658 at 120 Hz plus external 1920 × 1080 at 75 Hz.

This candidate is deliberately `unassigned`. Assigning it prematurely would allow the only
available host to define the product tiers. The exact engineering receipt is in
[`phase-0a-host-inventory-engineering-evidence-2026-08-30.json`](phase-0a-host-inventory-engineering-evidence-2026-08-30.json).

## Collector contract

`dory-phase0a-host-probe` emits schema `dory.phase0a.host-qualification@1`. It records the host
facts required to bind later campaigns: architecture, model, chip/core topology, memory,
firmware/loader, macOS build, boot session, power and low-power state, thermal state, root-storage
topology/capacity, and active display modes.

The collector intentionally excludes the hardware serial number, platform UUID, provisioning
UDID, battery serial, user name, and home-directory paths. Successful collection exits zero but
does not close ADR-017: `baselinesComplete` and `physicalMatrixComplete` remain false until exact
signed candidates complete the reproducible native, minimal-HV/VZ-harness, and Dory campaigns.

## Lifecycle calibration

The Developer-ID-signed, hardened-runtime `dory-phase0a-hv-calibration` candidate executes the same
page, reset architectural state, `mov x0, #42; hvc #0` program, complete `X0...X7` hypercall exit,
vCPU lifecycle, and teardown through raw Hypervisor.framework and Dory's contract-backed engine.
Schema 2 freezes five rounds, 20 warmups per harness per round, and 300 measured samples per
harness per round. Position alternates by round and sample parity, `CLOCK_MONOTONIC_RAW` times every
lifecycle, and R-7 interpolation summarizes every raw observation. The inference unit is the round
median; the budget statistic is the median of the five paired round-overhead values.

The current signed run did not pass the 3% orchestration budget:

| Round | Minimal HV median | Dory median | Dory overhead | Pass |
|---:|---:|---:|---:|:---:|
| 1 | 69.334 µs | 72.542 µs | 4.626% | No |
| 2 | 62.667 µs | 65.208 µs | 4.055% | No |
| 3 | 62.771 µs | 63.229 µs | 0.730% | Yes |
| 4 | 61.063 µs | 64.125 µs | 5.015% | No |
| 5 | 61.063 µs | 62.500 µs | 2.354% | Yes |

The paired round-overhead median is 4.055%. Power remained AC, low-power mode stayed disabled,
thermal state stayed nominal, the boot session did not change, and all 3,200 warmup/measured
executions produced the expected ABI result. The exact 3,000 raw observations are retained in the
deterministic gzip receipt linked by
[`phase-0a-hv-lifecycle-calibration-engineering-evidence-schema2-2026-08-30.json`](phase-0a-hv-lifecycle-calibration-engineering-evidence-schema2-2026-08-30.json).

The earlier schema-1 engineering receipt remains historical evidence but is superseded for future
decisions: it had only one 30-sample batch and did not preserve raw observations or use independent
round medians.
