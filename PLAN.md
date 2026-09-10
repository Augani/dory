# Dory: implementation plan for owned, GPU-accelerated VMs on Apple Silicon

Rewritten 2026-09-08 against `13228e14a` (1,954 commits, 2026-07-13 → 2026-09-08; ~314k lines Swift, ~18.5k Rust, ~7.5k C). This replaces the previous A00–A30 ledger. It keeps card IDs where the work is unchanged, but it **reorders the programme around the actual critical path found in the source and evidence audit** and corrects several claims the previous plan carried forward.

**Required outcome:** Linux ARM64, Linux x86_64 and macOS ARM64 virtual machines on Apple Silicon Macs, created and run through the shipped Dory app and CLI, with real hardware GPU acceleration in every cell, recoverable data, and performance that is genuinely good to use. Every execution engine, device model, firmware, renderer and translator is owned by Dory. No QEMU runtime, no third-party hypervisor, no time pressure that trades away architecture.

**Non-negotiables carried over:** Apple Silicon is the only host; macOS x86_64 and Intel hosts are out of scope; existing container product gates stay in force; qualification is candidate-bound and evidence-driven; llvmpipe/lavapipe/software output never closes a hardware gate.

## Start here

1. Read **Where we actually are** and **Corrections to the previous plan**. They change what "on track" means.
2. Read **Target architecture** and the numbered **Architecture decisions D01–D16**. A step that contradicts a decision is wrong, not clever.
3. Pick one card from the **Delivery order**. Cards are `Axx`; steps are `Axx.n`. A step is the assignable unit.
4. Do the step's **Action**, understand its **Why**, satisfy its **Check**. Attach the standard receipt under `docs/virtualization/evidence/`.
5. Update the step in place. Do not start a new roadmap, journal or ledger.

Navigation: [Where we are](#where-we-actually-are) · [Corrections](#corrections-to-the-previous-plan) · [Architecture](#target-architecture) · [Decisions](#architecture-decisions) · [Working rules](#working-rules-and-evidence) · [Delivery order](#delivery-order) · [Cards](#implementation-cards) · [Budgets](#performance-and-reliability-contract) · [Retirement](#retirement-inventory) · [Finish gates](#final-completion-gates).

---

## Where we actually are

"Implemented" means source and bounded development evidence exist. It does not mean release-qualified. `releaseQualifiedCells` in every current receipt is `0`.

### Linux ARM64 — native Hypervisor.framework runtime: **strong foundation, needs presentation, stock-guest and lifecycle work**

| Fact | Evidence |
|---|---|
| Production runtime is `Packages/ContainerizationEngine/Sources/DoryHV` (46,573 lines) executed as `DoryHVRunner.app/Contents/MacOS/dory-hv` (17,247 lines). It has per-vCPU threads, in-kernel GICv3 (`hv_gic_*`), PSCI CPU_ON/OFF/AFFINITY, generic timer PPIs, 32-slot virtio-mmio, FDT generation for `dory.armvirt@1`, direct-kernel and EDK2 UEFI boot. | `DoryHV/Machine.swift` (1,455), `VCPU.swift`, `GICv3MMIO.swift`, `ARMSystemRegisterTrap.swift`, `ARMPSCICPUState.swift`, `VirtioMMIO.swift`; `Firmware/DoryARMVirt/DoryARMVirtPkg` |
| Boots Linux 6.12.106-dory with 4 vCPU / 1 GiB, answers guest-agent RPC over vsock, exits cleanly in 2.9 s. | [`wave0-2026-09-08/wave1-arm-smp.json`](docs/virtualization/evidence/wave0-2026-09-08/wave1-arm-smp.json), [`wave1-arm-agent-ping.json`](docs/virtualization/evidence/wave0-2026-09-08/wave1-arm-agent-ping.json) |
| Alpine and Debian installer → detach → cold reopen → update → snapshot → recovery campaigns ran through the manager. | [`p05-arm-2026-09-05/`](docs/virtualization/evidence/p05-arm-2026-09-05/) |
| **Venus → virglrenderer → MoltenVK → Metal is proven end to end in the container VM**: `docker create --gpus all` → `/dev/dri/renderD128` → `driver=venus device=Virtio-GPU Venus (Apple M2 Pro)` → `vkCmdDispatch`, 65,536 outputs, 0 mismatches, repeated concurrently. | [`p06-container-2026-09-05/container-standard-gpu-shader.json`](docs/virtualization/evidence/p06-container-2026-09-05/container-standard-gpu-shader.json), `container-concurrent-shader-compute.json` |
| `VirtioGPU.swift` (9,348 lines) implements virtio-gpu with VirGL and Venus capsets, blob resources, host-visible DAX window, an out-of-process XPC renderer worker (`DoryRendererWorker.xpc`) statically linking `libvirglrenderer.a`, `libepoxy.a`, `libMoltenVK.a`, with ANGLE `libEGL/libGLESv2` for the GL path. Six owned virglrenderer patches. ARM64 and x86_64 guest Mesa producers build and verify. | `Packages/ContainerizationEngine/Sources/DoryRendererWorker*`, `patches/virglrenderer-*.patch`, `scripts/assemble-renderer-production-worker.sh`, [`arm64-virgl2-producer/receipt.json`](docs/virtualization/evidence/wave0-2026-09-08/arm64-virgl2-producer/receipt.json) |
| **Not done:** no on-screen hardware-rendered desktop frame has been recorded for any Linux VM (0 matches for `glmark`/`vkcube`/`GL_RENDERER` in VM evidence). `DesktopMode.swift:3105` still reports "host-accelerated display is not implemented by the RawHV Metal display contract". Only `off`/`venus` GPU modes exist for ARM (`EngineMode.swift:349`). PCIe ECAM, USB and DAX slots are reserved in the ABI but have no bus backend. Stock-distro kernel/Mesa profiles are not pinned. IRQ/cancel/suspend stress and UEFI parity under the signed daemon are open. | audit of `dory-hv/DesktopMode.swift`, `EngineMode.swift`, `DoryARMVirtV1ABI.swift` |

### Linux x86_64 — in-house DBT: **correct-first prototype, roughly two orders of magnitude too slow, and currently regressed**

| Fact | Evidence |
|---|---|
| Three tiers share one decoder/paging/IR: interpreter (`DoryX86Interpreter.swift`, 8,997 lines), baseline ARM64 JIT and an "optimizing" JIT that only adds a local constant-prop/dead-code pass (`DoryARM64BaselineJIT.swift`, 4,829 lines). Real/protected/long/compat modes, PAE/4-level paging with 4K/2M/1G pages, APIC/IOAPIC/PIC/PIT/HPET, precise exception delivery, PVH loader, EDK2 `dory.edk2.pc@1` firmware. 1,042 `@Test` cases in `DoryDBTX86Tests`, 262 in `DoryMachinePCTests`. | `dory-core-swift/Sources/DoryDBTX86`, `DoryMachinePC`, `Firmware/DoryPC` |
| Best ever end-to-end: optimizing JIT boot to agent bind-ready **3,901 s** (baseline 3,361 s); agent handshake 16.5 s; `/bin/true` RPC **218.7 s**. Interpreter did not reach GRUB in 7,200 s. | [`p06-pc-2026-09-06/tier-comparison-rpcdiag.json`](docs/virtualization/evidence/p06-pc-2026-09-06/tier-comparison-rpcdiag.json) |
| The apparent HEAD EFI fault was a stale produced-firmware mismatch, not an x86 semantic regression. A clean source-derived firmware build puts variable services in `RuntimeServicesCode`; the unchanged KASLR fixture reaches root mount at 523.6 s and `/sbin/init` at 606.7 s without `efi=debug`. | [`wave0-2026-09-08/pc-efi-runtime-current-firmware.json`](docs/virtualization/evidence/wave0-2026-09-08/pc-efi-runtime-current-firmware.json), [`unmodified-strict-control/receipt.json`](docs/virtualization/evidence/wave0-2026-09-08/pc-boot-timeline/unmodified-strict-control/receipt.json) |
| **Why it is slow (confirmed in source, not speculation):** every translated block ends with `exit = .dispatch` and returns to a Swift loop; the next block is found through a Swift `Dictionary<LookupKey, …>` keyed by a five-field Hashable struct; blocks are capped at `maximumResidentInstructionBudget = 64`; guest memory accesses call `throws` Swift methods on `DoryX86MmapMemory` that return `[UInt8]` arrays; the TLB is a Swift `Dictionary<TLBKey, TLBEntry>` consulted from Swift on every access; self-modifying code is detected by per-write generation counters. No block chaining, no indirect-branch cache, no inline TLB, no pinned guest registers. | `DoryARM64BaselineJIT.swift:2437-2484, 3416-3470`; `DoryX86MmapMemory.swift:85-140`; `DoryX86Paging.swift:70-144` |
| SMP is one host thread round-robining vCPUs in 64-instruction quanta (`DoryPCDirectKernelMachine.swift:1386`). Most VEX/AVX forms are rejected; XSAVE unqualified. | audit |
| PC virtio-gpu PCI device exists (`DoryPCVirtioGPUPCIDevice`, class 0x038000) and shares the renderer command lane; `DoryPCVirGLRendererAuthority` (~1,063 lines) is wired; Venus is intentionally hidden until a host-visible BAR exists. No PC frame has been rendered. | `DoryPCVirtioPCI.swift:948`, `DoryHV/DoryPCVirGLRendererAuthority.swift` |

### macOS ARM64 — Virtualization.framework adapter: **works, but under-featured and under-qualified**

| Fact | Evidence |
|---|---|
| IPSW discovery/validation, install, boot, display, keyboard/pointer, audio, SPICE clipboard, NAT network, suspend/restore saved state, snapshots, camera bridge and a signed `dory-vmm` helper exist. `NewMachineSheet` exposes `.macOSARM64`; `dorydctl machine create --ipsw` exists. | `DoryVZMacCore/DoryVZMacConfigurationBuilder.swift` (2,262), `DoryVMMKit/DoryVZMacDesktopApplication.swift` (1,024), [`p07-macos-2026-09-05/`](docs/virtualization/evidence/p07-macos-2026-09-05/) |
| **Missing:** user shared folders (`shares: absent`), guest tools (`guest-tools: absent`), guest-Metal proof, production daemon/catalog installation, interrupted save/restore drills. | [`p00-baseline-2026-09-04/capability-matrix.json`](docs/virtualization/evidence/p00-baseline-2026-09-04/capability-matrix.json) |

### Product surfaces, trust and build

`doryd` + `DorydKit` (82k lines), `dorydctl` (2,037 lines), `MachinesView`/`NewMachineSheet` in the app, XPC handoff to `dory-hv`/`dory-vmm`, signed launch handoff with authenticated peer rejection ([`wave0-2026-09-08/verification.json`](docs/virtualization/evidence/wave0-2026-09-08/verification.json): wrong-identity/unsigned rejected, absent/malformed fail closed; wrong-team unavailable on this host). Producer inventory, fixture preflight, matrix validator and evidence audit scripts exist. FFI archive rebuilt at macOS 14.0 floor. The app source binding is stale relative to HEAD; no signed release candidate exists.

---

## Corrections to the previous plan

These are places where the previous plan was wrong, misleading, or steering effort in the wrong order. Each has a card that fixes it.

1. **The previous plan treated x86_64 as a coverage problem; it is an execution-architecture problem.** A03–A10 spent eight cards on ISA completeness (v2/v3/AVX2, XSTATE, TSO SMP) before the engine could boot a kernel in under an hour. Adding instruction forms to a ~6 MIPS engine produces a complete slow engine. The x86 section is reordered: **A04–A06 redesign the execution core first** (memory model, inline TLB, chained code cache, pinned registers, lazy flags, threaded vCPUs) behind hard measured gates; ISA completeness (A07–A08) and the tier-2 optimizer (A09) follow. The interpreter stays as the semantic oracle.

2. **"Consolidate DoryHV with DoryARMVirt/DoryNativeHVArm64" pointed the wrong way.** `DoryNativeHVArm64` (2,050 lines) is a single-vCPU/single-page contract probe with no GIC, PSCI, timers, devices, DT or firmware. `DoryHV` is the production runtime. The probe is not a "competing production candidate" to converge into; it is a test harness to keep as a harness (or fold into `DoryHVTests`). R08 is rewritten accordingly. `DoryMachineARMVirt` (ABI/DT/boot-state, 732 lines) is already consumed by `DoryHV` and is the correct shared contract.

3. **"1,048,576-output guest Metal compute pass" was a host run.** `p07-macos-2026-09-05/host-metal-compute.json` records `deviceName: Apple M2 Pro`, 12 logical CPUs, 16 GiB — the host, not the guest (the probe's own header says to run it on both). There is **no guest Metal evidence**. A22.4 requires the probe to run inside the guest with guest-identifying output.

4. **The GPU stack is further along than the plan admitted, and less along than Settings implies.** Venus compute is proven in the container VM. What is not proven is *presentation*: guest scanout → zero-copy Metal texture → Dory window, with fences and retirement. The gating work is display/presentation (A11–A12), not renderer bring-up. Meanwhile `Settings.gpuVenusEnabled` and a `.linuxX86_64` platform picker are user-visible without any qualified backing; A15/A26 must project effective state truthfully.

5. **The GL strategy needs a decision, not a shrug.** The previous plan said "Zink remains optional". With Venus/MoltenVK proven, a single Vulkan transport with Zink for OpenGL avoids maintaining two renderer backends (virglrenderer-GL + ANGLE + virglrenderer-Venus + MoltenVK) with two sets of macOS patches. But MoltenVK lacks features Zink wants (geometry shaders, transform feedback, some formats). D07 makes this a measured experiment in A14.1 rather than an assumption either way.

6. **Wave 0 process work was crowding out engineering.** Signed handoff, producer inventory, matrix validator, evidence audit and receipts are valuable and are kept, but the previous "next assignments" list was five process items and one engine item. The new delivery order puts engine work in Wave 1 in parallel with the remaining trust items.

7. **PC Venus "shared memory over PCI BAR" was framed as a Vulkan blocker only.** It is also the same host-visible blob mechanism ARM already uses via the DAX window, and it interacts with the DBT's memory model (A04). Design it once in A04/A13 with the DBT owner, not as a graphics-only afterthought.

8. **The plan referenced evidence that had been renamed or misdescribed** (e.g. "p07 guest Metal", "17 executed unit tests across two runs plus a separate entitled smoke" presented as six live tests). Evidence bullets below cite only files that exist at HEAD; the historical-evidence audit (`scripts/audit-plan-evidence.py`) must be re-pointed at the new citations (A01.2).

---

## Target architecture

```text
App (SwiftUI) / dorydctl                      user intent, projection of daemon truth
  └─ doryd (DorydKit)                          definitions, policy, admission, durable ops, catalog
       └─ immutable launch plan + granted FDs/leases
            ├─ Linux ARM64  → dory-hv (DoryHV)             Hypervisor.framework, per-vCPU threads, GICv3
            ├─ Linux x86_64 → dory-hv (DoryPCMode)         DoryDBTX86 engine v2 + DoryMachinePC devices
            └─ macOS ARM64  → dory-vmm (DoryVZMacCore)     Virtualization.framework, VZMacPlatform
            
Guest devices (Linux): shared DoryVirtio cores → virtio-mmio (ARM) / virtio-pci (PC)
GPU:  guest Mesa (Venus + VirGL2/Zink) → virtio-gpu (blob, host-visible) → DoryRendererWorker.xpc
      → virglrenderer(+patches) → MoltenVK / ANGLE → Metal → IOSurface/MTLSharedTexture → Dory window
Host integrations: isolated brokers (gvproxy network, filesystem worker, audio, USB/xHCI, camera)
```

Ownership rules (unchanged): runner owns volatile machine state; daemon owns policy and durable operations; a worker owns what it isolates; a child never reinterprets an approved ISA, backend or graphics tier; one durable definition, one resolved plan, one operation record.

### Architecture decisions

These are decided. Changing one requires a written rationale in the receipt of the step that changes it.

- **D01 — Execution owners.** Linux ARM64: `DoryHV`. Linux x86_64: `DoryDBTX86` engine v2 inside `dory-hv` `DoryPCMode`. macOS: `DoryVZMacCore` in `dory-vmm`. `DoryNativeHVArm64` is test tooling.
- **D02 — x86 guest physical memory is a flat host reservation.** Reserve the whole guest-physical range once (`mmap` reserved, committed lazily) so `host = base + gpa`. Device MMIO ranges are left unmapped so accesses fault into the device path. No per-access Swift call, no `[UInt8]` round trips.
- **D03 — Inline software TLB.** Generated code performs the virtual→host translation itself: per-vCPU direct-mapped TLB (separate read/write/execute arrays keyed by VPN, tagged with ASID/CR3 generation), fast path ≈ 6 ARM64 instructions, slow path to a C helper that walks the page tables via the existing `DoryX86Paging` semantics. All architectural fault semantics remain in the walker.
- **D04 — Self-modifying code by page protection, not per-write counters.** Host pages backing guest pages that contain translated code are write-protected; the write fault handler (Mach exception / `SIGSEGV` in `DoryJITRuntimeC`) invalidates translations for that page, unprotects, and resumes. Device-DMA writes go through the same invalidation hook.
- **D05 — Direct block chaining and indirect-branch prediction.** Direct branches patch to the target's host code once translated; indirect branches consult an inline per-vCPU indirect-branch target cache; `RET` uses a shadow return-address stack. The dispatcher is generated code/C and is reached only on a cache miss. No Swift on the hot path.
- **D06 — Pinned guest registers and lazy flags.** The 16 x86 GPRs live permanently in ARM64 `x` registers across blocks; RIP, flags-result, and TLB base occupy reserved registers; the vCPU context pointer is fixed. Flags are stored as (last result, operation kind, operands) and materialized on demand; ARM NZCV is used directly for the common compare→branch pairs.
- **D07 — One Vulkan transport; GL strategy decided by measurement.** Venus over host-visible blobs is the primary transport on both ISAs. A14.1 runs an owned experiment comparing VirGL2→ANGLE against Zink→Venus→MoltenVK on the frozen desktop workload (correctness, fps, p95 frame interval). The winner becomes the OpenGL path; the loser is retained only if a required application needs it.
- **D08 — Zero-copy presentation.** Guest scanout resources are backed by `MTLSharedTexture`/IOSurface exported from the worker; the runner presents them through a `CAMetalLayer` in the app-owned display view with fence-gated retirement. Software copy paths remain for `off` graphics and recovery only.
- **D09 — Threaded vCPUs with an explicit memory-ordering mode.** One host thread per x86 vCPU. Guest loads/stores are emitted with acquire/release semantics (`LDAPR`/`STLR`) when more than one vCPU is admitted (TSO-preserving); a single-vCPU plan may use relaxed accesses. Locked RMW uses `LDAXR/STLXR` loops or LSE atomics. Hardware TSO mode is not publicly available and is not assumed.
- **D10 — Interrupts and time never stop the engine.** Pending-interrupt checks happen at block entries and backward branches via a per-vCPU flag; the guest TSC is `CNTVCT_EL0` scaled; APIC timer deadlines use host timers that set the flag. No polling of Swift objects.
- **D11 — Interpreter as oracle; JIT proves itself against it.** `DoryX86Interpreter` is retained, kept correct, and used in differential testing with the JIT and with an independent reference (A10). It is never the production tier.
- **D12 — Hot runtime in C, compilers in Swift.** The dispatcher, TLB miss/fault handlers, chaining patcher, IBTC, signal handling and atomics helpers live in `DoryJITRuntimeC`. Decoder, IR, register allocator and emitters stay in Swift. This is the measured need that justifies the language boundary.
- **D13 — ARM ABI stays `dory.armvirt@1`; PCIe is added as a bus, not a replacement.** virtio-mmio remains for existing slots; a PCIe ECAM root in the reserved range hosts xHCI and future devices. Persisted machines keep working.
- **D14 — Mac guests use only supported public Virtualization APIs.** Shared folders via `VZVirtioFileSystemDeviceConfiguration`, one display, supported saved-state APIs, Setup Assistant not automated. Capabilities the SDK cannot provide are reported, not faked.
- **D15 — Stock guests are first-class.** Any stock distro kernel with virtio-gpu blob + DRM sync support must work with Dory's guest Mesa packages; the managed kernel is an optimization, never a requirement.
- **D16 — Performance claims are measured on the frozen matrix only.** Targets in the contract section are engineering targets until A29 freezes them per host class.

---

## Working rules and evidence

### Before changing code

- Run `git status`; know the production owner and current call sites; preserve unrelated work.
- Read the manifests, test entrypoints and existing receipts. Know whether a test is pure, mocked, entitled or real-guest.
- Reserve shared files (`MachineManager.swift`, `DoryPCMode.swift`, `DesktopMode.swift`, `DoryX86Interpreter.swift`, `DoryARM64BaselineJIT.swift`, `VirtioGPU.swift`, renderer wire contracts, ABI files) before concurrent edits.
- Missing hardware or media blocks the qualification step, not the implementation step. Required CI fixtures fail closed; optional local jobs skip visibly.

### Verification ladder

1. **Focused behavioral regression** — assert values, faults, state changes, resources. No source-spelling tests.
2. **Subsystem integration** — real resolver/runner/device boundary, labeled substitutions, failure paths.
3. **Candidate-bound guest work** — rerun the affected kernel/app/lifecycle on immutable inputs with real output checks.
4. **Physical failure/recovery** — owned fixtures: worker/process loss, reset, host changes, interrupted durable commits; sanitizers/fuzzers for parsers and JIT.
5. **Release qualification** — declared matrix and budgets on exact signed/notarized bytes.

A checkbox closes only when its Check passes and the receipt is reviewed. `implementation merged; qualification open` is the normal intermediate state. Failed, timed-out, missing and skipped are four different states; retries never erase failures.

### Standard completion receipt

Use `docs/virtualization/evidence/<campaign>/`. Record: step, owner, reviewer, commit and dirty patch; exact commands, toolchain, locks and fixture digests; live runs also record signed component hashes, firmware/kernel/rootfs/Mesa/tools identities, host/guest versions and effective settings; expected vs observed, exit status, deadlines, cancellation, cleanup; test counts with skips separated; raw outputs/checksums; artifact hashes; candidate applicability; remaining gates. Never fabricate or overwrite historical evidence.

### Storage discipline

Inventory leases and free space before a campaign; use disposable clones in a campaign-owned directory with a byte budget; bound process trees, guest command durations and log sizes; confirm guests/helpers are gone before removing backing; preserve user VMs, originals, source and useful evidence; record before/after bytes. Fixture loss stays visible; never substitute a different disk.

### Verified local entrypoints

`scripts/build.sh`, `scripts/test.sh` (`rust|gvproxy|swift|app|ui|build|all`). Focused examples (toolchain currently Xcode 26.6 RC; A01 pins the supported one):

```sh
xcrun swift test --package-path dory-core-swift --jobs 4 --filter 'DoryDBTX86Tests'
xcrun swift test --package-path dory-core-swift --jobs 4 --filter 'DoryMachinePCTests|DoryMachinePCLinuxBootRunnerTests'
xcrun swift test --package-path Packages/ContainerizationEngine --jobs 4 --filter 'ARMSystemRegisterTrapTests|ARMPSCICPUStateTests|RawHVMachineRunnerTests'
xcrun swift test --package-path dory-core-swift --jobs 4 --filter 'DoryVZMacCoreTests|DoryVZMacCompatibilityTests'
DORY_RUN_NATIVE_HV_SMOKE=1 <entitled dory-native-hv-smoke>          # entitled, 30 s external deadline
scripts/pc-gpu-daemon-live-gate.sh                                  # requires production-root schema-2 catalog
scripts/desktop-linux-live-gate.sh                                  # ARM desktop live gate
```

---

## Delivery order

| Wave | Cards | Handoff |
|---|---|---|
| 0: trust and reproducibility (finish, do not expand) | A00.3–A00.5, A01 | Signed handoff on Release bytes; one coherent source-bound candidate; approved matrix; corrected evidence audit. |
| 1: unblock the engines | A02 (x86 regression + attribution), A04 (x86 memory/TLB/SMC core), A11 (ARM presentation path), A18 (ARM lifecycle), A21 (Mac production install), A16 (FEX default-mode) | x86 boots again with a measured profile; ARM shows its first zero-copy hardware frame in the real window; Mac installs through the daemon. |
| 2: make x86 fast, make GPU real | A05 (tier-1 JIT redesign), A06 (threaded vCPUs/TSO/interrupts), A12 (shared GPU semantics), A13 (PC host-visible BAR + Venus), A14.1 (GL strategy experiment), A19 (installers), A20 (devices) | x86 meets G1–G3 gates; Venus + chosen GL path present real desktops on ARM; PC renders its first frame. |
| 3: completeness | A07 (scalar/system semantics), A08 (FP/SIMD/XSTATE), A09 (tier-2 optimizer), A10 (independent oracle), A14 (desktop matrix both ISAs), A22 (Mac policy/tools/Metal), A17 (container GPU) | Declared CPU profiles complete and proven; desktop matrix passes on both ISAs; Mac guest Metal proven. |
| 4: product and data | A15 (GPU product behavior/recovery), A23 (storage), A24 (network/shares), A25 (guest tools), A26 (app/CLI parity) | Ordinary user journeys; recoverable data; truthful UI. |
| 5: final qualification | A27 (security), A28 (retirement), A29 (campaigns), A30 (release) | Exact candidate meets every finish gate. |

Waves express dependencies, not permission to idle. A04 can start today; it needs A02.1's regression fix only to measure end-to-end. A11 (ARM presentation) needs nothing from x86. A21 needs A00.3 only. A14.1's experiment needs A11's presentation path.

**x86 performance gates (owned by A02/A05/A06/A09, frozen by A29):**

| Gate | Target | Measured how |
|---|---|---|
| G0 | HEAD boots the frozen x86 fixture to `/sbin/init` without triple fault, KASLR enabled | A02.1 |
| G1 | ≥ 150 M guest instructions/s sustained across kernel boot (from ≈5.8 M today) | A04/A05 instrumentation |
| G2 | Fresh cold boot of frozen Ubuntu/Fedora x86_64 server image to agent-ready ≤ 90 s; desktop image to greeter ≤ 150 s | A05.5, A19 |
| G3 | Agent `/bin/true` RPC p50 ≤ 300 ms on a ready guest (from 218.7 s) | A02.3 protocol |
| G4 | Single-thread integer (CoreMark-like, frozen binary) ≥ 25 % of host-native; ≥ 40 % after A09 | A09.5 |
| G5 | 2 vCPU scaling ≥ 1.7×, 4 vCPU ≥ 3.0× on an embarrassingly parallel frozen workload; zero TSO litmus failures | A06.5 |
| G6 | Interactive desktop at 1080p: p95 frame interval ≤ 33 ms with hardware GL/Vulkan (relaxed from the ARM 16.7 ms budget; separately reported) | A14.5 |

---

## Implementation cards

Task directory:

- **Foundation:** [A00](#a00) auth, [A01](#a01) candidate/matrix/evidence, [A02](#a02) x86 regression and cost attribution.
- **x86 engine v2:** [A03](#a03) coverage ledger, [A04](#a04) memory/TLB/SMC core, [A05](#a05) tier-1 JIT redesign, [A06](#a06) threaded vCPUs/TSO/interrupts, [A07](#a07) scalar/system semantics, [A08](#a08) FP/SIMD/XSTATE, [A09](#a09) tier-2 optimizer, [A10](#a10) independent oracle.
- **GPU:** [A11](#a11) ARM zero-copy presentation and first frame, [A12](#a12) shared GPU semantics, [A13](#a13) PC host-visible BAR + Venus + first PC frame, [A14](#a14) GL strategy and desktop matrix, [A15](#a15) product behavior/recovery, [A16](#a16) FEX, [A17](#a17) container GPU.
- **OS cells:** [A18](#a18) ARM lifecycle/parity, [A19](#a19) installers/updates, [A20](#a20) devices, [A21](#a21) Mac production install/lifecycle, [A22](#a22) Mac policy/tools/Metal.
- **Product:** [A23](#a23) storage, [A24](#a24) network/shares, [A25](#a25) tools, [A26](#a26) app/CLI, [A27](#a27) security, [A28](#a28) retirement.
- **Finish:** [A29](#a29) campaigns, [A30](#a30) release.

---

## Foundation

<a id="a00"></a>

### A00 — Production authentication and trusted activation

**Owner/home:** `Packages/ContainerizationEngine/Sources/dory-hv/main.swift`, `DorydKit/DoryApplicationLaunchHandoff.swift`, `scripts/qualify-signed-launch-handoff.py`, `scripts/pc-gpu-daemon-live-gate.sh`.

**Starting point:** A00.1/A00.2 merged (`713473475`): no environment bypass; injection seam internal; 32 focused tests pass. Signed Release harness rejects unsigned/wrong-identity peers, fails closed on absent/malformed; wrong-team case is unavailable locally because all identities are Dory's team.

#### A00.1 — Remove ambient authentication override
- [x] Done. [receipt](docs/virtualization/evidence/review-fixes-2026-09-08/verification.json)

#### A00.2 — Contain the test seam
- [x] Done. `receiveIfRequested(arguments:authenticateDaemon:)` internal; public overload authenticates.

#### A00.3 — Exercise signed rejection and success on Release bytes
- [ ] **Action:** Keep `scripts/qualify-signed-launch-handoff.py` as the harness. Obtain the wrong-team case by signing the fixture peer with an ad-hoc or second-team identity in CI (not by weakening the check). Record valid, wrong-team, wrong-identity, unsigned, absent and malformed outcomes on the packaged Release runner.
- **Why:** Debug tests cannot establish Release peer admission.
- **Check:** Six outcomes recorded on packaged bytes; rejection precedes any descriptor use; wrong-team is a real rejection, not "unavailable".

#### A00.4 — Physical GPU harness through the production authority
- [ ] **Action:** Produce a schema-2 component catalog signed by the production component root (A01.5 output) so `pc-gpu-daemon-live-gate.sh` and the ARM desktop live gate can create a disposable VM through the installed daemon. Do not add test roots or bootstrap activation.
- **Why:** The harness must exercise the same authority as the product. [Negative admission already proven.](docs/virtualization/evidence/wave0-2026-09-08/pc-gpu-daemon-test-root-rejection.json)
- **Check:** Daemon accepts the production-root catalog, creates the VM, launches signed runner + worker with matching peer identity and granted FDs; the guest GPU readiness command runs.

#### A00.5 — Close the authority gate
- [ ] **Action:** Rerun A11.5 (ARM) and A13.5 (PC) frame checks on the signed candidate through this harness; attach hashes and negative results.
- **Check:** Signed candidate renders through the production path; security-boundary reviewer signs off.

**Card closes when:** environment cannot disable daemon authentication in shipped binaries and the physical GPU gates run through the real daemon.

<a id="a01"></a>

### A01 — Freeze candidate, fixtures, matrix and evidence

**Owner/home:** `scripts/inventory-wave0-candidate.py`, `scripts/validate-wave0-qualification-matrix.py`, `scripts/audit-plan-evidence.py`, `Config/DoryWave0QualificationMatrix.json`, producer scripts under `guest/` and `scripts/`.

**Starting point:** A01.1/A01.2/A01.4 done; matrix proposed but not approved; candidate source binding stale; historical audit points at the old plan's citations.

#### A01.1 — Inventory every producer
- [x] Done. [inventory](docs/virtualization/evidence/wave0-2026-09-08/candidate-producer-inventory.json); all three Mesa profiles verify; FFI archive at 14.0 floor.

#### A01.2 — Re-point and rerun the historical-evidence audit
- [x] **Done:** `scripts/audit-plan-evidence.py` now audits every evidence citation in **Where we actually are**, classifies `p07-macos-2026-09-05/host-metal-compute.json` as `host-only-not-guest`, and retains the four legacy receipts as `reacquisition-only`. [Current audit](docs/virtualization/evidence/wave0-2026-09-08/historical-evidence-audit-current.json)
- **Why:** The audit must check the claims the plan actually makes.
- **Check:** Passed with 12/12 cited paths resolved, no qualification-blocking documents, and no unresolved citations; seven focused auditor tests pass.

#### A01.3 — Freeze the test matrix
- [ ] **Action:** Finalize [`Config/DoryWave0QualificationMatrix.json`](Config/DoryWave0QualificationMatrix.json): host classes (oldest admitted M-series, midrange, high), macOS versions, Ubuntu 24.04 LTS + Fedora (current) for both Linux ISAs with immutable media digests, stock and managed kernel/Mesa profiles, GPU profiles (`venus`, `venus+zink` or `virgl2-angle` per D07 outcome), CPU profiles (`baseline`, `v2`, `v3`), 4 KiB/16 KiB page split, resource classes, Mac restore image. Supply the missing `arm64-virgl2-angle-metal` kernel/Mesa pins or drop the cell after A14.1 decides.
- **Check:** Release owner, runtime owner and security reviewer approve the exact digest; validator passes in `--require-approved` mode.

#### A01.4 — Prepare owned fixtures
- [x] Done. [preflight](docs/virtualization/evidence/wave0-2026-09-08/owned-fixture-preflight.json); Debian/Ubuntu/Kali ARM64 rootfs rebuilt; offline boot verified.

#### A01.5 — Build one coherent candidate and the production component root
- [ ] **Action:** Fresh signed rebuild at HEAD with complete source snapshot; regenerate the producer inventory (currently `incomplete: app source binding stale`). Establish the production component root signing flow that produces a schema-2 catalog (needed by A00.4). Second clean build reproduces inputs.
- **Check:** Inventory reports complete; schema-2 catalog verifies under the production root; development vs release signing clearly distinguished.

**Card closes when:** another engineer reproduces the same launch inputs and can tell mock, private fixture, development and release evidence apart.

<a id="a02"></a>

### A02 — Fix the x86 regression and attribute execution cost

**Owner/home:** `DoryPCDirectKernelMachine`, `DoryX86Interrupts`, `DoryX86Paging`, `dory-pc-uefi-smoke`, guest agent/vsock instrumentation.

**Starting point:** G0 is restored on a clean source-derived firmware build. The old `0x3fdc3743` fault came from a stale self-consistent bundle whose variable-runtime pointers still owned DXE Core `BootServicesCode`; candidate inventory now binds firmware to all platform sources. The 6 Sep build reached RPC. Milestone instrumentation exists (UART host-clock milestones, per-generation observation identity).

#### A02.1 — Diagnose and fix the EFI runtime fault (gate G0)
- [x] **Done:** The proposed source bisect was invalid because `051c97f25` and HEAD both contain the firmware fix `c8bfc2b0ff`; the failing fixture instead carried a pre-fix firmware bundle. A clean pinned build moves all variable-service pointers from DXE Core `BootServicesCode` to Dory `RuntimeServicesCode`, and the unchanged KASLR fixture reaches `/sbin/init`. [Receipt](docs/virtualization/evidence/wave0-2026-09-08/pc-efi-runtime-current-firmware.json)
- **Why:** Everything downstream measures against a booting guest.
- **Check:** KASLR-enabled optimizing-JIT boot reaches `/sbin/init`; the firmware probe validates runtime pointer ownership; 11 focused producer tests prevent stale source admission and pin the variable-driver dispatch contract. The interpreter remains a bounded semantic/conformance tier: its 100 M-instruction firmware control was censored without fault, and retained evidence shows full Linux boot is not practical (still in GRUB after two hours), so no interpreter full-boot claim is made.

#### A02.2 — Instrument and attribute the whole boot
- [ ] **Action:** On the fixed build, capture firmware, GRUB, kernel entry, root mount, init, agent bind, handshake, RPC milestones with one host clock. Add bounded counters: guest instructions executed, blocks translated/looked up/missed, dispatcher entries, TLB misses/walks, memory helper calls, device MMIO exits, timer interrupts, host CPU time per category. Measure instrumentation overhead.
- **Progress (2026-09-09):** Opt-in paging, memory-helper/MMIO, timer-request, and host wall/thread-CPU counters now join the existing instruction/JIT-cache/dispatcher telemetry. A release-build run on the fixed KASLR fixture reached GRUB, kernel, root mount, and init on one clock and reconciled 96.56% of wall time; three alternating 100 M-instruction pairs measured 5.14% median instrumentation overhead. The smoke fixture does not provide the production `dorycfg`/authenticated vsock agent path, so agent bind, handshake, and RPC remain open. [Receipt](docs/virtualization/evidence/wave0-2026-09-08/pc-boot-cost-attribution.json)
- **Check:** A report reconciles ≥ 90 % of wall time to counted categories; retained under `docs/virtualization/evidence/`.

#### A02.3 — Separate RPC from execution
- [ ] **Action:** On a ready guest compare serial echo, protocol ping and command RPC; capture request receipt → response delivery. Attribute vsock transport, guest scheduling and process creation separately.
- **Progress (2026-09-09):** `ExecResponse` now carries backward-compatible guest-monotonic queue, process-spawn, process-wait, output-drain, and request-receipt-to-response timings. The calibration CLI gained a bounded `profile` command that samples an echo-safe serial round trip, protocol handshake, uncached info RPC, and command RPC, then emits raw samples plus nearest-rank p50/p95 and an explicitly named transport/framing/host-scheduling residual. Parser, aggregation, compatibility, and canonical-receipt tests pass. A source-bound ready-guest run is still required; the retained 6 Sep observation remains 16.5 s handshake and 218.7 s `/bin/true`, so no performance gate is claimed. [Historical receipt](docs/virtualization/evidence/p06-pc-2026-09-06/tier-comparison-rpcdiag.json)
- **Check:** Three latencies reported with their owners; the dominant component named.

#### A02.4 — Fair tier comparison on the fixed build
- [ ] **Action:** Repeat interpreter/baseline/optimizing with identical disk state, resources, observer and timeout; retain unfinished runs as censored.
- **Check:** Boot and RPC reported separately per tier; no projection presented as observation.

#### A02.5 — Rank bottlenecks against D02–D06
- [ ] **Action:** Map measured cost to the architecture decisions (dispatcher returns, dictionary lookup, memory helper calls, TLB dictionary, 64-instruction cap, generation checks). Confirm the A04/A05 order or reorder with data. Verify user cancellation remains bounded during slow boot.
- **Progress (2026-09-09):** The fixed-build counters rank D02/D03 first (73.77 memory helpers and 73.32 translations per 100 retired instructions, but only 0.189% of translations walk), D04 second (35.49 generation checks per 100 instructions with a 0.00246% mismatch rate), and D05 third (2.82 instructions per optimizing block; only 1.46% chained). D06 remains fourth because its wall share is not independently observed; no share is fabricated. This confirms A04.1 → A04.2 → A04.3 → A05.1 → A05.2. Active infinite-guest power-off returns within the one-second bound on interpreter, baseline JIT, and optimizing JIT. [Receipt](docs/virtualization/evidence/wave0-2026-09-08/pc-execution-bottleneck-ranking.json)
- **Check:** Ranked list with percentages; A04/A05 step order confirmed or amended in place; cancellation test passes.

**Card closes when:** G0 met, cost attributed, and the first engine change is chosen from measurement.

---

## x86 engine v2

The x86 engine is rebuilt in place in `DoryDBTX86`/`DoryJITRuntimeC`, keeping the decoder, IR, paging semantics, interrupt delivery and interpreter. Each card lands behind a feature flag on the executor so the interpreter and the old baseline remain runnable for differential testing until A28 retires them.

<a id="a03"></a>

### A03 — Authoritative instruction and feature coverage ledger

**Owner/home:** `DoryX86CPUProfile`, `DoryX86InstructionFeaturePolicy`, `dory-x86-decode-audit` (schema 3 inventory), vectors.

**Starting point:** Conservative `compat-v1`/`intel-compatible-v1` profiles; F16C/FMA/BMI/LZCNT/MOVBE identities and v3 CPUID/control requirements added but masked; 15 audit tests; per-form proof dimensions reported. A03.3 partial.

#### A03.1 — Enumerate the promised architecture
- [ ] **Action:** From pinned Intel SDM and x86-64 psABI revisions, enumerate every mandatory instruction form (encoding, operand size, address size, mode, prefix legality) and privileged-state dependency for baseline, v2 (SSE3–SSE4.2, POPCNT, CX16, LAHF/SAHF, SSSE3) and v3 (AVX/AVX2, F16C, FMA, BMI1/2, LZCNT, MOVBE, XSAVE/OSXSAVE). Include system instructions Linux/GRUB/EDK2 require.
- **Check:** Pinned revisions; reviewer finds no missing family; ledger is machine-readable.

#### A03.2 — Separate implementation from proof
- [ ] **Action:** Extend the schema-3 inventory with columns: decoder, interpreter, JIT-v2 native, JIT-v2 helper, flags, faults, memory ordering, independent reference. States: unsupported / implemented-unqualified / qualified.
- **Check:** Every row links to executable vectors or an explicit gap.

#### A03.3 — Audit public feature state
- [x] Partial: identities and CPUID/control requirements merged, all new features masked; 18 focused tests. [receipt](docs/virtualization/evidence/wave0-2026-09-08/wave1-foundation-verification.json)
- [ ] **Action:** Fix the audit finding that CPUID can advertise SSE3/SSE4/AVX/XSAVE bits under `unqualifiedSIMDAndExtendedStateFeatures`; guest-observed CPUID, MSRs and XCR0 must equal implemented state. Round-trip persisted profiles; `#UD` tests for unadvertised forms.
- **Check:** Guest-visible CPUID/XCR0 equals enabled code paths; old persisted profiles keep meaning.

#### A03.4 — Assign each gap
- [ ] **Action:** Produce the finite gap list assigning every form to A07 (scalar/system) or A08 (FP/SIMD/XSTATE), with expected outputs/faults. Decide crypto/CRC32/RDRAND/RDSEED explicitly (RDRAND/RDSEED must have real entropy or be unadvertised).
- **Check:** No unowned required row.

#### A03.5 — Freeze profile promotion rules
- [ ] **Action:** Freeze `dory.x86_64.baseline@N`, `v2@N`, `v3@N` identifiers and upgrade rules; promotion requires every mandatory row qualified.
- **Check:** Promotion rejected while any row lacks evidence; old-profile restore tested on the promoted candidate.

<a id="a04"></a>

### A04 — Execution core: guest memory model, inline TLB and SMC protection (D02–D04, D12)

**Owner/home:** `DoryX86MmapMemory`, `DoryX86Paging`, `DoryJITRuntimeC`, `DoryPCPhysicalMemory`, DMA hooks in `DoryMachinePC` and `VirtioGPU` host-visible mappings.

**Starting point:** Flat `mmap` RAM exists but is reached only through Swift accessors; the TLB is a Swift dictionary; SMC is detected by per-page write generations; DMA and GPU mappings write RAM directly.

#### A04.1 — Flat guest-physical reservation
- [x] **Action:** Reserve the full `dory.pc@1` physical range in one `mmap(PROT_NONE)` at engine start; commit RAM ranges `PROT_READ|WRITE`; leave MMIO/ROM holes unmapped or read-only. Firmware ROM at `0xFF00_0000` is read-only mapped. Expose `base` to generated code through the vCPU context. Keep `DoryX86MmapMemory`'s API as a thin view for the interpreter and devices.
- **Why:** Enables `host = base + gpa` addressing without per-access calls.
- **Progress (2026-09-09):** `DoryX86MmapMemory` now owns one sparse reservation with compact interpreter/device views, direct GPA-offset RAM mappings, `PROT_NONE` holes, and immutable filled mappings. `DoryPCDirectKernelMachine` selects the smallest admitted 36–40-bit power-of-two GPA space (64 GiB through 1 TiB), maps high RAM above 4 GiB, and mirrors firmware at `0xFF00_0000`; the physical bus and paging view preserve the base into the 28-word JIT context. Mach VM access probes verify that MMIO reads and ROM writes are rejected, bus tests preserve device dispatch/write rejection, the maximum 512 GiB RAM configuration receives a 1 TiB reservation, and RSS remains below the 256 MiB reservation-overhead bound. The complete `DoryDBTX86Tests` + `DoryMachinePCTests` gate passes (1,320 tests, 166 suites). Generated inline translation/C slow path remains A04.2; process fault interception and dispatch remains A04.3.
- **Check:** Interpreter results unchanged on the full test suite; MMIO accesses fault into the device path; ROM writes fault; memory footprint accounted (RSS vs reserved).

#### A04.2 — Per-vCPU inline TLB and C slow path
- [x] **Action:** Add direct-mapped TLB arrays (e.g. 1024 entries × read/write/execute) in the vCPU context: `{vpn|asid_tag, host_addr_delta, perms}`. Generated code: shift VA, index, compare tag, add delta — one load + compare + branch on the fast path. Slow path in C calls into a Swift-exported walker (`DoryX86Paging.translate`) via `@_cdecl`, fills the entry, or raises the architectural `#PF` with the correct error code and CR2. Flush on CR3/CR0/CR4/EFER changes, `INVLPG`, `INVPCID`, and on page-table writes to pages cached in the TLB (tracked by a page bitmap).
- **Progress (2026-09-09):** Every PC vCPU now owns independent C-allocated 1,024-entry read/write/execute arrays (48 KiB total) with an exact canonical-VPN plus nonzero 28-bit address-space-generation tag, host-address delta, access-class separation, wrap-safe generation flush, and targeted page eviction. The fixed JIT context carries all three bases, mask, generation, sparse host reservation, C resolver, and hit-counter pointers. Scalar read emission performs the inline tag/index/delta path; a miss crosses a C ABI into the Swift paging walker, fills only direct RAM, rejects MMIO/cross-page spans, and preserves exact page-fault address/error for restart through the architectural interpreter. CR0/CR3/CR4/EFER, INVLPG, and INVPCID invalidations propagate from the paging unit; paging-structure pages observed by the walker are tracked sparsely, guest mutations invalidate both caches before a chained native load, and walker-owned A/D writes are suppressed from that dirty signal. Aggregate PC, UEFI-smoke, and PVH diagnostics report hits, misses, fills, page faults, fallbacks, invalidations, allocation, generation, and hit rate. Focused remap tests prove the next native load observes the new physical page, and the full DBT/PC gate passes (1,337 tests, 167 suites). A04.5 retains the separate write-side helper-removal and workload-performance proof.
- **Check:** Paging test suite passes through the TLB; page-table edits invalidate; fault priority and A/D bit updates unchanged; TLB hit rate reported by A02 counters.

#### A04.3 — Self-modifying code via page protection
- [ ] **Action:** When a guest page receives translated code, `mprotect` its host page read-only. Install a Mach exception handler (preferred) or `SIGSEGV`/`SIGBUS` handler in `DoryJITRuntimeC` on vCPU threads: on write fault to a protected page, invalidate all translations for that guest page (and chained predecessors), unprotect, and resume the faulting guest store precisely (re-execute via the slow path if the store was mid-instruction). Route device DMA and GPU host-visible writes through an explicit `invalidateCodePage(gpa)` hook. Remove per-write generation counters after parity.
- **Progress (2026-09-09):** Resident translated guest pages are protected read-only through `DoryX86MmapMemory`; the implementation tracks 4 KiB guest code pages while conservatively changing protection at the host allocation granule. Protection changes publish a shared generation, and every per-vCPU executor flushes stale write-TLB entries before dispatch. Consequently the first translated store to protected code cannot reach a stale direct pointer: its write-TLB miss takes the resolver slow path, restores write permission, invalidates every protected guest code page sharing that host granule, advances code generations, fills the safe direct address, and completes the original store once. This precise pre-store slow-path design avoids a mid-instruction host signal while retaining the plan's permitted re-execution semantics. Checked device/DMA writes use the same invalidation authority, and the PC bus exposes `invalidateCodePage(gpa:)`. Tests cover checked SMC recompilation, translated-store SMC recompilation, DMA invalidation, host-granule aliasing, cross-vCPU protection-generation synchronization, and 512 repeated protect/write cycles. The complete DBT/PC gate passes (1,343 tests, 167 suites). The checkbox remains open pending the named GRUB/kernel-alternatives/guest-JIT corpus, concurrency race evidence, and removal of the temporary per-write generation oracle after parity.
- **Progress (2026-09-09, byte-revalidation coherency follow-up):** Production diagnosis isolated a second protection boundary: after a sibling code-page write made a shared host allocation granule writable, unchanged resident-byte validation and shared-code reuse could republish native code without restoring read-only protection. An older inline write-TLB entry could then mutate guest code without another protection fault or generation advance, leaving stale translation lookup-visible. Fresh compilation, byte-validated reuse, and shared-code reuse now share one reprotection boundary; a changed protection flushes the executor's translation TLB and records the new shared generation before publication. Exact regressions reproduce both reuse paths, the full DBT/PC gate passes 1,444 tests in 171 suites with the restored CR3 admission, and the previously failing pinned Linux workload now passes all seven userspace checks and powers off after 733,843,413 instructions. A04.3 remains open for the named corpus, race evidence, and generation-oracle removal. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-cr3-smc-reprotection-recovery.json)
- **Check:** SMC test corpus (kernel alternatives patching, GRUB relocation, JIT-in-guest) passes; DMA into code pages invalidates; no lost invalidation under a stress fuzz with `-fsanitize=thread`-like race checks where available.

#### A04.4 — Atomics and locked operations
- [x] **Action:** Implement `LOCK`-prefixed RMW, `XCHG`, `CMPXCHG8B/16B` as `LDAXR/STLXR` loops or LSE (`CAS`, `LDADD`, …) on the host address, with unaligned-atomic fallback (split lock) via a global lock path. Ensure these interoperate with the interpreter's `DoryX86AtomicScalarMemory` semantics for differential tests.
- **Progress (2026-09-09):** Long-mode 32/64-bit memory `CMPXCHG`, including the accepted `LOCK` form, implicit-lock 32/64-bit memory `XCHG`, 32/64-bit memory `XADD` including its `LOCK` form, 32/64-bit `LOCK ADD/ADC/SUB/SBB/AND/OR/XOR`, 32/64-bit `LOCK INC/DEC/NOT/NEG`, 32/64-bit `LOCK BTS/BTR/BTC`, and aligned `CMPXCHG8B/16B` now resolve through the per-vCPU write TLB into C runtime host-address atomics. Register and immediate binary and bit-index sources are admitted. Naturally aligned RAM uses compiler-lowered sequentially consistent C11 compare-exchange/exchange/fetch and RMW operations; the 128-bit pair operation serializes two 64-bit words under the same global gate. Page faults return to the precise interpreter boundary, while unaligned, cross-page, MMIO, and tracked page-table operands decline without effects to the existing serialized fallback. The interpreter and native fallback share one C-owned split-lock mutex, preserving single-copy behavior during incremental conversion. The binary, carry/borrow, unary, bit RMW, and pair compare-exchange operation/width matrices match the interpreter's result, registers, and flags in both tiers, including wraparound for both incoming-carry states, signed register bit indices selecting preceding/following words, confined high immediate bit indices, INC/DEC carry preservation, NOT flag preservation, pair success/mismatch behavior, 8-byte upper-half register rules, independent CMPXCHG8B/CMPXCHG16B feature admission, and 16-byte replacement. Immediate-source and unaligned-decline precision also pass alongside swap, returned-old-value, cached-translation reuse, and fault rollback. A four-vCPU mixed interpreter/native single-copy litmus matrix covers every emitted locked transformation family; XCHG produces one linearizable token history, and CMPXCHG/CMPXCHG8B/CMPXCHG16B each produce exactly one winner across independent native executors and the interpreter. Ten repeated focused runs pass, and the complete DBT/PC gate passes (1,358 tests, 167 suites).
- **Check:** Atomic vector tests pass in interpreter and JIT; unaligned locked ops produce correct results; single-copy atomicity litmus tests pass.

#### A04.5 — Prove the core before the JIT redesign
- [ ] **Action:** Route the *existing* baseline JIT's memory operations through the inline TLB and flat addressing (helpers become the slow path). Measure with A02.2 counters.
- **Progress (2026-09-09):** Existing baseline scalar loads and stores now execute as native host accesses after an inline exact-tag TLB lookup; Swift/C helpers are restricted to miss, MMIO, cross-page, page-fault, and tracked-page-table slow paths. Native hit counters and C miss/fill/fault/fallback counters are projected through PC, UEFI-smoke, and PVH diagnostics. Two-dispatch tests prove both the read and write hit paths avoid another Swift page walk, and the complete DBT/PC gate passes (1,343 tests, 167 suites). Atomic/RMW helper removal and the frozen-fixture wall-share/instructions-per-second receipt remain before closure.
- **Check:** Full `DoryDBTX86Tests` and `DoryMachinePCTests` pass; x86 fixture boots; memory-helper share of wall time falls to < 10 %; report the new instructions/s.

**Card closes when:** guest memory accesses are host loads/stores with inline translation, SMC is page-protection based, and parity with the interpreter is proven.

<a id="a05"></a>

### A05 — Tier-1 JIT redesign: pinned registers, lazy flags, chaining, IBTC (D05, D06)

**Owner/home:** `DoryARM64BaselineJIT` (replaced in place by `DoryARM64Tier1`), `DoryDBTIR`, `DoryJITRuntimeC` dispatcher/patcher.

**Starting point:** Block-at-a-time compiler with Swift dispatcher return after every block; no chaining; no pinned registers; eager flag synthesis; 64-instruction cap; Dictionary lookup.

#### A05.1 — Fixed register convention and vCPU context
- [x] **Action:** Define the ARM64 register map: x86 RAX–R15 → `x0–x15` (or a documented permutation avoiding ARM64 ABI clashes in helper calls), context pointer `x28`, RIP `x27`, flags state `x25/x26`, TLB base derived from context, scratch `x16/x17`, callee-saved for the dispatcher. Define helper-call shims that spill only what a helper needs. Document in `DoryDBTX86/ABI.md`.
- **Progress (2026-09-09):** `DoryARM64Tier1ABI` freezes the injective pinned map (RAX–R15 in `x0`–`x15`, scratch `x16/x17`, Darwin-reserved `x18`, dispatcher `x19`–`x24`, lazy flags `x25/x26`, RIP `x27`, context `x28`) and is the executable source of truth for the append-only context indices. `DoryARM64Tier1BoundaryEmitter` supplies reusable machine-code entry, helper-call, and exit fragments: the entry preserves the Darwin callee-saved set in an aligned host frame, helper calls checkpoint and reload exactly their declared live guest subset while using typed argument sources, and the exit publishes precise pinned state before restoring the host ABI. `ABI.md` defines entry/exit, chaining, partial-register, helper-call, and restartable-state rules. Executed MAP_JIT tests prove register ownership, context-layout parity, exact spill scaling, all-register/state round-trip, helper result routing, and preservation across a real C helper call. While validating this work, the parallel gate exposed and fixed a JIT allocation race: code and guard pages now originate in one indivisible MAP_JIT mapping, so cleanup cannot unmap an unrelated concurrent RAM allocation; a 1,024-allocation concurrency regression and three consecutive normal parallel DBT/PC gates pass (1,363 tests, 168 suites).
- **Check:** ABI doc reviewed; helper shim tests confirm no clobber; interpreter ↔ JIT state round-trips.

#### A05.2 — Lazy flags with NZCV fast paths
- [x] **Action:** Represent EFLAGS as `{op, size, result, src1, src2}` in the context; materialize on `PUSHF`, `LAHF`, `SETcc`/`Jcc` needing non-NZCV flags, interrupt entry, and helper boundaries. Fuse `CMP/TEST/SUB/ADD → Jcc/SETcc/CMOVcc` into ARM `SUBS/ANDS` + native condition codes (mapping CF inversion, PF via table only when required). ADC/SBB/shift/rotate get dedicated materializers.
- **Progress (2026-09-09):** The stable context now appends `{op+count, width, result, source1, source2}` at words 43–47 while retaining word 17 as the last materialized RFLAGS image. `DoryARM64LazyFlagsState` round-trips that record and exactly materializes ADD/ADC/SUB/SBB, logical operations, INC/DEC, NEG, SHL/SHR/SAR, ROL/ROR, RCL/RCR, and SHLD/SHRD across their architectural 8/16/32/64-bit widths while preserving non-arithmetic, undefined, and architecturally unchanged bits. Baseline context creation explicitly clears pending state, and executor exit materializes a pending record before publishing architectural state, allowing producers to migrate incrementally without changing interpreter semantics. Exhaustive arithmetic boundary matrices and interpreter-oracle shift/rotate matrices cover carry, overflow, auxiliary carry, parity, zero, sign, zero/full/oversized masked counts, carry preservation, and context encoding. The first executable pinned-register tier-1 body fragment now emits low 8/16-bit, AH/CH/DH/BH, and native 32/64-bit ADD/ADC/SUB/SBB/CMP/AND/TEST/OR/XOR and INC/DEC/NEG producers, preserves every surrounding register bit, persists the complete pending record, and fuses adjacent SETcc, CMOV64, and conditional RIP selection through ARM NZCV with subtraction-CF inversion, domain-correct carry mappings, and explicit carry-preserving INC/DEC exclusions. Narrow operands are sign-bit aligned before flag-setting operations so fused N/Z/C/V conditions remain width-correct; narrow ADC/SBB results are exact but conservatively require materialization because ARM's carry input cannot be aligned with the operands. SHL/SHR/SAR/ROL/ROR/RCL/RCR producers now accept immediate and CL counts at every width, preserve partial registers, retain or resolve older lazy flags correctly for masked-zero counts, and defer all consumers to their dedicated materializers; bounded RCL/RCR bit loops implement the required modulo-9/modulo-17 narrow counts. Register SHLD/SHRD producers cover 16/32/64-bit immediate and CL forms, including the interpreter's deterministic 16-bit oversized-count result. Unsupported parity and addition `CF || ZF` combinations explicitly decline without appending code; constant logical predicates collapse to moves/no-ops. A one-CBZ on-demand boundary now calls a stable materializer only for a pending record, preserves all pinned GPRs across the Darwin C ABI, replaces `x25` with current RFLAGS, clears `x26` and the context payload, and increments a per-dispatch counter; flag-observing helper shims opt into that boundary explicitly. General SETcc, CMOV64, and conditional-RIP fallbacks share a complete materialized evaluator for all 16 x86 conditions. LAHF now consumes the materialized image into AH, and PUSHF lowering receives the required RF/VM-cleared, bit-1-set image for its future tier-1 stack write. `DoryARM64Tier1Emitter` now performs atomic, register-only whole-block admission for those producers and consumers, labels published code as `tier1`, and sits behind the executor's default-off `tier1Enabled` flag; declined blocks still compile through the old baseline. Direct execution and multi-block chained-dispatch tests prove interpreter-equivalent state, fused compare→Jcc with zero materializations, materializing parity SETcc, and exact counter aggregation. Executor, machine-wide, UEFI-smoke, and PVH boot diagnostics now report tier-1 compiled-block and lazy-materialization totals. MAP_JIT matrices prove all-width producer state/flags against the interpreter with both carry inputs, low/high-byte surrounding-bit preservation and native condition selection, all shift/rotate and double-shift operations under immediate and CL zero/full/oversized counts, both carry inputs, modulo-width-plus-one behavior, prior-record preservation, every admitted native condition across subtraction, addition, logical, and unary domains, fused and materialized CMOV/Jcc selection, every materialized condition, single-count materialization across multiple consumers, the no-call fast path, helper-visible materialized state, LAHF packing, and PUSHF sanitization. The legacy baseline ABI was not extended. The PUSHF stack write, interrupt consumers, wider tier-1 statement/helper coverage, production enablement, and performance evidence remain.
- **Progress (2026-09-09, PUSHF follow-up):** The tier-1 entry now preserves the generated-function memory context and callbacks in the dispatcher-owned callee-saved bank. PUSHF materializes and sanitizes the RFLAGS image, performs its eight-byte stack write through that stable callback, and publishes the decremented RSP only on success. Interpreter-differential MAP_JIT coverage proves the successful memory image and architectural state; an injected write failure proves unchanged state and memory on the interpreter retry path. Interrupt consumers, wider tier-1 statement/helper coverage, production enablement, and performance evidence remain.
- **Progress (2026-09-09, boundary/coverage follow-up):** Register-only MOV and flag-neutral NOT now execute in tier-1 for low 8/16/32/64-bit operands with exact partial-register and dword-zero-extension behavior; the old baseline gained matching word coverage so decline remains semantics-preserving. Their flag-neutral ARM sequences preserve a validated NZCV producer token across intervening instructions into fused Jcc. Every native return now counts and materializes a pending record before architectural state is visible; because the PC run loop delivers interrupts only after that publication boundary, interrupt entry cannot observe private lazy state. Differential baseline/tier-1 tests cover word NOT, MOV widths, preserved flags/upper bits, fusion, and per-boundary counter totals. Wider tier-1 statement/helper coverage, production enablement, and performance evidence remain.
- **Progress (2026-09-09, production-admission follow-up):** The PC machine's baseline executor now enables whole-block tier-1 admission in production while retaining atomic legacy-baseline fallback for every declined block; standalone executors remain opt-in for differential isolation. A protected-mode machine regression executes MOV/ADD/direct-branch blocks as tier-1, verifies exact architectural/accounting results, then replaces the live site with unsupported CPUID and proves interpreter fallback. The full DBT/PC gate passes with production admission (1,403 tests, 171 suites). Wider tier-1 statement/helper coverage and frozen-fixture performance evidence remain before A05.2 closes and the legacy baseline can be disabled.
- **Progress (2026-09-09, flag-byte follow-up):** LAHF and SAHF now have explicit IR operations instead of falling through an opaque statement path. The legacy baseline and tier-1 emitters both implement their exact AH/RFLAGS transforms; tier-1 LAHF materializes a pending record before packing the canonical flag byte, while tier-1 SAHF materializes first and then replaces only CF/PF/AF/ZF/SF from AH, forcing reserved bit 1 and preserving every other RFLAGS bit. Long-mode native admission is gated by the advertised `.lahf64` feature before either compiler can publish code. Interpreter-differential MAP_JIT tests cover both directions, surrounding-bit preservation, an ADD→LAHF boundary with exactly one materialization, and feature-profile decline. The full DBT/PC gate passes with 1,406 tests in 171 suites. Wider tier-1 statement/helper coverage and frozen-fixture performance evidence remain before A05.2 closes and the legacy baseline can be disabled.
- **Progress (2026-09-09, scalar flag-control follow-up):** CLC, STC, and CMC now lower to explicit IR and execute in both native tiers. Tier-1 resolves an older arithmetic record before replacing or toggling CF, whereas CLI, CLD, and STD update only the non-arithmetic base image and deliberately leave that record pending; their flag-neutral ARM sequences preserve an eligible NZCV token. Production privilege admission still rejects user-mode CLI before either compiler can publish code. One differential block carries an ADD record across STD/CLI, proves a single materialization at STC, applies CMC/CLC, and verifies the final LAHF image against the interpreter in both tiers. The full DBT/PC gate passes with 1,407 tests in 171 suites. Wider tier-1 statement/helper coverage and frozen-fixture performance evidence remain before A05.2 closes and the legacy baseline can be disabled.
- **Progress (2026-09-09, restartable-stack follow-up):** Tier-1 now admits long-mode register/immediate PUSH and register POP through the preserved scalar callbacks. Each stack helper resolves lazy flags before borrowing the payload words as staging storage, spills and reloads all pinned GPRs across the Darwin C ABI, preserves pre-decrement PUSH RSP semantics, and implements POP RSP aliasing exactly. Callback failure discards the temporary context; a block is rejected if any callback follows a committed stack write, while read-before-write blocks require the replay-safe scalar-read capability. Interpreter-differential MAP_JIT tests cover extended registers, RSP aliases, sign-extended immediates, successful POP→PUSH replay, pending ADD materialization, and failed read/write rollback. The full DBT/PC gate passes with 1,410 tests in 171 suites. Wider memory/helper coverage and frozen-fixture performance evidence remain before A05.2 closes and the legacy baseline can be disabled.
- **Progress (2026-09-09, register-transform follow-up):** Callback-free qword XCHG, dword/qword BSWAP, register MOVSX/MOVZX/MOVSXD, and CDQ/CQO now execute directly on pinned registers in tier-1. The emitted ARM operations are flag-neutral, retain the pending lazy record, and preserve an eligible NZCV token across the complete transform chain into a fused conditional branch. Interpreter-differential MAP_JIT matrices cover every admitted source/destination width, zero-extension, sign boundaries, register aliasing, and a mixed CMP→XCHG→BSWAP→MOVSX/MOVZX→CQO→Jcc block. The full DBT/PC gate passes with 1,412 tests in 171 suites. Wider memory/helper coverage and frozen-fixture performance evidence remain before A05.2 closes and the legacy baseline can be disabled.
- **Progress (2026-09-09, admission-telemetry follow-up):** Tier-one compiler coverage is now measurable instead of inferred from successful publications. Executor, aggregate PC, UEFI-smoke, and PVH diagnostics report cumulative attempt and decline totals alongside compiled-tier and lazy-materialization counts; an attempt begins only after architectural preflight, a decline records atomic handoff to the legacy emitter, and resident/shared cache hits do not inflate either compiler-boundary counter. Focused tests prove enabled success, enabled decline, disabled zero-attempt behavior, machine aggregation, and runner serialization. The full DBT/PC gate remains green with 1,412 tests in 171 suites. The cached PVH kernel/initramfs pair is absent locally, so no materialization-rate or performance claim is fabricated; the existing stateful UEFI fixture path will supply that measurement next.
- **Progress (2026-09-09, bounded-performance follow-up):** The production PC baseline path now accepts an explicit default-on tier-one switch, and both UEFI-smoke and PVH diagnostic runners expose a default-on measurement override while preserving historical PVH receipt decoding. A release-build, six-run alternating A/B used the repository-pinned Alpine 3.24.1 PVH kernel/initramfs for exactly 100 million retired instructions per run. Three legacy medians were 60.626 seconds (1.649 MIPS); three tier-one medians were 36.624 seconds (2.730 MIPS), a 39.59% elapsed reduction, 1.655x speedup, and 65.53% throughput uplift. Tier-one admitted 2,926 of 7,164 attempted unique sites (40.84%) and materialized 5,318,303 lazy records, or 5.39 per 100 native-retired instructions. All enabled execution/counter totals were identical across trials. The result is bounded early-boot engineering evidence: every run stopped at the instruction budget before console output, KASLR remained enabled, and it does not claim userspace, workload, cross-host, G1-G5, or release qualification. The full DBT/PC gate passes with 1,413 tests in 171 suites. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-early-boot-ab.json)
- **Progress (2026-09-09, effective-address follow-up):** LEA now forms 32- and 64-bit effective addresses directly from pinned base/index registers, scaled indexes, signed displacements, and instruction-relative bases. The complete address is staged before destination publication so destination/base/index aliases are exact; 32-bit address arithmetic wraps and destination writes retain x86 zero-extension semantics. The flag-neutral sequence preserves both the pending lazy record and an eligible live NZCV token into a fused conditional branch. Interpreter-differential MAP_JIT tests cover address widths, scale, negative displacement, RIP-relative addressing, aliasing, and CMP→LEA→Jcc. The full DBT/PC gate passes with 1,415 tests in 171 suites. General memory/helper coverage and successful userspace evidence remain before A05.2 closes and the legacy baseline can be disabled.
- **Progress (2026-09-09, timestamp follow-up):** RDTSC now reads the dispatcher-sampled virtual TSC directly from the pinned context and publishes its low/high dwords through EAX/EDX in tier-one. The flag-neutral sequence preserves the architectural flag image and exact dword zero-extension, while the existing translator and chained executor still isolate RDTSC as a mandatory dispatch boundary so the machine clock is resampled before the read and before subsequent guest work. A MAP_JIT regression proves value, flags, upper-half clearing, tier-one admission, and one-instruction chain termination. The full DBT/PC gate passes with 1,416 tests in 171 suites. This expands observed delay-loop coverage but does not resolve or reclassify the failed full-budget PVH probe.
- **Progress (2026-09-09, fence-helper follow-up):** LFENCE, MFENCE, and SFENCE now execute through the tier-one synchronization boundary. The generated fragment checkpoints all pinned caller-saved guest GPRs, invokes the memory owner's preserved Darwin callback exactly once, applies the same conservative DSB/ISB completion sequence as the legacy emitter, reloads every GPR, and invalidates the call-clobbered native NZCV token without discarding the callee-saved lazy record. Compiled metadata requests callback installation but does not falsely mark the non-failing fence as an interpreter side exit. Focused MAP_JIT tests prove all-register/flag round-trip, tier-one publication, and one synchronization event for every fence; the full DBT/PC gate remains green with 1,416 tests in 171 suites.
- **Progress (2026-09-09, segment-read follow-up):** Long-mode MOV-from-segment now reads CS/DS/ES/FS/GS/SS selectors from their stable context words directly into word-sized pinned GPR destinations. The fragment replaces only the low 16 bits, preserves the lazy record and native NZCV token, and therefore permits a mixed CMP→six selector reads→Jcc block to remain fused. An interpreter-differential MAP_JIT regression covers every selector, extended-register destinations, upper-bit preservation, exact architectural state, and the single exit materialization. The full DBT/PC gate passes with 1,417 tests in 171 suites; memory-destination segment writes still decline atomically to the legacy baseline.
- **Progress (2026-09-09, bit-scan follow-up):** Register-source BSF/BSR now execute in tier-one for dword and qword operands. The lowering first resolves an older lazy producer, computes the scan with RBIT/CLZ or CLZ/XOR, updates only materialized ZF under the engine's deterministic undefined-flag policy, leaves the entire destination unchanged on zero input, and zero-extends a nonzero dword result. The existing exhaustive interpreter oracle now includes tier-one for zero, all ones, every individual bit, aliases, extended registers, and the measured REP-prefixed kernel encoding. The full DBT/PC gate remains green with 1,417 tests in 171 suites; memory-source scans continue through atomic legacy fallback.
- **Progress (2026-09-09, register-bit-test follow-up):** Register-base BT/BTC/BTR/BTS now execute in tier-one for dword and qword operands with register or imm8 indexes. The index is reduced and staged before any destination write so base/index aliases are exact; an older lazy record is materialized before only CF is replaced, and dword-mutating forms zero-extend. The existing three-tier interpreter differential covers clear/set carry, wrapped and negative indexes, test/set/reset/complement, base/index aliasing, and upper-half semantics. The full DBT/PC gate remains green with 1,417 tests in 171 suites; memory-base and locked forms remain on restartable legacy paths.
- **Progress (2026-09-09, signed-multiply follow-up):** Callback-free two- and three-operand IMUL now execute in tier-one for dword and qword register destinations with register or sign-extended immediate sources. The lowering stages the full signed product before destination publication, compares the discarded high half with the truncated result's sign extension, and replaces only CF/OF after resolving any older lazy record; dword results retain x86 zero-extension semantics. The existing baseline/optimizing interpreter differential now exercises tier-one register aliases, negative operands, sign-extended immediates, and overflowing/non-overflowing products while memory-source forms continue through atomic legacy fallback. The full DBT/PC gate remains green with 1,417 tests in 171 suites; accumulator MUL/IMUL, memory operands, and DIV/IDIV remain separate slices.
- **Progress (2026-09-09, accumulator-multiply follow-up):** The qword accumulator MUL form now executes directly on pinned registers in tier-one, stages the complete unsigned product before publishing RDX:RAX, and replaces only CF/OF according to whether the high half is nonzero after resolving an older lazy producer. The expanded three-tier interpreter differential covers zero and nonzero high halves, RAX and RDX source aliases, an extended source register, an ADD→MUL materialization boundary, and a following SHRD consumer. The full DBT/PC gate remains green with 1,417 tests in 171 suites; narrower accumulator forms, signed one-operand IMUL, memory operands, and DIV/IDIV remain separate slices.
- **Progress (2026-09-09, measured-dword-MUL follow-up):** The retained full-budget negative-cache sample identifies two dominant native-emitter sites inside `delay_tsc`; disassembly of the pinned kernel shows one contains the exact `mul edx` form at `0xffffffff81e2dc36`. Dword accumulator MUL is now admitted by the translator and both native compilers. Tier-one zero-extends EAX and its source before forming the complete 64-bit product, publishes EDX:EAX only after consuming aliases, and applies the same CF/OF-only rule as qword MUL. Three-tier interpreter parity covers zero/nonzero high halves and the measured encoding, and the full DBT/PC gate remains green with 1,417 tests in 171 suites. This removes the arithmetic decline but does not claim the whole measured block: its adjacent RIP-relative load remains outside tier-one memory coverage.
- **Progress (2026-09-09, restartable-scalar-load follow-up):** Tier-one now admits scalar memory-to-register MOV for byte, word, dword, and qword operands through the preserved read callback. Effective-address formation covers 32-/64-bit base/index/scale arithmetic, signed displacement, RIP-relative addressing, destination aliases, and FS/GS bases before checkpointing every pinned GPR. The callback result is staged without destroying the authoritative pinned RIP or pending lazy record; the helper invalidates native NZCV, multi-read blocks require replay-safe memory, and a callback fault rolls the entire block back before interpreter fallback. Interpreter parity and fault tests cover every width, address forms, upper-bit behavior, segment bases, replay admission, and non-replay rejection. The exact measured 18-byte `mul edx` → RIP-relative MOV → LEA → JMP block at `0xffffffff81e2dc36` now compiles as one tier-one block with one memory callback, and the full DBT/PC gate passes with 1,420 tests in 171 suites. The separate hotter memory-source CMOV site remains outside tier-one coverage.
- **Progress (2026-09-09, measured-memory-CMOV follow-up):** Dword and qword memory-source CMOV now lower to typed IR and execute in both native tiers. The memory source is read unconditionally before the predicate, preserving x86's false-CMOV fault behavior; tier-one first resolves any pending lazy producer, restores every pinned GPR across the callback, evaluates from the materialized image, applies dword zero-extension on either outcome, and rolls faults back to the precise block checkpoint. Differential MAP_JIT coverage spans true/false predicates, both widths, destination/address aliases, mandatory callback counts, pending TEST materialization, and false-condition faults. The exact 15-byte `cmove rdx,[rip+0xbe43e1]` → `imul rdx,rdx,0xfa` hot block now compiles in tier-one. More strongly, all nine instructions in the measured 52-byte `delay_tsc` body from the GS load at `0xffffffff81e2dc14` through its terminal jump compile as one tier-one block with three replay-safe reads. The full DBT/PC gate passes with 1,425 tests in 171 suites; a fresh frozen-fixture run is required before claiming any runtime improvement or identifying the next measured decline.
- **Progress (2026-09-09, measured-memory-CMOV performance follow-up):** A release-build six-run A/B on the unchanged pinned PVH fixture retired exactly 100 million instructions per run. The tier-one-disabled median was 60.687 seconds (1.648 MIPS); the tier-one-enabled median was 8.464 seconds (11.815 MIPS), an 86.05% elapsed reduction and 7.170x throughput. All three enabled runs produced identical architectural state, execution statistics, and JIT counters: 99,916,355 native instructions, 83,645 interpreter instructions, 2,347 admissions from 4,624 attempts, and 39,944,352 lazy-flag materializations. Interpreter-differential MAP_JIT regressions separately execute both the exact 15-byte high-canonical memory-CMOV fragment and all nine instructions of the 52-byte `delay_tsc` body across both conditional paths; the full DBT/PC gate passes with 1,427 tests in 171 suites. Every timed run still stopped before console output or userspace, so this is bounded engineering evidence rather than G1-G3 or release qualification. The next measured declines are `iretq` at `text_poke_early+89` and two native-emitter blocks in `vsnprintf`. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-memory-cmov-ab.json)
- **Progress (2026-09-09, full-budget diagnostic follow-up):** A release-build tier-one PVH probe extended the identical pinned fixture to one billion retired instructions and 600 wall seconds. It exhausted the instruction budget after 417.763 seconds (2.394 MIPS) with zero console bytes; the terminal RIP was `delay_tsc+69`, and no maskable or non-maskable interrupt was delivered. It therefore neither qualifies userspace nor demonstrates workload completion. The stable 7,164-attempt/2,926-tier-one-block admission totals agree with the shorter trials and do not indicate a tier-one compiler divergence, but the no-console delay loop is an unresolved boot-path blocker. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-full-budget-probe.json)
- **Progress (2026-09-09, mixed-tier flags recovery):** The post-memory-CMOV no-console regression was a compiler-ABI transition bug, not a delay-loop semantic error: a tier-one producer could carry its private lazy-flags descriptor directly into legacy code that reads only the materialized RFLAGS word. The chained executor now materializes before any tier-one-to-baseline/optimizing transition, counts that event before restartable checkpoints, and admits only compilation-tier-homogeneous native traces. An interpreter differential makes tier-one ADD feed carry into a legacy memory ADC and proves exact state plus one materialization. The full DBT/PC gate passes with 1,428 tests in 171 suites. A fresh release run then crossed TSC calibration, reached authenticated userspace, passed all seven requested workloads, and powered off through ACPI after 737,988,972 instructions in 146.320 seconds; the matched tier-one-disabled control took 197.561 seconds, so this single-pair recovery comparison is 1.350x directional evidence, not a statistical benchmark. A05.2 remains open because 146,777 of 241,414 tier-one compilation attempts still declined and therefore require the legacy baseline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-mixed-tier-flags-recovery.json)
- **Progress (2026-09-09, measured memory-ALU follow-up):** Tier-one now admits byte/word/dword/qword register-destination ADD/ADC/SUB/SBB/CMP/AND/TEST/OR/XOR with scalar memory sources, plus the measured GS-relative word memory TEST-immediate family. Reads complete through the restartable callback before destination or replacement lazy-flags publication, and the resulting native flag token can feed an adjacent condition. Interpreter differentials cover all widths and operations, both measured blocks, branch outcomes, and failed-read rollback. A broad memory-destination experiment was rejected after a full run exposed an NX init-text panic; production admission now explicitly declines qword memory CMP/TEST and byte memory TEST forms. With that boundary, the full DBT/PC gate passes with 1,432 tests in 171 suites, and a release run reached authenticated userspace, passed all seven workloads, and powered off after 737,898,802 instructions in 134.194 seconds. Versus the preceding known-good run, tier-one declines fell by 14,199 (9.67%), interpreter instructions by 206,003, and elapsed time by 8.29% directionally; this single-run comparison is not statistical. A05.2 remains open because 132,578 of 231,022 attempts still require the legacy baseline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-measured-memory-alu.json)
- **Progress (2026-09-09, measured memory-PUSH follow-up):** Tier-one now admits long-mode qword PUSH from memory through a restartable scalar read followed by the transactional stack write. The source is staged from the old register image before RSP changes, so ordinary, RSP-relative, and destination-aliasing forms match the interpreter; either callback can fail without publishing temporary state or memory. Exact tests cover the three `swapgs_restore_regs_and_return_to_usermode` sites at `0xffffffff8100176d`, `0xffffffff81001770`, and `0xffffffff81001773`, whose combined 11,129 visible negative-cache hits disappear. The full DBT/PC gate passes with 1,435 tests in 171 suites, and a release run reached authenticated userspace, passed all seven workloads, and powered off after 734,484,716 instructions. Because that unmatched full run was 9.94% slower than the preceding single run, a balanced parent/candidate six-run comparison retired exactly 200 million instructions per trial: the parent median was 38.000 seconds and the candidate median 37.696 seconds, a small directional 0.80% elapsed reduction rather than a statistical claim. A05.2 remains open because 130,204 of 229,174 full-run attempts still declined. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-memory-push.json)
- **Progress (2026-09-09, bounded memory-MUL/store follow-up):** Tier-one now admits the measured 12-byte `mulq 0x8(%rsp)` → `movq %r11,0xc8(%rsi)` block at `__update_load_avg_se+0x11e` through one restartable read and one transactional write. The MUL source is staged before RDX:RAX publication, including address aliases, and a fault at either callback rolls the whole block back. A first correctness-passing full run exposed that generic qword-store admission changed 21,238 more dynamic block publications than the final bounded build, so production now permits the store only as the immediate successor of qword memory MUL; standalone, narrow, and atomic stores still decline. The focused gate passes 210 tests in 3 suites, the full DBT/PC gate passes 1,438 tests in 171 suites, and the bounded release run reached authenticated userspace, passed all seven workloads, and powered off after 734,496,554 instructions in 139.661 seconds. The prior 9,027-hit measured site disappears from the visible negative cache, while the next locked XOR site remains bounded. The 5.33% elapsed reduction versus the preceding unmatched full run is directional only, not a statistical claim. A05.2 remains open because 125,548 of 224,433 full-run attempts still declined. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-bounded-memory-mul-store.json)
- **Progress (2026-09-09, bounded byte-XOR follow-up):** Tier-one now executes the measured `lock xorb $1,0(%rbp)` at `filemap_map_pages+0x1f9` through the shared atomic compare-exchange gate and its Linux uniprocessor-patched `ds xorb $1,0(%rbp)` image through one replay-safe byte read plus a final transactional write. The pinned kernel's `.smp_locks` entry resolves exactly to `0xffffffff8153a159`, and its alternatives code writes `0x3e` over the registered `0xf0` prefix, explaining why locked-form admission alone left a 2,237-hit five-byte decline. A decoded-operation-wide companion experiment was rejected after reproducing the prior NX init-text panic and guest reset at 631,779,500 instructions. Production therefore admits the patched form only as the exact five-byte, one-instruction, one-statement block at the measured fixture RIP; the same operation elsewhere still declines. Differential tests cover both encodings across byte/flag boundaries, failed read/write rollback, exact negative admission, and 195 mixed interpreter/tier-one atomic toggles. The focused gate passes 43 tests, the full DBT/PC gate passes 1,441 tests in 171 suites, and the bounded release run reached authenticated userspace, passed all seven workloads, and powered off after 735,741,653 instructions in 150.234 seconds. The measured site disappears from the visible negative cache; the next native-emitter decline is `sete 0x23(%rsp)` at `__free_one_page+0x95` with 2,388 hits. A05.2 remains open because 125,948 of 224,625 full-run attempts still declined. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-bounded-byte-xor.json)
- **Progress (2026-09-09, rejected memory-SETcc follow-up):** An exact-site tier-one candidate for the measured `sete 0x23(%rsp)` at `__free_one_page+0x95` passed 44 focused tests, the 1,442-test DBT/PC gate, failed-write rollback, adjacent-RIP rejection, and an added chained pending-flags differential. Its pinned production run nevertheless reproduced the same NX init-text instruction fetch at `0xffffffff830c96ac` seen in earlier rejected memory-writing admissions, resetting after 629,367,042 instructions before any authenticated workload receipt. The candidate was reverted rather than generalized or accepted, and the post-withdrawal DBT/PC gate passes 1,441 tests in 171 suites. This result does not establish that memory SETcc is generally incorrect; it establishes that the measured production admission remains unsafe or unexplained, so the site is deferred and still requires the legacy baseline. [Rejected evidence](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-rejected-memory-sete.json)
- **Progress (2026-09-09, rejected CR3-read follow-up):** A read-only candidate lowered the two measured kernel `mov %cr3` sites through an explicit IR operation backed by an immutable dispatch-entry CR3 snapshot. It passed 44 focused tests, the 1,442-test DBT/PC gate, both native tiers, privilege and control-register exclusions, optimizer invalidation, and a compare→CR3 read→Jcc flags differential. The pinned production run nevertheless reset after 630,266,878 instructions at the exact same NX init-text address and free-init timer-interrupt path as the rejected memory-SETcc candidate. Because this admission added no guest-memory write, the repeated signature shifts the next investigation toward admission, tier-transition, or interrupt-state interaction without establishing a cause. The candidate was reverted, the post-withdrawal gate passes 1,441 tests in 171 suites, and the sites remain on the legacy path. [Rejected evidence](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-rejected-cr3-reads.json)
- **Progress (2026-09-09, CR3-read recovery follow-up):** The repeated NX failure was isolated to the A04.3 byte-revalidation coherency hole, not CR3 semantics: unchanged resident and shared-code reuse could leave a sibling-unprotected host granule writable while a stale inline write-TLB entry remained live. The executor now re-protects validated guest bytes and flushes that TLB state before publication. With the exact original CR3 lowering restored unchanged, 44 focused tests and the 1,444-test DBT/PC gate pass; a fresh release run crosses the former 630-million-instruction failure boundary, reaches authenticated userspace, passes all seven requested workloads, and powers off after 733,843,413 instructions in 146.186 seconds. The two measured CR3 sites are admitted again, while all other control-register reads and user-mode cases remain deferred. A05.2 remains open because 126,783 of 225,663 full-run tier-one attempts still declined. [Recovery receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-cr3-smc-reprotection-recovery.json)
- **Progress (2026-09-09, memory-SETcc recovery follow-up):** The exact `sete 0x23(%rsp)` admission was restored after the shared reprotection repair because its earlier NX reset had the same now-isolated coherency signature. With CR3 lowering and the reprotection regressions also enabled, 45 focused tests and the 1,445-test DBT/PC gate pass. A fresh release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,939,989 instructions in 145.370 seconds; the measured SETE site is absent from the retained negative-cache sample. Its exact-site boundary remains in force, and other memory SETcc forms still decline. The next visible kernel helper site is `rep movsq` at `sync_regs+0x22` with 12,188 hits. A05.2 remains open because 125,223 of 224,168 full-run tier-one attempts still declined. [Recovery receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-memory-sete-recovery.json)
- **Progress (2026-09-09, native SWAPGS follow-up):** Long-mode CPL0 `SWAPGS` now lowers through an explicit flag-neutral IR statement in both native tiers. The append-only 53-word execution context carries IA32_KERNEL_GS_BASE plus a performed marker, so dispatcher publication updates both GS MSRs after a real exchange without normalizing an untouched architectural snapshot. Interpreter differentials cover the two measured kernel sites, inconsistent initial GS images, user-mode atomic decline, and a CMP→SWAPGS→JNE path that preserves the native condition token. All 61 focused tests and the 1,446-test DBT/PC gate pass. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 734,270,253 instructions in 143.046 seconds; the two prior SWAPGS sites with 20,446 combined visible hits are absent from the retained negative cache. The next visible kernel declines are register-indexed memory `btq` (28,301 hits) and two `rep movsq` sites (13,637 and 11,653 hits). A05.2 remains open because 125,890 of 224,847 full-run tier-one attempts still declined. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-native-swapgs.json)
- **Progress (2026-09-09, measured memory-BT follow-up):** Tier-one now admits the measured `btq %rdx,0x228(%r15)` → `jb` kernel block through one restartable qword read. Signed register indexes select qwords on either side of the ModRM address with exact floor-division behavior; only CF publishes after a successful read, and failure leaves the entry checkpoint intact. Interpreter differentials cover indices 0, 63, 64, -1, and -65, both branch outcomes, failed-read rollback, and same-operation exclusion at another RIP. The 217-test focused gate and 1,447-test DBT/PC gate pass. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 732,321,746 instructions in 153.713 seconds; the prior 28,301-hit site is absent from the retained negative cache. The unmatched wall-time increase is recorded as noise, not a performance claim. The next visible kernel sites are a runtime-patched one-byte helper boundary (30,426 hits; live bytes still to capture), memory `btrq` (17,036), and `rep movsq` (11,825). A05.2 remains open because 128,462 of 227,352 full-run attempts still declined. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-measured-memory-bit-test.json)
- **Progress (2026-09-09, measured memory-BTR follow-up):** Tier-one now admits the measured `btrq %rcx,(%rax)` kernel block through the signed bit-string address path, one replay-safe qword read, and one final transactional write. The selected bit is cleared without disturbing its neighbors, CF reflects the old bit only after commit, and a write fault rolls state and memory back to the block-entry checkpoint. Interpreter differentials cover indices 0, 63, 64, -1, and -65, both source-bit states, and adjacent-RIP exclusion. The 218-test focused gate and 1,448-test DBT/PC gate pass. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,953,186 instructions in 146.514 seconds; the prior 17,036-hit BTR site is absent from the retained negative cache. The next visible kernel sites are two CR3 writes (12,113 and 9,606 hits) and `rep movsq` (11,064). A05.2 remains open because 128,014 of 226,761 full-run attempts still declined. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-measured-memory-bit-reset.json)
- **Progress (2026-09-09, measured CR3-write follow-up):** Tier-one now admits the two measured three-byte kernel CR3 writes, `movq %rax,%cr3` and `movq %rdi,%cr3`, as isolated dispatch boundaries. Every candidate value is revalidated before native entry; reserved high bits, PCID no-flush requests, user mode, non-long mode, and adjacent RIPs decline without effects. Successful publication updates architectural CR3, invalidates the translated-memory paging unit and executor JIT TLB, and returns before another guest instruction can run under the new root. Both encodings match the interpreter, a chained regression proves the mandatory boundary, the 54-word ABI-layout check passes, and the 1,449-test DBT/PC gate is green. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,805,095 instructions in 142.130 seconds; the prior sites with 21,719 combined visible hits are absent from the retained negative cache. The next visible kernel sites are `inb` (13,097 hits), `iretq` (12,244), memory `setne` (11,327), and `rep movsq` (10,315). A05.2 remains open because 126,310 of 224,212 full-run tier-one attempts still declined. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-measured-cr3-writes.json)
- **Progress (2026-09-09, measured memory-SETNE follow-up):** Tier-one now admits the exact three-byte `setne (%rbx)` at `0xffffffff812df36a` through the already-qualified transactional memory-SETcc emitter. The measured RIP and decoded condition/width form one bounded admission rule; identical bytes at an adjacent RIP still decline. Interpreter differentials cover both zero-flag outcomes and exact destination memory, while the shared emitter retains its failed-write rollback regression. The full DBT/PC gate passes 1,450 tests in 171 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,948,756 instructions in 143.850 seconds; the prior 11,327-hit SETNE site is absent from the retained negative-cache sample. The unmatched 1.21% elapsed increase is recorded as run noise, not a performance claim. The next native-emitter kernel decline is the neighboring `sete 0x22(%rsp)` at `0xffffffff815cab87` with 1,881 hits. A05.2 remains open because 127,035 of 225,774 full-run tier-one attempts still declined. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-measured-memory-setne.json)
- **Progress (2026-09-09, second measured memory-SETE follow-up):** Tier-one now admits the neighboring exact `sete 0x22(%rsp)` at `0xffffffff815cab87` through the same transactional memory-SETcc emitter, while identical bytes at an adjacent RIP remain interpreter-owned. Interpreter differentials cover both zero-flag outcomes with exact state and memory parity, and the shared failed-write regression preserves atomic rollback coverage. The full DBT/PC gate passes 1,451 tests in 171 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 732,428,289 instructions in 144.815 seconds; the prior 1,881-hit site is absent from the retained negative-cache sample and interpreter fallback retires 21,996 fewer instructions than the preceding unmatched run. The 0.67% elapsed increase is recorded as run noise, not a performance claim. The next exact memory-SETcc candidate is `sete 0x22(%rsp)` at `0xffffffff81388b5d` with 1,250 hits; higher-volume memory-BT and helper boundaries remain separately bounded. A05.2 remains open because 127,250 of 225,873 full-run tier-one attempts still declined. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-second-measured-memory-sete.json)
- **Progress (2026-09-09, printk memory-SETE follow-up):** Tier-one now admits the exact `sete 0x22(%rsp)` at `_prb_read_valid+0x2d` (`0xffffffff81388b5d`) through the transactional memory-SETcc emitter; its immediately following SETE and identical encodings elsewhere remain interpreter-owned. The consolidated additional-site differential matrix covers both zero-flag outcomes, exact state/memory parity, and adjacent-RIP exclusion, while the shared failed-write regression retains atomic rollback coverage. The full DBT/PC gate passes 1,451 tests in 171 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 734,167,784 instructions in 142.007 seconds; the prior 1,250-hit site is absent from the retained negative-cache sample, Tier-1 declines fall by 1,247, and interpreter fallback retires 9,648 fewer instructions than the preceding unmatched run. The 1.94% directional elapsed reduction is not a statistical performance claim. The new top native-emitter address is deferred because its offline bytes are not aligned with the live five-byte block; the next fully decoded bounded candidate is `btrq %r14,(%rax)` at `0xffffffff81681078`. A05.2 remains open because 126,003 of 224,235 full-run tier-one attempts still declined. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-printk-memory-sete.json)
- **Progress (2026-09-09, measured R14 memory-BTR follow-up):** Tier-one now admits the exact `btrq %r14,(%rax)` at `0xffffffff81681078` through the signed bit-string path, one replay-safe qword read, and one final transactional write. The matcher requires the measured RIP, four-byte one-instruction block, RAX base, qword width, and R14 index; the older RCX-site matcher is also hardened to its exact block and address shape. Interpreter differentials cover signed indexes 0, 64, and -1 and both selected-bit states, while the older matrix retains wider boundary and failed-write rollback coverage. The full DBT/PC gate passes 1,452 tests in 171 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 734,029,357 instructions in 143.326 seconds; the prior 1,661-hit site is absent from the retained negative-cache sample and interpreter fallback retires 6,824 fewer instructions than the preceding unmatched run. Aggregate attempts differ, so the +0.93% wall and decline movements are noise, not performance claims. The next decoded native sites are byte memory SHR (5,042 hits), memory BT→JAE (4,517), and word memory OR (2,124). A05.2 remains open because 127,757 of 226,462 full-run tier-one attempts still declined. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-r14-memory-btr.json)
- **Progress (2026-09-09, measured RCX memory-BT follow-up):** Tier-one now admits the exact six-byte `btq %rcx,(%rax)` → `jae` block at `0xffffffff81e1b3a0` through the signed bit-string read path. The matcher requires the measured RIP, two-instruction block, RAX base, qword width, and RCX index; the older RDX/R15 BT matcher is also hardened to its exact block and address shape. Interpreter differentials cover signed indexes 0, 64, and -1, both selected-bit states, exact CF/JAE targets, memory parity, and adjacent-RIP exclusion, while the older matrix retains wider boundary and failed-read rollback coverage. The full DBT/PC gate passes 1,453 tests in 171 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 734,085,846 instructions in 145.316 seconds; the prior 4,517-hit site is absent from the retained negative-cache sample, with 1,976 fewer declines and 16,714 fewer interpreter instructions than the preceding unmatched run. That run also had 2,611 fewer attempts, and its +1.39% wall movement is noise rather than a performance claim. The next dominant decoded native frontier is a high-byte register transform followed by a memory load at `__radix_tree_replace+0x9e` (18,919 hits). A05.2 remains open because 125,781 of 223,851 full-run tier-one attempts still declined. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-rcx-memory-bt.json)
- **Progress (2026-09-09, high-byte-copy and memory-extend follow-up):** Tier-one now implements flag-neutral MOV into AH/CH/DH/BH from low-byte registers, legacy high-byte registers, and immediates, staging the source before destination mutation so aliases are exact. Memory-source MOVSX/MOVZX now composes one restartable scalar read with the existing register extension lowering; a fault rolls any earlier statement in the block back to its entry checkpoint. Differential tests cover low/high/immediate high-byte sources, surrounding-bit and RFLAGS preservation, the measured `movb %cl,%bh` → `movzwl 0x2(%rsi),%ecx` block at `__radix_tree_replace+0x9e`, and failed-read rollback. The full DBT/PC gate passes 1,455 tests in 171 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,282,139 instructions in 153.438 seconds; the prior 18,919-hit block is absent, Tier-1 declines fall by 3,995, compiled Tier-1 blocks rise by 3,823, interpreter instructions fall by 57,155, and lazy materializations fall by 4,800,230 on nearly equal attempt totals. The +5.59% wall movement is run noise, not a performance claim. The next decoded native site is `setne (%rbx)` at `0xffffffff812df23d` with 11,524 hits. A05.2 remains open because 121,786 of 223,679 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-high-byte-memory-extend.json)
- **Progress (2026-09-09, second measured memory-SETNE follow-up):** Tier-one now admits the second exact three-byte `setne (%rbx)` at `0xffffffff812df23d` through the production-qualified transactional memory-SETcc emitter; the same bytes at an adjacent RIP still decline. Interpreter differentials cover both zero-flag outcomes with exact state and memory parity, and the shared failed-write regression retains atomic rollback coverage. The full DBT/PC gate passes 1,456 tests in 171 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,341,636 instructions in 147.624 seconds; the prior 11,524-hit site is absent from the retained negative-cache sample. The unmatched run has 1,551 fewer declines and 3,552 fewer interpreter instructions, but also 1,846 fewer attempts and 295 fewer compiled blocks, so its 3.79% directional elapsed reduction and aggregate movements are run noise rather than a performance claim. The highest-volume remaining helper is `rep movsq` at `0xffffffff813cd9a6` with 15,952 visible hits across address spaces; the next native-emitter block is `movslq %ecx,%rax` → `lock btsq %rax,(%rsi)` at `__resched_curr+0x11f` with 1,653 hits. A05.2 remains open because 120,235 of 221,833 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-second-memory-setne.json)
- **Progress (2026-09-09, measured atomic memory-BTS follow-up):** Tier-one now admits the exact `movslq %ecx,%rax` → `lock btsq %rax,(%rsi)` block at `__resched_curr+0x11f`. Signed bit-string indexing selects the surrounding qword before a compare-exchange loop performs the locked update; a comparison mismatch retries from its returned old value without a non-atomic read, and only the successful replaced value publishes CF. Interpreter differentials cover indices 0, 63, 64, -1, and -65, both old-bit states, and callback-fault rollback of the preceding MOVSXD; adjacent-RIP rejection and an eight-worker exactly-one-clear-CF atomicity test retain the bounded concurrency contract. The full DBT/PC gate passes 1,457 tests in 171 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,612,255 instructions in 149.195 seconds; the prior 1,653-hit block is absent and interpreter fallback retires 10,104 fewer instructions on nearly equal attempt totals. The +1.06% wall movement is unmatched-run noise, not a performance claim. The newly exposed dominant native block is `btq %rdi,0x228(%rsi)` → `jae` at `__radix_tree_replace+0x3c` with 17,268 hits; the top helper is `leave` at `btf_verifier_log_member+0x6e` with 103,976 hits. A05.2 remains open because 120,197 of 221,529 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-atomic-memory-bts.json)
- **Progress (2026-09-09, measured RDI/RSI memory-BT follow-up):** Tier-one now admits the exact 14-byte `btq %rdi,0x228(%rsi)` → near-`jae` block at `__radix_tree_replace+0x3c` through the production-qualified signed bit-string read path. Interpreter differentials cover indices 0, 63, 64, -1, and -65, both old-bit states, exact CF and branch destinations, unchanged memory, failed-read rollback, and adjacent-RIP exclusion. The full DBT/PC gate passes 1,458 tests in 171 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 732,350,904 instructions in 147.401 seconds; the prior 17,268-hit block is absent from the retained sample. The run has 1,666 more attempts, 953 more declines, 713 more compiled blocks, and 28,710 more interpreter instructions than its unmatched predecessor, so the 1.20% directional elapsed reduction and aggregate movements are noise rather than a performance claim. The same locked BTS operation is now exposed at its second-instruction entry boundary (`0xffffffff8133cb12`, 7,302 hits); the next unrelated native block is a dword rotate followed by a stack store at `blake2s_compress_generic+0x705` with 3,532 hits. A05.2 remains open because 121,150 of 223,195 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-rdi-rsi-memory-bt.json)
- **Progress (2026-09-09, standalone atomic memory-BTS follow-up):** Tier-one now admits the exact five-byte `lock btsq %rax,(%rsi)` block at the measured second-instruction boundary in `__resched_curr`, reusing the signed bit-string compare-exchange loop rather than broadening atomic admission. Standalone interpreter differentials cover signed indices 0, 64, and -1 with both old-bit states, full state and memory parity, exact CF, and adjacent-RIP exclusion; the shared emitter retains its broader signed-index, callback-fault rollback, and eight-worker atomicity matrix. The full DBT/PC gate passes 1,459 tests in 171 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,507,034 instructions in 150.515 seconds; the prior 7,302-hit standalone block is absent from the retained sample. Unmatched aggregate movements, including a 2.11% elapsed increase, are run noise rather than a performance claim. The next dominant native-emitter miss is `sete 0xb(%rsp)` at `btf_struct_check_meta+0x80` with 18,547 hits. A05.2 remains open because 121,705 of 223,515 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-standalone-atomic-bts.json)
- **Progress (2026-09-09, measured BTF stack-SETE follow-up):** Tier-one now admits the exact `sete 0xb(%rsp)` block at `btf_struct_check_meta+0x80` through the production-qualified transactional memory-SETcc emitter. The matcher also hardens every earlier measured memory-SETcc site to require its exact base register and displacement; an adjacent RIP and a mutated displacement at the measured RIP decline. Both zero-flag outcomes match the interpreter for full state and memory, while shared rejected-write coverage retains block-entry rollback. The full DBT/PC gate passes 1,459 tests in 171 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 734,402,052 instructions in 148.367 seconds; the prior 18,547-hit block is absent and no native-emitter decline remains in the capped hot-site list. The 1.43% unmatched elapsed reduction and aggregate movements are noise rather than a performance claim. The visible kernel frontier is now `rep movsq` with 15,290 hits across two address spaces and `rep stosq` with 9,075 hits. A05.2 remains open because 120,729 of 222,890 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-btf-stack-sete.json)
- **Progress (2026-09-09, long-mode LEAVE follow-up):** Qword `LEAVE` now lowers generally in long mode as `RSP ← RBP` followed by the existing transactional qword stack-pop path; the 16-bit operand-size-overridden form remains with the interpreter. Interpreter parity covers a nontrivial old stack pointer, frame address, caller frame value, flags, and memory, while an unmapped frame proves full block-entry rollback. The full DBT/PC gate passes 1,460 tests in 171 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,312,998 instructions in 150.316 seconds; the previously measured 103,976-hit kernel `leave` at `btf_verifier_log_member+0x6e` is absent. Against the unmatched prior run, interpreter retirement falls by 118,590, attempts by 1,068, and declines by 1,113, while the decline share moves from 54.17% to 53.92%; the 1.31% elapsed increase remains noise rather than a speed claim. The leading retained misses are an unidentified one-byte ASLR-dependent user site, an alternatives-patched one-byte kernel site whose live bytes are not captured, `rep movsq`, and `iretq`. A05.2 remains open because 119,616 of 221,822 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-long-mode-leave.json)
- **Progress (2026-09-09, live negative-site byte telemetry):** The bounded PVH diagnostic now projects the decoder-confirmed instruction bytes already retained by each live negative-cache entry. This makes ASLR-dependent userspace sites and alternatives-patched kernel sites actionable without guessing from static addresses, while the observation scope remains explicit: the capped sites describe live entries at the last completed sample, not cumulative reason totals. The DBT/PC/runner gate passes 1,492 tests in 175 suites, and the encoded diagnostic remains below its size bound. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,544,936 instructions in 139.051 seconds. The leading previously unidentified site is now conclusively `0x92` (`xchg eax,edx`) with 122,159 hits; the next userspace helper is `movups [rdi-0x10],xmm0` with 53,691 hits, and the leading native-emitter kernel site is `setne (%rcx)` with 11,523 hits. This diagnostics-only slice makes no performance claim. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-live-negative-site-bytes.json)
- **Progress (2026-09-09, dword register-XCHG follow-up):** Equal-width dword register `XCHG` now lowers through both native tiers, staging both inputs before publication and zero-extending both architectural destinations without changing flags; qword behavior is retained and the 16-bit form stays interpreter-owned. The measured `0x92` (`xchg eax,edx`) differential starts with nonzero upper halves and matches the interpreter through both JITs. The full DBT/PC/runner gate passes 1,492 tests in 175 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,811,367 instructions in 139.351 seconds; no live negative-cache entry retains byte sequence `[0x92]`, eliminating the prior ASLR-dependent 122,159-hit site from the capped sample. Against the unmatched telemetry run, interpreter retirement falls by 75,187 and declines by 1,631, while the 0.22% wall increase is noise rather than a performance claim. The newly visible leading helper is `invlpg (%rdi)` at `native_flush_tlb_one_user+0x1f` with 130,863 hits, and the leading native-emitter site is `setne (%rbx)` at `lookup_address_in_pgd_attr+0x15f` with 11,623 hits. A05.2 remains open because 117,391 of 219,293 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-dword-register-xchg.json)
- **Progress (2026-09-09, third measured memory-SETNE follow-up):** Tier-one now admits the exact `setne (%rbx)` at `lookup_address_in_pgd_attr+0x15f` (`0xffffffff812df2df`) through the production-qualified transactional memory-SETcc path. The matcher requires the measured RIP, three-byte single-instruction block, SETNE condition, byte width, and RBX base; identical bytes at an adjacent RIP decline. The consolidated additional-site differential covers both zero-flag outcomes with exact state and memory parity, and the shared failed-write regression retains rollback coverage. The full DBT/PC/runner gate passes 1,492 tests in 175 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,600,078 instructions in 147.528 seconds; the prior 11,623-hit exact RIP/byte pair is absent from the capped live sample. Interpreter fallback retires 45,296 fewer instructions than the unmatched predecessor, but that run has 850 more attempts and its 5.87% wall increase is noise rather than a performance claim. The leading native-emitter block is now a word memory subtraction at `__slab_free+0x69` with 3,687 hits. A05.2 remains open because 118,082 of 220,143 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-third-memory-setne.json)
- **Progress (2026-09-09, measured slab-free word-SUB/store follow-up):** Tier-one now admits the exact 11-byte `subw 0x14(%rsp),%r12w` → `movq %rcx,0x58(%rsp)` block at `__slab_free+0x69`. One restartable read feeds the existing word subtraction lowering; its flags remain lazy until the qword store materializes them and performs the final transactional write. The matcher requires the complete two-instruction block, registers, widths, displacements, and measured RIP. Interpreter parity covers a nontrivial R12 upper value, complete flags, the RCX store, and full memory, while a rejected final write proves block-entry state/memory rollback. The full DBT/PC/runner gate passes 1,493 tests in 175 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 734,049,723 instructions in 149.052 seconds; the prior 3,687-hit site is absent. Unmatched aggregate movement and the 1.03% wall increase are noise rather than a performance claim. The leading native-emitter boundary is now `btq %rax,(%rdi)` → `jb` at `dup_fd+0x2c6` with 7,648 hits; a live DS-prefixed standalone BTS and stack SETE are next. A05.2 remains open because 116,572 of 217,968 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-slab-free-word-sub-store.json)
- **Progress (2026-09-09, measured RAX/RDI memory-BT follow-up):** Tier-one now admits the exact six-byte `btq %rax,(%rdi)` → `jb` block at `dup_fd+0x2c6` through the production-qualified signed bit-string read path. The matcher requires the measured RIP, complete two-instruction block, RDI base, qword width, RAX index, and carry branch. Interpreter parity covers signed indices 0, 64, and -1, both bit states, exact CF/JB targets, complete state, unchanged memory, and failed-read rollback; identical bytes at an adjacent RIP decline. The full DBT/PC/runner gate passes 1,494 tests in 175 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,778,626 instructions in 154.752 seconds; the prior 7,648-hit exact site is absent and interpreter fallback retires 29,419 fewer instructions than the unmatched predecessor. Attempts differ by 1,974, so the 3.82% wall increase and aggregate movement are noise rather than a performance claim. The leading native-emitter boundary is now the live DS-prefixed `btrq %rdx,0x5c0(%rax)` at `unuse_temporary_mm+0x3a` with 13,268 hits. A05.2 remains open because 117,784 of 219,942 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-rax-rdi-memory-bt.json)
- **Progress (2026-09-09, alternatives-patched memory-BTR follow-up):** Tier-one now admits the exact live DS-prefixed `btrq %rdx,0x5c0(%rax)` at `unuse_temporary_mm+0x3a`. The single-vCPU alternatives patch replaces the static LOCK prefix with DS, which long mode ignores for this address; admission remains restricted to the measured nine-byte non-locking form. Signed bit-string lowering performs one restartable qword read, one final transactional write, and CF-only publication. Interpreter parity covers signed indices 0, 64, and -1, both old-bit states, complete state/memory, failed-write rollback, adjacent-RIP rejection, and displacement mutation. The full DBT/PC/runner gate passes 1,495 tests in 175 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 734,168,762 instructions in 153.000 seconds; the prior 13,268-hit exact live site is absent. The unmatched 1.13% wall reduction and aggregate changes are noise rather than a performance claim. The leading native-emitter site is now `shrb 0x19(%rsi)` at `free_frozen_page_commit+0x2b` with 5,039 hits. A05.2 remains open because 116,540 of 218,684 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-patched-memory-btr.json)
- **Progress (2026-09-09, measured byte memory-SHR follow-up):** Tier-one now admits the exact three-byte `shrb 0x19(%rsi)` at `free_frozen_page_commit+0x2b`. One replay-safe byte read feeds a SHR-by-one result into a final transactional byte write; the replacement lazy-flags descriptor is published only after that write succeeds, so failure leaves complete block-entry state and memory restartable. The matcher requires the measured RIP, byte count, one-instruction block, logical-right operation, byte width, count one, RSI base, displacement, and address width. Interpreter parity covers inputs `0x00`, `0x01`, `0x80`, and `0xff`, complete flags/state/memory, rejected-write rollback, adjacent-RIP rejection, and displacement mutation. The full DBT/PC/runner gate passes 1,496 tests in 175 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,386,471 instructions in 142.971 seconds; the prior 5,039-hit exact site is absent. Attempts differ by 2,069, so the 6.55% wall reduction and aggregate movements are unmatched-run noise rather than a performance claim. The leading native-emitter site is now `orw $0x10,0x3c(%rbx)` at `kernfs_activate_one+0x12` with 13,241 hits. A05.2 remains open because 115,383 of 216,615 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-byte-memory-shift.json)
- **Progress (2026-09-09, measured word memory-OR follow-up):** Tier-one now admits the exact five-byte `orw $0x10,0x3c(%rbx)` at `kernfs_activate_one+0x12`. One replay-safe word read feeds a final transactional word write, and the replacement logical-flags descriptor is published only after the callback succeeds. The matcher requires the measured RIP, byte count, one-instruction block, operation, widths, immediate, RBX base, displacement, and address width. Interpreter parity covers four word/flag boundaries with complete state and memory; rejected-write rollback, adjacent-RIP rejection, displacement mutation, and immediate mutation retain the bounded contract. The full DBT/PC/runner gate passes 1,497 tests in 175 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 734,176,186 instructions in 141.778 seconds; the prior 13,241-hit exact site is absent. Attempts differ by 805 and declines increase by 1,155, so the 0.83% wall reduction and aggregate movements are unmatched-run noise rather than a performance claim. The leading native-emitter site is now `setne (%rcx)` at `lookup_address_in_pgd_attr+0x66` with 11,649 hits. A05.2 remains open because 116,538 of 217,420 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-word-memory-or.json)
- **Progress (2026-09-09, fourth measured memory-SETNE follow-up):** Tier-one now admits the exact `setne (%rcx)` at `lookup_address_in_pgd_attr+0x66` through the production-qualified transactional memory-SETcc emitter. The consolidated SETNE matrix now selects each measured RIP's exact RBX or RCX address form, rejects an adjacent RIP and the wrong base, and matches both zero-flag outcomes for complete state and memory; shared SETcc coverage retains rejected-write rollback. The full DBT/PC/runner gate passes 1,497 tests in 175 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 734,252,699 instructions in 135.830 seconds; the prior 11,649-hit exact site is absent. Attempts differ by 1,479 and declines rise by 370, so the 4.20% wall reduction and aggregate movements are unmatched-run noise rather than a performance claim. The leading native-emitter block is now `btq %rbx,0x228(%rax)` → `jae` at `__radix_tree_delete+0xb4` with 3,124 hits. A05.2 remains open because 116,908 of 218,899 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-rcx-memory-setne.json)
- **Progress (2026-09-09, measured RBX/RAX memory-BT follow-up):** Tier-one now admits the exact ten-byte `btq %rbx,0x228(%rax)` → backward-`jae` block at `__radix_tree_delete+0xb4` through the production-qualified signed bit-string read path. Admission verifies the memory operand, index, condition, and both branch targets. Interpreter parity covers signed indexes 0, 64, and -1, both selected-bit states, exact CF and branch destinations, complete state, unchanged memory, and failed-read rollback; an adjacent RIP and changed branch condition decline. The full DBT/PC/runner gate passes 1,498 tests in 175 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,786,075 instructions in 148.071 seconds; the prior 3,124-hit exact block is absent. Attempts differ by 1,319, so the 9.01% wall increase and aggregate movements are unmatched-run noise rather than a performance claim. The leading native-emitter site is now `sete 0x2f(%rsp)` at `__slab_free+0x8a` with 8,252 hits. A05.2 remains open because 115,699 of 217,580 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-09/pvh-rbx-rax-memory-bt.json)
- **Progress (2026-09-10, slab-free memory-SETE follow-up):** Tier-one now admits the exact five-byte `sete 0x2f(%rsp)` at `__slab_free+0x8a` through the production-qualified transactional memory-SETcc emitter. The consolidated SETE matrix covers both zero-flag outcomes, exact state and memory, adjacent-RIP exclusion, and the measured RSP+0x2f address; shared coverage retains rejected-write rollback. The full DBT/PC/runner gate passes 1,498 tests in 175 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 734,119,813 instructions in 143.772 seconds; the prior 8,252-hit exact site is absent and interpreter fallback retires 24,356 fewer instructions than the unmatched predecessor. Attempts differ by 134, so the 2.90% wall reduction and aggregate movements are unmatched-run noise rather than a performance claim. The leading native-emitter block is now `movslq %ecx,%rax` → `lock btsq %rax,(%rsi)` at `__resched_curr+0x11f` with 6,614 hits. A05.2 remains open because 115,927 of 217,714 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-10/pvh-slab-free-memory-sete.json)
- **Progress (2026-09-10, alternatives-patched memory-BTS follow-up):** The prior static LOCK admission did not cover the live single-vCPU image at `__resched_curr+0x11f`: Linux alternatives replaces `0xf0` with the long-mode-ignored DS prefix `0x3e`, so the decoder correctly exposes an ordinary memory BTS. Tier-one now separately admits that exact eight-byte `movslq %ecx,%rax` → `ds btsq %rax,(%rsi)` block through the restartable signed bit-string read/write path while retaining compare-exchange semantics for the static locked image. Interpreter parity covers signed indices 0, 64, and -1, both old-bit states, the preceding MOVSXD result, CF, complete memory, rejected-write rollback, adjacent-RIP exclusion, and changed-base rejection. All 67 Tier-1 tests and the full 1,499-test/175-suite DBT/PC/runner gate pass. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,023,876 instructions in 148.766 seconds; the prior 6,614-hit live block is absent and interpreter fallback retires 17,520 fewer instructions than the unmatched predecessor. Attempts differ by 69, so the 3.47% wall increase and aggregate movements are unmatched-run noise rather than a performance claim. The only retained native-emitter site is `orw $0x4000,0x3c(%rbx)` at `__kernfs_remove.part.0+0x2c` with 2,115 hits. A05.2 remains open because 115,781 of 217,783 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-10/pvh-alternatives-patched-memory-bts.json)
- **Progress (2026-09-10, second measured word memory-OR follow-up):** Tier-one now admits the exact six-byte `orw $0x4000,0x3c(%rbx)` at `__kernfs_remove.part.0+0x2c`. The production-qualified transactional word-memory OR emitter is parameterized by the matcher-validated immediate, and its replacement logical flags publish only after the final write succeeds. The consolidated two-site matrix covers inputs 0, 1, 0x8000, and 0xffff, complete state/flags/memory, rejected-write rollback, adjacent-RIP exclusion, displacement mutation, and immediate mutation for both encodings. The full DBT/PC/runner gate passes 1,499 tests in 175 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 734,000,417 instructions in 141.396 seconds; the prior 2,115-hit site is absent. Attempts differ by 333, so the 4.95% wall reduction and aggregate movements are unmatched-run noise rather than a performance claim. The leading native-emitter block is now RIP-relative `btq %rax,...` → `jae` at `__call_rcu_common.constprop.0+0xfb` with 5,379 hits. A05.2 remains open because 116,015 of 218,116 attempts still decline. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-10/pvh-second-word-memory-or.json)
- **Progress (2026-09-10, RIP-relative memory-BT and A05.2 closure):** Tier-one now admits the exact ten-byte RIP-relative `btq %rax,0x184a6ed(%rip)` → `jae` block at `__call_rcu_common.constprop.0+0xfb`. The signed bit-string read resolves the fixed `0xffffffff82bf3da0` base from the end of the BT instruction and feeds CF directly into both exact branch targets. Interpreter parity covers signed indices 0, 64, and -1, both bit states, complete state/unchanged memory, the 25 MiB code-to-data span, failed-read rollback, adjacent-RIP exclusion, displacement mutation, and Jcc mutation. The full DBT/PC/runner gate passes 1,500 tests in 175 suites. A release run reaches authenticated userspace, passes all seven workloads, and powers off after 733,808,838 instructions in 145.254 seconds; the prior 5,379-hit block is absent and no `nativeEmitter` decline remains in the 16-site terminal capped sample. All retained sites are explicit `interpreterHelper` boundaries permitted by Appendix A.10. Together with the exhaustive lazy-flags vectors, required materialization boundaries, native NZCV condition paths, and prior frozen-fixture A/B measurement, this closes A05.2 without claiming that interpreter helpers or lower-ranked uncapped sites are absent. Attempts differ by 816, so the 2.73% wall increase and aggregate movements are unmatched-run noise rather than a performance claim. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-10/pvh-rip-relative-memory-bt.json)
- **Check:** Flag vector suite (all defined bits, all sizes, boundaries) passes in JIT vs interpreter; A02 counters show materialization rate; performance delta recorded.

#### A05.3 — Translation cache with direct chaining and IBTC
- [ ] **Action:** Replace the Swift dictionary with a C open-addressed hash keyed by `(physical RIP, mode, CPL, paging)`; blocks end in a chain slot patched on first taken branch to the target's host address (both directions for conditional branches). Indirect `JMP/CALL` consult a per-vCPU 4096-entry IBTC in generated code; `RET` uses a shadow return stack with fallback. Raise the block cap to natural boundaries (until control flow or a page boundary) with a large upper bound. Code cache is generational: flush on exhaustion with a bounded size from the plan (default 128 MiB retained).
- **Progress (2026-09-10, physical C block-cache slice):** The production resident index is now a C-owned open-addressed hash with linear probing, tombstones, replacement/removal/clear, and power-of-two growth at 70% occupancy, keyed exactly by physical RIP, execution mode, CPL, and paging state. Swift retains blocks only in recyclable integer ownership slots. The PC machine supplies the physical RIP through the same permission-checked instruction-fetch translation used for execution, enabling reuse across CR3 changes when physical and virtual identity match and separating distinct physical pages. Because current emitted bodies still encode virtual-RIP-relative behavior, a same-physical/different-virtual alias deliberately recompiles; a differential RIP-relative LEA test proves the guard. Cache lifecycle, aliasing, missing-identity decline, discontiguous paging, growth, and probe-chain tests pass, as does the full 1,506-test/176-suite DBT/PC/runner gate. A frozen release runner reaches authenticated userspace, passes all seven workloads, and powers off after 733,533,019 instructions in 152.226 seconds. It records 104,587,507 C block-cache hits, 131,079,899 recent-front-cache hits, 2,516,195 misses, zero legacy dictionary hits, and zero code-cache wraps. This is correctness and production-use evidence, not an unmatched-run performance claim. Subsequent slices below add direct chaining, natural-boundary growth, the generated IBTC, shadow returns, generational eviction, and their telemetry; the production boot measurement and controlled >95% dispatcher-entry gate still keep A05.3 open. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-10/pvh-physical-c-block-cache.json)
- **Progress (2026-09-10, direct resident-chain slice):** Both native emitters now end eligible direct and conditional dispatch blocks in independently patchable ARM64 branch slots. The chained executor installs same-tier links after resolving a taken target, retires multiple blocks under one generated instruction budget, and reports exact host dispatcher entries, patches, unlinks, and native block transitions. Link records cover every incoming and outgoing edge; target invalidation, replacement, address-space republishing, and cache removal restore predecessor fallbacks before lookup visibility is lost. Patched slots are explicitly disabled for one-block calls and native-trace replay, and every reachable target is generation- or byte-validated before a chain-mode entry. Runtime tests cover baseline and tier-1 warm linking, dispatcher reduction, exact retirement, budget exhaustion, ordinary-call isolation, target invalidation/unlink/replacement, conditional directions, and memory-callback ABI restoration. Blocks now grow to a control-flow or 4 KiB instruction-page boundary with a 4,096-instruction safety cap, and the bounded executable region retains its 128 MiB default. The full DBT/PC/runner gate passes with 1,518 tests in 177 suites (the pinned-input Linux boot test skips when its fixture variables are absent). The generated IBTC, shadow-return path, and generational eviction are recorded in the following slices; production boot measurement and the >95% dispatcher-entry gate remain, so A05.3 stays open.
- **Progress (2026-09-10, generated IBTC slice):** Each executor now owns a 4,096-entry C target cache exposed through the append-only per-vCPU ABI. Generated baseline indirect `JMP` and `CALL` exits compute the inline index, validate the guest-RIP tag and code-cache generation, reject a null host pointer, count hits or misses, and tail-branch directly on a hit. A miss returns to the runtime resolver, which fills a same-tier resident target; the next execution bypasses a Swift dispatcher entry. Resident retirement and whole-cache invalidation clear raw host pointers before code can become unreachable. Low-level MAP_JIT and runtime tests cover hit, miss, generation mismatch, fill, warm reuse, dispatcher reduction, invalidation, and refill. Native dispatcher, direct-chain, and IBTC counters—including aggregate hit rate—are projected through machine statistics, UEFI smoke JSON, and PVH boot snapshots. The full DBT/PC/runner gate passes with 1,520 tests in 177 suites (the pinned-input Linux boot test skips when its fixture variables are absent). Tier-one indirect terminators currently use the baseline generated fallback; the shadow-return path and generational eviction are recorded in the following slices. Production boot measurement and the >95% dispatcher-entry gate remain, so A05.3 stays open.
- **Progress (2026-09-10, shadow-return slice):** Each executor now also owns a bounded 64-entry C shadow return stack with a stable generated-code base, mask, and persistent top-pointer ABI. Successful direct and indirect CALLs push the guest post-decrement RSP and return RIP; when the continuation is already resident in the IBTC, the entry also captures its host address and code-cache generation. Generated RETs perform their architectural guest-stack read and RSP update first, then pop and validate the old guest RSP, returned guest RIP, generation, and nonzero host target before tail-branching. Empty, mismatched, cold, or stale predictions fail closed into the existing inline IBTC and dispatcher path. Resident retirement and whole-cache invalidation clear both raw-target predictors. C storage tests cover LIFO order, bounded wrap, mismatch consumption, generation failure, and clear; MAP_JIT tests cover a shadow hit and IBTC fallback, and the real dispatcher test proves a cold RET seeds the continuation before a warm CALL/RET removes the return edge's dispatcher entry. Hit, miss, push, and aggregate hit-rate telemetry is projected through machine statistics, UEFI smoke JSON, and PVH snapshots. The full DBT/PC/runner gate passes with 1,527 tests in 178 suites (the pinned-input Linux boot test skips when its fixture variables are absent). Generational eviction is recorded in the following slice; production boot measurement and the >95% dispatcher-entry gate remain, so A05.3 stays open.
- **Progress (2026-09-10, generational code-cache eviction slice):** The bounded executable cache is split into two alternating generations within the retained 128 MiB default region. Exhausting the active half rotates into the oldest half, unlinks and retires only blocks whose code lies in that target range, resets its bump pointer, increments the cache generation, and clears native traces plus raw-address IBTC and shadow-return predictions before reuse. Blocks in the newer half remain resident in the C cache and eligible for direct chaining; blocks larger than one generation decline instead of overlapping live code. Diagnostics now report both rotations and the number of evicted blocks through executor, machine aggregate, UEFI-smoke JSON, and PVH snapshots. A regression forces two rotations and proves the newer generation remains a cache hit while the oldest block recompiles; the full DBT/PC/runner gate passes 1,528 tests in 178 suites (the pinned-input Linux boot test skips because its fixture variables are absent). Production boot measurement and the controlled >95% dispatcher-entry gate remain, so A05.3 stays open.
- **Progress (2026-09-10, production dispatcher-gate measurement):** Profiling the first candidate run found that eager recursive validation of every reachable chain target consumed about 85% of host samples. Protected production memory now uses its global protection generation as an event boundary: making code writable advances that generation, unlinks all direct targets, clears IBTC/shadow raw pointers, and leaves resident blocks for lazy byte validation; stable dispatches no longer walk the graph. Provider-only memories retain recursive validation, and a new regression proves both zero linked-target fetches on the warm protected path and correct unlink/recompile after mutation. The full DBT/PC/runner gate passes 1,529 tests in 178 suites. The repaired release runner reaches authenticated userspace, passes all seven workloads, and powers off after 732,361,622 instructions in 228.082 seconds. It records two generation rotations evicting 81,343 blocks, 136,450 direct patches, 130,595 unlinks, 44,890,173 generated bypasses, and 188,833,188 native dispatcher entries. That is only a 19.21% within-run reduction (19.00% normalized against the preceding frozen block-entry baseline), so the >95% gate fails. IBTC records 3 hits/15,705,085 misses and the shadow stack 623 hits/14,841,168 misses because restartable memory/fault-capable blocks cannot safely become raw chain targets while one Swift checkpoint covers the whole entry. A05.3 stays open and A05.4 precise instruction-boundary recovery is now the measured dependency. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-10/pvh-generated-chaining-gate-failed.json)
- **Check:** Dispatcher entries per 1M instructions fall by > 95 % on kernel boot; chaining/unchaining correctness tests (invalidate a chained target, ensure predecessors unlink); IBTC hit rate reported.

#### A05.4 — Precise state at instruction boundaries without spills
- [ ] **Action:** Record per-instruction side-table metadata (RIP, flag state, live-in) so faults and interrupts inside a block restore exact architectural state without storing RIP after every instruction. Interrupt checks at block entry and backward branches read a single context byte (D10). Deoptimize to the interpreter for the faulting instruction when needed.
- **Progress (2026-09-10, instruction-boundary recovery foundation):** Translation now preserves one boundary record per accepted x86 instruction, including its guest RIP/byte span and the exact contiguous IR statement span; zero-statement NOP/control boundaries remain represented and a rewound fallback instruction is never published. The local optimizer remaps those spans after propagation or elimination instead of leaving stale statement indices. Both ARM64 emitters now project the boundaries into byte-relative host offsets outside generated code, record whether tier-1 native NZCV is live, and expose a binary-search lookup that resolves duplicate zero-code offsets to the later owning instruction. Their offsets include both generated chain-budget guards and chain metadata; a regression found and fixed the missing guard displacement before recovery was admitted. Baseline recovery masks are empty because its state is context-backed; tier 1 currently records a conservative all-GPR live/dirty mask pending the precise data-flow pass. Backward-compatible decoding accepts older IR and compiled-block records without side tables. The C execution bridge wraps memory callbacks without changing their ABI context, captures the generated return PC and context image at the first failed callback, and returns both through the prepared-execution result; the chained production dispatcher uses context-recoverable metadata to publish instructions completed before the fault, restore the faulting guest RIP, and retry only that instruction. Native-NZCV boundaries fail closed to whole-block rollback. Real MAP_JIT regressions cover first-instruction rollback, later-instruction prefix publication, unchanged destination state, exact retry RIP, and inline-TLB ABI preservation. The full DBT/PC/runner gate passes 1,534 tests in 178 suites. Exact tier-1 masks, native-NZCV recovery, inline-TLB fault-PC capture, the remaining non-chained execution path, interrupt polling, and the fault/latency acceptance checks remain, so A05.4 stays open.
- **Progress (2026-09-10, exact tier-one recovery masks follow-up):** Tier-one side tables now replace the all-GPR sentinel with per-instruction masks derived from the optimized IR. Live-in includes only GPR values read before their first write within that guest instruction, including partial-register preservation, address base/index inputs, and implicit x86 accumulator/stack/count operands; dirty-at-entry accumulates only GPRs written by earlier emitted instructions. Opaque helpers remain conservatively all-register, while the context-backed baseline retains empty masks. A real lazy-flags recovery test also proves that a callback fault at a native-NZCV boundary restores through the complete context-resident lazy record instead of rolling back the whole block. Metadata tests cover zero-code boundaries, cumulative writes, a partial AL destination, and scaled RBX/RCX addressing. The full DBT/PC/runner gate passes 1,536 tests in 178 suites. Inline-TLB fault-PC capture, the remaining non-chained execution path, interrupt polling, and the fault/latency acceptance checks remain, so A05.4 stays open.
- **Progress (2026-09-10, inline-TLB page-fault recovery follow-up):** The C resolver called directly by generated inline-TLB misses now captures its generated return PC before entering the Swift architectural walker. A `#PF` snapshots the same execution context used by scalar callback failures, allowing the chained dispatcher to resolve the side table, publish the completed instruction prefix, and retry only the faulting memory instruction; ordinary TLB fallbacks remain unmarked and continue through their valid scalar callback path. An mmap-backed long-mode regression proves a first-in-block `INC` retires exactly once, the following unmapped inline load records one TLB page fault, and the interpreter delivers vector 14 with the recovered instruction RIP and exact linear address. The parallel Tier-one helper path proves identical architectural recovery. The full DBT/PC/runner gate passes 1,537 tests in 178 suites. The remaining non-chained execution path, interrupt polling, and the fault/latency acceptance checks remain, so A05.4 stays open.
- **Progress (2026-09-10, non-chained precise-prefix follow-up):** The single-block `execute` and `executeSummary` APIs now use the same callback-fault side table as the production chained dispatcher and report the exact retired guest-instruction count separately from the compiled block's total size. A later-in-block read, write, atomic, or inline-TLB fault publishes only the completed architectural prefix and resumes at the faulting RIP; a first-instruction callback fault and a guard-only interpreter exit publish no speculative state. Tier-one direct callback boundaries checkpoint the pinned RFLAGS base alongside their existing GPR image, closing a stale-flags recovery defect without adding per-instruction spills. Baseline and tier-one regressions compare recovered register, RIP, flags, and memory state with an interpreter-retired prefix across partial-register copies, ALU/native-NZCV producers, atomics, stack operations, and multiply/store blocks. The full DBT/PC/runner gate passes 1,538 tests in 178 suites. Interrupt polling and the fault/latency acceptance checks remain, so A05.4 stays open.
- **Progress (2026-09-10, pending-work polling follow-up):** The append-only vCPU context now has one stable executor-lifetime pending-work byte. Both native emitters poll it at every chain-capable block entry before spending instruction budget, so patched direct targets—including backward branches—return to the dispatcher without retiring or spilling architectural state when work is pending; ordinary one-block execution remains independent of the chain latch. APIC and legacy PIC injection publish the byte through release stores to the matching baseline and optimizing executors, while the PC run loop consumes it only after crossing its controller/lifecycle dispatch boundary and treats a native zero-retirement exit as a yield rather than an interpreter step. Recovery/checkpoint copies deliberately preserve concurrent requests. Executed regressions cover the frozen context index, baseline/tier-one entry guards, clear-and-resume behavior, controller signaling, and a coordinated request arriving after dispatch has begun but before the first native instruction. The full DBT/PC/runner gate passes 1,543 tests in 178 suites. The implementation portion of A05.4 is complete; the named fault corpus and measured interrupt-latency acceptance evidence remain before closing the card.
- **Progress (2026-09-10, precise memory-target chaining follow-up):** Direct-chain admission now includes baseline and tier-one targets whose memory callbacks do not require multi-access replay proof. Every chain-capable dispatcher entry carries a memory-callback context even when its first block is callback-free, closing the ABI hole that would otherwise make a chained target read through a null callback context. A failed callback can resolve its host PC against any resident in the active chain, combine the generated completed-block counters with that resident's instruction boundary, publish the exact cross-block prefix, restore the pre-callback destination state, and retry at the faulting guest RIP; directly-chained diagnostics also include the completed edges on this recovery path. Targets that need restartable-read policy or have an uncaptured baseline interpreter guard remain conservatively dispatcher-separated. Baseline and tier-one MAP_JIT regressions warm a callback-free source into a memory-bearing target and then inject a target read fault after one safe instruction. The full DBT/PC/runner gate passes 1,544 tests in 178 suites. This removes the broad callback-target exclusion from A05.3 without weakening A05.4 fault precision; production chaining-share measurement remains required.
- **Progress correction (2026-09-10, production fault-recovery safety gate):** The preceding exact-mask, inline-TLB prefix, and callback-target chaining claims did not survive the pinned production workload and are withdrawn. A commit-level bisect found two stacked regressions: `9dc361c7cf` completed six workloads but looped until the 900-second wall budget after exact Tier-one masks were enabled, while `db06f5aed6` and later builds reset the guest near 634 million instructions after capturing an inline-TLB resolver context before generated code had published its architectural fault state. Tier one therefore returns to conservative all-GPR recovery metadata; baseline inline-TLB page faults return to whole-block rollback plus interpreter replay; and callback-bearing blocks remain dispatcher-separated until a production-proven cross-resident context contract exists. The focused recovery suite passes 12 tests and the full DBT/PC/runner gate passes 1,544 tests in 178 suites. The repaired release runner reaches authenticated userspace, passes all seven workloads, and powers off after 734,215,272 instructions in 240.723 seconds, with 2,285 inline-TLB page faults safely replayed. A05.4 and the >95% A05.3 dispatcher gate remain open. [Receipt](docs/virtualization/evidence/a05-tier1-2026-09-10/pvh-fault-recovery-safety.json)
- **Check:** Fault-restartability suite (RMW faults at each access, cross-page operands, MMIO) passes with metadata-based recovery; interrupt delivery latency bounded and measured.

#### A05.5 — Gate G1/G2/G3 on the frozen fixture
- [ ] **Action:** Run the frozen Ubuntu/Fedora x86_64 server fixture cold; record boot milestones, instructions/s, RPC p50/p95; compare to A02.4 tier baselines; retain raw samples.
- **Check:** G1 ≥ 150 M instr/s, G2 ≤ 90 s to agent-ready, G3 RPC ≤ 300 ms. If missed, A02.5 reranks and the card stays open — the gate is not lowered.

**Card closes when:** tier-1 is the production tier, the old baseline JIT is flag-disabled, and G1–G3 are met on the frozen fixture.

<a id="a06"></a>

### A06 — Real parallel vCPUs, TSO-preserving memory model and interrupt/timer path (D09, D10)

**Owner/home:** `DoryPCDirectKernelMachine` scheduler, `DoryPCMultiprocessorController`, `DoryPCLocalAPIC`, `DoryX86Interrupts`, `DoryJITRuntimeC` threading.

**Starting point:** One host thread, 64-instruction quanta, queued IPIs drained between quanta; APIC/IOAPIC/HPET implemented.

#### A06.1 — One host thread per vCPU
- [ ] **Action:** Give each vCPU its own thread with its own TLB, IBTC, flag state and code-cache view (shared code cache with per-thread chaining under a light lock or RCU-style publication). Device model calls from vCPU threads go through the existing machine lock with bounded critical sections; MMIO exits do not block other vCPUs.
- **Check:** SMP Linux boots with 2/4/8 vCPUs; `/proc/cpuinfo` and scheduling correct; no deadlock under IPI storms; sanitizer run clean where supported.

#### A06.2 — Memory ordering mode
- [ ] **Action:** When > 1 vCPU is admitted, emit `LDAPR`/`STLR` (acquire/release) for guest loads/stores and full barriers for `MFENCE`/serializing instructions; `LFENCE/SFENCE` mapped appropriately. Single-vCPU plans use relaxed accesses. Locked ops per A04.4. Make the mode a plan attribute recorded in receipts.
- **Check:** x86 TSO litmus suite (store buffering, message passing, IRIW, load buffering) shows zero forbidden outcomes across 10⁷ iterations per test on 4 vCPUs; performance cost of acquire/release measured and recorded.

#### A06.3 — Interrupt delivery from any thread
- [ ] **Action:** APIC/IOAPIC/timer deliveries set a per-vCPU `pendingWork` flag and, if the target is in `HLT`, wake it; generated code checks the flag at block entry/backward branch. `HLT` parks the thread on a condition variable with the APIC timer deadline. NMI/INIT/SIPI/startup-IPI complete the AP bring-up path.
- **Check:** IRQ latency (device event → guest handler entry) p99 ≤ 200 µs idle; no lost interrupts under stress; AP bring-up via INIT/SIPI works on 8 vCPUs.

#### A06.4 — Architectural time
- [ ] **Action:** TSC = `CNTVCT_EL0` scaled to the advertised frequency; `RDTSC/RDTSCP` inline; APIC timer/HPET/PIT/RTC deadlines through one host timer wheel; kvm-clock-style paravirtual clock offered only if implemented completely (else unadvertised). No drift between vCPUs.
- **Check:** Guest `clocksource` selects TSC; NTP-free drift ≤ 50 ppm over 1 h; `sleep 1` in guest is 1.00 ± 0.01 s.

#### A06.5 — Gate G5 and stress
- [ ] **Action:** Frozen parallel workload (e.g., `xz -T`, or a kernel build slice) at 1/2/4 vCPUs; IRQ storms; concurrent SMC stress; 100 start/stop cycles.
- **Check:** G5 met; zero correctness failures; retained raw samples.

**Card closes when:** vCPUs are real threads, TSO litmus passes, interrupts/time are correct and G5 is met.

<a id="a07"></a>

### A07 — Scalar, privileged, paging and exception completeness

**Owner/home:** decoder/interpreter/tier-1 scalar and system forms, `DoryX86Interrupts`, `DoryX86Paging`.

**Starting point:** Broad scalar coverage exists; complete form/fault inventory and independent qualification are open; PSE-36 not modeled.

#### A07.1 — Decode boundaries
- [ ] **Action:** Prefix groups, REX/high-byte rules, ModRM/SIB/displacements, RIP-relative, FS/GS bases, immediates, address wrapping, 15-byte limit including cross-page.
- **Check:** Legal/illegal generation around every byte boundary asserts length or precise fault.

#### A07.2 — Scalar results and flags
- [ ] **Action:** Exhaustive boundaries for arithmetic, ADC/SBB, shifts/rotates (zero/oversized counts), bit ops, MUL/DIV overflow, CMPXCHG, CMOV/SETcc, BMI1/2, LZCNT/TZCNT/POPCNT, MOVBE.
- **Check:** Registers and defined flag bits match the independent oracle (A10) in interpreter and tier-1.

#### A07.3 — Restartability and REP semantics
- [ ] **Action:** RMW faults at each access, unaligned/cross-page, MMIO, page permissions; REP MOVS/STOS/CMPS/SCAS/LODS both directions, zero counts, overlap, mid-string interruption with exact RCX/RSI/RDI/flags.
- **Check:** State unchanged (or architecturally permitted progress) on fault; resumed strings match oracle.

#### A07.4 — Modes, descriptors, paging and exceptions
- [ ] **Action:** Real→protected→long and compat transitions; GDT/LDT/IDT/TSS, CPL/IOPL, gates/IST, IRET, SYSCALL/SYSRET/SYSENTER; paging modes incl. PSE-36, canonicality, reserved/NX/WP/U-S, A/D, PCID, INVPCID, CR3/INVLPG; exception priority, error codes, CR2, nested/double/triple fault, NMI blocking, interrupt shadow, debug traps.
- **Check:** Valid/invalid descriptor, gate, stack, return, page-table-edit and nested-fault tests verified against the oracle; live page-table edits invalidate the inline TLB (A04.2).

#### A07.5 — Real workloads
- [ ] **Action:** Same vectors under interpreter and tier-1; then GCC/Clang, glibc/musl test slices, Python, Go (with default async preemption) inside the x86 guest.
- **Check:** Outputs and checksums attached; remaining gaps listed in the A03 ledger.

<a id="a08"></a>

### A08 — Floating point, SIMD and XSTATE (v2 and v3 profiles)

**Owner/home:** `DoryX86ExtendedFloat`, `DoryX86X87Transfer`, SSE/AVX lowering in tier-1, XSAVE state model.

**Starting point:** x87 via owned 80-bit soft-float; SSE/SSE2 native-ish; SSE3–SSE4.2 decoded but unqualified; AVX mostly rejected; no XSAVE.

#### A08.1 — x87 precision and control
- [ ] **Action:** Full 80-bit semantics: precision/rounding control, denormals, NaN payloads, exception flags/masks, FSAVE/FRSTOR/FXSAVE/FXRSTOR, stack faults. Keep the owned soft-float; optimize the common double-precision paths with host FP where results are bit-identical.
- **Check:** IEEE vector suite and oracle comparison bit-exact; performance recorded.

#### A08.2 — SSE through SSE4.2 on NEON
- [ ] **Action:** Lower all v2 SIMD forms to NEON (`128-bit q` registers pinned for XMM0–15), including MXCSR rounding/DAZ/FTZ behavior, NaN propagation order, integer saturation, PCMPxSTRx, CRC32, POPCNT.
- **Check:** Every v2 row qualified in the A03 ledger with oracle evidence; glibc string/memcpy fast paths execute natively.

#### A08.3 — AVX/AVX2/F16C/FMA as two NEON halves
- [ ] **Action:** YMM as paired NEON registers (or context memory with on-demand loading); VEX decoding complete; zeroing of upper halves on legacy SSE; FMA fused semantics; gathers; lane crossing forms (VPERM*, VPERMQ, VEXTRACTI128) with helper fallbacks where NEON lacks equivalents.
- **Check:** Every v3 row qualified; `/proc/cpuinfo` shows the profile; glibc/OpenSSL/NumPy AVX2 paths run correctly.

#### A08.4 — XSAVE/XRSTOR/XSAVEOPT/XSAVEC and XCR0
- [ ] **Action:** Implement the XSTATE area layout for x87/SSE/AVX components, init/modified optimizations, XCR0/XGETBV/XSETBV and the `#UD`/`#GP` rules; persisted-state versioning for suspend.
- **Check:** Linux context switch and signal frames round-trip; oracle comparison of saved areas; old saved states restore.

#### A08.5 — Promote v2 then v3
- [ ] **Action:** Enable profile bits only via A03.5 rules; run the desktop fixture with each profile; confirm CPUID equals implementation (A03.3).
- **Check:** v2 and v3 profiles qualified with full ledgers; unsupported extensions (AVX-512, AMX, VMX) unadvertised and `#UD`.

<a id="a09"></a>

### A09 — Tier-2 optimizing compiler (region formation, SSA, scheduling)

**Owner/home:** `DoryIROptimizer` → `DoryARM64Tier2`, profiling counters in tier-1.

**Starting point:** The "optimizing" tier is a local constant-prop pass; it was slower to bind-ready than baseline (3,901 s vs 3,361 s). A09 starts only after A05 meets G1–G3.

#### A09.1 — Profiling and region selection
- [ ] **Action:** Hot-block counters in tier-1 chain slots; form superblocks/traces along hot paths across blocks and across direct calls; tier up asynchronously on a compiler thread, publishing atomically.
- **Check:** Hot regions identified on CoreMark-like and kernel workloads; tier-up does not stall vCPUs.

#### A09.2 — SSA IR with x86-precise side exits
- [ ] **Action:** Convert regions to SSA; eliminate redundant flag computations, dead stores to registers, redundant TLB lookups within a page; keep memory ordering and precise faults by treating each guest instruction boundary as a potential side exit with a deopt map to the tier-1/interpreter state.
- **Check:** Differential test on the full vector corpus between tier-1 and tier-2; deopt correctness under injected faults.

#### A09.3 — Register allocation and scheduling for Apple cores
- [ ] **Action:** Linear-scan allocation over the full ARM64 file beyond the pinned set; address-mode fusion; load/store pairing; avoid partial register stalls; `CSEL`-based conditional moves.
- **Check:** Instruction-count and cycle measurements per region; no correctness regressions.

#### A09.4 — Code-cache management
- [ ] **Action:** Generational cache with LRU-ish region eviction, bounded compile-time budget per region, and memory ceilings from the plan; unchain/invalidate under SMC and CR3 churn.
- **Check:** Bounded RSS under a 48-hour desktop run; no unbounded growth; eviction storms absent.

#### A09.5 — Gate G4
- [ ] **Action:** Frozen single-thread integer and FP benchmarks vs host-native; report geometric mean and worst case.
- **Check:** ≥ 40 % of native single-thread integer; no key workload regresses vs tier-1; raw samples retained.

<a id="a10"></a>

### A10 — Independent x86 conformance oracle

**Owner/home:** new `Tools/x86-oracle/` (owned), vectors under `dory-x86-decode-audit/Vectors`.

**Starting point:** The interpreter is the only reference. It shares the decoder with the JIT, so it cannot catch decoder bugs.

#### A10.1 — Owned reference generator
- [ ] **Action:** Build an owned oracle that executes instruction vectors natively on x86_64 hardware (CI runner or a recorded corpus captured once on real Intel/AMD machines and committed with digests) and records register/flag/memory/fault outcomes; independent decoder derived from the SDM tables (A03.1).
- **Check:** Corpus generation reproducible; digests pinned; undefined flags masked.

#### A10.2 — Differential harness
- [ ] **Action:** Run interpreter, tier-1 and tier-2 against the corpus; diff per row; feed results into the A03 ledger's independent-reference column automatically.
- **Check:** Every ledger row's proof column is generated, not hand-edited.

#### A10.3 — System-level traces
- [ ] **Action:** Capture reference traces of privileged sequences (mode switches, page-table edits, exception delivery) from an owned bare-metal test kernel run on real hardware; compare with Dory.
- **Check:** Divergences enumerated and fixed or documented as architecturally permitted.

#### A10.4 — Fuzzing
- [ ] **Action:** Structured instruction fuzzing (decoder, interpreter vs tier-1) with libFuzzer-style harnesses in C; crash and divergence corpus retained.
- **Check:** 24-hour fuzz run with zero divergences on the frozen candidate.

#### A10.5 — Continuous gate
- [ ] **Action:** Required CI job on every x86 engine change; fixture absence fails the job.
- **Check:** Job green on HEAD; runtime bounded.

---

## GPU acceleration

<a id="a11"></a>

### A11 — ARM zero-copy presentation and the first verified hardware frame (D08)

**Owner/home:** `dory-hv/DesktopMode.swift` display contract, `VirtioGPU.swift` scanout, `DoryRendererWorkerVirglBackend`, app display view, `patches/virglrenderer-metal-shareable-scanout.patch`.

**Starting point:** Venus compute proven in the container VM; renderer worker, blob resources and DAX window exist; "host-accelerated display is not implemented by the RawHV Metal display contract"; no on-screen hardware frame recorded.

#### A11.1 — Trace the production display path
- [ ] **Action:** Trace app → daemon → plan → `dory-hv` → worker → scanout → window for the `venus` profile; identify every copy, FD, generation and lease. Document the current software scanout path and the intended shared-texture path.
- **Check:** A diagram/receipt listing each owner and copy count; fixture substitutions prohibited in release evidence.

#### A11.2 — Shared-texture scanout export from the worker
- [ ] **Action:** For `SET_SCANOUT(_BLOB)` resources, allocate `MTLTexture` with `MTLSharedTextureHandle`/IOSurface in the worker, export to the runner; guest `RESOURCE_FLUSH` becomes a fence + damage rectangle message, not a pixel copy. Retain the software path for `off`.
- **Check:** Zero CPU pixel copies per frame in the accelerated path (counted); damage rectangles honored; fence completion precedes publication.

#### A11.3 — Runner/app presentation with fence-gated retirement
- [ ] **Action:** Present the shared texture through a `CAMetalLayer` in the machine window; retire textures only after the consumer's `MTLCommandBuffer` completes; bind to worker/machine generations so worker loss cannot present stale frames.
- **Check:** Trace producer fence → presentation → consumer retirement per frame; no reuse before retirement under stress; resize and occlusion do not leak textures.

#### A11.4 — Render a verifiable guest pattern
- [ ] **Action:** In the ARM guest, verify DRM node, capset and driver (`vulkaninfo` shows Venus/`Apple M…`, no llvmpipe/lavapipe); run an owned shader that draws a known pattern to the scanout; compare captured window pixels.
- **Check:** Pixel comparison passes; renderer names rejected if software; receipt binds kernel/Mesa/worker hashes.

#### A11.5 — Repeat cold through the production catalog
- [ ] **Action:** Cold start via the installed daemon (A00.4) and repeat A11.4.
- **Check:** Same result on signed bytes; negative authority cases retained.

**Card closes when:** an ARM Linux guest's hardware-rendered frame reaches Dory's window zero-copy with proven fencing.

<a id="a12"></a>

### A12 — Shared GPU resource, queue and fence semantics (MMIO and PCI)

**Owner/home:** `VirtioGPU.swift`, `DoryPCVirtioGPUPCIDevice`, `DoryRendererWorkerVirtioCommandLane`, shared texture/blob leases.

**Starting point:** Raw MMIO device is mature (9,348 lines); PCI device reuses shared abstractions; asynchronous fence/generation coverage incomplete.

#### A12.1 — One semantic owner
- [ ] **Action:** Inventory MMIO vs PCI behavior differences; move the virtio-gpu command semantics into one transport-independent core consumed by both; keep transport-only concerns (BARs, MSI-X, MMIO regs) separate. Identical request vectors over both.
- **Check:** Vector parity table with zero unexplained differences; no whole-frame copy regressions.

#### A12.2 — Resource operations and limits
- [ ] **Action:** Validate create/destroy, attach/detach backing, capsets, transfers (bounds/strides/formats), scanouts, cursor updates, `RESOURCE_CREATE_BLOB/MAP_BLOB/UNMAP_BLOB/SET_SCANOUT_BLOB`, UUID, context init; per-resource and per-VM/global caps.
- **Check:** Invalid requests neither allocate nor touch unrelated memory; precise errors.

#### A12.3 — Asynchronous fences
- [ ] **Action:** Hold descriptors until real fence completion; global/context/ring ordering; exactly-once completion; out-of-order signals, no-fence commands, timeouts and errors without blocking the vCPU.
- **Check:** Reordered/delayed fence tests; vCPU never blocks on worker RPC (measured).

#### A12.4 — Backing generations
- [ ] **Action:** Readback vs concurrent guest writes; dirty regions; reset/ID reuse; stale callbacks; late texture retirement; worker replacement across generations.
- **Check:** Interleaved stress passes; stale publications rejected.

#### A12.5 — Kill a busy worker
- [ ] **Action:** Terminate the worker during confirmed outstanding work; reset the device; tear down the VM.
- **Check:** Bounded guest-visible failure; inventory returns to baseline; no leaked textures/FDs.

<a id="a13"></a>

### A13 — PC host-visible BAR, Venus on x86_64 and the first PC frame

**Owner/home:** `DoryPCPCIExpress`, `DoryPCVirtioGPUPCIDevice`, A04 memory core, `DoryPCVirGLRendererAuthority`, x86_64 guest Mesa.

**Starting point:** PCI virtio-gpu exists (class 0x038000, BAR at `0xd0002000`); Venus hidden pending a host-visible BAR; ARM already maps worker memory into the DAX window via `hv_vm_map`; on PC the DBT owns the address space, so the same mapping is `mmap(MAP_FIXED)` into the A04 reservation.

#### A13.1 — Define the PCI aperture ABI
- [ ] **Action:** Add a 64-bit prefetchable BAR (host-visible shared memory capability, `VIRTIO_PCI_CAP_SHARED_MEMORY_CFG`) in `dory.pc@1`'s reserved MMIO space; size/alignment; interaction with RAM/ROM/ECAM; persisted-ABI versioning.
- **Check:** Firmware enumerates and assigns it; ABI doc reviewed with DBT owner; old machines still load.

#### A13.2 — Blob mappings into the DBT address space
- [ ] **Action:** `MAP_BLOB` maps worker-exported memory at `reservation_base + bar_offset` with `MAP_FIXED`; `UNMAP_BLOB` remaps `PROT_NONE`; inline TLB entries for the range are flushed (A04.2) and any translated code in the range invalidated (A04.3). Coherence: host allocation granule vs 4 KiB guest pages bounded.
- **Check:** Map/execute/unmap/reuse under active readers; no stale pointers; subranges cannot expose adjacent memory; two VMs cannot read each other's exports.

#### A13.3 — Unhide Venus on PC
- [ ] **Action:** Advertise the Venus capset on PC only when the BAR path is admitted; x86_64 Venus Mesa artifacts (producer exists) installed in the guest.
- **Check:** `vulkaninfo` in the x86 guest reports Venus/Apple GPU; compute probe passes.

#### A13.4 — PC presentation
- [ ] **Action:** Reuse A11.2/A11.3 shared-texture presentation for PC scanouts.
- **Check:** Zero-copy PC frame; fence trace.

#### A13.5 — First verified PC hardware frame
- [ ] **Action:** Boot the frozen x86 desktop fixture with the accelerated profile; run the owned pattern shader; compare window pixels; repeat cold via the production catalog.
- **Check:** Pixel match; no software renderer; receipt binds candidate, firmware, kernel, Mesa, worker.

<a id="a14"></a>

### A14 — OpenGL strategy, correctness and the desktop matrix on both ISAs (D07, D15)

**Owner/home:** `guest/mesa/*`, `guest/desktop/*`, live gates, renderer patches.

**Starting point:** VirGL2→ANGLE and Venus→MoltenVK both build; no desktop qualified on either ISA; stock/managed profiles unfrozen.

#### A14.1 — Decide the OpenGL path by experiment
- [ ] **Action:** On the ARM desktop fixture (A11 path), run the frozen GL workload (GNOME Shell/Mutter, GTK4 apps, Firefox WebGL, glmark2, a Qt app) under (a) VirGL2→ANGLE→Metal and (b) Zink→Venus→MoltenVK→Metal. Record correctness (pixel/visual defects list), GL version/extensions exposed, fps, p95 frame interval, CPU time in worker, memory. Document MoltenVK feature gaps hit by Zink and whether owned MoltenVK/virglrenderer patches close them.
- **Check:** Written decision with data; the chosen path becomes the required GL profile in the A01.3 matrix; the other is retained only with a named dependent application.

#### A14.2 — Stock and managed profiles
- [ ] **Action:** Freeze stock (distro kernel + Dory Mesa package) and managed (Dory kernel + Mesa) profiles with exact requirements (blob, DRM sync, `virtio_gpu` options); guest package installer for stock distros; never replace the user's kernel silently.
- **Check:** Both profiles pass admission on Ubuntu and Fedora; hidden kernel replacement absent.

#### A14.3 — Graphics correctness
- [ ] **Action:** Shader/pixel comparisons; selected GL/Vulkan CTS cases (not formal conformance); robust-access and device-loss; orientation/alpha/stride/clip/damage/format checks; same-GPU texture export/import.
- **Check:** Pass/fail/skip lists retained; no fast-but-wrong output.

#### A14.4 — Vulkan synchronization and copies
- [ ] **Action:** External memory/semaphore import/export, acquire→render→submit→present, optimal→linear scanout copies, queue/fence lifetime; count CPU and GPU copies; separate translator CPU time from GPU time.
- **Check:** Trace attached; direct-linear vs optimal-to-linear qualified separately.

#### A14.5 — Compositor matrix and pressure (gates G6 and the ARM display budget)
- [ ] **Action:** GNOME and KDE on Xorg, XWayland and native Wayland, on Ubuntu and Fedora, both ISAs; active GTK/Qt/browser/WebGL/editor windows, text, resize, scaling, fullscreen; declared resolutions; sleep/wake; multiple VMs; remove `WaylandEnable=false`/`GSK_RENDERER` overrides only after the original failures pass.
- **Check:** Every required cell passes without llvmpipe/lavapipe; ARM meets the 1080p60 budget; PC meets G6; failures retained.

<a id="a15"></a>

### A15 — GPU product behavior and recovery

**Owner/home:** daemon effective-capability projection, app Settings/machine UI, worker recovery.

#### A15.1 — Observed capability state
- [ ] **Action:** One daemon-owned result: requested vs admitted vs observed profile, guest driver/API, worker-ready, guest-device-ready, first-presented-frame, loss/recovery. Replace the bare `gpuVenusEnabled` toggle projection with this.
- **Check:** UI and CLI show identical effective state; three readiness events distinguishable.

#### A15.2 — Reject unavailable required APIs
- [ ] **Action:** Required Vulkan/GL fails clearly when unavailable; offer explicit software choice; never silent fallback.
- **Check:** Negative requests fail with precise cause.

#### A15.3 — Honest renderer-loss recovery
- [ ] **Action:** Bounded worker restart with device reset or explained VM restart; disks preserved; failed GPU work reported failed.
- **Check:** Injected active loss; checksums preserved; status accurate.

#### A15.4 — Display resource behavior
- [ ] **Action:** Cursor/focus, resize, minimize/occlusion, display disconnect, teardown; per-VM/global admission and reclamation grace.
- **Check:** Textures/FDs reclaimed within the frozen grace period.

#### A15.5 — Multi-VM containment
- [ ] **Action:** Adversarial allocation and busy-worker kill/restart beside a healthy VM.
- **Check:** Quotas hold; healthy VM output unaffected.

<a id="a16"></a>

### A16 — FEX application compatibility (containers; not the x86 VM answer)

**Owner/home:** `guest/initfs/vendor/fex-*`, signal-context patches, container live gates.

**Starting point:** Pinned `fex-2607-dory1`; default Go async-preemption failure blocks promotion.

#### A16.1 — Reproduce default-mode failure
- [ ] **Action:** Default Go regexp failure on shipped, upstream-control and candidate FEX; `asyncpreemptoff` only as diagnostic.
- **Check:** Reproducer retained with kernel/rootfs/toolchain identities.

#### A16.2 — Root-cause and patch
- [ ] **Action:** Fix signal-context/`sigaltstack`/preemption handling in the owned FEX fork; upstream where accepted.
- **Check:** Default-mode Go suite passes; patch has a regression test.

#### A16.3 — Full default-mode validation
- [ ] **Action:** Node/Python/Go/Rust/JVM amd64 container workloads with default settings.
- **Check:** Pass list retained; no environment overrides.

#### A16.4 — Promote safely
- [ ] **Action:** Promote the pin with rollback path.
- **Check:** Existing container gates unchanged.

#### A16.5 — Page-size conflict
- [ ] **Action:** Resolve the 16 KiB GPU / 4 KiB FEX kernel configuration conflict (dual kernels by plan, or 4 KiB GPU kernel qualification) before A17 claims combined support.
- **Check:** Decision recorded; both features work in one VM or the limitation is explicit.

<a id="a17"></a>

### A17 — Combined native/amd64 container GPU

**Owner/home:** `dory-core/runc-wrapper` device translation, container VM kernel/initfs profiles, `DoryHV` Venus path, Settings GPU flow.

**Starting point:** `docker create --gpus all` translates to `/dev/dri/renderD128` and passes the 65,536-output Venus compute probe natively, repeated concurrently; idle-worker recovery preserves volume data. amd64 GPU workloads, active-work recovery, Settings and sustained isolation are unqualified; the 16 KiB GPU kernel conflicts with FEX's 4 KiB requirement (A16.5).

#### A17.1 — Standard requests only
- [ ] **Action:** Keep `--gpus`/`--device` translation as the only entry; ship architecture-correct guest Mesa/Vulkan loader for arm64 and amd64 in the supported images; remove any remaining diagnostic driver environment overrides from the qualified path.
- **Why:** Users run stock Docker commands; an env-var recipe is not a product feature.
- **Check:** Native compute probe passes with an empty environment on the supported image; the amd64 image's Vulkan loader finds the Venus ICD without overrides.

#### A17.2 — Active-work recovery
- [ ] **Action:** Kill the renderer worker while a container compute job is mid-dispatch; observe `VK_ERROR_DEVICE_LOST` (or equivalent) in the container, worker replacement, and a fresh job succeeding; volume checksums unchanged.
- **Why:** Idle-crash recovery does not prove in-flight safety.
- **Check:** Bounded failure reported to the container; data intact; resource inventory back to baseline.

#### A17.3 — Settings flow and isolation
- [ ] **Action:** GPU enable/disable in Settings reaches the container VM plan and is observable from containers; two containers with independent contexts cannot read each other's resources; 8-hour concurrent compute loop.
- **Why:** Policy and isolation must be real, not assumed from the worker design.
- **Check:** Disabled GPU → no `/dev/dri`; isolation negative tests pass; 8-hour run has zero mismatches and bounded memory.

#### A17.4 — Combined FEX + GPU
- [ ] **Action:** After A16.5 resolves the page-size conflict, run amd64 container GPU workloads (compute probe, a Vulkan-using amd64 application) under FEX default mode.
- **Why:** This is the combination the container product advertises.
- **Check:** Pass list retained; no `asyncpreemptoff` or driver overrides.

#### A17.5 — Gate retention
- [ ] **Action:** Rerun the container performance/reliability gates C01–C11 with GPU enabled by default.
- **Check:** No regression beyond C07 tolerances; idle CPU unchanged.

---

## Operating-system cells

<a id="a18"></a>

### A18 — Native ARM runtime: lifecycle, correctness, PCIe bus and probe retirement (D01, D13)

**Owner/home:** `DoryHV/Machine.swift`, `VCPU.swift`, `GICv3MMIO.swift`, `ARMSystemRegisterTrap.swift`, `ARMPSCICPUState.swift`, `DoryMachineARMVirt`, `DoryNativeHVArm64` (to retire as production candidate).

**Starting point:** Production runtime boots SMP Linux to agent in 2.9 s; 19 focused PSCI/pause/register tests; loader alignment fixes merged (`4fb4396e8`, `58f141a5f`). Open: startup-cancel race, IRQ/device stress, UEFI parity through the daemon, suspend/resume quiescence, sysreg trap completeness, PCIe/USB slots unbacked.

#### A18.1 — Confirm the owner and reclassify the probe
- [ ] **Action:** Record that `DoryHV` is the sole production ARM execution owner. Move `DoryNativeHVArm64` and `dory-native-hv-smoke` into test/tooling targets (or `DoryHVTests`), reusing only its deadline/lifecycle contracts where `DoryHV` lacks them. Remove it from the release package graph.
- **Check:** No production target depends on `DoryNativeHVArm64`; entitled smoke still runs from the test tree; shipping inventory excludes it.

#### A18.2 — Lifecycle boundaries under production launches
- [x] Partial: team-array init serialized against stop/pause; terminal state under lock; sysreg log counter protected. [receipt](docs/virtualization/evidence/wave0-2026-09-08/wave1-arm-smp.json)
- [ ] **Action:** Cancel during run, WFI, IRQ, device work and teardown; bounded rendezvous; generation-safe quiescence for pause/suspend; SIGTERM requests guest shutdown before force.
- **Check:** 1,000 randomized cancel points with zero hangs/leaks; owner threads verified.

#### A18.3 — Registers, PSCI and interrupts
- [ ] **Action:** Guest-executed MRS/MSR vectors for the debug/PMU RAZ/WI policy and UNDEFINED for the rest; complete PSCI (VERSION, FEATURES, CPU_ON/OFF/SUSPEND decision, AFFINITY_INFO, SYSTEM_OFF/RESET); one GIC pending/in-service owner; SMCCC handling with explicit `NOT_SUPPORTED` for unimplemented calls.
- **Check:** Guest vector suite passes; PSCI CPU_ON/OFF under SMP; hotplug/suspend explicitly admitted or rejected.

#### A18.4 — Boot and memory topology
- [x] Partial: legacy Image text-offset, 2 MiB alignment, overflow rejection, DTB reservation. [receipt](docs/virtualization/evidence/wave0-2026-09-08/wave1-arm-agent-ping.json)
- [ ] **Action:** Admitted minima and host memory pressure; DTB/firmware/runtime topology identity; timer frequency; 16 KiB and 4 KiB guest page configurations.
- **Check:** Boots at minima; identical topology across firmware/DTB/runtime asserted.

#### A18.5 — PCIe root and xHCI on `dory.armvirt@1`
- [ ] **Action:** Back the reserved ECAM/MMIO range with a PCIe root complex (shared with PC's `DoryPCPCIExpress` where transport-neutral); attach xHCI (A20.4) and allow virtio-pci as an alternative transport for future devices. virtio-mmio slots unchanged.
- **Check:** Linux enumerates the root and xHCI; existing persisted machines boot unchanged; DT and firmware describe the bus identically.

#### A18.6 — Parity and stress
- [ ] **Action:** Direct and UEFI, 1/2/4/8 vCPUs, IRQ storms, memory pressure, rapid lifecycle, sleep/wake, dirty-page tracking correctness for snapshots.
- **Check:** All pass under the signed daemon; one production owner remains.

<a id="a19"></a>

### A19 — Ordinary Linux installation and updates on both ISAs

**Owner/home:** firmware/media pipeline, machine planners, install journals, guest catalog.

**Starting point:** Alpine/Debian ARM manager campaigns prove media transitions on existing disks; no fresh ordinary installer campaign on either ISA; EDK2 firmware for both.

#### A19.1 — Reproducible firmware
- [ ] **Action:** Two clean builders rebuild ARM/PC firmware from locks; console/GOP, variables (atomic recoverable store), enumeration, ExitBootServices, reset.
- **Check:** Hashes match or nondeterministic fields documented; variable store survives failed install and firmware update.

#### A19.2 — Media validation and import
- [ ] **Action:** ISO/raw/imported media detection, ISA, allocation limits; streaming verified download with resume/cancel; immutable cache; owned bounded QCOW2/VMDK converter (no external utility).
- **Check:** Malformed/wrong-ISA rejected before mutation; original bytes preserved.

#### A19.3 — Fresh installations
- [ ] **Action:** Ubuntu and Fedora installers from pinned media on ARM64 (native) and x86_64 (DBT) through app and CLI; partitioning, bootloader, input, network; cancel/retry cleanup; serial/recovery console.
- **Check:** Four fresh installs complete; x86 installer time recorded against G2.

#### A19.4 — Installed-disk independence
- [ ] **Action:** Detach media, restart daemon, cold boot offline, change resources, reboot repeatedly; NVRAM persisted.
- **Check:** No dependency on installer/scratch; boot order persists.

#### A19.5 — Updates and recovery
- [ ] **Action:** Package/kernel/bootloader/tools/graphics updates; rollback; encrypted disks; non-US keyboard; initramfs regeneration.
- **Check:** Two families per ISA complete install→boot→update→recovery.

<a id="a20"></a>

### A20 — Device parity and daily I/O

**Owner/home:** `DoryVirtio` cores, MMIO/PCI transports, host network/audio/USB/input adapters.

#### A20.1 — Queue and DMA correctness over both transports
- [ ] **Action:** Descriptor chains, indirect/loop/overflow, event suppression, wrap, exactly-once completion; FEATURES_OK/DRIVER_OK/reset; PCI BAR probing/reassignment, ECAM, capabilities, MSI/MSI-X, INTx under real firmware; DMA uses granted physical authority.
- **Check:** Identical vectors pass over MMIO and PCI.

#### A20.2 — Durable block I/O
- [ ] **Action:** Geometry, read/write/flush/discard/write-zeroes, short I/O, read-only, ENOSPC, cancellation, reset; crash after acknowledged flush.
- **Check:** Checksums intact; durability boundary honored.

#### A20.3 — Network, RNG, vsock
- [ ] **Action:** Offloads/MTU/backpressure/link change; cryptographic RNG; vsock flow control/half-close/reset; agent framing/deadlines.
- **Check:** Real entropy; malformed input bounded.

#### A20.4 — Interactive devices
- [ ] **Action:** Keyboard release/focus recovery, relative/absolute pointer, scrolling; audio formats/latency/underrun/device loss; xHCI control/bulk/interrupt, hotplug, detach; camera and mass-storage as separate opt-in capabilities.
- **Check:** Each exercised in a real guest; policies separately verified.

#### A20.5 — Concurrent I/O parity
- [ ] **Action:** Reset/stop during outstanding I/O; multi-VM load; delete duplicate cores after parity.
- **Check:** No stale DMA, duplicate completion, hang or leak.

<a id="a21"></a>

### A21 — Production Mac installation and lifecycle (D14)

**Owner/home:** `DoryVZMacCore`, `DoryVMMKit`, `MachineManager`, install/saved-state journals.

**Starting point:** Private signed-helper install/suspend/restore work exists ([`p07-macos-2026-09-05/`](docs/virtualization/evidence/p07-macos-2026-09-05/)); production daemon/catalog admission and failure boundaries open.

#### A21.1 — Install through the shipped path
- [ ] **Action:** Supported restore discovery (`VZMacOSRestoreImage.latestSupported`/user IPSW), hardware-model compatibility, minima; via installed daemon and signed helper: download/cache → prepare → install → first boot → Setup Assistant → installed cold boot without the IPSW cache.
- **Check:** Recorded end to end on the signed candidate.

#### A21.2 — Atomic identity
- [ ] **Action:** Hardware model, machine identifier, auxiliary storage, disk and configuration as one owned bundle; retries never regenerate identity.
- **Check:** Hashes stable across retries/cold restarts.

#### A21.3 — Lifecycle transitions
- [ ] **Action:** Start/shutdown/force-stop/restart/pause/suspend/restore with deadlines; real file checksum + compute task after restore; SIGTERM → guest shutdown request first.
- **Check:** Observed transitions; post-restore workload passes.

#### A21.4 — Durable-boundary failure injection
- [ ] **Action:** Kill/reopen at reserve/quiesce/save/validate/publish/acknowledge/consume/cleanup; one saved-state manifest; wrapper/bundle reconciled atomically.
- **Check:** Fresh daemon selects one recoverable state; consumed RAM never replayed.

#### A21.5 — Host and upgrade failures
- [ ] **Action:** Locked console, sleep/restart, disk full, drive loss, stale leases, incompatible saved state, guest/Dory upgrades; safe cold boot offered.
- **Check:** Data and identity preserved in every case.

<a id="a22"></a>

### A22 — Mac device policy, shared folders, guest tools and guest Metal

**Owner/home:** `DoryVZMacConfigurationBuilder`, host brokers, Mac guest tools, `scripts/macos-metal-compute-probe.swift`.

**Starting point:** Camera/mic opt-in and policy exist; `shares: absent`, `guest-tools: absent`; Metal evidence is host-only.

#### A22.1 — Policy reaches VZ configuration
- [ ] **Action:** Trace CPU/RAM/display/network/audio/clipboard/shares/camera/USB settings from definition → plan → constructed VZ devices and brokers; disabled devices absent or blocked.
- **Check:** Constructed configuration inspected per setting; guest cannot use disabled devices.

#### A22.2 — Shared folders and granted integrations
- [ ] **Action:** `VZVirtioFileSystemDeviceConfiguration` with `VZSharedDirectory`/`VZMultipleDirectoryShare`, read-only/read-write roots, directional clipboard enforcement; unsupported modes rejected truthfully.
- **Check:** Guest mounts shares with correct permissions; revocation works; capability matrix `shares: implemented`.

#### A22.3 — Trustworthy Mac guest tools
- [ ] **Action:** Machine-bound tools installed through supported mechanisms (launchd agent), reporting OS/build, protocol, capabilities, readiness (helper alive / VM running / login / workload-ready); no automation of Setup Assistant.
- **Check:** Readiness states distinguishable; tools cannot gain unrelated host access.

#### A22.4 — Guest Metal proof
- [ ] **Action:** Run `macos-metal-compute-probe` **inside** the guest and a render probe (owned Metal app drawing a known pattern) captured in Dory's window; record guest device name (`Apple Paravirtual device`), guest OS build, logical CPUs equal to the plan.
- **Check:** Guest-identified pass; window pixels match; one-display limit documented.

#### A22.5 — Sustained Metal and policy revocation
- [ ] **Action:** 8-hour Metal workload; camera/mic revocation mid-session; display resize/scale.
- **Check:** No corruption/crash; revocation immediate.

---

## Product, data and shipped surfaces

<a id="a23"></a>

### A23 — Storage, snapshots, clone and backup recoverability

**Owner/home:** mutation authority and journals in `DorydKit`, Mac bundle/recovery, snapshot manager, disk format code, import converter (A19.2).

**Starting point:** Mutation authority, journals, Mac bundle/recovery and snapshot infrastructure exist; Alpine/Debian cold snapshot/export/reopen campaigns ran on ARM. Failure-boundary drills, second-host import and x86/Mac saved-state versioning are open.

#### A23.1 — Advertised data operations inventory
- [ ] **Action:** Enumerate per cell what is offered: cold snapshot, restore, clone, export/import, backup, disk resize, live suspend (Mac via VZ saved state; Linux ARM only if A18 quiescence proves it; x86 only after A08.4 XSTATE versioning). Anything unproven is marked unavailable in daemon capabilities and hidden or disabled in UI/CLI with the reason.
- **Why:** A menu item that sometimes destroys data is worse than no menu item.
- **Check:** UI/CLI expose exactly the inventory; every advertised operation has a drill in A23.4.

#### A23.2 — Journals and atomic commits
- [ ] **Action:** One mutation authority per machine directory; every durable operation writes an intent record, performs work in a staging area, and publishes atomically (rename/link); interruption at each boundary (intent, staging, publish, acknowledge, cleanup) leaves either the old or new state, never a mix. Export bundles carry identity, ABI, config and content hashes so a second host can verify before adopting.
- **Why:** Interrupted data operations are the common failure users actually hit.
- **Check:** Kill/reopen corpus at every boundary passes for each operation; import on a second checkout verifies hashes and rejects tampered bundles.

#### A23.3 — Snapshot consistency
- [ ] **Action:** Cold snapshots capture disk plus firmware variables plus configuration with hashes; snapshot metadata records machine ABI (`dory.armvirt@1`/`dory.pc@1`), CPU/GPU profile and host constraints so restore rejects incompatibilities before touching the disk. Dirty-page tracking for any future live path is proven by CPU/DMA/granule write coverage (A18.6) before use.
- **Why:** Restoring a snapshot into an incompatible machine silently corrupts it.
- **Check:** Incompatible ABI/profile snapshot rejected with precise reason; compatible restore boots and passes guest checksum.

#### A23.4 — Restore drills
- [ ] **Action:** For each cell: write known files in the guest, snapshot, mutate, restore, verify; clone and boot the clone with a distinct identity; export, delete, import, boot; Mac saved-state restore followed by a real compute/file task; x86 restore across a profile version bump (must reject or migrate, never misinterpret).
- **Why:** A snapshot that cannot be restored is a false sense of safety.
- **Check:** Guest data checksums intact in every drill; identity rules (Mac machine identifier preserved; clones distinct) hold.

#### A23.5 — Failure boundaries
- [ ] **Action:** Disk full during snapshot/export; external drive disconnect during commit; daemon kill during publish; host restart mid-operation; concurrent operations on the same machine rejected by lease.
- **Why:** Real environments fail at the worst moment.
- **Check:** No data loss in any case; operation status accurate after reopen; stale leases recovered.

<a id="a24"></a>

### A24 — Networking and filesystem sharing

**Owner/home:** gvproxy launch plan and forward registry, `dory-network-helper`, `DoryFSWorker*`, `DoryHostShareCoherenceBridge`, virtio-net/virtiofs devices.

**Starting point:** gvproxy NAT datapath, forward registry, filesystem worker (7,673 lines) and coherence bridge exist for containers/ARM. `DesktopMode.swift:1085` rejects a resolved network mode as "not implemented by raw-HV"; policy variants and Mac shares (A22.2) are open.

#### A24.1 — Modes and isolation
- [ ] **Action:** Define the network modes per cell: NAT (gvproxy), host-only, none, and any bridged/shared mode the platform supports honestly (VZ bridged needs entitlement; raw-HV bridged needs the network helper). Implement or explicitly reject the currently unimplemented raw-HV mode. Observe isolation from inside the guest (can/cannot reach host services, other VMs, LAN, internet).
- **Why:** Network policy is a security boundary users rely on.
- **Check:** Each mode's connectivity and isolation observed in guest tests for each cell; denied modes reject with reason rather than falling back to NAT.

#### A24.2 — Port forwarding and DNS
- [ ] **Action:** Forward registry with conflict detection, persistence, and revocation on stop; DNS resolution policy (host resolver vs guest), mDNS/`.local` policy; link-change (Wi-Fi ↔ Ethernet, sleep/wake) recovery without guest reboot.
- **Why:** Developer workflows depend on ports and names working after ordinary host events.
- **Check:** Forwards survive daemon restart; conflicts rejected; DNS behavior observed; connections recover after link change within a bounded time.

#### A24.3 — Filesystem shares (Linux)
- [ ] **Action:** virtiofs through the isolated filesystem worker with explicitly granted roots (read-only/read-write); coherence bridge for host-side edits; internal shares separate from user home (`e5b7e52b0`); ownership/permission mapping documented; symlink/`..` escape prevention.
- **Why:** Shares are the most common host-access path and the most common escape vector.
- **Check:** Coherence tests (host edit → guest sees; guest edit → host sees) pass; escape attempts fail; permission mapping matches documentation.

#### A24.4 — Performance
- [ ] **Action:** TCP/UDP throughput and latency and virtiofs read/write/metadata throughput vs same-host baseline at matched MTU/offload/cache policy; report per cell.
- **Why:** Slow shares and networking make an otherwise fast VM unusable.
- **Check:** ≥ 90 % of baseline throughput; ≤ 10 % p95 latency regression; raw samples retained.

#### A24.5 — Concurrency and recovery
- [ ] **Action:** Kill the filesystem worker and the network helper during active I/O; verify bounded guest-visible error, reconnect, and data integrity.
- **Check:** No corruption; reconnect within grace period; leases released.

<a id="a25"></a>

### A25 — Guest tools and desktop integration

**Owner/home:** `dory-core/agent` (Rust guest agent), Linux tools packaging under `GuestTools/`, Mac tools (A22.3), daemon readiness projection.

**Starting point:** The Rust guest agent answers RPC over vsock in Linux guests (proven on ARM; once on x86). Desktop integration (clipboard, resolution, time sync) and tools delivery for stock distros are incomplete; Mac tools absent.

#### A25.1 — Delivery
- [ ] **Action:** Package Linux tools for both ISAs as distro-native packages (deb/rpm) plus a generic tarball, delivered through an ISO/virtiofs share or an in-guest fetch from the daemon; machine/session identity in the handshake; versioned protocol with capability negotiation.
- **Why:** Stock guests must be able to gain tools without a managed kernel.
- **Check:** Fresh Ubuntu and Fedora installs (both ISAs) acquire tools; absent, stale and unhealthy tools are distinguishable in the daemon.

#### A25.2 — Capabilities
- [ ] **Action:** Clipboard (both directions, policy-gated), resolution/scale following the window, time sync after sleep/suspend, graceful shutdown/reboot requests, file drop where the platform supports it.
- **Why:** These make a VM feel like an application instead of a remote machine.
- **Check:** Each capability observed end to end on GNOME/KDE (Linux) and macOS guests; disabled policy blocks the capability.

#### A25.3 — Readiness projection
- [ ] **Action:** Tools state (absent / installed / connected / capability set) in the daemon-owned machine result alongside GPU state (A15.1).
- **Check:** UI and CLI show identical tools state; state changes are events, not polls.

#### A25.4 — Updates
- [ ] **Action:** Tools update path in-guest; declared compatibility window between tools and daemon protocol versions.
- **Check:** Old tools + new daemon and new tools + old daemon behave as declared; unsupported combinations reported.

#### A25.5 — Security
- [ ] **Action:** Tools protocol fuzzed; tools cannot request host access beyond the machine's granted policy; agent runs with minimal privileges in the guest where possible.
- **Check:** 24-hour fuzz clean; negative authority tests retained.

<a id="a26"></a>

### A26 — App/CLI/API parity and upgrade migration

**Owner/home:** `Dory/Models/AppStore.swift`, `MachinesView`, `NewMachineSheet`, `dorydctl`, `DorydKit` operation records, `DoryOperations` definitions.

**Starting point:** App and CLI can create/start/stop/pause/suspend machines; the app holds substantial duplicate state; platform picker and GPU toggle are visible regardless of qualification.

#### A26.1 — One definition, one plan, one operation
- [ ] **Action:** Project all machine state in the app from daemon-owned definitions, resolved plans and operation records; extract operation-specific logic out of `AppStore.swift` (7,180 lines) incrementally, deleting duplicate caches and state machines as each projection lands.
- **Why:** Two sources of truth disagree exactly when something goes wrong.
- **Check:** Machine state identical across app and `dorydctl` at every lifecycle point in a scripted comparison; no app-side mutation bypasses the daemon.

#### A26.2 — Truthful platform picker
- [ ] **Action:** `.linuxX86_64` and each GPU profile are selectable as qualified only when the current candidate's capability projection (A15.1, A03.5) admits them on this host; otherwise shown as preview with the exact reason and consequences. Remove options unimplementable with public APIs (R19).
- **Why:** Users judge the product by what the picker promises.
- **Check:** Capabilities equal built configuration on every supported host/guest tuple; preview labels carry the daemon's reason string.

#### A26.3 — Operation/generation binding and cancellation
- [ ] **Action:** Every long operation has an ID and generation; client timeouts never cancel backend work; explicit cancel is bound to machine/operation/generation and honored by the backend with bounded deadlines (A18.2, A21.3).
- **Why:** A dropped socket must not abort an install, and a cancel must not kill a newer operation.
- **Check:** Timeout vs cancel behaviors observed for install, snapshot, and start; stale-generation cancel rejected.

#### A26.4 — Upgrade migration
- [ ] **Action:** Definitions and operation records migrate once per schema version with a journal; interrupted migration resumes or rolls back; legacy definitions (Intel-host, QEMU-era) rejected intelligibly.
- **Check:** Migration corpus passes without loss; interrupted-migration drill recovers.

#### A26.5 — Documentation and help
- [ ] **Action:** Public `dorydctl machine` reference and in-app help generated from or checked against the qualified capability set.
- **Check:** Reviewed against the A01.3 matrix; no undocumented flags, no documented unqualified claims.

<a id="a27"></a>

### A27 — Trust boundaries, isolation and component delivery

**Owner/home:** entitlements/sandbox profiles under `Config/`, launch handoff, component catalog verifier, XPC services, `DoryJITRuntimeC`.

**Starting point:** Signed launch handoff with peer identity; catalog verifier rejects test roots; XPC renderer/filesystem workers; JIT uses `MAP_JIT`. Env-driven behavior audit, revocation, parser fuzzing and JIT hardening review are open.

#### A27.1 — Launch/renderer override audit
- [ ] **Action:** Inventory every environment variable, file path convention and CLI flag that changes runner/worker/helper behavior; classify as removed, development-signed-only, or product configuration with admission.
- **Why:** Ambient overrides are how authority leaks.
- **Check:** Inventory committed; shipped binaries ignore development-only variables (tested).

#### A27.2 — Process isolation
- [ ] **Action:** Minimal entitlements per process (`hypervisor` only in runners; no network in workers that don't need it); descriptor containment (workers receive only granted FDs); peer identity checked on every XPC connection; sandbox profiles for renderer and filesystem workers.
- **Why:** A compromised renderer must not become a compromised host.
- **Check:** Negative tests per boundary (wrong peer, extra FD, escaped path); `codesign -d --entitlements` inventory matches the plan.

#### A27.3 — Component catalog and signing
- [ ] **Action:** Production component root with offline verification, schema-2 catalog (A01.5), revocation list, pinned publisher verification for downloaded media; rollback of a revoked component.
- **Check:** Tampered, expired, revoked and downgraded catalogs rejected; valid catalog admitted.

#### A27.4 — Guest-controlled parsers
- [ ] **Action:** libFuzzer/structured fuzzers for virtio descriptor chains, virtio-gpu commands (both transports), FDT/ACPI generation inputs, PCI config space, agent protocol, media/ISO/QCOW2/VMDK parsers, firmware variable store.
- **Check:** 24-hour runs clean on the candidate; every crash gets a regression test.

#### A27.5 — JIT hardening
- [ ] **Action:** W^X discipline with `pthread_jit_write_protect_np`; code cache integrity checks on publication; guest cannot influence host code layout beyond translation; helper table not writable from generated code; bounds on translation inputs.
- **Check:** Security review of the tier-1/tier-2 emitters; tests for write-protect toggling and cache integrity.

<a id="a28"></a>

### A28 — Retirement of obsolete code, stale tasks and documents

Owns the [retirement inventory](#retirement-inventory). Each row is retired only after persisted-state migration, behavioral parity, affected guest tests and shipping-payload inspection pass.

#### A28.1 — Old x86 tiers (R21)
- [ ] **Action:** After A05.5 and A09.5 gates, remove the pre-v2 baseline/optimizing executors, the Swift dispatcher path and per-write SMC generation counters. Keep the interpreter (D11) and its tests.
- **Check:** No call sites remain; test suite still passes via tier-1/tier-2 and interpreter; binary size and build time recorded.

#### A28.2 — ARM probe and duplicate cores (R08, R09, R17)
- [ ] **Action:** After A18.1/A18.6, `DoryNativeHVArm64` and probe executables leave the release graph; after A20.5, duplicate virtio cores are deleted.
- **Check:** Shipping inventory excludes probes; virtio vectors pass on the single shared core.

#### A28.3 — Intel-host / x86 macOS remnants (R06)
- [ ] **Action:** Remove unreachable planning, UI options, components and build wiring; keep only explicit legacy-definition rejection.
- **Check:** Importing an old Intel-host definition yields an intelligible rejection.

#### A28.4 — QEMU-named references and legacy engines (R07, R15, R16)
- [ ] **Action:** Classify every `qemu` reference (15 Swift files) as name-only compatibility, attribution, or dependency; remove dependencies; migrate legacy lifecycle models once.
- **Check:** Package/process/linked-binary inventory shows no QEMU runtime dependency; migration corpus passes.

#### A28.5 — Documents and evidence authority (R05, R18)
- [ ] **Action:** Remove superseded plan fragments, source-text tests and hand-curated pass receipts as authority; keep immutable historical inputs where useful.
- **Check:** `scripts/audit-plan-evidence.py` passes; no test asserts prose.

---

## Qualification and release

<a id="a29"></a>

### A29 — Frozen performance and reliability campaigns

**Owner/home:** benchmark harnesses under `scripts/benchmark-*`, `qualify-container-engine-performance.sh`, new VM campaign scripts, dedicated benchmark account/host.

#### A29.1 — Freeze budgets per host class
- [ ] **Action:** Calibrate every row of the contract table on the approved matrix hosts; record the frozen numbers with rationale; any change afterwards is a reviewed scope change, not a post-failure edit.
- **Check:** Frozen budget document signed by release, runtime and performance owners.

#### A29.2 — CPU campaigns
- [ ] **Action:** Native ARM micro and whole-workload comparisons vs a minimal HV reference; x86 gates G1–G5 on frozen binaries and fixtures; repeated matched samples; censored runs retained.
- **Check:** Every gate met or explicitly failed with retained samples; no estimates.

#### A29.3 — Graphics campaigns
- [ ] **Action:** ARM 1080p60 budget, PC G6, Mac Metal budget; input-to-visible and resize-to-stable on each desktop cell; sleep/wake and multi-VM variants.
- **Check:** p95/p99 recorded with correctness checks passed first.

#### A29.4 — Reliability
- [ ] **Action:** ≥ 100 start/stop/reboot cycles per required cell; 48-hour mixed desktop/development workload per release-critical composition; failure injection (worker loss, disk full, host restart, drive loss); multi-VM pressure.
- **Check:** Zero corruption, zero unexpected crashes; every failure retained and triaged.

#### A29.5 — Container gates C01–C11
- [ ] **Action:** Rerun the existing container performance and reliability campaigns on the same candidate.
- **Check:** Unchanged within C07 tolerances; evidence ZIPs produced.

<a id="a30"></a>

### A30 — Qualify and publish the exact release

**Owner/home:** `scripts/release.sh`, notarization flow, publication workflows, evidence archive scripts.

#### A30.1 — Candidate assembly
- [ ] **Action:** Build, sign and notarize the exact candidate from a tagged revision; SBOM and manifests bind app, daemon, runners, workers, firmware, kernels, Mesa, tools and FFI archive.
- **Check:** Producer inventory complete; second clean build reproduces inputs.

#### A30.2 — Matrix execution
- [ ] **Action:** Execute every required cell of the approved matrix on the exact notarized bytes; A29 results must reference these hashes.
- **Check:** No cell borrowed from another architecture or an earlier build.

#### A30.3 — Evidence archives
- [ ] **Action:** Produce `Dory-<version>-vm-qualification-evidence.zip` alongside the container performance and reliability ZIPs, each with manifest, deterministic digest list, raw results, summaries, cleanup and redaction reports.
- **Check:** Archives validate; bound to the candidate.

#### A30.4 — Claims review
- [ ] **Action:** Public capabilities, release notes, website and app copy equal the qualified product; translated CPU performance reported separately; limitations listed.
- **Check:** Reviewer signs off against DONE-01–14.

#### A30.5 — Publication and reverification
- [ ] **Action:** Publish; download the published artifacts and evidence; recompute identities and digests; publish digests with the release.
- **Check:** Downloaded bytes match; missing/failed/skipped required evidence blocks publication.

---

## Performance and reliability contract

Initial engineering targets; A29 freezes per host class. Never lowered after a failure to manufacture a pass — change scope explicitly with rationale instead.

| Dimension | Target | Boundary |
|---|---|---|
| Native ARM CPU microbenchmark | ≥ 95 % of host-native; ≥ 97 % of a minimal HV reference | Release binary, matched loops |
| Native ARM whole workload | Within 10 % of same-host native-virtualization reference | Build, compression, runtime, interactive |
| x86 translated (G1–G5) | ≥ 150 M instr/s; boot ≤ 90 s server / ≤ 150 s desktop; RPC ≤ 300 ms; ≥ 25 % (tier-1) / ≥ 40 % (tier-2) native single-thread; 2 vCPU ≥ 1.7× | Frozen fixtures, identical resources |
| Linux ARM / Mac display 1080p60 | p95 ≤ 16.7 ms, p99 ≤ 33.4 ms, ≤ 1 % missed | Completed host presentation |
| x86 display 1080p (G6) | p95 ≤ 33 ms | Reported separately |
| Input-to-visible | p95 ≤ 50 ms, p99 ≤ 100 ms | Injected input → changed frame |
| Resize-to-stable | p95 ≤ 250 ms | Correct resolution, non-stale frame |
| Installed cold boot | ARM Linux ≤ 30 s; macOS ≤ 60 s; x86 Linux ≤ 90 s (server) | Fixed disk/cache state |
| Idle | ≤ 5 % of one core desktop; ≤ 2 % headless; no busy polling | Fixed sampling |
| Storage/network | ≥ 90 % baseline; ≤ 10 % p95 regression | Matched policy |
| Memory | Frozen per-profile budgets; JIT cache ≤ plan; reclaim within grace | Attributed footprint |
| Reliability | Zero corruption; zero unexpected crashes in campaign | Failures recorded, never erased |

### Physical matrix and execution order

1. Oldest admitted Apple Silicon class, midrange, high; every supported macOS branch; a deliberate low-memory case.
2. Ubuntu LTS + Fedora per Linux ISA, stock and managed profiles; Mac guest builds with restore provenance.
3. 1/2/4/8 vCPUs, small/typical/large RAM, one/multiple VMs, internal/external drives, offline launch.
4. Correctness first (CPU/faults, GPU identity/output, storage checksums, permissions), then performance.
5. ≥ 100 start/stop cycles per cell; 48-hour mixed workload; frozen suspend/restore, GPU-loss and reset counts.
6. Install → boot → tools → guest update → Dory update → rollback; injected disk-full, process/worker loss, host restart, drive loss.
7. Retain everything; a fix reruns the minimized failure and the affected end-to-end gate.

### Existing container performance and reliability gates (C01–C11)

Unchanged in substance from the previous plan and still required: immutable candidate binding (C01); matched 6 vCPU/6 GiB environments vs OrbStack/Colima (C02); ≥ 9 balanced interleaved rounds (C03); real developer workloads (C04); correctness before timing (C05); existing harness owners `benchmark-*.sh`/`qualify-container-engine-performance.sh` (C06); statistical claim rules — parity within 10 % medians, win > 10 % with non-overlapping bootstrap CIs (C07); full resource accounting (C08); 8-hour endurance and > 24-hour TCP connection (C09); durable evidence ZIPs (C10); reverified downloaded publication (C11).

---

## Retirement inventory

| ID | Candidate | Action | Prerequisite |
|---|---|---|---|
| R01 | Kernel-address tracing / hardcoded PCs in PC bring-up | Behind diagnostic config | A02.2 structured traces |
| R02 | Blanket Xen CPUID / no-op hypercalls | Minimal documented PVH contract | Negative hypercall tests |
| R03 | ELF address masks, unqualified section loading | Validated boot-format mapping | A07/A19 loaders |
| R04 | Tests depending on `/tmp` or lacking boot assertions | Fixture-explicit tests | CI fails on absent fixture |
| R05 | Source-text tests | Delete after structured checks | A01 |
| R06 | Intel-host / x86 macOS options | Remove | Legacy-definition rejection kept |
| R07 | Generic VZLinux / custom-VZ-GPU experiments | Bounded legacy adapter only | Installed-user migration path |
| **R08 (corrected)** | `DoryNativeHVArm64` as a production candidate | Reclassify as test tooling; `DoryHV` is the owner | A18.1 |
| R09 | Duplicate old/new virtio cores | Port to shared core | A20.5 |
| R10 | In-process legacy renderer in `VirtioGPU.swift` test fakes | Worker-channel doubles | A12 |
| R11 | `DoryPCVirGLRendererAuthority` | **Retain**; finish PC GPU; delete only after shared replacement | A13 |
| R12 | Hardcoded dual-capset/kernel tuple policy | Typed authenticated profiles | A14.2 |
| R13 | Monolithic `MachineManager`/`DesktopMode`/`Machine`/`AppStore` | Extract by operation | A26.1 |
| R14 | Repeated wire/LE utilities | Shared checked utility | Fixtures |
| R15 | QEMU-named legacy references | Classify; no runtime dependency | A28.4 |
| R16 | Competing lifecycle models | Migrate once | A26.4 |
| R17 | Probe executables in release graph | Move to dev targets | A18.1, A28.5 |
| R18 | Hand-curated pass receipts | Remove as authority | A01.2 |
| R19 | Options unimplementable with public APIs | Remove; report reason | A22/A26 |
| R20 | Unmeasured optimizations | Remove or disable | A09.5 |
| **R21 (new)** | Pre-v2 baseline/optimizing x86 executors, per-write SMC generations, Swift dispatcher path | Remove after tier-1/tier-2 gates | A05.5, A09.5 |
| **R22 (new)** | The losing GL path from A14.1 | Retain only with a named dependent | A14.1 |

---

## Legacy coverage

| Earlier phase | Current owners |
|---|---|
| P00 | A01/A28/A29 |
| P01 | A00/A01/A26/A27 |
| P02 | A03–A10 |
| P03 | A18 |
| P04 | A06/A12/A13/A20 |
| P05 | A19 |
| P06 | A11–A17 |
| P07 | A02/A04/A05/A06/A09 |
| P08 | A21/A22/A23 |
| P09 | A20/A22/A25 |
| P10 | A23 |
| P11 | A24 |
| P12 | A15/A26 |
| P13 | A00/A01/A27/A28 |
| P14 | A02/A09/A14/A17/A29; C01–C11 |
| P15 | A28/A29/A30 |

### Q01–Q08 review rules (unchanged)

Q01 minimized regression + real-guest rerun; Q02 explicit fixture identity; Q03 tests check behavior not text; Q04 versioned ABI fixtures with one owner; Q05 sanitizer/race/fuzz where supported; Q06 long campaigns as separate pre-release jobs; Q07 optimization requires correct output and whole-workload improvement; Q08 deletion removes real call sites and migrates persistence.

---

## Final completion gates

- [ ] **DONE-01** Apple Silicon sole host; Linux ARM64, Linux x86_64, macOS ARM64 the only guest cells.
- [ ] **DONE-02** Each cell installs from ordinary media, reboots without installer, updates, shuts down and recovers via app and CLI.
- [ ] **DONE-03** ARM Linux on `DoryHV`; x86 Linux on `DoryDBTX86` v2 + `DoryMachinePC`; Mac on `DoryVZMacCore`. No hidden third-party runtime or architecture substitution.
- [ ] **DONE-04** Both Linux ISAs: qualified guest Vulkan and OpenGL (per D07) with zero-copy presentation; Mac: qualified guest Metal; containers: qualified GPU compute through the same renderer. Software rendering ruled out by evidence.
- [ ] **DONE-05** x86 gates G0–G6 met on the frozen matrix; baseline/v2/v3 profiles complete with independent-reference proof; real parallel vCPUs with TSO litmus clean; unsupported extensions unadvertised.
- [ ] **DONE-06** Display/input, storage/network, sound, shares and tools work through daily journeys.
- [ ] **DONE-07** Requested policy equals actual configuration.
- [ ] **DONE-08** Cold snapshots, clone/export/import, backup restore, upgrade and interruption recovery preserve data and identity; live-save explicitly unavailable unless proven.
- [ ] **DONE-09** Performance budgets frozen and met per host/guest/profile; translated CPU reported separately.
- [ ] **DONE-10** Sustained campaigns, failure injection, multi-VM pressure and signed/notarized validation pass with retained evidence.
- [ ] **DONE-11** Retirement inventory resolved for release-critical rows.
- [ ] **DONE-12** Container product gates retained.
- [ ] **DONE-13** Public claims match the qualified product; support can reproduce failures.
- [ ] **DONE-14** This is the only active plan; work updates it in place.

## Appendix A — x86 engine v2 design notes

These notes make D02–D06, D09, D10 and D12 concrete enough to implement and review. They are design intent, not measured results; A02.5 may amend ordering with data and any amendment is recorded in the receipt.

### A.1 Address spaces and memory layout (D02)

```text
host reservation (one mmap, PROT_NONE):   [base, base + 2^gpaBits)
  RAM ranges           → PROT_READ|PROT_WRITE, MAP_FIXED over the reservation
  firmware ROM         → PROT_READ (writes fault → device path rejects)
  MMIO / PCI BARs      → left PROT_NONE (accesses fault → device dispatch)
  host-visible blobs   → MAP_FIXED of worker-exported memory (A13.2), PROT per blob
  guest pages holding translated code → PROT_READ (A04.3), restored on write fault
```

- `gpaBits` is fixed by `dory.pc@1` (currently 36–40 bits depending on admitted RAM plus the BAR aperture); the reservation is virtual only and costs no RSS.
- Guest physical → host: `host = base + gpa`. The interpreter and device models use the same base through `DoryX86MmapMemory`'s thin view; device DMA calls `invalidateCodePage(gpa)` after writes into RAM.
- Faults on `PROT_NONE`/`PROT_READ` ranges are caught by a Mach exception port (preferred, per-task) or `SIGSEGV`/`SIGBUS` handlers installed by `DoryJITRuntimeC`. The handler identifies the vCPU from the faulting thread, decodes intent from side-table metadata (A05.4), and either performs the MMIO access through the device path, invalidates code translations, or raises the architectural fault.

### A.2 Inline TLB (D03)

Per-vCPU, per-access-kind (read, write, execute) direct-mapped arrays; sizes are tunables in the plan (defaults 1024 entries × 3, 16 bytes each = 48 KiB per vCPU).

```text
entry { tag: UInt64      // vpn << 12 | asidGeneration (low bits); mismatch on either → miss
        delta: Int64  }  // host address = va + delta  (delta = base + gpa - va, page-aligned)
```

Fast path emitted for a load of `[va]` with width w:

```text
lsr   x16, va, #12          ; vpn
and   x16, x16, #(N-1)      ; index
add   x16, x_tlb, x16, lsl #4
ldp   x17, x_delta, [x16]   ; tag, delta
eor   x17, x17, va_tag      ; compare tag incl. ASID gen
cbnz  x17, slow_path
ldr   w_dst, [va, x_delta]  ; actual access (acquire form when SMP, A.5)
```

- Page-crossing accesses (unaligned, spanning two pages) go to the slow path, which performs two translations and either a split access or the architecturally correct fault ordering.
- Slow path (C): consult the software page walker exported from Swift (`@_cdecl("dory_x86_walk")`) with the existing `DoryX86Paging` semantics; on success fill the entry; on fault, raise `#PF` with error code and CR2 through the same interrupt-delivery path the interpreter uses.
- Invalidation: `MOV CR3` bumps the vCPU's ASID generation (cheap; PCID-aware when enabled); `INVLPG` clears one index in all three arrays; `INVPCID`/global flushes bump generation; writes to a guest page that is a page-table page of a cached entry (tracked by a per-page "is-PT" bitmap set by the walker) flush the arrays. Permission changes (CR0.WP, CR4.SMEP/SMAP, EFER.NXE) bump the generation.
- Execute TLB is consulted only at block entry and on page crossing in the translator, not per instruction.

### A.3 Register convention (D06)

| ARM64 | Use | Notes |
|---|---|---|
| `x0–x15` | RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI, R8–R15 | Pinned across blocks; spilled only around helper calls that need arguments (shims copy to context) |
| `x16, x17` | scratch | IP0/IP1, clobbered by helpers |
| `x18` | reserved (platform) | never used |
| `x19` | flags: last result | lazy flags state part 1 |
| `x20` | flags: operand/aux | lazy flags state part 2 |
| `x21` | flags: op kind + size | small integer |
| `x22` | TLB base (per vCPU) | context-derived |
| `x23` | guest RIP (virtual) | updated at block boundaries and before side exits |
| `x24` | pending-work flag address or cached value | interrupt/exit checks |
| `x25, x26` | tier temporaries | reserved for tier-2 |
| `x27` | memory base (`base`) | for physical accesses (page walks, device paths) |
| `x28` | vCPU context pointer | fixed |
| `x29, x30` | frame/link | dispatcher and helper calls |
| `q0–q15` | XMM0–XMM15 | pinned when the block uses SIMD; else lazily loaded |
| `q16–q31` | YMM upper halves / scratch | tier-2 may pin |

Helper shims: a helper declares which guest registers it reads/writes; the shim stores only those to the context and reloads them after. Flag state is materialized to `EFLAGS` in context only when the helper needs it.

### A.4 Lazy flags (D06)

Flag state = `(kind, size, result, src1/aux)`. Kinds: `add, sub, logic, inc, dec, shl, shr, sar, rol, ror, rcl, rcr, mul, imul, adc, sbb, bt, neg, none(explicit EFLAGS)`. Materialization rules per bit (CF, PF, AF, ZF, SF, OF) are table-driven and shared between interpreter (for testing) and emitter.

Fusion: `CMP/TEST/SUB/AND/ADD/OR/XOR … → Jcc/SETcc/CMOVcc` within a block emits `SUBS/ANDS/ADDS` and uses ARM condition codes directly; x86 CF = !ARM C for subtraction; `JP/JNP`, `JBE`-after-`ADD` and other non-direct mappings materialize the specific bit only. `PUSHF/LAHF/SAHF/POPF`, interrupt entry, `IRET`, and helper boundaries materialize the full register.

### A.5 Memory ordering (D09)

| Plan | Loads | Stores | Locked RMW | Fences |
|---|---|---|---|---|
| 1 vCPU | `LDR` | `STR` | `LDXR/STXR` loop or LSE | `MFENCE → DMB ISH`; `LFENCE/SFENCE → nop`/`DMB ISHST` |
| ≥ 2 vCPU | `LDAPR` (fallback `LDAR` on hosts without RCpc) | `STLR` | `LDAXR/STLXR` or LSE with `AL` semantics | `MFENCE → DMB ISH` |

Rationale: x86 TSO allows only store→load reordering to a different address. Acquire loads + release stores forbid load→load, store→store and load→store reordering, and permit store→load through the store buffer, matching TSO closely enough for the litmus suite in A06.2. The cost is measured; the result and the litmus outcomes are recorded before the mode is frozen. Unaligned locked operations that cross a cache line take a global split-lock path (rare, correct).

### A.6 Translation cache, chaining and IBTC (D05)

- Block key: `(physical RIP, mode, CPL, paging, SS/CS attributes that affect decoding)`. Translating from physical addresses lets translations survive CR3 switches; the execute TLB validates the virtual mapping at block entry.
- Block ends at: unconditional/conditional/indirect branch, `RET`, `CALL`, `SYSCALL`/`INT`/`IRET`, serializing or mode-changing instructions, page boundary, or a large instruction budget.
- Direct chaining: each block exit has a patch slot (`B target` initially to a stub). First execution of the stub looks up/translates the target, patches the slot (with `sys_icache_invalidate` for the slot), and jumps. Unchaining: when a block is invalidated, every predecessor slot recorded in its `incoming` list is re-pointed to the stub.
- Indirect branches: per-vCPU IBTC with 4096 entries `{guestRIP → hostAddr, generation}` consulted inline; miss falls to the C dispatcher which resolves and inserts. `RET` first checks a shadow return stack (guest RSP-tagged) then the IBTC.
- Dispatcher (C): open-addressed hash on the block key; translation requests are made to Swift through a single `dory_x86_translate(ctx, key) → hostAddr` entry; the Swift side owns emission and metadata.
- Code cache: single `MAP_JIT` region per machine, bump-allocated in generations; on exhaustion, a full flush of the oldest generation with unchaining (bounded pause, measured), or a whole flush if fragmentation dominates. Ceiling from the plan (128 MiB default).
- Pending-work check: `LDRB w, [x28, #pendingWork]; CBNZ w, exit_to_dispatcher` at block entry and at backward branches; this is the only place interrupts, deadline cancellation, and tier-up requests are honored.

### A.7 Self-modifying code (D04)

1. When a block is translated from guest physical page P, the runtime marks P as code-bearing (per-page bitmap) and `mprotect`s its host page `PROT_READ`.
2. A guest store to P faults; the handler: records the write, invalidates all blocks intersecting P (via a per-page block list), unchains predecessors, restores `PROT_READ|WRITE`, clears the bitmap, and resumes so the store re-executes. If the faulting instruction itself is in P (true SMC of the running block), resume in the interpreter for that instruction.
3. Device DMA and blob writes call `invalidateCodePage(gpa)` explicitly (no protection needed since they are host writes).
4. Pages that thrash (data and code mixed) are detected by a counter and translated in "write-checked" mode: blocks on that page begin with a cheap byte-hash check instead of protection (bounded fallback, measured).

### A.8 Precise state and deoptimization (A05.4)

Each translated block carries a side table: for every guest instruction, `(hostOffsetStart, guestRIP, flagsKindAtEntry, dirtyRegistersMask)`. On a fault or asynchronous exit at host PC `h`, the runtime binary-searches the table, writes back RIP and flag state, and either delivers the exception (interrupt-delivery code unchanged) or hands the single instruction to the interpreter (`DoryX86Interpreter.step`) and re-enters the cache. Because pinned registers already hold guest state, no per-instruction spills are needed. Tier-2 regions carry the same tables per instruction boundary; optimizations may not move guest-visible side effects across boundaries unless they are provably invisible (no fault, no memory, no flags consumer).

### A.9 Interrupts, halts and time (D10)

- `HLT`: exit to dispatcher; the vCPU thread waits on its condition variable with a timeout equal to the nearest timer deadline (APIC timer, HPET, PIT). Wake-ups set `pendingWork`.
- Device → vCPU: device thread sets pending bits under the APIC lock, then `pendingWork = 1`, then signals if halted. The running vCPU sees it at the next block entry/backward branch.
- IPIs: same path; INIT/SIPI drive AP state machine in the target thread.
- TSC: `mrs x, CNTVCT_EL0` scaled by a per-machine multiplier to the advertised frequency; `RDTSCP` adds the vCPU id from context. Offsets preserved across suspend/restore.

### A.10 Tiering

- Tier-1 compiles everything on first execution (fast compiler, no IR passes beyond fusion).
- Tier-2 compiles hot regions asynchronously on a compiler thread using tier-1 counters; publication swaps the chain slot atomically; tier-2 failure falls back to tier-1 silently and records the reason.
- Interpreter executes: single instructions after faults/deopts, instructions the tiers decline (explicitly listed in the A03 ledger), and differential-test runs.

### A.11 Test strategy specific to the engine

- **Differential harness**: same vector corpus → interpreter, tier-1, tier-2, oracle (A10); compare registers, defined flags, memory diffs, fault kind/code/CR2.
- **Litmus**: store buffering, message passing, IRIW, LB, CoRR, atomics visibility on 2/4 vCPUs (A06.2).
- **SMC corpus**: kernel `alternatives`, GRUB relocation, in-guest JITs (LuaJIT/V8 in userspace), self-patching test kernel.
- **Fault corpus**: RMW at each access, cross-page, MMIO in the middle of REP, page permission changes mid-block.
- **Cache-management stress**: code-cache exhaustion, unchain storms, CR3 churn.
- **Fuzzing**: decoder (A10.4), TLB slow path, dispatcher hash.

## Appendix B — GPU presentation path notes (D07, D08)

### B.1 Frame flow (both ISAs)

```text
guest Mesa (Venus / Zink or VirGL2)
  → virtio-gpu commands (blob resources, host-visible when mapped)   [MMIO on ARM, PCI on PC]
  → VirtioGPU core (transport-independent, A12.1) → worker command lane (XPC, bounded, generational)
  → DoryRendererWorker.xpc: virglrenderer(+patches) → MoltenVK / ANGLE → Metal
  → scanout resource backed by MTLSharedTexture/IOSurface exported to the runner
  → runner: RESOURCE_FLUSH = fence + damage; publish (texture, fence, generation) to the app view
  → app: CAMetalLayer draws the shared texture; retires it when the command buffer completes
```

Rules: no CPU pixel copy in the accelerated path; every published frame carries `(workerGeneration, machineGeneration, fenceId)`; a consumer never retires a texture before the producer fence and the consumer command buffer both complete; software scanout is a separate path used only for `off` and recovery.

### B.2 Host-visible memory

- ARM: worker-exported memory mapped into the DAX window with `hv_vm_map` (exists).
- PC: same exported memory mapped `MAP_FIXED` into the A.1 reservation at the BAR offset; inline TLB and code translations covering the range invalidated on map/unmap (A13.2).
- Both: mappings bound to worker generation; worker death unmaps (`PROT_NONE`) before any replacement can reuse the range; guest sees a device reset.

### B.3 Decision experiment (A14.1) inputs

Workload set frozen with digests: GNOME Shell (Mutter) session, GTK4 demo suite, Firefox with a WebGL scene, glmark2 (selected scenes), a Qt 6 application, a video player. Measures: visual defect list (screenshots diffed against a lavapipe reference for correctness only), fps, p95 frame interval, worker CPU time, RSS, GL version and extension list, MoltenVK feature gaps encountered by Zink (geometry shaders, transform feedback, `VK_EXT_robustness2`, texture formats). Same host, same guest, same kernel, back to back, three runs each.

## Appendix C — macOS cell notes (D14)

- Install: `VZMacOSRestoreImage` (latest supported or user IPSW), `VZMacOSConfigurationRequirements` for minimum CPU/RAM, `VZMacHardwareModel` and `VZMacMachineIdentifier` persisted as one bundle with `VZMacAuxiliaryStorage`.
- Graphics: `VZMacGraphicsDeviceConfiguration` with one `VZMacGraphicsDisplayConfiguration`; the guest sees Apple's paravirtual GPU with real Metal. Dory's job is to prove it in-guest (A22.4) and keep the window/scale path correct, not to build a renderer.
- Shares: `VZVirtioFileSystemDeviceConfiguration` + `VZSharedDirectory`/`VZMultipleDirectoryShare`; guest mounts via `mount_virtiofs`.
- Save/restore: `saveMachineStateTo`/`restoreMachineStateFrom` (macOS 14+) wrapped in the A21.4 manifest; incompatible saved state offers cold boot.
- Known platform limits to state, not hide: one display, no Rosetta in macOS guests, no nested virtualization, Setup Assistant is interactive, bridged networking needs entitlement.

## Agent assignment template

> Execute **[Axx.n — title]** from PLAN.md on **[revision]**. Read its starting point, action, why and check, and the architecture decisions it touches (**[Dnn]**). Own **[files/modules]**; coordinate **[shared files]** with **[owner/reviewer]**. Prerequisites: **[IDs, candidate, fixtures]**. Preserve **[behavior/evidence]**. Implement through **[production entrypoint]**, add the smallest meaningful regression, run **[focused command]** and **[guest/failure workload]**. Use disposable owned resources. Record the standard receipt with skips and limits. Commit focused changes and update the step in place. Do not widen claims, disable authority, use software graphics silently, or mark missing physical evidence passed.

### The next useful assignments

1. **A02.1** — bisect and fix the EFI-runtime/KASLR triple fault; restore G0. *(x86 owner)*
2. **A04.1–A04.2** — flat guest-physical reservation and inline TLB with C slow path; measure with A02.2 counters. *(x86 owner, can start in parallel with A02.1 on the interpreter path)*
3. **A11.1–A11.3** — shared-texture scanout export and fence-gated presentation on ARM; then **A11.4** first verified frame. *(GPU owner)*
4. **A18.1** — reclassify `DoryNativeHVArm64` as tooling; **A18.2** cancel-point stress. *(ARM owner)*
5. **A21.1** — Mac install through the installed daemon; **A22.4** guest Metal probe inside the guest. *(Mac owner)*
6. **A01.2, A01.5, A00.3** — re-point the evidence audit at this plan, fresh coherent candidate with production component root, wrong-team signed case. *(release owner)*
7. **A14.1** — prepare the GL strategy experiment fixtures (GNOME/GTK4/Firefox/glmark2/Qt on Ubuntu ARM64) so it can run as soon as A11.3 lands.

These are assignments, not claims that anything ran during this rewrite.
