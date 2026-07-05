# GPU Compute In Guest: Virtio-GPU Venus Research

Date: 2026-07-04

## Summary

Verdict: do not commit to a production GPU compute feature yet. The stack is real and worth a spike, but Dory should treat it as an experimental `dory-hv --gpu=venus` path with a llama.cpp Vulkan benchmark as the first acceptance gate.

The strongest route is:

1. Guest Mesa Venus driver serializes Vulkan calls over virtio-gpu.
2. DoryHV implements virtio-gpu with blob resources, host-visible memory, context init, fences, and a host memory window.
3. Host side uses virglrenderer with Venus enabled.
4. virglrenderer calls host Vulkan, provided on macOS through MoltenVK over Metal.

That matches the known macOS container direction from libkrun and Podman, but Dory cannot inherit it directly because Dory owns its VMM and device model.

## Evidence

Mesa documents Venus as the virtio-gpu protocol for Vulkan command serialization and lists the required virtio-gpu kernel parameters: 3D features, capset query fix, resource blobs, host visible memory, and context init. Mesa also says this normally means a guest kernel at least 5.16 or backports plus a compatible hypervisor. Source: https://docs.mesa3d.org/drivers/venus.html

QEMU documents virtio-gpu as the paravirtual GPU and display controller, requiring `CONFIG_DRM_VIRTIO_GPU` in the guest kernel. Its Venus path requires `hostmem`, `blob`, and `venus` on the virtio-gpu device, with the host memory window typically between 256 MiB and 8 GiB. Source: https://qemu.readthedocs.io/en/v9.2.4/system/devices/virtio-gpu.html

virglrenderer exposes a `VIRGL_RENDERER_VENUS` feature flag in its public header, and also has render-server support that is respected by the Venus renderer. Source: https://android.googlesource.com/platform/external/virglrenderer/+/upstream-master/src/virglrenderer.h

Khronos describes Vulkan Portability as the standardized path for layered Vulkan implementations over Metal and names MoltenVK as a leading implementation on Apple platforms. Source: https://www.vulkan.org/porting

MoltenVK describes itself as a Vulkan 1.4 graphics and compute implementation layered over Apple's Metal framework, with SPIR-V translated to Metal Shading Language. Source: https://github.com/KhronosGroup/MoltenVK

Red Hat's June 2025 write-up for macOS Podman containers describes the same functional stack: Mesa Venus in the guest, virglrenderer on the host, and MoltenVK translating Vulkan to Apple Metal. Their llama.cpp/RamaLama test reports a 40x improvement over the prior macOS container GPU computing baseline, but also notes ongoing upstream work around virtio-gpu shared memory page negotiation. Source: https://developers.redhat.com/articles/2025/06/05/how-we-improved-ai-inference-macos-podman-containers

## Dory Requirements

Guest kernel:

- Add `CONFIG_DRM=y`, `CONFIG_DRM_VIRTIO_GPU=y`, `CONFIG_SYNC_FILE=y`, DMA-BUF support, and any DRM helpers required by Linux 6.12.
- Keep `CONFIG_VIRTIO_MMIO=y`; Dory does not use PCI in the hot path.
- Ship Mesa with Venus ICD in the guest image or inject it into GPU-enabled machine images.

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
