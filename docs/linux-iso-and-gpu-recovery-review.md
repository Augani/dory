# Linux ISO and GPU recovery review

- **Decision date:** 2026-08-26
- **Status:** Portable ARM64 EFI recovery and dual-renderer admission implemented; physical preview calibration passes, while the public release gate remains closed pending release-signed/notarized matrix evidence
- **Scope:** Linux installation media, normal desktop application behavior, and GPU acceleration on Apple Silicon

## Product contract

Dory's baseline promise is that a user can select a compatible ARM64 Linux EFI ISO, install it to
a persistent virtual disk, eject the installer, and cold-boot the installed system with ordinary
storage, network, keyboard, pointer, audio, and display devices. Guest tools may improve clipboard,
sharing, resize, and shutdown, but they are not a boot requirement.

“Any Linux distro” means a distribution whose ARM64 installer contains the standard EFI and VirtIO
drivers needed by the presented virtual hardware. It does not mean that an x86_64 ISO can use
Apple-Silicon hardware virtualization. Whole-system x86_64 support is a separate QEMU TCG emulation
product tier and will be materially slower. Rosetta can translate x86_64 applications inside a
compatible ARM64 Linux guest; it cannot install or boot an x86_64 distribution.

GPU acceleration is an optional capability above that baseline. Its absence or failed activation
must never prevent the desktop or software-rendered applications from starting.

## What was broken

| Priority | Fault | User-visible effect |
|---|---|---|
| P0 | Structurally valid, unqualified ARM64 EFI media was reclassified as experimental during runtime planning, while the create path never authorized experimental candidates. | The UI accepted and copied an ISO, but the daemon could reject it before launch. |
| P0 | The production renderer tuple was Venus-only while the worker bootstrap and receipt required VirGL2 plus Venus. | The packaged worker could not satisfy its own activation contract, so hardware 3D could not be honestly admitted. |
| P0 | The guest display manager used a hard `Requires=` dependency on graphics preflight. | A missing, incompatible, or failed Venus pack could prevent GDM and therefore every desktop app from starting. |
| P0 | The managed Ubuntu image had reverted the known Xorg, GTK4 GL-renderer, and Firefox XWayland compatibility settings. | Firefox and GTK applications could stay alive without a usable mapped window or display corrupt textures. |
| P0 | RawHV advertised host-accelerated display even though its desktop runtime rejects that mode. | Automatic fallback could choose a mode that deterministically fails instead of reaching software graphics. |
| P0 | Linux XR24/XRGB resources retained guest VirGL format 2, while Dory intentionally transported their byte-identical Metal scanout as canonical BGRA format 1; the worker compared the two numeric identifiers verbatim. | GNOME's ARGB resources could present, but ordinary XRGB desktop updates were rejected as `RESOURCE_FLUSH` response `0x1205`, producing a partially visible desktop whose applications appeared not to launch. |
| P1 | The live gate required Venus/Zed for every managed distro and used `xwininfo` as native-Wayland evidence. | Tests encoded an impossible or irrelevant success definition and obscured the functioning baseline. |

The retired Venus-only design was not complete GNOME acceleration. Venus transports Vulkan. GNOME Shell's
Mutter/Cogl compositor is still an OpenGL/EGL consumer, and the earlier real-device evidence had
shown GNOME on `kms_swrast`, Xorg without DRI3, and Zed presenting one frame without meeting
sustained liveness. That earlier evidence qualified neither the compositor nor the complete desktop.

## Recovery implemented in this change

1. A structurally inspected ARM64 Linux EFI installer or disk on Virtualization.framework is now a
   supported, runnable portable baseline when exact runtime qualification is absent. Structural
   inspection, architecture checks, media identity, mutable-disk provenance, device checks, and
   known failed qualification still fail closed.
2. RawHV no longer advertises the host-display level that its runtime rejects, allowing automatic
   planning to continue to a launchable backend/graphics level.
3. Graphics activation publishes requested and effective state transactionally. If Venus
   preflight is missing or fails, the managed guest records the failure, removes the private Vulkan
   environment, keeps the effective VirGL desktop path, and returns success so login can continue.
4. The display manager now orders graphics activation with `Wants=` and `After=` instead of making
   it a hard prerequisite.
5. Managed Ubuntu returns to its currently qualified Xorg compatibility cell with
   `GSK_RENDERER=gl`, Firefox XWayland presentation, software WebRender, and DMA-BUF presentation
   disabled. These settings are managed-image compatibility policy, not mutations applied to a
   user's stock ISO.
6. Unit and offline image checks now distinguish optional acceleration from desktop availability
   and prove that an explicit failed runtime qualification remains blocked.
7. Production identity is now the schema-3 `dory-dual-metal-20260826` tuple: the signed worker,
   its XPC-local ANGLE Metal pair, VirGL2 capset 2, and Venus capset 4 are one inventoried graph.
8. A build-time command in the already-signed runner launches that exact nested XPC and emits a
   canonical transcript receipt. Runtime activation reboots a fresh worker generation and compares
   its exact capset digests, feature bits, worker identity, inventory, Mesa, and managed kernel.
9. Developer-ID-sealed evidence can authorize preview hardware testing. Public release/support
   additionally requires the pinned detached Ed25519 signature; a present invalid signature never
   downgrades to preview.
10. Renderer-worker, candidate Metal-device, and candidate GPU-quiescence failures now leave the
    helper through a dedicated status instead of looking like a guest boot error. The daemon stops
    startup retries, records a circuit breaker against the exact runner/inventory/worker digests,
    and suppresses that candidate for six hours.
11. The next automatic production plan can therefore select its already-declared software
    recovery level. A hardware-only request receives an explicit unavailable-plan error; the
    daemon never silently changes an exact user request.
12. Scanout admission now canonicalizes only the two byte-layout-equivalent alpha/X pairs:
    VirGL formats `1/2` map to BGRA transport `1`, and `67/68` map to RGBA transport `67`.
    Cross-family and unknown aliases remain rejected before a Metal texture is acquired.

## Target architecture

### Tier A — portable ARM64 EFI baseline

- Virtualization.framework firmware, persistent EFI variable store, and stable machine identity.
- Read-only installer media plus persistent NVMe disk.
- Standard VirtIO 2D display, keyboard, pointer, network, audio, and serial diagnostics.
- Distribution-owned Mesa software rendering (`llvmpipe`/`lavapipe`) when no 3D renderer is
  negotiated.
- No Dory kernel parameters, global Mesa overrides, or Dory Tools requirement for a stock ISO.

This tier is the recovery and compatibility invariant. Dory may label an unknown exact distro
“Unqualified,” but absence of a qualification record alone cannot make structurally compatible
media unbootable.

### Tier B — optional integration

The guest and host negotiate versioned clipboard, resize, sharing, clock, graceful shutdown, and
optional Rosetta registration. Each feature degrades independently when tools are absent or older.

### Tier C — isolated acceleration

The shipping macOS path should expose independent capabilities rather than one ambiguous “GPU”
flag:

- **VirGL/OpenGL:** desktop compositor and conventional Linux GUI acceleration.
- **Venus/Vulkan:** native Vulkan applications that meet the exact kernel, Mesa, capset, blob,
  host-visible-memory, context-init, and WSI requirements.
- **Software:** always retained as a recovery path.

The practical current design is a standards-compatible VirtIO GPU on RawHV or pinned QEMU/HVF,
with VirGL and Venus implemented by a separately signed, sandboxed renderer process. The process
must have bounded queues, memory, commands, shader work, and timeouts; no network; no arbitrary
filesystem access; generation-bound resources; and explicit reset. A renderer crash invalidates
the accelerated generation. Because submitted fences, resources, and scanout ownership are then
uncertain, the current implementation stops the VM cleanly instead of attempting an unsafe in-VM
renderer swap. It does not mutate the guest disk. The exact failed candidate is durably suppressed,
so the next automatic production plan selects a declared software recovery level; an explicit
hardware-only plan remains an error. Live in-VM renderer replacement is future work and requires a
guest-visible device reset protocol that proves every old generation resource has retired.

The package and worker contract are now coherently dual-capset and fail closed without a real
bootstrap receipt. The repaired tuple passed a physical Developer-ID preview calibration on
2026-08-26, but that calibration deliberately records `not-release-qualifying`: it is not the
release-signed and notarized artifact required for a public support claim. Hardware 3D therefore
remains Unqualified for public release and the portable Tier-A recovery path is retained.

### 2026-08-26 physical preview result

Candidate `eb0a840980c4e1b843720de60bbf56f9fe9b89699fc23a675dc16704f191797a`
ran on a Mac14,10 with Apple M2 Pro and macOS 27 build 26A5416b. Its runner SHA-256 was
`e28c725ac615eb22fbde90b66886e467e0020afe543668cabd962e96f3248396`, its renderer-worker
SHA-256 was `2393647b8f844b8b41ae32b70797df6040adf3a9971ebef8a5d0d062b616e943`, and its candidate
inventory SHA-256 was `b2ef1a8897fcde2beec1bd62476d7c356e93d724b6bafeceda738134ce8b0db3`.

The managed Ubuntu 24.04 guest reached GNOME graphical target and remained live for more than 15
minutes. `glxinfo` reported direct, accelerated VirGL rendering rather than llvmpipe; `glxgears`
ran for 35 seconds at approximately 147–157 FPS. The Venus probe created an XCB surface and
256x256 FIFO swapchain, acquired, rendered, submitted, presented, and reached idle on `Virtio-GPU
Venus (Apple M2 Pro)`. Firefox, Files, Calculator, Settings, Terminal, and Zed 1.16.1 all mapped
full windows and remained alive. Zed mapped `/opt/dory/mesa/lib/libvulkan_virtio.so` and sustained
its native Venus window for 30 seconds. Both guest and host logs contained zero rejected
`RESOURCE_FLUSH` commands, zero `VK_ERROR_DEVICE_LOST`, and zero GPU-quiescence failures.

This closes the observed functional XR24 blocker. It does not waive the release-signature,
notarization, recovery/fault-injection, multi-host, or full managed-distro matrix gates.

macOS 27 custom VirtIO APIs are a future VZ integration opportunity, not the present recovery
plan. They do not remove the need for a Linux guest driver, renderer isolation, protocol bounds,
presentation, reset, saved-state, and exact-candidate evidence.

## Release matrix and gates

The generic-ISO gate is separate from the managed-rootfs acceleration gate. At minimum it must run
current ARM64 installers for Ubuntu, Debian, Fedora, openSUSE, and one rolling distribution through:

1. ISO inspection and private import.
2. EFI installer boot, partitioning, and installation.
3. ISO ejection and cold boot from disk with the same EFI/NVRAM identity.
4. Network, input, audio, resize, suspend/restart, and serial recovery.
5. Login plus sustained visible launch of a terminal, file manager, settings application, browser,
   and one GTK4/Qt application using software graphics.
6. Kernel and bootloader update followed by reboot.
7. Missing-tools behavior and snapshot/export/import of disk plus firmware state.

Acceleration has its own exact matrix. A release claim requires the exact signed worker and guest
tuple to bootstrap for real, negotiate exactly the advertised capsets, show the actual Mesa
renderer, produce a synchronized host-presented frame, survive resize/reset/worker death, and keep
the compositor and representative applications alive for a sustained run. Fixture-only capset
tests and a single first frame are not release evidence.

The release wrapper now requires all of the following, with no `FAIL`/`UNAVAILABLE` allowance:
an authenticated renderer-release receipt, direct Mesa rendering whose renderer is VirGL (never
llvmpipe/softpipe/swrast), a mapped sustained `glxgears` workload, and Ubuntu Zed using the Venus
Vulkan ICD through surface creation, swapchain rendering, presentation, and sustained liveness.

Native Wayland, XWayland/X11, VirGL, Venus, and software rendering are separate test cells. A gate
must use compositor-aware surface evidence and host-visible frame change for native Wayland; an
X11 window-tree query cannot prove a native-Wayland window is usable.

## Primary references

- [Apple: running GUI Linux in Virtualization.framework](https://developer.apple.com/documentation/virtualization/running-gui-linux-in-a-virtual-machine-on-a-mac)
- [Apple WWDC22: VirtIO GPU 2D Linux display](https://developer.apple.com/videos/play/wwdc2022/10002/)
- [Apple: Rosetta in ARM Linux VMs](https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms)
- [QEMU VirtIO GPU architecture and requirements](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html)
- [Mesa VirGL](https://docs.mesa3d.org/drivers/virgl.html)
- [Mesa Venus](https://docs.mesa3d.org/drivers/venus.html)
- [Mesa Zink](https://docs.mesa3d.org/drivers/zink.html)
- [UTM graphics architecture](https://github.com/utmapp/UTM/blob/main/Documentation/Graphics.md)
- [Parallels: VirGL for ARM Linux VMs](https://kb.parallels.com/en/128518)
- [VMware Fusion ARM Linux support matrix](https://knowledge.broadcom.com/external/article/315602)
- [Apple WWDC26: custom VirtIO devices](https://developer.apple.com/videos/play/wwdc2026/224/)
