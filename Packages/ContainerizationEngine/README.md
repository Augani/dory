# ContainerizationEngine

This package contains Dory's production macOS 15+ Hypervisor.framework VM helper, `dory-hv`. It is
not an alternate app backend or a future Apple `containerization` integration. `doryd` owns the
local engine and launches this helper on supported hosts; macOS 14 selects the `dory-vmm`
Virtualization.framework fallback from `dory-core-swift`.

The full process, storage, networking, and trust-boundary contract is documented in the
[delivery plan](../../PLAN.md). This package implements the Dory-owned Linux helper for Apple
Silicon hosts; macOS ARM64 guests use the supported VZMac path in `dory-core-swift`.

## What ships here

- Arm64 raw-HV boot/device implementation for native Linux on Apple Silicon, plus DoryPC
  boot/device scaffolding for translated x86_64 Linux. Intel hosts, Windows guests, and macOS
  x86_64 are outside this delivery programme.
- Virtio block, network, vsock, rng, balloon, VirGL/Venus GPU, and VirtioFS devices.
- A copyless guest networking path through the provenance-pinned `gvproxy` helper.
- VirtioFS host sharing with a correctness-first zero-TTL baseline, isolated worker authority,
  bounded FSEvents batching for invalidation delivery, queue/backpressure telemetry, and recovery.
- Published-port, SSH-agent, host-AI, and guest-control bridges.
- USB host discovery, bounded host-device access, a USB/IP bridge, and authenticated Dory Tools
  `usb-vhci@1` attach/detach. Linux camera sharing uses that same production path to expose the
  permission-aware Mac capture backend as a standard UVC device.
- `dory-hv usb list` reports each exact interface tuple and its capture decision. Hubs, built-in
  host devices, storage that has not passed an eject transaction, smart-card/security devices, and
  host Bluetooth controllers are rejected before authorization or open.
- Physical discovery also issues an opaque identity token over stable topology, VID/PID, device
  revision, and serial identity; the serial itself never crosses the public control plane. Attach
  requires that token on every control-plane hop, and the runner recomputes and compares it before
  `IOServiceAuthorize` or device open so a stale bus address cannot select replacement hardware.
- The same Rust `DoryCore` guest handshake, multiplexing, protobuf, Docker dataplane, and half-close
  behavior used by doryd and the VZ fallback.

`Package.swift` intentionally exposes only the `dory-hv` executable and its supporting/test targets.
Historical `ContainerizationVMEngine` and `dory-vmboot` prototype sources were removed because they
were not build targets or production dependencies.

## PC graphics recovery

The app's graphics-restart command requests a VirtIO GPU reset, not a PC machine restart.
Unexpected loss of the authenticated PC renderer also requests only that GPU reset: guest RAM,
vCPU execution, disks and network retain their owners. Until the driver writes status zero,
no replacement is admitted. After backend and PCI queue retirement, a fresh daemon-authorized
worker with identical features/capsets and a newer generation is installed; pending fresh queues
are replayed without requiring another guest kick. Old callbacks cannot restore graphics readiness.
Reset admission is consumed once; a later worker failure requires a new guest reset.
An intentional whole-guest reboot during this handoff joins its pending worker preparation.

Readiness is revoked on loss and restored only by fresh-generation producer/shader/presentation
observations. A replacement bootstrap failure leaves the running VM's graphics unavailable;
host presentation/resource-retirement faults retain their separate fail-closed stop behavior.
These are implemented and locally tested boundaries, not a physical worker-kill, surviving GPU
context or three-family desktop qualification claim.

## Build and test

The generated DoryCore XCFramework and Swift bindings are ignored build products. Materialize them
before building this package directly:

```sh
../../scripts/build-dory-ffi-xcframework.sh
swift test
swift build -c release --product dory-hv
```

Repository CI and the release bundler run that prerequisite automatically. A source build is not
release evidence: the exact signed helper, kernel, rootfs, guest agent, gvproxy, data-drive path, and
host OS tier are rebound and exercised by the release qualification gates.

The physical Mac camera gate must run from the Xcode-built `DoryHVRunner.app`; an unbundled SwiftPM
binary is rejected because it cannot prove the production bundle identity, camera usage string, or
camera entitlement:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project ../../Dory.xcodeproj -scheme DoryHVRunner \
  -configuration Release -derivedDataPath /absolute/path/to/DerivedData \
  DORY_BUNDLE_RENDERER=0 DORY_BUNDLE_RENDERER_REQUIRED=0 \
  DORY_BUNDLE_VENUS=0 DORY_BUNDLE_VENUS_REQUIRED=0 build
/absolute/path/to/DerivedData/Build/Products/Release/DoryHVRunner.app/Contents/MacOS/dory-hv \
  camera-qualify --frames 60 --timeout-sec 60
```

The camera gate disables renderer packaging because it does not exercise graphics; a normal Release
bundle still requires and seals the separately qualified exact renderer tuple.

The canonical `dory.host-camera-qualification@1` receipt binds the signed runner bytes, hashed
usage description and camera identity, exact 1280×720 JPEG frame/byte totals, stream digest,
monotonic delivery latency, host tuple, authorization, and post-capture shutdown. This proves the
physical AVFoundation/TCC source. The ARMVirt Fedora gate separately proves the standard UVC,
USB/IP, Linux VHCI, `uvcvideo`, and V4L2 data path; sustained frame-drop and A/V-sync campaigns are
still required before a broad performance claim.
