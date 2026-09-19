# Dory x86_64 Linux readiness review — 2026-09-19

Reviewed on branch `codex/virtual-workspace-foundation` through implementation commit
`121d86faa`. Host: Apple M2 Pro, macOS 27.2, Xcode 27.0, Swift 6.4. The working checkout also
contains a pre-existing user modification to `scripts/arm-ubuntu-scenario-driver.sh`; it was not
changed, staged, or used as release evidence during this review.

This review supersedes the x86_64 conclusions in `READINESS-REVIEW-2026-09-15.md` where current
source, configuration, and tests differ. Historical receipts remain useful measurements, but only
an exact, clean candidate can satisfy a release gate.

## Verdict

**Dory is not ready to expose x86_64 Linux as a supported customer runtime. Keep the production
availability gate closed.**

The single-vCPU engine is now suitable for continued internal Linux qualification. Reproducible
PVH inputs exist, the optimized qualification graph executes, the safe no-raw-predictor production
boundary has repeated userspace evidence, scalar RAM and aligned locked operations share a host
atomic domain, and direct native loads and stores have explicit Arm ordering. None of that proves a
free-running multiprocessor runtime.

Release remains blocked by four boundaries:

1. PC host threads are now persistent for the machine lifetime, but guest execution remains
   slice/coordinator driven. It does not provide sustained, shared-memory execution in which every
   vCPU stays in its own dispatch loop.
2. Unaligned, split-cache-line, split-page, and interpreter 16-byte locked operations still need a
   machine-scoped exclusion/rendezvous mechanism that also excludes ordinary accesses. Remote TLB,
   code-retirement, DMA, and self-modifying-code protocols also need free-running SMP proof.
3. Only `compat-v1` is launchable. The selected x86-64-v2 feature set is not yet completely
   implemented, independently referenced, migration-stable, and registered as a guest ABI.
4. The exact implementation candidate now has two clean, repeated single-vCPU PVH userspace and
   ACPI-poweroff passes on this host. It still lacks production signing, the supported-host/tier
   matrix, and the complete UEFI install/reboot/cold-boot/update lifecycle campaign.

## Gate status

| Gate | Status | Evidence / reason |
|---|---|---|
| Public product admission | **Safe, closed** | `DoryReleaseSupportPolicy` keeps translated x86_64 Linux unavailable; daemon bootstrap requires explicit qualification authority. |
| Focused debug atomic/interpreter validation | **Pass** | 106 tests in 3 suites passed: the complete interpreter suite, compare/exchange write/fault semantics, and mixed interpreter/native concurrency probes. |
| Optimized x86 qualification graph | **Pass** | 2,036 tests passed across `DoryDBTX86Tests` (1,450), decode audit (135), PC (361), firmware (48), Linux boot runner (35), and PC qualification (7). The graph excludes unrelated `DorydKitTests` without exposing debug-only injection hooks in production. |
| Release Linux runner build | **Pass** | The release PVH runner and content-addressed fixture importer build in the optimized qualification graph. |
| Release register-loop benchmark | **Provisional pass** | Current 5,000,000-instruction run: interpreter 1.13 MIPS, baseline JIT 746.17 MIPS, tier-one JIT 380.92 MIPS. This is a regression probe, not a ship gate. |
| Reproducible PVH inputs | **Pass on reviewed host** | A clean checkout reproduced and re-verified the pinned ISO-derived kernel, initrd, and symbols, then published all three through the content-addressed importer with exact manifest hashes. |
| Recent PVH boot/userspace | **Clean exact-candidate pass, bounded scope** | Two consecutive `rawTargetPrediction=none` runs at `121d86faa` completed all seven userspace workloads and ACPI S5 from a clean tree with the same release runner. Receipts remain internal (`releaseQualified=false`), ad-hoc signed, single-vCPU evidence for one host and one tier/configuration. |
| UEFI install, reboot, cold boot, update | **Fail: no exact-candidate evidence** | No retained campaign covers the complete installer and installed-disk lifecycle for this candidate. |
| Production predictor boundary | **Pass, conservative** | Production raw target prediction is disabled. Enabled `all` and `tier1-direct-chain` configurations reproduced a native slice that failed to return before the watchdog; neither is admitted. |
| Real SMP | **Fail** | Machine-owned host workers persist across `run` calls, but the coordinator still submits and awaits bounded slices. The narrow frozen register-only overlap probe is not a Linux SMP runtime. |
| x86-64-v2 guest ABI | **Fail** | Profile registry still exposes only `baselineV1` / `compatibleV1`. |
| Aligned scalar atomic domain | **Pass at unit/integration scope** | Swift byte-array/mmap RAM, interpreter aligned scalar locked families, and native JIT helpers use the same lock-free sequentially consistent 1/2/4/8-byte host atomics. |
| Complete SMP memory contract | **Fail** | Direct native loads/stores are conservatively ordered and aligned scalar atomics interoperate, but split/unaligned/16-byte exclusion, remote invalidation acknowledgement, and the full tier-pair litmus matrix remain open. |
| Release reproducibility | **Partial** | Fixture and candidate identities are content-addressed, and two clean exact-candidate PVH receipts are retained. Twenty-run stability, production signing, the supported-host/tier matrix, and UEFI lifecycle receipts do not yet exist. |

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

### Clean exact-candidate PVH evidence

`Qualification/X86_64/Evidence/2026-09-19-pvh-clean-exact-candidate-campaign.json` binds the
clean implementation candidate, fixture-import receipt, release runner, complete diagnostic
receipts, and reviewed configuration:

| Run | Source | Result | Elapsed | Retired instructions |
|---|---|---|---:|---:|
| `66b9e8bc-37cb-4871-bf96-ce2f218690c2` | clean `121d86faa` | seven workloads + ACPI S5 | 259.61 s | 733,197,676 |
| `ebea26bd-60d8-4a20-b6e3-c4c59c2c9fe5` | clean `121d86faa` | seven workloads + ACPI S5 | 268.34 s | 733,659,790 |

Both used runner SHA-256
`02ca94e747a5e04732f6a48e5726349307b1b0847b5aec53ca35a113c8bb7948`, protected host pages,
`compat-v1`, baseline JIT with tier one enabled, one vCPU, no raw target prediction, and the exact
content-addressed Alpine fixture. Both full receipts report a clean source tree, a matching guest
receipt, all requested workloads passed, and terminal `powered-off`; raw prediction counters and
pending work's maximum retired-instruction delay remained zero. The runner is linker-signed ad hoc,
and the diagnostic schema correctly reports `releaseQualified=false`, so this closes the clean PVH
evidence gap for the reviewed tuple without claiming product release qualification.

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

These fixes make the current single-vCPU and aligned-scalar signal substantially stronger. They do
not substitute for the missing free-running SMP, UEFI lifecycle, or supported-matrix campaigns.

## Remaining engineering work

### P0 — Extend persistent workers into free-running vCPU dispatch

- Move bounded guest dispatch into one long-running loop per existing persistent host worker. Each
  worker must own its architectural state, JIT context, native TLB, and code-cache cursor without
  returning ownership to the coordinator after every slice.
- Deliver interrupt, timer, cancellation, and tier-work requests through per-vCPU atomic pending
  work. Do not return to a central coordinator after every instruction budget.
- Keep deterministic single-thread replay as a separate explicit implementation, not as the
  production SMP scheduler.
- Define worker startup, stop, pause, reset, snapshot, and failure ownership so device/lifecycle
  operations rendezvous only when required and cannot strand a worker.
- Retire the frozen one-instruction overlap path only after persistent workers cover its tests.

### P0 — Finish the SMP memory and translation contract

The normative target is `docs/virtualization/x86-smp-memory-contract.md`. Its remaining code is not
just a larger mutex:

- Add a machine-scoped byte-range/rendezvous authority for unaligned, cache-line-split, page-split,
  and non-lock-free 16-byte operations. Ordinary interpreter, native, DMA, and shared-mapping
  accesses to an affected range must participate.
- Give interpreter CMPXCHG16B either a qualified lock-free 128-bit transaction or the same range
  authority. A helper lock that excludes only other locked helpers is insufficient.
- Publish remote TLB/address-space generations and require target acknowledgement before a vCPU can
  retire an access under an invalidated translation.
- Add epoch/hazard retirement for native code so invalidated storage cannot be recycled while
  another vCPU can still execute it.
- Audit every DMA/shared-memory writer for RAM ordering, page-table invalidation, and translated-code
  generation revocation.
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

- Replace the reviewed ad-hoc runner with the production-signed candidate and retain its identity.
- Repeat PVH correctness on every supported host class and every admitted production tier/config;
  the reviewed host's single-vCPU baseline-JIT/no-predictor tuple now has two clean passes.
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

The fixture and optimized-test foundations are now present. The next implementation slice should
establish the execution and memory foundations together:

1. Extend `DoryPCVCPURuntime` from persistent mailbox workers to long-running guest dispatch, with
   explicit deterministic mode, per-vCPU pending-work state, and fully specified
   lifecycle/failure ownership.
2. Introduce a machine-scoped memory-range rendezvous used by all ordinary and locked access paths
   for split/unaligned and non-lock-free 16-byte transactions.
3. Add remote translation-generation publication/acknowledgement and native-code epoch retirement.
4. Add two-vCPU shared-memory litmus and throughput campaigns that fail against the current
   coordinator path and pass only with genuine overlap and architectural ordering.
5. Re-run the content-addressed PVH fixture after each slice, preserve exact receipts, and execute
   the clean production-signed PVH/UEFI matrix once the production tuple is frozen.

Until those gates pass, x86_64 Linux should remain visible only to internal qualification tooling.
