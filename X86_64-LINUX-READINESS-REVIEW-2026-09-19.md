# Dory x86_64 Linux readiness review — 2026-09-19 (updated 2026-09-20)

Reviewed on branch `codex/virtual-workspace-foundation` through exact clean implementation commit
`298d6668e21ac291193978dc082cb518b3df9027`. Host: Apple M2
Pro, macOS 27.2, Xcode 27.0, Swift 6.4. The working checkout also contains a pre-existing user
modification to `scripts/arm-ubuntu-scenario-driver.sh`; it was not changed, staged, or used as
release evidence during this review.

This review supersedes the x86_64 conclusions in `READINESS-REVIEW-2026-09-15.md` where current
source, configuration, and tests differ. Historical receipts remain useful measurements, but only
an exact, clean candidate can satisfy a release gate.

## Verdict

**Dory is not ready to expose x86_64 Linux as a supported customer runtime. Keep the production
availability gate closed.**

The single-vCPU engine is suitable for continued internal Linux qualification. Reproducible PVH
inputs exist, the optimized qualification graph executes, the safe no-raw-predictor production
boundary has repeated exact-head userspace evidence, and CPU RAM paths now share a machine-scoped
byte-range authority for ordinary and locked access. Direct native loads and stores also have
explicit Arm ordering. The single-vCPU path now lends its persistent worker one long-running
run-session job, and that exact clean implementation has focused debug, optimized,
Thread-Sanitizer, and two repeated PVH workload plus ACPI-poweroff passes with one
Developer-ID-signed hardened-runtime runner. None of this proves a free-running multiprocessor
runtime or a notarized production package.

Release remains blocked by four boundaries:

1. The one-vCPU production path now runs one persistent worker job with exact result/directive
   handoffs while the coordinator retains clocks and events. Requests above one vCPU still use the
   bounded coordinator scheduler and frozen overlap path. There is no sustained shared-memory SMP
   runtime in which every vCPU owns a dispatch loop.
2. CPU ordinary accesses and unaligned, split-backing, and interpreter 16-byte locked fallbacks now
   share a machine-scoped range authority. Coordinated dispatch now publishes and acknowledges
   remote translation invalidations; current Virtio/xHCI DMA paths enter the same RAM authority;
   private executor storage cannot be invalidated or recycled during native entry. Free-running
   delivery/acknowledgement, cross-vCPU self-modifying-code proof, external/shared mappings, and the
   complete tier-pair matrix remain open.
3. Only `compat-v1` is launchable. The selected x86-64-v2 feature set is not yet completely
   implemented, independently referenced, migration-stable, and registered as a guest ABI.
4. Exact clean source commit `298d6668e` has two repeated single-vCPU PVH userspace and ACPI-poweroff
   passes on this host using a Developer-ID-signed hardened-runtime runner. The runner is not
   notarized and Gatekeeper rejects it as `Unnotarized Developer ID`; the supported-host/tier matrix
   and complete UEFI install/reboot/cold-boot/update lifecycle campaign still do not exist.

## Gate status

| Gate | Status | Evidence / reason |
|---|---|---|
| Public product admission | **Safe, closed** | `DoryReleaseSupportPolicy` keeps translated x86_64 Linux unavailable; daemon bootstrap requires explicit qualification authority. |
| Focused debug atomic/interpreter validation | **Pass** | The cutover source passes the full 390-test PC suite across 52 suites, plus the 35-test boot-runner/stress group. The 62 direct-kernel and 17 run-session suites pass debug, optimized, and Thread Sanitizer. |
| Optimized x86 qualification graph | **Pass** | 2,073 tests passed at implementation candidate `fc6ab7fd8` across `DoryDBTX86Tests` (1,466), decode audit (135), PC (382), firmware (48), Linux boot runner (35), and PC qualification (7). The graph excludes unrelated `DorydKitTests` without exposing debug-only injection hooks in production. |
| Release Linux runner build | **Pass** | The release PVH runner and content-addressed fixture importer build in the optimized qualification graph. |
| Release register-loop benchmark | **Provisional pass** | Current 5,000,000-instruction run: interpreter 1.13 MIPS, baseline JIT 746.17 MIPS, tier-one JIT 380.92 MIPS. This is a regression probe, not a ship gate. |
| Reproducible PVH inputs | **Pass on reviewed host** | A clean checkout reproduced and re-verified the pinned ISO-derived kernel, initrd, and symbols, then published all three through the content-addressed importer with exact manifest hashes. |
| Recent PVH boot/userspace | **Exact-head internal pass** | Two consecutive `rawTargetPrediction=none` runs at clean `298d6668e` completed all seven userspace workloads and ACPI S5 through the new single-vCPU long-running worker path with the same Developer-ID-signed hardened-runtime runner. Receipts remain internal (`releaseQualified=false`), single-vCPU evidence for one host and one tier/configuration; the runner is not notarized. |
| UEFI install, reboot, cold boot, update | **Fail: no exact-candidate evidence** | No retained campaign covers the complete installer and installed-disk lifecycle for this candidate. |
| Production predictor boundary | **Pass, conservative** | Production raw target prediction is disabled. Enabled `all` and `tier1-direct-chain` configurations reproduced a native slice that failed to return before the watchdog; neither is admitted. |
| Real SMP | **Fail** | One vCPU now uses a single long-running worker job. More than one vCPU still uses coordinator-submitted bounded slices; the narrow frozen register-only overlap probe is not a Linux SMP runtime. |
| x86-64-v2 guest ABI | **Fail** | Profile registry still exposes only `baselineV1` / `compatibleV1`. |
| CPU scalar/locked range domain | **Pass at unit/integration scope** | Checked byte-array/mmap/translated/PC RAM, direct native loads/stores, aligned native atomics, interpreter unaligned and split-backing locked fallbacks, and interpreter/native CMPXCHG16B all enter one backing-address range authority. Missing authority makes direct native atomics fail closed. |
| Complete SMP memory contract | **Fail** | Coordinated translation publication/acknowledgement, current-device DMA range participation, and private-executor code-storage hazard protection are implemented and tested. Free-running acknowledgement, cross-vCPU SMC, external/shared mappings, and the full tier-pair litmus matrix remain open. |
| Release reproducibility | **Partial** | Fixture and candidate identities are content-addressed, and two clean exact-head PVH receipts bind one Developer-ID-signed runner. Twenty-run stability, notarized product packaging, the supported-host/tier matrix, and UEFI lifecycle receipts do not yet exist. |

## Measurements that must not be conflated

### Current microbenchmark

`swift run -c release dory-x86-throughput-benchmark 5000000` on implementation commit
`8ca198c212` (the later persistent-worker refactor does not change this benchmark's engine path):

| Tier | MIPS | Scope |
|---|---:|---|
| Interpreter | 1.13 | Tight register loop |
| Baseline JIT | 746.17 | Tight register loop, one accepted direct chain |
| Tier-one JIT | 380.92 | Tight register loop, one accepted direct chain |

This proves that resident generated code can be fast. It does not exercise paging, TLB misses,
loads/stores, locked operations, interrupts, devices, firmware, or Linux. Tier one remains about
51% of baseline on this workload; qualification must explain or remove that inversion instead of
selecting the better result after the fact.

### Clean signed exact-head PVH evidence

`Qualification/X86_64/Evidence/2026-09-20-pvh-single-vcpu-session-cutover-campaign.json` binds the
exact clean source, fixture-import receipt, signed release runner, complete diagnostic receipts,
and reviewed configuration:

| Run | Source | Result | Elapsed | Retired instructions |
|---|---|---|---:|---:|
| `f3f67d00-7bdd-412e-87c5-ec893e0a8d99` | clean `298d6668e` | seven workloads + ACPI S5 | 412.51 s | 733,907,967 |
| `5c6c65aa-eaac-4c7a-8baa-7b8b6ea1461f` | clean `298d6668e` | seven workloads + ACPI S5 | 411.02 s | 732,052,860 |

Both used runner SHA-256
`5dc27874aa8b1f26fe3bde5b88869ce1e60f01dba20e023f5327395a51836bb4`, protected host pages,
`compat-v1`, baseline JIT with tier one enabled, one vCPU, no raw target prediction, and the exact
content-addressed Alpine fixture. Both full receipts report a clean source tree, a matching guest
receipt, all requested workloads passed, and terminal `powered-off`; raw prediction counters and
pending work's maximum retired-instruction delay remained zero.

The runner is signed by `Developer ID Application: Augustus Otu (864H636QW4)` with a secure
timestamp, hardened runtime, and `com.apple.security.cs.allow-jit`. Strict `codesign` verification
passes. It is not notarized: `spctl` rejects it as `Unnotarized Developer ID`. The diagnostic schema
therefore correctly remains `releaseQualified=false`; this is strong internal exact-candidate
evidence, not a distributable product release qualification. The configured `dory-notary`
credential is present, but Apple's service rejected the read-only history preflight with HTTP 403
because the developer team has a missing or expired agreement. A team account holder must resolve
that agreement before any exact candidate can be submitted.

The earlier clean `39345b6c4`, `c9fa7e1eb`, and `121d86faa` two-run campaigns remain retained as
predecessor evidence, but none is used to stand in for exact-head coverage.

### Raw-predictor boundary evidence

`Qualification/X86_64/Evidence/2026-09-19-pvh-raw-predictor-campaign.json` records the accepted
correctness boundary:

| Run | Source | Predictors | Result | Elapsed | Retired instructions |
|---|---|---|---|---:|---:|
| `084eea32-ab67-4922-844f-475975af8007` | `5d888565b3` | none | seven workloads + ACPI S5 | 262.73 s | 732,285,985 |
| `db664692-b11b-4681-864d-5ee712b9f323` | `5d888565b3` | none | seven workloads + ACPI S5 | 254.14 s | 732,309,747 |

Both used the exact runner SHA-256
`d3b7a1ccdb19679aa6217fa520ffd26796c3f5321af7ca29eae9a9073e2ad594`, protected host pages,
`compat-v1`, baseline JIT with tier one enabled, one vCPU, and the same content-addressed Alpine PVH
fixture. Raw direct-chain, IBTC, and shadow-return counters remained zero, and pending work's
maximum retired-instruction delay was zero. Both receipts deliberately remain internal evidence
because the tree was dirty and the public release gate was closed.

The same campaign rejected raw prediction. `all` reached the wall budget, and
`tier1-direct-chain` passed once and then reached the wall budget on a repeat. Production therefore
keeps all raw host-address prediction disabled.

### Older retained guest evidence

- `docs/virtualization/evidence/a05-tier1-2026-09-12/pvh-tier1-direct-chain-acceptance.json`
  contains two successful Alpine PVH userspace runs from an older candidate at about 3.2 MIPS. Its
  own receipt leaves combined prediction/A05.3 open.
- `docs/virtualization/evidence/p06-pc-2026-09-06/tier-comparison-rpcdiag.json` records an older
  optimizing-JIT preview taking 3,901 seconds to agent bind-ready and 218.725 seconds for
  `/bin/true` over RPC. It is not release qualification.

## Issues fixed during this review

1. The debug interpreter entry stack was reduced from an approximately 473 KiB frame to about
   15 KiB by separating fetch/decode and string execution. Canonical REP and XSTATE boundary tests
   no longer crash worker stacks.
2. Profile-sensitive `F3 0F BC/BD` lowering no longer substitutes BSF/BSR when BMI1/LZCNT semantics
   are advertised but not natively implemented.
3. Publication tests retain and assert the exact-byte revalidation immediately before native code
   publication.
4. TLB invalidation tests now seed real native hits before claiming to revoke them.
5. Atomic/pending-work probes no longer starve on the global test pool, and tests that measure one
   shared gate are serialized within their suite.
6. The physical x86 reference corpus is an immutable SwiftPM resource instead of a deleted external
   path.
7. UEFI coherence expectations and Swift 6.4 diagnostics were corrected without weakening
   production checks.
8. A checked-in, content-addressed PVH fixture manifest/importer now validates size and SHA-256,
   publishes durable receipts, and refuses mutable-path identity.
9. PVH receipts bind the exact candidate source state, runner hash, fixture hashes, host class,
   profile, tier, memory policy, predictor configuration, vCPU count, and memory size.
10. Production raw target prediction is disabled after the accepted configuration boundary proved
    enabled raw chaining non-repeatable.
11. The package has an isolated optimized x86 qualification graph and CI receipt instead of
    compiling debug-only daemon test hooks into production modules.
12. Atomic coordination is machine scoped rather than process global; independent VMs do not share
    one lock/failure domain.
13. Direct native guest loads and stores now both contain conservative `DMB ISH` ordering. The test
    model correctly treats Store Buffering 0/0 as permitted and Load Buffering 1/1 as forbidden.
14. Ordinary aligned scalar RAM accesses and native locked helpers share one host-atomic domain.
    Misaligned host-atomic requests are rejected instead of silently claiming atomicity.
15. Interpreter aligned locked ALU, unary, XCHG, CMPXCHG, XADD, bit-test/update, and CMPXCHG8B
    forms execute through host compare/exchange transactions. Losing CAS attempts discard candidate
    architectural state, preserving precise flags and registers.
16. `DoryPCVCPURuntime` now owns persistent host threads for the complete machine lifetime. A
    public `run` borrows those workers without recreating them, consumes exact per-run CPU-time
    deltas, and joins every parallel submission before propagating a failure or releasing the
    execution gate.
17. A clean isolated checkout of `121d86faa` reproduced the pinned PVH artifacts, imported them
    through the immutable store, built one release runner, and completed two consecutive seven-
    workload plus ACPI-poweroff runs. The full diagnostic receipts and their campaign binding are
    retained under `Qualification/X86_64/Evidence`.
18. `DoryX86MemoryAccessCoordinator` now provides fair, machine-scoped, backing-address range
    leases. Checked RAM and direct native scalar accesses enter ordinary leases; native atomics do
    the same after the machine atomic gate; interpreter unaligned, split-backing, and CMPXCHG16B
    fallbacks acquire one exclusive multi-range lease only after complete fault preflight. Focused
    contention tests cover overlapping/disjoint admission, sparse backing, direct native helpers,
    fail-closed authority loss, unaligned locked operations, and 16-byte compare/exchange.
19. `DoryX86PhysicalRAM` now requires range-coordinated backing memory at its type boundary instead
    of allowing the PC bus to fabricate an unrelated coordinator. Direct translated host mapping
    fails closed when the physical-memory implementation cannot prove the same range authority.
20. Every current Virtio and xHCI DMA transfer was traced through `DoryPCPhysicalMemoryBus` into
    range-coordinated RAM and translated-code lifetime invalidation. Integration tests prove
    overlapping exclusion, disjoint progress, and protected-code generation revocation.
21. A machine-scoped translation-invalidation coordinator now publishes targeted/global
    invalidations to every paging unit and baseline/optimizing native TLB, records required and
    acknowledged generations per vCPU, coalesces page-table-write flushes before the next dispatch,
    and handles generation wrap with a global reset. This closes the serialized coordinator path,
    not the future free-running delivery protocol.
22. Baseline and optimizing executable regions remain private to each vCPU executor, and the
    executor lock spans native entry, invalidation, retirement, and storage rotation. A
    deterministic blocked-native-execution test proves `invalidateAll()` cannot return or recycle
    storage while generated code is still executing.
23. A clean detached `c9fa7e1eb` checkout rebuilt the universal FFI artifact and release runner,
    re-imported every manifest-bound PVH object, signed the runner with Developer ID plus hardened
    runtime/`allow-jit`, and completed two consecutive seven-workload plus ACPI-poweroff runs. The
    retained campaign records the successful strict signature check and the still-open notarization
    boundary.
24. `DoryPCRunSession` now provides an isolated, machine-scoped foundation for exact shared budget
    reservation/return, stable stop arbitration, generation-safe pending work, coalesced all-worker
    quiescence, and lost-wakeup-free observation. Eleven protocol tests include 10,000-operation
    concurrent budget, stop, publication, and quiescence campaigns and pass Thread Sanitizer. It is
    deliberately unwired, so it cannot silently alter the current guest path before worker-loop
    parity gates exist.
25. The current serialized dispatcher no longer has a lost-clear window between draining device
    work and clearing native JIT poll bytes. Publication and acknowledgement now share one leaf
    generation boundary: a racing edge either prevents the clear or restores the byte afterward.
    Four deterministic interleaving tests cover both race orders and synchronous in-dispatch work,
    and the suite passes Thread Sanitizer.
26. A clean managed worktree at exact source commit `39345b6c4` rebuilt the universal FFI artifact,
    release runner, and fixture importer; re-imported every manifest-bound PVH object; and signed
    the runner with Developer ID, hardened runtime, a secure timestamp, and `allow-jit`. Two
    consecutive runs completed all seven userspace workloads and ACPI S5 in 367.85 and 365.79
    seconds. Strict signature verification passes; notarization remains externally blocked by the
    developer-team agreement.
27. The one-vCPU production dispatcher now submits exactly one long-running host-worker job per
    `run`, exchanges exact result/directive envelopes without worker run-ahead, returns unused
    reservations on halt/fault/failure, merges execution and CPU-time counters once, and completes
    the stop handshake before join or error propagation. The 62 direct-kernel and 17 session tests
    pass debug, optimized, and Thread Sanitizer across interpreter, baseline, and optimizing tiers.
    A clean `298d6668e` runner then completed two consecutive seven-workload plus ACPI-poweroff PVH
    runs in 412.51 and 411.02 seconds.

These fixes make the current single-vCPU and CPU memory-exclusion signal substantially stronger.
They do not substitute for the missing free-running SMP delivery protocol, concurrent cross-vCPU
translation/code-lifetime proof, UEFI lifecycle, or supported-matrix campaigns.

## Remaining engineering work

### P0 — Extend the run-session worker loop to SMP

The bisectable implementation sequence and ownership invariants are recorded in
`docs/virtualization/x86-free-running-vcpu-plan.md`.

The session foundation, serialized pending-work repair, and single-vCPU long-running cutover are
implemented through `298d6668e`. The single-vCPU parity/PVH gate is closed; the SMP gate is not.

- Extend the single-vCPU result/directive loop across every admitted vCPU. Each worker must own its
  architectural state, JIT context, native TLB, and code-cache cursor without returning ownership
  to the coordinator after every slice.
- Deliver interrupt, timer, cancellation, and tier-work requests through per-vCPU atomic pending
  work. Do not return to a central coordinator after every instruction budget.
- Keep deterministic single-thread replay as a separate explicit implementation, not as the
  production SMP scheduler.
- Define worker startup, stop, pause, reset, snapshot, and failure ownership so device/lifecycle
  operations rendezvous only when required and cannot strand a worker.
- Retire the frozen one-instruction overlap path only after persistent workers cover its tests.

### P0 — Finish the SMP memory and translation contract

The normative target is `docs/virtualization/x86-smp-memory-contract.md`. CPU byte-range exclusion
is implemented; the remaining contract is not just more stress on that lock:

- Keep the audited Virtio/xHCI DMA paths on the existing backing-address authority. Inventory every
  external and shared-mapping adapter before admission, fail closed when it cannot prove the same
  coordinate system, and extend overlap/disjoint tests to each admitted adapter.
- Extend split-cache-line, split-page, and 16-byte contention/fault tests across translated memory,
  PC physical routing, every admitted execution tier, and code-protected pages.
- Move the existing remote TLB/address-space generation publication and acknowledgement into the
  free-running dispatch protocol so a target cannot retire an access under an invalidated
  translation without returning to the central coordinator.
- Add cross-vCPU code mutation/fetch and page-table-write campaigns. Preserve the current private
  executor storage invariant; require explicit epoch/hazard retirement before any future shared
  executable cache can recycle storage.
- Audit every external/shared-memory writer for RAM ordering, page-table invalidation, and
  translated-code generation revocation.
- Execute the full interpreter/baseline/optimizing pair matrix for TSO, locks, fences, TLBs, DMA,
  self-modifying code, and code-cache rotation at 1, 2, and 4 vCPUs.

### P0 — Ship an honest x86-64-v2 profile

Keep `compat-v1` immutable. Add a new registered profile only after the selected SSE3, SSSE3,
SSE4.1, SSE4.2/CRC32, POPCNT, PAT, and XSAVE/XCR0 contract is complete. Every advertised feature
needs decoder/execution agreement, independent physical reference vectors including flags and
faults, interpreter/JIT parity, stable CPUID/MSR migration identity, and an explicit fallback
policy.

Do not advertise AVX/AVX2 to satisfy probes. They require complete YMM state, VEX upper-lane rules,
XSAVE images, exception behavior, and two-half NEON lowering in a later profile.

### P0 — Complete the exact-candidate PVH matrix and UEFI campaigns

- Package and notarize the production candidate. The reviewed internal runner is Developer-ID
  signed with hardened runtime and `allow-jit`, but Gatekeeper correctly rejects it while
  unnotarized. The installed notary credential currently reaches Apple but is blocked by a missing
  or expired developer-team agreement (HTTP 403), which must be resolved by an account holder.
- Repeat PVH correctness on every supported host class and every admitted production tier/config;
  the reviewed host's current single-vCPU baseline-JIT/no-predictor tuple has two clean signed
  passes.
- For UEFI, retain installer boot, install, installer reboot, cold boot from disk, package update,
  shutdown, recovery, and negative/fault injection evidence.
- Exercise storage, network, entropy, clock, console/input, and graphics where applicable.
- Run 1, 2, and 4 vCPUs only after the persistent runtime and SMP contract qualify those counts.
- Require two clean campaigns for the exact production tuple; do not borrow evidence from another
  predictor, profile, firmware, device ABI, write policy, or binary.

### P1 — Make performance evidence representative

Extend the benchmark into named, non-substitutable cells for RAM load/store/RMW, paging/TLB hit and
miss distributions, branch prediction, fallback boundaries, interrupt/device-exit pressure, and
1/2/4-vCPU parallel work. Record wall time, thread CPU, retired guest instructions, native
dispatcher entries, compilation/rotation, TLB counters, callbacks, fallback sites, and direct-chain
acceptance. Explain the tier-one/baseline inversion before changing thresholds.

### P1 — Bound the remaining dispatcher stack

`executeDecodedStep` still has an approximately 394 KiB debug frame even though callers no longer
stack it under decoding. Split it by execution domain and add a CI stack-frame ceiling below 64 KiB
per dispatcher so a future switch case cannot silently recreate the crash.

## Activation criteria

Do not change public availability until all of these are true:

1. Twenty consecutive debug and optimized qualification runs complete with zero crash, hang,
   failure, or unexplained nondeterminism.
2. A clean checkout reproduces every boot artifact and verifies every content hash.
3. Current signed PVH and UEFI candidates complete the required userspace and lifecycle matrices on
   every supported host class.
4. The exact production tuple—CPU profile, protected-page policy, predictor set, firmware, devices,
   vCPU count, and signed binaries—passes two clean campaigns.
5. Product SLOs are written before measuring them. Tight-loop MIPS remains a regression floor;
   guest boot, login, RPC, update, shutdown, and interactive latency are release gates.
6. Two-vCPU sustained shared-memory work demonstrates real host overlap and at least 1.6x throughput
   over one vCPU without violating TSO, atomicity, TLB, DMA, or SMC tests.
7. The x86-64-v2 profile passes independent ISA vectors and the selected distro/application matrix.
8. Public policy is enabled only by an explicit release change after signed receipts are reviewed;
   qualification bootstrap authority never becomes an implicit public escape hatch.

## Immediate next code slice

The single-vCPU cutover and exact PVH repeat are complete. The next implementation slice should
establish the multiprocessor ownership and memory foundations together:

1. Move per-vCPU event, interrupt/NMI, pending-work, and remote translation-generation delivery
   onto the owning worker, including halted/native/fault/stop races and wrap-safe quiescence.
2. Finish the device/shared-state lock-order audit and external/shared-mapping inventory against
   the existing backing-address range rendezvous.
3. Admit interpreter/interpreter two-vCPU sustained shared-memory execution first, with TSO,
   locked-operation, invalidation, DMA, SMC, code-cache, and throughput gates that fail against the
   bounded coordinator path. Add baseline, mixed, and optimizing pairs only after their matrices.
4. Re-run the content-addressed PVH fixture after each promoted slice and retain exact receipts.
5. Execute the clean notarized PVH/UEFI matrix only after the production tuple and supported host
   classes are frozen.

Until those gates pass, x86_64 Linux should remain visible only to internal qualification tooling.
