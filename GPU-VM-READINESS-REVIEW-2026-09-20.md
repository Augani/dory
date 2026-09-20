# Dory VM + GPU readiness review — 2026-09-20

Branch `codex/virtual-workspace-foundation` at `f8cad1ea5`. Host: Apple M2 Pro, macOS 27.2, Xcode 27 / Swift 6.4.
`swift build` of `Packages/ContainerizationEngine` (which pulls in all of `dory-core-swift`) completes clean (51 s, debug, warnings only).

This review answers one question: **can Dory fully run GPU-accelerated Linux ARM64, Linux x86_64 and macOS ARM64 VMs today?** It does not repeat the machine-level findings of `READINESS-REVIEW-2026-09-15.md` (ARM lifecycle, macOS display/network/shares) or `X86_64-LINUX-READINESS-REVIEW-2026-09-19.md` (x86 SMP/memory model); those remain valid and are referenced where they intersect GPU.

## 0. Bottom line

| Guest | Runs an ordinary distro? | GPU acceleration today? | Verdict |
|---|---|---|---|
| Linux ARM64 (DoryHV / `dory-hv`) | Yes, Ubuntu Server 24.04.4 is the one admitted public cell; UEFI + GRUB console works since `8c8966d7e`. | **No.** The device, worker, Metal presenter all exist and build, but the daemon admission gate for `hardwareAccelerated3D` requires a *Dory-managed signed guest kernel + Mesa*, and the tree that produced those (`guest/`) was deleted in `583840fc1e` on 09-15. Nothing can currently satisfy the gate. | Not ready for GPU. Closest of the three. |
| Linux x86_64 (DoryDBTX86 + DoryMachinePC) | Internal only. Single-vCPU PVH boot to userspace takes 740–760 s; UEFI install lifecycle has no evidence. | **No.** `DoryPCVirtioGPUPCIDevice` exists and can attach a VirGL authority, but the PC virtio-gpu has no blob/host-visible aperture (no `RESOURCE_CREATE_BLOB`, `MAP_BLOB`, `SET_SCANOUT_BLOB`, no `VIRTIO_PCI_CAP_SHARED_MEMORY_CFG`), so Venus is impossible there and VirGL has the same managed-kernel gate as ARM. | Not ready, and not close. CPU is the blocker before GPU matters. |
| macOS ARM64 (DoryVZMacCore / VZ) | Restore/install path exists; policy marks it "deferred from this release". | **Yes, by Apple.** `VZMacGraphicsDeviceConfiguration` gives Paravirtual GPU / in-guest Metal for free; evidence `p07-macos-2026-09-05/macos-metal-observation.json` shows it, but is screenshot-transcribed. | Ready for GPU in principle; blocked only by product gaps (display config, shares, network, notarization) and by a policy flag. |

So: **no, Dory is not ready to fully run any of the three with GPU acceleration.** macOS is one policy flip and a few product items away. Linux ARM64 is one architectural decision (below) plus a qualification campaign away. Linux x86_64 is a long way off and GPU is not the constraint there.

## 1. What has been done well (keep it)

- **No QEMU is genuinely true for the runtime.** `docs/virtualization/no-qemu-source-debt.json`, the shim in `DoryVirglRendererShim`, and the build scripts show the renderer is virglrenderer + ANGLE-Metal + MoltenVK + libepoxy (UTM's maintained forks, pinned by tree hash in `Config/DoryRendererProductionTuple.json`) linked statically into an isolated XPC worker. These are libraries you are allowed to depend on by `PLAN.md` §1.4. Only the deleted `guest/qemu-builder` used QEMU, and only as an image-build tool — removing that was consistent with your rule.
- **The host GPU architecture is the right shape.** Isolated renderer worker process → SHM-backed blobs mapped into the guest with `hv_vm_map` → `MTLSharedTextureHandle` export for scanout → `DesktopMetalView` samples worker pixels directly (no `Data`/IOSurface copy on the worker path). Generation-bound leases, fail-closed on missing authority, correlated tracing. This is more principled than UTM's design.
- **The fence contract is correct.** `DoryRendererProducerFenceContract.managedLinux612106PrepareFBV1` encodes exactly the right insight: `RESOURCE_FLUSH` is only a producer-complete boundary if the guest kernel uses `drm_gem_plane_helper_prepare_fb()` (upstream `30f86b8f86ad`, merged in Linux 6.13). You identified this, backported it, and gate on it. Most hypervisors ignore this and get torn frames.
- **Container Venus compute is real** (`p06-container-2026-09-05/container-standard-gpu-shader.json`) — the MoltenVK/Venus/worker pipeline executes shaders on the physical GPU. That proves the host half of the pipeline.
- **The evidence discipline is unusually honest.** `PLAN.md` §1.1 already refuses to claim GPU desktops from container compute. Do not lose this.

## 2. What went wrong

### 2.1 You deleted the only producer of GPU-capable guests and left the gate that requires them — **P0**

`583840fc1e chore(guest): remove virtual workspace guest tree` removed 142 files (16,758 lines), including:

- `guest/kernel/` — 6.12.106 build with `dory-gpu.fragment`, `dory-accelerated-desktop.fragment`, `dory-pc-virgl2.fragment`, and patches `0006-virtio-gpu-align-host-visible-vram`, `0007-virtio-gpu-wait-for-scanout-producers`, `0008-virtio-gpu-fail-closed-on-producer-fence-error`.
- `guest/mesa/` — the Venus and PC-VirGL2 Mesa builds pinned to `osy/mesa@79bc850d` (the exact Mesa peer of the renderer tuple), plus `dory-vulkan-probe.c` and `dory-vulkan-compositor-probe.c` that `PLAN.md` §3.5 says to *retain and extend*.
- `guest/desktop/` — the rootfs producer that installed the graphics pack.

Meanwhile `MachineManager.swift:13812-13830` (PC) and its ARM counterpart still require `rendererGuestKernelSHA256`, `rendererGuestMesaSHA256`, and `rendererProducerFenceContract` in *signed catalog evidence bound to the boot artifact* before `hardwareAccelerated3D` will launch. With `guest/` gone there is no path from source to a launchable GPU guest. `READINESS-TASKS-2026-09-15.md` says "do not restore it for this candidate" — that is fine for the Ubuntu-Server-headless cell, but it means the GPU programme is currently unbuildable, and `PLAN.md` Part 3 still points at deleted files.

**Decision needed:** either (a) restore `guest/kernel` + `guest/mesa` (not `guest/qemu-builder`, not `guest/initfs`) as the managed profile, or (b) redesign admission so stock distributions can qualify at runtime (§4 below recommends (b) with (a) as an optional "Dory graphics pack").

### 2.2 The GPU gate is bound to build identity, not observed behaviour — **P0 (design)**

Requiring the guest kernel SHA-256 to be signed into the catalog means **only Dory-built images can ever be accelerated**. Parallels, UTM, and Fusion all accelerate stock Ubuntu/Fedora. Your fence contract requirement is legitimate, but it can be verified at runtime instead:

- Kernel ≥ 6.13 contains `30f86b8f86ad` upstream. Ubuntu 24.04.3+ HWE (6.14), Ubuntu 25.04+, Fedora 42+, Debian 13 all ship it. Detect via the guest agent (`uname -r` + `/sys/module/virtio_gpu`) or simply via host-side observation: a kernel using `prepare_fb` submits `RESOURCE_FLUSH` *after* the Venus fence signals, which the worker can verify on the first N frames (fence-before-flush ordering check) and fail closed if violated.
- Mesa: Venus needs `VK_EXT_external_memory_dma_buf`/blob support in guest Mesa ≥ 24.x; probe `vulkaninfo` via the agent, or check the Venus capset handshake — you already parse capsets.

`PLAN.md` §3.4.6 already says "a stock profile needs its own demonstrated compatibility" and §3.7.7 says "support explicit unaccelerated installation where the stock installer lacks the required driver/fence contract". The code has not caught up: there is no stock profile at all.

### 2.3 Patch 0006 is a guest fix for a host problem — **P1 (design)**

`0006-virtio-gpu-align-host-visible-vram.patch` pads blob aperture nodes to 16 KiB inside the guest DRM driver because `hv_vm_map` needs host-page alignment. That makes a stock kernel unable to use host-visible blobs on Apple Silicon at all (4 KiB-aligned `MAP_BLOB` offsets will fail the `hv_vm_map` in `VirtioGPU.swift:1656`). This must be solved on the host:

- Reserve the host-visible window as one 16 KiB-granular region and give the worker a slab allocator that hands out 16 KiB-aligned SHM sub-ranges for every blob (round `size` up, keep the guest-visible `size` unchanged).
- On `MAP_BLOB` at a guest offset that is not 16 KiB-aligned, map the containing 16 KiB host page(s) and accept that up to 12 KiB of a *neighbouring blob from the same worker/VM* becomes guest-visible. This is acceptable only if all blobs in the window belong to that VM's single worker generation (they do), and if you never place non-GPU data in the window. Document it as the aperture contract in `PLAN.md` §3.3.5, which already asks for exactly this.
- Alternatively, use 16 KiB guest pages on ARM (`CONFIG_ARM64_16K_PAGES`) — but that is again a managed-kernel requirement and breaks FEX/x86 containers (the `dory-gpu.fragment` comment records this conflict), so it cannot be the stock answer.

### 2.4 PC virtio-gpu is a 2D + VirGL device, not a blob device — **P1 for x86 GPU**

`dory-core-swift/Sources/DoryVirtio/DoryVirtioGPU.swift:217-240` implements commands `0x0100–0x010B`, `0x0200–0x0207`, `0x0300–0x0301`. Missing: `RESOURCE_CREATE_BLOB (0x010C)`, `SET_SCANOUT_BLOB (0x010D)`, `RESOURCE_MAP_BLOB (0x010E)`, `RESOURCE_UNMAP_BLOB (0x010F)`, `GET_EDID (0x010A)`, `CTX_CREATE` capset_id/context_init handling for Venus, and the PCI shared-memory capability + BAR for the host-visible region. `DoryPCVirtioPCI.swift` has no `VIRTIO_PCI_CAP_SHARED_MEMORY_CFG`. `PLAN.md` §3.6 describes this work correctly; none of it has started, and the ARM `VirtioGPU.swift` (9,464 lines) already has a working blob implementation that has not been shared with the PC device (`PLAN.md` §3.2 "shared semantic GPU core" is also not started).

### 2.5 No displayed-pixel evidence exists for any Linux VM — **P1 (evidence)**

Every hardware-GPU receipt in `docs/virtualization/evidence/` is container compute (`p06-container-*`) or macOS (`p07-macos-*`). There is no receipt of a Linux VM desktop, `glmark2`, or even a triangle presented through `DesktopMetalView`. `PLAN.md` §3.5 lists what such a receipt must contain. The two Vulkan probe sources that would produce it were deleted with `guest/mesa`.

### 2.6 GPU work has been starved since 2026-09-08 — **process**

`git log` on `VirtioGPU.swift`, `DoryRendererWorker*`, `dory-hv/Desktop*` shows the last substantive change on 09-08 (`a93458b49`, `33cd3e2e4`). Everything since is x86 SMP/memory-model qualification (~15 commits). That work is good, but it is P2-08/P2-10 in your own plan, while P3-01 ("trace one complete production graphics path") has never been executed. You are polishing the hardest, least-differentiating tier while the two tiers you could ship (ARM Linux, macOS) have no GPU path a user can reach.

### 2.7 Linux VM display is a separate `dory-hv` process window — **P2 (product)**

`dory-hv/DesktopMode.swift` runs its own `NSApplication` and `NSWindow`. The Dory app never hosts the framebuffer; the VM appears as a second app. This makes in-app window management, multi-display, fullscreen/Spaces, drag-drop and consistent chrome impossible, and it is different from macOS guests where `VZVirtualMachineView` is embeddable. For the isolated-worker security model this is defensible, but the frame should reach the app via an IOSurface/`MTLSharedTexture` handle over XPC so the app owns the window and `dory-hv` owns the VM.

### 2.8 Smaller items

- `DoryVirglRendererSession.c:1583` binds virglrenderer only when `DORY_VIRGL_RENDERER_STATIC_LINKED` is defined; a plain `swift build` produces a `dory-renderer-worker` that returns `-ENOSYS` on first use. Fine for production (assembled via `scripts/assemble-renderer-production-worker.sh`) but there is no developer-mode dlopen fallback, so nobody can iterate on GPU without the 3-job, full-Xcode, hour-long static build. Add a `DORY_RENDERER_DEVELOPMENT_DYLIB` dlopen path guarded off in release.
- Renderer tuple pins `osy/mesa` 26.0.0-devel as the *guest* Mesa peer. A stock distro will ship 24.x/25.x Venus. Verify the Venus wire protocol (`VN_MAX_VERSION`) the worker's virglrenderer accepts against stock Mesa; if the UTM virglrenderer fork requires the osy/mesa peer, that is a hard blocker for stock guests and must be measured before §4 step 3.
- The macOS Metal evidence is transcribed from screenshots (`PLAN.md` §1.1 says so). Rerun with a guest-side JSON probe pulled over vsock before calling it qualified.
- `MachineManager.swift` at 25k+ lines now also contains the GPU admission policy (lines ~13800–14080 for PC; ARM elsewhere). The stock-profile work in §4 will touch it heavily; extract `DoryGraphicsAdmission` first or the change will be unreviewable.

## 2b. Desktop-experience scorecard (Linux ARM64, the target user)

"A user installs Ubuntu/Fedora desktop on an Apple Silicon Mac and it feels native." Component by component, against what a Parallels/UTM user gets today:

| Desktop requirement | State in code | Gap |
|---|---|---|
| Installer with graphical console | UEFI framebuffer + keyboard since `8c8966d7e` | Qualification pending (`READINESS-TASKS` §2) |
| Hardware GPU for the compositor (GNOME/KDE) | Host stack complete; **no admissible guest** (§2.1–2.3) | The whole of §4 |
| Host-side scanout without copies | `DesktopMetalView` samples worker SHM directly; CPU path is damage-proportional | Done for worker path |
| Dynamic resolution on window resize | `updateScanoutSize` + `VIRTIO_GPU_EVENT_DISPLAY` exists | **No `GET_EDID` (0x010A)**; GNOME/Mutter use EDID for mode lists and DPI, so resize works but scaling/mode selection is degraded |
| HiDPI / Retina | `guestBackingScaleFactor` plumbed into the view | Guest receives no DPI hint without EDID; users will get 1× on a 2× panel or blurry upscale |
| Multi-display | Scanout array supports N; `DesktopMode` builds N windows | Untested; no hot-plug of a second display |
| Cursor | `UPDATE_CURSOR`/`MOVE_CURSOR` handled, hardware-cursor mailbox in presenter | OK |
| Pointer/keyboard | virtio-input, separate keyboard + absolute tablet endpoints (correct) | No relative-mouse (`EV_REL`) capture mode → FPS games / Blender orbit / CAD unusable |
| Audio | virtio-snd playback + capture on AVAudioEngine | OK in code; no desktop-latency measurement |
| Clipboard | Policy plumbing in `DesktopMode` and daemon; **the Rust agent has no clipboard handler** | Guest half missing; no Wayland (`wl-clipboard`/portal) integration |
| Shared folders | virtio-fs device + FS worker | OK |
| Guest tools package for stock distros (agent, resize, clipboard, time) | Agent exists in `dory-core/agent`, shipped only inside the managed rootfs | No `.deb`/`.rpm`; stock users get nothing |
| Drag-and-drop, USB passthrough | USB/IP over vsock only; no xHCI on ARM board | Parity gap (09-15 review §2.5) |
| Suspend/resume with GPU | Not supported; cold snapshots only | PLAN §3.8.8: reject accelerated suspend explicitly |
| VM window inside the Dory app | Separate `dory-hv` process window (§2.7) | Product gap |
| Uncompromised performance | 4 vCPU native ARM via HVF: CPU is host-speed. GPU: Venus/MoltenVK adds one translation layer (Vulkan→Metal), same as UTM; OpenGL via Zink adds a second. | Acceptable; the "no compromise" bar is met on CPU, ~80–90% on GPU by construction — the same ceiling as every non-Apple hypervisor on this platform |

Reading this honestly: the *hardware* side of a native-quality Linux desktop is 70–80% built, and the last 20% is not exotic — EDID, relative pointer, clipboard agent, guest-tools packaging, window-in-app. The 0% item is the one that blocks everything: no stock distribution can currently be *admitted* to the GPU path.

## 3. What you need to build (per guest)

### Linux ARM64 — closest to done
1. Host-side 16 KiB aperture allocator (replaces patch 0006).
2. Stock-profile graphics admission: kernel ≥ 6.13 + observed fence ordering + Venus capset handshake; managed kernel becomes optional, not required.
3. Restore `guest/mesa/dory-vulkan-probe.c`, `dory-vulkan-compositor-probe.c`, and a minimal `guest/kernel` (6.12 + 0007/0008 only, no 0006) as the *optional* managed graphics pack, or drop 6.12 and target 6.14 where 0007 is upstream.
4. `GET_EDID` (synthesize an EDID per scanout with the host panel's physical size so the guest computes the right DPI), relative-pointer capture mode in virtio-input, and a clipboard handler in `dory-core/agent` (Wayland via `wl-clipboard`/portal, X11 fallback).
5. Frame handoff to the app over XPC (IOSurface or shared texture) so the app owns the window.
5b. Package the agent as `.deb`/`.rpm` with systemd units so stock Ubuntu/Fedora users get resize, clipboard, shares and time sync without a managed image.
6. The §3.5 displayed-pixel campaign: triangle → glmark2 → GNOME on Ubuntu 24.04 HWE ARM64 and Fedora 42, all through the signed launcher, raw JSON + screenshot retained.
7. Zink-on-Venus vs VirGL2-on-ANGLE decision for OpenGL (`PLAN.md` §3.7) — measure, do not guess. Stock GNOME/Mutter needs GL 3.x or working Vulkan (Mutter does not use Vulkan; KWin 6 can). This decides whether Zink is required for GNOME.

### macOS ARM64 — GPU is done, product is not
1. Flip `DoryReleaseSupportPolicy.availability` for macOS once the 09-15 review §4 items land: display configuration from user settings (not fixed 1920×1080@144), user shared folders through the production adapter, host-build preflight for saved state.
2. Replace the screenshot-transcribed Metal receipt with a guest probe result over vsock.
3. Notarization (the 09-19 review says Apple notary returns 403 — developer agreement needs signing; nothing ships without it).

### Linux x86_64 — GPU is not the constraint
1. Do not start PC GPU until the 09-19 review's four boundaries are down to one. A 740-second boot cannot host a desktop regardless of GPU.
2. When you do: lift blob/`SET_SCANOUT_BLOB`/`MAP_BLOB` and the host-visible window out of `DoryHV/VirtioGPU.swift` into a transport-agnostic `DoryVirtioGPUCore` (PLAN §3.2), add `VIRTIO_PCI_CAP_SHARED_MEMORY_CFG` + a 64-bit prefetchable BAR to `DoryPCVirtioPCI`, and route the aperture through the DBT memory provider with code-invalidation hooks (§3.6.3). x86 guests get Venus + Zink only; VirGL2 is a second path you do not need to keep.
3. Stock x86 kernels ≥ 6.13 satisfy the fence contract the same way; the PC-specific `doryPCX8664LinuxVirGL2PrepareFBV1` contract enum should collapse into the same stock-profile check.

## 4. The path to connect what exists (ordered, with acceptance)

You have the worker, the device, the presenter, the fence insight, and the build system. The missing pieces are glue and a policy change, not new subsystems. Execute in this order and do not interleave x86 work:

1. **Trace P3-01 exactly as written** (1–2 days). Launch the Ubuntu 24.04 ARM64 cell with `hardwareAccelerated3D` forced through a debug authority, capture where admission fails (it will fail at the kernel-SHA gate), then temporarily bypass it and record the first *technical* failure (expected: `hv_vm_map` alignment on `MAP_BLOB`, or Venus capset mismatch with stock Mesa 24.x). This single trace tells you whether §2.3 and the Mesa-version risk in §2.8 are real. Acceptance: a written first-failure with the exact frame in `VirtioGPU.swift` or the worker.
2. **Host-side aperture allocator** (§2.3). Acceptance: stock 6.14 kernel `MAP_BLOB` succeeds at 4 KiB offsets; `DoryHVTests` cover neighbouring-blob exposure being intra-generation only.
3. **Stock graphics admission** (§2.2). Introduce `DoryGraphicsGuestProfile { managed(kernelSHA, mesaSHA), stock(observedKernel, fenceOrderingVerified, venusCapset) }`. Admission grants `hardwareAccelerated3D` provisionally for stock, worker verifies fence-before-flush on the first frames, downgrades to `.software` with a user-visible reason on violation (PLAN §3.9.4). Acceptance: app/CLI/API show requested vs effective profile.
4. **Displayed-pixel campaign on ARM** (§3.5). Restore the two probes, add a compute probe, run on Ubuntu 24.04 HWE and Fedora 42. Acceptance: raw JSON with device name ≠ llvmpipe/lavapipe, screenshot hash, worker Metal command-buffer completion IDs correlated.
5. **OpenGL decision** (§3.7). Run glmark2 + GNOME under Zink→Venus→MoltenVK and under VirGL2→ANGLE; pick per-profile default. Acceptance: a table, not an opinion.
6. **App-owned window** (§2.7). Move presentation surface to the app over XPC; keep `dory-hv` headless-capable. Acceptance: Linux and macOS VMs appear in the same app window chrome.
7. **macOS product items + policy flip** (§3, macOS). Can run in parallel with 2–6 by a different owner.
8. **Only then** return to x86 SMP, and start PC GPU (§3, x86) after the 09-19 activation criteria are met.

## 5. What to stop doing

- Stop treating the deletion of `guest/` as settled for the GPU programme. It was correct for the headless Ubuntu Server cell and for removing the QEMU image builder; it was not correct to remove the kernel patches and Vulkan probes without a replacement plan. Either restore `guest/kernel` (without 0006) and `guest/mesa` probes, or implement §4 step 3 so they are unnecessary. Do not leave `PLAN.md` Part 3 pointing at deleted files.
- Stop gating GPU on Dory-signed guest kernels as the *only* path. It guarantees no user with a stock distro ever sees acceleration.
- Stop spending the GPU team's cycles on x86 memory-model cells until ARM has one displayed frame.
- Stop calling container Venus compute "Linux GPU" in status summaries. `PLAN.md` already forbids it; keep it that way.

## Appendix — files inspected

`PLAN.md` §1.1, §3.1–3.10; `READINESS-REVIEW-2026-09-15.md`; `READINESS-TASKS-2026-09-15.md`; `X86_64-LINUX-READINESS-REVIEW-2026-09-19.md`;
`Packages/ContainerizationEngine/Package.swift`; `Sources/DoryHV/VirtioGPU.swift`; `Sources/DoryHV/DoryPCVirGLRendererAuthority.swift`; `Sources/DoryVirglRendererShim/DoryVirglRendererSession.c`; `Sources/DoryVirglRendererShim/include/DoryVirglRendererShim.h`; `Sources/dory-hv/DesktopMetalDisplay.swift`; `Sources/dory-hv/DesktopMode.swift`;
`dory-core-swift/Sources/DoryVirtio/DoryVirtioGPU.swift`; `DoryVirtio/DoryVirtioGPUAcceleration.swift`; `DoryMachinePC/DoryPCVirtioPCI.swift`; `DoryOperations/DoryVirtualizationPlatform.swift`; `DoryOperations/DoryVirtualMachineCapabilities.swift`; `DorydKit/MachineManager.swift` (~13795–14080); `DoryRendererWorkerWireContracts/DoryRendererWorkerIdentity.swift`; `DoryVZMacCore/DoryVZMacConfigurationBuilder.swift`;
`scripts/build-virglrenderer.sh`; `scripts/build-renderer-production-dependencies.sh`; `scripts/renderer-production-tuple.py`; `patches/`;
`git show 583840fc1e --stat` and `583840fc1e^:guest/kernel/{PINS,patches/6.12.106/0006,0007}`, `583840fc1e^:guest/mesa/PINS`.
