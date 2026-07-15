<p align="center">
  <img src="website/public/logo.svg" width="120" alt="Dory logo">
</p>

<h1 align="center">Dory</h1>

<p align="center">
  <b>Docker and Linux containers, native to your Mac.</b><br>
  A free, open-source SwiftUI app with its own container engine, Docker tools, Kubernetes tooling,
  and Linux machines.
</p>

<p align="center">
  <a href="https://github.com/Augani/dory/releases/latest"><img src="https://img.shields.io/github/v/release/Augani/dory?color=2E9BF5" alt="Latest release"></a>
  <a href="https://github.com/Augani/dory/stargazers"><img src="https://img.shields.io/github/stars/Augani/dory?style=flat&logo=github&color=2E9BF5" alt="GitHub stars"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPLv3-blue.svg" alt="License: GPL v3"></a>
  <img src="https://img.shields.io/badge/Apple%20silicon-macOS%2014%2B-lightgrey" alt="Apple silicon, macOS 14 or later">
</p>

> Dory 0.3 is Apple-silicon-first. Intel Mac support is planned for a later release and is not
> included in current downloads or Homebrew installs.

![Dory interface](website/public/demo.gif)

## Highlights

- **Docker-compatible workflow.** Dory bundles the Docker CLI, Buildx, Compose v2, and `kubectl`,
  registers a `dory` Docker context, and exposes its socket at `~/.dory/dory.sock`.
- **One shared Linux VM.** Containers share a persistent engine instead of creating a VM for every
  workload. The engine uses Apple virtualization APIs and reports free guest pages back to macOS.
- **Durable local storage.** Images, containers, volumes, networks, machine disks, and snapshots
  live in one managed `.dorydrive` on your Mac. Runtime caches and sockets remain replaceable.
- **Native Mac interface.** Manage containers, images, volumes, networks, Compose projects,
  Kubernetes resources, and Linux machines from a SwiftUI app with no Electron runtime.
- **Linux machines.** Create Ubuntu, Debian, Fedora, Alpine, and Arch machines with terminals,
  snapshots, resource controls, and development recipes.
- **Migration.** Import images, volumes, networks, and container definitions from an existing local
  Docker-compatible engine after reviewing Dory's preflight report.
- **Local networking.** Published ports use localhost, while optional `*.dory.local` domains and
  trusted local HTTPS are available through an explicit one-time system integration step.
- **Diagnostics and recovery.** `dory doctor`, `dory repair`, `dory disk`, `dory routes`, and
  support bundles make the engine inspectable without deleting user data.
- **Private by default.** No account, telemetry, or paid tier. Dory is GPL-3.0 software.

See [COMPATIBILITY.md](COMPATIBILITY.md) for the supported surface and current limitations.

## Install

### Homebrew

```sh
brew install --cask Augani/dory/dory
```

Open Dory once after installation. The app installs its bundled command-line tools and creates the
`dory` Docker context automatically.

### Direct download

Download the notarized Apple Silicon DMG from
[GitHub Releases](https://github.com/Augani/dory/releases/latest), drag Dory to Applications, and
open it.

Release assets include:

| Asset | Purpose |
|---|---|
| `Dory-x.y.z-arm64.dmg` | Recommended Apple Silicon installer |
| `Dory-x.y.z-arm64.zip` | Full app archive |
| `Dory-x.y.z-lite.zip` | App-only build for an existing Docker-compatible engine |
| `dory-engine-x.y.z-arm64.tar.gz` | Headless Dory engine |

## Quick start

After Dory reports that the engine is ready:

```sh
docker context use dory
docker run --rm hello-world
docker compose up
```

Useful diagnostics:

```sh
dory doctor --active
dory disk
dory routes
dory repair
```

## Data and uninstall behavior

The default data drive is:

```text
~/Library/Application Support/Dory/Dory.dorydrive
```

Ordinary uninstall does not delete this drive. This preserves containers, images, volumes,
networks, and machines if the app is reinstalled. Workload deletion remains an explicit action.

Homebrew uninstall:

```sh
brew uninstall --cask Augani/dory/dory
```

For a direct installation, run `dory uninstall` before deleting `Dory.app`.

## Engine backends

| Backend | Description |
|---|---|
| **Dory engine** | Default shared-VM engine with bundled tools and persistent storage |
| **Existing engine** | Use a detected local Docker-compatible engine while keeping Dory's UI |
| **Custom socket** | Connect Dory to a user-selected Unix socket |

The full Dory engine uses the raw Hypervisor.framework path on macOS 15 or later and a bundled
Virtualization.framework fallback on macOS 14.

## SSH agent forwarding

The built-in engine exposes `/run/host-services/ssh-auth.sock`. Mount it only into trusted
containers that need the host agent:

```sh
docker run --rm \
  -v /run/host-services/ssh-auth.sock:/agent.sock \
  -e SSH_AUTH_SOCK=/agent.sock \
  your-image ssh-add -L
```

## Requirements

- Apple Silicon Mac.
- macOS 14 Sonoma or later.
- Xcode 26 or later only when building from source.
- At least 8 GiB of memory is recommended for container, Kubernetes, and machine workflows.

## Build from source

```sh
git clone https://github.com/Augani/dory.git
cd dory
scripts/build.sh
scripts/test.sh
```

The test command runs the Rust, Swift package, app, and UI suites. You can also open
`Dory.xcodeproj` in Xcode.

## Repository layout

| Path | Contents |
|---|---|
| `Dory/` | SwiftUI app and Docker-compatible runtime integration |
| `dory-core-swift/` | Daemon, operations, networking, and shared Swift packages |
| `dory-core/` | Rust guest agent, dataplane, sync, and FFI components |
| `Packages/ContainerizationEngine/` | Dory's virtual machine engine and devices |
| `guest/` | Reproducible Linux guest inputs |
| `website/` | Public website source |
| `scripts/test.sh` | Single public test entrypoint |

## Next release

The next release will be driven by real 0.3 user feedback. Priorities are:

- installation, update, sleep/wake, and recovery reliability;
- external-drive, backup, restore, and migration polish;
- VPN, IPv6, local-network, and Kubernetes compatibility;
- lower idle resource use and faster file sharing;
- broader developer-tool compatibility.

Intel Mac support follows after dedicated Intel hardware validation. Graphical Linux-machine
sessions may be explored later; the current machine product is focused on terminal and service
workloads.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[GPL-3.0](LICENSE) © 2026 Dory contributors.
