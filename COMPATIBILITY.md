# Dory compatibility

This document describes Dory's current public product surface. Dory is under active development, so
please report workflows that behave differently from a standard Docker engine.

## Platform

| Environment | Status |
|---|---|
| Apple Silicon, macOS 15 or later | Supported; uses Dory's Hypervisor.framework engine |
| Apple Silicon, macOS 14 | Supported by the full bundle through the Virtualization.framework fallback |
| Intel Mac | **Unavailable**; no public build before dedicated physical qualification |
| Windows or Linux host | **Unavailable**; Dory is a macOS app |

Dory ships one Apple Silicon Docker Core app. Kubernetes, Linux Machines, the shared Linux Desktop
runtime, and the managed Debian, Ubuntu, and Kali images are signed optional components. Their
payloads live on the selected Dory data drive and can be removed independently without deleting
workload data.

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
| Migration | Transactional full or exact-selection import with dependency closure, selected-scope preflight, rollback, source-drift rejection, and a selected/verified/omitted completeness report |
| In-place upgrade | Signed preflight, exact last-known-good app/config/components, next-launch workload smoke, safe automatic rollback, and recovery export when durable schema rollback is unsafe |

Keep independent backups of important data. Dory refuses unsafe replacement and shrinking
operations, but it is not a substitute for a normal backup strategy.

## Kubernetes

| Capability | Status |
|---|---|
| k3s provisioning | Supported in the shared engine |
| `kubectl` | Installed by the optional Kubernetes component |
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
| Scheduled local recovery bundles | Supported; owner-only durable schedules, archive re-import verification on every run, periodic disposable boot verification, and scheduler-owned retention |
| Managed remote/offsite machine backup | **Unavailable**; Dory does not claim an S3 or hosted backup service |
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
| Corporate proxy, scoped CA, split DNS, and VPN profile | Supported with preview/apply/disable ownership checks and automatic reconciliation |
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
| Dory control MCP | Local stdio server with read-only mode, machine execution, waits, and events |
| Third-party MCP catalog/gateway | **Unavailable**; Dory's control MCP is not a tool marketplace or proxy |
| Agent sandbox | Supported dedicated non-root VM with read-only mount defaults, enforced egress, credential/resource grants, rollback, manifests, kill, named reuse, and daemon TTL |

Run `dory agent guide --json` for the exact contract provided by the installed release. Sandbox
network defaults to `none`; `outbound` permits only Dory DNS and explicit resolved destination/port
grants; `full` is an explicit unrestricted choice. See `SANDBOX_THREAT_MODEL.md` for trust boundaries.

## Preview

- In-guest Venus/Vulkan acceleration is preview on the Apple-silicon raw-HV tier.
- Remote SSH workspace foundations and custom machine kernel/rootfs inputs remain preview with the
  exact limits in `ARCHITECTURE.md` and `MACHINE_IMAGE_CONTRACT.md`.

## Unavailable

- USB attach, detach, and remembered replay are unavailable. Host discovery is supported, but the
  engine fails closed until a complete guest USB/IP RPC and physical qualification exist.
- Audio passthrough is unavailable.
- Intel-host public builds are unavailable before dedicated physical qualification.
- Desktop images beyond the managed Debian, Ubuntu, and Kali Xfce profiles are unavailable.
- Managed image update discovery/replacement, mDNS/multicast relay, and general L2 bridging are
  unavailable in 0.4. Their proposed boundaries are documented in
  `POST_V0.4_PRODUCT_DESIGNS.md`.

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
