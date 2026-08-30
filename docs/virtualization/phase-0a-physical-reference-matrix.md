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

## First lifecycle calibration

The Developer-ID-signed, hardened-runtime `dory-phase0a-hv-calibration` candidate executes the same
page, `mov x0, #42; hvc #0` program, vCPU lifecycle, and teardown through raw
Hypervisor.framework and Dory's contract-backed engine. Five warmups precede 30 samples per
harness. AB/BA order alternates, `CLOCK_MONOTONIC_RAW` times every lifecycle, and R-7 interpolation
produces median/p95/p99 values.

The first clean run did not pass the 3% orchestration budget:

| Harness | Median | p95 | p99 | Worst | CV |
|---|---:|---:|---:|---:|---:|
| Minimal Hypervisor.framework | 81.417 µs | 110.781 µs | 115.927 µs | 116.459 µs | 15.61% |
| Dory execution contracts | 84.521 µs | 100.012 µs | 106.515 µs | 108.666 µs | 10.85% |

Median overhead is 3.81%. Power remained AC, low-power mode stayed disabled, thermal state stayed
nominal, the boot session did not change, and all 70 warmup/measured executions produced the
expected register value. The exact receipt is
[`phase-0a-hv-lifecycle-calibration-engineering-receipt-2026-08-30.json`](phase-0a-hv-lifecycle-calibration-engineering-receipt-2026-08-30.json).
The signed candidate SHA-256 is
`1736bf2693adb3980f1b6802d4ce110b648552c2acd7f1b10f1a1473ad792a31`; the receipt SHA-256 is
`a9b255d630d2541c2cb5e7bdedc108d5dec1eaa43c14e92b72cacef7abbb9128`. It was signed by team
`864H636QW4` with hardened runtime and `com.apple.security.hypervisor`, but was not submitted for
notarization because it is engineering evidence, not a release candidate.
