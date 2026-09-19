# Dory x86_64 Linux readiness review — 2026-09-19

Reviewed from branch `codex/virtual-workspace-foundation`, base commit `5cfea613e22e`, plus the
uncommitted fixes listed in this report. Host: Apple M2 Pro, macOS 27.2, Xcode 27.0, Swift 6.4.

This review supersedes the x86_64 conclusions in `READINESS-REVIEW-2026-09-15.md` where current
source, configuration, and tests differ. Historical receipts remain useful measurements, but they
are not promoted to evidence for the current candidate.

## Verdict

**Dory is not ready to expose x86_64 Linux as a supported customer runtime. Keep the production
availability gate closed.**

The engine is ready for continued internal qualification: the reviewed x86/PC/firmware test set is
green after the fixes below, the current release microbenchmark is fast on its narrow workload, and
the UI/daemon correctly prevent an unqualified public launch. The release decision is still blocked
by four architectural and evidence gaps:

1. No source-bound PVH or UEFI Linux boot was run on this commit and exact production configuration.
   The repository and searched local caches contain no current kernel/initrd/OVMF fixture with which
   to perform that run.
2. The PC run loop is still coordinator-driven. Its parallel path overlaps at most one frozen,
   register-only NOP/MOV instruction per vCPU; this is not free-running SMP capable of running Linux.
3. The only registered CPU compatibility profile is `compat-v1`. The ISA-level model knows about v2
   and v3, but no launchable x86-64-v2 profile exists.
4. The strongest real-guest evidence predates the current source and production settings and remains
   far too slow for a supported product.

## Gate status

| Gate | Status | Evidence / reason |
|---|---|---|
| Public product admission | **Safe, closed** | `DoryReleaseSupportPolicy` reports translated x86_64 Linux unavailable; daemon bootstrap requires explicit qualification authority. |
| Debug x86/PC/firmware suites | **Pass** | 1,447 tests in 140 suites passed together after this review. |
| Release Linux runner build | **Pass** | `swift build -c release --product dory-pc-linux-boot-runner` completed cleanly against the reviewed tree. |
| Optimized test execution | **Blocked** | SwiftPM builds every package test target before applying the filter. `DorydKitTests` references debug-only lifecycle-injection APIs and emits more than 700 cascading compile diagnostics in release mode, so the package cannot currently assemble any release test bundle. No test seam was moved into production to hide this defect. |
| Release register-loop benchmark | **Provisional pass** | 5,000,000 instructions: interpreter 1.10 MIPS, baseline JIT 749.57 MIPS, tier-one JIT 337.37 MIPS. This is a regression probe, not a ship gate. |
| Current-source PVH boot/userspace | **Fail: no evidence** | No current immutable kernel/initrd fixture was available. Historical runs are from commit `13372fb2c6a...`. |
| UEFI install, reboot, cold boot, update | **Fail: no evidence** | No exact-candidate installer campaign or retained artifact set exists for this source. |
| Exact production JIT configuration | **Fail: stale evidence** | Current defaults are protected host pages and all raw-target predictors. Retained PVH acceptance isolated tier-one direct chaining and explicitly left combined prediction/A05.3 open. |
| Real SMP | **Fail** | Coordinator schedules and awaits slices; the overlap path accepts only a tiny paging-off, register-only, one-instruction shape. |
| x86-64-v2 guest ABI | **Fail** | Profile registry implements only `baselineV1` / `compatibleV1`. |
| Locked operations / memory model | **Open** | A process-wide pthread mutex preserves mixed interpreter/JIT atomicity but serializes all vCPUs; no complete SMP TSO/litmus campaign exists. |
| Release reproducibility | **Fail** | Boot fixtures and their producer manifest are absent, so a clean checkout cannot reproduce current guest qualification. |

## Measurements that must not be conflated

### Current microbenchmark

`swift run -c release dory-x86-throughput-benchmark 5000000` on the reviewed working tree:

| Tier | MIPS | Scope |
|---|---:|---|
| Interpreter | 1.10 | Tight register loop |
| Baseline JIT | 749.57 | Tight register loop, one accepted direct chain |
| Tier-one JIT | 337.37 | Tight register loop, one accepted direct chain |

This proves that generated code can be fast once it is resident and linked. It does not exercise
paging, TLB misses, loads/stores, locked operations, interrupts, devices, firmware, or Linux. It
also shows tier one at 45% of baseline performance on this workload; qualification must explain or
remove that inversion rather than selecting the better number after the fact.

### Retained real-guest evidence

- `docs/virtualization/evidence/a05-tier1-2026-09-12/pvh-tier1-direct-chain-acceptance.json`
  contains two successful Alpine PVH userspace runs. They retired about 733 million instructions in
  230–232 seconds: approximately **3.2 MIPS**, with only 36.43–36.47% dispatcher avoidance. The
  receipt explicitly says A05.3 remains open and the combined predictor configuration is not
  accepted.
- `docs/virtualization/evidence/p06-pc-2026-09-06/tier-comparison-rpcdiag.json` records the optimizing
  JIT taking **3,901 seconds** to agent bind-ready and **218.725 seconds** to execute `/bin/true` over
  RPC. It is preview evidence from commit `051c97f25b...`, not release qualification.

The current microbenchmark is therefore encouraging engine evidence, while the retained guest
numbers remain the product reality until a current-source campaign replaces them.

## Issues fixed during this review

1. **Debug interpreter stack crashes.** The monolithic interpreter step used an approximately
   473 KiB debug stack frame, causing SIGBUS on Swift Testing worker stacks. Fetch/decode was split
   from decoded execution, and REP bulk/scalar string paths were moved into non-inlined helpers.
   The entry frame is now about 15 KiB and the string dispatcher about 7 KiB. Canonical REP and
   XSTATE boundary tests now pass without stack faults.
2. **Profile-incorrect JIT lowering.** `F3 0F BC/BD` now lowers to BSF/BSR only when the selected CPU
   profile does not advertise BMI1/LZCNT. Profiles that advertise TZCNT/LZCNT retain interpreter
   authority until their distinct flag semantics have native IR support.
3. **Publication-revalidation test drift.** Tests now assert the intentional second exact-byte read
   performed immediately before JIT publication, including page-boundary and pending-work cases.
   The safety read was not removed.
4. **False TLB-hit tests.** Scalar fixtures now use a distinct address register, and invalidation
   tests explicitly seed the native read TLB before claiming to exercise a hit and its revocation.
5. **Atomic/pending-work test starvation.** Tests that need an independently scheduled OS thread no
   longer depend on a saturated global worker pool. Process-wide atomic-gate probes are serialized
   within their suite because simultaneous probes alter the resource being measured.
6. **Deleted external test dependency.** The physical x86 reference corpus is now an immutable
   SwiftPM test resource rather than a path into the removed `guest/diagnostics` tree.
7. **Stale production expectations and warnings.** UEFI composition now expects protected host-page
   write coherence; ignored mutation results are explicit, removing Swift 6.4 warnings. Extended
   attribute names now decode their signed C bytes explicitly instead of relying on the deprecated
   null-terminated-string initializer.

These fixes make the test signal trustworthy. They do not substitute for the missing guest and SMP
qualification.

## Remaining engineering work

### P0 — Reproducible guest qualification inputs

Build a checked-in fixture manifest and producer, not an ad hoc local image:

- Pin source URLs, licenses, configuration, toolchain/container identity, and SHA-256 for kernel,
  initrd/rootfs, DoryPC firmware, and installer ISO.
- Produce immutable PVH smoke and UEFI installer fixtures from a clean checkout.
- Make every receipt bind source commit, dirty-tree state, executable hashes, fixture hashes, host
  class, CPU profile, execution tier, JIT write policy, predictor options, vCPU count, and memory.
- Cache artifacts by content hash; never accept a mutable path as qualification identity.

### P0 — Make optimized qualification tests executable

The release runner builds, but the package-wide release test harness does not. Fix this as test
architecture rather than by compiling fault-injection switches into production:

- Separate independently runnable test products so an x86 release filter does not first compile
  unrelated daemon test modules.
- Put lifecycle fault-injection support in a test-only support target, or gate the dependent daemon
  tests consistently when the production hooks are unavailable.
- Add an optimized x86/PC/firmware CI job that executes, rather than merely compiles, the same
  qualification set and preserves its receipt.
- Keep the release product free of test closures, crash injectors, and diagnostic-only initializers.

### P0 — Replace slice orchestration with a real vCPU runtime

The next runtime must have one persistent host worker per vCPU:

- Each worker owns architectural state, JIT context, TLB, code-cache cursor, and a long-running
  dispatch loop. It must not return to a coordinator after every instruction budget.
- Interrupt, timer, cancellation, and tier-work requests use per-vCPU atomic pending-work state.
  Device and lifecycle mutations rendezvous only when required.
- Preserve a separate deterministic single-thread mode for replay and conformance; do not make the
  production scheduler deterministic by serializing it.
- Publish/retire code with an epoch or hazard scheme so one vCPU cannot execute recycled code while
  another invalidates or replaces it.
- Remove the one-instruction frozen overlap path only after the new runtime covers its tests.

### P0 — Define and prove the SMP memory contract

- Write down the guest-visible x86 TSO contract for ordinary loads/stores, locked operations,
  fences, page-table writes, DMA, self-modifying code, and instruction fetch.
- Keep aligned natural-width host atomics lock-free; use a machine-scoped fallback only for
  unaligned/split operations that cannot be represented safely.
- Replace the process-global atomic mutex only after interpreter and every JIT tier share the same
  machine-scoped coordinator and litmus tests prove single-copy atomicity.
- Add generation-safe TLB invalidation, protected-page alias handling at the host allocation
  granule, DMA invalidation, and cross-vCPU SMC tests.

### P0 — Ship an x86-64-v2 compatibility profile

Keep `compat-v1` immutable for existing definitions. Add a new registered profile with, at minimum,
SSE3, SSSE3, SSE4.1, SSE4.2/CRC32, and POPCNT. Add PAT and the XSAVE/XCR0 contract required by the
selected distro envelope. Every advertised feature needs:

- decoder and execution-policy agreement;
- independent physical-reference vectors, including exceptions and flags;
- interpreter and JIT parity;
- CPUID/MSR migration identity tests; and
- an explicit fallback policy when native lowering is absent.

Do not advertise AVX/AVX2 merely to satisfy a probe. Introduce them as a later profile once YMM
state, VEX upper-lane rules, XSAVE images, and two-half NEON lowering are complete.

### P1 — Make performance evidence representative

Extend `dory-x86-throughput-benchmark` into named, non-substitutable cells:

- register/control-flow loop;
- RAM load/store and read-modify-write;
- paging with TLB hit and miss distributions;
- branch/direct-chain/IBTC/return prediction;
- interpreter fallback boundaries;
- interrupt/timer/device-exit pressure; and
- 1/2/4-vCPU parallel workloads.

Record wall time, thread CPU, retired guest instructions, native dispatcher entries, cache
compilations/rotations, TLB counters, callback counts, fallback sites, and direct-chain acceptance.
Profile the tier-one/baseline inversion before changing thresholds.

### P1 — Reduce remaining debug stack and dispatcher risk

`executeDecodedStep` still has an approximately 394 KiB debug frame even though callers no longer
stack it under decoding. Split it by execution domain: integer/control, memory/atomics,
x87/MMX/SIMD, system/interrupt, and I/O/string. Add a CI stack-frame report with a defined maximum
(target: less than 64 KiB per dispatcher) so a new switch case cannot silently recreate the crash.

### P1 — Run the exact guest matrix

For both PVH and UEFI paths, on the exact signed candidate:

- boot to userspace and agent readiness;
- install from ISO, installer reboot, cold boot from disk, package update, shutdown, and recovery;
- exercise storage, networking, entropy, clock, console/input, and graphics where applicable;
- run 1, 2, and 4 vCPUs, with CPU hot/idle and interrupt pressure;
- inject invalid page tables, MMIO faults, code mutation, cache rotation, device reset, and power
  transitions; and
- repeat on every supported host class.

## Activation criteria

Do not change public availability until all of these are true:

1. Twenty consecutive debug and release qualification runs complete with zero crash, hang, test
   failure, or unexplained nondeterminism.
2. A clean checkout reproduces every boot artifact and verifies its hash.
3. Current-source PVH reaches userspace and completes the workload receipt on every supported host
   class; UEFI completes install, reboot, cold boot, update, and recovery.
4. The exact production configuration—CPU profile, protected-page policy, predictors, firmware,
   devices, vCPU count, and signed binaries—passes two clean campaigns. No evidence may be borrowed
   from a different configuration.
5. Product SLOs are written before measuring them. The current 300 MIPS tight-loop value may remain
   a micro-regression floor, but guest boot, login, RPC latency, and interactive workload SLOs are
   the release gates.
6. Two-vCPU sustained parallel work demonstrates real host overlap and at least 1.6x throughput
   over one vCPU without violating TSO/atomic/SMC tests.
7. The x86-64-v2 profile passes independent ISA vectors and the selected distro/application matrix.
8. Public policy is enabled only by an explicit release change after the signed receipts are
   reviewed; qualification bootstrap authority never becomes an implicit public escape hatch.

## Immediate next code slice

The highest-leverage next implementation is the vCPU runtime foundation, but it should begin only
after the fixture producer lands so every scheduler change can be tested against the same Linux
workload. The first slice should therefore contain:

1. `DoryPCX86QualificationFixtureManifest` plus a content-addressed builder/importer.
2. A source-bound PVH smoke command that emits a complete configuration and performance receipt.
3. `DoryPCVCPURuntime` with persistent workers, per-vCPU pending-work state, and deterministic mode
   as an explicit alternative implementation.
4. Machine-scoped atomic/coherence authority injected into interpreter and JIT contexts.
5. A two-vCPU litmus and parallel-work campaign that fails against the existing coordinator path
   and passes only when genuine overlap and ordering are both demonstrated.

Until those gates pass, x86_64 Linux should remain visible only to internal qualification tooling.
