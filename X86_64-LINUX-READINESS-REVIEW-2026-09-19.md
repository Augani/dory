# Dory x86_64 Linux readiness review — 2026-09-19 (updated 2026-09-20)

Reviewed on branch `codex/virtual-workspace-foundation` through implementation commit
`e7c6f1eec766de3f60f56464a8e8125c67e784ef`. Host: Apple M2
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
inputs exist, the safe no-raw-predictor production boundary is retained, and CPU RAM paths share a
machine-scoped byte-range authority for ordinary and locked access. Direct native loads and stores
also have explicit Arm ordering. Every vCPU receives one persistent owner job for the duration of
a public run. A new fail-closed internal policy admits exactly two interpreter vCPUs with
host-monotonic time and no caller-supplied PCI or platform-MMIO extensions to execute bounded guest
chunks concurrently. The default path, every native or mixed tier pair, extension devices, and the
public product path remain denied. The owning workers handle processor events, interrupt/NMI
delivery, and translation invalidation, including maintenance while parked. All guest MMIO/PIO
entry is conservatively serialized per machine without blocking ordinary RAM or DMA publication.

The latest exact clean boot-evidence candidate at `5c07bcf44` has two repeated PVH workload plus ACPI
S5 passes in baseline JIT and two more in the interpreter. The same Developer-ID-signed,
hardened-runtime runner completed every observation; interpreter batching reduced the real boot
from a 900-second timeout at 47.9 million instructions to two complete runs in 759.31 and 739.36
seconds. Exact qualification also found and fixed a halted-owner lost-wake defect: an interrupt
published while IF or priority blocked it could later become deliverable without a second
publication edge. The APIC/PIC regression and the complete current 429-test PC suite pass in debug,
release, and under Thread Sanitizer. None of this proves a production free-running multiprocessor
runtime, ordinary installed Linux lifecycle, or a notarized production package.

Release remains blocked by four boundaries:

1. Every requested vCPU now runs one persistent owner job with exact result/directive handoffs and
   worker-owned processor events/interrupts/invalidations while the coordinator retains clocks and
   machine lifecycle. Exactly one internal interpreter/interpreter pair can now execute ordinary
   and locked guest memory instructions concurrently through bounded rendezvous batches. That
   policy is not public, is not used by the signed Linux runner, excludes caller extension devices,
   and has not passed the complete tier, lifecycle, device, translation, SMC, or scaling matrix.
2. CPU ordinary accesses and unaligned, split-backing, and interpreter 16-byte locked fallbacks now
   share a machine-scoped range authority. Coordinated dispatch now publishes and acknowledges
   remote translation invalidations; current Virtio/xHCI DMA paths enter the same RAM authority;
   private executor storage cannot be invalidated or recycled during native entry. Free-running
   delivery/acknowledgement, cross-vCPU self-modifying-code proof, external/shared mappings, and the
   complete tier-pair matrix remain open. A machine-scoped guest device-entry domain now covers
   MMIO/PIO/PCI callbacks, but asynchronous built-in paths and public extension devices still need
   the documented callback-graph and free-running race audit.
3. Only `compat-v1` is launchable. The selected x86-64-v2 feature set is not yet completely
   implemented, independently referenced, migration-stable, and registered as a guest ABI.
4. Exact clean source commit `5c07bcf44` has two repeated single-vCPU PVH userspace and
   ACPI-poweroff passes in each of the interpreter and baseline-JIT tiers on this host using one
   Developer-ID-signed hardened-runtime runner. The runner is not notarized and Gatekeeper rejects
   it as `Unnotarized Developer ID`; Apple's notary service still returns HTTP 403 for the missing
   or expired developer-team agreement. The supported-host/guest/device matrix and complete UEFI
   install/reboot/cold-boot/update lifecycle campaign do not exist.

## Gate status

| Gate | Status | Evidence / reason |
|---|---|---|
| Public product admission | **Safe, closed** | `DoryReleaseSupportPolicy` keeps translated x86_64 Linux unavailable; daemon bootstrap requires explicit qualification authority. |
| Current PC/device concurrency validation | **Pass at source-test scope** | Current head passes all 429 PC tests across 56 suites in debug, release, and under Thread Sanitizer with no race report, plus 35 runner tests across 4 suites in debug and release. The artifact-backed Linux integration is separate and is not counted as boot evidence. |
| Optimized x86 qualification graph | **Pass at current implementation head** | With `DORY_X86_OPTIMIZED_QUALIFICATION=1`, the isolated release graph passes DBT 1,470 tests/141 suites, decode audit 135/22, PC 429/56, firmware 48/12, runner 35/4, and qualification 7/2. The graph excludes unrelated `DorydKitTests` without exposing debug-only injection hooks in production. This is current source-test evidence, not a signed boot receipt. |
| Release Linux runner build | **Pass** | The release PVH runner and content-addressed fixture importer build in the optimized qualification graph. |
| Release register-loop benchmark | **Provisional pass** | Current 5,000,000-instruction run: interpreter 1.13 MIPS, baseline JIT 746.17 MIPS, tier-one JIT 380.92 MIPS. This is a regression probe, not a ship gate. |
| Reproducible PVH inputs | **Pass on reviewed host** | A clean checkout reproduced and re-verified the pinned ISO-derived kernel, initrd, and symbols, then published all three through the content-addressed importer with exact manifest hashes. |
| Recent PVH boot/userspace | **Latest retained exact-candidate internal pass in both required CI tiers** | At clean `5c07bcf44`, two consecutive `rawTargetPrediction=none` baseline-JIT runs and two interpreter runs completed all seven userspace workloads and ACPI S5 with the same Developer-ID-signed hardened-runtime runner. These receipts predate the concurrent-pair changes, remain internal (`releaseQualified=false`), and cover one single-vCPU host/profile/device tuple; the runner is not notarized. |
| UEFI install, reboot, cold boot, update | **Fail: no exact-candidate evidence** | No retained campaign covers the complete installer and installed-disk lifecycle for this candidate. |
| Production predictor boundary | **Pass, conservative** | Production raw target prediction is disabled. Enabled `all` and `tier1-direct-chain` configurations reproduced a native slice that failed to return before the watchdog; neither is admitted. |
| Real SMP | **Fail for production admission** | An internal exact-two-vCPU interpreter policy now executes ordinary and locked guest instructions concurrently and proves real owner-thread overlap. It still rendezvous-batches through the coordinator, excludes extension devices, has no current Linux SMP receipt or scaling result, and leaves every public/native/mixed pair denied. |
| x86-64-v2 guest ABI | **Fail** | Profile registry still exposes only `baselineV1` / `compatibleV1`. |
| CPU scalar/locked range domain | **Pass at unit/integration scope** | Checked byte-array/mmap/translated/PC RAM, direct native loads/stores, aligned native atomics, interpreter unaligned and split-backing locked fallbacks, and interpreter/native CMPXCHG16B all enter one backing-address range authority. Missing authority makes direct native atomics fail closed. |
| Guest device-entry domain | **Pass at source-test scope** | All vCPU physical buses and the port bus share one recursive per-machine domain for MMIO, ECAM, PCI BAR, and PIO callbacks. Ordinary RAM and DMA synchronization stay outside it. Full PC testing found and retained a regression for an xHCI MMIO/DMA lock cycle; the corrected boundary passes the device-heavy TSan matrix. Asynchronous backend and extension-device qualification remains open. |
| Complete SMP memory contract | **Fail** | Worker-owned translation acknowledgement, current-device DMA range participation, private-executor code-storage hazard protection, and the conservative guest device-entry boundary are implemented and tested. The interpreter pair passes initial SB/LB/message-passing/MFENCE and XCHG/XADD/CMPXCHG cells, exact budget/fault tests, an external page-table invalidation test, and async poweroff join. IRIW, the remaining fence/locked/split cases, guest-driven local/remote TLB campaigns, cross-vCPU SMC/DMA, asynchronous callback audit, and every other tier/count remain open. |
| Release reproducibility | **Partial** | Fixture and candidate identities are content-addressed, and four clean exact-commit `5c07bcf44` PVH receipts bind one Developer-ID-signed runner across baseline JIT and interpreter. Twenty-run stability, notarized product packaging, the supported-host/guest/device matrix, and UEFI lifecycle receipts do not yet exist. |

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

### Exact signed baseline and interpreter PVH evidence (`5c07bcf44`)

`Qualification/X86_64/Evidence/2026-09-20-pvh-signed-baseline-interpreter-campaign.json`
binds the exact clean source, content-addressed fixture import, signed release runner, four complete
diagnostic receipts, and reviewed configuration:

| Run | Tier | Result | Elapsed | Retired instructions |
|---|---|---|---:|---:|
| `38ce4055-1345-4c12-a294-1bc67115476f` | baseline JIT + tier one | seven workloads + ACPI S5 | 414.32 s | 733,474,673 |
| `47765a0f-10df-41df-b0d8-3251d6070b95` | baseline JIT + tier one | seven workloads + ACPI S5 | 421.69 s | 733,612,796 |
| `be73236f-8320-45c7-a5f4-c452f57ed7e9` | interpreter | seven workloads + ACPI S5 | 759.31 s | 769,081,290 |
| `11cffbc9-e8c0-4906-b9d1-cdda4c203a80` | interpreter | seven workloads + ACPI S5 | 739.36 s | 766,808,878 |

All four observations used runner SHA-256
`ac6e580994eb80fea7a5413c0f92cdbd901770755f67df6786888df4575e80b8`, protected host pages,
`compat-v1`, one vCPU, no raw target prediction, and the same immutable Alpine fixture store. Every
receipt binds clean source `5c07bcf4423c1b64f1a501cec4a633728f2e6057`, a distinct lowercase
UUID, all seven exact workload names, and terminal host-observed `powered-off`. Baseline raw
prediction counters and pending work's maximum retired-instruction delay remained zero.

The interpreter averaged 749.33 seconds and completed twice inside the unchanged 900-second
qualification bound. Before the page-bounded fetch, memory-lease coalescing, and safe batching
work, the same tier retired only 47,858,000 instructions before timing out at 900 seconds. The
optimization is therefore accepted for this one PVH tuple without turning the timing into a broad
performance claim.

The first exact signed baseline attempt at preceding commit `e83eabf7d4` is retained as
`Qualification/X86_64/Evidence/2026-09-20-pvh-halted-owner-lost-wake-failure.json`. It stopped after
662,672,507 instructions at `pv_native_safe_halt` while local-APIC IRR still held deliverable vector
236, IF was set, no interrupt shadow remained, and processor priority permitted service. The
terminal-halt decision had only checked whether a *new* work generation was published. Commit
`5c07bcf44` rechecks already-published deliverable NMI, APIC, and PIC work before declaring terminal
HLT; deterministic APIC and PIC tests reproduce the no-second-edge boundary.

The runner and importer are signed by
`Developer ID Application: Augustus Otu (864H636QW4)` with a secure timestamp and hardened runtime;
the runner additionally has `com.apple.security.cs.allow-jit`. Strict `codesign` verification
passes. Gatekeeper still reports `Unnotarized Developer ID`. A fresh `notarytool history`
preflight with the configured `dory-notary` credential reached Apple but returned HTTP 403 because
the developer-team agreement is missing or expired. All four diagnostics therefore correctly keep
`releaseQualified=false`.

### Older clean signed session-cutover PVH evidence (`298d6668e`)

`Qualification/X86_64/Evidence/2026-09-20-pvh-single-vcpu-session-cutover-campaign.json` binds the
exact clean source, fixture-import receipt, signed release runner, complete diagnostic receipts,
and reviewed configuration:

| Run | Source | Result | Elapsed | Retired instructions |
|---|---|---|---:|---:|
| `f3f67d00-7bdd-412e-87c5-ec893e0a8d99` | clean `298d6668e` | seven workloads + ACPI S5 | 412.51 s | 733,907,967 |
| `5c6c65aa-eaac-4c7a-8baa-7b8b6ea1461f` | clean `298d6668e` | seven workloads + ACPI S5 | 411.02 s | 732,052,860 |

The new pair averages 411.77 seconds versus 366.82 seconds for the preceding `39345b6c4` pair,
about 12.3% slower. The source candidates differ by more than the worker-loop cutover, so this is
not a controlled attribution; it is retained as a performance-regression signal that must be
explained with matched instrumentation before release.

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
predecessor evidence, but none is used to stand in for current-head coverage.

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
28. The single-vCPU owner worker now applies its processor events, interrupt/NMI delivery, and
    page-table invalidation acknowledgement instead of returning architectural ownership to the
    coordinator. Session wake publication is coupled to per-vCPU generations, and mutable processor
    state is isolated in per-vCPU slots for the future multi-worker cutover.
29. Pending-work and quiescence acknowledgement no longer lose a racing publication. New work
    reopens an acknowledged barrier, targeted work advances only its processor, and deterministic
    tests cover both interleavings plus synchronous broadcast behavior under Thread Sanitizer.
30. A worker parked on a published result remains available for translation-maintenance requests
    without claiming the processor is architecturally idle or mutating lifecycle/interrupt state
    past that result. Repeated host-clock halt/interrupt tests and a dedicated maintenance-idleness
    regression pass.
31. Every vCPU physical bus and the port-I/O bus now share one per-machine recursive guest device
    domain. It serializes MMIO, ECAM, PCI BAR, and PIO entry while leaving ordinary RAM and DMA
    publication live and isolating independent machines. The first complete PC run exposed an xHCI
    cycle in which MMIO waited for an in-flight transfer while disconnect needed memory
    synchronization; `synchronize()` was removed from the guest device domain and the exact race is
    retained as a regression. The 401-test PC target and 99-test device-heavy TSan matrix pass.
32. Multi-vCPU public runs now install one machine-lifetime owner job per vCPU rather than creating
    a new worker closure for every bounded slice. Exact command/result envelopes, reservation
    return, stop handshakes, pending work, and parked-owner maintenance extend across all owners.
    General guest execution remains serialized by explicit admission; this foundation does not
    mislabel the frozen register-only overlap probe as SMP.
33. Interpreter instruction fetch reads a page-bounded window instead of re-fetching incremental
    prefixes, preserves short-backing and page-fault boundaries, coalesces covered ordinary-memory
    leases for one safe batch, and polls asynchronous work between batches. Batches terminate at
    page-table writes, REP/yield, HLT, exceptions, interrupt-state changes, and other precise
    boundaries. Host-monotonic interpreter execution deliberately remains per-instruction. Two
    exact signed PVH interpreter runs now finish inside the fixed 900-second bound.
34. Exact signed qualification exposed a halted-owner lost wake after Linux's sleep workload. A
    local-APIC timer request was already in IRR, IF and priority later allowed it, but no second
    generation edge existed to wake the terminal-halt decision. The decision now checks deliverable
    NMI, APIC, and PIC state, with APIC/PIC regressions that publish while IF is clear and require
    delivery after `STI; HLT`. The 411-test PC suite, 35 runner tests, and 96-test focused Thread
    Sanitizer matrix pass after the repair.
35. An internal, fail-closed multiprocessor policy now admits only an exact two-vCPU interpreter
    pair with host-monotonic time and no caller-supplied PCI or platform-MMIO extensions. Both
    persistent owners reserve disjoint global budget before a lost-wakeup-free rendezvous, execute
    concurrently, join before architectural state is inspected, return unretired reservations,
    and select faults/stops deterministically. Default and public behavior remain serialized.
36. Real protected-mode guest loops now run 2,000 iterations each of Store Buffering, Load
    Buffering, Message Passing, MFENCE substitution, implicit-locked XCHG, and locked CMPXCHG on
    the admitted pair; a 24,000-instruction locked XADD campaign proves no lost updates. The probe
    requires two actual concurrent owner entries, so these tests cannot pass through the serial
    default. All seven pass under Thread Sanitizer.
37. The expanded full PC run exposed three tests whose two-second success assertions depended on
    work starting promptly on the shared dispatch pool. Device-domain, translation-invalidation,
    and xHCI disconnect tests now use dedicated host threads and explicit start observations. The
    exact three-test sanitizer run passes, followed by the complete 429-test/56-suite PC target
    under Thread Sanitizer.

These fixes establish a genuine but narrow concurrent interpreter pair. They do not substitute for
asynchronous device callback audit, complete cross-vCPU translation/code-lifetime proof, the full
tier/count matrix, Linux SMP and scaling evidence, UEFI lifecycle, or supported-host campaigns.

## Remaining engineering work

### P0 — Extend the run-session worker loop to SMP

The bisectable implementation sequence and ownership invariants are recorded in
`docs/virtualization/x86-free-running-vcpu-plan.md`.

The session foundation, serialized pending-work repair, and single-vCPU long-running cutover were
implemented at `298d6668e`. Through `e0cfdcdc8`, the owner worker also handles its processor events,
interrupt/NMI delivery, pending generations, and translation invalidation, including parked-owner
maintenance, and every vCPU keeps one owner job for the public run. Exact checkpoint `5c07bcf44`
has repeated baseline and interpreter PVH evidence. Commit `40db03245` adds the internal exact-two-
vCPU interpreter policy described above. It is qualification scaffolding, not a public promotion,
and the SMP gate remains closed.

- Complete the promotion matrix for the internal interpreter/interpreter admission before exposing
  it to Linux or product policy. Each owner already retains its architectural state, paging/TLB
  context, and exact result/budget envelope across command boundaries.
- Move the remaining clock/lifecycle coordination into explicit quiescence rendezvous so ordinary
  execution does not return to a central coordinator after every bounded command.
- Keep deterministic single-thread replay as a separate explicit implementation, not as the
  production SMP scheduler.
- Define worker startup, stop, pause, reset, snapshot, and failure ownership so device/lifecycle
  operations rendezvous only when required and cannot strand a worker.
- Retire the frozen one-instruction overlap path only after persistent workers cover its tests.
- Preserve the implemented parked-owner maintenance for every vCPU so invalidation publication
  cannot wait on a coordinator that is itself waiting for a result response or quiescence barrier.

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
- Complete the asynchronous device callback graph in
  `docs/virtualization/x86-device-shared-state-audit.md`. The machine guest-entry domain is present,
  but clock/input/reset/deferred-completion/interrupt sinks and public MMIO/PCI extensions still
  need sustained-SMP and teardown qualification.
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
  the reviewed host's current single-vCPU interpreter and baseline-JIT/no-predictor tuples each
  have two clean signed passes.
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

Persistent owner jobs, the conservative machine device-entry boundary, single-vCPU PVH parity,
interpreter viability, and an internal exact-two-vCPU interpreter admission are implemented. The
first guest-code cells cover SB, LB, message passing, MFENCE, XCHG, XADD, and CMPXCHG with proven
owner overlap. Baseline, mixed, optimizing, caller extension devices, and product admission remain
denied by default. The next slice is:

1. Finish the built-in asynchronous callback review and add concurrent clock/input/reset,
   completion/interrupt, hot-unplug, and teardown tests. Require each admitted
   `platformMMIODevices`/`pciFunctions` implementation to declare and prove its callback, DMA,
   interrupt-publication, and teardown contract.
2. Add guest-driven page-table rewrite plus local and remote targeted/global invalidation while the
   other owner is executing. Then add CPU and DMA mutation/fetch of active code, protected-page
   rotation, and generation-publication tests.
3. Complete the interpreter-pair memory matrix: IRIW, SFENCE/LFENCE, the remaining locked families,
   ordinary-reader mixtures, unaligned/cache-line/page splits, faulting second pages, and 8/16-byte
   compare/exchange. Add pause/reset/snapshot/teardown races and exact stop arbitration for each.
4. Replace coordinator rendezvous batching with the documented sustained owner-loop/quiescence
   protocol, then demonstrate a shared-memory workload with real host overlap and at least 1.6x
   two-vCPU throughput over one vCPU without changing correctness policy.
5. Add baseline/baseline, interpreter/baseline, and optimizing combinations one at a time only
   after the same matrix passes for that exact pair. Retain the interpreter as the oracle and keep
   raw host-address prediction disabled.
6. Continue the x86-64-v2 semantic/reference program and UEFI installed-disk lifecycle in parallel;
   neither should be deferred behind Tier2 performance work.
7. Re-run the complete debug, optimized, and sanitizer graphs plus content-addressed PVH evidence
   after each promoted execution pair. Once the product tuple and supported host classes are frozen
   and the Apple team agreement is restored, execute the clean notarized PVH/UEFI matrix and only
   then consider a separate public-policy change.

Until those gates pass, x86_64 Linux should remain visible only to internal qualification tooling.
