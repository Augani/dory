# Dory Venus runtime

Dory ships a small, isolated Venus Vulkan ICD for accelerated ARM64 desktop guests. It lives at
`/opt/dory/mesa` and does not replace the distribution's Mesa OpenGL stack. The distribution keeps
rendering GNOME/Xfce through VirGL, while Vulkan applications such as Zed use this pinned ICD.

The macOS renderer cannot expose Linux `sync_fd` semaphore imports. Dory's virtio-gpu transport
already orders access to shared resources, so the patch in `patches/` enables Venus' existing
implicit-fencing path, exposes WSI when that path is active, and avoids requesting the absent host
extension. Acquired-image synchronization is still consumed by Venus' driver-side semaphore path;
the extension is not merely advertised.

`build.sh` produces `guest/out/dory-mesa-venus-arm64.tar.zst`. The archive contains only the Venus
ICD, its one non-baseline XCB dependency, a capability probe, and provenance. Desktop image and
in-place update builders consume the same archive, so a full image and an updated image cannot
silently diverge.
