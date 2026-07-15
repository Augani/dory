# Dory compatibility

This document describes the public Dory 0.3 product surface. Dory is under active development, so
please report workflows that behave differently from a standard Docker engine.

## Platform

| Environment | Status |
|---|---|
| Apple Silicon, macOS 15 or later | Supported; uses Dory's Hypervisor.framework engine |
| Apple Silicon, macOS 14 | Supported by the full bundle through the Virtualization.framework fallback |
| Intel Mac | Not included in 0.3 releases; planned after dedicated hardware validation |
| Windows or Linux host | Not supported by the macOS app |

## Docker workflow

| Capability | Status |
|---|---|
| Docker CLI and API | Supported through the `dory` context and `~/.dory/dory.sock` |
| Containers | Create, run, start, stop, restart, remove, inspect, logs, stats, exec, attach, and port publishing |
| Images | Pull, build, inspect, history, tag, save/load, remove, and prune |
| Buildx / BuildKit | Bundled; contexts, secrets, SSH mounts, cache import/export, and cancellation supported |
| Volumes | Create, inspect, browse, copy, remove, and prune |
| Networks | Bridge networks, custom IPAM, aliases, connect/disconnect, inspect, remove, and prune |
| Compose | Bundled Compose v2 with profiles, overrides, `.env`, builds, health dependencies, and external resources |
| Registry authentication | Docker-compatible login and credential flow |
| Bind mounts | Home-directory and `/Volumes` paths are shared at their native macOS paths |
| amd64 images on Apple Silicon | Supported for common development workloads through bundled FEX |

Some specialized Docker extensions and host-specific plugins may assume another product's internal
paths. Open an issue with the exact tool and version when that happens.

## Storage and data

| Capability | Status |
|---|---|
| Managed data drive | Supported; defaults to `~/Library/Application Support/Dory/Dory.dorydrive` |
| External data drive | Supported on mounted local APFS storage under `/Volumes` |
| Data-drive growth | Supported; shrinking is intentionally rejected |
| Backup / verify / restore | Supported while the selected drive is idle |
| Uninstall preservation | Supported; ordinary uninstall keeps workload data |
| Migration | Imports images, volumes, networks, writable layers, and container definitions after preflight |

Keep independent backups of important data. Dory refuses unsafe replacement and shrinking
operations, but it is not a substitute for a normal backup strategy.

## Kubernetes

| Capability | Status |
|---|---|
| k3s provisioning | Supported in the shared engine |
| `kubectl` | Bundled |
| Resource browser | Pods, deployments, services, config maps, secrets, and ingresses |
| Workload actions | Logs, exec, scale, restart, rollout, and apply |
| Multiple Kubernetes versions | Selectable from supported Dory presets |

Large local clusters require enough memory and disk space. Stop unused workloads before changing
engine resources.

## Linux machines

| Capability | Status |
|---|---|
| Distributions | Ubuntu, Debian, Fedora, Alpine, and Arch presets |
| Access | Embedded terminal, `dory ssh`, and command execution |
| Resources | CPU and memory configuration with guest-reported statistics |
| Snapshots and export/import | Supported |
| Development recipes | Node, Python, Go, Rust, and customizable package selections |
| Graphical Linux sessions | Not part of the current product; possible future work |

Machines are intended for terminal applications, local services, and development environments.

## Networking

| Capability | Status |
|---|---|
| Published ports | Localhost by default |
| `*.dory.local` domains | Optional system integration |
| Trusted local HTTPS | Optional local certificate authority |
| Container-to-host services | `host.dory.internal` |
| Custom DNS and proxies | Configurable |
| VPN environments | Supported in common configurations; report provider-specific issues |
| IPv6 | Local dual-stack behavior is supported; external availability follows the host network |
| LAN-visible publishing | Explicit opt-in; do not expose untrusted services |

## Developer tools

Dory is designed for standard Docker API consumers, including Testcontainers, Dev Containers,
local cloud emulators, CI workflow runners, and Kubernetes development tools. Compatibility can
still vary by tool version and by assumptions about Docker Desktop-specific file paths.

SSH-agent forwarding is available at `/run/host-services/ssh-auth.sock`. Mount it only into trusted
containers because any process with agent access may request signatures.

## Experimental or deferred

- In-guest Venus/Vulkan acceleration is experimental.
- USB and audio passthrough do not have a finished public workflow.
- Intel-host builds are deferred to a later release.
- Graphical Linux-machine sessions are not included in 0.3.

## Getting help

Start with:

```sh
dory doctor --active
dory disk
dory routes
dory support bundle
```

When filing an issue, include the Dory version, macOS version, Mac model, affected command or tool,
and a redacted support bundle when available.
