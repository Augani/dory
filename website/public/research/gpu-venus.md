# GPU Compute In Guest: Virtio-GPU Venus Research

Date: 2026-07-05

## Summary

Verdict: do not commit to a production GPU compute feature yet. The stack is real and worth a spike, but Dory should treat it as an experimental `dory-hv --gpu=venus` path with a llama.cpp Vulkan benchmark as the first acceptance gate.

The strongest route is:

1. Guest Mesa Venus driver serializes Vulkan calls over virtio-gpu.
2. DoryHV implements virtio-gpu with blob resources, host-visible memory, context init, fences, and a host memory window.
3. Host side uses virglrenderer with Venus enabled.
4. virglrenderer calls host Vulkan, provided on macOS through MoltenVK over Metal.

That matches the current macOS container direction from libkrun/krunkit, Podman, Lima, and Colima, but Dory cannot inherit it directly because Dory owns its VMM and device model.

## Evidence

Mesa documents Venus as the virtio-gpu protocol for Vulkan command serialization and lists the required virtio-gpu kernel parameters: 3D features, capset query fix, resource blobs, host visible memory, and context init. Mesa also says this normally means a guest kernel at least 5.16 or backports plus a compatible hypervisor. Source: https://docs.mesa3d.org/drivers/venus.html

QEMU documents virtio-gpu as the paravirtual GPU and display controller, requiring `CONFIG_DRM_VIRTIO_GPU` in the guest kernel. Its Venus path requires `hostmem`, `blob`, and `venus` on the virtio-gpu device, with the host memory window typically between 256 MiB and 8 GiB. Source: https://qemu.readthedocs.io/en/v9.2.4/system/devices/virtio-gpu.html

virglrenderer exposes a `VIRGL_RENDERER_VENUS` feature flag in its public header, and also has render-server support that is respected by the Venus renderer. Source: https://android.googlesource.com/platform/external/virglrenderer/+/upstream-master/src/virglrenderer.h

Khronos describes Vulkan Portability as the standardized path for layered Vulkan implementations over Metal and names MoltenVK as a leading implementation on Apple platforms. Source: https://www.vulkan.org/porting

MoltenVK describes itself as a Vulkan 1.4 graphics and compute implementation layered over Apple's Metal framework, with SPIR-V translated to Metal Shading Language. Source: https://github.com/KhronosGroup/MoltenVK

Red Hat's June 2025 write-up for macOS Podman containers describes the same functional stack: Mesa Venus in the guest, virglrenderer on the host, and MoltenVK translating Vulkan to Apple Metal. Their llama.cpp/RamaLama test reports a 40x improvement over the prior macOS container GPU computing baseline, but also notes ongoing upstream work around virtio-gpu shared memory page negotiation. Source: https://developers.redhat.com/articles/2025/06/05/how-we-improved-ai-inference-macos-podman-containers

Colima now documents GPU-powered AI workloads on Apple Silicon through the krunkit VM type. That corrects the earlier roadmap comparison: Colima does have a GPU path, but it is krunkit/libkrun Venus forwarding, not raw Apple GPU device passthrough. Source: https://colima.run/docs/ai/

Lima documents krunkit as experimental, Apple Silicon/macOS focused, and backed by Mesa Venus Vulkan in the guest. Its container example passes `/dev/dri` into the container and validates with `vulkaninfo --summary`. Source: https://lima-vm.io/docs/config/vmtype/krunkit/

Apple's public Virtualization.framework has virtio graphics/display configuration APIs, but dory-hv uses Hypervisor.framework and owns the device model. There is no documented Hypervisor.framework API that passes a real Apple GPU into a Linux guest as a native Linux GPU device. Source: https://developer.apple.com/documentation/virtualization/vzvirtiographicsdeviceconfiguration

## Dory Requirements

Guest kernel:

- Add `CONFIG_DRM=y`, `CONFIG_DRM_VIRTIO_GPU=y`, `CONFIG_SYNC_FILE=y`, DMA-BUF support, and any DRM helpers required by Linux 6.12.
- Keep `CONFIG_VIRTIO_MMIO=y`; Dory does not use PCI in the hot path.
- Ship Mesa with Venus ICD in the guest image or inject it into GPU-enabled machine images.
- Keep the default kernel headless. Build the experimental GPU kernel with `DORY_EXPERIMENTAL_GPU=1 guest/kernel/build.sh arm64`, which adds `guest/kernel/dory-gpu.fragment`.

DoryHV device model:

- Implement virtio-gpu device ID 16 with control and cursor queues.
- Implement 2D resource commands enough for Linux driver initialization even if compute is the target.
- Implement resource blob creation, host-visible memory, context initialization, capset query, fences, and shared-memory or hostmem window plumbing.
- Decide whether the host renderer runs in-process or out-of-process. Out-of-process is preferred for crash isolation and matches virglrenderer render-server direction.
- Add a capability check so GPU support fails closed when MoltenVK or virglrenderer is unavailable.

Host dependencies:

- Bundle or locate a pinned virglrenderer build with Venus enabled.
- Bundle or locate MoltenVK from the Vulkan SDK or a pinned runtime artifact.
- Keep app size budget in view. If bundled dylibs push the zip over target, make GPU an external developer-preview install.

Validation:

- `vulkaninfo` inside the guest sees a non-lavapipe physical device through Venus.
- `vkcube` or `vkcube-wayland` runs under a machine profile.
- `llama.cpp` with `GGML_VULKAN=1` runs a small model and beats CPU-only by at least 5x on Apple silicon.
- Dory remains stable if the render server crashes.

## Risks

- MoltenVK is a portability implementation, not native Vulkan. Feature gaps matter for compute workloads, especially matrix-oriented AI kernels.
- Venus relies on host-visible memory behavior that Mesa documents as constrained and partly implementation-dependent. Dory's Hypervisor.framework memory model must be proven with blob resources before product work.
- Most upstream examples assume KVM, PCI, memfd, or QEMU glue. Dory uses Hypervisor.framework and virtio-mmio, so the hard part is the device/backend bridge, not the guest driver.
- Shipping GPU support safely likely means an extra process boundary. That is more packaging and lifecycle work.
- This does not help Metal-native workloads in the guest. It is Vulkan API forwarding for Linux workloads.

## Recommended Spike

1. Add a hidden `--gpu=venus` flag and guest kernel config symbols only.
2. Bring up a tiny virtio-gpu device until Linux binds `virtio_gpu`.
3. Add capset query and blob resource plumbing against a mocked renderer first.
4. Integrate virglrenderer in a helper process and pass commands over a local socket.
5. Run `vulkaninfo`, then a small llama.cpp Vulkan benchmark.

Go criteria:

- Guest `vulkaninfo` succeeds through Venus on macOS 15+ Apple silicon.
- llama.cpp Vulkan is at least 5x faster than CPU-only in the Dory guest.
- Renderer crashes do not crash the VM or app.
- Added compressed artifacts keep the app zip under the roadmap budget.

No-go fallback:

- Keep GPU compute as documented research.
- Prefer host-side model runners integrated with Dory's reverse proxy and machine filesystem sharing.
- Revisit when virglrenderer, MoltenVK, and Linux virtio-gpu shared-memory negotiation are cleaner upstream.

## Current Dory Spike State

- Hidden engine flag: `dory-hv engine --gpu venus`.
- App launch opt-in: `DORY_EXPERIMENTAL_GPU=venus`.
- Kernel opt-in: `DORY_EXPERIMENTAL_GPU=1 guest/kernel/build.sh arm64`.
- Implemented engine-side Venus gate: `VirtioGPU` keeps bootstrap mode inert by default, but Venus
  mode now requires a host renderer object, advertises resource blobs/context init, exposes the
  UAPI host-visible shared-memory region, and forwards blob/context/submit commands through a
  dynamic virglrenderer adapter.
- The runtime probe fails closed unless `libvirglrenderer.dylib`, `MoltenVK_icd.json`, and
  `virgl_renderer_resource_map_fixed` are available. That last symbol is needed so blob mappings
  land inside Dory's guest-visible window instead of becoming a crash-prone copy path.
- `scripts/bundle-engine.sh` now attempts to package the Venus host runtime into the app bundle:
  compatible `libvirglrenderer.dylib` plus its non-system dylib closure in
  `Contents/Frameworks`, and a rewritten `MoltenVK_icd.json` in
  `Contents/Resources/vulkan/icd.d`. Use `DORY_VIRGLRENDERER_PATH`, `DORY_MOLTENVK_ICD`, and
  `DORY_MOLTENVK_DYLIB` to point at pinned artifacts; set `DORY_BUNDLE_VENUS_REQUIRED=1` for a
  GPU-preview release that must fail if those artifacts are missing or too old.
- Docker `--gpus` on the shared VM remains rejected by default. With `DORY_EXPERIMENTAL_GPU=venus`,
  the shim translates it into `/dev/dri/renderD128`, `/dev/dri/card0`, and `c 226:* rwm` for the
  experimental virtio-gpu device.

## WORKING end to end (2026-07-06)

A Linux container in Dory's engine runs Vulkan on the Apple GPU. `vulkaninfo` inside the container
reports `deviceName = Virtio-GPU Venus (Apple M2 Pro)`, `driverID = DRIVER_ID_MESA_VENUS`, Mesa
25.0.7, with compute/graphics/transfer queues and memory heaps. Chain: guest Mesa Venus ->
virtio-gpu -> Dory `VirtioGPU` -> virglrenderer (slp/krunkit) -> MoltenVK -> Metal.

Supersedes the `resource_map_fixed` note above. The four things that were needed:

1. On `RESOURCE_MAP_BLOB`, call `virgl_renderer_resource_get_map_ptr(res, &hostVA)` (NOT
   `virgl_renderer_resource_map`, which returns `-22`/EINVAL for the MoltenVK-backed Apple blob),
   then `hv_vm_map` that host VA into the guest host-visible window at the requested offset. This is
   the libkrun/krunkit macOS model. The window is mapped per blob on demand, never pre-mapped.
2. Init flags = `VIRGL_RENDERER_VENUS | VIRGL_RENDERER_NO_VIRGL` only.
3. Gate the Venus capset on `max_size > 0` (Venus reports `max_version == 0`).
4. Build the GPU guest kernel with `CONFIG_ARM64_16K_PAGES=y` so blob offsets/sizes match the
   Apple Silicon 16 KiB hv granule (added to `guest/kernel/dory-gpu.fragment`).

Host runtime deps: `brew install slp/krunkit/virglrenderer molten-vk libepoxy`. Guest: any image
with Mesa Venus, e.g. `debian:trixie-slim` + `mesa-vulkan-drivers vulkan-tools` (ships
`libvulkan_virtio.so` + `virtio_icd.json` for arm64). Run with `--device /dev/dri/renderD128
--device /dev/dri/card0 -e VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/virtio_icd.json`. Do NOT set
`VKR_DEBUG=validate` (forces a validation layer MoltenVK lacks -> vkCreateInstance fails).
