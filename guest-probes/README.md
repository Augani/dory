# Dory stock-guest GPU probes

These probes are deliberately built and run inside each stock Linux guest used by the displayed-pixel campaign. Do not cross-compile them on macOS and do not build them in Docker: the distro compiler, loader, Vulkan ICD, window system, and Mesa packages are part of the evidence.

Install the distro-native development packages first. Typical package names are:

- Ubuntu/Debian: `build-essential glslc libvulkan-dev libwayland-dev libxcb1-dev libdrm-dev libglew-dev libsdl2-dev`
- Fedora: `gcc glslc vulkan-loader-devel wayland-devel libxcb-devel libdrm-devel glew-devel SDL2-devel`

Then build in the guest:

```sh
./build-in-guest.sh
```

The script refuses non-Linux hosts and writes binaries plus a guest-toolchain receipt under `out/$(uname -m)/`.

The campaign consists of four probes:

- `dory-vulkan-probe`: Vulkan 1.3 application and optional XCB/Wayland presentation contract.
- `dory-vulkan-compositor-probe`: Venus DMA-BUF, sync-file, and KMS scanout contract.
- `dory-compute-probe`: deterministic three-pass Vulkan reduction of 1,048,576 values. It compares the GPU result with a CPU oracle and rejects CPU devices, llvmpipe, and lavapipe.
- `dory-gl-probe`: an SDL/OpenGL window containing a rotating alpha-blended textured quad plus a visible frame number and nonce. It rejects software renderers and hashes the final readback.

Examples:

```sh
cd out/$(uname -m)
./dory-compute-probe --nonce=campaign-001 --shader=./dory-compute-reduce.spv
./dory-gl-probe --nonce=campaign-001 --frames=180 --hold-ms=5000
./dory-vulkan-probe --wsi=auto --nonce=campaign-001
sudo ./dory-vulkan-compositor-probe --drm=/dev/dri/card0 --nonce=campaign-001
```

Every successful probe emits one JSON object on stdout using schema `dev.dory.gpu-probe` version 1. Each record includes the device, driver, API version, extensions used, checked result hash, frame count, nonce, and timings. Diagnostic progress and failures go to stderr.

Validate each retained result before correlating it with host-side evidence:

```sh
./validate-result.py --nonce=campaign-001 result.json
```

The validator rejects malformed records, nonce mismatches, non-finite timings, and llvmpipe/lavapipe/software-rasterizer identities.
