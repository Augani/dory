# Dory desktop readiness and remaining implementation — 22 September 2026

**Reviewed source:** `3fd13806f282268a9166618ce85db8c50bcd416f`, branch `codex/virtual-workspace-foundation`.

**Requested outcome:** ordinary Linux ARM64 and Linux x86_64 desktops, plus macOS ARM64, on Apple Silicon hosts, with demonstrated guest GPU acceleration and useful devices, installation, lifecycle and recovery through Dory.

The working tree was clean before review, including untracked non-ignored files. There were no outstanding changes to commit first; no empty checkpoint commit was created. Existing ignored build/campaign outputs were inspected selectively and were not added to Git or changed.

This is a dated source audit and detailed work inventory requested for the current state. [PLAN.md](PLAN.md) remains the implementation authority. Task IDs below map to its sections; this report does not replace the agreed architecture or promote any release cell. Checked boxes mean the specifically described implementation exists, not that the entire feature is production-qualified. Unchecked boxes identify remaining code, integration, validation or release work.

## 1. Readiness assessment

**Dory has substantial infrastructure for all three guest families, but the reviewed evidence does not establish a finished, release-qualified accelerated desktop for any of them.** ARM Linux is closest to a complete graphics path. x86 Linux additionally needs substantial execution/performance work and the missing Venus memory interface. macOS uses Apple's existing virtual GPU; its remaining work is product correctness, integration and current guest qualification, not a new GPU driver.

| Guest | Execution and boot already present | Graphics already present | Principal remaining boundary |
|---|---|---|---|
| Linux ARM64 | DoryHV/Hypervisor.framework, ARM board, GIC/PSCI, virtio-mmio, direct kernel and EDK2 UEFI paths | VirGL/ANGLE and Venus/MoltenVK workers, host-visible arena, stock fence verification, app display relay | Stable stock desktop through the complete guest-render-to-window path; semantic pixel verification; installer/update/device/recovery campaigns |
| Linux x86_64 | DoryDBTX86 interpreter/JIT, PC firmware/devices, persistent vCPU workers; retained single-vCPU PVH userspace passes | Software scanout and PC VirGL2 renderer authority | Ordinary desktop install/boot performance, production SMP correctness, PCI host-visible blob aperture and Venus commands, app presentation parity |
| macOS ARM64 | VZMac install/bundle/identity, lifecycle and saved-state code, shares and network policy | Apple Mac graphics configuration; retained guest Metal probe and VM-local vsock collection | One-display admission fix, current visible Metal/lifecycle evidence, production installation/recovery, tools and separately gated optional devices |

The actual release policy remains much narrower than this target:

- [DoryVirtualizationPlatform.swift](dory-core-swift/Sources/DoryOperations/DoryVirtualizationPlatform.swift), `DoryReleaseSupportPolicy`, admits ARM Linux, explicitly excludes x86 Linux and macOS, and limits public installer identity to the pinned **Ubuntu Server 24.04.4 ARM64** ISO.
- [DoryWave0QualificationMatrix.json](Config/DoryWave0QualificationMatrix.json) has `releaseQualified: false`, a pending review, one ARM Ubuntu cell, and an unqualified VirGL2 profile. It does not describe the requested three-family desktop release.
- A public availability flag is not release evidence. Changing those flags alone would expose unfinished combinations.
- “Both architectures” in this report means ARM64 and x86_64 **Linux guests on Apple Silicon**. Intel host support, x86 macOS, nested virtualization and direct physical GPU passthrough are outside the reviewed delivery target.

### What the recent evidence actually says

1. The tracked [stock capability-reset observation](docs/virtualization/evidence/a4-2026-09-22/arm64-stock-capability-reset.json) proves that a stock ARM Ubuntu kernel can see VirGL, blob/context features and VirGL2/Venus capset metadata after a renderer reset. Its explicit exclusions include Mesa context creation, blob mapping, GPU submission and a displayed-pixel receipt. Preserve that narrow claim.
2. The locally retained `release-build/gpu-campaign-runtime-lease-ack-seq80/display-window.json` records an app window, scanout 0, frame 1 and Metal completion 1, with **`transport: cpuCopy`**. This is useful presentation evidence. It does not establish guest hardware rendering; a host Metal blit can display a firmware or software-rendered framebuffer.
3. The same local campaign's daemon log includes a runtime warning that an `@MainActor` function in `DoryApplicationProcessLauncher.swift:276` was not called on the main thread. Treat this as an unresolved diagnostic to reproduce on the rebuilt candidate, not proof of a new root cause.
4. [The retained x86 review](X86_64-LINUX-READINESS-REVIEW-2026-09-19.md), updated through the September 20 work, records two baseline-JIT PVH runs around 414/422 seconds and two interpreter runs averaging about 749 seconds at `5c07bcf44`. Those are controlled boot/userspace/ACPI-poweroff fixtures on one host, not desktop boot times and not current-head production qualification.
5. The current [Mac Metal verifier](scripts/verify-macos-guest-metal-probe.py) deliberately produces `releaseEligible: false`, even with a vsock receipt. Window visibility, lifecycle and pacing still need correlation.

## 2. Work already done that should be retained

### Linux graphics and desktop integration

- [x] Isolated renderer worker and authenticated, versioned worker contracts; capability, resource, blob-mapping and scanout leases.
- [x] ARM per-VM, generation-bound shared arena and host-granule refcounting in [VirtioGPU.swift](Packages/ContainerizationEngine/Sources/DoryHV/VirtioGPU.swift). This is the basis for handling 4-KiB guest offsets on a 16-KiB host.
- [x] Stock producer-fence profile, provisional admission and [VirtioGPUStockFenceVerifier.swift](Packages/ContainerizationEngine/Sources/DoryHV/VirtioGPUStockFenceVerifier.swift). The managed graphics stack is not the current shipping direction.
- [x] Renderer replacement/reset handling, preserved capabilities, deferred/replayed queue work and the latest boot-reset readiness repair. Recent commits also address canonical EDID requests, context cleanup and display orientation.
- [x] [DoryVMDisplayWireContracts](dory-core-swift/Sources/DoryVMDisplayWireContracts), daemon broker, runner relay and [LinuxMachineDisplayView.swift](Dory/Features/Machines/LinuxMachineDisplayView.swift). ARM Linux product windows can be owned by Dory.app.
- [x] CPU-frame throttling/coalescing, presentation acknowledgements, cursor relay, relative pointer input, display topology/hotplug and Retina policies have implementation paths.
- [x] Linux text/image clipboard transport and a live graphical-session bridge; Debian/RPM source packaging, signed offline tools-ISO producer and in-app tools media installation.
- [x] Retained [guest GPU probes](guest-probes/README.md), displayed-frame correlation, OpenGL comparison verifier and CI entry points. These are tools to acquire evidence, not completed campaigns.
- [x] Accelerated Linux saved-state suspend is rejected rather than claiming that GPU context restoration already works.

### x86 execution and devices

- [x] Decoder, interpreter, baseline/Tier1 and optimizing infrastructure, paging/TLBs, checked memory, code protection/invalidation, CPU-profile machinery and independent conformance infrastructure.
- [x] Persistent host workers, per-vCPU mutable execution state, run commands, pending-work generations, translation acknowledgements and a single-vCPU long-running session.
- [x] A narrow **internal, exactly-two-vCPU interpreter** execution policy with real overlap. Production defaults still serialize; native/mixed execution is not generally admitted.
- [x] Shared RAM/atomic coordination, owner-scoped page-walker suppression, initial guest/DMA code and page-table mutation tests, and callback-under-lock repairs.
- [x] PC PCI/interrupt/timer/firmware models; block, network, input, sound, entropy, vsock, filesystem adapters, xHCI/HID/UVC code and a host USB lease path.
- [x] A PC VirGL2 authority using bounded staging allocations. Its comment and capset filtering explicitly leave Venus hidden until a real PC host-visible aperture exists.

### macOS and common product infrastructure

- [x] Mac restore/install journal, durable bundle/identity, auxiliary storage, resource configuration, lease, saved-state and recovery code.
- [x] User shares now travel from `MachineManager.appendVZMacResolvedDevicePolicyArguments` through `--share` into `DoryVZMacAdapter` and `DoryVZMacSharedDirectory`. The old blanket “user shares are not wired” finding is stale.
- [x] Mac shared NAT, disconnected and gvproxy-backed host-only policy are present. Loopback port forwarding is supported through the host-only route; bridged mode and LAN-exposed forwarding are rejected there.
- [x] Separate audio input/output policy, bidirectional SPICE text/image clipboard, image-backed USB storage, camera bridge components and package/signature tooling exist.
- [x] [DoryGuestMetalProbe.swift](GuestTools/DoryGuestTools/DoryGuestMetalProbe.swift) retains deterministic compute/render source. [DoryVZMacMetalProbeCollector.swift](dory-core-swift/Sources/DoryVZMacCore/DoryVZMacMetalProbeCollector.swift) collects a challenged result over the selected VM's own socket.
- [x] Durable daemon operations, immutable launch planning, candidate authority, configuration revalidation, failure reporting, disk/snapshot/backup machinery and release evidence validators are already substantial. Extend them rather than building another control plane.

## 3. Findings that change the next implementation steps

| Priority | Finding and source | Required action |
|---|---|---|
| P0 for the target | No complete current three-family desktop qualification; public scope is one server ISO | Finish vertical slices and publish exact desktop matrix cells only after they pass (R1–R3) |
| P0 for ARM graphics | Latest retained tracked evidence stops at GPU discovery; recent boot/reset/display repairs need a fresh end-to-end run | Reproduce the first failing boundary, then retain stock guest shader and visible-window proof (L1–L3) |
| P0 for x86 Vulkan | [DoryPCVirGLRendererAuthority.swift](Packages/ContainerizationEngine/Sources/DoryHV/DoryPCVirGLRendererAuthority.swift):104 filters to VirGL2; no PC blob aperture lifecycle | Implement the PCI capability, checked DBT mapping and blob command path before advertising Venus (X4) |
| P0 for usable x86 desktop | Production vCPUs remain serialized; broad native/mixed SMP and practical ordinary-desktop timings are unproven | Complete the memory/execution matrix and profile real installer/userspace workloads (X1–X3) |
| P1 correctness | [DoryVZMacResourcePlan.swift](dory-core-swift/Sources/DoryVZMacCore/DoryVZMacResourcePlan.swift):80 permits eight displays; the installed macOS 27.0 SDK's `VZMacGraphicsDeviceConfiguration.h:26` says a maximum of one | Gate Mac creation/reconfiguration/restore to one display and repair tests/comments/UI (M1) |
| P1 evidence | [verify-displayed-pixel.py](guest-probes/verify-displayed-pixel.py) validates PNG magic, hashes and metadata correlation, but does not decode pixels or check a visible nonce/pattern | Add an independent image oracle; a matching hash only proves which bytes were retained (L3) |
| P1 evidence | Mac verifier independently checks compute digest but only validates the shape of the render/shader hash strings | Independently derive expected render output and approved shader identity, then correlate the live guest preview/window (M2) |
| P1 runtime investigation | Local seq80 log reports the launcher MainActor warning; source uses `Thread.isMainThread`/`assumeIsolated` and a main-queue closure | Reproduce under current Swift/runtime, implement a verified actor hop if needed, preserve nonblocking launch/handoff (C1) |
| P1 optional devices | Mac production camera requests are explicitly rejected in `MachineManager.swift:16213`; selective clipboard policies are also rejected | Implement the missing authority/integration or keep these options unavailable (M4, D5) |
| P1 documentation | PLAN baseline still says Tier1 direct chaining is selected, Mac share authority is missing, and Mac probe source is missing | Reconcile those historical summaries with current code and evidence; do not change the old receipts themselves (R1) |

The display-limit conclusion is supported by the installed SDK, not an assumption that all VZ graphics types have the same limit. Dory's Linux multimonitor implementation should keep its own capability policy.

## 4. Linux ARM64 and shared graphics checklist

### L1 — Complete one stock desktop from firmware to guest GPU output

**PLAN:** 2.3, 2.16, 3.1, 3.4, 3.5. **Type:** integration/targeted fixes plus real-guest qualification. **First dependency:** current signed candidate and owned test disk.

**Extend these existing files:** `Packages/ContainerizationEngine/Sources/dory-hv/DesktopMode.swift`, `DesktopRuntimeGraphicsReadinessState.swift`, `DesktopRendererWorkerLaunch.swift`; `DoryHV/VirtioGPU.swift`, `VirtioGPUStockFenceVerifier.swift`, `VirtioGPUGraphicsTrace.swift`; `DorydKit/DoryMachineStart.swift`, `DoryRendererBootstrapQualification.swift` and `DoryMachineDisplayPresentationStore.swift`.

- [ ] Rebuild from the reviewed head and freeze the app/daemon/runner/firmware/worker/dependency tuple. A seq60/seq80 run cannot validate code added after that candidate was assembled.
- [ ] Boot the selected stock desktop ISO through the normal daemon, install to an owned blank disk and retain serial plus graphics traces from firmware through the graphical login/session.
- [ ] Trace `GET_CAPSET_INFO → GET_CAPSET → CTX_CREATE → CREATE_BLOB/MAP_BLOB → SUBMIT_3D → producer fence → scanout → app completion`. For VirGL, record its actual transfer/resource path rather than requiring Venus-only operations.
- [ ] Fix only the first failing transition reproduced on current bytes. Cover firmware-to-kernel status reset, initial queue configuration, context ID cleanup/reuse, zero fence IDs, a reset before desktop readiness, reset after readiness, and replacement-worker failure.
- [ ] Preserve the feature/capset contract across reset while invalidating all volatile context/resource/queue generations. Avoid recreating the worker for a boot reset that should only reset guest-facing state; prove the latest deferral behavior.
- [ ] Ensure pending kicks replay once after the new queue and renderer are both usable; no command is completed twice or stranded behind an old generation.
- [ ] Preserve a useful installer/software framebuffer throughout this transition. “Desktop window exists,” “driver connected” and “verified hardware rendering” remain separate observations.
- [ ] Complete a real guest compute probe and a windowed rendering probe with software renderers rejected. Leave required-GPU failures explicit and optional fallback visible.

**Accept when:** a stock installed ARM desktop reaches a current-generation hardware-rendered visible frame and deterministic compute result through Dory.app; cold boot repeats and reset/replacement failures terminate or recover within defined deadlines. Extend `VirtioGPUStockFenceVerifierTests`, `DesktopRuntimeGraphicsReadinessStateTests`, renderer/queue tests and physical campaign cases for the reproduced defects.

### L2 — Finish arena, producer synchronization and renderer lifetime validation

**PLAN:** 3.2–3.4, 3.8. **Type:** hardening existing code; new common interfaces only where PC reuse requires them.

**Owners:** `DoryHV/VirtioGPU.swift`, `DoryRendererWorkerWireContracts/DoryRendererBlobMappingLease.swift`, `DoryRendererWorkerMetalTransport`, `DoryRendererWorkerServiceCore`, `DoryRendererWorkerVirglBackend`, `DoryVirglRendererShim`, and the renderer patches/build tuple.

- [ ] Audit every guest offset, allocation size, stride, rounded host range and arithmetic overflow before mapping or exporting. Keep the complete arena private to one VM and worker generation.
- [ ] Test overlapping 4-KiB blobs sharing a 16-KiB host granule; final-reference unmap; holes; boundary-crossing accesses; rapid resource ID reuse; memory pressure and renderer death.
- [ ] Prove backing is zeroed/owned before exposure, including padding. Cross-VM and host memory must never be reachable through padding or a stale lease.
- [ ] Centralize map/unmap retirement so guest CPU aliases, renderer references and in-flight Metal consumers all release before backing reuse.
- [ ] Exercise producer-fence success, reordered/duplicate/failed/never-signaled fences, queued reset and simultaneous scanout retirement. A used-ring completion is not proof of GPU completion.
- [ ] Verify coherent/noncoherent memory and flush/invalidate behavior for the actual MoltenVK memory types; do not infer it from `bytesNoCopy` or unified memory alone.
- [ ] Enforce per-VM quotas on contexts, resources, arena bytes, descriptors, queued work and outstanding exported frames. Emit structured reasons for exhaustion/timeouts.
- [ ] Feed identical GPU semantic vectors to MMIO and PCI as semantics are shared. Keep transport-specific IRQ/configuration code separate.

**Accept when:** repeated multi-VM map/render/reset/stop stress has no stale mapping, cross-VM exposure, duplicate completion or unbounded resource growth; renderer loss leaves guest disks intact.

### L3 — Make displayed-pixel evidence prove the pixels

**PLAN:** 3.5, 5.7. **Type:** new verifier/oracle code plus stronger probe/capture contracts.

**Extend:** `guest-probes/dory-vulkan-probe.c`, `dory-vulkan-compositor-probe.c`, `dory-gl-probe.c`, `dory-compute-probe.c`, `validate-result.py`, `verify-displayed-pixel.py`, `test-displayed-pixel.py`, `scripts/arm-ubuntu-scenario-driver.sh`, and app capture instrumentation. **Proposed new file:** `guest-probes/pixel-oracle.py` with independent expected-pattern generation and decoding.

- [ ] Define a deterministic held reference frame containing a machine/run challenge, frame counter, corner/orientation markers, color patches, alpha and a textured region. Use an encodable pixel marker, not OCR as the sole authority.
- [ ] Retain the probe binary/source/shader/input hashes, workload parameters and expected output definition. Bind them to the outer signed candidate and selected guest runtime.
- [ ] Decode the captured PNG; reject malformed/truncated files, blank content, the wrong guest viewport, old nonce/counter, mirrored/rotated/channel-swapped output and unexpected geometry.
- [ ] Record a guest viewport rectangle and scale/color metadata. Compare deterministic interior regions with explicitly bounded tolerances for host scaling/color conversion; do not demand a whole decorated-window byte-for-byte match.
- [ ] Correlate the decoded marker with the **same** guest resource/frame, producer completion, app Metal completion and capture receipt. Account for a newer frame overtaking a receipt; a held challenge frame or capture handshake must remove this race.
- [ ] Verify offscreen outputs independently where deterministic. `validate-result.py` currently checks a result hash's format and device identity; hash syntax is not an output oracle.
- [ ] Add negative fixtures whose PNG and all recorded hashes are internally consistent but whose actual pixels are wrong. Also test stale-frame substitution and a software/firmware frame with valid host Metal completion.
- [ ] Keep low-level verifier success distinct from the outer campaign's source/signature/guest/lifecycle qualification. Require all of them at final admission.

**Accept when:** replacing a correct image with a consistently rehashed blank/wrong/stale image fails. The actual visible challenge matches guest results and host presentation, for each admitted transport/API/ISA.

### L4 — Choose and prove the OpenGL/Vulkan desktop stack

**PLAN:** 3.7. **Type:** workload runner, compatibility data and targeted dependency fixes; comparison verifier already exists.

**Extend:** `guest-probes/verify-opengl-strategy.py`, its tests, in-guest build/probe scripts, `Config/DoryRendererProductionTuple.json`, renderer patches and capability/diagnostic models. Add a guest workload collection script that emits the existing comparison schema rather than hand-writing measurements.

- [ ] Inspect the actual distro packages for Venus ICD and Zink/VirGL driver availability on each ISA. Stock Mesa package names do not guarantee the needed drivers were built or installed.
- [ ] Record exact kernel/Mesa/compositor versions and negotiated Vulkan features/formats, with driver identity and software fallback detection.
- [ ] Compare Zink → Venus → MoltenVK and VirGL2 → ANGLE → Metal at identical resolution, host, guest CPU/RAM, desktop and worker tuple.
- [ ] Run the existing required workload set: glmark2, GNOME overview, KWin overview, GTK4, Qt6, Firefox WebGL Aquarium, Blender viewport, LibreOffice Impress and Zed. Record unsupported workloads as failures, not omissions.
- [ ] Measure p95/p99 frame intervals, first-shader stall, CPU and RSS, shader correctness and visible output. Select the default only from a passing comparison.
- [ ] Qualify Wayland/XWayland and Xorg only for the sessions actually offered. Test direct scanout/compositing transitions and DMA-BUF/sync-file interoperability.
- [ ] Keep the project's 6.13 stock-kernel fence policy distinct from upstream Venus's minimum feature requirements. Kernel version alone cannot prove Dory's synchronization contract; test vendor backports and live ordering.
- [ ] On missing capabilities, report a supported software mode or reject required acceleration. Preserve the user's kernel. Do not silently install a managed kernel/Mesa stack contrary to PLAN 3.3 D2.
- [ ] Rebase/repair pinned host renderer dependencies when a demonstrated protocol/feature mismatch requires it. Advertise only tested API/extension levels, not the maximum advertised by upstream MoltenVK.

Upstream [Venus requirements](https://docs.mesa3d.org/drivers/venus.html) identify blob, host-visible and context-init requirements and describe host-memory assumptions; they do not qualify Dory's Darwin adaptation. [Zink requirements](https://docs.mesa3d.org/drivers/zink.html) and [MoltenVK's portability behavior](https://github.com/KhronosGroup/MoltenVK/blob/main/README.md) must be checked against the pinned build and actual feature queries.

**Accept when:** selected desktop/API profiles pass real applications without an undisclosed software renderer; required feature checks and workload results mechanically control selection.

### L5 — Finish ordinary distro installation and desktop tools

**PLAN:** 2.16, 4.9. **Type:** product/campaign integration and native package production.

**Extend:** `DoryOperations/DoryInstallerISO.swift`, guest candidates/matrix, `DorydKit/DoryInstalledDesktopPayloadReceipt.swift`, `DoryGuestIntegrationPackage.swift`, Linux package sources and `dory-core/agent`.

- [ ] Select explicit Ubuntu and Fedora desktop media per ISA and verify current vendor availability/support and checksums when freezing. Old server fixtures and local Fedora 42 experiment names do not automatically define the next public desktop release.
- [ ] Retain blank-disk install → remove ISO → daemon restart → offline installed-disk boot → user login → package/kernel/bootloader update → reboot/recovery for each cell.
- [ ] Build signed `.deb` and `.rpm` packages natively for ARM64 and x86_64, then produce and verify each tools ISO. Source-package tests do not create installable packages.
- [ ] Verify user service installation across GNOME/KDE, Wayland/X11, logout/login, no graphical session, multiple users and permissions revocation.
- [ ] Complete transactional package upgrade/rollback/uninstall and capability negotiation with older supported agents. Keep VM stop and recovery usable without guest tools.
- [ ] Test clipboard text and PNG in both directions, focus policy, payload limits, echo suppression, permissions revocation and session changes.
- [ ] Test resize/udev/user-session notifications and high-DPI mode changes against actual compositors; packaging an `xrandr --auto` helper is not proof for every session.
- [ ] Exercise normal developer workloads, package management, Git/builds, browser, editor, network and sustained disk activity.

**Accept when:** users can install and maintain ordinary desktops without a hidden custom guest image or manual host repair, and tools install/update using the documented supported route.

### L6 — Complete app presentation across both Linux backends

**PLAN:** 3.8–3.9, 4.8. **Type:** complete existing relay integration and qualify it.

**Extend:** `Dory/Features/Machines/LinuxMachineDisplayView.swift`, `MachinesView.swift`, `DoryVMDisplayWireContracts`, `DorydKit/DoryVMDisplayBroker.swift`, `DoryVMDisplayRelayState.swift`, `dory-hv/DoryVMDisplayRunnerRelay.swift`, `DesktopMode.swift`, `DoryPCDesktopAdapters.swift` and `MachineManager.swift`.

- [ ] Keep the recent reconnect/lease-ack/orientation/CPU-coalescing fixes; cover opening the window before first frame, closing/reopening it, runner replacement and daemon reconnect.
- [ ] Complete PC production launch wiring to the app-owned relay. The manager configuration currently describes its broker endpoint as ARM RawHV-specific; verify the full PC launch path rather than assuming a reusable display class proves parity.
- [ ] Relay software and accelerated scanouts, cursor, absolute/relative input, resize and topology for PC with the same machine/operation/generation checks.
- [ ] Bound frame queue depth and retire replaced/occluded/minimized frames safely. Preserve the newest deferred CPU update without indefinite stale display.
- [ ] Test 1/2/multiple Linux scanouts, independent geometry/EDID, host monitor moves, Retina/fractional scaling, hotplug/unplug and focus/key release.
- [ ] Report requested profile, admitted profile, driver connected, fence-verified, first shader, first presentation and device loss separately. Reset live success state on generation changes.
- [ ] Measure input-to-visible, resize-to-stable, frame drops, CPU-copy bytes, GPU blits, memory and lease return-to-baseline.

**Accept when:** the same app controls and truthful diagnostics work for ARM and PC desktops, including reconnect and renderer loss under load.

## 5. Linux x86_64 execution and graphics checklist

### X1 — Finish the production execution and memory contract

**PLAN:** 2.4, 2.6–2.10. **Type:** substantial implementation and conformance work.

**Extend:** `DoryMachinePC/DoryPCDirectKernelMachine.swift`, `DoryPCRunSession.swift`, `DoryPCRunCommandBus.swift`, `DoryPCHostWorker.swift`, `DoryPCRunConcurrentExecutionGate.swift`, `DoryPCDeviceAccessCoordinator.swift`, `DoryPCTranslationInvalidationCoordinator.swift`, `DoryPCPhysicalMemory.swift`; `DoryDBTX86/DoryX86MemoryAccessCoordinator.swift`, `DoryX86Paging.swift`, `DoryX86JITTLB.swift`, interpreter/JIT emitters and `DoryJITRuntimeC`.

- [ ] Preserve the safe production configuration: do not re-enable failed raw target prediction/chaining combinations from older PLAN text. Requalification must cover each exact optimization combination.
- [ ] Extend the internal interpreter pair to the remaining memory-model cells: IRIW, remaining locked families, split/unaligned/cross-page RAM, ordinary readers/writers versus fallback atomics, and fault ordering.
- [ ] Prove native/native and mixed interpreter/native access obey the same x86 memory contract, including DMA and shared GPU mappings. One-vCPU guests still have device/renderer observers.
- [ ] Exercise remote TLB/code invalidation while an owner is running, halted, parked, entering/exiting native code, retiring a code cache, or racing teardown.
- [ ] Extend the current generic guest-memory DMA tests to real configured virtio queues/backends mutating code and page tables. Include reset, completion and interrupt delivery under concurrent DMA.
- [ ] Replace remaining ordinary execution rendezvous batching with independently running admitted owners, while retaining explicit pause/reset/snapshot/stop rendezvous.
- [ ] Complete INIT/SIPI/IPI/NMI, interrupt shadows, timer deadlines, APIC priority and wake delivery under genuine overlap. Preserve the lost-wake regression.
- [ ] Enforce bounded cancellation/join before memory/device destruction. Fix callback re-entry and lock ordering across extensions as well as built-in devices.
- [ ] Qualify 2/4-vCPU Linux SMP, futex contention, compile workloads and scaling before exposing production parallel vCPUs. Add further counts only with evidence.

**Accept when:** all admitted tier/count/device combinations pass independent semantics, TSan where applicable, guest litmus, real Linux SMP and reset/stop stress, with measured overlap and scaling. A test-only policy that excludes normal extension devices does not close production SMP.

### X2 — Close CPU profile, firmware and ordinary userspace gaps

**PLAN:** 2.3–2.4, 2.7, 2.9, 2.12. **Type:** targeted semantic fixes; profile promotion conditional on conformance.

**Extend:** `DoryDBTX86/DoryX86Decoder.swift`, interpreter/JIT scalar and SIMD lowering, `DoryX86CPUProfile.swift`, `DoryX86ProfileRegistry.swift`, `DoryX86ExtendedFloat.swift`, `DoryX86FloatingPointEnvironment.swift`; `DoryFirmware`, `Firmware/DoryPC`, `DoryPCACPI.swift`, `DoryPCAPIC.swift`, timer/RTC/PCI modules; decode/conformance/qualification targets.

- [ ] Freeze the minimum CPU profile needed by the selected distro and Mesa userspace. Keep CPUID, interpreter, JIT and saved state consistent.
- [ ] Fill demonstrated instruction/exception/fault gaps from installer, glibc, kernel and Mesa workloads using independent reference vectors. Preserve precise RIP, partial effects and retry behavior.
- [ ] Complete and test x87/MXCSR/rounding/NaN/denormal behavior, SSE baseline, and signal/context restoration for the advertised profile.
- [ ] Promote v2/v3 only when all their dependencies, AVX/XSTATE forms and persistence contracts pass. Do not make AVX-512 or a complete new optimizing tier a prerequisite for the first useful baseline desktop.
- [ ] Verify JIT entry/exit/chained-edge ABI with actual edge observations, protected-code mutation and pending-work latency. Keep unsafe predictors disabled.
- [ ] Rebuild EDK2 from pinned current source; test UEFI variables, GOP, PCI enumeration, ExitBootServices, virtual runtime services, KASLR, ACPI shutdown/reboot and bootloader updates.
- [ ] Run stock installer and installed-disk boots, not only PVH fixtures. Retain failed instruction traces and minimized regression inputs.

**Accept when:** selected ordinary distro kernels/userspace and desktop driver binaries run under the exact persisted CPU profile without undisclosed instruction or firmware workarounds.

### X3 — Make translated desktops practically usable

**PLAN:** 2.5, 2.11, 2.13, 5.2. **Type:** profiling-led optimization and benchmark automation.

- [ ] Reacquire current-head optimized PVH baselines using the existing qualification recipes and CI graph; record all source/binary/profile/predictor/host identities.
- [ ] Instrument ordinary EFI boot, installer progress, desktop login, agent RPC, package install, editor startup and graphics command submission separately.
- [ ] Attribute wall and CPU time to instruction execution, decoding/compilation, helper/exit dispatch, page walking/TLBs, invalidation, coordinator waits, device entry and renderer waits.
- [ ] Investigate the retained session-cutover slowdown and the register-loop baseline/Tier1 inversion before broadening optimization settings.
- [ ] Optimize the largest measured costs while preserving precise faults and bounded pending-work checks; add regression budgets around whole workloads.
- [ ] Set practical boot/login/input budgets from repeated measurements before qualification. Do not present fixture MIPS or a guest marker as desktop responsiveness.
- [ ] Add SSA/hot-region work only if it is needed after profiling and wins on actual workloads. Existing Tier2 infrastructure does not remove the need for side-exit maps, safe publication and code-cache bounds.

**Accept when:** installation and daily interaction meet explicitly agreed budgets on the admitted host class, with no correctness regression or weakened timeouts used to manufacture a pass.

### X4 — Implement the missing PC Venus host-visible path

**PLAN:** 2.6, 2.14, 3.2–3.6. **Type:** required new code. **Dependencies:** ARM displayed-pixel proof under the current plan; safe PC memory/PCI foundation. A single-vCPU PC can be used for initial functional bring-up before wider SMP admission.

**Modify existing:** `DoryMachinePC/DoryPCVirtioPCI.swift`, `DoryPCPCIExpress.swift`, `DoryPCV1ABI.swift`, `DoryPCPhysicalMemory.swift`, `DoryVirtio/DoryVirtioGPU.swift`, `DoryVirtioGPUAcceleration.swift`, `DoryHV/DoryPCVirGLRendererAuthority.swift`, renderer wire contracts and PC desktop adapters.

**Proposed new units:** `DoryPCHostVisibleGPUAperture.swift` in DoryMachinePC, a `DoryPCVenusRendererAuthority.swift` adapter beside the existing VirGL authority, and a small shared blob-resource/mapping owner in DoryVirtio or an existing shared GPU target. Names are proposals, not existing APIs.

- [ ] Define/version the PC shared-memory region ABI: PCI shared-memory capability, host-visible region ID, 64-bit BAR/range, size/alignment, probing, relocation and reset semantics.
- [ ] Make firmware resource allocation and Linux virtio-gpu discovery see the same region. Validate overlap with RAM, ROM, ECAM and other BARs before launch.
- [ ] Add create-blob/map/unmap/set-scanout-blob command validation and replies, resource ownership, offsets/lengths, permissions and format/stride checks in the semantic device.
- [ ] Map authorized worker arena backing into the PC physical-memory provider. Ordinary reads/writes, interpreter paths, native fast paths and DMA must resolve the same mapping and access policy.
- [ ] Invalidate all affected TLB/direct-pointer/code aliases on map/unmap/relocation/reset. Wait for every relevant owner acknowledgement before reusing or freeing memory.
- [ ] Carry machine, worker, device and resource generations across the mapping/scanout protocol. Reject stale/replayed exports and resource ID reuse from an older generation.
- [ ] Preserve host-granule overlap/refcount behavior established on ARM without exposing adjacent VM/host data.
- [ ] Connect Venus scanout to the existing PC presentation consumer and app relay; keep producer completion, host completion and lease retirement distinct.
- [ ] Advertise Venus/blob/host-visible features only after the complete composition is present and admitted. The generic feature enum's existence is not implementation of the device protocol.
- [ ] Test malformed commands, BAR reassignment, aperture boundary accesses, concurrent map/unmap, worker crash, reset during GPU/CPU access and stop while mappings are live.
- [ ] Run actual **x86_64** kernel/Mesa/Vulkan loader/probes, then desktop compositor/application workloads. FEX or an amd64 process inside the ARM container engine cannot fill this cell.

**Accept when:** an installed x86 guest discovers the PCI aperture, maps real blobs, executes deterministic Vulkan on the host GPU, presents the correct challenge frame and survives reset/worker loss without stale aliases.

## 6. macOS ARM64 checklist

### M1 — Correct Mac graphics admission and presentation assumptions

**PLAN:** 4.5, 4.8. **Type:** confirmed source correction plus policy/UI/test changes.

**Extend:** `DoryVZMacCore/DoryVZMacResourcePlan.swift`, `DoryVZMacConfigurationBuilder.swift`, `DoryVMMKit/DoryVZMacAdapter.swift`, `DoryVZMacDesktopApplication.swift`, capability planning and Mac display UI/tests.

- [ ] Restrict supported VZMac configurations to one display on the reviewed SDK/runtime contract; reject additional displays before creating disks or rewriting manifests.
- [ ] Repair the comment/assertion that separate `VZVirtualMachineView` instances automatically bind distinct Mac displays. Multiple views do not create unsupported guest displays.
- [ ] Update create, import, reconfigure and restore validation plus tests. For persisted invalid multimonitor definitions, explain the problem and provide an explicit one-display repair path; do not silently rewrite saved-state compatibility.
- [ ] Test live resize, display scale, fullscreen, occlusion, host monitor moves, keyboard layouts and focus-release on the supported single display.
- [ ] Document current process ownership: `dory-vmm/main.swift` enters `DoryVZMacDesktopApplication`, which owns an `NSApplication` and `NSWindow`. The Linux app relay does not embed that VZ view into Dory.app automatically.
- [ ] Qualify this supported helper-hosted Mac window as part of the Dory product journey. If main-app ownership is required later, first prototype a public-API architecture with explicit lifecycle ownership; do not invent an IOSurface export API for Apple's VZ Mac GPU.

**Accept when:** all visible Mac display choices are valid and the window reconnect/lifecycle experience works without promising unsupported multimonitor behavior. The SDK constraint belongs to [VZMac graphics displays](https://developer.apple.com/documentation/virtualization/vzmacgraphicsdeviceconfiguration/displays), not Dory's Linux GPU device.

### M2 — Finish current guest Metal proof

**PLAN:** 4.4, 5.7. **Type:** extend the existing probe/verifier and add product-bound capture/lifecycle collection.

**Extend:** `GuestTools/DoryGuestTools/DoryGuestMetalProbe.swift`, `DoryGuestMetalProbeTransport.swift`, `DoryVZMacMetalProbeCollector.swift`, `dory-vzmac-qualification`, `scripts/verify-macos-guest-metal-probe.py` and its tests.

- [ ] Generate a signed tools manifest for the exact candidate; run the retained probe inside the selected VM through the existing host-issued challenge.
- [ ] Independently compute the accepted checkerboard byte digests and approved shader identity in the host verifier. The guest already checks its render bytes; the verifier should also reject arbitrary well-formed render/shader hashes.
- [ ] Bind compute and live preview to the same challenge; include a visible nonce/frame marker so a previously displayed checkerboard cannot satisfy a new run.
- [ ] Retain raw guest JSON, transport receipt, guest OS/build, machine identifier, resources, bundle/signing identity, source/shader hashes and the selected product-window capture.
- [ ] Add a Mac product-window verifier with a pixel oracle and machine/operation/capture binding. A host Metal test is a control, not guest proof.
- [ ] Run the probe after cold boot, resize, minimize/restore, host sleep/wake and supported save/restore. Check device/command-buffer errors and timeouts.
- [ ] Measure sustained render pacing and input response; the current 1,024-value compute/64×64 render probe establishes deterministic correctness, not performance under real workload.
- [ ] Keep the sub-result non-release-eligible until the outer campaign validates all these boundaries. Do not merely change its Boolean.

**Accept when:** a current installed Mac guest produces correct challenged compute and visible graphics, and repeats them across supported lifecycle transitions with portable evidence.

### M3 — Qualify install, identity and saved-state recovery

**PLAN:** 4.1–4.2, 4.6. **Type:** integration/fault campaigns with fixes to existing journals as failures arise.

**Extend:** `DoryVZMacMachineBundle.swift`, `DoryVZMacInstallJournal.swift`, `DoryVZMacMachineLease.swift`, `DoryVZMacSavedState.swift`, `DoryVZMacManagedSavedStateOperation.swift`, `DoryVZMacRecovery.swift`, `DoryVZMacPortableBundle.swift`, daemon operation adapters and UI progress.

- [ ] Validate IPSW support/hardware-model/CPU/RAM requirements using the supported Apple configuration before durable allocation. Complete cancellable/resumable/integrity-checked download handling where the product route lacks it.
- [ ] Run daemon-authorized install → Setup Assistant → first login → shutdown → offline cold reopen without the original IPSW path.
- [ ] Retain stable machine/hardware/auxiliary identity across retries and helper/app/daemon restarts. Define clone identity separately from retry/reopen identity.
- [ ] Test interruption/full disk/helper crash at every install journal transition; reconnect to the existing operation rather than creating another bundle.
- [ ] Validate save-state compatibility against the exact devices, shares, disk/auxiliary lineage and host/guest tuple.
- [ ] Prove one-shot saved-state consumption is durable before resumed execution can advance disks. A consumed RAM image cannot replay against newer disk contents.
- [ ] Inject failures before/after reserve, pause, temporary save, digest, publish, consume, restore and resume. Recovery must be idempotent.
- [ ] After restore, verify open application state, known file contents, clocks, input, networking, shares and Metal; offer cold recovery for incompatible states without deleting the user's disk.
- [ ] Validate export/import/backup restore into a fresh owned location and supported second host where portability is claimed.

**Accept when:** installation and recovery succeed through ordinary Dory operations with no manual bundle surgery. [Apple's installation model](https://developer.apple.com/documentation/virtualization/installing-macos-on-a-virtual-machine) remains the platform authority.

### M4 — Complete Mac tools and device policy

**PLAN:** 4.3, 4.5, 4.9. **Type:** qualification of wired features; new general tools/optional-device integration where absent.

- [ ] **Shares:** retain the now-wired `--share`/adapter path; verify RO/RW behavior, canonical-root authority, bookmarks/access loss, root replacement, rename/delete, revocation and save/restore compatibility. Keep the tools distribution share separate from user shares.
- [ ] **Network:** prove shared NAT, disconnected and host-only isolation, stable MAC identity, DNS and loopback forwards. Keep bridged and LAN exposure unavailable unless a supported explicit implementation is added.
- [ ] **Audio:** qualify independently enabled input/output, permissions denial, route changes, device removal and sleep/wake through actual VZ streams.
- [ ] **Clipboard:** prove SPICE text/image bidirectional behavior and disabled mode. For selective direction/format policies, implement an independently controllable bridge and revocation behavior before removing the current rejection; a single SPICE enable Boolean cannot enforce those policies.
- [ ] **Tools:** extend the existing GuestTools app with a versioned machine-bound capability/health service for the integration features actually promised. The Metal challenge and camera transport do not by themselves provide general file transfer/time/open-URL/shutdown RPC.
- [ ] Separate user-session clipboard/open-URL work from privileged installation/system changes; add bounded framing, request IDs, timeouts, replay/generation checks, capability negotiation and reconnect.
- [ ] Finish signed/notarized package install/update/rollback/uninstall on ordinary guests. Verify diagnostics for missing, outdated or disconnected tools.
- [ ] **Camera, if included:** carry explicit host permission and device grant through the daemon/helper, install/authorize the guest camera extension, bind the session to VM identity, implement stop/revocation and retain real camera frames inside an app. Only then remove production camera rejection.
- [ ] **USB:** qualify existing disk-image-backed `DoryVZMacUSBMassStorage` independently from physical USB. Implement physical passthrough only against an available supported public API and the SDK/runtime capability inventory; do not relabel a virtual disk as a captured physical device.

**Accept when:** every exposed toggle changes the real configuration/guest behavior and each optional feature remains unavailable until its authority and guest path are complete.

## 7. Device coverage and remaining shared work

The user-visible device contract must be frozen per backend. A class, reserved IRQ or topology slot is not a discovered and working guest device.

| Device/function | ARM Linux implementation basis | x86 Linux implementation basis | macOS implementation basis | Remaining acceptance/code |
|---|---|---|---|---|
| Keyboard/pointer/tablet | virtio input + app relay | PS/2, virtio input, USB HID | VZ input/view | Layouts, modifiers, focus release, pointer capture, wheel/high-DPI coordinates; verify installers and desktops |
| Display/GPU | MMIO GPU + renderer + relay | PCI GPU, VirGL2; Venus missing | VZMac graphics | L1–L6, X4, M1–M2; no blanket OpenGL/Vulkan/Metal capability claim |
| Block storage | VirtioBlk/raw disk | DoryVirtioBlock/PCI | VZ block/image attachments | Flush durability, ENOSPC, sparse growth, readonly ISO, reset/stop with I/O, independent writable leases |
| Network | VirtioNet + host network stack | Virtio network/PCI | VZ NAT or gvproxy attachment | Mode isolation, IPv4/IPv6 policy, DNS/VPN changes, queues/offloads/MTU, stable identity and forwards |
| Shared directories | VirtioFS + isolated FS worker | PC VirtioFS adapter | VZ directory sharing | Metadata/cache/mmap/fsync semantics, host/guest edits, root grants/revocation, performance |
| Audio output/input | VirtioSound + desktop audio backend | DoryVirtioSound + Mac audio backend | VZ sound streams | Format negotiation, duplex, drift/underrun, mute, permissions, route changes, no audio after revocation |
| Physical USB | USB/IP over vsock with guest-agent attach path | Direct host lease into emulated xHCI | Separate SDK/public-API-dependent path | Test actual device classes; ARM needs guest modules/tools; PC needs controller/transfer stress; Mac virtual storage is distinct |
| Camera | Virtual UVC/host camera components | UVC/xHCI and host backend components | Guest CoreMediaIO bridge components; production grant rejected | Explicit permission, frames in real guest apps, unplug/revoke/restart, bounded buffers and supported formats |
| Vsock/tools | VirtioVsock + Rust agent | PC vsock adapter | VZ socket collector; more integration needed | Flow control, framing, disconnect, identity, generation, timeouts and privilege boundaries |
| Entropy | VirtioRng | DoryVirtioEntropy | VZ entropy | Real random source, bounds and reset; do not invent a new RNG |
| Memory pressure | ARM balloon machinery | Audit/complete actual PC advertised composition | Supported VZ policy only | Track CPU/DMA/GPU ownership; no reclaim of leased memory; expose only supported controls |
| Clock/power | ARM timer/GIC/PSCI | APIC/PIT/HPET/RTC/ACPI | VZ lifecycle | Sleep/wake, monotonicity, timer delivery, guest shutdown/reboot, drift and bounded stop |
| Removable media | ISO/block policy | ISO/block plus USB classes | VZ USB image attachment | Eject/reinsert, readonly policy, active I/O, persistence and clear physical/virtual distinction |

### D1 — Queue and DMA correctness

**PLAN:** 2.14. **Owners:** `DoryVirtio`, ARM `VirtioMMIO`, PC `DoryPCVirtioPCI`, device backends and guest-memory providers.

- [ ] Exercise feature negotiation and FEATURES_OK/DRIVER_OK/reset over both transports; queue length/alignment, indirect chains, cycles, direction, wraparound, event suppression and interrupt masking.
- [ ] Reject guest-controlled integer overflow, out-of-range DMA, stale/reused descriptors and unbounded outstanding requests before host access.
- [ ] Define exactly-once completion and generation cancellation for every asynchronous backend. Complete or cancel requests before unmapping guest memory.
- [ ] Test real disk/network/filesystem/audio/USB activity during reset, hot-unplug, renderer loss and VM stop; check no late DMA or callbacks survive teardown.
- [ ] Refactor duplicated semantics only after common vectors demonstrate parity. ARM MMIO and PC PCI still need distinct transport logic.

### D2 — Storage, snapshots, backup and migration

**PLAN:** 4.6, 4.10. **Owners:** daemon snapshot/restore/saved-state/backup stores, block backends, Mac bundle code, operation journals and storage provider.

- [ ] Validate exclusive writable disk leases, owned versus external media, durable flush semantics, bounded resize and full-disk/error propagation.
- [ ] Label cold disk snapshots, crash-consistent snapshots, guest-quiesced snapshots and full saved state accurately. APFS cloning is not proof of application consistency.
- [ ] Preserve the accelerated-Linux saved-state rejection until CPU/device/GPU state restoration is implemented; do not block cold snapshots or normal shutdown on that optional future feature.
- [ ] Verify interrupted clone/move/import/export/delete/backup operations recover to known states with fsync/atomic publication where required.
- [ ] Test restore boot and guest file/application checksums, not just archive readability. Retention must never remove the last good backup after a failed run.
- [ ] Preserve external share contents and original ISOs when deleting a VM; maintain independent firmware variables and network/Mac identities in clones.
- [ ] Run existing installation migration/update/reopen paths across all families; preserve container data and unsupported legacy disks without silent reinterpretation.
- [ ] If non-raw import is offered, implement an owned bounded converter with explicit supported format variants. Raw disk support and the no-QEMU invariant remain the baseline.

### D3 — Network and filesystem integration

**PLAN:** 4.7. **Owners:** gvproxy producer/runtime, route/port registries, `DoryVMMGVProxyNetwork`, `DoryFSWorker`, `VirtioFS`, PC FS adapter and VZ shares.

- [ ] Freeze semantics of NAT, disconnected, isolated/host-only and any later bridged modes per backend; test host/LAN/cross-VM reachability explicitly.
- [ ] Persist forwards with conflict detection, bind scope and transactional rollback; recover after daemon/helper restart and host route changes.
- [ ] Test offline boot, VPN/UTUN/DNS changes, sleep/wake, long-lived connections, MTU, IPv6 and flow backpressure.
- [ ] Verify path traversal/symlink/root-replacement protection and RO/RW grants in real guest workloads.
- [ ] Specify and test modes/ownership/case behavior, xattrs, rename/unlink, mmap, locks, watchers, cache invalidation and fsync.
- [ ] Benchmark small-file builds and metadata-heavy workloads as well as large sequential transfers; fix measured bottlenecks without weakening durability or grants.

### D4 — Input, audio and privacy behavior

**PLAN:** 2.15, 4.5. **Owners:** app display input, desktop audio backends, virtio input/sound, VZ policy and host permission brokers.

- [ ] Add real-guest cases for all pressed keys released on focus loss, non-US layouts, secure-attention shortcuts, pointer capture release and host display scale changes.
- [ ] Exercise simultaneous capture/playback, sample-rate/device changes, suspend/reopen, buffer limits and underrun recovery. Record silence/latency/drift rather than only stream creation.
- [ ] Permissions revocation must stop capture promptly, release host resources and update app/CLI capability state. A persisted preference is not a live permission grant.

### D5 — USB and camera device classes

**PLAN:** 2.15, 4.5. **Owners:** `DoryHV/Usb`, `DoryPCXHCI.swift`, `DoryPCUSBDevice.swift`, `DoryPCUSBUVCDevice.swift`, `DoryHostDeviceBroker`, `DoryPCUSBPassthrough.swift`, `DoryHostCamera`, VZ camera bridge and GuestTools extension.

- [ ] Publish an explicit supported-class table: HID, storage, serial and camera need different transfer behavior. Do not promise arbitrary USB from a single successful device.
- [ ] For ARM USB/IP, prove stock distro VHCI/module availability, agent attachment, reconnect and vsock isolation; installer USB forwarding before tools is a separate feature.
- [ ] For PC xHCI, verify command/event/transfer rings, short packets, stalls, cancellation, alternate settings, hot-unplug, reset and control/bulk/interrupt transfers against real devices.
- [ ] Add/qualify isochronous support only if the selected camera/audio devices require it; reject unsupported endpoint types explicitly.
- [ ] Require stable physical identity and an exclusive user-selected host lease; prevent capture of disallowed/internal devices and mounted host storage.
- [ ] Test device replacement on the same port, surprise removal, host sleep, denied/revoked permission and VM death; settle all requests and return the device to the host.
- [ ] Validate camera extension packaging/authorization and real frame delivery separately for Mac; the general production camera grant remains unfinished.

## 8. Common control plane and release checklist

### C1 — Reliable lifecycle, launch and UI truth

**PLAN:** 2.2, 4.8, 5.3. **Type:** focused corrections plus cross-backend integration.

- [ ] Reproduce the local MainActor launcher warning under the selected toolchain. Audit `DoryApplicationProcessLauncher.beginLaunch` and callers; use an explicit asynchronous MainActor entry when required. Do not synchronously wait on the actor needed to finish launch/handoff.
- [ ] Verify start planning cancellation and pre-spawn revalidation errors remain terminal/actionable through daemon, operation events and UI; preserve the latest fixes.
- [ ] Revalidate exact executable/signature/component/source identity immediately before execution; never reinterpret a failed required plan into another backend or graphics tier.
- [ ] Keep one machine definition, one resolved plan and one operation ID across app/CLI/API; retry and reconnect must not duplicate installs, disks, windows or workers.
- [ ] Model process running, tools connected, logged-in desktop, driver initialized and verified presentation independently, bound to lifecycle generation.
- [ ] For ARM CPU lifecycle, finish real guest PSCI/system-register/GIC/timer/idle tests and cancellation during CPU_ON/WFI/device I/O. Release VM handles/mappings only after every vCPU and device callback has joined.
- [ ] Test app closed, daemon restart, user session changes, host sleep/wake and interrupted operations with active graphics, networking and disk work.

### R1 — Align support policy, catalog and documentation

**PLAN:** 1.8, 5.1. **Type:** code/configuration/documentation after implementation evidence exists.

- [ ] Reconcile the current server-only policy with the intended desktop matrix. Add explicit ARM/x86 distro desktop and Mac OS/host/resource/device cells to the catalog and matrix; keep unavailable cells unavailable until their gates pass.
- [ ] Derive app picker/settings and CLI errors from the same capability data, including one-display Mac limits, stock graphics prerequisites and backend-specific devices.
- [ ] Keep provisional stock graphics, runtime-verified graphics and release-qualified cell state separate; do not use a kernel version string as qualification.
- [ ] Update stale PLAN baseline claims about x86 prediction/SMP, Mac shares/network/probe and Linux app windows. Mark old GPU reports as historical context rather than reassigning completed implementation work.
- [ ] Resolve PLAN 3.7's old “build pinned guest Mesa packages” instruction against the later stock-only decision: freeze and record distro-provided packages; build host dependencies and probes, not an unannounced replacement guest stack.
- [ ] Replace stale host/toolchain/media examples only with verified selected tuples. The local 26B5086k observation is not interchangeable with the matrix's frozen host builds.

### R2 — Assemble and qualify the actual shipped candidate

**PLAN:** 1.6–1.7, 5.6–5.7. **Type:** pipeline completion and physical campaigns.

- [ ] Rebuild pinned firmware, renderer libraries/worker, Swift/Rust binaries and guest tools from clean source, including reproducibility/provenance checks and licenses/SBOM.
- [ ] Sign every nested executable/XPC/helper/extension with the required entitlements; notarize/staple the final distribution where required and verify downloaded candidate bytes.
- [ ] Run after-assembly source/runtime/component identity checks, signed launch/handoff and negative admission tests. Bind approvals and evidence to the exact candidate inventory.
- [ ] Acquire legitimate campaign authority, signing/notarization access, host classes, IPSW/ISO inputs and isolated test disks as needed. These are operational inputs, not missing emulator code; earlier reports of missing inputs must be rechecked because later signed candidate runs exist.
- [ ] Run two independent clean qualifying campaigns per required tuple as specified by the existing plan. Retain raw guest results, screenshots, traces, command lines, versions, timings, failures/skips and restore verification.
- [ ] Add final Linux/Mac semantic image verification and the chosen OpenGL comparison as required outer gates, not just unit tests of the verifier.
- [ ] Reject missing/failed/skipped required evidence; verify release publication and update/rollback against the same qualified bytes.
- [ ] Preserve the no-QEMU production/dependency check and container/runtime obligations. This desktop work must not regress existing Docker, FEX/GPU, networking or data-drive behavior.

### R3 — Freeze and pass usable desktop budgets

**PLAN:** 5.2–5.4. **Type:** measurement and failure/recovery automation.

- [ ] Freeze workload-specific budgets after baseline measurement: install/boot/login, input-to-visible, frame pacing, shader stalls, clipboard/resize latency, disk/network/share throughput and idle/active memory/CPU.
- [ ] Record p50/p95/p99 and warm/cold definitions, not only average FPS. Keep native ARM, translated x86 and Mac results separate.
- [ ] Run sustained mixed I/O/graphics, concurrent VMs and memory/GPU pressure; inspect FD/thread/mapping/lease leaks and fairness.
- [ ] Kill renderer, filesystem worker, VM runner and daemon at defined points; test GPU loss during work, full disk, unplugged external drive, revoked permissions and host sleep/wake.
- [ ] Verify bounded recovery without silently rebooting a VM with unsaved work or replacing a missing durable disk with an empty one.
- [ ] Retain container regression coverage and update/migration/rollback drills alongside the new desktop matrix.

## 9. Code inventory and interface-level specifications

This is the implementation inventory for the requested target. “New” means a proposed unit; “extend” means the path already exists. Actual patches should be written against a reproduced failure or the specified missing contract. These sketches define interfaces/invariants, not compiled drop-in implementations.

| Work | Existing code to extend | New code or artifact to write | Verification home |
|---|---|---|---|
| L1/C1 | ARM GPU/DesktopMode/readiness; daemon start/launcher | Regression cases for reset/readiness/handoff; actor-hop correction if reproduced | DoryHVTests, DorydKitTests, ARM live campaign |
| L2 | Arena/worker/wire contracts | Shared blob owner/transport-neutral interfaces where needed; retirement/quota cases | DoryHVTests, renderer service/transport tests |
| L3 | Guest probes, capture and evidence verifier | Pixel oracle; versioned visual challenge and crop/scale receipt; false-image fixtures | `guest-probes/test-displayed-pixel.py` and physical evidence |
| L4 | OpenGL verifier, renderer tuple/patches | In-guest workload collection/measurement runner; selected compatibility results | `guest-probes/test-opengl-strategy.py`, workload matrix |
| L5 | Media inspector, installer operations, Linux packages/agent | Native package artifacts, upgrade/reconnect integration cases | GuestTools/Linux tests, real distro installation |
| L6 | Display broker/relay, PC adapters, app window | PC launch/relay wiring and any missing cursor/topology bridge | DoryVMDisplay tests, LinuxMachineDisplayWindowTests |
| X1 | DBT memory/JIT/PC run session | Remaining native/mixed memory contract, safe independent execution and device quiescence | DoryDBTX86Tests, DoryMachinePCTests, TSan and guest litmus |
| X2 | CPU profiles/decoder/FP/firmware | Demonstrated missing semantic lowerings/reference vectors/profile migration | Decode audit, DBT, firmware and installed guest cases |
| X3 | Existing benchmarks and qualification runner | Cost attribution and ordinary-desktop performance workloads | Optimized qualification/retained baseline comparison |
| X4 | PCI/GPU/physical memory/renderer | PC GPU aperture, Venus authority, blob semantics and alias retirement | PC PCI/GPU/memory tests plus x86 guest Vulkan |
| M1 | Mac resources/config/view/capabilities | One-display validation/migration and accurate UI/test expectations | DoryVZMacCoreTests, DoryVZMacAdapterTests |
| M2 | Metal probe/collector/verifier | Render/shader oracle, visible challenge and Mac product-window correlation | Metal verifier/collector tests, live Mac qualification |
| M3 | Mac bundles/journals/saved-state/recovery | Missing failure-edge handling uncovered by real crash drills | VZMac recovery/saved-state/portable-bundle tests |
| M4 | GuestTools, shares/network/device arguments | General guest integration service; optional camera grant or selective clipboard bridge | Guest-tools packaging, policy/security and real guest tests |
| D1–D5 | Existing device/storage/network/share/input/USB code | Missing class/transfer/reset/revocation/durability behavior shown by matrix | Backend unit suites plus real devices and fault campaigns |
| R1–R3 | Policy/catalog/evidence/release workflows | Desktop cells, final semantic gates, physical workload/fault orchestration | Matrix validators, release/CI and candidate campaign pair |

### A. PC GPU aperture contract to implement

Prefer existing identifiers/lease types when integrating this proposed interface:

```swift
// Proposed contract, not an existing API or a complete implementation.
struct PCGPUMapIdentity: Hashable, Sendable {
    let machine: UUID
    let workerGeneration: UInt64
    let deviceGeneration: UInt64
    let resourceID: UInt32
    let resourceGeneration: UInt64
}

protocol PCGPUApertureAuthority: Sendable {
    // backing is an authenticated worker lease, never a guest-supplied host pointer.
    // Validate requested and rounded ranges against the negotiated aperture first.
    func map(_ identity: PCGPUMapIdentity,
             backing: AuthorizedBlobBacking,
             guestOffset: UInt64, length: UInt64,
             writable: Bool) async throws -> GPUMapLease

    // Stop new accesses, revoke CPU/DMA aliases, await acknowledgements and
    // outstanding host GPU consumers, then release the final granule references.
    func retire(_ lease: GPUMapLease) async throws

    // Must not return success while an old-generation alias remains usable.
    func reset(deviceGeneration: UInt64) async throws
}
```

`AuthorizedBlobBacking` and `GPUMapLease` above are placeholders for a checked adapter around existing renderer lease contracts, not extra parallel wire formats. The implementation needs overflow-safe range calculation, a mapping/resource table, per-granule refcounts, access resolution in every memory path, owner invalidation acknowledgements, quota accounting and a bounded retirement state machine.

Required retirement sequence:

```text
active mapping
  → reject new submissions/access grants
  → publish CPU/TLB/DMA alias invalidation
  → await all affected owners or fail the lifecycle operation safely
  → drain/cancel renderer and presentation consumers
  → remove guest mapping and release final host granule references
  → permit resource/backing reuse under a new generation
```

Do not hold the global device-entry lock while waiting for an owner or completion that needs that lock to make progress.

### B. Visual evidence contract to implement

Extend the existing evidence schemas rather than substituting this illustrative shape for them:

```text
candidate/source/component identity
machine + operation + runtime/worker/device/resource generations
guest ISA + OS/kernel/Mesa + API/feature/driver identity
probe source/binary/shader/input digests + expected workload parameters
challenge nonce + visible frame marker + expected pixel regions
guest compute/readback result + producer completion
app frame/Metal completion + capture timing + viewport/scale/color metadata
captured PNG digest + independent decoded-pixel comparison result
outer install/lifecycle/device/performance results
```

Verifier implementation order:

```python
# Specification pseudocode. Each step must reject malformed input explicitly.
verify_candidate_and_component_binding(bundle)
verify_selected_guest_and_probe_identity(bundle)
verify_guest_compute_oracle(bundle)
frame = decode_png_with_size_limits(bundle.capture)
viewport = validate_and_crop_guest_viewport(frame, bundle.capture_metadata)
marker = decode_visual_challenge(viewport)
require_same_challenge_and_frame(marker, bundle.guest, bundle.presentation)
compare_expected_regions(viewport, expected_pixels(bundle.workload), tolerances)
verify_producer_to_presentation_generation_and_completion_chain(bundle)
require_outer_lifecycle_and_device_results(bundle)
```

The decoded pixel comparison must run after hashes are checked. Hashes authenticate retained bytes relative to a manifest; they do not say whether those bytes show the correct image. CPU-copy transport is valid for software/installer operation and can also carry rendered pixels; hardware proof must come from the guest workload and renderer chain, not the transport label alone.

### C. Mac one-display repair to implement

- Use a single capability authority for Mac display count in resource validation, UI, configuration and import/restore checks; the reviewed contract is one.
- Reject a request with two displays before bundle creation and include the supported maximum in the error.
- Revalidate persisted resources on reopen; preserve an incompatible saved state and offer an explicit cold-boot reconfiguration path.
- Remove unsupported secondary Mac window construction or keep it unreachable behind a future separately verified capability.
- Add a real `VZVirtualMachineConfiguration.validate()` integration case alongside pure resource-plan tests. The current test using `maximumDisplayCount + 1` alone cannot catch an incorrect maximum of eight.

### D. General guest integration service to implement where absent

Reuse `DoryGuestIntegrationPackage/Health` and existing transport contracts. Add only the missing Mac service/adapters and required Linux handlers:

```text
hello(protocol version, tools build, guest identity, available capabilities)
open session(machine/runtime generation, granted capability set)
request(id, capability, bounded payload, deadline)
response(id, result/error, current generation)
revoke/close(cancel requests, release session resources, clear clipboard state)
```

Capabilities must be explicit: text/image clipboard directions, file push/pull, display notification, time sync, graceful shutdown, open URL/path and diagnostic/probe collection. Avoid generic unrestricted remote shell as a shortcut for all user integration. Missing tools should degrade optional integration, not remove host-authorized force-stop/recovery.

## 10. Recommended implementation sequence and completion gates

The order follows current dependencies, not nominal file count. No reliable percentage-complete or calendar estimate follows from the number of existing types/tests.

1. **Current ARM slice:** rebuild current code; diagnose boot/reset readiness and the launcher warning; finish L1 and semantic evidence L3. Gate: one stock installed ARM desktop with challenged GPU output in the app.
2. **Desktop baseline:** L2, L4–L6 and essential D1–D4. Gate: selected ARM desktops install, update and stay usable with real tools/input/audio/network/shares, including renderer-loss recovery.
3. **Mac completion:** M1–M4 can proceed independently of x86 CPU optimization. Gate: ordinary install, supported one-display Metal, shares/network/audio/clipboard and lifecycle recovery through Dory.
4. **x86 execution:** X1–X3 can progress while ARM/Mac integration runs. Gate: correct ordinary x86 installed desktop with practical timings and truthful vCPU support.
5. **x86 GPU:** after ARM displayed-pixel proof, X4 plus L6 parity and x86 versions of L3–L5. Gate: real x86 Mesa executes and presents hardware Vulkan/OpenGL through Dory, with safe alias retirement.
6. **Optional device expansion:** D5 and camera/selective clipboard/physical USB per backend. Gate each advertised device class separately; keep unfinished classes visibly unavailable.
7. **Release:** R1–R3, clean after-assembly campaigns, recovery and update/rollback. Gate: exact qualified public cells and artifact bytes, not a broad “GPU supported” switch.

### Final delivery checklist

- [ ] ARM Linux: fresh ordinary desktop install, ISO detached, offline cold boot, package/kernel update, tools and everyday workload pass.
- [ ] x86 Linux: the same journey runs an x86 kernel under DoryDBT, with an admitted CPU/vCPU configuration and usable measured performance.
- [ ] Both Linux ISAs: current hardware compute, semantic visible-frame proof, selected desktop GL/Vulkan stack, resize/input and renderer-loss behavior pass.
- [ ] macOS ARM64: supported IPSW install/Setup Assistant/cold reopen, one-display Metal, device policy and saved-state/cold recovery pass.
- [ ] All three: disk, network, shares, keyboard/pointer and advertised audio/clipboard/tools work under normal operation and failure.
- [ ] Every advertised USB/camera/advanced feature has separate real-device evidence; unavailable features are accurately hidden/explained.
- [ ] App/CLI/API report the same effective configuration, lifecycle and observed graphics state.
- [ ] Snapshots/backups/restore/update preserve data and reject incompatible state safely.
- [ ] Performance and reliability budgets pass on each frozen host/guest cell.
- [ ] Signed/notarized delivered bytes, provenance, matrix and two required campaigns agree; release remains closed until then.

## 11. Validation performed for this report

This review read current source, recent Git history, PLAN and prior reviews, the qualification matrix, selected tracked evidence, the local seq80 presentation/daemon logs and the installed **macOS SDK 27.0** graphics headers. Primary Apple/Mesa/MoltenVK references were checked for platform/dependency constraints. Historical or ignored evidence was not treated as a new current-head guest run.

The following existing focused checks were run successfully during this review:

| Command | Result |
|---|---|
| `python3 -B guest-probes/test-displayed-pixel.py` | Passed verifier tests |
| `python3 -B guest-probes/test-opengl-strategy.py` | 9 tests passed |
| `python3 -B scripts/test-verify-macos-guest-metal-probe.py` | 8 tests passed |
| `python3 -B GuestTools/Linux/test-package-source.py` | 6 tests passed |
| `python3 -B GuestTools/Linux/test-iso-source.py` | 2 tests passed |

These tests establish the current validators/package-source behavior, including its limits. They do not resolve the missing independent pixel oracle, produce guest packages, boot a VM, prove hardware acceleration or qualify a release. No full app/package rebuild, guest install, physical USB/audio/camera run, notarization or new live graphics campaign was performed for this documentation task. No runtime implementation was changed.
