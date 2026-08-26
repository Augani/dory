# Dory Venus runtime

Dory ships a small, isolated Venus Vulkan ICD for accelerated ARM64 desktop guests. It lives at
`/opt/dory/mesa` and does not replace the distribution's Mesa OpenGL stack. The distribution keeps
rendering GNOME or Xfce through VirGL, while native Vulkan applications such as Zed may select this
pinned ICD after the complete renderer tuple passes admission.

The guest uses unmodified Venus WSI synchronization. Swapchain acquire imports the standard
`VK_KHR_external_semaphore_fd` `SYNC_FD` value `-1`, which represents an already-signaled temporary
payload. The bounded pack probe verifies that exact import, submits a real semaphore wait and
queue-signaled release through core Vulkan 1.3 `vkQueueSubmit2`, exports the release payload with
`vkGetSemaphoreFdKHR`, and waits for the resulting fence. Dory does not submit hidden work on an
application queue and does not enable Mesa's retired `venus_implicit_fencing` path. The host
MoltenVK bridge, renderer, kernel/device ABI, and guest pack are still one qualified tuple; passing
the guest probe alone is not an acceleration claim.

`build.sh` produces `guest/out/dory-mesa-venus-arm64.tar.zst`. It builds against the pinned Debian
Bullseye GNU-libc 2.31 baseline rather than inheriting the newest managed desktop ABI. Mesa,
Meson, libdrm, Wayland protocols, and the required Wayland scanner are exact hash-pinned inputs.
Meson runs with network downloads disabled after those inputs have been fetched and verified. The
probe compiles against the Vulkan headers in that same pinned Mesa tree, while dynamically resolving
newer extension entry points through Bullseye's public Vulkan loader ABI. Unused libdrm hardware
backends and test programs are disabled; only the core interface consumed by Venus is built.

Libdrm is linked statically into the ICD and its symbols are hidden. No renamed or private libdrm
DSO is shipped, so an application's distro libdrm cannot interpose on the ICD's DRM calls. X11,
XCB, Wayland, compression, the Vulkan loader, libc, and the ELF interpreter remain explicit guest
interfaces. The schema-6 manifest records the exact dynamic dependency sets, maximum GNU-libc
symbol; build-time and in-guest checks reject RPATH/RUNPATH, unresolved symbols, `GLIBC_PRIVATE`,
dynamic libdrm, exported DRM symbols, symlinks, writable paths, or undeclared files.

The application probe has two modes. Boot preflight proves a real non-CPU Venus Vulkan 1.3 device, robust buffer
access, dynamic rendering, synchronization2, maintenance4, the exact WSI/device extensions, the
Zed atlas texture usages, and the SYNC_FD import/submit/export/fence round trip. `--wsi=xcb` or
`--wsi=wayland` additionally creates a native surface and 64x64 FIFO swapchain, acquires and clears
one image through Vulkan 1.3 dynamic rendering, queues it for presentation, and waits for the
presentation queue to become idle. The exact-candidate desktop gate runs that active-session mode
before launching Zed. See
[`vulkan-13-application-readiness.md`](../../docs/architecture-gates/vulkan-13-application-readiness.md)
for the audited application and component boundary.

The separate compositor probe enforces the truthful v2 output contract: the device-local optimal
image must support color attachment, blending, and transfer source; the imported LINEAR
virtio-gpu scanout needs transfer destination only. It renders into the optimal image, copies into
the real scanout DMA-BUF, synchronizes ownership, and validates the mapped scanout bytes. This is
the mechanism probe for the compositor architecture; it does not make an unmodified compositor or
an unmeasured VM release-qualified.

The archive is a single replaceable `/opt/dory/mesa` tree containing only the relocatable ICD, its
manifest, the Vulkan synchronization probe, ABI facts, and package provenance. Full image builds
and in-place updates use the same transactional tree installer, preventing old DSOs from surviving
an upgrade. No process-wide `LD_LIBRARY_PATH` is required.

A musl guest requires a separately built and qualified catalog pack; it is never treated as
compatible with this GNU-libc artifact. Likewise, a successful structural build does not establish
Zed acceleration or release readiness. Those require the signed host tuple and exact-candidate
physical gate on every supported distro cell.
