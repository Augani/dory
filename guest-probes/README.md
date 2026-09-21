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

For a physical displayed-pixel run, launch the probe from the bounded keyboard script with a
campaign-owned ready marker written immediately before `exec`. Pass a `--guest-command` to
`scripts/arm-ubuntu-scenario-driver.sh` that waits for that marker. The driver then requests the
next Metal-completed app frame and captures the Dory window while the probe's `--hold-ms` interval
is active. Use `--probe-result-command` to read the probe's saved stdout, `--probe-nonce` to bind
it to the run, and `--graphics-trace` to name the isolated runner's
`graphics-trace.ndjson`. Probe mode fails closed unless all three are available.

The retained `gpu-display-evidence.json` binds the validated probe hash, window PNG hash,
capture-frame receipt, display resource generation, and the identical process-local Metal
completion ID recorded in the runner trace. It is a sub-result only; the outer ARM installer and
fault campaign remains fail-closed until its other authorities complete.

Replay verification is independent of the scenario process:

```sh
./verify-displayed-pixel.py --nonce=campaign-001 /path/to/retained/run
```

The verifier revalidates the probe, every retained digest, the capture-frame identity, and the
unique matching `metalPresentationCompleted` event in the retained runner trace.

## OpenGL strategy comparison

Phase A5 compares Zink → Venus → MoltenVK with VirGL2 → ANGLE → Metal under
identical host, guest, resolution, CPU, memory, worker, and desktop conditions.
Retain `comparison.json`, `zink-venus.json`, and `virgl2-angle.json` in one
directory, then verify the pair and render the required comparison table:

```sh
python3 guest-probes/verify-opengl-strategy.py --evidence /absolute/evidence/root
python3 guest-probes/verify-opengl-strategy.py \
  --evidence /absolute/evidence/root --markdown
```

The verifier requires glmark2, GNOME Shell and KWin overview animations, GTK4,
Qt 6, Firefox WebGL Aquarium, Blender viewport, LibreOffice Impress, and Zed
measurements. Each run records explicit API prerequisites, p95 frame interval,
first-shader stall, worker CPU, and worker RSS. A selected default must pass
every workload without llvmpipe, lavapipe, or another software renderer.
Passing Zink evidence must include robustness2, dynamic rendering, extended
dynamic state, and timeline-semaphore support.
The second passing path may be retained only for a named compatibility need;
failures remain valid measurements but cannot be selected or retained.
