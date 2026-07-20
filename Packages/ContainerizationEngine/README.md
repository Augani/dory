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
- Virtio block, network, vsock, rng, balloon, GPU-preview, and VirtioFS devices.
- A copyless guest networking path through the provenance-pinned `gvproxy` helper.
- Host-share coherence, bounded FSEvents batching, queue/backpressure telemetry, and recovery.
- Published-port, SSH-agent, host-AI, and guest-control bridges.
- USB host discovery and a host usbip bridge. Attach/detach remain unavailable because the guest
  vhci RPC is intentionally absent and every public surface fails closed before claiming a device.
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
