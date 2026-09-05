# Dory virtualization: implementation review and delivery checklist

**Reviewed:** 2026-09-03; implementation verification and plan status sharpened 2026-09-04.

**Original review baseline:** commit `78375a12e`, including the working-tree changes present at the start of that review. **Completed P00 baseline:** source `a65187e13`, with exact phase-entry state, focused fixes and retained evidence in the [P00 receipt](docs/virtualization/p00-baseline-2026-09-04.json).

**Purpose:** the single implementation plan for the team. This replaces the previous project roadmaps, architecture proposals, research plans, and narrative progress ledgers.

**Current work:** reconcile implemented behavior with the roadmap, remove demonstrated dead code and tests that only assert source wording, and fix connected runtime defects. Use GPT-5.5 agents with disjoint file ownership for implementation and a coordinating integration review. Physical guest and release qualification remain open.

**Jump to:** [current audit](#2-what-exists-today-evidence-based-audit) · [code removal programme](#4-remove-replace-retain-the-code-cleanup-programme) · [phase order and owners](#5-delivery-order-and-team-ownership) · [module/interface map](#6-concrete-module-and-interface-work-map) · [final completion checklist](#10-final-completion-checklist).

## 1. The outcome we are building

Build a Dory-owned virtual-machine product on **Apple Silicon macOS hosts**, with these three guest targets:

| Guest | CPU execution | Machine and boot | Accelerated graphics | Performance promise to qualify |
|---|---|---|---|---|
| Linux ARM64 | Hypervisor.framework through Dory's native VMM | DoryARMVirt; direct kernel and UEFI/installer boot | Dory virtio-gpu, isolated renderer, Metal presentation | Near-native CPU execution and responsive end-to-end workloads |
| Linux x86_64 | Dory x86-to-ARM64 full-system translation | DoryPC; diagnostic PVH boot and production UEFI/installer boot | Same renderer architecture, connected through the PC device transports | Competitive translated performance, measured separately from native execution |
| macOS ARM64 | Apple's Virtualization.framework | Apple's supported Mac platform, IPSW restore and persistent Mac identity | Apple's paravirtualized Mac graphics and guest Metal | Near-native CPU execution and a qualified accelerated Mac desktop |

**GPU acceleration is required, including Docker containers.** Deliver Linux VM OpenGL/Vulkan, macOS guest Metal and container GPU compute. P06 now includes the container worker/device/driver integration and P08 covers guest Metal; none may be replaced by a permanent unsupported flag or a software-rendering pass.

**macOS x86_64, Intel hosts, Windows guests, other host operating systems, GPU passthrough, and a replacement for Apple's Mac platform are outside this delivery programme.** Keep the minimum schema compatibility needed to explain old definitions, but do not implement or continue planning those targets. Windows is a later programme after these three cells pass their gates; do not add Windows-only device or ISA work speculatively.

“Own our version of QEMU” means Dory owns the VMM, execution integration, x86 translator, machine models, devices, orchestration, product experience, and release. It does not mean copying QEMU or rewriting every useful dependency. Keep appropriately licensed EDK II, Linux, Mesa, virglrenderer, ANGLE, MoltenVK, and Apple frameworks where they serve a clear purpose. Owning more code creates an opportunity to optimize; it is not evidence that it will outperform mature alternatives.

### 1.1 Platform limits that determine the design

- ARM64 Linux can execute its ARM64 instructions on Apple Silicon with hardware virtualization. macOS ARM64 should use Apple's supported Mac virtualization platform and graphics device. Apple's documented flow provides IPSW installation, persistent Mac platform data, and accelerated guest Metal. [Apple's virtualization overview and examples](https://developer.apple.com/videos/play/wwdc2022/10002/).
- x86_64 Linux requires instruction translation on ARM64. Do not promise arbitrary x86 workloads at native x86 speed. Application translation inside an ARM64 guest is a different product capability from booting an x86_64 kernel and installer.
- Accelerated virtual graphics are not physical GPU passthrough or universal API parity. Linux and macOS have different graphics implementations and must have separate capability and performance evidence.
- Apple's documented built-in Linux virtio graphics path is a display path; it does not establish that Dory's custom Linux 3D pipeline works. The chosen target for Linux remains Dory's custom VMM and GPU devices. Investigating new Apple custom-device APIs must not block that work or become another parallel production engine.
- Venus has host-memory and synchronization assumptions that require explicit implementation and validation on macOS; a Vulkan version string is insufficient. [Mesa Venus requirements](https://docs.mesa3d.org/drivers/venus.html).
- Zink has feature-specific Vulkan requirements. It is an optional route to OpenGL, not a reason to discard the existing working VirGL2/ANGLE route. [Mesa Zink requirements](https://docs.mesa3d.org/drivers/zink.html).

Do not equate “perfectly well” with every Linux distribution, every application, and every physical peripheral. Completion means the declared support matrix passes the correctness, installation, acceleration, everyday-use, recovery, security, and performance gates below, with explicit limitations for capabilities the platform cannot supply.

### 1.2 How to use this checklist

1. Assign each phase a directly responsible owner and a reviewer from the adjacent subsystem.
2. Create team issues using the task IDs below. Issues track work; this file retains the architectural decisions and completion gates.
3. A checkbox closes only after the code is integrated into the real app/daemon/runner path, its required tests pass, and its evidence is linked. A type, stub, fixture, decoder match, or passing mock test alone does not complete a runtime feature.
4. Record evidence inline under the task or in a versioned machine-readable receipt. Do not create another parallel roadmap or append an unstructured progress journal.
5. Newly proposed files below are **proposed**, not claims that those files exist. Prefer extending an existing implementation when it already owns the responsibility.
6. Phase ordering expresses dependencies, not a waterfall. macOS, CPU correctness, GPU, and media work can proceed independently where shown.
7. All future-work checkboxes start open. Existing work is described in the audit; it is not automatically release-qualified.

## 2. What exists today: evidence-based audit

This is a source review and an inspection of retained engineering results. It is not a new physical guest campaign. Paths below are relative to the repository; core module names resolve under `dory-core-swift/Sources/`, and raw-HV/runner modules under `Packages/ContainerizationEngine/Sources/`.

### 2.1 Where the product actually stands

| Area | Current implementation/evidence | Next unmet boundary |
|---|---|---|
| Linux ARM64 | `DoryHV/Machine.swift` is the production raw-HV execution owner, with per-vCPU execution, devices, direct boot and desktop integration. | Qualify ordinary UEFI installers and installed-disk lifecycle; consolidate ownership without replacing the working runtime. |
| Linux x86_64 | DoryDBT/DoryPC has a checked PVH loader, conservative versioned CPU profiles, interpreter/JIT differential checks and retained musl, glibc, systemd and bounded I/O workload successes. See P02. | Remaining architectural faults/ISA coverage, independent physical-x86 reference, ordinary UEFI installation, graphics and useful translated performance. It is beyond early kernel bring-up but is not a qualified general distro VM. |
| x86 throughput | `DoryPCDirectKernelMachine` runs bounded serialized vCPU slices. The source-62 musl/glibc diagnostic campaigns took roughly 522/563 host seconds each. | These mixed boot/workload durations are engineering observations, not benchmarks or near-native performance. Real parallel vCPU execution and measured JIT improvements remain P07. |
| Native abstraction | `DoryNativeHVArm64` is used by probes; `run(until:)` still rejects non-nil deadlines. | It does not replace `DoryHV/Machine`. Narrow or adapt the existing contract only where a real production caller needs it; avoid creating a second execution owner. |
| Linux graphics | ARM raw-HV has worker-isolated VirGL2/ANGLE/Metal and Venus/MoltenVK code, guest builds and a pinned production tuple. PC production rejects accelerated graphics. | Shared asynchronous resource/fence/blob/cursor semantics, PC worker wiring, x86 guest artifacts and real stock-guest desktop evidence. |
| Docker GPU | GPU configuration/kernel selection and Docker device-request normalization exist. The 2026-09-05 implementation connects signed daemon bootstrap admission to an engine worker-backed GPU; integration verification and real guest compute qualification are in progress. | Verify the new daemon/engine connection, package and qualify guest DRM/ICD readiness, and bind Docker device authorization to that readiness. Resolve the 16 KiB GPU / 4 KiB FEX conflict before claiming combined support. |
| macOS ARM64 | VZMac has real bundle, install, runtime, display and daemon integration. | Install-to-first-boot event ordering is fixed with focused coverage; backend saved-state continuation, effective device policy and physical install/Metal/recovery qualification remain P08. |
| Control plane | P01 retains integrated plan, resource, lifecycle and compound-operation coverage. | Do not redo the completed resolver work. Audit runtime consumption and recovery at each backend; a control-plane pass does not prove the guest works. |
| Devices/sharing | Both raw and portable virtio implementations exist. Filesystem workers and path/resource authority are valuable production boundaries. | Converge proven device behavior across MMIO/PCI. Zero-TTL host sharing remains the correct baseline until coherence exists. |
| Release | P00/P01 and bounded P02 engineering receipts exist; none of the three product cells is release-qualified. | Final public toolchain/host matrix, installer/desktop/recovery/security/performance campaigns and signed candidate qualification. |

### 2.2 Review findings and disposition

| ID | Finding | Action / status |
|---|---|---|
| F01 | A probe-only native engine rejects deadlines while production uses another execution owner. | Still open: P03-01/03. Do not route production through the probe as a cosmetic cleanup. |
| F02 | x86 vCPUs execute serially; CPU and device state are not qualified for parallel execution. | Still open: P07. Retain deterministic UP bring-up and report translation truthfully. |
| F03–F05 | The original audit found false Xen services, ELF address masking and local-image/fixed-address bring-up assumptions. | The P02-01–07 replacements and bounded userspace results are already recorded. Do not assign these as untouched work. Remaining CPU correctness is P02-11–16/20. |
| F06–F07 | PC acceleration is rejected; shared GPU semantics do not yet establish parity with the ARM worker path. | P04/P06 remain open. The existing renderer facade is an integration asset, not evidence of an implemented PC desktop; connect it to verified production authority or replace it after parity. |
| F08 | Guest graphics inputs and synchronization policy are tied to ARM managed artifacts. | P06 must separate architecture/profile qualification from host renderer identity and qualify stock media explicitly. |
| F09 | At review entry, installation published `.stopped` and the desktop exited before first boot. | Fixed in this review using the production install/start orchestration: installer stops no longer finish the desktop; postboot stops still do. Seven focused adapter/lifecycle tests pass. Physical IPSW installation remains P08 qualification. |
| F10 | Mac saved-state execution and daemon transaction authority still need backend integration; strict mutable-artifact checks deliberately prevent unsafe continuation. | P08-04–07. Preserve containment and reject pseudo-saves; do not confuse P01 admission coverage with physical suspend/restore. |
| F11 | Mac policy must be checked in the constructed VZ devices, not only in the resolved plan. | P08-10–16: inspect actual audio/network/clipboard/share configuration and disabled integrations. Also reconcile Mac `.virtualDisk` admission: the descriptor/resolved plan advertise it, but the backend validator accepts only `.macOSRestoreImage`; the verified restore-install path does not close installed-disk lifecycle support. |
| F12 | Host-share metadata caching is disabled and PC sharing lacks the full notification contract. | Keep correct zero-TTL behavior; optimize after P11 coherence evidence. |
| F13 | Source-string tests still assert implementation spelling or historical security patches without running behavior. | Delete demonstrated redundant shape checks; retain ABI, malformed-input, resource-containment and observable lifecycle coverage. |
| F14 | Parallel device/runtime implementations and disconnected facades add maintenance without production benefit. | Delete only after checking production consumers and coverage; keep isolation, generation, lease and persistence boundaries. |
| F15 | The plan's opening audit and first assignments describe closed work, while long chronological paragraphs bury current blockers. | Replace stale status and assignments; keep task IDs and linked raw evidence. Update status at the affected phase instead of appending another run narrative. |

### 2.3 Evidence limits

- The [P00 baseline](docs/virtualization/p00-baseline-2026-09-04.json) and [P01 review](docs/virtualization/p01-control-plane-review-2026-09-03.json) describe their own frozen sources and test exclusions. Their counts are not fresh test counts for this checkout.
- The [source-62 profile probe validation](docs/virtualization/evidence/p02-correctness-2026-09-04/selected-paging-profile-probes-through-run-62-validation.json) records seven workloads each for two kernels/userspaces and host-observed ACPI S5. The [systemd validation](docs/virtualization/evidence/p02-correctness-2026-09-04/systemd-kernel-b-probe-2-validation.json) records eight workloads including PID 1 service supervision. These are pinned diagnostic environments, not installed distributions.
- The [bounded stress closure](docs/virtualization/evidence/p02-correctness-2026-09-04/p02-25-stability-closure-through-io3.json) uses a synthetic block file and isolated Ethernet peer. It proves the recorded flush/reopen and frame contracts, not physical storage durability, host TCP/IP, SMP or long soak.
- The earlier ARM integer-loop receipt reports about 95.99% of host-native throughput on one M2 Pro. A small loop cannot establish whole-system Linux performance. Historical graphics observations and firmware scenario definitions also cannot qualify an altered candidate.
- Mac restore-image metadata discovery is not installation. Static decoder coverage is not executed instruction semantics. Interpreter/JIT agreement is not an independent architectural reference.

### 2.4 Current cleanup verification

The current macOS fix adds a production-used install/start lifecycle seam; synchronous and duplicate installer stops no longer terminate the desktop before first boot, while start failures and real postboot stops retain their termination behavior. `DoryVZMacAdapterTests` passes 7 XCTest cases from a fresh task-specific SwiftPM build using the local RC Xcode, with zero failures. Full physical install/Metal qualification is still open.

The attempted saved-state admission-only change was rejected during integration review: accepting the daemon path while emitting the old JSON pseudo-payload would not establish restorable memory. F10 stays open and the path behavior remains unchanged.

Historical evidence was inspected, with 11 referenced artifact hashes rechecked and matching. No fresh guest boot, GPU campaign, physical reference, app release build or notarized qualification is implied. Historical source manifests and receipts remain unchanged. **GPU scope correction:** the preliminary PC-facade and container-option removals were restored after the user confirmed GPU support for containers as well as VMs. The existing GPU authority, scanout bridge, generation/lifetime tests, kernel selection and configuration are retained as inputs to the required P06 integration. The working ARM renderer was never removed. Passing tests of the preliminary deletion do not qualify GPU functionality; final verification below refers to the retained implementation.

Script cleanup removes the Intel-host workflow/readiness branch, the Dockerfile package-name test, AppStore prose assertions and duplicated USB method-spelling checks. Artifact, entitlement, digest-pinning and negative-input checks remain. Current readiness (4) and container-performance (3) tests, security contracts, shell syntax and release workflow actionlint pass. The linter configuration now includes the actual `benchmark`, `sonoma` and `lan` runner labels.

The app/test bundle builds with `xcodebuild build-for-testing` in isolated derived data. The earlier app test execution failed at LaunchServices; no passing app runtime tests are claimed. The final retained GPU/display/USB slice passes 90 Swift Testing cases in 7 suites, including worker authority, scanout lifetime and USB hardening. Final core policy/backend/ISO verification passes 105 tests with 4 opt-in media tests skipped and zero failures; x86 differential suites pass 16 tests, and Mac adapter/lifecycle coverage passes 7 tests. The x86 test crash was reproduced as stack exhaustion and fixed by separating synthetic perturbation work from the decode call frame; all regression assertions remain, and production decoder stack pressure is not claimed resolved. No-QEMU artifact/source gates (4 tests) and the gvproxy switch gate (2 tests) also pass.

### 2.5 Active implementation, 2026-09-05

A [fresh macOS 26.6.2 development installation](docs/virtualization/evidence/p07-macos-2026-09-05/development-context.json) completes through Apple VZ from the official restore image and boots to the graphical welcome/language screen. Pointer and keyboard input were observed through the VM view. The user completed setup and reached the desktop. Normal qualifier close saved Apple VM state and a new process restored the desktop. After clean shutdown, increasing resources from 2 CPUs / 4 GiB to 4 CPUs / 8 GiB made responsiveness noticeably faster according to the user. A [guest Metal compute smoke](docs/virtualization/evidence/p07-macos-2026-09-05/macos-metal-observation.json) completed on Apple Paravirtual device and verified all 1,048,576 values. This private 80-GiB sparse-disk VM proves development install, saved-state continuation and one Metal workload; production MachineManager lifecycle and sustained graphics qualification remain open.

GPT-5.5 implementation assignments cover container GPU worker/device wiring and guest packaging, effective macOS device policy, and PC renderer integration. The coordinator owns daemon GPU bootstrap admission and integration review. Container launch now stages a kernel-bound bootstrap from verified production renderer identity, passes fixed descriptor authority, validates CLI/descriptor agreement before spawning, and sanitizes the renderer process environment. The environment-only `DORYD_GPU_SUPPORTED` claim no longer grants GPU capability. The daemon configuration/process slice passes 69 XCTest cases with zero failures using the explicit Xcode RC toolchain. Engine product/target builds pass; the combined engine/worker/native PSCI suite passes 31 tests. The ARM Mesa runtime and initfs now build and pass their artifact verifiers through an isolated Docker endpoint; the [build receipt](docs/virtualization/evidence/p06-container-2026-09-05/builds.json) records exact digests. These checks do not close P06 or prove guest compute. The Mac device-policy slice passes 26 XCTest cases and 2 daemon-mapping Swift Testing cases: resolved network/audio/clipboard flags now reach actual VZ device construction. Managed directory authority, directional clipboard and unsupported networking still need implementation; physical disabled-device checks remain open. PC graphics, ordinary distro installation, saved-state continuation and physical qualification remain required.

The development checkpoint also replaces the managed Mac saved-state receipt with Apple save/restore calls, validates private state files through trusted directory descriptors, and covers failure ordering with 14 passing focused tests. F10 remains open: native Mac live-disk mutable provenance and physical continuation are unqualified. The suspend path now renews the production plan after helper exit and journals the refreshed plan; 24 existing saved-state/planning tests pass, but the new mutable-disk path still needs direct production-coordinator integration coverage. The PC worker attachment and daemon FD9 staging build with a separate VirGL2 capability profile; 39 focused engine/worker/PC tests pass. Production acceleration remains unavailable until an actual immutable x86 kernel/Mesa boot artifact and matching packaged qualification are verified. Guest Vulkan packaging uses hash-verified Bookworm Vulkan 1.3 packages; provenance and shell checks pass, and both ARM Mesa/initfs builds now pass through a matching, Developer ID-signed temporary runner/worker bundle. Runtime GPU compute remains unqualified. A production daemon signature check incorrectly passed a static-code flag to the live-code API; the corrected call accepts the production daemon identity and rejects wrong-identifier and ad-hoc probes ([physical evidence](docs/virtualization/evidence/p06-container-2026-09-05/dynamic-code-validity-smoke.json)). The private renderer-identity entitlement is rejected before daemon startup on this host. A signed embedded-metadata probe succeeds; production carrier migration and actual GPU engine execution remain open. The ARM UEFI firmware bundle builds successfully; ordinary installer qualification remains open.

## 3. Architectural decisions: stop expanding the system in competing directions

### 3.1 One product composition

```text
App / CLI
    │ requests and observations
Daemon: definitions, operations, resource admission, durable state
    │ one immutable validated launch plan + granted resources
    ├── Linux ARM64 runner
    │       Dory native HV execution + DoryARMVirt + shared device cores
    ├── Linux x86_64 runner
    │       DoryDBT + DoryPC + the same shared device cores
    └── macOS ARM64 runner
            Dory VZMac adapter + Apple Mac platform and graphics

Linux device cores ── bounded contracts ── renderer worker / filesystem worker
Host services ── narrowly granted network, audio, camera and USB capabilities
```

The runner owns guest execution and volatile device state. The daemon owns policy and durable operations. Workers own the resources and parsers they isolate. The UI owns presentation and user intent. No second planner in a child process may quietly reinterpret the requested backend, media or capability tier.

### 3.2 Deliberate simplifications

- **Reuse the functioning native Linux runtime.** Do not replace it with a new engine just because a cleaner package exists. Extract or adapt responsibilities behind tested contracts.
- **One core per virtio device, two transports.** ARM MMIO and PC PCI can differ. Queue validation, device semantics and feature policy should converge.
- **One CPU interpreter as the x86 semantic reference.** Native JIT lowering must preserve those semantics. Do not implement separate undocumented behavior to make a specific kernel pass.
- **One Mac backend.** Preserve VZMac and isolate its Apple-specific identity/lifecycle. Do not build an Apple Silicon Mac machine emulator.
- **One durable VM definition, one resolved launch plan, one operation record.** Project UI and CLI models from these; do not repeatedly serialize equivalent state through layers without a trust or ownership reason.
- **One renderer capability profile per qualified composition.** Cryptographic binding is necessary; hardcoding every product to exactly one kernel and two capsets is not a permanent architecture.
- **Local restore before migration.** Complete crash-consistent snapshots, backup and compatible restore first. Live migration, portable RAM states and renderer-state migration are outside the initial finish line.
- **Raw sparse disks first.** Implement the formats the product promises. Add transactional import conversion for required external formats; avoid building a general-purpose disk tool suite before installation works.
- **No language rewrite.** Keep Swift orchestration and existing C/Rust boundaries. Move a measured hot loop to C or Rust only when profiling and a stable interface justify it.
- **No security shortcut disguised as simplification.** Keep descriptor containment, peer identity checks, resource budgets, snapshot quiescence and signing. Reduce redundant layers around these mechanisms rather than removing the mechanisms.

## 4. Remove, replace, retain: the code cleanup programme

This is the removal inventory. Status is governed by the current audit and affected phase: R01–R04 already have bounded P02 replacements; remaining rows are candidates, not blanket deletion instructions. For each removal, first identify call sites, persistent formats and replacement behavior; then remove the old path in the same integration change or an immediately following one. Do not keep indefinite fallback implementations.

| Priority / ID | Candidate | Action | Prerequisite and proof |
|---|---|---|---|
| Now / R01 | Kernel-address tracing and local-image assumptions in PC bring-up | Move useful trace facilities behind explicit diagnostic configuration; remove hardcoded kernel PCs and unconditional output | P02 pinned boot fixtures and structured failure traces reproduce failures |
| Now / R02 | Blanket Xen CPUID and successful unimplemented hypercalls | Remove impersonation/workarounds; support only a documented minimal PVH contract or a genuinely implemented explicit Xen profile | PVH entry without false capabilities; negative hypercall and memory-size tests |
| Now / R03 | ELF address masks and unqualified section loading | Replace with validated boot-format mapping and segment/zero-fill rules | Multiple kernels, malformed inputs, relocation/high-memory tests |
| Now / R04 | Tests that depend on local `/tmp` files or lack successful-boot assertions | Replace with assertions and explicit fixture availability; move manual experiments out of ordinary unit tests | Required integration job fails when its fixture is absent; optional local test reports skipped |
| Early / R05 | Source-text tests requiring QEMU policy or fixed prose headings | Delete those assertions after structured backend/capability/evidence checks exist | Old unsupported routes reject; release manifest and artifact audit still enforce the actual policy |
| Early / R06 | x86 macOS / Intel-host planning, UI options, components and production branches | Remove unreachable production options and build wiring; retain only explicit legacy-definition rejection where needed | Linux x86 guest support remains; importing an old definition is safe and intelligible |
| Early / R07 | Generic VZLinux/custom-VZ-GPU experiments competing with DoryARMVirt | Keep only a bounded reference/legacy compatibility adapter until migration is qualified; exclude experimental engines from normal resolution | Existing installed Linux users retain a tested migration/recovery path |
| Early / R08 | Duplicate native-HV CPU ownership in `DoryHV/Machine.swift` and `DoryNativeHVArm64` | Converge through an adapter or extraction; remove the redundant production candidate after parity | ARM direct and UEFI boot, stop/reset/suspend, interrupts and resource tests pass |
| Early / R09 | Duplicate old/new virtio devices | Select the mature behavior as reference, port into shared core, delete superseded core and adapters | Same device vectors and real Linux traces pass over MMIO and PCI |
| Early / R10 | In-process legacy renderer/executor in raw `VirtioGPU.swift` used by test fakes | Replace fakes with worker-channel test doubles; delete test-only production rendering branches | Worker protocol tests cover equivalent failure/fence/reset behavior; no real call sites remain |
| Early / R11 | Disconnected `DoryPCVirGLRendererAuthority` composition | Retain the existing authority, scanout bridge and resource/generation tests while P06 connects the required PC GPU path. Delete only after a shared replacement preserves behavior. | Real PC worker authority, asynchronous completion and accelerated guest output; a dead-code deletion cannot close the GPU requirement. |
| Early / R12 | Hardcoded dual-capset/kernel tuple policy | Replace with typed authenticated profiles with explicit guest synchronization requirements | Unsupported profile combinations still reject; no capability is advertised without implementation |
| Early / R13 | Monolithic `MachineManager.swift`, `DesktopMode.swift`, `Machine.swift` responsibilities | Extract operation-specific implementations and immutable projections while deleting duplicate logic | Behavioral tests stay at public operation boundaries; extraction does not add another coordinator chain |
| Early / R14 | Repeated little-endian/wire utility code and serialization wrappers | Share a small checked binary utility where behavior is identical; remove redundant codecs | Byte fixtures, bounds/overflow and backward-compatibility tests |
| Later / R15 | Legacy QEMU execution, image-helper, binfmt and control dependencies | Retire actual runtime dependencies and unused build paths based on call-site evidence; preserve standards-compatible transport implementations, truthful migration messages and attribution | No actual QEMU production dependency remains; package, process and linked-binary inventory checked; name-only references classified accurately |
| Later / R16 | Competing legacy and typed lifecycle models | Migrate existing definitions/operations once, then delete redundant planners, caches and state transitions | Interrupted migration/restart/rollback corpus passes without data loss |
| Later / R17 | Probe executables and one-off benchmark entrypoints in release package graph | Move to developer/test targets; retain focused reproducible qualification tooling | Shipping artifact inventory excludes probes; CI still has necessary tools |
| Later / R18 | Manually curated “pass” receipts, schema-only certification and obsolete evidence | Remove as authority; keep historical immutable inputs only where useful for regression | Candidate identity, actual commands/results and validated raw artifacts establish every pass |
| Later / R19 | Platform options that cannot be implemented with public macOS APIs | Remove dead UI toggles and false capability flags; report exact unsupported reason | Capabilities match built configuration on every supported host/guest tuple |
| Later / R20 | Optimizations without measured benefit or correct fallback | Remove or leave disabled behind internal experiments; retain only benchmarked wins | Correctness and p95/p99/resource results justify keeping each optimization |

**Retain deliberately:** renderer and filesystem process isolation; existing network and storage safety; launch-resource authority; durable migration and recovery journals; generation counters and lease revocation; signed component identity; guest permission controls; negative tests; ABI snapshots; the interpreter reference; useful user/container features. These solve concrete problems. A short forwarding file such as the renderer-contract re-export is not automatically overengineering; judge it by whether it provides a needed dependency boundary.

## 5. Delivery order and team ownership

| Phase | Deliverable | Primary owner | Dependencies |
|---|---|---|---|
| [P00](#phase-p00) | Reproducible baseline, scope and cleanup inventory | Technical lead + QA/release | None |
| [P01](#phase-p01) | Single definition, launch plan and operation ownership | Control-plane team | P00 |
| [P02](#phase-p02) | Correct x86 interpreter, PVH and first userspace boot | CPU + PC/firmware teams | P00; use P01 interfaces |
| [P03](#phase-p03) | ARM native/runtime consolidation and full boot contract | Native VMM + firmware team | P00/P01 |
| [P04](#phase-p04) | Common device correctness and both transports | Devices + storage/network teams | P01; overlaps P02/P03 |
| [P05](#phase-p05) | General Linux media, installer and installed-disk lifecycle | Firmware/media + guest team | P02/P03/P04 for each architecture |
| [P06](#phase-p06) | Shared Linux GPU implementation and x86 acceleration | Graphics + device + guest teams | P04; early ARM work starts immediately |
| [P07](#phase-p07) | x86 baseline JIT, memory model and SMP performance | CPU/compiler team | P02/P04 for JIT/TSO; P05/P06 for installed desktop profiling |
| [P08](#phase-p08) | Reliable macOS install, lifecycle and policy | macOS team | P00/P01; independent of x86/GPU work |
| [P09](#phase-p09) | Guest tools and complete desktop interaction | Desktop + guest + host integration | Running cells from P05/P06/P08 |
| [P10](#phase-p10) | Storage, snapshots, backup and recovery | Storage + control + runtime teams | Stable device/lifecycle contracts |
| [P11](#phase-p11) | Networking and host sharing qualification | Network + file-service teams | P04/P05/P08; can start early |
| [P12](#phase-p12) | UI/CLI/API consolidation and migration | App + daemon team | P01; integrates each cell incrementally |
| [P13](#phase-p13) | Security, components and supply-chain hardening | Security + release | Starts P00; gates all phases |
| [P14](#phase-p14) | Performance optimization and physical qualification | Performance + QA; subsystem owners fix failures | Correct end-to-end candidate cells |
| [P15](#phase-p15) | Release, upgrades, support and final deletions | Release + all owners | All applicable gates |

Critical paths: **ARM:** P00 → P01/P03/P04 → P05/P06 → P09–P14 → P15. **x86:** P00 → P02/P04 → P05/P06/P07 → P09–P14 → P15. **Mac:** P00/P01 → P08 → P09–P14 → P15. macOS and ARM progress must not wait for x86 optimizing-JIT work. A cell may have an earlier preview, but the full programme remains incomplete until all three requested cells qualify.

Staff by expertise, not package count. At minimum assign distinct accountability for CPU/DBT, native/firmware/devices, graphics/guest drivers, macOS, control/storage, desktop/guest tools, and qualification/security/release. People can cover multiple roles, but reviewers of CPU semantics, GPU fences, and durable-data changes need independent expertise. Do not reuse the old engineer-week estimates; estimate tasks after P00/P02/P06 reveal actual gaps and available team capacity.

<a id="phase-p00"></a>

## P00. Establish the baseline and stop creating contradictory work

**Deliverable:** one reproducible source baseline, one three-cell scope, a validated issue map, and a safe removal inventory.

- [x] **P00-01** Record the exact source commit plus current uncommitted changes, submodule/dependency revisions, selected Xcode/SDK, host OS/build, signing mode and guest artifact hashes. Reconcile the existing CPU work with its owner before rebasing or deleting anything.
- [x] **P00-02** Rebuild the Swift package test products from a clean task-specific build location; fix the missing/incompatible cached-test-product setup. Do not treat `--skip-build` discovery failure as a runtime failure or a test pass.
- [x] **P00-03** Run the appropriate existing package, app, Rust and script suites. Capture failures, skips and runtime; separate pre-existing failures from new regressions. Inspect test entrypoints before running destructive/clean-account campaigns.
- [x] **P00-04** Produce a real call graph for app/CLI → daemon → resolver → component acquisition → runner → CPU/machine/devices → guest readiness for each of the three cells. Mark code that has no production call site.
- [x] **P00-05** Freeze the initial host policy: Apple Silicon only; select a final public macOS/SDK minimum supported by required APIs. Keep beta-only evidence in its own experimental cell. Audit availability guards rather than assuming a successful build means runtime availability.
- [x] **P00-06** Define exact initial guest candidates: two distinct general-purpose Linux families for ARM64 and x86_64, a small reproducible diagnostic Linux fixture for each, and supported compatible macOS IPSW builds. Pin downloads by hash and record architecture, boot layout, guest kernel, libc and graphics stack.
- [x] **P00-07** Make a capability matrix for CPU, boot, disk, network, shares, graphics API, display, input, audio, clipboard, guest tools, suspend, snapshots and recovery. Give each cell `absent`, `implemented`, `integration-tested` or `release-qualified` status with an evidence pointer.
- [x] **P00-08** Inventory obsolete source against R01–R20: production call sites, feature flags, persistent identities, test-only usage and replacement owner. Start with false-success behavior and disconnected duplicate implementations.
- [x] **P00-09** Add behavior/structured-contract coverage for backend selection and qualification policy that the deleted documentation-only checks never proved. The obsolete dossier checker and public-document assertions were removed in this cleanup; retain existing runtime checks and close the behavioral coverage gaps explicitly.
- [x] **P00-10** Inspect `.github/workflows/intel-engine.yml`, guest QEMU-builder inputs, legacy binfmt handlers and no-QEMU debt entries. Separate x86 guest artifacts still needed from unsupported Intel-host or QEMU-runtime machinery.
- [x] **P00-11** Choose one issue label and evidence schema per subsystem; keep API/ABI decisions here. Keep unresolved interface proposals and decisions in this file, with linked team issues where useful. Do not create additional design/architecture documents.
- [x] **P00-12** Define performance workloads and provisional budgets before optimization. Freeze release budgets after baseline calibration and before testing the candidate. Record any later changes with rationale and requalify affected cells.

**Exit:** a new team member can build and identify the true implementation status without relying on old plans, local `/tmp` files or an engineer's private environment. No silent test skips in a required gate.

### P00 completion and reproducible entry point — 2026-09-04

P00's baseline is recorded at implementation commit `a65187e13`. The [receipt](docs/virtualization/p00-baseline-2026-09-04.json) binds phase-entry source `5fc049c139`, locks, host/signing facts, guest candidates, tests and exclusions. The current review permits independent ARM P03/P04 and Mac P08 progress alongside remaining x86 correctness work.

- [Call graph and R01–R20 inventory](docs/virtualization/evidence/p00-baseline-2026-09-04/callgraph-removal-inventory.json): 39 nodes and 44 source-anchored edges at that baseline. Use the current audit for subsequent removals.
- [Capability matrix](docs/virtualization/evidence/p00-baseline-2026-09-04/capability-matrix.json): 42 entries across three guest cells; none release-qualified. P02 subsequently advanced diagnostic x86 userspace, while general guest tools, installation and desktop qualification remain open.
- [Host policy](docs/virtualization/evidence/p00-baseline-2026-09-04/host-policy-performance.json): Apple Silicon and macOS 15.0 runtime floor for the three-cell product. Existing macOS 14 compatibility targets remain separate. Selected public build policy is Xcode 26.6 (17F113), SDK 26.5, and initial public testing on macOS 26.6.2 (25G83). These are retained policy inputs; this review does not newly verify those upstream versions. The local macOS 27 beta/Xcode 17F109 evidence is experimental. Minimum-host and final-toolchain physical coverage remain required.
- [Guest catalog](Config/DoryVirtualizationGuestCandidates.json): pinned Ubuntu/Fedora ARM64/x86_64 installer inputs, Alpine diagnostic inputs and a macOS IPSW candidate with artifact identities. Server media and metadata discovery do not establish installed desktops or Mac installation.

| Historical baseline result | Limit |
|---|---|
| Core broad run retained 1,101 XCTest and 1,159 Swift Testing results, including failures; affected suites later passed 182 XCTest + 46 Swift tests. | Read the receipt for exact source binding; not a fresh full-suite pass. |
| Container package: 1,202 tests in 141 suites passed from a fresh build. | No physical guest qualification implied. |
| App: 83 isolated client/transport tests passed. | Installed Dory was not stopped or replaced; original-identity/release qualification remains open. |
| Rust: 224 tests, formatting and strict Clippy passed. | Linux-only execution was not claimed. |
| Scripts: 28 offline entrypoints, 19 host/SDK methods and 15 fixture-preparer tests passed. | Required missing media fails closed; optional historical PVH absence was explicit. |

A clean checkout can build and run the baseline contract suites with the committed locks. Use Rust `1.95.0` from `rust-toolchain.toml`, Python 3.10 or newer, the protobuf `protoc` compiler (observed here: `libprotoc 33.0`), and the selected full Xcode on a supported build host. The final public toolchain is selected policy; this campaign's actual build receipts are explicitly RC/beta engineering evidence. The clone example assumes the reviewed commits have been shared; local review can use a clean detached worktree at the same commit. These commits have not been pushed by this task.

```sh
git clone https://github.com/Augani/dory.git Dory
cd Dory
git checkout "$(git log --diff-filter=A --format=%H -- docs/virtualization/p00-baseline-2026-09-04.json)"
export DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer
brew install protobuf
bash scripts/build-dory-ffi-xcframework.sh
p00_build_root="$(mktemp -d -t dory-p00-build)"
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 swift test --package-path dory-core-swift --scratch-path "$p00_build_root/core" --jobs 3 --no-parallel --filter 'DoryVirtualMachineBackendPlannerTests|VirtualMachineCapabilitiesTests|DoryVirtualMachineQualificationManifestTests|DoryResolvedMachinePlanTests'
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 swift test --package-path Packages/ContainerizationEngine --scratch-path "$p00_build_root/container" --jobs 3 --no-parallel
cargo test --manifest-path dory-core/Cargo.toml --workspace --locked
python3 .github/scripts/test-vz-platform-sdk.py --require-selected-sdk
python3 .github/scripts/test-release-host-policy.py
python3 scripts/test-prepare-virtualization-fixtures.py
```

The checkout command selects the commit that first added the P00 receipt, retaining both the implementation and its evidence; its exact implementation parent is recorded inside that receipt. The FFI builder regenerates ignored bindings/frameworks from committed Rust sources; do not copy an engineer's generated artifacts as a new source baseline. Keep each frozen source checkout paired with a unique SwiftPM scratch location. The core filter above is a reproducible contract entry point, not a replacement for the broader recorded suites. Release additionally requires `verify-release-host-policy.py` against the actual host; unit fixtures do not authorize it. App build/test commands, exact filters, source manifests, raw failure logs and isolated-host signing facts are retained in the linked P01 receipts. Inspect destructive entrypoints before selecting additional campaigns.

Fetch only explicitly selected guest inputs into a new cache. This command downloads the two small pinned diagnostic ISOs and derives bounded, verified kernel/initramfs files; it does not boot a guest. Add `--verify-only` to require cached input bytes without network access; missing or mismatched inputs fail.

```sh
p00_fixture_cache="$(mktemp -d -t dory-p00-fixtures)"
python3 scripts/prepare-virtualization-fixtures.py --id alpine-virt-3.24.1-arm64 --id alpine-virt-3.24.1-x86_64 --cache-directory "$p00_fixture_cache" --extract
```

**Issue/evidence decision:** every subsystem uses the common versioned [evidence envelope schema](Config/DoryVirtualizationEvidence.schema.json), with one canonical issue label: `subsystem:cpu`, `subsystem:native`, `subsystem:firmware`, `subsystem:devices`, `subsystem:graphics`, `subsystem:macos`, `subsystem:control`, `subsystem:storage`, `subsystem:network`, `subsystem:guest-tools`, or `subsystem:qualification`. The [11 subsystem envelopes](docs/virtualization/evidence/p00-baseline-2026-09-04/subsystem-evidence.json) bind source, host class, scope and hashed receipts; historical receipt formats remain immutable artifacts. Canonical cells are `linux-arm64-native`, `linux-x86_64-translated`, and `macos-arm64-vzmac`; legacy evidence aliases are mapped explicitly in the baseline index. Schema validity cannot promote a skipped/experimental result into release qualification. Keep unresolved API/ABI changes in the owning PLAN task; no separate architecture document or external issue was created.

**Performance decision:** the [provisional workload policy](docs/virtualization/evidence/p00-baseline-2026-09-04/host-policy-performance.json) defines 12 workloads, 25 metrics, resource profiles, measurement boundaries and sampling controls before optimization. No performance measurements or frozen release budgets are claimed. P14 must calibrate on the final physical matrix, commit numeric release bounds before candidate testing, and record/requalify any later changes.

<a id="phase-p01"></a>

## P01. One control plane and one launch composition

**Existing code to change:** `DoryOperations/DoryVirtualMachineDefinition.swift`, `DoryVirtualMachineBackendPlanner.swift`, `DoryVirtualMachineCapabilities.swift`, `DoryVirtualMachineQualificationManifest.swift`, `DorydKit/DoryResolvedMachinePlan.swift`, `DoryDaemonVirtualMachineLaunchPlanResolver.swift`, production planning/activation modules, `MachineManager.swift`, and their app/CLI projections.

- [x] **P01-01** Write the three-cell backend table as executable policy. Host ARM64 + Linux ARM64 → native DoryARMVirt; host ARM64 + Linux x86_64 → DoryPC/DBT; host ARM64 + macOS ARM64 → VZMac. Reject macOS x86_64, Intel hosts and unknown combinations before component download or disk mutation.
- [x] **P01-02** Distinguish requested architecture, detected media architecture, host architecture, CPU profile, machine ABI and execution tier. A template label or filename must not substitute for media inspection.
- [x] **P01-03** Make `DoryResolvedMachinePlan` the immutable launch input containing verified media/artifact references, guest resources, device policy, effective capabilities, persistence roots and schema/ABI identities.
- [x] **P01-04** Trace the current planners and authorities. Merge duplicate validation of the same immutable facts; retain revalidation only at a real trust boundary or mutable-resource handoff. Delete wrappers that merely rename the same value.
- [x] **P01-05** Bind runner arguments/envelope to that exact plan. The runner verifies its received resources and implements it; it does not choose a different backend, kernel, GPU or network mode.
- [x] **P01-06** Carry graphics preference as a requirement or an explicitly selected recovery mode. Requested acceleration failing to initialize is a visible error; recovery to software requires a separate explicit operation and cannot report accelerated support.
- [x] **P01-07** Model installation, stopped, starting, running, stopping, suspended, failed and recovering states once, with explicit operation progress. Distinguish process alive, VM started, guest booted, tools connected, desktop visible and workload-ready.
- [x] **P01-08** Consolidate journals: one durable operation ID, idempotency key, expected state/version, acquired resources, stage and compensation record. Keep typed operation payloads; avoid generic dictionaries and duplicate lifecycle stores.
- [x] **P01-09** Make cancellation and daemon/runner death release the same leases exactly once. Reconnect after daemon restart by matching process identity and machine generation, not PID alone.
- [x] **P01-10** Reconcile host memory/CPU admission across multiple VMs and the container engine. Account for guest RAM, DBT caches, renderer resources, disk staging and worker overhead; give users actionable capacity errors.
- [x] **P01-11** Define migration for old backend names, distro-led definitions, disk identities and saved-state schemas. Retain original records until the new composition is validated; reject unsafe in-place conversion without deleting workloads.
- [x] **P01-12** Add public-operation tests for every supported/unsupported combination, component absence, malformed media, stale plan, altered artifact, concurrent start, cancellation and restart. Assert no filesystem/network mutation on rejected preflight.
- [x] **P01-13** Remove duplicate launch construction after every app, CLI, restore, clone and recovery entrypoint consumes the unified plan. Add an architecture test on allowed module dependencies, not on arbitrary source-code wording.

**Exit:** the same definition yields the same concrete runtime and device configuration from every entrypoint; a requested capability cannot disappear between the UI, daemon and runner.

**Recorded completion — 2026-09-04:** P01's control-plane implementation and focused corrections are retained in the [review receipt](docs/virtualization/p01-control-plane-review-2026-09-03.json) and [compound-operation campaign](docs/virtualization/evidence/p01-compound-review-2026-09-04/campaign.json). The public-operation boundaries include product-cell preflight, schema-6 plans, component/resource authority, exact runner inputs, readiness separation, operation identity, cancellation/restart, migration and compound snapshot/clone/recovery. Do not reassign these as unimplemented foundations.

**Verification scope:** the receipts preserve the broad run's failures, focused passing corrections, final Release build/symbol audit and 83 isolated app transport tests. Process-level SIGKILL campaigns exercise daemon restart and authenticated helper adoption; compound-operation campaigns also use durable fault injection and helper subprocesses. These distinct, overlapping runs must not be summed into a new blanket pass count.

**Still open:** physical guest/framework/graphics behavior, backend suspend/resume after legitimate guest disk writes, host pressure and release performance. Strict saved-plan artifact checks remain intentional until P08 supplies a validated mutable-artifact continuation contract. Exact-plan admission and helper readiness do not prove restored guest memory or a usable desktop. The retained host/toolchain was experimental; use P00's public-host qualification policy for release.

<a id="phase-p02"></a>

## P02. Make x86 execution correct and boot real userspace

**Existing code:** `DoryDBTX86/DoryX86Decoder.swift`, `DoryX86Interpreter.swift`, `DoryX86CPUProfile.swift`, `DoryX86Paging.swift`, `DoryX86Memory.swift`, `DoryX86MmapMemory.swift`, `DoryX86Differential.swift`, `DoryMachinePC/DoryPCPVHKernel.swift`, `DoryPCPVHBoot.swift`, `DoryPCDirectKernelMachine.swift`, and their tests.

**Deliverable:** a trustworthy uniprocessor x86-64 Linux boot through Dory's CPU and PC implementation, with the interpreter as the semantic reference. Optimize only after reducing failures to architectural tests.

**Status, 2026-09-04:** P02 remains open. The [review through run 62](docs/virtualization/evidence/p02-correctness-2026-09-04/review-through-run-62.json) and [source validation](docs/virtualization/evidence/p02-correctness-2026-09-04/evidence-validation-through-run-62.json) retain frozen source gates, failures and corrections. Run 62 recorded 1,039 passing Swift Testing cases and 10 passing XCTest cases, with a disabled physical-reference case and an optional fixture skip. These are historical results for `b930793f5f00d3abc0eae8ee2cee7e4b8e9da8d9`, not fresh qualification of the current review tree.

| Completed boundary | Retained evidence | Limit |
|---|---|---|
| Checked PVH/ELF loading, explicit unsupported-service failures, pinned fixture runner | P02-01–07 and the [paging/CPU audit](docs/virtualization/p02-paging-audit-2026-09-04.md) | Ordinary UEFI installation remains P05. |
| Conservative CPU profiles and first Linux ISA baseline | [Selected-profile probes](docs/virtualization/evidence/p02-correctness-2026-09-04/selected-paging-profile-probes-through-run-62-validation.json), [Linux CPU baseline contract](docs/virtualization/p02-linux-cpu-baseline-2026-09-04.md) | x86-64 psABI baseline only; no x86-64-v2/v3 claim. Broader architectural behavior remains open. |
| Interpreter/baseline-JIT parity for the same seven musl workloads and poweroff | [Interpreter probe 3](docs/virtualization/evidence/p02-correctness-2026-09-04/userspace-interpreter-probe-3.json), [JIT probe 9](docs/virtualization/evidence/p02-correctness-2026-09-04/userspace-baseline-jit-probe-9.json) | One pinned diagnostic environment; a shared interpreter bug can survive differential comparison. |
| Two kernels, musl/glibc and systemd service supervision | [Systemd and prerequisite validation](docs/virtualization/evidence/p02-correctness-2026-09-04/systemd-kernel-b-probe-2-validation.json) | The two kernels have different symbols but identical `PT_LOAD` envelopes. Optional-module/intermediate-unmount warnings remain in the record. |
| Bounded allocation/process/filesystem/clock stress and block/network I/O | [P02-25 closure](docs/virtualization/evidence/p02-correctness-2026-09-04/p02-25-stability-closure-through-io3.json) | One vCPU, synthetic block file, isolated Ethernet peer; no host networking, power-loss, SMP or soak qualification. |
| Decode/support inventory, time audit, bounded fuzzing and host-cost observations | [ISA inventory](docs/virtualization/evidence/p02-correctness-2026-09-04/run-37-isa-inventory.json.gz), review through run 62 | Decode counts are not executed coverage; measurements do not close P14. |

**Next:** close the concrete remaining mode/exception/paging/scalar/floating-point/SIMD cases in P02-11–16 and obtain independent x86 reference execution in P02-20. Preserve minimal guest-discovered regression vectors. Later source fixes, including protected IRET and binary80 operations, need current focused verification and an appropriate guest rerun; they do not automatically close an entire architectural category. ARM P03/P04 and Mac P08 may proceed independently instead of waiting for every x86 extension.

### P02.A Remove misleading bring-up shortcuts

- [x] **P02-01** Move the fixed-address kernel traces, unconditional register/hypercall prints and local image paths out of normal execution. Preserve useful diagnostics as a bounded opt-in trace with image build ID, symbol map, last exits, faults and guest console tail.
- [x] **P02-02** Replace globally advertised Xen identity and success stubs. Prefer correct non-Xen PVH entry with a supplied versioned memory map; ordinary UEFI remains the product boot contract. If a supported hypercall is retained, implement its exact semantics, capability discovery, argument validation, failure and guest fault behavior.
- [x] **P02-03** Return defined failure for unsupported calls instead of success. Derive guest memory/topology answers from the actual machine configuration. Remove `try?` where it hides guest-memory faults or partial protocol writes.
- [x] **P02-04** Audit every register encoding in `0F 01` and related system groups. Decode exact VMCALL/VMMCALL/VMX/SVM/invalidation forms and enforce mode, feature and privilege rules. Add all ModRM variants as bounded vectors; unsupported operations must raise the proper architectural exception.
- [x] **P02-05** Rebuild ELF/PVH loading around checked offsets, lengths, program segments, BSS zero-fill, entry ranges and boot-note parsing. Remove arbitrary `p_paddr` masking; support only specified relocations. Do not generally load sections outside `PT_LOAD` to compensate for one malformed interpretation.
- [x] **P02-06** Validate reserved low memory, command line, initramfs, memory map, ACPI tables, firmware apertures and kernel segments for overlap and overflow. Test multiple real kernels with different layouts, and malformed ELF/notes/headers that must reject without touching guest state.
- [x] **P02-07** Generalize the existing Linux boot runner to explicit fixture/configuration arguments and bounded budgets. Required CI must obtain a pinned fixture or fail; optional local absence must be reported as skipped. Replace unconditional dumps with assertions of userspace readiness and clean poweroff.

The implementation references are the [PVH boot ABI](https://xenbits.xenproject.org/docs/unstable/misc/pvh.html), [Linux's PVH implementation](https://raw.githubusercontent.com/torvalds/linux/master/arch/x86/platform/pvh/enlighten.c), and [Linux x86 boot protocol](https://www.kernel.org/doc/html/latest/arch/x86/boot.html). A successful kernel-specific workaround does not override those contracts.

### P02.B Close architectural correctness systematically

- [x] **P02-08** Create an ISA support inventory generated from or checked against decoded forms: prefixes, mode, operand/address size, decoder support, interpreter semantics, JIT support, flags, faults and reference vectors. Count executed forms separately from static binary decoding.
- [x] **P02-09** Freeze a conservative versioned CPU profile. Audit all CPUID leaves/subleaves, topology, cache information, address widths, MSRs, feature dependencies and extended state. Never advertise a feature because its opcode decodes. Specifically audit currently omitted PAE/PSE/PGE against each selected Linux kernel: x86_64 requires PAE, while other requirements depend on kernel configuration. Implement and qualify the semantics before setting those bits; do not bypass checks using Xen identity.
- [x] **P02-10** Define the first supported Linux CPU baseline explicitly. Qualify x86-64-v2 or v3 only when all required features work; keep AVX-512 and unrelated extensions outside the critical path unless a selected guest requires them. Preserve graceful `#UD` for unadvertised extensions.
- [ ] **P02-11** Validate real/protected/compatibility/long-mode transitions, segment limits and descriptors, task register, IDT/GDT/LDT access, privilege changes, interrupt stack switching, IRET, SYSCALL/SYSRET and SYSENTER/SYSEXIT.
- [ ] **P02-12** Validate exception priority and precise state: divide/invalid opcode/general protection/page fault/alignment/debug faults; stack faults; interrupt shadow; NMI blocking; double fault and triple-fault reset. Faulting instructions must not commit later effects.
- [ ] **P02-13** Validate paging modes and sizes, canonical addresses, reserved bits, NX, write protection, user/supervisor access, accessed/dirty bits, cross-page operations, page-table edits, CR3 changes and INVLPG. Include instruction fetch across page boundaries.
- [ ] **P02-14** Validate scalar arithmetic flags, shifts/rotates, condition codes, bit operations, multiplication/division, atomics and string operations. REP must be interruptible and restartable with correct partial progress.
- [ ] **P02-15** Validate x87 precision/control/status, exceptions and stack behavior; MMX aliasing; SSE scalar/vector lane semantics; NaNs, signed zero, rounding, denormals, MXCSR, and conversions. Host floating-point shortcuts require proof of equivalent guest behavior.
- [ ] **P02-16** Validate every exposed SIMD/VEX form, upper-lane clearing, alignment/fault behavior and XSTATE save/restore. Feature masking must prevent guest libraries choosing an unsupported optimized path.
- [x] **P02-17** Audit architectural versus emulated time: TSC frequency/monotonicity, CPUID timing leaves, RDTSCP if advertised, pause/idle/reset semantics and scheduler interaction. Do not use raw host wall-clock discontinuities as guest time.
- [x] **P02-18** Correct memory backing initialization: throwing allocation instead of process traps, validated size/alignment, holes/ROM/MMIO permissions, accounting, teardown and consistent errors. Share byte-array and mmap conformance cases rather than maintaining divergent semantics.
- [x] **P02-19** Repair differential testing to give interpreter and JIT independent copies of initial memory/device state. Compare GPRs, RIP, relevant flags, SIMD/x87/XSTATE, segment/control state, written memory and fault details; compare permitted nondeterminism explicitly.
- [ ] **P02-20** Add independent architectural reference execution on physical x86 hardware for bounded instruction cases, with exact initial state and defined output masks. Interpreter-versus-JIT comparison alone can preserve a shared bug.
- [x] **P02-21** Fuzz decode, instruction execution and page walking with fuel/memory limits. Minimize every guest-discovered bug into a regression case. Preserve crash inputs without exposing private guest memory in ordinary logs.

### P02.C Boot ladder and acceptance

- [x] **P02-22** Boot a pinned minimal kernel/initramfs to a unique userspace marker. Exercise syscalls, process creation, exec, memory allocation, signals, timers, filesystem reads/writes and shutdown. Require a machine-readable result from the guest.
- [x] **P02-23** Repeat with at least two different kernels and both musl and glibc userspace, then a systemd environment. Eliminate fixed load addresses and distribution-name workarounds from the VMM.
- [x] **P02-24** Run the same diagnostic boot with interpreter and baseline JIT, preserving equivalent observable state and device behavior. Tier-switching may change speed; it must not change guest capabilities or machine ABI.
- [x] **P02-25** Add one-vCPU stability stress: allocate/free/mmap/mprotect, fork/exec, package unpack, compression, checksums, clock tests, disk flush and sustained network I/O. Reduce failures before adding more CPU extensions.
- [x] **P02-26** Record cold boot duration, guest instructions, fallback reasons and top host costs, but label them engineering measurements until P14.

**Exit:** repeatable userspace boot and workload completion, correct faults and memory behavior, no fake hypervisor services, no test passing merely because an instruction budget expired. SMP throughput is a later gate.

<a id="phase-p03"></a>

## P03. Consolidate native ARM64 execution and the ARM machine

**Existing code:** `Packages/ContainerizationEngine/Sources/DoryHV/Machine.swift`, ARM boot and MMIO devices, `dory-core-swift/Sources/DoryNativeHVArm64/`, `DoryMachineARMVirt/`, `DoryExecutionContracts/`, `DoryFirmware/`, and `Firmware/DoryARMVirt/`.

- [ ] **P03-01** Select one production vCPU/memory/interrupt owner. Wrap the working native path with the smallest useful execution contract, then extract proven operations incrementally. Remove duplicate ownership only after direct-kernel and UEFI behavior is preserved.
- [ ] **P03-02** Preserve the existing per-vCPU thread ownership rules for Hypervisor.framework. Add explicit start/stop rendezvous, cancellation, timeouts and teardown on the correct threads; prove no race destroys a live vCPU.
- [ ] **P03-03** Complete or narrow `run(until:)`: deadlines must have an implemented monotonic clock and cancellation strategy. A public launch/suspend path cannot discover `deadlineNotImplemented` during an operation.
- [ ] **P03-04** Unify HV GIC routing, interrupt assertion/deassertion, pending/in-service state and device IRQ ownership. Do not mix the new generic pending-IRQ mechanism with an independently owned production GIC.
- [ ] **P03-05** Replace blanket trapped-system-register read-as-zero/write-ignore handling with a reviewed register/feature policy. Use architectural RAZ/WI only where specified; expose guest CPU features consistent with available state and traps.
- [ ] **P03-06** Complete the required PSCI functions: version/features and accurately supported CPU_ON/OFF/affinity/reset/poweroff behavior. Add suspend/hotplug only if part of the supported product, with explicit capability reporting. The 2026-09-05 implementation adds exact CPU affinity validation, `ON_PENDING` versus `ON`, both CPU_ON calling conventions, mapped executable-entry validation and level-zero AFFINITY_INFO; the combined native PSCI/engine policy/worker launch suite passes 31 tests in four suites. A [four-CPU physical-host smoke](docs/virtualization/evidence/p03-native-2026-09-05/arm64-four-cpu-agent-ping.json) boots the bundled Linux 6.12.106 kernel on a private rootfs clone, brings all four CPUs online, reaches userspace and returns a successful agent response. This uses an ad-hoc development binary and does not qualify UEFI, GPU, a stock installer or release signing. A follow-up fixes AFFINITY_INFO64 level-argument truncation: high 32-bit values now reject instead of aliasing level zero; all four PSCI state tests pass. CPU_OFF/hotplug and physical SMP qualification remain open. Target validation and calling conventions were checked against the [Linux KVM PSCI implementation](https://github.com/torvalds/linux/blob/master/arch/arm64/kvm/psci.c) and [Arm Trusted Firmware PSCI implementation](https://github.com/ARM-software/arm-trusted-firmware/blob/master/lib/psci/psci_main.c).
- [ ] **P03-07** Validate direct boot: kernel Image header, placement, DTB alignment/size, initramfs ranges, reserved memory, initial registers, MMU/cache state and timer frequency. Keep the [ARM64 Linux boot contract](https://www.kernel.org/doc/html/latest/arch/arm64/booting.html) as the normative reference.
- [ ] **P03-08** Keep device-tree/firmware/runtime memory maps identical. Test every MMIO region, interrupt assignment, shared-memory aperture, firmware range, vCPU count and RAM boundary against the actual constructed machine.
- [ ] **P03-09** Implement pause/quiesce/resume barriers across vCPUs, device queues and workers. Preserve virtual time and pending interrupts; prevent callbacks from mutating a captured state generation.
- [ ] **P03-10** Treat all-pages dirty reporting as a correct baseline. Optimize dirty tracking only through supported page-protection/tracking mechanisms with write-fault, DMA and page-granularity coverage. Never claim incremental snapshot efficiency from a blanket bitmap.
- [ ] **P03-11** Test 1/2/4/8 vCPU configurations where admitted, minimum/large RAM, host memory pressure, idle WFI, interrupt storms, rapid start/stop/reset, host sleep/wake and resource reclamation.
- [ ] **P03-12** Keep macOS-version checks and API availability localized to the host adapter. Require exact minimum-host physical coverage before dropping a compatibility path.
- [ ] **P03-13** Remove the duplicate native engine implementation or reduce it to the same production adapter once parity passes. Keep small probes as clients of that adapter, not separate implementations.

**Exit:** one production native execution implementation supports both managed direct boot and the DoryARMVirt UEFI machine with the required lifecycle contract and no regression in the current container/managed-Linux runtime.

<a id="phase-p04"></a>

## P04. Make device semantics correct and shared across Linux architectures

**Existing code:** `DoryVirtio/`, `DoryMachinePC/DoryPCVirtioPCI.swift`, `DoryPCPCIExpress.swift`, PC interrupt/timer models, `DoryHV/Virtqueue.swift`, `VirtioMMIO.swift`, existing raw-HV devices, `DoryHV/DoryPCVirtioFSPCI.swift`, host device backends.

Use the [Virtio specification](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html) for transport and device behavior. Supporting the selected devices does not require implementing every optional Virtio feature.

### P04.A Memory, queues, transports and interrupts

- [ ] **P04-01** Inventory behavioral differences in old/new queues and device cores. Select one shared implementation per device; retain architecture-specific MMIO/PCI transport adapters and measured fast paths.
- [ ] **P04-02** Define checked guest-memory/DMA operations with range, permissions, mapping generation and revocation. Distinguish RAM, ROM, MMIO and renderer apertures; device DMA must obey guest-physical region permissions and granted DMA authority, independently of a vCPU’s guest virtual page tables/CPL. Do not incorrectly apply CPU virtual-access rules to device DMA.
- [ ] **P04-03** Implement exact feature negotiation, status transitions, FEATURES_OK/DRIVER_OK handling, queue configure/reset and full device reset. Do not accept features for which the implementation lacks semantics.
- [ ] **P04-04** Validate split rings, indirect descriptors, loops, readable/writable ordering, lengths, overflow, overlapping rings, used-index wrap, event suppression and descriptor reuse. Add packed rings only if profiling justifies their extra implementation.
- [ ] **P04-05** Preserve immutable request snapshots and bounded in-flight operations. Completion must be exactly once, after required effects, and rejected if queue/device/memory generation changed.
- [ ] **P04-06** Implement deferred completion without blocking the vCPU loop on filesystem, renderer or network round trips. Maintain bounded backpressure and fairness across devices and VMs.
- [ ] **P04-07** Validate PCI BAR probing and reassignment, 32/64-bit regions, ECAM, memory/I/O decode enables, capability lists, MSI/MSI-X tables/masks/PBA and INTx routing against real firmware enumeration.
- [ ] **P04-08** Complete PC APIC/IOAPIC/PIC/PIT behavior needed by selected Linux guests, including logical destination support, interrupt priorities, EOI and INIT/SIPI sequencing. xAPIC logical mode has no independent CPUID feature bit to hide; a temporary restriction requires a specifically qualified guest/physical-destination-mode contract, not a generic feature mask.
- [ ] **P04-09** Correct PC ACPI PM status/enable/control separation; W1C and SCI behavior; sleep/reset requests; PM timer 3.579545 MHz frequency, width and wrap; FADT flags; snapshot/reset state. Test against virtual time, not incidental HPET tick counts.
- [ ] **P04-10** Validate HPET, RTC, CMOS and time calibration under idle, pause, host sleep and reset. Guest scheduler time must stay consistent across all enabled clock sources.

### P04.B Essential devices

- [ ] **P04-11** Block: validate capacity/sector geometry, read/write/flush ordering, discard/write-zeroes, read-only errors, short I/O, cancellation, queue reset and durability. A completed guest flush must correspond to the declared host persistence policy.
- [ ] **P04-12** Network: validate MTU, checksum/GSO features, scatter/gather, receive buffering, multiqueue where used, backpressure, link changes, MAC persistence and malformed frames. Share one host backend contract across ARM and PC.
- [ ] **P04-13** Entropy: provide cryptographic host randomness through bounded queues; validate partial reads, reset and worker failure. Never return deterministic test bytes in production.
- [ ] **P04-14** Input: implement complete key/button release, absolute and relative pointer modes, wheel/high-resolution scrolling, capability queries and resynchronization after focus loss or queue overflow.
- [ ] **P04-15** Sound: validate PCM formats/rates/channels, stream state, buffer positions, event delivery, latency, underrun/overrun and device loss. Use one host audio backend with per-VM routing and permission policy.
- [ ] **P04-16** Vsock/guest control: implement bounded connection lifecycle, framing, half-close, cancellation, reset and backpressure. Avoid guest control channels that can request ambient host filesystem or process access.
- [ ] **P04-17** File sharing: reuse the isolated filesystem worker; expose only negotiated semantics and the actual granted roots. Keep zero-cache/non-DAX as the initial correctness baseline; P11 owns further qualification.
- [ ] **P04-18** USB: retain the existing xHCI/HID/UVC work where connected; test enumeration/control/bulk/interrupt transfers, reset and detach. Treat physical passthrough, emulated HID, camera forwarding and disk-image USB mass storage as different capabilities.
- [ ] **P04-19** Hotplug only for declared devices. Define rejection for unsupported hot changes; never edit live device topology by mutating persisted configuration alone.
- [ ] **P04-20** Execute the same device behavior vectors through ARM MMIO and PC PCI. Add fuzzing of guest-supplied queue/config inputs and teardown races; delete duplicate old implementations only after parity and real guest tests.

**Exit:** both Linux machine models expose a small correct hardware contract sufficient for installation, desktop use and durable workloads. No unrelated legacy device collection is needed simply to resemble a general PC emulator.

<a id="phase-p05"></a>

## P05. General Linux media, firmware, installation and installed boot

**Existing code:** `DoryFirmware/`, `Firmware/DoryARMVirt/`, `Firmware/DoryPC/`, `DoryOperations/DoryInstallerISO.swift`, `DoryLinuxInstalledDisk.swift`, `DoryInstalledLinuxBootBundle.swift`, firmware runtime authorities, `MachineManager` install and media operations, guest build scripts.

### P05.A Firmware and media

- [ ] **P05-01** Freeze versioned ARM and PC firmware/platform ABIs matching the implemented devices. Keep EDK II source/toolchain locks, reproducible patch application, artifact hashes and firmware-variable compatibility.
- [ ] **P05-02** Build firmware on two clean builders using pinned inputs; compare output hashes or explicitly document unavoidable nondeterministic fields. Verify manifests, licensing and toolchain provenance before signing.
- [ ] **P05-03** Test UEFI reset vector/entry, memory map, PCI/MMIO enumeration, block devices, console/graphics, boot order, NVRAM read/write, ExitBootServices and subsequent OS runtime interactions.
- [ ] **P05-04** Verify persistent boot variables across restart, installer media removal, failed install and firmware update. Preserve an atomic recoverable variable store; never silently initialize new NVRAM over an existing guest identity.
- [ ] **P05-05** Inspect ISO/disk content for architecture, EFI boot path, partitions, image format, logical capacity and supported boot method. Bound parser work and reject conflicting/corrupt metadata; do not infer compatibility from the distribution name.
- [ ] **P05-06** Implement streaming verified download/import with resume, cancellation, space reservation, temporary-file ownership, hash validation, deduplicated immutable cache and atomic publication. The source image remains unchanged.
- [ ] **P05-07** Begin with raw sparse writable disks and read-only installer media. If QCOW2/VMDK import is promised, implement it in an isolated bounded converter with backing-chain/cycle/path checks and transactional destination verification; no QEMU utility runtime dependency.
- [ ] **P05-08** Keep installation media, disk, firmware code, firmware variables and guest tools as separately identified artifacts. An installer update does not mutate the guest's installed system unless explicitly requested.

### P05.B Real installation and distro-neutral operation

- [ ] **P05-09** ARM: boot a stock installer through DoryARMVirt UEFI, install to a new disk, shut down, eject media, and boot the installed disk. Repeat on two independent general-purpose distro families before widening coverage. A [2026-09-05 development run](docs/virtualization/evidence/p05-arm-2026-09-05/development-context.json) reaches the new firmware's UEFI shell, installs stock Alpine 3.24.1 to a fresh disk, detaches the ISO, and reaches the installed guest after reset (two boots, five completed steps). The exact matrix-selected Alpine and [Debian update gates](docs/virtualization/evidence/p05-arm-2026-09-05/debian-matrix-update.json) subsequently pass on the same firmware: each records three boots with media detached; Debian completes all 30 fixture steps. These results cover two independent distro families. A subsequent [two-process Alpine run](docs/virtualization/evidence/p05-arm-2026-09-05/alpine-process-cold-context.json) installs and exports a stopped disk/NVRAM bundle, exits, then verifies its persisted sentinel after a new process restores and boots without an ISO. The equivalent [Debian two-process check](docs/virtualization/evidence/p05-arm-2026-09-05/debian-process-cold-context.json) also passes after its three-boot install/update sequence. These prove development cold-snapshot portability across process exit for both distro families. One-vCPU serial runner qualification still does not prove production daemon install finalization, direct reopening of a daemon-managed machine, or graphics.
- [ ] **P05-10** x86: repeat the same sequence through DoryPC UEFI. A PVH diagnostic boot does not substitute for installer/firmware compatibility or desktop support.
- [ ] **P05-11** Test installer graphics/input, networking, clock, storage discovery, partitioning, bootloader installation and final reboot. Capture stage-specific errors and a serial/recovery console even when graphical setup fails.
- [ ] **P05-12** Implement durable install finalization: transition the definition from installation media to installed-disk boot once verified. Future cold boot must not require the original ISO or a managed direct-kernel bundle.
- [ ] **P05-13** Qualify guest kernel and Mesa package updates, bootloader changes and initramfs regeneration on installed systems. Keep rollback/recovery media available without pinning every stock guest to Dory's managed kernel. The [2026-09-05 Alpine update receipt](docs/virtualization/evidence/p05-arm-2026-09-05/alpine-matrix-update.json) passes the exact `alpine-update` matrix gate with the pinned gvproxy build: three boots, eight completed steps, and installer media absent on the final boot. This proves that fixture's package-update/reboot sequence on a development runner. The Debian update gate also passes with three boots and 30 steps. The [Alpine recovery gate](docs/virtualization/evidence/p05-arm-2026-09-05/alpine-matrix-recovery.json) also passes three boots and ten steps, reattaches recovery media, and verifies the installed disk sentinel through a read-only mount. Mesa/GPU, additional distro coverage and production lifecycle qualification remain open.
- [ ] **P05-14** Keep managed images as optional fast-start templates. Remove distro-specific assumptions from engine selection, guest readiness and host-path construction; use guest-reported OS/tool capabilities.
- [ ] **P05-15** Provide signed architecture-specific guest integration packages with explicit install consent and uninstall. Boot and basic display/network must remain usable when the tools are absent.
- [ ] **P05-16** Test encrypted guest disks at the guest-controlled layer, recovery prompts, non-US keyboard input and changed boot order. State clearly if host-managed disk encryption is a separate future feature.
- [ ] **P05-17** Add low-disk, bad media, checksum failure, cancellation, process termination, host restart and detached external data-drive scenarios at every install stage. Preserve user disks and make retry/resume/recreate choices explicit.
- [ ] **P05-18** Grow the published compatibility matrix only from exact tested media, installed kernel/Mesa and runtime tuples. Unknown compatible media may be experimental; it cannot inherit a nearby distro's release status.

**Exit:** Linux ARM64 and x86_64 each install from ordinary supported media, reboot without that media, update, use persistent storage/network, and reach a desktop or shell through the real product flow. Accelerated desktop qualification is P06, not inferred from installation.

<a id="phase-p06"></a>

## P06. Complete accelerated Linux graphics and container GPU compute

**Existing code:** raw-HV `VirtioGPU.swift`; portable `DoryVirtioGPU.swift`; `DoryPCVirtioPCI.swift`; `DoryHV/DoryPCVirGLRendererAuthority.swift`; `dory-hv/DoryPCMode.swift`, `DesktopMode.swift`, `DesktopMetalDisplay.swift`; renderer worker/Metal/backend/shim modules; wire contracts; `Config/DoryRendererProductionTuple.json`; `guest/mesa/`; guest desktop/kernel graphics inputs and live gates.

**Deliverable:** genuine guest OpenGL and Vulkan acceleration, correct presentation, explicit effective capability reporting, and a shared implementation across ARM MMIO and PC PCI. This is one of the two largest engineering risks alongside x86 CPU correctness/performance.

**Required scope, confirmed 2026-09-04:** GPU acceleration is a primary deliverable for **Linux ARM64 VMs, Linux x86_64 VMs, macOS ARM64 guests, and Docker containers**. Mac guest Metal remains P08. Container Vulkan/compute belongs to this phase, not a retired experiment. Existing ARM worker rendering, GPU kernel selection, container GPU launch/configuration and PC integration assets must be preserved until a connected replacement supplies their required behavior. Do not remove needed GPU development code merely because its production connection is unfinished.

**Immediate priority:** connect and verify the signed worker path for the ARM container engine while advancing PC graphics integration. Correctness, explicit capability reporting and real workload output are required; filesystem/library presence and a visible toggle are insufficient. The current container runner still rejects acceleration, and the PC runner rejects it without renderer authority. Those are implementation gaps to close, not desired permanent product policy.

| Product path | Existing connection to retain | Missing production connection |
|---|---|---|
| ARM Linux VM | `MachineManager` renderer staging → `DesktopRendererWorkerLaunch.prepare` → `DesktopMode.Controller` → worker-backed `VirtioGPU`, host-visible memory and synchronized presentation. | Consistent admitted image/kernel/renderer/runtime qualification and physical guest workload evidence. |
| Docker engine | `DorydConfiguration` GPU kernel/configuration and shim device-request normalization. | Engine renderer bootstrap/command lane, GPU device attachment and guest DRM readiness. Runtime readiness must replace ambient environment flags for device authorization. |
| x86 Linux VM | `DoryPCVirGLRendererAuthority` → portable GPU authority; PC PCI/UEFI constructors already accept acceleration authority. | `MachineManager` PC renderer admission and `DoryPCMode` envelope/worker forwarding. VirGL2 first; Venus additionally needs blob BAR and generation-bound host mappings. |
| macOS guest | Apple VZ Mac graphics and the existing VZMac display view. | P08 connected lifecycle/device-policy checks and physical guest Metal qualification. |

### P06.A Profiles and dependency ownership

- [ ] **P06-01** Define a small profile set: software display; accelerated VirGL2/OpenGL; accelerated VirGL2 plus Venus/Vulkan. Each profile declares guest driver requirements, capsets, synchronization, formats, presentation and recovery behavior.
- [ ] **P06-02** Separate signed host worker/artifact identity from guest architecture and guest driver/kernel requirements. Replace permanent equality to one dated tuple with a versioned profile plus exact release artifact references.
- [ ] **P06-03** Preserve producer-fence proof where the current implementation needs it. For stock kernels, prove sufficient standard synchronization or require an explicit supported guest package. Never remove the kernel digest gate merely to make an ISO launch.
- [ ] **P06-04** Derive one renderer lock manifest and remove duplicated pin/digest policy across Swift, Python and guest PINS after generated/validated consumers agree. A source upgrade is not automatically a wire-protocol version change.
- [ ] **P06-05** Keep VirGL2 → ANGLE → Metal and Venus → MoltenVK → Metal as the initial implemented routes. Audit the pinned fork patches against upstream and retain only patches with a reproduced regression and a named owner. [MoltenVK runtime guidance](https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/MoltenVK_Runtime_UserGuide.md).
- [ ] **P06-06** Report actual guest driver, renderer/device identity, API version/extensions, selected profile, producer/consumer synchronization path and first completed frame. A requested profile, capset list or worker startup is not evidence an application used the GPU.

### P06.B One GPU core, complete asynchronous semantics

- [ ] **P06-07** Port the mature raw-HV GPU semantics into one shared core in bounded slices: command decoding, resources/backing, contexts, capsets, features, scanouts, cursors, fences, blob mappings and reset. Keep Metal/XPC types in host adapters.
- [ ] **P06-08** Preserve asynchronous queues and descriptor ownership until required GPU work completes. Remove synchronous renderer round trips from CPU execution; use bounded deferred completions tied to queue/device/worker generations.
- [ ] **P06-09** Implement real global/context fence operations, ring selection, completion ordering, timeout/error propagation, reset cancellation and exactly-once used-ring updates. Do not acknowledge a fence merely because the submit RPC returned.
- [ ] **P06-10** Complete RESOURCE_CREATE_BLOB, MAP_BLOB, UNMAP_BLOB and SET_SCANOUT_BLOB, UUID/context initialization and capability negotiation. Reject unsupported feature/command combinations precisely.
- [ ] **P06-11** Validate all offset/stride/format/dimension calculations, resource IDs, backing changes, context ownership and resource reuse. Bound total memory, contexts, queues and in-flight commands per VM and worker.
- [ ] **P06-12** Implement cursor shape, position, hotspot, hide/show and per-scanout delivery through the common host cursor/display sink. Preserve button/key focus behavior across display changes.
- [ ] **P06-13** Define renderer/shared-memory/texture retirement: producer completion → consumer import/presentation → consumer retirement → backing release. Protect against late callbacks, reset, resource ID reuse, stale handles and worker death.
- [ ] **P06-14** Preserve damage-proportional software updates already present on ARM; avoid replacing them with whole-frame copies during consolidation. Use software mode for deterministic recovery and test oracles.
- [ ] **P06-15** Migrate old in-process renderer tests to a fake worker channel, then delete unused production executor/texture-fallback branches. Retain tests for malformed command streams, lifetime/fence failures and resource exhaustion.

### P06.C ARM OpenGL, Vulkan and stock guest compatibility

- [ ] **P06-16** Qualify the current managed Xorg/VirGL path first: color formats, orientation, alpha, row stride, clipping, damage, compositing and stable redraw. Test GTK/Qt/browser/editor workloads and a shader test, not only glxgears.
- [ ] **P06-17** Validate shared Metal texture export/import and same-GPU compatibility on every admitted host class. Require completed GPU rendering and actual presentation before marking display ready.
- [ ] **P06-18** Validate Venus host-visible mapping on 4 KiB guest pages and the host's allocation granule. Prove alignment, subrange ownership, CPU cache coherence, alias handling, unmap/rebind and protection against exposing adjacent memory.
- [ ] **P06-19** Verify actual Vulkan features/extensions, external memory/semaphore behavior, acquire/render/submit/present and error paths. Test robust access and device loss; do not promote features merely from a host API bit.
- [ ] **P06-20** Qualify optimal-render → linear-copy scanout separately from direct linear rendering. Count GPU copies and CPU copies; shared memory does not justify an unconditional “zero-copy” claim.
- [ ] **P06-21** Connect generic ARM UEFI guests to the same verified GPU path. Validate stock distro Mesa/kernel combinations and any explicit guest-pack upgrade transaction. Preserve the installation's selected kernel unless the user chooses a managed package.
- [ ] **P06-22** Make guest preflight downgrade visible as an effective profile change. If a user required Vulkan, a VirGL-only result fails that request; it cannot silently pass the accelerated-Vulkan gate.
- [ ] **P06-23** Extend live graphics gates from managed ARM/X11 assumptions into architecture/profile/compositor-aware runs. Distinguish an application process existing from a mapped and actively redrawing hardware-rendered surface.

### P06.D PC OpenGL and Vulkan

- [ ] **P06-24** Compose the signed renderer bootstrap in `DoryPCMode`, pass the shared authority through `DoryPCUEFIRuntimeAuthority` to the PCI GPU, and wire shared texture output into the existing host display. Remove the launch rejection only after its complete profile gate passes.
- [ ] **P06-25** Replace full-backing CPU staging with bounded region transfers where possible; preserve immutable validated command snapshots. Measure synchronous stalls and copied bytes before and after.
- [ ] **P06-26** Add a versioned PCI host-visible shared-memory capability and blob BAR. Define sizing/probing, address assignment, memory-decode enables, aperture bounds and RAM-hole interaction without silently breaking persisted machine ABI.
- [ ] **P06-27** Map renderer-exported validated shared memory into the PC address space. Integrate unmap/remap with DBT page tables, cached host pointers, code invalidation and permissions. Never permit execution from revoked or reused mappings.
- [ ] **P06-28** Test CPU reads/writes concurrent with GPU work, MMIO, worker restart, queue reset and aperture relocation. Reject stale memory generations before host access.
- [ ] **P06-29** Extend Mesa/guest-driver builds, manifests, installers, verification and dependencies to x86_64. Do not pass an ARM64 library through an architecture-neutral filename. Keep host runner architecture and guest package architecture distinct.
- [ ] **P06-30** Qualify x86 stock VirGL first, then Venus with the same pixel, fence, memory and WSI criteria as ARM. Record CPU translator time separately from GPU render time.
- [ ] **P06-31** Keep PC Vulkan hidden until blob mapping, fences, guest packages and sustained real presentation all pass. A working PCI software framebuffer is not a partial accelerated tier.

### P06.E Compositor, display and application coverage

- [ ] **P06-32** Test Xorg, XWayland and native Wayland as separate cells. Use guest compositor-aware observations; X11 window enumeration cannot establish native Wayland readiness.
- [ ] **P06-33** Qualify GNOME and KDE; add a selected wlroots compositor only when intended for support. Remove `WaylandEnable=false` and forced `GSK_RENDERER=gl` only after their original failure cases and current desktop workloads pass.
- [ ] **P06-34** Test Retina/fractional scaling, resize under load, multiple independent Linux scanouts, display rotation if supported, monitor disconnect/reconnect, full-screen, occlusion/minimize and host sleep/wake.
- [ ] **P06-35** Exercise OpenGL and Vulkan shader/pixel correctness, text/scrolling, WebGL/browser GPU use, GTK4/Qt, editor workloads and sustained 3D resource churn. Detect llvmpipe/lavapipe or other software fallbacks explicitly.
- [ ] **P06-36** Treat hardware video decode/encode and GPU compute compatibility as separate capabilities. Current video-disabled renderer policy does not promise codec acceleration; ordinary video playback still needs usability qualification.
- [ ] **P06-37** Evaluate Zink only after both primary routes are stable. Keep it only if measured compatibility/maintenance/performance benefits justify replacing a route; avoid a permanent third default rendering stack.
- [ ] **P06-38** Run worker kill, malformed GPU commands, allocation failure, fence timeout, device loss, VM reset and repeated starts. Require bounded failure, guest-data preservation and an explicit recovery choice.
- [ ] **P06-39** Check that descriptor, shared-memory, texture, context and host RSS use returns to baseline after teardown; qualify concurrent VMs under global GPU pressure.

**Exit:** both Linux ISAs run a real accelerated desktop and required OpenGL/Vulkan workloads through their production machines. Effective graphics matches the user's requirement. Pixel/fence/lifetime correctness, stock/managed guest policy and sustained performance all have exact candidate evidence.

### P06.F Docker container GPU acceleration

- [ ] **P06-C01** Reuse the production isolated renderer bootstrap and worker command lane in `dory-hv engine`. Carry verified renderer authority from the daemon, attach the real `VirtioGPU` to the engine machine, provide host-visible memory and propagate worker failure without falsely reporting a healthy GPU.
- [ ] **P06-C02** Preserve GPU kernel/guest-driver selection as one verified contract. Resolve the current 16 KiB GPU-kernel versus 4 KiB FEX requirement before advertising GPU together with x86_64 application compatibility. Unsupported combinations must produce a clear preflight error; do not silently change architecture, disable requested translation, or substitute a software device.
- [ ] **P06-C03** Package and expose the guest DRM render node and matching Vulkan ICD through the container device request/OCI path with bounded permissions. Support the documented Docker/API request end to end; do not authorize a device merely because the request string is present. The daemon dataplane now translates an admitted generic `--gpus all` request (or device `0`) into `/dev/dri/renderD128` with `rw` permissions, preserves unrelated requests, and rejects unsupported driver/capability/count/options and conflicting mappings. All 53 dataplane tests pass, including HTTP forwarding of the translated request and rejection before backend access. Compatible container Mesa/ICD packaging and real compute remain unqualified.
- [ ] **P06-C04** Derive Settings, daemon, shim and guest capability reporting from the configured worker and observed guest readiness. Replace the app's ambient `dlopen`/Homebrew renderer probe with the same verified authority as the runner. Preserve requested settings on initialization failure and explain recovery. The app shim's environment-driven GPU request stripping and all-DRM cgroup grant are removed; requests now reach the backend's admission policy unchanged. The app/test bundle builds and all three shared-VM compatibility tests pass. LaunchServices initially blocked the test host beside the installed app; removing the duplicate hardcoded `LSMultipleInstancesProhibited` plist key lets the existing build setting control it. The signed test invocation uses `INFOPLIST_KEY_LSMultipleInstancesProhibited=NO`; normal build settings retain the existing restriction. Settings now also reuses the daemon’s signed-runner preflight instead of loading ambient/Homebrew renderer libraries. Startup retains the requested GPU setting when preflight fails, and conflicting GPU/FEX requests fail explicitly instead of silently selecting FEX. All 33 runtime-support app tests pass for this follow-up, including rejection of conflicting GPU/FEX requests. This is package preflight, not observed guest GPU readiness; live capability reporting and real compute remain open.
- [ ] **P06-C05** Run native ARM64 container Vulkan enumeration, allocation/copy/synchronization and compute-output checks against CPU reference output. Exercise worker crash/restart, concurrent containers, resource bounds and engine shutdown. Require evidence of hardware execution rather than successful software rendering.
- [ ] **P06-C06** Qualify supported amd64 container GPU workloads separately from native ARM64. Publish the actual API/ISA/device limitations and measure host-native, native-guest and translated-container workloads separately.

**Container GPU exit:** the app can enable the verified GPU composition, the daemon launches it, Docker admits the authorized device request, a real container computes correct output on the host GPU, and failure/restart/teardown preserve the required isolation and user data. This gate is required alongside VM graphics; it does not replace P06.C/D or Mac P08 Metal qualification.

<a id="phase-p07"></a>

## P07. Make x86 translation fast without sacrificing semantics

**Existing code:** `DoryARM64BaselineJIT.swift`, `DoryDBTIR.swift`, `DoryIROptimizer.swift`, `DoryJITRuntimeC/`, memory/paging/replay/interrupt code and `DoryPCDirectKernelMachine.swift`.

### P07.A Safe baseline execution

- [ ] **P07-01** Profile representative installed Linux workloads in release builds: kernel boot, package manager, compiler, browser/compositor, compression and filesystem/network load. Separate decoder, optimizer, emitter, callbacks, page walking, block lookup, device exits and interpreter fallback.
- [ ] **P07-02** Extend native lowering in hotness order while preserving precise faults, flags and state materialization. Keep unimplemented instructions on the interpreter path; report fallback counters and reasons.
- [ ] **P07-03** Prove JIT memory publication/reclamation in the actual signed/notarized runner: MAP_JIT policy, approved writer, executable/write transitions, instruction-cache invalidation, guard pages and concurrent readers. A standalone probe is supplementary.
- [ ] **P07-04** Use generation-checked translation keys including guest mode/privilege/address-space assumptions. Invalidate on code writes, DMA, page-table changes, permissions, remapping and tier/profile changes as required.
- [ ] **P07-05** Implement safe fast RAM/TLB paths with permission, generation and MMIO guards. Remove byte-at-a-time scalar reconstruction and coarse locks only when memory conformance and fault tests remain correct.
- [ ] **P07-06** Bound code cache size, compile work and eviction. Use safe block-link invalidation and reader retirement; snapshots must never persist executable host code.
- [ ] **P07-07** Improve register residency, lazy flags, helper calls, direct block linking and vector lowering as individual measured changes. The current local optimizer is not an established optimizing compiler; publish actual gain, code size and compile cost.
- [ ] **P07-08** Preserve exact recovery from faulting instructions inside blocks, partial REP operations, MMIO side effects and asynchronous interrupts. Deoptimization/state recovery must identify the correct guest instruction boundary.

### P07.B Real SMP and the x86 memory model

- [ ] **P07-09** Specify x86 TSO on ARM for ordinary memory, loads/stores, locked operations, fences, unaligned and cross-page atomics, instruction visibility and DMA interaction. Choose a correct baseline before optimizing barriers.
- [ ] **P07-10** Replace serialized round-robin CPU execution with per-vCPU host execution and explicit per-vCPU state ownership. Split machine locks into actual memory/device/interrupt ownership; do not merely reduce the current global lock timeout.
- [ ] **P07-11** Add interrupt delivery queues, AP startup, scheduler wakeups, HLT idle behavior, stop/reset barriers and device synchronization under parallel execution.
- [ ] **P07-12** Run memory-order litmus, atomic stress, guest kernel lock torture, futex/process/thread stress, concurrent page-table changes and DMA/code invalidation. Validate at 1/2/4/8 admitted vCPU configurations.
- [ ] **P07-13** Provide deterministic single-threaded replay for diagnosing concurrency failures; the diagnostic scheduler must not become the production performance model.
- [ ] **P07-14** Measure scaling, lock contention, compilation contention, fairness, interrupt latency and energy under concurrent VMs. Disable unsupported SMP profiles explicitly until correctness and stability pass.
- [ ] **P07-15** Add hot-block/superblock optimization only after baseline profiles demonstrate need. Do not build a speculative optimizing compiler, persistent translated-code format or cross-host migration layer before these workloads benefit.
- [ ] **P07-16** Compare same-host x86 full-system translation against a pinned external reference such as QEMU TCG without making it a shipped dependency. Also report absolute user-work time; beating a slow reference alone does not establish usability.

**Exit:** x86 Linux uses actual parallel vCPUs where advertised, retains interpreter/JIT semantic parity, has bounded compilation/memory overhead, and meets predeclared translated-workload budgets. The product still identifies it as translated execution.

<a id="phase-p08"></a>

## P08. Repair and finish macOS ARM64 through the existing VZMac path

**Existing code:** `DoryVZMacCore/`, `DoryVZMacCompatibility/`, `DoryVMMKit/DoryVZMacAdapter.swift`, `DoryVZMacDesktopApplication.swift`, `DorydKit/MachineManager.swift`, `DoryMachineSavedState.swift`, `HvProcess.swift`, `LinuxMachineBackendAdapters.swift`, `Dory/Features/Sheets/NewMachineSheet.swift`, `Dory/Models/AppStore.swift`.

**Deliverable:** a reliable install-to-desktop Mac VM with real accelerated guest Metal, correct policy, durable operations and recoverability. Retain Apple's Mac graphics and platform rather than building another backend.

### P08.A Fix the connected lifecycle before adding features

- [x] **P08-01** Correct install completion versus terminal `.stopped`: the production install/start orchestration remains alive across installer stop events and starts first boot once. Installer progress and the existing running-state managed readiness handoff remain separate. Seven focused adapter/lifecycle tests pass in this review; physical packaged installation remains P08-02.
- [ ] **P08-02** Test the actual adapter/desktop orchestration with a small deterministic runtime seam, then the exact packaged product path. Avoid a parallel qualification app that exercises different lifecycle logic.
- [ ] **P08-03** Reuse shared signal/AppKit shutdown handling. SIGTERM/SIGINT from daemon stop must request bounded guest shutdown; handle installation cancellation, running, paused and failed states before escalating to forced termination.
- [ ] **P08-04** Unify saved-state directory and file authority between daemon and VZMac. Accept the intended `saved-state-v1` transaction through verified ownership; preserve path containment and private permissions instead of broadening arbitrary path acceptance.
- [ ] **P08-05** Remove the private helper pseudo-saved-state format. Keep one outer operation/manifest and one backend payload descriptor with configuration/identity/host/runtime/payload hashes.
- [ ] **P08-06** Make suspend atomic: reserve capacity, quiesce, save, validate, publish, then acknowledge. Failure must leave a known running/paused/stopped state and a recoverable artifact, with no false “saved” event. Bind suspension-time mutable artifact state to the saved execution plan: current strict artifact publication stamps reject guest-written disks at saved-state preflight. Preserve that rejection until a validated continuation contract can accept legitimate writes without accepting substituted backing.
- [ ] **P08-07** Make restore commit boundaries recoverable. If the VM resumes before metadata cleanup succeeds, record that reality and avoid replaying the same saved state or reporting a stopped VM. Test termination at each boundary.
- [ ] **P08-08** Replace the duplicated Mac control server with the existing bounded authenticated transport. Add absolute read deadlines, request/client limits, peer identity, operation/generation binding and inode-safe socket cleanup; keep backend-specific handlers small.
- [ ] **P08-09** Replace fabricated healthy/zero device telemetry with observed VZ state and explicit unavailable counters. Distinguish VM running, guest booted, desktop visible, guest tools connected and workload ready.

### P08.B Make requested policy equal actual configuration

- [ ] **P08-10** Carry requested CPU/RAM, display, network, audio input/output, camera, clipboard, shares, tools and supported USB policy through the single resolved launch contract into `DoryVZMacConfigurationBuilder`.
- [ ] **P08-11** Remove hardcoded shared NAT/bidirectional clipboard/audio defaults that override the requested policy. Inspect the constructed VZ device arrays in tests; verify disabled integrations are absent or effectively blocked in the guest.
- [ ] **P08-12** Bind managed Guest Tools delivery and shared directories to granted read-only/read-write roots. Do not leave those options usable only from the standalone CLI helper.
- [ ] **P08-13** Reuse host display presentation policy for initial size, backing scale, full-screen, selected physical display and restoration. Qualify actual Retina resizing with the Mac graphics view.
- [ ] **P08-14** Preserve the currently implemented single independent Mac guest display limit. Full-screen on another host monitor is not an additional guest display. Reevaluate only against verified final public API support; do not invent a workaround capability.
- [ ] **P08-15** Verify every VZ device/API against the selected final SDK and host availability. Treat virtual USB mass storage, physical USB attachment and camera bridging as different features with different support gates.
- [ ] **P08-16** Make camera/microphone access opt-in with host permission handling, revocation and visible use. Optional camera extension activation must not prevent the base Mac VM from installing or booting. New-machine camera and microphone defaults are now off in both UI state and collected settings; all 14 existing settings tests pass, including explicit enabling. Host permission, revocation, visible use and extension-independent boot still require end-to-end qualification.

### P08.C Installed Mac identity, media and recovery

- [ ] **P08-17** Preflight IPSW compatibility using supported Apple restore-image requirements. Validate CPU/RAM floors and hardware-model support before creating artifacts; persist exact restore provenance.
- [ ] **P08-18** Persist hardware model, Mac machine identifier, auxiliary storage, disk and effective configuration as one machine-owned bundle. Never regenerate identity during an ordinary start, upgrade or recovery.
- [ ] **P08-19** Commit a successful install to installed-disk boot in the definition. Remove the permanent `.install`/IPSW requirement from installed-Mac validation. Cold boot must work with the original IPSW cache removed.
- [ ] **P08-20** Wire existing `DoryVZMacRecovery`, portable bundle and clone operations into the daemon mutation/journal authority. Remove generic snapshot rejection for Mac only when all required artifacts are covered.
- [ ] **P08-21** Distinguish same-machine restore from new-machine clone. Restore preserves identity; clone regenerates the intended Mac/MAC identities and validates copied auxiliary storage against Apple's supported behavior.
- [ ] **P08-22** Include disk, auxiliary storage, hardware model, machine identifier and configuration in stopped/cold snapshots. Exclude host-bound RAM/execution state from portable exports.
- [ ] **P08-23** Enforce saved-state compatibility uniformly in managed and diagnostic paths: host, OS/build, runtime, configuration and backend requirements. Incompatibility offers explicit cold boot while preserving disk data.
- [ ] **P08-24** Test install retry, unavailable restore service, disk full, interrupted writes/copy/rename, external-drive loss, stale leases, host restart and upgrade rollback. Never repair by silently creating a new identity or blank disk.
- [ ] **P08-25** Qualify guest OS updates, recovery boot, resource changes while stopped and import on a second compatible physical Mac. Record unsupported combinations as such.

### P08.D Prove the Mac desktop and guest Metal

- [ ] **P08-26** Add guest-side OS/build/Metal device/feature inventory and a real Metal render/compute check with validated output. A visible `VZVirtualMachineView` is not proof of application GPU execution. A private development Metal probe now validates every output of a 1,048,576-element Metal workload and passes in the macOS 26.6.2 guest on Apple Paravirtual device. Feature inventory, render workloads and production-path collection remain open.
- [ ] **P08-27** Test Setup Assistant, login, repeated boot/shutdown, suspend/restore, host sleep/wake, display resizing, keyboard shortcuts, trackpad gestures, audio, clipboard, shared folders and ordinary browser/productivity use. P01 admission and diagnostic control tests do not qualify native saved-memory execution; a real prepared IPSW/platform bundle is required for that campaign.
- [ ] **P08-28** Run representative Xcode build/debug and guest graphics workloads with fixed resource allocations. Compare CPU, storage, GPU work and display latency separately; do not generalize one score to “native speed.”
- [ ] **P08-29** Implement a production-path Mac live qualification campaign using the actual daemon and signed `DoryVMM.app`, with exact IPSW/guest/runtime/configuration identities and artifact capture.
- [ ] **P08-30** Promote the current experimental Mac admission only after install, update, recovery, guest Metal, sustained use and release gates pass. Rename misleading “qualified” booleans that currently mean “backend available.”
- [ ] **P08-31** Repair stop/discard of an already suspended Mac as one transaction. Current daemon stop removes its saved-state wrapper while the Mac bundle can remain suspended, leaving the next start dependent on a deleted receipt. Coordinate backend state/artifact cleanup and daemon transition to cold-stopped; test interrupted discard without modifying the guest disk.

**Exit:** a fresh Mac installation reaches usable accelerated desktop through the product, relaunches without its installer, respects all device/privacy policy and survives stop/suspend/recovery/upgrade paths with correct identity and data.

<a id="phase-p09"></a>

## P09. Guest tools, input, display, audio and daily desktop use

**Existing code:** desktop presentation/clipboard/input code; `dory-core/agent`, `transfer-helper`; `DoryOperations/DoryGuestIntegration*`; `DoryVMMKit/`; `GuestTools/`; camera bridge/extension modules; host audio/USB backends; machine UI.

- [ ] **P09-01** Define one small versioned guest-tools protocol with capability negotiation, guest OS/build/architecture, heartbeat, addresses, shutdown, resize, clipboard/file transfer and diagnostics. Reuse existing framing and identity primitives; avoid another general RPC platform.
- [ ] **P09-02** Build/install/update/uninstall tools for Linux ARM64, Linux x86_64 and macOS ARM64. Distinguish the current Mac camera application from a complete guest agent; implement the missing general service explicitly.
- [ ] **P09-03** Tools absence, version mismatch or failure must degrade integrations visibly while leaving boot, base input/display and guest networking usable. Never substitute helper liveness for a guest heartbeat.
- [ ] **P09-04** Complete keyboard layouts, modifiers, dead keys, composed text/IME, host shortcut capture/release, key repeat and release-on-focus-loss. Test common non-US layouts, accessibility shortcuts and recovery from a lost input connection.
- [ ] **P09-05** Qualify relative/absolute pointer modes, high-resolution scrolling, trackpad gestures where supported, cursor hotspots, pointer capture and release. Reset all pressed keys/buttons when a window disconnects.
- [ ] **P09-06** Share host presentation behavior across Linux and Mac: scaling, selected physical screen, full-screen transitions, monitor removal and window restoration. Dedicated-display mode is a host window arrangement with a reliable exit route, not GPU passthrough.
- [ ] **P09-07** Complete independent Linux multi-display topology, per-display scale and runtime reconfiguration only within the advertised matrix. Preserve explicit Mac topology limits.
- [ ] **P09-08** Implement clipboard disabled/read/write/bidirectional policy only where enforceable. Bound payload size/types; handle rich text, Unicode, large payloads, loop suppression and focus/multi-VM isolation. Unsupported directional behavior must reject, not degrade to bidirectional.
- [ ] **P09-09** Implement cancellable file transfer/drag-drop with explicit destination authority, size limits, progress and safe overwrite handling. Do not allow guest paths to select arbitrary host destinations.
- [ ] **P09-10** Qualify speaker/microphone format negotiation, latency, route changes, Bluetooth/wired devices, mute, permissions, unplug, sleep/wake and multi-VM mixing. Prevent stale microphone capture after a VM stops.
- [ ] **P09-11** Qualify camera as an optional capability: host permission, frame format/rate, bounded buffering, timestamps, reconnect, privacy indicator and guest extension activation/update/removal. Maintain A/V synchronization and revoke access on stop.
- [ ] **P09-12** Qualify supported USB classes and lease ownership with unplug/reset/conflicting host access. Keep general passthrough optional until its platform/device matrix passes; a disk image attachment does not qualify it.
- [ ] **P09-13** Expose accurate guest integration health and actionable repair/install prompts. Do not make users read implementation names or renderer tuple hashes during ordinary setup; retain those in diagnostics.
- [ ] **P09-14** Test simultaneous VMs with different clipboard, microphone, camera, share and display policies. Events and devices must never cross machine identity boundaries.
- [ ] **P09-15** Test host app accessibility: VoiceOver labels/order, keyboard navigation, reduced motion, contrast, scalable text and errors/progress announcements. Verify guest input remains usable while host accessibility features are active.
- [ ] **P09-16** Qualify daily journeys: create, install, login, open browser/editor, share a project, build it, attach a terminal, resize/full-screen, suspend/resume, shut down and reopen. Run the same journey after upgrading Dory and guest tools.

**Exit:** the supported desktop feels locally integrated, with bounded and truthful capabilities. Optional physical-device limitations cannot hide failures in core display, input, storage or network behavior.

<a id="phase-p10"></a>

## P10. Durable storage, snapshots, backups and recovery

**Existing code:** `DoryOperations/DoryDataDrive*`, operation journals/leases, machine artifact authority; `DorydKit/DoryMachineSavedState.swift`, clone/import/export/backup managers, workspace mutation coordinator; firmware variable stores; VZMac bundle and portable operations; raw block backends.

### P10.A Storage correctness and resource ownership

- [ ] **P10-01** Define the machine-owned artifact set for each cell: disks, firmware variables or Mac auxiliary storage, identities, configuration, tools metadata, logs and optional saved state. Separate reconstructible cache from irreplaceable guest data.
- [ ] **P10-02** Use descriptor-rooted operations and exclusive machine leases for all disk/identity mutations. Validate file type, owner, permissions, symlinks and volume identity before opening or replacing a resource.
- [ ] **P10-03** Preserve sparse allocation and APFS clone opportunities where supported; account for allocated versus virtual capacity and clone divergence. Reserve temporary/recovery headroom before installation, conversion, snapshot and upgrade.
- [ ] **P10-04** Make resize a stopped or explicitly supported coordinated operation. Grow safely; reject shrink until a complete guest-filesystem-aware path exists. Do not report filesystem growth merely because the disk file grew.
- [ ] **P10-05** Validate read-only disks, flush/fsync ordering, host cache mode, short writes, ENOSPC, EIO, data-drive disconnection and remount. Surface a durable storage failure rather than silently continuing with successful guest completions.
- [ ] **P10-06** Test data-drive movement, external APFS drives, ownership changes, host restart and stale lock recovery. Ordinary app uninstall/component removal must preserve VM and container workload data.

### P10.B Snapshot and restore semantics

- [ ] **P10-07** Ship verified stopped/cold snapshots first for all three cells. Atomically include every required disk/identity/firmware artifact; expose their crash-consistent or application-consistent guarantee accurately. The [2026-09-05 ARM Alpine cold-snapshot matrix gate](docs/virtualization/evidence/p05-arm-2026-09-05/alpine-matrix-cold-snapshot.json) passes four boots, nine console steps and both stopped capture/restore actions; the final guest verifies the original sentinel exists and the post-snapshot sentinel does not. This exercises ARM disk/NVRAM rollback on the development runner, not production app/daemon shipping, RAM restore, or the other guest architectures.
- [ ] **P10-08** For a live snapshot, implement freeze → stop new work → drain/fence → capture → validate → publish → resume. For durable suspend, retain the validated saved artifact and stop/release the helper after commit instead of resuming it. Dory-owned Linux state includes vCPU, RAM, clocks, interrupts, queues and pending requests; macOS uses Apple’s opaque VZ save/restore payload plus supported validation and Dory’s outer transaction.
- [ ] **P10-09** Never serialize host JIT code or stale GPU handles. Regenerate translation caches and reestablish renderer mappings/resources only through a implemented restore protocol. If accelerated state cannot be restored safely, reject live GPU suspend and offer a cold snapshot.
- [ ] **P10-10** Keep a compatibility manifest for execution/machine/device/firmware/state schemas, CPU profile, host/runtime requirements and effective configuration. Missing compatibility evidence fails restore before guest data changes.
- [ ] **P10-11** Prevent cross-resource partial restore: verify all hashes/required files first, stage the target, commit once, retain previous state until validated. Test every process-kill and disk-full boundary.
- [ ] **P10-12** Implement snapshot delete/retention with reference tracking; do not remove shared base data still used by clones or backups. Bound storage growth and show actual recoverable points.

### P10.C Backup, clone, import and recovery

- [ ] **P10-13** Define clone versus restore identities for Linux UUID/MAC/agent credentials and Mac platform identity. Prevent simultaneous use of duplicate guest-control credentials or conflicting MACs.
- [ ] **P10-14** Export portable cold bundles with versioned manifests, hashes, sparse-preserving storage and declared dependencies. Do not include host-bound saved RAM states as generally portable.
- [ ] **P10-15** Import into a staged destination, validate format/size/architecture/required runtime and identity policy, then register the machine. Reject malicious archive paths, symlink escapes, compression bombs and backing-file references.
- [ ] **P10-16** Wire existing backup scheduling to verified exports and restore drills. Keep a last-known-good local recovery point; do not advertise remote/offsite backup that is not implemented.
- [ ] **P10-17** Implement startup reconciliation for interrupted install/update/snapshot/import/restore and orphaned processes. Use journals and verified resources to propose safe recovery; never infer permission to discard a guest disk.
- [ ] **P10-18** Add `doctor`/repair operations for stale state, missing component, invalid firmware variables, incompatible save, failed update and detached data drive. Every repair states whether it changes configuration, discards volatile state or modifies durable data.
- [ ] **P10-19** Test backup restoration on a second compatible physical host, guest update rollback, Dory upgrade rollback and schema incompatibility. A successful archive hash is not a successful recovery drill.

**Exit:** supported guests survive ordinary failure and upgrade scenarios without data/identity loss, and the team can demonstrate restore from a verified backup. Live migration and portable running-GPU snapshots remain outside the initial release scope.

<a id="phase-p11"></a>

## P11. Networking and host filesystem behavior

**Existing code:** raw-HV/PC GVProxy adapters, daemon network planners/reconcilers, `DoryCore` network contracts, Rust dataplane/agent, `DoryFSWorkerServiceCore/`, `DoryHV/VirtioFS.swift`, `DoryPCVirtioFSPCI.swift`, VZMac configuration.

### P11.A Networking

- [ ] **P11-01** Define supported modes per cell: shared NAT by default, isolated/no-network when selected, and bridged/LAN-visible modes only with working host authority and qualification. Reject unsupported requests instead of substituting NAT.
- [ ] **P11-02** Validate DHCP, IPv4/IPv6, DNS resolution/search domains, MTU, fragmented traffic, TCP/UDP, connection teardown and address renewal. Preserve stable machine MAC/IP identity where promised.
- [ ] **P11-03** Reuse one host-port publication and conflict-resolution authority. Bind localhost by default; keep LAN exposure explicit; clean up only rules/routes/processes owned by the VM.
- [ ] **P11-04** Qualify corporate proxies, trusted CA configuration, split DNS, VPNs, Wi-Fi/Ethernet switching, sleep/wake and host network loss. Report environmental unavailability separately from a broken guest NIC.
- [ ] **P11-05** Carry Mac networking policy into actual VZ attachment and forwarding. Do not assume Linux GVProxy implementation means Mac NAT/forwarding parity is finished.
- [ ] **P11-06** Bound packet queues, connections, socket buffers and idle work. Measure syscall/copy overhead, queue stalls, drops and resource leaks; optimize offloads only after correctness tests.
- [ ] **P11-07** Remove obsolete QEMU-named transport/control assumptions after all active Dory paths consume the chosen protocol. Preserve interoperability tests for actual network behavior, not just command spelling.
- [ ] **P11-08** Test simultaneous VMs/container engine, duplicate ports/subnets, malicious traffic, helper death, daemon restart and privilege loss. Host DNS/routes/firewall must return to the expected state after teardown.

### P11.B Host sharing

- [ ] **P11-09** Define host shares as a specific filesystem contract, not universal Linux POSIX storage. Keep Linux root filesystems and databases on guest block disks unless the required sharing semantics are proven.
- [ ] **P11-10** Preserve descriptor-rooted containment and explicit read-only/read-write authority. Test symlink escape, directory replacement, path races, revoked roots and external-volume identity changes.
- [ ] **P11-11** Qualify case sensitivity, Unicode normalization, hard links, symlinks, rename-over-open, unlink-open, permissions/UID mapping, timestamps, sparse files, locks and fsync behavior. Document inherent host-filesystem limits in product help.
- [ ] **P11-12** Implement or explicitly reject FUSE xattr operations and filesystem-wide sync according to supported semantics. Existing host helpers do not prove those operations are exposed to the guest.
- [ ] **P11-13** Test mmap, guest/host concurrent writes, editor atomic-save patterns, rapid rename, build tools, file watchers and cancellation. Validate guest-visible errors and data after worker restart.
- [ ] **P11-14** Keep metadata TTL zero while coherent caching is ineligible. Remove stale comments claiming it is enabled. Before enabling caching, prove invalidation under rename/replacement, lost/coalesced FSEvents, overflow, root changes and dirty pages.
- [ ] **P11-15** Qualify stock-kernel behavior without Dory notification extensions and managed-kernel behavior with them separately. Do not add a PC notification extension unless the selected cache policy needs it.
- [ ] **P11-16** Keep DAX deferred unless a measured workload requires it. Any later implementation needs correct truncation, permissions, mapping granules, invalidation, revocation and crash semantics.
- [ ] **P11-17** Reuse the same file service through MMIO and PCI; reduce request copies/batch overhead only after protocol conformance. Do not create a second filesystem server for x86.
- [ ] **P11-18** Measure git status/checkout, package-manager installation, compilation, Python environments and large-tree traversal on host shares and guest disks. Publish the difference honestly and guide users to guest disks when required.

**Exit:** supported developer and desktop workloads have predictable network/share behavior, correct failure recovery, and measured performance without host-state corruption or filesystem overclaims.

<a id="phase-p12"></a>

## P12. One usable app, CLI and API

**Existing code:** `Dory/Features/Sheets/NewMachineSheet.swift`, `Dory/Features/Machines/`, `Dory/Models/AppStore.swift`, machine runtime adapters, `DorydKit/MachineManager.swift`, operation projections/events, existing CLI command surfaces.

- [ ] **P12-01** Implement one creation journey: select Linux or macOS; inspect/select compatible media; show detected architecture, native/translated execution, effective graphics, resources and integration permissions; then prepare/install.
- [ ] **P12-02** Remove macOS Intel and Intel-host options and stale QEMU/FEX/Rosetta claims from full-machine creation. Preserve clear separate application-translation wording for the existing container product.
- [ ] **P12-03** Make component requirements visible and versioned: base runtime, x86 translator/firmware where separately packaged, Linux graphics/guest tools, Mac tools. Installation failure cannot alter the requested architecture or silently select another backend.
- [ ] **P12-04** Expose actual install/boot/tools/desktop progress with cancellation and recoverable errors. Progress must follow observed stages, not fixed timers or the existence of a process.
- [ ] **P12-05** Project effective capabilities from the resolved/runtime result into settings. Disable unsupported operations with a specific explanation; do not show controls whose values are ignored by the runner.
- [ ] **P12-06** Make start/stop/restart/reset/pause/suspend/snapshot/clone/export/import/delete semantics identical across app and CLI, subject to cell capabilities. Destructive actions identify the exact machine and affected durable/volatile data.
- [ ] **P12-07** Provide stable machine-readable command output, operation IDs, progress and exit codes. Keep diagnostics separate from normal stdout so scripts do not parse human log lines.
- [ ] **P12-08** Reuse existing event streams/projections; remove duplicated polling/state caches that can contradict daemon truth. Handle reconnect, missed events and daemon restart through versioned snapshots plus events.
- [ ] **P12-09** Extract bounded responsibilities from `MachineManager` and `AppStore` only after public-operation tests exist: media/install, lifecycle, artifact mutation and UI projections. Delete the moved duplicate paths; avoid adding generic factories or plugin registries.
- [ ] **P12-10** Migrate existing managed Linux definitions, resources, tools and saved data. Show unavailable legacy architectures explicitly; never erase an old machine because the new resolver rejects it.
- [ ] **P12-11** Add end-to-end journeys from a clean account and an upgraded account: installation, offline installed-VM boot, resource changes, component removal, failed update, recovery export and uninstall preservation.
- [ ] **P12-12** Align public website/help/release metadata with the qualified matrix at release. Remove stale future-QEMU and universal-GPU statements. Keep this file as the internal delivery guide; public user help describes released behavior.

**Exit:** users and automation see the same truthful runtime behavior, progress, capabilities and recovery actions, without needing knowledge of internal package or renderer names.

<a id="phase-p13"></a>

## P13. Security, components, licensing and build discipline

**Existing code:** machine/operation/file authority modules; guest parsers; JIT runtime; renderer and filesystem worker services; signed-component importer, production trust/activation, sandbox profiles, release inventory/build scripts and workflows.

- [ ] **P13-01** Maintain a concise threat model in this file: untrusted guest CPU/code, disk/firmware/media, device descriptors, GPU commands, file paths, guest tools, downloaded components and hostile local IPC peers. Identify the parser, authority and resource budget at each boundary.
- [ ] **P13-02** Keep least-privilege process separation: app/daemon policy, VM execution/JIT, renderer foreign code and host file service. Grant only required files, Mach/XPC services, sockets and devices; test the actual packaged sandbox profiles.
- [ ] **P13-03** Verify local IPC peer identity and machine generation; bound request size, client count, duration and pending work. Avoid unauthenticated EOF-delimited servers or PID-only trust.
- [ ] **P13-04** Fuzz media/firmware/ELF/UEFI variables, x86 decode, virtqueue descriptors, GPU commands, file protocol and guest-agent messages with memory/time budgets. Turn vulnerabilities into minimized regressions.
- [ ] **P13-05** Validate JIT W^X/publication/reclamation on signed builds. Keep generated host code nonpersistent and separate from untrusted serialized guest state. Audit pointer authentication/ABI assumptions at C/Swift/assembly boundaries where relevant.
- [ ] **P13-06** Prove resource-exhaustion behavior for guest RAM, JIT code, descriptors, queued work, sockets, threads, textures/blob mappings and disk allocation. Per-object limits must also have aggregate per-VM and global limits.
- [ ] **P13-07** Make every optional component install transactional: verified manifest/signature/digest, architecture/OS/ABI check, bounded extraction, staged activation, rollback and cleanup. Pin all build inputs and reject unexpected dynamic libraries/RPATHs.
- [ ] **P13-08** Ensure no runner or guest integration downloads mutable executables at launch. Installed-machine boot works offline with its already installed runtime components; updates are explicit versioned operations.
- [ ] **P13-09** Audit production QEMU debt from source through built artifacts, linked libraries, helper processes and package manifests. Distinguish allowed external comparison tools from shipped execution/conversion dependencies. Do not treat a source scan with an allowlist as proof debt is zero.
- [ ] **P13-10** Complete SBOM/license attribution for Dory, Rust crates, EDK II, Linux, Mesa, virglrenderer, ANGLE, MoltenVK and patches. Resolve actual source/provenance obligations; owning the VMM does not remove upstream licenses.
- [ ] **P13-11** Use Apple-supported acquisition of macOS restore media and persist provenance; avoid bundling Apple installation media in Dory. Verify distribution/licensing requirements against current authoritative terms before release.
- [ ] **P13-12** Separate release, engineering and synthetic receipts. A developer-signed unnotarized probe cannot unlock a release feature. Sign/notarize the actual app/helpers and verify Gatekeeper behavior on a clean physical host.
- [ ] **P13-13** Redact support bundles by default: credentials, guest file contents, clipboard, private paths, camera/audio data and raw memory. Retain useful hashes, versions, stage failures and bounded traces with explicit diagnostics consent where needed.
- [ ] **P13-14** Test component tampering, downgrade, wrong architecture, stale signature, malicious archive, missing worker, denied permission and revoked share/device. Failure must leave existing VMs/data intact.
- [ ] **P13-15** Remove obsolete privileged helpers, entitlements, build jobs and optional packages after their final runtime dependencies are gone. Keep a release inventory check preventing them from reappearing.

**Exit:** the exact shipped composition has bounded trust/resource boundaries, recoverable component updates, complete provenance and no unresolved critical/high-severity issues in the supported surface.

<a id="phase-p14"></a>

## P14. Performance and physical qualification

Performance work starts with instrumentation during earlier phases; qualification happens only after correctness. This section replaces the deleted Linux VM performance contract and carries forward the still-required container-engine evidence contract.

### P14.A Measurement ownership and comparators

- [ ] **P14-01** Implement one candidate-bound result schema containing source revision/dirty status, app/runner/firmware/renderer/tools/kernel hashes, host model/SoC/RAM/OS/build, guest build/configuration, architecture/execution/profile, harness version, commands, timestamps, raw samples, correctness and cleanup outcomes.
- [ ] **P14-02** Record clocks and measurement points: operation accepted, runner spawned, VM started, guest booted, desktop ready, input sent/received, rendering submitted/completed, frame presented, disk flush complete. Calibrate host/guest timing or measure an end-to-end host interval; do not subtract unsynchronized clocks.
- [ ] **P14-03** Measure the full attributable process set: daemon, runner, workers, relevant helpers and guest memory. Report CPU/physical footprint, GPU allocations, code cache, FDs/threads, disk logical/allocated bytes and post-teardown reclaim. Missing attribution remains unavailable.
- [ ] **P14-04** For ARM CPU overhead, compare a matched native workload/minimal HV harness where semantics are comparable, then the same Linux workload in a qualified same-host VMM. Report OS/compiler/library differences explicitly; never present a cross-OS score as pure hypervisor overhead.
- [ ] **P14-05** For Mac, compare the same guest OS/workload/resources through a minimal supported VZ reference and the Dory production path; use host-native comparisons only when workload semantics match.
- [ ] **P14-06** For x86, compare pinned full-system translated execution with identical guest image/resources on the same Apple Silicon host. Report absolute usability and scaling as well as relative speed. Native physical x86 is a correctness/reference context, not an equivalent host-performance denominator.
- [ ] **P14-07** Run cold and warm/cache conditions separately. Balance run order, warm up deliberately, retain all valid samples and failed samples with reasons; record power source, low-power mode, thermal condition and competing host load.
- [ ] **P14-08** Use repeated runs and distributions: median, p95/p99 where sample count supports them, variance and confidence intervals. Define speedup as reference elapsed time / Dory elapsed time for timed work, or Dory throughput / reference throughput for throughput; the proposed 20% geometric-mean target means a ratio of at least 1.20. Freeze the key-workload list before running comparisons. Do not estimate tail latency from a handful of runs or infer causation from one faster sample.
- [ ] **P14-09** Instrument DBT cache/fallback, CPU exits/interrupts, block flush, network queues, file service, GPU command/fence/copy/presentation and UI stages. Optimize the dominant measured cause, then rerun correctness and the affected whole-workload gate.

### P14.B Proposed budgets to calibrate and freeze

These are **initial engineering targets**, not results or current support claims. P00/P14 calibration must assign numeric limits to every applicable host/resource/profile cell before a release candidate is judged. If a target is unrealistic, revise the supported resource class or scope explicitly; do not lower it after a failing candidate merely to pass.

| Dimension | Initial target / decision rule | Measurement boundary |
|---|---|---|
| Native CPU microbenchmark | At least 95% throughput of equivalent host-native code and at least 97% of minimal HV/VZ orchestration where a valid comparator exists | Release executable, repeated matched loops and broader compute cases; no desktop inference |
| Native whole-workload overhead | Target within 10% of the same guest workload/resources on a minimal/qualified same-host native-virtualization reference | Build, compression, language runtime and interactive applications; each reported separately |
| x86 translated compute | Target at least 20% geometric-mean improvement over the pinned full-system reference suite, with no key workload more than 10% worse; also meet absolute interactive budgets | Identical x86 guest/image/compiler/resources; keep this as an ambition until measured |
| Linux/Mac display at 1080p60 | Under a specified normal interactive workload, p95 frame interval ≤16.7 ms, p99 ≤33.4 ms, and ≤1% missed 60 Hz deadlines | Continuously demanded updates through completed host presentation; exclude intentional idle frames and freeze refresh/timestamp tolerance before measuring |
| Input-to-visible-update | Target p95 ≤50 ms and p99 ≤100 ms on the declared desktop profile | Injected input to verified changed frame; no IPC-only latency claims |
| Resize-to-stable-content | Target p95 ≤250 ms after final resize event for normal desktop workload | Correct guest resolution/scale and completed nonstale presentation |
| Installed cold boot | Initial target ≤30 s ARM Linux, ≤60 s macOS, ≤120 s x86 Linux to the defined ready point | Fixed disk/cache/resource state; installer and deliberate filesystem-repair cases separate |
| Idle behavior | Target total attributable VM/helper CPU ≤5% of one host core for an idle desktop; headless target ≤2%; no busy polling | Fixed sampling interval with host/guest workload state recorded |
| Storage and network | Target ≥90% of comparable same-host baseline throughput; no more than 10% p95 regression at matched queue depth/concurrency | Correct data, identical durability/MTU/offload/cache policy, not guest-cache bandwidth |
| Memory and resources | Freeze per-profile guest RAM + host overhead + DBT/GPU budgets; no unbounded growth; resources return within a declared grace period after stop | Attributed physical footprint and resource objects; no double-counting shared mappings |
| Reliability | Zero data-corruption/checksum errors and zero unexpected VM/worker crashes in the required campaign | Failures remain recorded; retry does not erase an unsuccessful observation |

For 4K/high-refresh/multiple-display operation, define separate host resource classes and budgets. Do not force an entry-level host through a high-end test profile and then silently change resolution, vCPU count or graphics mode. Numeric CPU/GPU/memory ceilings that remain uncalibrated are an open release gate.

### P14.C Physical matrix and campaigns

- [ ] **P14-10** Qualify the oldest supported Apple Silicon generation/resource class, a midrange machine and a high-resource machine, covering every advertised host OS/API branch. Include a low-memory configuration deliberately; use resource admission to reject unsupported profiles.
- [ ] **P14-11** For each Linux ISA, run at least two independent general-purpose distro families plus the diagnostic fixture. Add each marketed distro/version, kernel/Mesa profile and architecture to the matrix explicitly. Test stock and managed graphics paths separately.
- [ ] **P14-12** For Mac, run the selected compatible guest builds across the advertised host matrix, including install, update and recovery. Beta host or guest results stay separate from final-release support.
- [ ] **P14-13** Cover 1/2/4/8 vCPU configurations where admitted, small/typical/large guest RAM, one and multiple VMs, internal and qualified external data drives, offline boot and network changes.
- [ ] **P14-14** Run at least 100 start/stop/reboot cycles per required cell, repeated suspend/restore where supported, and a sustained 48-hour mixed desktop/development session on each release-critical composition. Freeze exact counts in the campaign manifest before execution.
- [ ] **P14-15** Run installation → disk reboot → tools install → guest update → Dory update → rollback/recovery journeys, including disk-full, process kill, worker crash, host restart and data-drive disconnect injection.
- [ ] **P14-16** Verify actual GPU APIs/device identities and pixel correctness before frame-rate tests. Include sustained CPU/GPU/storage/network load and concurrent VMs; inspect thermal throttling rather than hiding it.
- [ ] **P14-17** Check security/resource negative cases on packaged binaries: malformed requests, denied/revoked permissions, stale handles, memory exhaustion, invalid signatures and unavailable components.
- [ ] **P14-18** Generate a human summary only from validated raw artifacts. Bind every qualified capability and budget to the exact candidate; relevant artifact/configuration changes invalidate affected results.
- [ ] **P14-19** Maintain a regression triage loop: reproduce, minimize, identify ownership, fix, rerun the focused failure and affected end-to-end gate. Avoid “fixes” that merely change expected text, hide a feature, relax a timeout or remove a test without a scope decision.

### P14.D Existing container-engine performance contract carried forward

The current container runtime is valuable and must not regress while the VM programme proceeds. These obligations remain separate from full-VM qualification. No old July/August number establishes a current release performance claim.

- [ ] **P14-C01** Use the exact extracted notarized candidate, source/build/release-manifest/SBOM/archive digests and app/helper/kernel/rootfs/agent/component identities. Every comparison image must be immutable `@sha256:` content with matching platform, layers and lockfiles.
- [ ] **P14-C02** Run on a dedicated physical Apple Silicon benchmark account. The destructive isolated campaign runs one engine at a time, with matched **6 vCPU/6 GiB** and each product's recorded defaults. Compare the selected Dory, OrbStack and Colima versions; additional products require the same protocol.
- [ ] **P14-C03** Run a separate same-session matched interleaved campaign with at least **nine balanced rounds**. Record exact settings and resource allocation; invalidate comparisons with different content/architecture, memory differing by more than 5%, mutable fixtures or invalid cleanup.
- [ ] **P14-C04** Cover npm/pnpm offline dependency installs, Rails/Bundler and Composer bind workflows, cold/cached native ARM64 and amd64 BuildKit builds, framework watchers, Compose/Testcontainers readiness, warm lifecycle, cold start/wake and controlled external HTTPS/DNS/TCP/TLS.
- [ ] **P14-C05** Verify exact trees/lockfiles, service health, watcher events, durable markers and teardown before accepting timing. Separate cache generation, cold pulls, offline installs, warm lifecycle, internal networking and external networking.
- [ ] **P14-C06** Keep the existing harness responsibilities: `benchmark-user-workflows.sh`, `benchmark-developer-workflows.sh`, `benchmark-registry-npm.sh`, `benchmark-external-network.sh`, `benchmark-campaign.sh`, and `qualify-container-engine-performance.sh`. Keep workload and evidence requirements here; the campaign archive carries executable protocol inputs and results, not a copy of the changing roadmap.
- [ ] **P14-C07** Preserve raw samples, median, quartiles, range, variation and order. A parity description requires medians within 10% and overlapping distributions; a claimed win requires >10% median improvement with nonoverlapping bootstrap 95% confidence intervals from the matched campaign. Otherwise report the observed gap/inconclusive result.
- [ ] **P14-C08** Measure attributable physical footprint for the full process set, reclaim, guest RAM, threads/FDs, watcher backlog and disk growth. Keep subsystem counters diagnostic unless the actual user workflow also ran.
- [ ] **P14-C09** Preserve the separate reliability obligation: eight-hour resource/file/API endurance and more-than-24-hour unchanged TCP connection, using the existing 25-hour evidence run. Any correctness error or linear unbounded growth fails the campaign.
- [ ] **P14-C10** Publish `Dory-<version>-container-engine-performance-evidence.zip` and `Dory-<version>-reliability-evidence.zip` bound to the same candidate. Performance ZIP includes `manifest.json`, deterministic `sha256.txt`, raw harness results, generated summaries, cleanup and redaction reports; reliability ZIP includes duration completion, candidate binding and raw endurance/connection results.
- [ ] **P14-C11** Reverify both evidence families in publication after artifact download, against source/run/build/manifest/archive identity, then publish their digests with the release. Missing/failed/skipped/wrong-candidate evidence blocks claims. Temporary CI artifacts are not the stable public record.

Correctness, file coherence, durability and host permissions must not be weakened to improve a benchmark. Container results never substitute for full Linux or Mac installation, graphics, desktop and recovery gates.

**Exit:** all three VM cells meet their frozen budgets on the declared physical matrix, with complete correctness/reliability evidence; the existing container product passes its own retained gates.

<a id="phase-p15"></a>

## P15. Release the qualified product and finish removing old code

**Existing code:** `scripts/publish-release.sh`, release orchestration/qualification/verifiers, `.github/workflows/release.yml`, `scripts/build-components.py`, bundling/signing/runtime inventory and update/rollback code.

- [ ] **P15-01** Build a clean release candidate from the recorded source state with pinned firmware/renderer/guest artifacts. Package only production dependencies; exclude experiments, debug traces, unused backends and probe executables.
- [ ] **P15-02** Sign/notarize/staple the actual app and helpers/components with validated entitlements, code identity and embedded dependencies. Verify launch and Gatekeeper acceptance on a clean physical Mac.
- [ ] **P15-03** Require candidate-bound boot/install/device/GPU/lifecycle/security/performance/reliability evidence for each advertised cell. No missing row may inherit a neighboring cell's pass.
- [ ] **P15-04** Test fresh install, download interruption, offline use of installed VMs, component upgrade/removal, app upgrade, schema migration, rollback and uninstall preservation from the last supported release.
- [ ] **P15-05** Complete R01–R20 removals, verifying active call sites and persisted migrations before deletion. Remove expired compatibility flags and duplicate implementations; shrink source debt without removing current guest data compatibility.
- [ ] **P15-06** Replace old source/prose-shape tests with meaningful runtime/artifact gates. Keep small ABI projections and hostile-input regression fixtures; remove tests whose sole purpose was sustaining deleted architecture.
- [ ] **P15-07** Produce the final support matrix and capability limitations from the qualification catalog. Publish truthful native/translated and accelerated/software distinctions, exact host requirements and recovery/support procedures.
- [ ] **P15-08** Verify one release identity across app archive/DMG, component catalog, update metadata, package managers, website and evidence assets. Use the existing whole-release entrypoint; do not manually patch individual public artifacts.
- [ ] **P15-09** Run a support drill using redacted diagnostics from failed install, no desktop, GPU loss, networking failure, incompatible save and corrupted media. Ensure each maps to a tested recovery action and subsystem owner.
- [ ] **P15-10** Close every release-critical defect and removal dependency. Keep optional capability gaps explicitly unsupported; do not label the complete three-cell programme finished while any required cell is only experimental.
- [ ] **P15-11** Tag the final plan/candidate evidence and maintain this file for follow-up work. Open Windows as a separately scoped programme only after this release is stable; do not revive the retired Mac Intel effort.

**Exit:** a new user can install and operate each supported guest through the shipped app, obtain genuine accelerated graphics and the declared performance, recover failures without losing data, and upgrade safely. The team can reproduce every support claim from retained evidence.

## 6. Concrete module and interface work map

These are implementation responsibilities, not a request to create a package for every row. Existing modules remain the default home. Proposed filenames identify bounded work when no existing implementation owns it.

| Work item | Existing home | Code to add/change | Delete/consolidate when done |
|---|---|---|---|
| Effective VM plan | `DoryOperations`, `DorydKit/DoryResolvedMachinePlan.swift` | Complete typed CPU/machine/media/device policy and versioned runner input; one capability derivation | Duplicate mutable launch builders and policy defaults |
| Native CPU ownership | `DoryHV/Machine.swift`, `DoryNativeHVArm64` | Adapter/extraction of actual HV calls, vCPU thread lifecycle, GIC, clocks and barriers | Unused second production engine |
| x86 semantics | `DoryDBTX86` | Exact decoder groups, CPUID/MSRs, exceptions, memory/XSTATE, isolated differential states | Fake Xen services and broad no-op decoding |
| PC boot | `DoryMachinePC`, `DoryFirmware` | Validated ELF/PVH loader, correct PM/interrupt state and UEFI platform integration | Kernel-address/load-mask workarounds |
| Parallel DBT | `DoryPCDirectKernelMachine`, `DoryARM64BaselineJIT` | Per-vCPU executor, TSO strategy, shared memory and stop barriers; measured fast paths | Global run lock and nominal-only multicore scheduling |
| Shared device memory | `DoryExecutionContracts/GuestMemory.swift`, existing RAM/DMA accessors | One checked mapping/access contract with permissions/generation and host-backed regions | Divergent mmap/array/worker access semantics |
| Shared GPU state | `DoryVirtio` with host adapters | Context/resource/fence/blob/cursor state machine and deferred completion; proposed `DoryVirtioGPUFenceState.swift` only if needed | Duplicate raw/portable semantics and in-process test executor |
| PC GPU aperture | `DoryPCPCIExpress`, `DoryPCPhysicalMemory`, GPU transport | BAR/capability mapping, permission and DBT invalidation; proposed `DoryPCGPUSharedMemory.swift` if no current owner fits | Full-copy-only blob substitutes and dead adapter composition |
| Renderer profiles | Wire contracts, renderer backend, `Config/DoryRendererProductionTuple.json` | Small authenticated profiles, artifact/guest separation, real completion preflight | Dated tuple identity in unrelated layers and duplicated pins |
| Guest graphics artifacts | `guest/mesa`, `guest/kernel`, `guest/desktop` | Architecture-keyed build/verify/install metadata, stock/managed synchronization policy and Wayland qualification | ARM-only assumptions in common code; expired compatibility overrides |
| Mac lifecycle | `DoryVZMacAdapter`, `DoryVZMacDesktopApplication`, `DoryVZMacCore` | Correct install/first-boot/stop/suspend/restore events and effective configuration | Duplicate control server, pseudo-receipt, hardcoded policies |
| Installed artifact operations | Existing mutation coordinator, Mac bundle/recovery/portable code | Compose installed boot, snapshot/clone/import/export in the daemon | Unreachable core operations and duplicated standalone orchestration |
| General guest tools | Existing Rust agent/transports and `GuestTools` | Mac service plus architecture-specific packaging, bounded negotiation and health | Helper-identity readiness pretending to be guest readiness |
| Live guest campaigns | Existing Linux gates + proposed `scripts/macos-vm-live-gate.sh` | Production-path install/boot/Metal/lifecycle collection; exact candidate binding | Qualifying a separate demo app instead of the product |
| x86 conformance fixtures | Existing DBT/PC tests + proposed structured fixture inventory | Pinned bytes/images, expected registers/faults/memory, independent reference results | Local `/tmp` success criteria and decoder-only completion claims |
| Release catalog | Existing component/qualification manifests and verifier scripts | Exact host/guest/profile/candidate support projection with unavailable metrics | Handwritten release support claims and dummy pass records |

### 6.1 Required handoff contracts between teams

| Producer → consumer | Minimum contract | Required integration proof |
|---|---|---|
| Media → resolver | Detected ISA, format/boot type, immutable digest, logical/allocated size, validated artifact authority | Wrong architecture and altered media reject before allocation |
| Resolver → runner | Immutable plan ID/fingerprint, effective resource/device policy, versioned identities, granted descriptors/resources | Runner starts exactly the approved composition or returns a typed error |
| CPU → machine | Exit reason, precise guest state, accessed address/width, pending operation, cancellation/barrier state | MMIO/fault/interrupt delivery works identically across interpreter/JIT where applicable |
| Machine → device | Checked DMA authority, queue/device generation, virtual clock, IRQ sink | Reset and late completion cannot touch a newer machine generation |
| GPU → worker | Immutable commands, bounded resources, context/worker generation, expected completion/fence | Validation and GPU execution errors reach the correct guest response |
| Worker → display | Validated texture/blob lease, format/geometry, producer completion and retirement contract | No stale frame, premature buffer reuse or leaked resource under resize/reset |
| Guest tools → daemon | Machine-bound version/capabilities, observed readiness/health, bounded operations | Tools absence is distinguishable from VM death or a hung desktop |
| Runtime → persistence | Quiesced state inventory, ABI/configuration/host constraints, payload hashes | Incompatible/incomplete state rejects before partial restore |
| Qualification → release | Exact candidate/host/guest/profile, commands/raw data, verdicts/limits, signature and provenance | Missing/changed evidence cannot unlock a release capability |

### 6.2 Per-task completion record

For every checked task record: **owner; source commit; affected entrypoints; regression test or physical command; input/candidate hashes; result artifact; observed limitations; reviewer; removed old path.** Use existing structured evidence infrastructure. Do not create a new bespoke ledger package or a separate Markdown progress report.

## 7. Test strategy and team review gates

| Layer | What it proves | What it cannot prove |
|---|---|---|
| Pure unit/spec vectors | Parser bounds, instruction/device semantics, state transitions | A real OS/application works |
| Independent differential CPU checks | Architectural agreement for tested forms/states | Every instruction combination or whole-system timing |
| Composed runner tests | Real launch inputs, policy handoff, lifecycle, IPC and artifact ownership | Physical GPU/framework behavior when substitutes are used |
| Pinned guest boot tests | Kernel/userspace and machine/device integration | Installer/update/desktop usability |
| Production-path live tests | Installation, application output, integration and recovery on exact hardware | Untested hosts/guests or an altered release binary |
| Performance/reliability campaigns | Declared workloads/budgets over measured duration and matrix | Universal native speed or absence of all future faults |
| Signed release validation | Shipped identities, provenance, packaging and retained evidence | Runtime correctness without the preceding layers |

- [ ] **Q01** Every CPU/device fix includes the minimal reproducer and the relevant real-guest rerun; every durable-data change includes interruption/recovery checks.
- [ ] **Q02** Tests requiring external guest fixtures declare acquisition, immutable identity and expected absence behavior. Required jobs fail when data is missing; local optional skips remain visible.
- [ ] **Q03** Semantic tests assert outputs, faults, lifecycle and resource effects. Avoid tests that mirror function structure or require a particular prose sentence.
- [ ] **Q04** ABI/serialization fixtures are allowed when they protect actual compatibility. Derive them from one owner and review intentional version changes.
- [ ] **Q05** Use sanitizer/race/fuzz runs for native memory, concurrent CPU/device access and untrusted parsers where supported. Track unsupported tooling explicitly rather than claiming clean results from jobs that never execute.
- [ ] **Q06** Keep long physical campaigns separate from fast PR gates, with required pre-release execution and artifact retention. Do not trigger destructive campaigns in a developer's ordinary active account.
- [ ] **Q07** Every optimization demonstrates correctness parity plus a statistically credible improvement in a relevant user workload, without unacceptable latency/resource regressions.
- [ ] **Q08** Before deleting an implementation, remove all production call sites, migrate persistent values and replace required coverage. Deleted behavior should remove its tests; preserved safety must retain behavioral tests.

## 8. Main risks and decision points

| Risk | Earliest decisive evidence | Response if it fails |
|---|---|---|
| x86 CPU semantic breadth/TSO too incomplete | P02 real userspace plus independent vectors; P07 SMP litmus | Reduce advertised CPU profile, correct semantics and defer the x86 support date; no native-speed promise |
| Stock Linux GPU synchronization differs from managed kernel | P06 adversarial producer/fence/scanout runs on stock guests | Require explicit guest package or keep that profile experimental; never bypass synchronization proof |
| PC Venus mapping invalidates DBT assumptions | P06 concurrent BAR/map/reset/code-invalidation tests | Keep PC Vulkan closed while fixing shared-memory authority; retain qualified VirGL profile separately |
| Apple public Mac APIs lack a requested feature | Selected final SDK/runtime tests and actual guest behavior | Expose the supported subset and exact limitation; no private API dependency or new Mac emulator |
| New contracts add layers without production ownership | P01 call graph and composed tests | Merge redundant layers; stop adding packages until a concrete owner is established |
| Custom CPU/GPU maintenance exceeds team capacity | P00 staffing and repeated bring-up/patch burden | Sequence releases by cell, reduce optional scope and staff critical expertise; preserve architecture correctness |
| Snapshot/upgrade damages guest data | P10 crash/failure injection and restore drills | Block release, retain original artifacts and fix commit/rollback boundaries |
| Large tests pass without real behavior | P00 test inventory and P14 candidate/fixture checks | Replace shape assertions and mock-only qualification with real product-path evidence |
| Performance gains come from changed semantics/settings | Matched P14 protocol and correctness checks | Invalidate the result; restore comparable durability/resources/content |
| Documentation drifts again | Changes to this file reviewed with affected code | Update the relevant section and evidence links; do not start another competing plan |

## 9. First implementation assignments

The baseline and initial control-plane composition are already recorded. Assign current gaps, with one file owner per active change and a coordinator reviewing integration. Use GPT-5.5 workers for bounded work; do not launch multiple agents rewriting the same CPU/device owner.

| Workstream | Next implementation | Reviewable acceptance |
|---|---|---|
| Test/dead-code cleanup | Remove source-spelling/prose tests and disconnected production facades after consumer search; update active test entrypoints. | Smaller source/test surface, preserved behavioral/security/ABI coverage, focused suites pass. |
| Native ARM | P03 vCPU lifetime, cancellation and owner selection; direct/UEFI regression baseline. | No destruction of a running vCPU; existing workloads preserved under one production owner. |
| macOS lifecycle | P08-01/02 install-to-first-boot, then saved-state authority and actual device policy. | Production orchestration starts exactly once after install, remains alive until real shutdown, and reports failures correctly. |
| CPU correctness | Remaining P02-11–16 fault/state/FP cases plus P02-20 independent x86 reference. | Minimal architectural regressions and affected pinned guest rerun; no widened CPU claims from decoder coverage. |
| Devices/PC boot | P04 shared queue/device parity and P05 installer-to-installed-disk boot. | Same observable queue semantics over MMIO/PCI; installed guest boots without installer media. |
| Graphics/guest/containers | Priority P06: reuse ARM worker for container compute, connect PC VirGL and x86 artifacts, and qualify Venus mapping/synchronization. | Correct GPU-compute output in real containers and real accelerated VM desktops through production runners; no fake fences or software substitution. |
| Performance | Profile the real ARM workload and x86 baseline-JIT fallbacks after correctness fixes. | Matched user workload improvement with unchanged semantics; report native and translated results separately. |
| Product/release | Integrate each working cell into app/CLI and run candidate-bound physical campaigns. | Truthful capabilities, recoverable operations and qualified installed guest behavior. |

Prioritize the ARM Linux product path for the native-performance objective while x86 correctness and Mac lifecycle proceed independently. Do not gate native progress on a speculative x86 optimizing compiler, or restart P00/P01 because their earlier narrative still exists. Every completed wave must state what was removed, what behavior changed, what actually ran, and which gates remain open.

## 10. Final completion checklist

- [ ] **DONE-01** Apple Silicon is the sole product host; Linux ARM64, Linux x86_64 and macOS ARM64 are the only guest cells in this programme.
- [ ] **DONE-02** Each cell installs from its supported ordinary media, reboots without installer dependence, updates, shuts down and recovers through the app and CLI.
- [ ] **DONE-03** ARM Linux uses the consolidated native Dory runtime; x86 Linux uses DoryDBT/DoryPC; Mac uses the supported VZMac path. No hidden QEMU runtime or architecture substitution remains.
- [ ] **DONE-04** Both Linux ISAs have qualified guest OpenGL and Vulkan acceleration; Mac has qualified guest Metal; Docker containers have qualified GPU compute through the same isolated renderer architecture. Effective application/renderer evidence rules out accidental software rendering.
- [ ] **DONE-05** CPU profiles, memory/fault semantics, interrupts/timers, device queues and parallel x86 execution pass the required correctness tests.
- [ ] **DONE-06** Display/input, storage/network, sound, shares and supported tools work through daily desktop/developer journeys. Optional capabilities and public API limits are accurately represented.
- [ ] **DONE-07** Requested privacy/device/network policy equals actual configuration; disabled integrations cannot operate.
- [ ] **DONE-08** Cold snapshots, clone/export/import, backup restore, safe upgrade and interruption recovery preserve guest data and correct identity. Any unsupported live-save capability is explicitly unavailable.
- [ ] **DONE-09** Performance budgets are frozen and met for every advertised host/guest/profile; translated CPU performance is reported separately and native-speed claims are workload-specific.
- [ ] **DONE-10** Sustained physical campaigns, failure injection, multi-VM pressure and exact signed/notarized release validation pass with retained evidence.
- [ ] **DONE-11** Obsolete implementations, false-success stubs, fixed-address diagnostics, duplicate owners and expired compatibility scaffolding identified in R01–R20 are removed or have an explicit remaining dependency and owner; release-critical ones are gone.
- [ ] **DONE-12** The existing container product retains its required correctness, compatibility, data safety, performance and reliability gates.
- [ ] **DONE-13** Public capabilities and release metadata match the qualified product, support can reproduce/repair failures, and no unresolved release-critical defects remain.
- [ ] **DONE-14** This is the only active team implementation/architecture plan. New work updates its checklist and evidence instead of rebuilding the old document sprawl.

## 11. Documentation consolidation and retained non-plan material

The earlier consolidation removed the previous root architecture/research/release/compatibility/parity plans, the empty task tracker, and the Markdown planning/evidence collection under `docs/`. Their useful findings, threat boundaries, performance obligations and delivery tasks are consolidated here. The outdated Intel Mac programme is removed.

The README is an entry link to this guide, not another roadmap. `CONTRIBUTING.md` remains a basic build/contribution manual, `CHANGELOG.md` remains release history, and package/firmware/guest READMEs remain local build instructions. Public website help and unrelated creative assets are not team implementation plans; their release claims must be synchronized under P12/P15. License texts, build locks, kernel/renderer patches, source manifests, test fixtures and machine-readable evidence remain intact.

Generated machine ABI projections were moved unchanged to `Firmware/DoryARMVirt/abi.txt` and `Firmware/DoryPC/abi.txt`; the two existing ABI tests now read those fixture paths. They preserve exact machine interfaces and are not alternative planning documents.

The old Phase 0A programme manifest and its fixed-heading document verifier/tests were removed. Readiness tests no longer require deleted documentation or enforce obsolete QEMU prose in documentation; remaining source-text policy checks are tracked for replacement. The earlier consolidation bundled `PLAN.md` in container-performance evidence; the current cleanup removes that incidental document dependency while preserving the campaign requirements and result manifest. Those historical consolidation edits did not change runtime source. The current implementation review does change source, with focused verification recorded in section 2.4.

Historical JSON receipts retain the dates, schemas and limitations under which they were collected. They are historical evidence, not active plans or current release passes. Some receipts refer to retired document names; preserve signed/historical bytes and explain provenance here rather than rewriting evidence. Retire a stale gate only when its actual consumer and replacement have been verified.

### 11.1 Current engineering entrypoints

Use `CONTRIBUTING.md` for basic setup and `scripts/test.sh --help` for the existing suite entrypoints. Main source areas are `Dory/`, `dory-core-swift/`, `Packages/ContainerizationEngine/`, `dory-core/`, `Firmware/`, `guest/`, `GuestTools/`, `DoryTests/` and `DoryUITests/`.

Before running any build/test campaign, inspect its options and cleanup behavior. Existing release/benchmark scripts can stop runtimes, remove test products or purge a dedicated benchmark account. A documentation review does not authorize those operations against active user workloads.

Release remains through the existing `scripts/publish-release.sh <version>` workflow after all applicable gates pass; this plan does not publish a release. It defines the work and evidence the team needs before doing so.
