<p align="center">
  <img src="docs/logo.svg" width="120" alt="Dory logo">
</p>

<h1 align="center">Dory</h1>

<p align="center">
  <b>Docker &amp; Linux containers, native to your Mac.</b><br>
  A free, open-source alternative to Docker Desktop and OrbStack. One self-contained SwiftUI app
  that ships its own engine, Docker tools, Kubernetes tooling, and one shared VM for a fraction
  of the memory.
</p>

<p align="center">
  <a href="https://github.com/Augani/dory/stargazers"><img src="https://img.shields.io/github/stars/Augani/dory?style=flat&logo=github&color=2E9BF5" alt="GitHub stars"></a>
  <a href="https://github.com/Augani/dory/releases/latest"><img src="https://img.shields.io/github/v/release/Augani/dory?color=2E9BF5" alt="Latest release"></a>
  <a href="https://github.com/Augani/dory/releases"><img src="https://img.shields.io/github/downloads/Augani/dory/total?color=34D058" alt="Downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPLv3-blue.svg" alt="License: GPL v3"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey" alt="Platform">
</p>

> ⭐ **If Dory saves you memory (or money), please [star the repo](https://github.com/Augani/dory). It genuinely helps others find it.**

![Dory: containers, images, volumes, networks, and Linux machines](docs/demo.gif)

## Why Dory

- **One VM, all your containers.** Dory builds on [Apple's open-source container stack](https://github.com/apple/containerization)
  and boots a single persistent Linux micro-VM that runs *everything*, instead of one VM per
  container. Measured **~4.7× less idle memory** than per-container VMs (2 containers: ~122 MB vs
  ~574 MB), and the gap widens with every container you add
  ([methodology](docs/research/benchmark-methodology.md)).
- **Small and silent, permanently.** A ~6 MB native app with ~0% idle CPU. No indexers, no
  phone-home, no fans. That's a design constraint, not a version note.
- **Free for everyone, forever.** No per-seat license, no "commercial use" tier, no account,
  no sign-in. GPL-3.0, full source right here. (A [sourced comparison](docs/comparison.md) exists
  if you want one, so judge for yourself.)
- **Your `docker` CLI just works, even on a clean Mac.** Dory bundles the Docker CLI, Compose
  plugin, and `kubectl`, serves the Docker API on `~/.dory/dory.sock`, and registers a `dory`
  Docker context. `docker run`, `docker compose`, your existing scripts and tools drive it
  unchanged.
- **Native, not Electron.** One Swift/SwiftUI app: menu-bar agent + full dashboard, launch
  animation to launch-at-login, light and dark. No Chromium, no Node, no telemetry.

## What you get

**Docker, complete**
- Containers with live stats, logs, embedded terminal, env inspection; create / start / stop /
  restart / delete from the UI or CLI.
- Images: pull, **build** from a context folder, run, prune, **registry sign-in**, full inspect.
- Volumes (with a file browser) and networks (subnet / gateway / attached-container inspect).
- **Compose**: `up` / `down` with `.env` + variable interpolation, `depends_on` ordering, and
  `service_healthy` waiting.
- Bundled host tools: Docker CLI, Docker Compose v2, and `kubectl` are shipped inside Dory.app
  and linked into `~/.dory/bin` only when you ask for shell integration.

**Kubernetes, one click**
- k3s inside the shared VM with selectable Kubernetes versions.
- Cluster browser: pods, deployments, services, config maps, secrets, ingresses, all with live
  health, pod exec, scale / restart / rollout controls, and `kubectl apply` from the app.

**Linux machines**
- Full Ubuntu / Debian / Fedora / Alpine / Arch VMs with snapshots, terminal access, and
  use-case recipes (Node, Python, Go, Rust, …) that provision the machine ready-to-code,
  plus a composer to hand-pick runtimes, tools, and packages.
- Your home directory is shared into the engine, so `docker run -v ~/project:/app` just works.

**Networking that disappears**
- Published ports on `localhost`, automatic **`*.dory.local` domains** for every container, and
  local **HTTPS** issued by a local CA. All consent-gated, nothing installed silently.
- **Apple GPU AI bridge**: run Metal-backed services on macOS, such as Ollama, LM Studio, MLX, or
  llama.cpp, and call them from Linux containers at `host.dory.internal` on ports `11434`, `1234`,
  or `18190`. In-guest GPU compute is an experimental virtio-gpu Venus/Vulkan path with a
  fail-closed virglrenderer/MoltenVK gate that release builds can bundle when compatible pinned
  artifacts are available; it is not raw Apple GPU passthrough.
- x86/amd64 images run on Apple silicon via emulation.

**Zero-friction start**
- First launch starts Dory's bundled engine, kernel, networking helper, Docker tools, Compose,
  and Kubernetes tooling. No Docker Desktop, Colima, OrbStack, Homebrew, or Apple `container`
  install is required for the built-in shared-VM path.
- **Migration** imports your images and containers from Docker Desktop or OrbStack.

See [COMPATIBILITY.md](COMPATIBILITY.md) for the honest, per-feature status matrix.

## Install

```sh
brew install --cask Augani/dory/dory
```

…or download the notarized `.dmg` from [Releases](https://github.com/Augani/dory/releases/latest),
drag Dory to Applications, and open it. First launch guides you through the rest; supported Macs do
not need a separate Docker install.

## Engine backends

Dory selects a backend automatically; `DORY_RUNTIME` can override the shipping shared-VM, Docker,
or mock paths for development. Apple `container` is detected for comparison and future backend work,
but Dory's full Docker/Compose/Kubernetes feature set currently runs through the shared VM.


| `DORY_RUNTIME` | Backend | Model |
|---|---|---|
| `shared` *(default on supported hosts)* | **Shared VM** | One persistent `dockerd`-in-VM for all containers (OrbStack-style). Standalone: no Docker required. Apple silicon uses `dory-hv`; Intel prefers the raw `dory-hv` tier when signed PVH assets are bundled, then falls back to the Virtualization.framework shared-engine tier when its amd64 assets are available. |
| `apple` *(planned)* | **Apple `container`** | One lightweight micro-VM per container. Detected for benchmarking and future backend work, but not yet a feature-equivalent selectable backend for Compose, Kubernetes, and Linux machines. |
| `docker` | **Docker Engine API** | Transparent proxy to an existing Docker-compatible socket (Docker Desktop, OrbStack, Colima, Rancher Desktop, Podman). Fallback for unsupported hosts or installs without bundled engine assets. |
| `mock` | **Mock** | In-memory sample data for UI development. |

## Requirements

> **Intel engine status:** Dory now builds and routes a universal app with Intel shared-engine
> tiers. The raw `dory-hv` x86 path is implemented and selected first when PVH assets are bundled;
> the Virtualization.framework helper remains the fallback tier. Full Intel readiness still needs
> the physical Intel Mac gates in the roadmap before it is considered finished.

- **Runs on macOS 14 (Sonoma) or later**, universal for Intel and Apple silicon. That matches
  OrbStack's floor, so Dory installs anywhere OrbStack does.
- **The built-in engine on Apple silicon needs macOS 15 (Sequoia) or later** - the full experience:
  Dory's own bundled engine, bundled Docker/Compose/kubectl tools, one shared VM, low memory,
  Kubernetes, Linux machines, `*.dory.local` domains. Nothing else to install. The engine uses
  Apple's in-kernel interrupt API, which is macOS 15+ on Apple silicon, so it cannot run on
  macOS 14.
- **Intel Macs** run the same universal app. Builds with Intel `dory-hv` PVH assets use the
  low-memory raw engine as an Intel beta; builds with only the amd64 VZ assets use the
  Virtualization.framework shared-engine fallback. Full Intel readiness is still hardware-gated.
- **On macOS 14, or any install without bundled engine assets**, Dory runs as a native app against
  any Docker-compatible engine you install (Colima, Docker Desktop, Rancher Desktop, Podman, or
  OrbStack).
- Xcode 26 or later (to build from source).

## Build & run from source

```sh
scripts/build.sh        # compile-check
scripts/test.sh         # full test suite
scripts/shot.sh         # build, launch, and screenshot the window
```

Or open `Dory.xcodeproj` in Xcode and Run.

### Optional system integration

These need a one-time admin grant (the same one OrbStack asks for) and are run by you, never
silently:

```sh
scripts/enable-networking.sh    # *.dory.local domains + trust the local CA
scripts/enable-kubernetes.sh    # bootstrap k3s in the shared VM
```

## Architecture

```
Dory.app (SwiftUI)
      │
      ▼
ContainerRuntime protocol ──► { Shared VM · Docker API · Mock · Apple container (planned) }
      │
      ├─ doryd shim          Docker REST API over ~/.dory/dory.sock
      ├─ Compose engine      YAML → dependency DAG → reconcile
      ├─ engine services     health state machine · event synthesis · anon-volumes
      └─ Net                 LocalCA (TLS) · DomainRouter (*.dory.local) · port forwarding
```

Everything is dependency-light: the HTTP / unix-socket transport, YAML parser, and Docker-API
client and server are hand-rolled, so the build stays small and deterministic. The
`Packages/ContainerizationEngine` package links Apple's `containerization` framework to boot the
Linux VM in-process.

## What's next

Portable dev machines you can back up and restore, remote access to your engine, and sandboxed
environments for AI agents. Follow the [releases](https://github.com/Augani/dory/releases), and
open an issue if you want to shape what comes first.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[GPL-3.0](LICENSE) © 2026 Dory contributors.
