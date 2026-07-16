# Dory compatibility

This document describes the Dory 0.3.1 public product surface. Dory is under active development, so
please report workflows that behave differently from a standard Docker engine.

## Platform

| Environment | Status |
|---|---|
| Apple Silicon, macOS 15 or later | Supported; uses Dory's Hypervisor.framework engine |
| Apple Silicon, macOS 14 | Supported by the full bundle through the Virtualization.framework fallback |
| Intel Mac | Not included in current releases; planned after dedicated hardware validation |
| Windows or Linux host | Not supported by the macOS app |

The standard Apple Silicon build omits the large graphical guest images. The all-inclusive Desktop
build adds the managed Debian, Ubuntu, and Kali images. Both builds include containers, Kubernetes,
and headless Linux servers; an existing graphical machine remains manageable if the lean build is
installed later.

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
| Guest OS | Managed Debian 13, Ubuntu 24.04 LTS, or Kali rolling Xfce desktop; lightweight Alpine headless Linux on native arm64 |
| Access | Configurable desktop user, graphical session, embedded or selected external terminal, `dory machine shell`, and command execution |
| Resources | CPU and memory configuration with guest-reported statistics |
| Snapshots and export/import | Supported |
| Development recipes | Curated Node, Python, Go, Rust, Java, Ruby, and DevOps toolsets for Debian and Alpine |
| Graphical Linux sessions | Supported with managed Debian, Ubuntu, and Kali Xfce profiles on Apple Silicon |
| Desktop display | Retina-sharp 2x framebuffer, dynamic window resizing, and matching Xfce scaling |

Desktop machines run normal graphical and command-line applications with glibc and systemd. Their
disk is thin-provisioned to 64 GiB in the selected Dory data drive. Headless machines use Alpine,
musl, `root`, and `/bin/sh`. Arbitrary desktop images and guest kernel modules are not part of the
current contract.

## Networking

| Capability | Status |
|---|---|
| Published ports | Localhost by default |
| `*.dory.local` domains | Optional system integration |
| Trusted local HTTPS | Optional local certificate authority |
| Container-to-host services | `host.dory.internal` |
| Custom DNS and proxies | Configurable |
| Docker bridge subnet | Configurable private /16 through /24; applying restarts the engine while preserving data |
| VPN environments | Supported in common configurations; report provider-specific issues |
| IPv6 | Local dual-stack behavior is supported; external availability follows the host network |
| LAN-visible publishing | Explicit opt-in; do not expose untrusted services |

## Developer tools

Dory is designed for standard Docker API consumers, including Testcontainers, Dev Containers,
local cloud emulators, CI workflow runners, and Kubernetes development tools. Compatibility can
still vary by tool version and by assumptions about Docker Desktop-specific file paths.

SSH-agent forwarding is available at `/run/host-services/ssh-auth.sock`. Mount it only into trusted
containers because any process with agent access may request signatures.

## Automation and operations

| Capability | Status |
|---|---|
| Diagnostics | Passive and active checks for sockets, API, Docker, networking, mounts, registries, disk, memory, and helpers |
| Repair | Targeted dry runs with explicit apply and engine-restart controls |
| Cleanup | Dry run by default; named volumes require a second explicit flag |
| Support bundles | Redacted local evidence collection |
| Agent guide | Versioned JSON command and safety contract |
| MCP | Local stdio server with read-only mode, machine execution, waits, and events |
| Agent sandbox | Preview dedicated VM with explicit mounts, rollback, TTL cleanup, and reported network enforcement |

Run `dory agent guide --json` for the exact contract provided by the installed release. In the 0.3
preview sandbox, `none` and `full` network policies are enforced. `outbound` currently grants full
egress and reports that the narrower policy was not enforced.

## Experimental or deferred

- In-guest Venus/Vulkan acceleration is experimental.
- USB/IP scan, attach, detach, and remembered replay are available in the app and CLI. They may
  require macOS approval and compatible guest support.
- Audio passthrough does not have a finished public workflow.
- Intel-host builds are deferred to a later release.
- Desktop images beyond the managed Debian, Ubuntu, and Kali Xfce profiles are deferred.

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
