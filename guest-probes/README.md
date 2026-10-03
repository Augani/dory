# Dory stock-guest GPU probes

These probes are deliberately built and run inside each stock Linux guest used by the displayed-pixel campaign. Do not cross-compile them on macOS and do not build them in Docker: the distro compiler, loader, Vulkan ICD, window system, and Mesa packages are part of the evidence.

Install the distro-native development packages first. Typical package names are:

- Ubuntu/Debian: `build-essential glslc libvulkan-dev libwayland-dev libxcb1-dev libdrm-dev libglew-dev libsdl2-dev`
- Fedora: `gcc glslc vulkan-loader-devel wayland-devel libxcb-devel libdrm-devel glew-devel SDL2-devel`

Then build in the guest:

```sh
./build-in-guest.sh
```

The script refuses non-Linux hosts and writes binaries plus a version-2 guest-toolchain receipt under `out/$(uname -m)/`. The receipt records every probe source, the visual-challenge header, compute shader source, built probe binaries, and SPIR-V SHA-256 hashes. Retain it with the campaign; it does not substitute for retaining the actual candidate or guest runtime identity.

The campaign consists of four probes:

- `dory-vulkan-probe`: Vulkan 1.3 application and optional XCB/Wayland presentation contract. It retains nonce-bound offscreen readback and, for WSI runs, a bounded readback of the exact swapchain image submitted for presentation. The host independently replays both pixel oracles.
- `dory-vulkan-compositor-probe`: Venus DMA-BUF, sync-file, and KMS scanout contract. It retains Vulkan-staging readback of the background and 120 nonce-bound challenge-cell samples for independent host replay.
- `dory-compute-probe`: deterministic three-pass Vulkan reduction of 1,048,576 values. It compares the GPU result with a CPU oracle and rejects CPU devices, llvmpipe, and lavapipe.
- `dory-gl-probe`: an SDL/OpenGL window containing a rotating alpha-blended textured quad plus a visible frame number and nonce. It rejects software renderers, hashes the final readback, and reports 120 actual RGB8 challenge-cell samples for an independent host color oracle.

The compute probe prefers coherent host-visible memory, but also runs on
noncoherent host-visible types using explicit mapped-range flush/invalidate and
host/shader memory barriers. Its result records the selected input/output memory
coherency; a missing coherent type alone is not a GPU failure.
Use `--memory=noncoherent` for a separate qualification run when the selected
device offers that type; the option fails rather than silently selecting a
coherent allocation when noncoherent memory is unavailable.
The Vulkan compositor readback has the analogous
`--readback-memory=noncoherent` selection and records
`readbackMemoryCoherency` in its result.

Examples:

```sh
cd out/$(uname -m)
./dory-compute-probe --nonce=campaign-001 --shader=./dory-compute-reduce.spv
./dory-gl-probe --nonce=campaign-001 --frames=180 --hold-ms=5000
./dory-vulkan-probe --wsi=auto --nonce=campaign-001
sudo ./dory-vulkan-compositor-probe --drm=/dev/dri/card0 --nonce=campaign-001
```

The Vulkan application uses a 960×600 default only for on-screen WSI runs; its
offscreen default remains 64×64. An explicit WSI extent must fit the challenge
grid, or the probe fails before claiming a displayed frame. All three presenting
probes accept `--ready-file=/absolute/run-owned/path` and `--hold-ms=0..30000`.
The ready file is published atomically and exclusively after presentation, with a marker containing the
nonce-derived challenge hash and frame number. The campaign and replay verifiers require
that exact marker to match the guest result, so a stale ready file cannot establish the
current frame. Keep the hold long
enough for the host capture; the default is two seconds. The retained PNG
oracle uses the probe extent plus the captured guest viewport to check marker
scale and placement. The viewport receipt retains the source crop origin and
dimensions, which the replay verifier bounds by the accelerated trace surface.
It also checks the GL window's alpha-textured checker
colors, or the Vulkan application's/compositor's expected interior clear color.
The scenario driver passes the validated probe record to that oracle, and the
replay verifier independently repeats the same checks from retained bytes.

Every successful probe emits one JSON object on stdout using schema `dev.dory.gpu-probe` version 1. Each record includes the device, driver, API version, extensions used, result hash, frame count, nonce, and timings. The compute hash and GL challenge-cell readback have independent host oracles. The verifier now replays Vulkan application/compositor metadata hashes from the declared nonce, device, driver, format and extent; those hashes are **not** GPU-output digests and still require the separate displayed-pixel oracle. Diagnostic progress and failures go to stderr.

Validate each retained result before correlating it with host-side evidence:

```sh
./validate-result.py --nonce=campaign-001 result.json
```

The validator rejects malformed records, nonce mismatches, non-finite timings, and llvmpipe/lavapipe/software-rasterizer identities.

For a physical displayed-pixel run, launch the probe from the bounded keyboard
script with a unique `--ready-file` and a capture-sized hold of at least 5000 ms. Pass a
`--guest-command` to `scripts/arm-ubuntu-scenario-driver.sh` that waits for the
presented marker's exact content, not merely for probe process startup. Supply
the same path as `--probe-ready-file` to the scenario driver; it independently
reads the marker through guest exec before requesting capture, retains that
transport receipt, and binds the path and hold duration from the probe result.
Supply
`--probe-build-receipt-command` alongside `--probe-result-command`; the driver retrieves the
guest build receipt and checks its source hashes against this candidate's probe sources. The
driver then requests the
next broker-accepted Metal-completed app frame. The qualification app holds frame polling until
the driver captures the Dory window and atomically releases the request marker; this prevents a
newer frame overtaking the capture receipt. Keep the probe's `--hold-ms` interval active through
that handshake. Use `--probe-result-command` to read the probe's saved stdout, `--probe-nonce` to bind
it to the run, and `--graphics-trace` to name the isolated runner's
`graphics-trace.ndjson`. Probe mode fails closed unless the build receipt,
presented marker, result, nonce and trace are all available. For release qualification,
generate a fresh 128-bit lowercase hex nonce (for example,
`python3 -c 'import secrets; print(secrets.token_hex(16))'`) and pass the exact candidate inventory digest with
`--component-candidate-inventory-sha256`. The driver writes canonical
`campaign-challenge.json` with that candidate, the actual app operation and machine.
The campaign producer must retain it at
`evidence/graphics-acceleration/campaign-challenge.json` in the signed bundle inventory.
The accelerated release verifier requires this file and replays the displayed-pixel
proof against its nonce; the producer is responsible for issuing the nonce before the
guest run, not reconstructing it from a completed capture.

The retained v3 `gpu-display-evidence.json` binds the validated probe hash, window PNG hash,
capture-frame receipt, display resource generation, and the identical process-local Metal
completion ID recorded in the runner trace. The verifier also requires one ordered
`scanoutPublished → hostSubmissionAccepted → metalPresentationCompleted` chain for the
same machine, operation, worker generation, renderer resource, device generation, frame and
surface. `cpuCopy` cannot satisfy this accelerated proof even if a host Metal blit completed.
It is a sub-result only; the outer ARM installer and
fault campaign remains fail-closed until its other authorities complete.

Replay verification is independent of the scenario process:

```sh
./verify-displayed-pixel.py --nonce=campaign-001 /path/to/retained/run
```

The verifier revalidates the probe, build receipt, every retained digest, the capture-frame identity, and the
unique ordered accelerated frame chain in the retained runner trace.
For the fixed v1 compute probe, `validate-result.py` independently reproduces the nonce-seeded
million-value reduction and its hash; a well-formed arbitrary digest is not accepted.
For the GL probe it independently checks all 120 reported GPU-readback challenge-cell colors,
including the nonce/frame bits, against the same marker decoded from the product window PNG.

## ARM mapped-page fault witness

`mapped-page-retry.c` is a separate negative-test witness, not a GPU probe or a
public runtime switch. The campaign builds its exact source with the guest's
`/usr/bin/cc`. Add `--mapped-page-fault` to the isolated ARM daemon campaign only
when its signed cell explicitly permits `mapped-page-repeated-permission`.
Ordinary authorities do not grant memory fault injection.

The witness owns a challenge-patterned private scratch mapping, proves its
resident contiguous physical pages, and nominates one aligned 16 KiB host page.
The helper rejects any page whose complete contents differ from that pattern.
Only the real vCPU exception path counts retries; completion requires 16 retries,
the seventeenth exit, successful guest exception injection and restored memory
permissions. The independent guest witness must receive a fault at its nominated
address and then read the unchanged page. The runner also requires the original
boot/operation and a newly acquired Dory display frame, stops its bounded guest
unit, and retains exact command/results for replay.

Replay an existing run without mutating the guest:

```sh
python3 scripts/arm-ubuntu-mapped-page-fault.py --verify-only \
  --app /absolute/Dory.app --mach-service dev.dory.readiness.armubuntu.RUN-ID \
  --machine readiness-arm-ubuntu-RUN-ID --run-directory /absolute/run
```

Missing compiler, scratch ownership, fault authority, guest signal, permission
rollback or same-boot display recovery fails this phase. Passing it does not
qualify the separate full-flush/storage-failure or installer-navigation phases.

## ARM full-flush error and byte recovery

Add `--full-flush-fault` to the isolated daemon campaign when the signed cell
permits `block-full-flush-enospc`. The installed-disk lifecycle/snapshot journey
runs first. The storage witness then verifies `/dev/vda` is the root filesystem's
sole physical backing device and has a write-back cache. It opens that device
read-only and calls `fsync`; it never writes raw disk sectors. The host injects
one full-flush failure under the existing bounded signed authority. A passing
phase requires the helper's current used-ring IOERR receipt, guest EIO, a
successful subsequent flush on the same descriptor, fsynced exact payload bytes,
same-boot live display recovery, and offline/online cold boots preserving those
bytes. The signed authority must also admit the disconnected boot configuration.

The original `storage-recovery.json` snapshot observation remains unchanged and
does not claim an injected failure. `storage-recovery-qualification.json` joins
that independently replayed snapshot journey to `storage-full-flush-fault.json`;
both the live gate and sealed-bundle verifier replay the underlying commands.
These sub-results remain non-release-eligible.

```sh
python3 scripts/arm-ubuntu-full-flush-fault.py --verify-only \
  --app /absolute/Dory.app --mach-service dev.dory.readiness.armubuntu.RUN-ID \
  --machine readiness-arm-ubuntu-RUN-ID --run-directory /absolute/run
```

## ARM UEFI/GRUB installer navigation

Pass `--navigation-plan /absolute/plan.json` to the isolated ARM daemon campaign.
The plan has kind `dev.dory.arm-ubuntu-installer-navigation-plan`, schema 1,
the exact campaign `machineID`, and six ordered `stages`: `uefi-menu`,
`uefi-boot-manager`, `grub-menu`, `grub-edit`, `grub-challenge`, `installer`.
Every stage has `captureDelayMilliseconds` (0...300000). The first four also
have `steps`, using the same balanced evdev frames as the app's bounded keyboard
script. The firmware menu choices and delays must match the frozen firmware/ISO;
the `grub-edit` steps must position the cursor on the entry's `linux` line.
If firmware has already reached GRUB when the app attaches, the first stage may
use a balanced guest Ctrl-Alt-Delete followed by Escape to enter firmware setup;
it must still capture the actual UEFI menu, not label the GRUB screen as UEFI.
The last two stages cannot supply keys: the runner appends a fresh
`dory.navigation=<128-bit nonce>` at line end, then boots that edited entry
with Ctrl-X. This phase stops at Subiquity's language screen. The separate
`--input-script` continues the ordinary install/login/probe workflow.

For the outer gate, use `machineID: "readiness-arm-ubuntu-TEMPLATE"` in each
supplied navigation, installer and optional login plan. Before starting firmware,
the gate materializes an exclusive copy bound to its newly allocated machine ID
and retains both source/copy hashes. Only that explicit placeholder may be
rebound; a plan naming another live machine is rejected. Use throwaway campaign
credentials: retained keyboard plans are private qualification artifacts, not
redacted support bundles.

Each checkpoint uses the signed app's existing runner-applied keyboard authority
and held post-input Metal frame, then captures that exact Dory window. Local
ImageIO/Vision recognition is restricted to its guest viewport. Replay decodes
the original PNGs again, verifies the source-bound keys, monotonic command/frame
sequences, six distinct screens, and the fresh nonce in a cursor-contiguous
kernel serial command line. A userspace echo, copied screenshot, caller-supplied
OCR result, unbalanced key frame, wrong operation or missing installer screen
cannot pass. Recognition runs on the host CPU; it is not guest GPU evidence.

`installer-navigation.json` retains the raw checkpoint references.
`uefi-grub-input.json` joins that proof to the same scenario operation and its
later GPU framebuffer. The live gate and sealed-bundle verifier independently
replay both. Without this plan, or either signed-policy fault phase, the in-tree
scenario remains incomplete; passing all implemented phases still never grants
release admission or qualifies other guest/host cells.

```sh
python3 scripts/arm-ubuntu-installer-navigation.py --verify-only --require-qualification \
  --app /absolute/Dory.app --mach-service dev.dory.readiness.armubuntu.RUN-ID \
  --machine readiness-arm-ubuntu-RUN-ID --run-directory /absolute/run
```

## ARM controlled renderer restart and same-boot redraw

`scripts/arm-ubuntu-renderer-recovery.py` uses the signed Dory display broker's
existing restart command. The runner first requests `DEVICE_NEEDS_RESET`; it
does not replace the renderer underneath live guest queues. The existing guest
status-zero/reset-completion path admits the replacement. Command acceptance
is only an acknowledgement (`rendererRecoveryVerified: false`). Recovery needs
a newer worker generation, unchanged VM operation/plan/boot, and independent
GPU pixel/producer-fence/Metal-completion replay before and after replacement.

A bounded, source-hashed guest systemd witness retains 2 MiB of random memory
without persisting it, keeps the same PID/process-start ticks, and repeatedly
reads/writes/fsyncs a 512 KiB challenged regular file. It must make forward
progress after redraw and stop cleanly; the final bytes must still match. No
VM reboot, disk rewrite, production daemon endpoint, or host process killing
is used. This proves controlled restart with guest CPU/memory/I/O survival,
not unexpected worker death or survival of an existing GL/Vulkan context.
Those stress cases remain separate report requirements.

The runtime's unexpected-worker-loss path is distinct from this controlled campaign.
It immediately revokes live fence/shader/presentation observations and requests only
a GPU reset. After the guest resets, every display consumer must acknowledge resource
retirement before a fresh worker can be admitted; an uncertain in-flight unref cannot
strand an ID permanently. Timeout, incomplete transport reset, and later shutdown
reject replacement. Local failure-path tests cover these boundaries, not a physical
worker-kill campaign or survival of an existing guest GPU context.

Supply `--renderer-recovery-plan /absolute/redraw-plan.json` to the ARM live
gate/scenario driver. The plan has these exact fields:

```json
{
  "kind": "dev.dory.installed-desktop-renderer-recovery-redraw-plan",
  "schemaVersion": 1,
  "guestCommand": "<launch the in-tree held GPU probe in the active guest desktop session>",
  "expectedOutput": "<exact launch-command stdout, including its newline>",
  "probeResultCommand": "<read that probe's result after its bounded presentation hold>",
  "probeBuildReceiptCommand": "<read the matching build-in-guest.sh receipt>",
  "probeReadyFileTemplate": "/tmp/dory-renderer-{nonce}.ready",
  "graphicsTrace": "DORY-CAMPAIGN-GRAPHICS-TRACE"
}
```

These command placeholders are deliberately not runnable: the campaign must
identify its actual active guest desktop user/session and installed probe path.
For each launch/read command the driver passes fresh `DORY_GPU_PROBE_NONCE` and
`DORY_GPU_PROBE_READY_FILE` environment variables through the normal guest agent.
Use them in the probe's `--nonce`/`--ready-file` arguments and result paths;
hardcoded old results cannot pass. Launch the bounded probe with redirected
output so the launch acknowledgement returns while its challenge is held.
Both redraws reject software rendering and require current in-tree source and
binary build receipts. The explicit graphics-trace placeholder is replaced only
with this campaign's exact runtime trace; a different fixed path is rejected.

`--capture-only` reuses the existing GPU collector without installer keys,
lifecycle writes or fault injection. It never emits outer campaign PASS.
`renderer-recovery.json` retains ordered raw controls, restart intent/ack,
both pixel bundles, witness/source hashes and cleanup. The scenario gate and
immutable-bundle verifier independently replay it and join it to the
fault-surviving guest and final running operation. Release eligibility remains
false. Standalone replay does not require a live guest:

```sh
python3 scripts/arm-ubuntu-renderer-recovery.py --verify-only \
  --app /absolute/Dory.app --mach-service dev.dory.readiness.armubuntu.RUN-ID \
  --machine readiness-arm-ubuntu-RUN-ID --run-directory /absolute/run
```

## OpenGL strategy comparison

Phase A5 compares Zink → Venus → MoltenVK with VirGL2 → ANGLE → Metal under
identical host, guest, resolution, CPU, memory, worker, and desktop conditions.
Use `collect-opengl-strategy.py` on the macOS renderer host to execute each path's
nine workload commands and generate `zink-venus.json` or `virgl2-angle.json` from
actual observations. Its plan is `dory.opengl-workload-plan@2` with exact keys
`schema`, `path`, `metadata`, `workerPID`, `workerExecutable`, `graphicsTrace`,
`inventoryCommand`, `visualEvidenceDirectory`, `computeResultFile`,
`expectedProbeNonce`, and `workloads`. `inventoryCommand` is an argv array that runs
`collect-opengl-inventory.py` inside the same graphical guest session (for example
through an owned SSH wrapper) and writes one JSON object to stdout. `metadata`
carries the comparison-run guest/candidate/machine/resource
fields plus the runner's `operationID` and `workerGeneration`; host model/build,
source commit, timestamp, and worker SHA-256 are captured by the collector. Each
workload has `id`, an argv-array `command` (or `null`), `timeoutSeconds`, and an
`unavailableReason` (required only for a null command). The nine IDs and order are
those in `verify-opengl-strategy.py`.

First run the matching GPU probe in the guest and retain its unedited JSON output.
For Zink/Venus use `dory-vulkan-probe`; for VirGL2 use `dory-gl-probe`. The guest
inventory command takes `--path zink-venus|virgl2-angle --probe-result /absolute/probe.json`.
It records `/etc/os-release`, `uname`, the live desktop session and compositor version,
`glxinfo -B`, installed graphics/compositor package versions, ICD/DRI files and,
for Venus, `vulkaninfo --summary`. It derives `apiCapabilities` only from the
probe's device-enabled extension/feature lists. The host collector retains the
inventory stdout/stderr and SHA-256, and refuses to begin workload commands if
the inventory identity, renderer, software classification, or capabilities differ
from plan metadata. A package or ICD file is inventory, not proof that a Vulkan
feature was negotiated. The Vulkan probe now queries robustness2, extended
dynamic state, and timeline semaphores and enables each only when its selected
Venus device supports it. Missing optional features do not break the baseline
probe, but they prevent Zink selection in the comparison verifier.

Before any measured workload, the collector copies and independently replays the
complete displayed-pixel bundle from `visualEvidenceDirectory`. It requires the
same probe bytes as the guest inventory and the same machine, operation, worker
generation, path-specific API, and `expectedProbeNonce`. Zink also requires a
`computeResultFile` from `dory-compute-probe` with the same nonce and Venus device;
VirGL2 sets that field to `null`. The independent compute reduction oracle and
visible-pixel/accelerated-trace oracle must both pass before Zink workloads run.

The command is responsible for starting and stopping the real guest application
in a dedicated campaign VM. Its instrumentation must emit a line such as
`DORY_METRIC {"kind":"shaderCompile","durationNanoseconds":42000000}` to
stdout/stderr for the first actual shader compilation. A missing event is a FAIL,
never an inferred stall. The collector takes frame timestamps only from new
`metalPresentationCompleted` events with the exact machine, operation, worker,
scanout, and resolution; it samples the live host renderer PID for CPU/RSS.
`glmark2` must print one `glmark2 Score: N` line. Raw command output and graphics
trace excerpts and timestamped renderer CPU/RSS samples are retained with hashes
under `dory.opengl-workload-collection@5`, and `collection.json` includes p99 frame
intervals. An unavailable or failed workload is recorded explicitly as FAIL.
Run it once per path into two separate new output directories. The collector
writes the path run JSON, a retained `plan.json`, `inventory.stdout.json`, `collection.json`, a copied
`visual-evidence/` bundle, a `raw/` directory containing each workload's stdout,
stderr, graphics trace and `worker-samples.ndjson`, and (for Zink) `compute-result.json`. Copy them into
one comparison directory as `<path>.json`, `<path>.plan.json`, `<path>.inventory.json`,
`<path>.collection.json`, `<path>.visual-evidence/`, `<path>.raw/`, and
`zink-venus.compute.json`. The verifier re-hashes every raw workload file and
replays submission-before-completion ordering, frame counts, p95/p99 intervals,
renderer CPU/RSS peaks, first-shader telemetry and the glmark2
score; merely retaining digest strings in `collection.json` is not sufficient:

```sh
python3 guest-probes/collect-opengl-strategy.py \
  --plan /absolute/zink-plan.json --output /absolute/zink-collection
python3 guest-probes/collect-opengl-strategy.py \
  --plan /absolute/virgl-plan.json --output /absolute/virgl-collection
```

The collector requires a clean source tree and records the worker file hash; the
outer campaign must still bind that PID/file to the signed candidate and check
application-specific shader correctness and visible content under the measured
workloads. A passing path-level challenge does not prove that every application
rendered correctly. The comparison verifier requires
`dory.opengl-strategy-comparison@4`, both copied visual bundles, the Venus compute
result, controlled guest inventories and all selected-path workload results before
admitting a default.

Retain `comparison.json`, both path run JSON files, both path inventory and
collection sidecars, both visual bundles and the Venus compute result in one
directory, then verify the pair and render the
required comparison table:

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
The verifier also includes the collection sidecars' p99 frame intervals in its
comparison table and rejects p99 values below p95 for passing workloads.
Passing Zink evidence must include robustness2, dynamic rendering, extended
dynamic state, and timeline-semaphore support. `dynamicRendering` is the
actually enabled Vulkan 1.3 core feature; an unenabled
`VK_KHR_dynamic_rendering` extension name is not a substitute.
The second passing path may be retained only for a named compatibility need;
failures remain valid measurements but cannot be selected or retained.

For release qualification, place the complete standalone
displayed-pixel bundle under `evidence/graphics-acceleration/` and the complete
OpenGL comparison under `evidence/opengl-strategy/` in the signed Linux VM
performance bundle. Set `launch.graphics.accelerationEvidence` to
`evidence/graphics-acceleration/gpu-display-evidence.json`. The outer bundle
verifier replays both proofs, checks the displayed-pixel receipt against the
exact launch operation, and binds the selected comparison run to the same
machine, operation, guest architecture, component candidate and graphics API.
An accelerated verification receipt uses schema 2; a legacy schema-1 receipt
cannot authorize an accelerated qualification. Software receipts remain schema 1.
