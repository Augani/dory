<p align="center">
  <img src="website/public/logo.svg" width="120" alt="Dory logo">
</p>

<h1 align="center">Dory</h1>

<p align="center">
  <strong>Your complete local Linux workspace, built for Mac.</strong><br>
  Docker, Compose, Kubernetes, persistent Linux machines, migration, recovery, and agent automation<br>
  in one native, open-source app.
</p>

<p align="center">
  <a href="https://github.com/Augani/dory/releases/latest"><img src="https://img.shields.io/github/v/release/Augani/dory?color=147FE8" alt="Latest release"></a>
  <a href="https://github.com/Augani/dory/stargazers"><img src="https://img.shields.io/github/stars/Augani/dory?style=flat&logo=github&color=147FE8" alt="GitHub stars"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-147FE8" alt="GPL-3.0 license"></a>
  <img src="https://img.shields.io/badge/Apple%20Silicon-macOS%2014%2B-0B1828" alt="Apple Silicon, macOS 14 or later">
</p>

<p align="center">
  <a href="https://augani.github.io/dory/"><strong>Website</strong></a> ·
  <a href="https://github.com/Augani/dory/releases/latest"><strong>Download</strong></a> ·
  <a href="COMPATIBILITY.md"><strong>Compatibility</strong></a> ·
  <a href="https://augani.github.io/dory/llms-full.txt"><strong>Agent reference</strong></a>
</p>

> Dory is built and qualified for Apple Silicon. Intel Mac support will follow after dedicated
> hardware validation. Current downloads and the Homebrew cask do not include an Intel build.

<p align="center">
  <a href="https://augani.github.io/dory/#product"><strong>Explore the interactive Dory interface</strong></a>
</p>

## What Dory is

Dory is a self-contained local runtime for software development on macOS. It gives standard Docker
tools a native Apple Silicon engine, adds one-click Kubernetes and persistent Linux machines, and
keeps the whole workspace operable from both a SwiftUI app and a versioned command-line interface.

There is no required Docker Desktop, external VM manager, account, cloud control plane, telemetry,
or commercial-use tier. Dory is GPL-3.0 software and stores workload data on your Mac.

| Surface | What ships in Dory |
|---|---|
| Docker | Docker 29 API and CLI, Buildx, BuildKit, Compose v2, registries, bind mounts, volumes, and custom networks |
| Native app | Containers, images, volumes, networks, Compose projects, Kubernetes, Linux machines, health, migration, and settings |
| Linux machines | Full Debian 13, Ubuntu 24.04 LTS, and Kali rolling Xfce desktops plus lightweight Alpine headless VMs, with configurable resources, scoped mounts, networking, recipes, snapshots, clone, import, and export |
| Kubernetes | One-click k3s with selectable v1.34, v1.35, and v1.36 presets plus a native resource browser |
| Migration | Transactional import from Docker Desktop, OrbStack, Colima, Rancher Desktop, Podman, or another Docker-compatible socket |
| Storage | One managed `.dorydrive`, external APFS drive support, sparse growth, verified backup, restore, and safe selection |
| Networking | Localhost ports, optional local domains and HTTPS, low ports, host services, custom DNS/proxy ports, and opt-in LAN access |
| Operations | Auto-Idle, active diagnostics, targeted repair, safe cleanup, support bundles, wait primitives, and event streams |
| Agents | Versioned JSON guide, non-interactive schemas, read-only MCP mode, machine execution, and preview isolated sandbox VMs |

## Why it is different

- **A complete runtime, not a dashboard.** Dory bundles its engine, guest, Docker tools, Compose,
  Buildx, `kubectl`, networking, file sharing, and recovery tools.
- **One shared container VM.** Containers use one persistent Linux engine. Its memory ceiling is
  configurable, and free guest pages can be returned to macOS.
- **Linux machines beside containers.** Machines are separate VMs with their own disk, address,
  resources, shell, shares, and snapshots. They are not disguised containers.
- **Every important setting is in the app.** Engine resources, storage, migration, local domains,
  low ports, LAN access, Auto-Idle, machine environment policy, USB, and managed defaults all have a
  graphical path.
- **Automation is a product surface.** JSON schemas, safe dry runs, event streams, wait commands,
  a machine-readable guide, and MCP let coding agents operate Dory without scraping the UI.
- **Recovery preserves data.** Repairs are targeted, cleanup is a dry run by default, engine
  restarts require clear intent, and ordinary uninstall keeps the selected data drive.

## Install

### Homebrew

```sh
brew install --cask Augani/dory/dory
```

Open Dory once. The daemon keeps `docker`, `docker compose`, `kubectl`, and `dory` available in
`~/.dory/bin`, creates the `dory` Docker context, and points it at `~/.dory/dory.sock`. Docker
Desktop and a separate Docker CLI install are not required.

### Direct download

Download the notarized Apple Silicon DMG from
[GitHub Releases](https://github.com/Augani/dory/releases/latest), drag Dory to Applications, and
open it.

| Release asset | Purpose |
|---|---|
| `Dory-x.y.z-arm64.dmg` | Recommended lean installer: containers, Kubernetes, and headless Linux servers |
| `Dory-x.y.z-desktop-arm64.dmg` | All-inclusive installer with Debian, Ubuntu, and Kali graphical desktops |
| `Dory-x.y.z-arm64.zip` | Lean app archive |
| `Dory-x.y.z-desktop-arm64.zip` | All-inclusive app archive |
| `Dory-x.y.z-lite.zip` | Native UI for an existing Docker-compatible engine |
| `dory-engine-x.y.z-arm64.tar.gz` | Headless Dory engine bundle |
| `release-manifest.json` | Artifact names, hashes, and release provenance |
| `Dory-x.y.z.cdx.json` | CycloneDX software bill of materials |

### Requirements

- Apple Silicon Mac
- macOS 14 Sonoma or later
- 8 GiB of Mac memory recommended for mixed container, Kubernetes, and machine workloads
- Xcode 26 or later only when building Dory from source

## Quick start

Wait for the app to report that the engine is ready, then use normal Docker commands:

```sh
docker context use dory
docker run --rm hello-world
docker run -d --name web -p 8080:80 nginx
open http://localhost:8080
```

Start a Compose project from a terminal or open its YAML file from the Compose screen:

```sh
docker compose up -d
docker compose ps
```

Check the full runtime before a development session:

```sh
dory doctor --active
dory routes --json
dory disk --json
```

## Docker workflow

Dory is designed for existing Docker clients and standard Docker API consumers. `dory <args>` is
also a direct passthrough to the bundled Docker CLI, so `dory ps` and `docker ps` target the same
engine.

### Containers

Use the CLI for the full Docker surface. In the app you can:

- create, start, stop, restart, inspect, and delete containers;
- group and control Compose services together;
- filter all, running, and stopped containers;
- view CPU and memory activity, ports, configuration, and environment variables;
- stream and copy logs;
- use an embedded interactive shell or open a separate Terminal.app window;
- open published ports from the container row.

### Images, volumes, and networks

- Pull, build, run, inspect, tag, save, load, delete, and prune images.
- Create, inspect, browse, copy, delete, and prune named volumes.
- Create bridge networks with custom IPAM, aliases, connect or disconnect containers, inspect,
  delete, and prune.
- Authenticate to private registries with Docker-compatible credential flows.

### Build and architecture support

Buildx and BuildKit are bundled. Dory supports build contexts, secrets, SSH mounts, cache import and
export, registry authentication, cancellation, and common multi-stage builds. Native arm64 images
are fastest. Common `linux/amd64` images and build workloads run on Apple Silicon through Dory's
built-in FEX path, which is enabled by default on new installs and can be changed in Settings.

### Bind mounts and file watching

Paths in your Mac home directory and on mounted drives under `/Volumes` are shared at their native
paths. Dory's release gates cover read, write, truncate, spaces in paths, host edit visibility, file
locking, and watcher behavior. Run this when a tool such as Vite, Tailwind, or Webpack does not see
changes:

```sh
dory mount --json
dory doctor --json --only mounts,watch,filelock
```

## Compose

Dory bundles Compose v2. Profiles, override files, `.env`, builds, health dependencies, named
volumes, custom networks, and external resources use the normal `docker compose` workflow. The
native Compose screen can open a YAML file, start or stop a project, restart running services, run
`down`, and jump from a service to its container details.

## Kubernetes

The Kubernetes screen creates a local k3s cluster inside the shared engine and lets you choose a
supported v1.34, v1.35, or v1.36 preset. Switching versions recreates the cluster and is presented
as a destructive action.

The native browser covers:

- pods with logs, exec, copy, and delete;
- deployments with scale and rolling restart;
- services, ConfigMaps, Secrets, and Ingresses;
- namespace filtering, YAML apply, rollout status, and kubeconfig copy.

The bundled `kubectl` and `dory k8s <kubectl args...>` target the same cluster. k3s has its own image
store, so push a built image to a registry or import it into the cluster before using it in a Pod.

## Dory Linux machines

Dory Linux machines are persistent, separate VMs rather than containers. The app offers full Xfce
desktops based on Debian 13, Ubuntu 24.04 LTS, or Kali Linux rolling for graphical and command-line
applications. A lightweight Alpine-based headless profile remains available for services,
terminals, test environments, and agent work. Each machine has its own disk, address, resources,
shares, and snapshots.

From the app or CLI you can:

- create, start, stop, delete, and inspect machines;
- choose Desktop Linux or Headless Linux when creating a machine in the app;
- choose 1 to 8 CPUs and 1 to 16 GiB of memory per machine;
- configure the desktop Linux username, then use its Xfce session, embedded terminal, or an external
  terminal selected in Settings;
- use a root shell for lightweight headless machines or `dory machine shell NAME`;
- execute structured commands with `dory machine exec NAME --json -- COMMAND`;
- share the Mac home directory or add only selected folders;
- set a DNS target override and reach machines through local domains;
- install verified Node.js, Python, Go, Rust, Java, Ruby, or DevOps recipes;
- take, restore, clone, export, import, and delete snapshots.

Headless CLI example:

```sh
dory machine create dev
dory machine start dev
dory machine exec dev --json -- /bin/sh -lc 'apk add git && git --version'
dory machine snapshot dev --note before-upgrade
dory machine shell dev
```

Desktop machines use native arm64 Debian 13, Ubuntu 24.04 LTS, or Kali rolling with systemd, Xfce,
Bash, a configurable login user, and a 64 GiB thin-provisioned disk stored in the selected
`.dorydrive`. They run normal graphical and command-line Linux applications and can mount the Mac
home at `~/Mac` only when the user enables that share. Headless machines retain the smaller Alpine,
`root`, and `/bin/sh` contract.

### Machine secrets and host access

New machines do not receive arbitrary host environment variables. Settings contains an allow-list.
`ANTHROPIC_API_KEY` is the default entry, while `OPENAI_API_KEY`, `GH_TOKEN`, and `HF_TOKEN` are
available presets. Only named, non-empty values are copied at creation time.

Mac folders are also private by default. A persistent machine sees only mounts selected at creation,
and an agent sandbox sees no host files unless an explicit mount is supplied.

CLIs inside a machine can optionally open authentication pages in the Mac browser and complete
localhost callbacks through Dory's browser-login bridge.

## Move from another runtime

Settings > Migrate & Compare detects Docker Desktop, OrbStack, Colima, Rancher Desktop, Podman, and
other running Docker-compatible Unix sockets. It shows a preflight inventory before writing to
Dory.

The import can preserve:

- image content and visible tags;
- named volume data;
- custom networks and detected IPAM settings;
- container configuration and Compose labels;
- writable container layers;
- port bindings;
- running, stopped, and paused state.

The source is treated as read-only, volume content is copied through temporary helpers, capacity and
name collisions are checked first, and an interrupted import keeps recovery state. Dory never
deletes the source. Bind-mounted files already live on the Mac and are referenced at their existing
paths rather than copied into the data drive.

Keep the old runtime installed until the preflight and post-import checks pass.

## Storage that stays yours

The default data drive is:

```text
~/Library/Application Support/Dory/Dory.dorydrive
```

Images, containers, named volumes, custom networks, machine disks, and snapshots live together in
this managed drive. Runtime sockets, replaceable logs, and caches remain under `~/.dory`.

Dory supports:

- local APFS data drives, including mounted drives under `/Volumes`;
- sparse Docker storage from 128 GiB to 2 TiB;
- safe growth without preallocating the full logical capacity;
- stopped-engine backups with chunk manifests and completion markers;
- full backup verification before restore;
- restore to a new path without overwriting an existing drive;
- explicit selection of a restored drive with the same durable identity.

Shrinking is refused. To move to a smaller drive, back up and restore into a new destination.

```sh
dory data path
dory data capacity --json
dory data grow 256 --json
dory data backup ~/Desktop/dory.dorybackup
dory data verify ~/Desktop/dory.dorybackup
dory data restore ~/Desktop/dory.dorybackup /Volumes/Work/Dory.dorydrive
dory data use /Volumes/Work/Dory.dorydrive
```

## Networking

Published ports bind to localhost by default. Dory never widens an explicit `127.0.0.1` or `::1`
binding.

Optional system integration adds:

- automatic names under `*.dory.local` or a per-user custom suffix;
- a local certificate authority for trusted HTTPS;
- Dory-owned resolver and packet-filter rules;
- built-in forwarding for ports 80, 443, and published TCP ports below 1024;
- source-preserving LAN and Tailscale access as an explicit opt-in.

Settings > Network shows the exact plan before macOS authorization and can remove Dory-owned rules.
The DNS resolver, HTTP proxy, and HTTPS proxy ports are configurable. This also allows separate
macOS accounts to choose unique suffixes and avoid shared-port conflicts.

Containers reach Mac services through `host.dory.internal`. Common host AI endpoints are available
without enabling experimental guest GPU support:

| Host service | Address from a container |
|---|---|
| Ollama | `host.dory.internal:11434` |
| LM Studio | `host.dory.internal:1234` |
| llama.cpp | `host.dory.internal:18190` |

Useful commands:

```sh
dory routes --json
dory network --json --active
dory network authorization-plan --json
dory network authorize --json --dry-run
dory network authorize --json --apply
dory network --lan-visible on
```

`dory expose` can also print or start a `cloudflared` command for a temporary public HTTPS tunnel.

## Runtime modes and resource control

Settings > Engine & Daemon controls the engine backend, CPU count, memory ceiling, common amd64
support, and experimental Venus GPU acceleration. Applying CPU or memory changes restarts the engine
and restores the containers that were running.

Dory has four availability modes:

| Mode | Behavior |
|---|---|
| Always On | Start with the app and keep the engine available |
| Auto-Idle | Sleep after 5, 15, 30, or 60 idle minutes |
| Battery Saver | Auto-Idle with a maximum 5-minute delay |
| Manual Stop | Keep running until explicitly stopped |

Auto-Idle can keep published ports, labeled projects, or Kubernetes awake. Its status and transition
history are visible in the UI and CLI.

```sh
dory mode auto-idle
dory idle status --json
dory idle history --json
dory engine sleep
dory engine wake
```

## Diagnostics, repair, and cleanup

The Health screen runs passive checks by default. Active probes create a small throwaway container
to test DNS, ports, mounts, registry access, file watching, memory, and helpers. Results are grouped,
repair actions are previewed, and support bundles are redacted.

```sh
dory doctor --json
dory doctor --json --active
dory doctor --json --diff
dory support bundle --json --active
dory repair all --json
dory repair all --json --apply
dory cleanup --json
dory cleanup --json --apply
```

`repair all --apply` does not restart a healthy data plane. A disruptive engine restart requires the
specific engine target and `--restart-engine`. Cleanup is a dry run unless `--apply` is present, and
volume pruning also requires `--include-volumes`.

## Built for agents and automation

Dory publishes a versioned local contract instead of asking agents to infer commands from terminal
text.

```sh
dory agent guide --json
dory mcp serve --read-only
dory wait engine --until running --timeout 60 --json
dory events --follow --json
```

The stdio MCP server implements protocol version `2025-11-25` and exposes:

- `dory.agent_guide`
- `dory.doctor`
- `dory.compat`
- `dory.engine_status`
- `dory.machine_list`
- `dory.machine_exec`
- `dory.sandbox_run`
- `dory.wait`
- `dory.events`

Launch with `--read-only` to block machine execution and sandbox writes. Agents should inspect first,
prefer JSON, run dry-run commands before writes, and use the narrowest repair target.

The preview sandbox command creates a dedicated Dory Linux VM, shares no host files by default,
supports scoped read-only or read-write mounts, optional rollback, TTL cleanup, and `none`,
`outbound`, or `full` network policy requests. `none` and `full` are enforced. In 0.3, `outbound`
currently provides full egress and reports `networkPolicyEnforced=false` until scoped egress ships.

```sh
dory sandbox run --json --network none --rollback -- /bin/sh -lc 'uname -a'
dory sandbox run --json --mount "$PWD:/workspace:ro" -- /bin/sh -lc 'ls /workspace'
```

Machine-readable references:

- [`llms.txt`](https://augani.github.io/dory/llms.txt)
- [`llms-full.txt`](https://augani.github.io/dory/llms-full.txt)
- [`agent-guide.json`](https://augani.github.io/dory/agent-guide.json)
- [`docs/agents.md`](https://augani.github.io/dory/docs/agents.md)
- [`docs/operations.md`](https://augani.github.io/dory/docs/operations.md)
- [`docs/compatibility.md`](https://augani.github.io/dory/docs/compatibility.md)

## Settings in the app

Everything below is available without using the command line:

| Settings page | Controls |
|---|---|
| General | Launch at login, menu bar, background daemon, terminal tools, preferred external terminal (system default, Terminal, iTerm2, Ghostty, Warp, WezTerm, Alacritty, Kitty, or a custom app), browser login bridge, Docker host conflict repair, light or dark appearance |
| Engine & Daemon | Dory, detected external, or custom socket backend; restart; CPU; memory; amd64 support; experimental GPU; local daemon status |
| Resources | Data drive, reveal, backup, verify, restore, select, grow, per-process memory, Mac capacity |
| Machines | Host environment allow-list and the file-sharing boundary for persistent and sandbox machines |
| Auto-Idle | Availability mode, delay, blockers, and wake notifications |
| Network | Domains, suffix, macOS authorization, low ports, resolver and proxy ports, LAN and Tailscale access |
| USB Devices | Scan, attach, detach, and remember USB/IP attachments per machine |
| Local Tools | Stable and preview CLI capabilities with copyable commands |
| Migrate & Compare | Source selection, read-only inventory, preflight, import, and product comparison |
| Managed | JSON defaults for engine, DNS, Auto-Idle, sandbox file sharing, and telemetry policy |
| About | App version and build |

The menu bar can also start and stop containers and Compose projects, open the app, and show engine,
Kubernetes, and machine state.

## Engine backends

| Backend | Purpose |
|---|---|
| Dory daemon | Full local product: shared engine, machines, Kubernetes, storage, networking, Auto-Idle, and agents |
| Existing engine | Use a detected Docker Desktop, OrbStack, Colima, Rancher Desktop, or Podman socket while keeping Dory's native container UI |
| Custom socket | Connect the native UI to a selected Docker-compatible Unix socket |

Linux machines and built-in Kubernetes require the Dory daemon backend. The full Dory engine uses a
Hypervisor.framework path on macOS 15 or later and a bundled Virtualization.framework fallback on
macOS 14.

## Security and privacy

- No Dory account or sign-in
- No telemetry
- No required cloud service or remote control plane
- Localhost-only publishing by default
- Explicit macOS authorization before system networking changes
- A removable plan for Dory-owned resolver, certificate, and packet-filter rules
- No host file sharing in agent sandboxes by default
- Named environment-variable allow-list for new machines
- Redacted support bundles
- Signed and notarized release app, signed Sparkle updates, release manifest, and CycloneDX SBOM

SSH-agent forwarding is available at `/run/host-services/ssh-auth.sock`. Mount it only into trusted
containers because any process with access can ask your agent to sign data.

```sh
docker run --rm \
  -v /run/host-services/ssh-auth.sock:/agent.sock \
  -e SSH_AUTH_SOCK=/agent.sock \
  your-image ssh-add -L
```

## Current boundaries

- Apple Silicon is the only qualified host architecture. Intel support is planned for a later
  release after dedicated hardware validation.
- Desktop Linux provides managed Debian 13, Ubuntu 24.04 LTS, and Kali rolling Xfce arm64 profiles.
- Headless Dory Linux remains Alpine-based arm64 with an initial root `/bin/sh` login.
- In-guest Venus/Vulkan acceleration is experimental. Host AI services work without it.
- USB/IP attach and replay are available but may require macOS user authorization and compatible
  guest support.
- Audio passthrough is not part of the current release.
- Agent sandbox is preview, and its `outbound` policy is not yet narrower than full egress.
- Specialized Docker extensions may depend on another product's private paths. Use `dory compat`
  and report the exact tool and version when that happens.

See [COMPATIBILITY.md](COMPATIBILITY.md) for the tested product contract.

## Uninstall and reinstall

Ordinary uninstall stops Dory services and removes app-owned runtime and shell integration. It does
not delete the selected `.dorydrive`, so reinstalling can reconnect to existing workload data.

```sh
brew uninstall --cask Augani/dory/dory
```

For a direct installation, run `dory uninstall` before deleting Dory.app. Deleting containers,
volumes, machines, snapshots, or the data drive remains a separate explicit action.

## Build and test from source

```sh
git clone https://github.com/Augani/dory.git
cd dory
scripts/build.sh
scripts/test.sh
```

The source build is lean by default. Use
`DORY_DESKTOP_BUNDLE_MODE=all scripts/build.sh` to include all three verified graphical desktop
images. The two modes are intentionally all-or-none so an app labeled all-inclusive cannot silently
ship a missing distribution.

`scripts/test.sh` is the single public test entrypoint. It covers the Rust workspace, Swift packages,
app tests, UI tests, CLI contracts, and public repository checks. Release qualification adds signed
distribution, clean-install, live engine, network, filesystem, migration, compatibility, endurance,
and notarization gates.

| Path | Contents |
|---|---|
| `Dory/` | Native SwiftUI app and runtime integration |
| `dory-core-swift/` | Daemon, operations, networking, and shared Swift packages |
| `dory-core/` | Rust guest agent, data plane, sync, and FFI components |
| `Packages/ContainerizationEngine/` | Virtual machine engine and device implementations |
| `guest/` | Reproducible Linux guest inputs |
| `website/` | Human and machine-readable GitHub Pages source |
| `scripts/dory` | Public CLI and agent contract |
| `scripts/test.sh` | Public test entrypoint |

## Support and contribution

Before opening an issue, collect the smallest useful evidence:

```sh
dory version
dory doctor --active
dory support bundle --json --active
```

Include the Dory version, macOS version, Mac model, affected command or tool, and the redacted bundle
path when appropriate. [Open an issue](https://github.com/Augani/dory/issues/new) or read
[CONTRIBUTING.md](CONTRIBUTING.md) to help improve Dory.

## License

[GPL-3.0](LICENSE) © 2026 Dory contributors.
