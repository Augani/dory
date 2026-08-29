# Vulkan 1.3 application-readiness gate

Status: implemented as a fail-closed guest and physical-candidate contract. A physical managed
Ubuntu VM has passed the boot mechanism stage and a real native-Wayland acquire, Vulkan 1.3 render,
queue-present, and present-idle transaction on a hardware Venus device. Exact Zed 1.16.1 selected
that Vulkan Venus adapter, rejected software emulation, and logged its first rendered frame. The
ten-second editor-liveness gate, host worker-backed Metal frame, compositor acceleration, and
performance budgets remain open. This document therefore records no complete GPU-acceleration or
performance result.

## Why the previous contract was invalid

The old renderer tuple declared Vulkan 1.2 and the guest probe requested 1.2. That was below the
current supported Linux floor for the workload that exposed the problem: Zed's installation
requirements say that Linux needs a Vulkan 1.3 driver. A JSON or ICD version string cannot close
that gap. The exact Zed `v1.16.1` source (`eb8e1c8b5502b7007465fbbc465f4a736fa39210`) pins wgpu
29.0.4; its GPU setup obtains real surface capabilities, creates a device, and configures a 64x64
FIFO test surface. It separately requires a BGRA8 or RGBA8 atlas format with texture-binding and
copy-destination usage.

Primary evidence:

- [Zed Linux requires a Vulkan 1.3 driver](https://zed.dev/docs/installation#linux).
- [Exact Zed surface/device and atlas checks](https://github.com/zed-industries/zed/blob/eb8e1c8b5502b7007465fbbc465f4a736fa39210/crates/gpui_wgpu/src/wgpu_context.rs).
- [Exact Zed lockfile pin to wgpu 29.0.4](https://github.com/zed-industries/zed/blob/eb8e1c8b5502b7007465fbbc465f4a736fa39210/Cargo.lock).
- [Exact Zed CLI foreground lifecycle](https://github.com/zed-industries/zed/blob/eb8e1c8b5502b7007465fbbc465f4a736fa39210/crates/cli/src/main.rs).
- [Exact wgpu 29.0.4 Vulkan capability discovery](https://github.com/gfx-rs/wgpu/blob/e99f5305ded96ff7006f0714d043a7f735bd45c2/wgpu-hal/src/vulkan/adapter.rs).
- [Khronos `vkGetSemaphoreFdKHR` export contract](https://registry.khronos.org/vulkan/specs/latest/man/html/vkGetSemaphoreFdKHR.html)
  and [SYNC_FD `-1` import/export semantics](https://registry.khronos.org/vulkan/specs/latest/man/html/VkImportSemaphoreFdInfoKHR.html).

wgpu can assemble functionality from a core version and promoted extensions. Consequently, API
version alone is insufficient evidence, and the gate deliberately verifies the mechanisms the
application and this transport depend on.

## Exact tuple audit

The pinned components do not have a source-level Vulkan 1.3 ceiling:

- Mesa Venus commit `79bc850d884a1307356ff61c017e58901b90c7e2`, tree
  `585b6604e6ef58585cfc44f7b4d5eab172ddfbbd`, has a Vulkan 1.4 maximum. Its physical-device
  sanitizer clamps the advertised API to 1.2 when `VK_KHR_synchronization2` is disabled, and its
  WSI path enables synchronization2 only when semaphore `SYNC_FD` import is available. This is the
  decisive runtime boundary, so the guest must report an actual 1.3 device and pass a real SYNC_FD
  submit; source support cannot substitute for that evidence. See the exact
  [version clamp and WSI capability logic](https://gitlab.freedesktop.org/osy/mesa/-/blob/79bc850d884a1307356ff61c017e58901b90c7e2/src/virtio/vulkan/vn_physical_device.c).
- virglrenderer commit `65cc14eb896f121ffc5130ce04815a923a03c41d`, tree
  `94dc34ffde98cf70f0c11fe921bec10a09d3907f`, carries the Venus Vulkan 1.3 dynamic-rendering,
  synchronization2, maintenance4, queue-submit2, and external-semaphore-FD dispatch paths. See the
  exact [Venus extension table](https://github.com/utmapp/virglrenderer/blob/65cc14eb896f121ffc5130ce04815a923a03c41d/src/venus/vkr_common.c).
- MoltenVK commit `ef1c5461774f5fbd224ddcfd91fd2c0ea23f0384`, tree
  `14f470cffb6b74c5e72647925a0c7f83ba64abb8`, is a Vulkan 1.4 source implementation and reports
  dynamic rendering, synchronization2, and maintenance4 in its Vulkan 1.3 feature structure. See
  the exact [feature implementation](https://github.com/utmapp/MoltenVK/blob/ef1c5461774f5fbd224ddcfd91fd2c0ea23f0384/MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm).

An exact clean MoltenVK artifact with SHA-256
`35934ac3175215dfa7680c0c2c8958f0d66c1cffe6ff509b9a3cb22c90ce1905` was probed directly on an
Apple M2 Pro. An instance requesting Vulkan 1.3 succeeded; the device reported Vulkan 1.3.334 and
enabled robust buffer access, dynamic rendering, synchronization2, and maintenance4. This is a
host mechanism observation only. It is not a Venus guest result, a rendered frame, or a speed
measurement.

## Contract

The checked `guestMesaBuildPolicy.applicationReadiness` object binds the exact Zed and wgpu source
identities above. Runtime manifest schema 6 binds the following generic Vulkan contract:

- Vulkan loader and non-CPU `driverName=venus` physical device API at least 1.3;
- robust buffer access plus Vulkan 1.3 `dynamicRendering`, `synchronization2`, and `maintenance4`;
- `VK_KHR_swapchain` and `VK_KHR_external_semaphore_fd` device extensions;
- `VK_KHR_surface`, `VK_KHR_xcb_surface`, and `VK_KHR_wayland_surface` instance extensions;
- importable and exportable `SYNC_FD`, a real temporary `fd=-1` import, a queue-signaled release
  export through `vkGetSemaphoreFdKHR` (where the specification permits either a real descriptor
  or `-1` for an already-signaled payload), core `vkQueueSubmit2`, and a bounded fence completion;
- BGRA8 or RGBA8 UNORM optimal-tiling support for sampled-image and transfer-destination atlas use;
- XCB and Wayland native-surface gates.

The gate is split because the system boot preflight runs before a desktop display exists:

| Stage | Required evidence |
|---|---|
| Boot admission | Loader/device API, Venus hardware identity, core features, device and instance extensions, atlas usages, SYNC_FD import/export, device creation, queue-submit2, and fence completion |
| Active desktop | A real XCB or Wayland native surface, a graphics-and-present queue, non-empty capabilities/formats/present modes, the first compatible application surface format, FIFO presentation, successful 64x64 swapchain/image creation, image acquisition, Vulkan 1.3 dynamic-rendering clear, queue presentation, and an idle presentation queue |
| Exact workload | Exact Zed archive/version, Venus ICD in the process maps, the cell's qualified native WSI in the process environment, a process that remains alive, and no software/emulated/device-lost fallback signature |

The physical desktop gate runs the active-surface stage before it starts Zed. A failure at any
stage keeps the candidate unavailable. Ubuntu is explicitly a native-Wayland cell. The current
Debian and Kali XFCE cells remain explicit XCB cells and remain unavailable while their Xorg DRI3
path is unqualified; success on Ubuntu does not project onto them.

## Physical observations on 2026-08-24

The exact managed Ubuntu diagnostic cell produced five distinct results that must not be merged:

1. Boot preflight passed Vulkan 1.3 on `Virtio-GPU Venus (Apple M2 Pro)`, including the required
   feature, atlas-format, SYNC_FD, submit, and fence mechanisms.
2. An Xorg active-surface probe failed with `No DRI3 support detected - required for
   presentation`. The recovered Xorg log shows the modesetting driver selecting `/dev/dri/card0`,
   then refusing glamor on llvmpipe and loading software GLX. This follows the exact Xserver
   21.1.11 behavior: glamor rejects llvmpipe unless the screen is a PRIME GPU, and glamor is the
   code path that installs the screen DRI3 callbacks. Mesa's non-software X11 WSI correspondingly
   refuses presentation without DRI3. See the exact
   [Xserver glamor decision](https://gitlab.freedesktop.org/xorg/xserver/-/blob/xorg-server-21.1.11/glamor/glamor_egl.c)
   and [pinned Mesa X11 WSI check](https://gitlab.freedesktop.org/osy/mesa/-/blob/79bc850d884a1307356ff61c017e58901b90c7e2/src/vulkan/wsi/wsi_common_x11.c).
3. The same immutable kernel and graphics pack, with only a disposable GDM policy derivative,
   entered a real `wayland` user session and passed native Wayland surface creation, a
   graphics/present queue, FIFO mode, and a five-image 64x64 swapchain on the hardware Venus
   device. That run predated the acquire/render/present strengthening in this gate, so it does not
   prove a submitted presentation. No exact Zed archive was available in the cell.
4. A later disposable derivative carried the strengthened probe and the same exact Venus library.
   On a native Wayland session it acquired one of the five swapchain images, cleared it with Vulkan
   1.3 dynamic rendering, completed a synchronization2 submission, queued the image for
   presentation, and reached an idle presentation queue. The exact receipt included
   `swapchain-acquire=yes`, `swapchain-render=yes`, `queue-present=yes`, and `present-idle=yes`.
   This is an application presentation request; it is not evidence that GNOME's final scanout was
   worker-backed or that the host completed a Metal frame.
5. The pinned Zed 1.16.1 ARM64 archive (SHA-256
   `384499c75d75c6aab53110dbc1d8856f6f774baaa32dc57b9963f9e29f8d007b`) started on that Wayland
   cell. Its own log selected `Virtio-GPU Venus (Apple M2 Pro)` through Vulkan, reported
   `is_software_emulated: false`, driver `venus`, and `Rendered first frame`. The diagnostic editor
   process then exited before the required ten-second liveness sample, including when launched
   through the exact CLI's documented `--foreground` path. The exact-workload gate therefore
   remains failed closed; the first-frame log is not a durable application or release result.

The GNOME compositor in the successful Wayland experiment still mapped `kms_swrast_dri.so`.
Native Venus applications and whole-desktop composition are separate acceleration boundaries.
Forcing Zink is not a valid bridge on the current tuple: a physical probe reached the Venus device
but reported missing base Zink requirements (`logicOp` and `VK_EXT_custom_border_color`) before it
also encountered the Xorg DRI3 failure. Dory therefore defaults the managed Ubuntu session to
Wayland but keeps compositor acceleration, the host Metal consumer, durable exact-Zed operation,
and whole-VM speed unqualified. Mesa's supported architecture for OpenGL-over-Vulkan is documented in
[Zink](https://docs.mesa3d.org/drivers/zink.html); the guest Vulkan transport is documented in
[Venus](https://docs.mesa3d.org/drivers/venus.html).

## Physical compositor-profile result on 2026-08-24

The first compositor profile required a Vulkan renderer to blend directly into the one-plane
LINEAR DMA-BUF used for KMS scanout. It failed correctly on both Dory final formats. The physical
guest reported modifier features `0x00001081` for XRGB8888/BGRA8 and XBGR8888/RGBA8, which includes
color attachment but not color-attachment blend. Exact wlroots requires both flags, so it rejected
both formats before creating an invalid framebuffer.

Source audit found that the observed feature set is hard-coded by exact virglrenderer
`65cc14eb896f121ffc5130ce04815a923a03c41d`; it does not come from MoltenVK. That bridge also strips
color-attachment and input-attachment usage before querying the host. A new host qualification
against the exact statically linked MoltenVK archive then established the real boundary:

- both LINEAR formats report `0x8000d403` and reject a color-attachment image query with
  `VK_ERROR_FORMAT_NOT_SUPPORTED`;
- both optimal formats report `0x8000dd83`, including color attachment, blend, and transfer source;
- both LINEAR formats support transfer destination and accept a transfer-destination image query;
- a real blend-enabled pipeline rendered red at 25% alpha over green in an optimal image,
  `vkCmdCopyImage` copied it to a LINEAR image, and mapped readback matched BGRA bytes
  `0,191,64,64` and RGBA bytes `64,191,0,64` exactly.

This rejects two tempting shortcuts: adding a blend flag to virglrenderer would advertise a host
operation that fails, and replacing wlroots with Weston would still require blend-capable output
attachments. The next guest profile is `native-vulkan-optimal-copy-compositor-v2`: render into an
optimal device-local image, copy on-GPU into a transfer-destination LINEAR DMA-BUF, then scan out
only after its producer fence. Exact primary-source boundaries are the
[virglrenderer emulation](https://github.com/utmapp/virglrenderer/blob/65cc14eb896f121ffc5130ce04815a923a03c41d/src/venus/vkr_physical_device.c),
[MoltenVK format properties](https://github.com/utmapp/MoltenVK/blob/ef1c5461774f5fbd224ddcfd91fd2c0ea23f0384/MoltenVK/MoltenVK/GPUObjects/MVKPixelFormats.mm),
[wlroots Vulkan requirement](https://gitlab.freedesktop.org/wlroots/wlroots/-/blob/329a88e72424486180ff3339440fa9f8f711af02/render/vulkan/pixel_format.c), and
[Weston Vulkan blending implementation](https://gitlab.freedesktop.org/wayland/weston/-/blob/d1882b0a544ae2197b597a6e39478e719bc54302/libweston/renderer-vulkan/vulkan-pipeline.c).

The successful host copy probe is mechanism evidence only. It does not qualify the Venus guest
modifier advertisement, imported virtio-gpu DMA-BUF, compositor integration, producer fence,
worker-backed Metal frame, Zed liveness, or performance.

## Verification boundary

Structural verification currently consists of strict-warning probe compiles, schema/manifest and
ELF-closure verification, tuple tests, and two builds from separate source roots whose schema-6
runtime archives and stamps are byte-identical. This closes deterministic reproduction for the
exact pinned guest inputs, not the physical graphics gate.
Release qualification additionally requires the signed exact host/guest tuple to pass the booted
VM gate on every admitted distro/media cell. It must then pass frame integrity, device-loss/reset,
sleep/wake, sustained workload, CPU, latency, and whole-VM performance budgets. None of those
physical results may be inferred from this contract.
