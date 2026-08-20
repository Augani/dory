# Dory compatibility contract

## Supported hosts

| Environment | Status |
|---|---|
| Apple Silicon, macOS 15 or later | Supported with Dory's Hypervisor.framework engine |
| Apple Silicon, macOS 14 | Supported with the bundled Virtualization.framework fallback |
| Intel Mac | Unavailable until a dedicated physical candidate is qualified |
| Windows or Linux host | Unavailable; Dory is a macOS app |

## Supported product surface

- Docker 29 API and bundled CLI
- Buildx, BuildKit, and Compose v2 in Docker Core; kubectl in the optional Kubernetes component
- Containers, images, named volumes, bind mounts, bridge networks, custom IPAM, registries, and port publishing
- OpenSearch, Elasticsearch, and other mmap-heavy workloads with guest `vm.max_map_count=262144`
  and a default container `nofile` limit of 65536
- Common linux/amd64 images on Apple Silicon through FEX
- k3s v1.34, v1.35, and v1.36 presets
- Persistent arm64 Linux machines: managed Ubuntu 24.04 LTS GNOME and Debian 13/Kali rolling Xfce desktops plus lightweight Alpine headless VMs, with resources, scoped mounts, network addresses, recipes, snapshots, clone, import, export, verified scheduled local recovery bundles, and signed in-place desktop updates with automatic rollback
- Hardware Vulkan in managed arm64 desktops through Dory's isolated, capability-probed Venus runtime, with automatic fallback to classic VirGL and software
- Managed `.dorydrive` storage, sparse growth, verified backup, restore, and external local APFS drives
- Transactional full or exact-selection migration from detected Docker-compatible engines, with dependency closure, rollback, source-drift rejection, and selected/verified/omitted completeness evidence
- Localhost ports, optional local domains and HTTPS, built-in low-port forwarding, custom resolver and proxy ports, and opt-in LAN access
- Auto-Idle, diagnostics, targeted repair, safe cleanup, support bundles, JSON guide, wait, events, and MCP
- Signed in-place update preflight, exact last-known-good app/config/component records, next-launch
  workload smoke, safe automatic rollback, and recovery export when durable schema rollback is unsafe

Dory ships one Docker Core app. Kubernetes, Linux Machines, the shared Linux Desktop Runtime, and the managed Debian, Ubuntu, and Kali images are signed optional components stored on the selected data drive. Removing a component reclaims only its installed payload and preserves workload data.

## Developer tools

Dory targets standard Docker API clients and has dedicated compatibility checks or release gates for common workflows such as VS Code Dev Containers, Testcontainers, act, local cloud emulators, Tilt, registries, and Kubernetes tools.

```sh
dory compat --json
dory compat --recipe TOOL
```

Compatibility can vary when a client depends on another product's private paths, extensions, or desktop-only integration.

## Current machine boundary

Desktop machines run normal graphical and command-line applications with Ubuntu 24.04 LTS GNOME or Debian 13/Kali rolling Xfce, plus glibc, systemd, Bash, and a configurable login user. Their window uses a true 2x guest framebuffer, dynamically follows its Mac window, and applies matching desktop scaling. Headless machines use Alpine, musl, `root`, and `/bin/sh`. User-selected arm64 EFI installer ISOs are preview: Dory separates architecture preflight from exact-media/host runtime evidence, privately stages accepted media, and preserves disk, NVRAM, and install-media lifecycle. Other arbitrary desktop images and guest kernel modules are outside the current contract.

## Supported

- Dedicated agent sandbox VMs are supported with non-root execution, read-only mount defaults,
  enforced deny/allowlist/full egress, resource caps, credential grants, manifests, kill, and TTL.
- USB host discovery is supported and read-only.
- Build Activity is supported for builds launched by Dory, including durable history, logs, cache
  visibility, and cancellation.
- Scheduled local machine recovery bundles are supported. Dory verifies every archive through the
  import path, periodically boots a disposable verifier, and never applies retention to manual
  snapshots.

## Preview

- Custom arm64 Linux installation from ISO through EFI until installation, reboot, media ejection,
  devices, and guest integration pass the exact-candidate physical-Mac matrix.
  Ubuntu 24.04.3 and 24.04.4 are known unstable on Mac14,10/macOS build 26A5406e with the retired
  VirtIO-block EFI profile. The current native-NVMe/fsync profile completed Ubuntu 24.04.3 install,
  updates, ISO ejection, and persistent GNOME/Chrome boot, but a later Chromium-install guest stall
  keeps that exact tuple unqualified.
- Remote SSH workspace foundations and custom machine kernel/rootfs inputs within their published
  image and trust limits.

## Unavailable

- USB attach, detach, and replay until the guest USB/IP RPC and physical qualification exist
- Intel host builds before dedicated physical qualification
- Complete x86_64 guest operating systems on Apple Silicon hardware virtualization
- Audio passthrough
- Managed remote/offsite machine backup or S3 backup
- Third-party MCP catalog/gateway; Dory's local MCP controls Dory only
- Managed image-update orchestration, mDNS/multicast relay, and general L2 bridging

## Report a difference

```sh
dory version
dory doctor --active
dory support bundle --json --active
```

Open an issue with the affected tool and version, the exact command, expected behavior, actual behavior, Mac model, macOS version, and redacted support bundle path.
