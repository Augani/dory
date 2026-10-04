# Dory development checkpoint and delivery plan

Updated **4 October 2026**. Reviewed baseline: `b3ba69695` plus the cleanup and fixes recorded below.

This is Dory's only development plan. It records the current implementation, the gaps preventing complete GPU accelerated Linux ARM64, Linux x86_64 and macOS ARM64 guests, and the order in which to close them. Dory has substantial machine, renderer and product infrastructure. **None of the three accelerated desktop paths is currently established as release qualified.** The next work is to stabilize and prove complete guest journeys through that infrastructure.

Update this file when behavior or evidence changes. Keep raw receipts, logs, fixture recipes and operational instructions in their existing source directories; they support this plan. Git history preserves superseded plans and reports. Do not create another roadmap, readiness report or parallel task ledger.

## Scope and current status

The target host is Apple Silicon. Linux ARM64 uses DoryHV and Hypervisor.framework; Linux x86_64 runs an actual x86 kernel through DoryDBTX86 and DoryPC; macOS ARM64 uses Apple's Virtualization.framework Mac platform. FEX serves x86 container/userspace compatibility and remains a separate obligation. Intel hosts, x86 macOS, Windows guests, nested virtualization and physical GPU passthrough are outside this delivery scope.

| Guest path | Implemented now | What the evidence establishes | Main remaining gate |
|---|---|---|---|
| Linux ARM64 | Native vCPU owners, ARMVirt/GIC/PSCI, direct and UEFI boot, virtio devices, renderer workers, stock GPU admission and app display relay | Earlier managed-kernel agent boots at 2/4 vCPUs; stock GPU capabilities survive reset. These have narrow source/workload limits. | Stock desktop installation, detached-media boot, guest hardware rendering and independently verified pixels in Dory, then lifecycle/device campaigns |
| Linux x86_64 | Interpreter/JIT, paging/atomics/invalidation, persistent workers, PC firmware/devices, VirGL and PC host-visible Venus plumbing | Earlier pinned PVH userspace/S5 passes. Latest normal boot slice fails its instruction budget; IO fails its wall budget and a longer diagnostic crashes with SIGBUS. | Resolve native control-flow failure, complete current IO/boot gates, then ordinary distro performance, production SMP and accelerated desktop qualification |
| macOS ARM64 | IPSW install/bundle/identity, lifecycle/save/restore, one-display admission, shares/network/tools, guest Metal probe and VM-local collection | Product and verification code exist; older observations and host shader controls do not qualify the current installed guest. | Production install/cold reopen/update, challenged in-guest Metal with product-window pixels, lifecycle/device evidence |

The executable [release support policy](dory-core-swift/Sources/DoryOperations/DoryVirtualizationPlatform.swift) remains narrower: pinned Ubuntu Server 24.04.4 ARM64 is the public Linux installer identity; x86 Linux and Mac are excluded from normal release admission. Explicit candidate authority permits constrained qualification work. Keep that distinction until the relevant cells pass.

[The proposed matrix](Config/DoryWave0QualificationMatrix.json) contains six guest cells and five graphics profiles: Ubuntu server ARM64, Ubuntu/Fedora desktops on both Linux ISAs, and macOS ARM64. Review is pending and `releaseQualified` is false. Linux kernel/Mesa graphics inputs remain unpinned in the matrix validator. Frozen host classes are macOS 26.6.2 and 27.0; the current development host is **macOS 27.2, Xcode 27.0 (27A266a)** and cannot substitute for either release host.

### Evidence that determines the next work

| Retained source | Result and limit |
|---|---|
| [Current x86 cost and receive-worker record](X86-MEMORY-COST-REPORT-2026-10-03.json) | At `97279c8fa`, the unchanged 120M-instruction/120s check stops at 120M instructions in 79.432s before userspace. The 1.5B/900s IO run delivers 960 replies/eight block flushes but fails the wall budget without complete guest result, host reopen or S5. The separate 1800s diagnostic exits SIGBUS after 1504.261s without a final receipt. PC/LR point into non-executable allocation memory; the cause is unproved. The earlier seven-workload/S5 pass predates the receive change. Not all named local raw attachments in this summary are tracked. |
| [ARM 4-vCPU boot](docs/virtualization/evidence/wave0-2026-09-08/wave1-arm-smp.json), [ARM 2-vCPU boot](docs/virtualization/evidence/wave0-2026-09-08/wave1-arm-agent-ping.json) | Ad-hoc entitled managed-kernel/vsock observations; they do not prove a stock installed desktop, current signed daemon, UEFI parity or repeated lifecycle recovery. |
| [ARM stock capability reset](docs/virtualization/evidence/a4-2026-09-22/arm64-stock-capability-reset.json) | GPU feature/capset discovery after reset. Mesa context creation, submissions, blob mapping and displayed pixels are explicitly outside its proof. |
| [Clean baseline build](docs/virtualization/evidence/review-2026-09-12/part1-clean-build.json), [candidate launch](docs/virtualization/evidence/review-2026-09-12/candidate-campaign-launch.json) | Earlier source-bound artifact reproduction and constrained physical launch. New runtime bytes need new applicable results. |

A boot marker, renderer name, capset, host Metal completion, screenshot hash or passing unit suite cannot alone establish guest GPU acceleration. Evidence must connect the selected guest's compute/render result to independently checked product-window pixels and the exact runtime candidate.

## Architecture and ownership

| Layer | Source owner | Responsibility |
|---|---|---|
| App | `Dory/Features/Machines`, `Dory/Runtime/Machines` | User intent, display/input and daemon-derived operation/readiness state |
| Control plane | `dory-core-swift/Sources/DorydKit`, `DoryOperations` | Admission, immutable plans, authenticated handoff, durable operations and resources |
| Contracts | `DoryExecutionContracts`, `DoryVMContracts`, display/renderer wire contracts | Versioned ISA, CPU, board, device, generation and transport identities |
| ARM Linux | `Packages/ContainerizationEngine/Sources/DoryHV`, `dory-hv`, `DoryMachineARMVirt` | Native execution, ARM board, guest memory and MMIO adapters |
| x86 Linux | `DoryDBTX86`, `DoryJITRuntimeC`, `DoryMachinePC` | x86 semantics/translation/ordering, PC platform and PCI adapters |
| Linux devices and GPU | `DoryVirtio`, DoryHV/PC adapters, isolated renderer service/backend/Metal transport | Shared device semantics; VirGL/ANGLE/Metal and Venus/MoltenVK/Metal, backing/fences/scanout |
| Mac | `DoryVZMacCore`, `DoryVZMacCompatibility`, `DoryVMMKit`, `dory-vmm` | Apple Mac configuration, installation, identity, lifecycle and virtual graphics |
| Guest and delivery | `GuestTools`, `guest-probes`, `dory-core`, `Firmware`, `Config`, `scripts`, workflows | Agent/tools, probes, pinned artifacts, signing, packaging and qualification |

Extend these owners. The standalone `DoryNativeHVArm64` probe and older Linux VZ fallback do not replace the target production machines. Keep QEMU out of the shipping runtime. Do not silently change ISA, backend, graphics profile or vCPU count to make a campaign pass.

### Runtime invariants

Rules 1–7 govern translated x86 execution. ARM's equivalent lifecycle boundary uses native HV owners and execution-region retirement; it does not acquire translator backing leases per instruction. Rules 8–10 apply across the relevant GPU and product paths.

1. One worker owns each active vCPU's architectural/paging/TLB/JIT state and executable cursor. Pause, stop, reset, snapshot and failure return only after all workers acknowledge the same quiescence generation and release execution authority.
2. Pending work and invalidation are generation based. Clearing a poll byte cannot erase concurrent work. Invalidation acknowledgement follows exit from old generated code, translation invalidation and the required acquire boundary. Instruction reservations cannot wrap/overshoot; return unretired reservations.
3. Product SMP uses host-monotonic time and an explicitly admitted tier/count/device tuple. Deterministic replay is an explicit serial configuration. Internal two-interpreter overlap is not production native/mixed SMP admission.
4. x86 ordering and atomicity apply across interpreter/native/callback/device/shared-memory paths. Preserve aligned scalar atomicity, LOCK/XCHG ordering and fence semantics. Preflight operations requiring atomic side effects while preserving fault priority and architecturally permitted partial progress. Legacy SSE and VEX upper-lane effects differ. Advertise only qualified features.
5. CPU/DMA/shared writers use machine-scoped backing-address leases. Publish data and code/TLB revocation before completion/interrupt. A 16-KiB host protection granule covers all overlapping 4-KiB guest pages. Executable storage stays private per executor; shared caches require proved retirement before reuse.
6. Session metadata locks do not nest into devices, RAM, generated code or interrupt callbacks. Guest MMIO/PIO enters the machine device domain before local locks. Snapshot callbacks and release local locks before cross-device calls, backend waits, RAM acquisition or interrupt publication. Ordinary RAM/DMA synchronization stays outside that domain; asynchronous callbacks need independent lock-order review.
7. Unknown MMIO/PCI/shared adapters are denied until DMA, invalidation, completion, reset and teardown authority is proved. Do not enable memory/JIT shortcuts or raw host-target predictors to hide a failed gate.
8. GPU resource/mapping/fence/scanout/presentation leases are generation bound. Reset retires stale completions without releasing backing still in use. Cover 4-KiB guest/16-KiB host offsets and reuse. Measure CPU copies, shared mappings and valid GPU blits separately.
9. The daemon binds operation/generation, resources, signatures and immutable plan to the selected runner/workers. Candidate authority permits bounded campaigns, not public support. Another VM's output or a stale result cannot promote readiness.
10. Disk/snapshot/clone/backup/upgrade work preserves data through interruption and independent reopen. Unsupported saved-state/device combinations fail before mutation. Cleanup removes only campaign-owned resources.

## Remaining work in execution order

B and E can proceed while A is resolved. GPU conformance and common recovery can proceed in parallel using owned fixtures. Keep changes bounded enough to review and compare.

### A Stabilize current x86 execution

**Immediate priority. Owners: DoryDBTX86, DoryJITRuntimeC, DoryMachinePC and the Linux boot runner.**

- [ ] Reproduce and reduce SIGBUS using the retained profile/tier/guest inputs and disabled predictors. Retain generated instructions, register/stack state and executable-region lifetime; compare interpreter/baseline. Inspect callback calling convention, saved registers, return address, alignment, retirement and asynchronous entry. The current evidence does not identify the cause.
- [ ] Repair the demonstrated cause and retain its smallest behavioral regression. Repeat the extended diagnosis without changing payload, counts, DMA guards, signal handling or success criteria.
- [ ] Pass the original complete IO gate: exact UUID/sequence/payload echoes and existing guest timing/count bounds, eight block rounds/flushes, independent host reopen/byte verification, no pending/drop/backend failure and actual ACPI S5 within 900s.
- [ ] Re-run pinned userspace and normal boot budget on the repaired source. Record the normal budget failure until it passes; a longer correctness run cannot close it.

**Exit:** reproduced cause and regression; current exact binaries complete unchanged userspace/IO/S5 gates without crash/corruption. Normal boot/performance remains open until its frozen budgets pass.

### B Finish a stock ARM Linux desktop

**Owners: DoryHV/ARMVirt, daemon planning, app display and qualification producers.**

- [ ] Verify exact catalog media and graphics inputs. Install stock Ubuntu desktop through product UEFI/installer into an owned disk, detach media and cold boot. Repeat Fedora after the first complete slice.
- [ ] Prove native 2/4-vCPU execution and GIC/PSCI through cancellation, CPU_OFF/restart, timer/IPI stress, pause/stop/reset and host sleep/wake. Record direct boot and UEFI scope separately.
- [ ] Run real guest GL/Vulkan workloads for advertised profiles; independently verify their results and challenged pixels in Dory. Exercise login, terminal, browser/editor, package install and compositor.
- [ ] Complete input, resize/Retina/fullscreen/cursor, audio, clipboard, tools, network and sharing journeys, including permissions, revocation and reconnect.
- [ ] Replay renderer replacement, full-flush and mapped-page faults with stale-generation rejection and recovered output. Accelerated Linux saved-state suspend remains rejected until GPU state restoration is implemented and proved.

Use existing ARM installer-navigation, desktop-lifecycle, renderer-recovery and fault campaign scripts. Their fixtures prove tooling behavior; installed-guest receipts are still required.

**Exit:** a current signed candidate installs, cold boots and runs a useful stock ARM desktop with proved guest GPU work, visible output and recoverable devices on selected host/cells.

### C Make ordinary x86 Linux usable and admit production SMP

**Owners: DoryDBTX86, DoryMachinePC, firmware and PC product integration. Prerequisite: A.**

- [ ] Profile the corrected enabled path. Existing samples identify checked-write/lease work, short blocks with repeated generation checks and owner/worker cutovers. Measure allocations and guest throughput before changing each; preserve faults, invalidation and pending-work deadlines.
- [ ] Reduce those costs one change at a time. Keep raw predictors disabled until their own control-flow/lifetime/invalidation proof passes. Qualify/promote the existing optimizing executor only when proved semantics and measured benefit justify it.
- [ ] Complete independent x86 decode/semantic/fault reference coverage for advertised scalar/privileged/paging/x87/SSE behavior. Preserve immutable `compat-v1` and `intel-compatible-v1` identities. Qualify a separate versioned x86-64-v2 profile, including SSE3/SSSE3/SSE4.1/SSE4.2/POPCNT and stable CPUID/MSR persistence, through independent execution/parity. XSAVE/AVX remain separately gated. Static decodes do not prove execution; keep unqualified features/profiles unavailable.
- [ ] Finish sustained vCPU owner loops and all-worker lifecycle quiescence. The current internal two-interpreter configuration does not establish native/mixed/four-vCPU production operation.
- [ ] Prove ordering/atomics, remote TLB invalidation, CPU/DMA code/page-table mutation, cache retirement and device completion/reset races for each admitted tier combination at 1/2/4 vCPUs. Include permitted Store Buffering relaxation, forbidden Load Buffering/IRIW, message publication, mixed ordinary/locked access, split/faulting operands and targeted sanitizer runs.
- [ ] Install stock Ubuntu desktop through DoryPC UEFI, detach media, cold boot, update and run ARM-equivalent desktop/device workloads. Repeat Fedora and qualify exact profile/vCPU/clock. Do not downgrade advertised four-vCPU requests to serial execution.

**Exit:** current x86 guests pass CPU/data/lifecycle gates and installed desktops meet frozen usability budgets with the advertised parallel configuration actually running.

### D Qualify Linux GPU acceleration on both ISAs

**Owners: shared GPU semantics, ARM MMIO/PC PCI adapters, renderer workers and app display.**

PC host-visible aperture/Venus commands, stock Linux fence admission, capability reset handling and display relays now exist. PC production launch still requires signed boot-kernel/Mesa/profile evidence; ARM's stock provisional path has a different admission contract. These are integration and qualification tasks, not missing-device rewrites.

- [ ] Pin stock kernel/Mesa/driver, firmware, virglrenderer, ANGLE and MoltenVK per profile. Distinguish VirGL2/OpenGL and Venus/Vulkan; qualify any selected OpenGL-over-Vulkan strategy separately. Reject software rendering/fallback for acceleration claims.
- [ ] Exercise context/resource/blob creation, host-visible PCI aperture, mapping/fences/retirement through actual guest submissions. Cover offsets, aliases, remapping, pressure and renderer loss. Prove each ISA's transport.
- [ ] Independently verify guest compute/render, then nonce-derived pixels and orientation from the selected product window. Correlate producer completion, scanout and presentation with VM operation/generation.
- [ ] Prove completed stock producer fences before promoting readiness. Capsets/provisional admission do not suffice; managed and stock profiles cannot share unsupported synchronization assumptions.
- [ ] Complete compositor/apps, display topology/resize, minimize/restore, host sleep/wake, worker crash/restart, GPU timeout and mapping faults. Recovery cannot publish stale readiness.
- [ ] Measure frame latency/pacing, CPU copies/shared texture/GPU blits and memory/FD/thread/resource growth against budgets frozen before campaigns. Retain failures/fallbacks and independent rounds required by verifiers.

Reuse `guest-probes`, pixel/OpenGL verifiers, PC GPU daemon campaigns and Linux performance-bundle validators. The older managed-rootfs smoke does not qualify a stock ISO installation.

**Exit:** every advertised Linux graphics profile has exact-candidate guest execution, correct visible pixels, sustained performance and recovery evidence. Unsupported APIs remain unavailable.

### E Complete macOS ARM64 and guest Metal

**Owners: VZMac, daemon Mac operations, dory-vmm and GuestTools.**

- [ ] Run production IPSW install/Setup Assistant into a durable bundle. Preserve hardware model, machine identifier and auxiliary storage across restart, cold reopen and update. Exercise cancelled/interrupted install without identity loss.
- [ ] Keep one-display validation aligned across app/admission/helper. Prove resources, stop/restart/pause, host sleep/wake, save/restore, incompatible/corrupt saved state and recovery on selected tuples. After restore verify guest data/workloads, not just resumed host state.
- [ ] Install exact signed tools. Issue fresh machine/operation-bound nonces; collect compute/render over that VM's socket and independently verify product-window pixels. Repeat after resize, minimize/restore, sleep/wake and save/restore with fresh challenges and actual lifecycle traces.
- [ ] Produce signed two-campaign Metal proofs and sustained performance. Existing probe/sub-gates deliberately leave release eligibility false; install, devices, lifecycle, performance and publication remain outer gates.
- [ ] Qualify user shares, NAT/disconnected/host-only networking and permitted forwards, audio input/output, clipboard and tools updates. Include read-only grants, revocation, malformed/disconnected transport and permissions. Add camera/USB claims only after their separate gates pass.

Reuse Apple's Mac virtual graphics. Remaining work is product integration and guest qualification; there is no new Mac GPU driver workstream.

**Exit:** a product-installed Mac guest survives required lifecycle operations and demonstrates current in-guest Metal compute/render, visible output and advertised devices.

### F Finish common operations and preserve user data

**Owners: daemon, app/CLI/API, storage/network/filesystem workers and tools.**

- [ ] Keep one definition/operation/resolved-plan model. Verify cancellation/retry, daemon restart, stale handoff/results and helper loss. Report firmware/kernel/session/agent/GPU/presentation readiness separately with actionable errors.
- [ ] Pass flush/reopen, sparse growth/ENOSPC, snapshot rollback, clone identity, export/import and backup restore drills. Inject interruption at journal/publication boundaries; independently reopen data and preserve manual snapshots/unrelated archives during retention.
- [ ] Qualify network isolation, IPv4/IPv6/DNS, port ownership/reconciliation, reconnect and sleep/VPN transitions. Keep unsupported Mac bridging/LAN-forward policy visibly rejected.
- [ ] Qualify sharing through guest writes, host edits/watchers, concurrent access, permission/revocation, worker crash and consistency recovery. Keep unproved DAX shortcuts unavailable.
- [ ] Complete offline/versioned tools install/update on both Linux families and Mac, with stale/unsigned/wrong-guest rejection and rollback.
- [ ] Rehearse upgrades of definitions/disks/tools/components/credentials/snapshots from existing installations, with atomic migration and recovery. Retire obsolete paths only after their obligations have a proved successor.
- [ ] Preserve Docker/Compose, networking, bind/volume data, BuildKit/devcontainers, idle/wake and default-mode FEX behavior. Keep the unpromoted signal-context candidate out of production until asynchronous/default-preemption regressions, reproducible build and rollback pass.

**Exit:** production operations preserve data/ownership through interruption for all admitted cells and the existing container product remains functional.

### G Freeze the matrix and ship the proved candidate

**Owners: release/runtime/security reviewers, artifact producers and qualification pipeline.**

- [ ] Finish guest artifact producer migration. The earlier guest workspace deletion removed kernel/initfs/Mesa/desktop build and verification scripts, but `scripts/build-components.py`, bundling and the release workflow still invoke them. Replace those stale consumers with owned reproducible producers and digest/provenance verification. Do not restore the removed workspace wholesale or bypass verification with old local outputs. This blocks a clean release build independently of runtime readiness.
- [ ] Freeze host/SoC/OS, guest media/kernel/page size, CPU/vCPU/resources, tools and graphics tuples. Pin matrix graphics inputs, collect required reviews and reconfirm upstream media/support at selection time.
- [ ] Freeze numeric install/boot/command, frame/pacing, throughput, idle/resource and recovery budgets before measuring. Use independent rounds and distributions; retain failed/fallback/unavailable samples. Microbenchmarks do not establish desktop usability.
- [ ] Assemble/sign exact app/daemon/runner/worker/firmware/tools/graphics bytes. Run owned physical campaigns through constrained candidate authority on frozen hosts; retain source/artifact/signature/plan/operation identities and raw output.
- [ ] Pass authentication/grant/replay/revocation, hostile protocols/ranges, JIT code protection, quotas and cleanup. Run final-candidate reliability/resource-growth soaks and recovery.
- [ ] Replay Linux/Mac evidence verifiers; combine them with install/lifecycle/data/device/performance/container gates in the final producer. Partial sub-gates cannot issue public qualification.
- [ ] Promote policy/catalog/app/website claims only for passing cells. Publish through the existing release entrypoint; verify notarized downloads, component metadata, Sparkle and Homebrew identify the same candidate. Changed/re-signed executable payloads require affected campaigns again.

**Exit:** released bytes and public claims have complete reproducible evidence for advertised tuples.

## Essential verification and test policy

Keep tests that protect a concrete failure boundary. Avoid source-text searches, implementation mirrors, label/default-literal checks and historical test-count ledgers. Prefer parameterized coverage for repeated safety contracts. Real guests and visible-output campaigns remain necessary even when unit tests pass.

| Retain | Purpose |
|---|---|
| Independent CPU semantics/fault/profile and ordering regressions | Prevent silent translation corruption |
| Ranges/leases/atomics/DMA/SMC/TLB/worker lifecycle | Prevent stale code, corruption, lost wakes and deadlocks |
| GPU fence/mapping/resource/scanout/reset | Prevent premature reuse and false readiness |
| Auth/plans/grants/signatures/hostile parsers | Bind authority to intended resources |
| Journal/snapshot/clone/backup/import/upgrade/reopen | Preserve user data through failure |
| Network/share protocols and real operation boundaries | Preserve isolation, connectivity and consistent state |
| Tamper/fallback/pixel verification and campaign ownership guards | Prevent false qualification and unsafe cleanup |
| Focused product journeys and signed guest campaigns | Prove the integrated product works |

Run affected essential suites during implementation; run the retained full suite and required physical campaigns for release. Use targeted sanitizers for concurrency/ownership changes and explicitly report skips/missing prerequisites.

```sh
scripts/test.sh swift
scripts/test.sh rust
scripts/test.sh app
scripts/test.sh ui
scripts/test.sh build
python3 -B scripts/validate-wave0-qualification-matrix.py \
  --matrix Config/DoryWave0QualificationMatrix.json --source-root .
```

App/UI schemes require Dory to quit under the runner guard. Package tests can run while the installed app remains active. Use an owned build directory if another process owns SwiftPM's normal directory. Live guests require signed/entitled binaries, owned prepared disks/media and explicit campaign input/ownership checks; read arguments before launch.

## Definition of complete

All must pass on the final signed candidate:

- [ ] Fresh ARM/x86 stock Linux installs, detached-media cold boot, updates and useful desktops at advertised resources.
- [ ] Correct x86 CPU/memory/SMP and frozen normal boot/performance budgets, with no unresolved native crash.
- [ ] Guest GL/Vulkan results and independently captured pixels for every advertised Linux profile, with sustained pacing/recovery.
- [ ] Mac install/stable identity/update/lifecycle/save/restore, challenged guest Metal and visible pixels.
- [ ] Advertised network/shares/input/audio/clipboard/tools/optional devices work and recover on exact cells.
- [ ] Data-preserving snapshot/clone/backup/import/upgrade/failure drills and coherent app/CLI/API operations.
- [ ] Security/isolation/quotas/reliability/resource-growth and existing container obligations pass.
- [ ] Reviewed matrix/final evidence/catalog, signed downloads and all distribution surfaces agree.

## This checkpoint

Superseded root readiness/GPU/x86 reports and six virtualization planning/audit documents were removed. Their relevant invariants and open gates are incorporated here. Raw evidence, recipes, ABI/build/tool instructions and release history remain.

The cleanup removes 41 old test files and adds one consolidated suite, leaving 40 fewer files. It removes 127 redundant/cosmetic/source-structure/obsolete cases and preserves 26 campaign arming cases in the consolidated suite. CPU/GPU/memory/authentication/persistence coverage remains. Two focused regressions cover the Mac fixes.

The package runner uses a portable bounded watchdog. Mac Metal transport accepts the issuer's fractional-second timestamps; the host collector suppresses SIGPIPE on a disconnected guest socket. The FEX kind gate reads the retained kernel tuple instead of deleted pins and checks missing provenance producers before creating resources; live qualification remains blocked until producer migration is complete. The duplicated security wrapper now invokes the current canonical checks.

| Checkpoint validation | Result and scope |
|---|---|
| App and retained app-test compile | Debug ARM64 `build-for-testing` passed. Signing, firmware bootstrap and release renderer packaging disabled; no app/tests launched. |
| ARM owner/PSCI/pause/mapped-fault mechanisms | 39 tests passed across six suites; one prepared-guest PSCI registration skipped. Actual CPU_OFF guest campaign remains open. |
| PC receive/worker/concurrent gate/invalidation | 22 tests passed across four suites, no skips. This does not resolve the long-run native crash. |
| Mac collector and timestamp/pixel verifier | Seven collector tests and 29 verifier tests passed. Compiled actual guest transport accepts issuer timestamps. Removing only SIGPIPE suppression from a temporary collector mutant causes signal termination; fixed code returns EPIPE. Host controls do not qualify a Mac guest. |
| Retained GitHub Python harness suites | All 32 passed after fixing stale signed-desktop/JIT fixtures and the FEX pins consumer; two suites for removed guest implementations were retired. The 26 arming scenarios pass in the consolidated guard. |
| Additional retained checks | Portable watchdog, security/destructive guards, backup/restore/capacity, 12 dory-open cases, workflow contract/references, source no-QEMU audit, document links and diff checks passed. |
| Matrix structural validation | Passed with review pending and eight unpinned Linux graphics kernel/Mesa inputs; no release approval. |

Local check logs are under `.dory-build/checkpoint-*`. Full Rust/Swift suite execution, app/UI test execution, hosted CI, signed release assembly and physical guest campaigns were not run in this checkpoint. The installed app/daemon were left running. No release cell is promoted.

For subsequent work, choose an open item, implement it through the existing owner, verify behavior/integration, retain a compact raw receipt and update the relevant status here. Close an item only when its exit evidence exists.
