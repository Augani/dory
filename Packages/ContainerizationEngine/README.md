# ContainerizationEngine

This package contains Dory's production macOS 15+ Hypervisor.framework VM helper, `dory-hv`. It is
not an alternate app backend or a future Apple `containerization` integration. `doryd` owns the
local engine and launches this helper on supported hosts; macOS 14 selects the `dory-vmm`
Virtualization.framework fallback from `dory-core-swift`.

The full process, storage, networking, and trust-boundary contract is documented in the
[architecture guide](https://augani.github.io/dory/docs/architecture.md).

## What ships here

- Arm64 and x86_64 raw-HV boot/device implementations. Public 0.4 releases remain Apple-silicon
  only until an Intel candidate passes dedicated physical qualification.
- Virtio block, network, vsock, rng, balloon, VirGL/Venus GPU, and VirtioFS devices.
- A copyless guest networking path through the provenance-pinned `gvproxy` helper.
- Host-share coherence, bounded FSEvents batching, queue/backpressure telemetry, and recovery.
- Published-port, SSH-agent, host-AI, and guest-control bridges.
- USB host discovery, bounded host-device access, a USB/IP bridge, and authenticated Dory Tools
  `usb-vhci@1` attach/detach. Linux camera sharing uses that same production path to expose the
  permission-aware Mac capture backend as a standard UVC device.
- `dory-hv usb list` reports each exact interface tuple and its capture decision. Hubs, built-in
  host devices, storage that has not passed an eject transaction, smart-card/security devices, and
  host Bluetooth controllers are rejected before authorization or open.
- The same Rust `DoryCore` guest handshake, multiplexing, protobuf, Docker dataplane, and half-close
  behavior used by doryd and the VZ fallback.

`Package.swift` intentionally exposes only the `dory-hv` executable and its supporting/test targets.
Historical `ContainerizationVMEngine` and `dory-vmboot` prototype sources were removed because they
were not build targets or production dependencies.

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
export DEVELOPER_DIR=/Applications/Xcode-26.6.0-Release.Candidate.app/Contents/Developer
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
