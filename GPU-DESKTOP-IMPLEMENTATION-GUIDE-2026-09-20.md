# Dory — implementation guide: GPU-accelerated Linux desktops on Apple Silicon

Companion to `GPU-VM-READINESS-REVIEW-2026-09-20.md`. This is an execution guide, not a new roadmap: every step maps to a `PLAN.md` section, and `PLAN.md` should absorb the decisions below once made. File and symbol names are from the tree at `f8cad1ea5`.

**Goal:** a user installs stock Ubuntu 24.04+ or Fedora 42+ (ARM64) from the vendor ISO in the Dory app, logs into GNOME/KDE, and gets a hardware-accelerated, HiDPI-correct, clipboard-sharing desktop in a Dory window. Then macOS. Then x86_64.

**Ownership boundary (unchanged):** Hypervisor.framework, Virtualization.framework, Metal, EDK2, Mesa, virglrenderer, ANGLE, MoltenVK are permitted dependencies. No QEMU anywhere, including build tooling.

## Decisions (made 2026-09-20; record in PLAN.md §3.3 and §3.4)

**D1 — Aperture overlap policy: intra-VM padding visibility, not rejection.**
All blobs of one VM are allocated from one contiguous per-VM, per-worker-generation SHM arena that mirrors the guest aperture 1:1. `MAP_BLOB` maps whole 16 KiB granules; up to 12 KiB of a neighbouring blob *from the same VM* may become guest-visible. Rationale: the guest DRM allocator places blobs at 4 KiB boundaries, so rejection would surface as random `VK_ERROR_OUT_OF_DEVICE_MEMORY` under GNOME; the padding exposes nothing across VMs or to the host, and it needs no guest kernel change. Never place non-GPU data in the arena.

**D2 — Stock-only guest profile. Do not restore the managed kernel/Mesa pack.**
The product path is vendor ISOs with kernel ≥ 6.13 and distro Mesa; correctness is established at runtime (fence-ordering verification + Venus capset negotiation), not by a Dory-signed kernel digest. Rationale: one guest profile to qualify instead of two; no kernel maintenance burden; matches what users of Parallels/UTM expect; `guest/kernel` is not restored, `guest/qemu-builder` stays gone. Keep `DoryGraphicsGuestProfile.managed` as an enum case only so the type can grow later, with no admission path behind it. If A2-bis shows the UTM virglrenderer fork cannot serve stock Mesa, rebase the fork onto upstream — do not answer with a managed Mesa.

**D3 — Pre-6.13 kernels get a working software desktop, never a broken accelerated one.**
Downgrade is automatic, visible, and explains itself. The guest-tools package (B4) later offers the HWE/newer-kernel hint; Dory never replaces a user's kernel.

**D4 — Venus is the primary API; OpenGL path is chosen by A5 measurement, with Zink→Venus as the presumptive default** because it removes a whole renderer (VirGL2/ANGLE) from the tuple if it passes. VirGL2 is retained only if a named GNOME/GTK/Qt workload fails on Zink.

**D5 — The Dory app owns the window; `dory-hv` owns the VM.** Frames cross as IOSurface/shared-texture leases over XPC (B5). No second `NSApplication`.

**D6 — Order is A → B ∥ C → D. No x86 GPU work, and no x86 commits by the GPU owner, until A4 has one retained displayed-pixel receipt.**

---

## Phase A — Make one accelerated frame appear on stock Ubuntu (PLAN §3.1–3.5)

Nothing else matters until this works. Estimated shape: 5 engineering steps, each with a hard acceptance test.

### A1. Trace the production graphics path and find the first real failure (PLAN §3.1)

**Why first:** you have never launched a Linux VM with `hardwareAccelerated3D` through the daemon. The first failure will decide the design of A2/A3.

1. Build the production renderer worker once so the shim actually binds virglrenderer:
   ```
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
   scripts/build-renderer-production-dependencies.sh --prefix /tmp/dory-renderer-deps --jobs 3
   scripts/build-virglrenderer.sh ...            # see header for args
   scripts/assemble-renderer-production-worker.sh ...
   ```
   Keep the resulting inventory JSON; `renderer-production-tuple.py` will need it in A3.
2. Add a **developer-only bypass** for the guest-identity gate. In `dory-core-swift/Sources/DorydKit/MachineManager.swift` around the `.hardwareAccelerated3D` case (PC ≈ line 13812; find the ARM twin by grepping `rendererGuestKernelSHA256`), allow `DORY_GRAPHICS_ADMISSION_OVERRIDE=unsafe-development` to substitute a synthetic kernel/Mesa digest. Compile it out in release (`#if DEBUG`). This is scaffolding; A3 removes the need for it.
3. Install Ubuntu 24.04.3+ Desktop ARM64 (HWE kernel 6.14 — verify `uname -r` ≥ 6.13 inside the guest; 6.13 is where upstream `30f86b8f86ad` landed). Launch with the override.
4. Enable the existing trace (`33cd3e2e4 feat(hv): persist opt-in graphics trace`, `a93458b49` correlated scanout tracing) and record, in order: capset handshake → `CTX_CREATE` → first `RESOURCE_CREATE_BLOB` → `MAP_BLOB` → first `SUBMIT_3D` → first fence → first `SET_SCANOUT_BLOB` → first `RESOURCE_FLUSH` → worker `MTLSharedTextureHandle` export → `DesktopMetalView` present.
5. Write `docs/virtualization/evidence/gpu-trace-2026-XX/first-failure.json` with the exact step, the frame in `VirtioGPU.swift` / worker, and guest `dmesg` + `journalctl -u gdm`.

**Expected failures (prepare for both):**
- `MAP_BLOB` offset not 16 KiB-aligned → `hv_vm_map` fails in `VirtioGPUHostVisibleMemory.map` (`VirtioGPU.swift:1642`). Go to A2.
- Venus capset/version mismatch between stock Mesa 24.x/25.x and the UTM virglrenderer fork (`65cc14eb`). Go to A2-bis.

**Acceptance:** one retained trace with an identified first failure. Not a screenshot; the JSON.

### A2. Host-side 16 KiB aperture allocator (PLAN §3.3.5) — replaces deleted kernel patch 0006

**Where:** `Packages/ContainerizationEngine/Sources/DoryHV/VirtioGPU.swift` — `VirtioGPUHostVisibleMemory`, the `.mapBlob`/`.createBlob` renderer lane, and the worker side in `DoryRendererWorkerVirglBackend`.

The problem: a stock guest hands you `MAP_BLOB` at any 4 KiB offset; `hv_vm_map` requires 16 KiB host-page alignment for both host pointer and GPA. Today `map()` rejects that (`offset.isMultiple(of: HostPage.size)`).

Design:
1. **Worker allocates blobs 16 KiB-aligned and 16 KiB-padded** in its SHM. The guest-visible blob `size` is unchanged; only the backing is padded. (This is the host half of what patch 0006 did in the guest.)
2. **Aperture as a slab.** Replace the ad-hoc `mappings: [UInt32: (offset,size)]` with a 16 KiB-granule bitmap over the window. On `MAP_BLOB(offset, size)`:
   - Compute `[floor16(offset), ceil16(offset+size))`.
   - Per **D1**, overlapping granules shared with a neighbouring blob are mapped, not rejected. Consecutive granules from different blobs must therefore be backed by *contiguous host memory*: **the worker allocates all blobs of a VM out of one contiguous SHM arena that mirrors the aperture 1:1** (arena offset == aperture offset). `MAP_BLOB` becomes `hv_vm_map(arenaBase + floor16(offset), guestBase + floor16(offset), granuleBytes)` for any granule not yet mapped; `UNMAP_BLOB` unmaps only granules no longer referenced by any live blob (refcount per granule).
3. **Arena sizing.** Default window is 256 MiB (`VirtioGPUHostVisibleMemory.init`). Make it a machine setting (1–4 GiB for desktops; Venus host-visible memory is where all `HOST_VISIBLE|COHERENT` Vulkan heaps live, and GNOME + a browser will exceed 256 MiB). Reserve as a `MAP_SHARED|MAP_NORESERVE` `shm_open` arena in the worker, pass the FD once at bootstrap (extend `DoryRendererWorkerBootstrap`), `mmap` in the VMM once. This also removes the per-blob FD handoff in `DoryRendererWorkerBlobMappingAuthority`.
4. Keep `resource_map_info` (cache attributes) per blob; the guest already gets it from `MAP_BLOB` response.
5. Tests in `DoryHVTests`: 4 KiB-offset map succeeds; adjacent blobs share a granule and unmap in either order; unmap of the last referrer actually `hv_vm_unmap`s; reset releases everything; fuzz `offset/size` overflow.

**Acceptance:** stock 6.14 kernel completes `MAP_BLOB` for every blob GNOME creates in the first 60 s; no `hv_vm_map` error in the trace; tests pass under TSan.

### A2-bis. Venus protocol compatibility with stock Mesa

If A1 shows a capset/version mismatch:
1. Compare `VN_MAX_VERSION` / `vn_info_wire_format_version` in `utmapp/virglrenderer@65cc14eb` against Mesa 24.2 (Ubuntu 24.04), 25.0 (Ubuntu 25.04 / Fedora 42), 25.1+.
2. If the fork is behind upstream, rebase the pinned virglrenderer onto upstream `main` while carrying the three Dory patches and UTM's Metal patches (`patches/virglrenderer-*.patch`). Update `Config/DoryRendererProductionTuple.json` and `renderer-production-tuple.py` `EXPECTED_SOURCES`.
3. Add a **capset negotiation table** in the worker: the Venus capset it advertises must be the intersection of MoltenVK-supported features and what the guest Mesa version can consume. Reject a guest Mesa older than the minimum with a user-visible reason (PLAN §3.9.5).

**Acceptance:** `vulkaninfo` inside the guest reports the Venus device (`Virtio-GPU Venus (Apple M2 Pro)`), not lavapipe.

### A3. Stock-profile graphics admission (PLAN §3.4.5–6, §3.9) — replaces the signed-kernel gate

**Where:** `MachineManager.swift` (`.hardwareAccelerated3D` cases; `producerFenceContract` default at ≈1395; bootstrap construction at ≈15060), `DoryRendererWorkerIdentity.swift` (`DoryRendererProducerFenceContract`), `DoryVirtualMachineCapabilities.swift`, `DoryRendererWorkerBootstrap`.

1. **Extract first.** Move the graphics admission out of `MachineManager` into `DorydKit/DoryGraphicsAdmission.swift` with a pure function `admit(request, evidence, hostFacts) -> DoryGraphicsAdmissionDecision`. Unit-test it. Do not do steps 2–5 inside the 25k-line file.
2. **Introduce the profile type:**
   ```swift
   enum DoryGraphicsGuestProfile {
     case managed(kernelSHA256: String, mesaSHA256: String, fence: DoryRendererProducerFenceContract)
     case stock(minimumKernel: KernelVersion /* 6.13 */, minimumMesa: MesaVersion, fenceVerification: .observedAtRuntime)
   }
   ```
   `DoryRendererProducerFenceContract` gains `case upstreamPrepareFBLinux613 = 3`. `DoryRendererArtifactManifest.managedGuestKernel` becomes optional. Per **D2**, `.managed` has no admission path in this release; `.stock` is the only profile that can be admitted.
3. **Admission for `.stock`** grants `hardwareAccelerated3D` *provisionally*: `effectiveGraphics = .hardwareAccelerated3D(state: .provisional)`. The catalog no longer needs `rendererGuestKernelSHA256`. Keep the *worker* identity requirements (code-directory hash, candidate inventory) exactly as they are — the host side is still Dory-signed.
4. **Runtime fence verification in the worker.** In `DoryRendererWorkerVirglBackend`, for the first N (=30) `RESOURCE_FLUSH` on a scanout-bound blob, check that the producing context's last fence for that resource has already signalled (`virgl_renderer_context_create_fence` callback ordering vs. the flush arrival). If a flush arrives before its producer fence: mark `fenceContractViolated`, report through the existing `VirtioGPURendererRuntimeFailure` path, and have the VMM downgrade presentation to CPU-copy path with reason `guestKernelLacksPrepareFB` (this is the observable behaviour of a pre-6.13 kernel). After N clean frames, promote `.provisional → .verified`. Both states are surfaced (step 6).
5. **Guest-side hint via agent (optional, faster).** When `dory-core/agent` is present, report `uname -r`, `/sys/module/virtio_gpu/version`, and `vulkaninfo --summary` over vsock; admission uses it to skip the provisional window. Without the agent, runtime verification alone decides.
6. **Truthful state (PLAN §3.9).** `DoryMachineDisplayPresentationStore` and the API expose: `requestedGraphics`, `admittedGraphics`, `verificationState (provisional|verified|downgraded(reason))`, `guestDriver (venus|virgl|software)`, `firstShaderCompletedAt`, `firstPresentationCompletedAt`. App shows a small status pill; CLI `dory vm inspect` prints it.
7. Delete the A1 development override.

**Acceptance:** stock Ubuntu 24.04 HWE and Fedora 42 launch accelerated with no catalog kernel hash; a deliberately old kernel (Ubuntu 22.04 GA 5.15) downgrades with a user-visible reason and still boots to a working software desktop; `DoryGraphicsAdmissionTests` cover every branch.

### A4. Displayed-pixel campaign (PLAN §3.5)

1. Restore the probes from git: `git show 583840fc1e^:guest/mesa/dory-vulkan-probe.c` and `dory-vulkan-compositor-probe.c` into a new top-level `guest-probes/` (not `guest/`, to avoid re-importing the deleted image tree). Add `dory-compute-probe.c` (deterministic 1M-element reduction with a checked hash) and `dory-gl-probe.c` (textured, alpha-blended, rotated quad with frame number + nonce rendered as text).
2. Build them **inside the guest** with the distro's toolchain (they are stock-distro probes); no cross builds, no Docker.
3. Each probe emits JSON: device name, driver, API version, extensions used, result hash, frame count, nonce, timings. Reject `llvmpipe`/`lavapipe` in the probe itself.
4. Host side: extend `scripts/arm-ubuntu-scenario-driver.sh` (there is already an uncommitted modification there — review it first) to: launch through the **signed** daemon path, pull probe JSON over vsock, capture the Dory window via `CGWindowListCreateImage`, hash it, and correlate with the worker's Metal command-buffer completion IDs (`onWorkerPresentationCompleted`).
5. Run on: Ubuntu 24.04 HWE, Ubuntu 25.04, Fedora 42, Debian 13. GNOME (Mutter) and KDE Plasma 6 (KWin). Record failures as failures.

**Acceptance:** four retained bundles with matching probe hash + window hash on a physical Apple GPU, launched via the signed path, no override. This is the first real "Linux GPU" receipt Dory has ever had.

### A5. OpenGL strategy — measured, not chosen (PLAN §3.7)

GNOME/Mutter and most GTK/Qt apps are OpenGL, not Vulkan. Two candidate paths exist in your tuple:
- **VirGL2 → ANGLE → Metal** (UTM's path; GLES 3.x-ish, GL compatibility via virgl).
- **Zink → Venus → MoltenVK** (Mesa's GL-on-Vulkan; requires a decent Vulkan feature set from MoltenVK — check `VK_EXT_robustness2`, `VK_KHR_dynamic_rendering`, `VK_EXT_extended_dynamic_state`, timeline semaphores; your `moltenvk-fail-closed-robustness2.patch` is directly relevant).

1. Same guest, same host, same resolution; run glmark2 (all scenes), GNOME Shell overview animations, Firefox WebGL Aquarium, Blender viewport, LibreOffice Impress transitions.
2. Record per path: GL version reported, glmark2 score, p95 frame interval, shader-compile stall on first use, worker RSS, failures.
3. Pick the default per profile. Retain the second only for a named compatibility need. Expect: Zink wins on GL level and correctness, VirGL2 wins on startup; but measure.

**Acceptance:** a table in `docs/virtualization/evidence/`, and PLAN §3.7 updated with the decision.

---

## Phase B — Make it a desktop, not a demo (PLAN §3.8, §4.7–4.9)

Can run in parallel with A4/A5 by a second owner. Ordered by user impact.

### B1. EDID and HiDPI
- `VirtioGPU.swift`: implement `VIRTIO_GPU_CMD_GET_EDID (0x010A)` and advertise `VIRTIO_GPU_F_EDID`. Synthesize a 128-byte EDID per scanout: preferred mode = current window size in guest pixels, physical size (cm) derived from the host panel's `NSScreen` physical size × the window fraction, so the guest computes ~the host DPI. Regenerate and raise `VIRTIO_GPU_EVENT_DISPLAY` on resize/scale change (hook `updateScanoutSize`).
- `DesktopMetalDisplay.swift`: `guestBackingScaleFactor` is already plumbed — make the guest render at 2× on Retina by default with a user toggle ("Retina resolution" vs "Scaled").
- **Acceptance:** GNOME reports 200% scale automatically on a Retina host; text is crisp; dragging the window between a 2× and 1× display re-modes without a black frame.

### B2. Relative pointer capture
- `VirtioInput.swift`: add `case relativePointer` endpoint (`EV_REL` REL_X/REL_Y/REL_WHEEL/REL_HWHEEL + BTN_*), alongside the existing `absolutePointer`.
- `DesktopMode.swift`: capture mode toggled by click-in / Ctrl+Cmd release; hide host cursor, `CGAssociateMouseAndMouseCursorPosition(false)`, feed deltas.
- **Acceptance:** Blender orbit and a first-person game are usable; pointer never escapes or jumps on capture/release.

### B3. Clipboard
- `dory-core/agent` (Rust): add a `clipboard` handler in `dispatch.rs` with Wayland (`wl-clipboard`/`ext-data-control-v1` via `wayland-client`) and X11 (`x11-clipboard`) backends; text + image/png first. Push/pull over vsock, bounded size, mime whitelist.
- Host: `DesktopMode.ClipboardPlan` already exists; wire `NSPasteboard.changeCount` polling → agent; agent → `NSPasteboard`.
- **Acceptance:** bidirectional text and image paste between host and GNOME/KDE sessions; policy `.off` provably sends nothing.

### B4. Guest tools for stock distros
- Package the agent as `dory-guest-tools` `.deb` (Ubuntu/Debian) and `.rpm` (Fedora) with systemd units: `dory-agent.service` (vsock), `dory-clipboard.service` (user session), udev rule for resize. Build with the distro's native tooling in a Dory VM (no Docker/QEMU dependency in the pipeline). Sign the repo; expose it as an in-app "Install Dory Guest Tools" action that mounts an ISO with the packages.
- **Acceptance:** fresh Ubuntu Desktop install → tools ISO → `apt install` → resize, clipboard, shares, time sync work; uninstall is clean.

### B5. VM window inside the Dory app
- Keep `dory-hv` as the VM/worker owner; make it able to run **headless** (no `NSApplication`) and export each scanout as an `IOSurface` (create from the worker SHM granules with `IOSurfaceCreate` + `kIOSurfaceBytesPerRow` from the blob stride, or wrap the `MTLSharedTextureHandle` you already export) over the existing XPC channel with the same generation-bound lease model.
- Dory app: `LinuxMachineDisplayView` (Metal, like `DesktopMetalView`) that samples the IOSurface; input events go back over the same channel. `VZVirtualMachineView` for macOS guests sits next to it in the same window chrome.
- **Acceptance:** a Linux VM and a macOS VM open as tabs/windows of the Dory app; fullscreen, Spaces, minimise, and multi-display work identically for both.

### B6. Multi-display and hot-plug
- Allow N scanouts (already an array); add/remove at runtime with `VIRTIO_GPU_EVENT_DISPLAY`; per-display EDID (B1).
- **Acceptance:** add a second display while GNOME is running; it appears in Settings → Displays with correct DPI.

### B7. Backpressure and resilience (PLAN §3.8.3–5)
- Bound queued worker frames to 2; drop oldest; measure p95/p99 present interval.
- Kill the worker mid-render: guest sees device loss (`VK_ERROR_DEVICE_LOST`), GNOME falls back, VM stays up, disk intact, user sees the reason, "Restart graphics" action relaunches the worker with a new generation.
- **Acceptance:** worker `kill -9` during glmark2 never takes the VM down.

### B8. Suspend policy
- Reject saved-state suspend for accelerated profiles with a clear message (PLAN §3.8.8); offer guest suspend-to-RAM and cold snapshots.

---

## Phase C — macOS guests (PLAN Part 4) — parallel owner

GPU is Apple's; this is product work.
1. Display configuration from user settings in `DoryVZMacConfigurationBuilder` (multiple `VZMacGraphicsDisplayConfiguration`, user-chosen size/PPI; not a fixed 1920×1080@144).
2. User shared folders through the production adapter (policy currently rejects them).
3. Saved-state host-build preflight; hash only the header, not the whole state.
4. Bridged/host-only networking (`com.apple.vm.networking` entitlement request).
5. Replace the screenshot-transcribed Metal receipt with a guest-side probe over vsock.
6. Notarization: the notary service returns 403 — the developer agreement must be signed on the Apple Developer site before anything ships.
7. Flip `DoryReleaseSupportPolicy.availability` for macOS; keep `releaseQualified: false` until two clean campaigns.

---

## Phase D — x86_64 desktops (PLAN §2, §3.6) — only after A and B

Do not start GPU here until the x86 review's activation criteria are met (real SMP, x86-64-v2, UEFI lifecycle, ≥ ~300 MIPS sustained). Then:
1. Lift blob/`SET_SCANOUT_BLOB`/`MAP_BLOB`/aperture logic from `DoryHV/VirtioGPU.swift` into transport-agnostic `DoryVirtioGPUCore` in `dory-core-swift/Sources/DoryVirtio` (PLAN §3.2). Both ARM MMIO and PC PCI devices become thin transports.
2. `DoryPCVirtioPCI.swift`: add `VIRTIO_PCI_CAP_SHARED_MEMORY_CFG` (shmid 0, 64-bit prefetchable BAR 2, 1–4 GiB). EDK2 `DoryPC` firmware must size the BAR; Linux virtio-gpu discovers it via `virtio_get_shm_region`.
3. Route the aperture through the DBT memory provider with alias/code-invalidation hooks (PLAN §2.6/§3.6.3): guest x86 code may live near or write into mapped blobs; `hv_vm_map` does not apply here — the translator's sparse memory must alias the worker arena.
4. Venus + Zink only on PC; collapse `doryPCX8664LinuxVirGL2PrepareFBV1` into the stock profile (A3).
5. Repeat A4 with an x86 kernel/Mesa inside the x86 VM (not amd64 in the ARM container VM).

---

## Sequencing and ownership

| Week | Owner 1 (GPU) | Owner 2 (Desktop) | Owner 3 (macOS/product) |
|---|---|---|---|
| 1 | A1 trace, A2 design | B1 EDID | C1–C3 |
| 2–3 | A2 allocator, A2-bis if needed | B2 relative pointer, B3 clipboard | C4–C6 |
| 4–5 | A3 stock admission + extraction | B4 guest tools | C7, two macOS campaigns |
| 6–7 | A4 campaign, A5 GL measurement | B5 window-in-app | — |
| 8+ | B7 resilience, PLAN Part 3 exit | B6, B8 | Part 5 hardening |

Rules while executing:
- No x86 commits from Owner 1 until A4 has one retained bundle.
- Every step's acceptance test lands in the same PR as the code.
- Every receipt is raw JSON + hashes, launched through the signed path, or it is "development evidence" and says so.
- Update `PLAN.md` §1.1, §3.3, §3.4, §3.7 as decisions are made; delete `PLAN.md` references to `guest/mesa` and `guest/kernel` when `guest-probes/` and A3 replace them.

## Definition of done (Part 3 exit, restated)

A stock Ubuntu 24.04 HWE ARM64 desktop and a Fedora 42 desktop, installed from vendor ISOs in the Dory app with no Dory kernel, run GNOME and KDE with hardware Venus/GL, correct HiDPI, clipboard, shares, relative pointer, in a Dory-owned window; `glmark2` and a WebGL page run on the Apple GPU (device name verified, no software fallback); killing the renderer never kills the VM; and all of it is recorded by replayable receipts launched through the signed daemon path.
