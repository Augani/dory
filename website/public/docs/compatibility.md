# Dory compatibility contract

## Supported hosts

| Environment | Status |
|---|---|
| Apple Silicon, macOS 15 or later | Supported with Dory's Hypervisor.framework engine |
| Apple Silicon, macOS 14 | Supported with the bundled Virtualization.framework fallback |
| Intel Mac | Not included in current releases |
| Windows or Linux host | The macOS app is not supported |

## Stable product surface

- Docker 29 API and bundled CLI
- Buildx, BuildKit, Compose v2, and kubectl
- Containers, images, named volumes, bind mounts, bridge networks, custom IPAM, registries, and port publishing
- Common linux/amd64 images on Apple Silicon through FEX
- k3s v1.34, v1.35, and v1.36 presets
- Persistent arm64 Linux machines: managed Debian 13 + Xfce desktops and lightweight Alpine headless VMs, with resources, scoped mounts, network addresses, recipes, snapshots, clone, import, and export
- Managed `.dorydrive` storage, sparse growth, verified backup, restore, and external local APFS drives
- Transactional migration from detected Docker-compatible engines
- Localhost ports, optional local domains and HTTPS, built-in low-port forwarding, custom resolver and proxy ports, and opt-in LAN access
- Auto-Idle, diagnostics, targeted repair, safe cleanup, support bundles, JSON guide, wait, events, and MCP

## Developer tools

Dory targets standard Docker API clients and has dedicated compatibility checks or release gates for common workflows such as VS Code Dev Containers, Testcontainers, act, local cloud emulators, Tilt, registries, and Kubernetes tools.

```sh
dory compat --json
dory compat --recipe TOOL
```

Compatibility can vary when a client depends on another product's private paths, extensions, or desktop-only integration.

## Current machine boundary

Desktop machines run normal graphical and command-line applications with Debian 13, glibc, systemd, Xfce, Bash, and a configurable login user. Headless machines use Alpine, musl, `root`, and `/bin/sh`. Other desktop distributions and arbitrary guest kernel modules are outside the current contract.

## Preview and experimental

- Dedicated agent sandbox VMs are preview.
- Sandbox `outbound` currently grants full egress and reports that scoped egress is not enforced.
- In-guest Venus and Vulkan GPU acceleration are experimental.
- USB/IP attachment may require user approval and compatible guest support.

## Deferred

- Intel host builds
- Desktop distribution selection beyond managed Debian 13 + Xfce
- Audio passthrough
- Scoped outbound-only sandbox filtering

## Report a difference

```sh
dory version
dory doctor --active
dory support bundle --json --active
```

Open an issue with the affected tool and version, the exact command, expected behavior, actual behavior, Mac model, macOS version, and redacted support bundle path.
