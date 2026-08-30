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
