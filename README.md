<p align="center">
  <img src="website/public/logo.svg" width="120" alt="Dory logo">
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

![Dory: containers, images, volumes, networks, and Linux machines](website/public/demo.gif)

## Why Dory

- **Its own engine, built for the Mac.** Dory ships `dory-hv`, its own hypervisor engine on
  Apple's Hypervisor.framework: one persistent Linux VM runs *everything*, instead of one VM per
  container, and memory is genuinely handed back to macOS as workloads idle (free-page reporting,
  not a balloon that never deflates). Measured **~4.7× less idle memory** than per-container VMs
  (2 containers: ~122 MB vs ~574 MB), and the gap widens with every container you add
  ([methodology](website/public/research/benchmark-methodology.md)).
- **Small and silent, permanently.** A native app with ~0% idle CPU. No indexers, no
  phone-home, no fans. That's a design constraint, not a version note.
- **Free for everyone, forever.** No per-seat license, no "commercial use" tier, no account,
  no sign-in. GPL-3.0, full source right here. (A [sourced comparison](website/public/comparison.md)
  exists if you want one, so judge for yourself.)
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
  or `18190`.
- **In-guest GPU compute (experimental)**: an opt-in virtio-gpu **Venus/Vulkan** path — containers
  running Mesa's Venus driver see the Apple GPU through virglrenderer → MoltenVK → Metal
  (`vulkaninfo` enumerates it, compute queues included). Toggle it in Settings; the renderer ships
  inside the app. Not raw GPU passthrough; fences and heavy async workloads are still maturing.
- **Intel (x86/amd64) images** run on Apple silicon via an opt-in QEMU emulation toggle — on
  Dory's own engine, no separate VM.

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

### Pick your flavor

Every release ships three artifacts, so you install only what you need:

| Asset | What it is |
|---|---|
| `Dory-x.y.z.dmg` / `.zip` | **Full app** with Dory's bundled engine — zero prerequisites, works on a clean Mac |
| `Dory-x.y.z-lite.zip` | **App only** (~6 MB) — front an engine you already run (Colima, Docker Desktop, OrbStack, Rancher Desktop, Podman) |
| `dory-engine-x.y.z-arm64.tar.gz` | **Headless engine runtime**, no GUI — `./dory-engine start`, then `docker context use dory-engine`. Colima-style |

## Engine backends

Dory defaults to its own engine, and **Settings → Engine Backend** switches it Colima-style — no
reinstall, no environment variables:

| Backend | Model |
|---|---|
| **Dory engine** *(default)* | One persistent `dockerd`-in-VM for all containers on `dory-hv`, Dory's own Hypervisor.framework engine. Standalone: no Docker install required. Memory reclaim, GPU, x86 emulation, Kubernetes, Linux machines. |
| **Existing engine** | Transparent proxy to an engine already on your Mac — auto-detects Colima, Docker Desktop, OrbStack, Rancher Desktop, and Podman sockets. Dory becomes the GUI, domains, and port UX on top. |
| **Custom socket** | Point Dory at any Docker-compatible unix socket. |

(`DORY_RUNTIME=shared|docker` remains as a development override.)

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
ContainerRuntime protocol ──► { Dory engine (dory-hv) · any Docker-compatible socket }
      │
      ├─ doryd shim          Docker REST API over ~/.dory/dory.sock
      ├─ Compose engine      YAML → dependency DAG → reconcile
      ├─ engine services     health state machine · event synthesis · anon-volumes
      └─ Net                 LocalCA (TLS) · DomainRouter (*.dory.local) · port forwarding

dory-hv (Helpers/dory-hv) — Dory's own VMM on Hypervisor.framework
      ├─ virtio devices      blk · net · vsock · fs (virtiofs) · balloon · rng · gpu (Venus)
      ├─ memory reclaim      free-page reporting → pages handed back to macOS in seconds
      ├─ docker socket       engine.sock served over vsock with full half-close fidelity
      └─ gvproxy sidecar     outbound NAT/DNS + published-port forwards
```

Everything is dependency-light: the HTTP / unix-socket transport, YAML parser, Docker-API
client/server, and the entire VMM (virtio devices, FDT builder, GIC wiring, vsock transport) are
hand-rolled in Swift, so the build stays small and deterministic.

## What's next

Portable dev machines you can back up and restore, remote access to your engine, and sandboxed
environments for AI agents. Follow the [releases](https://github.com/Augani/dory/releases), and
open an issue if you want to shape what comes first.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[GPL-3.0](LICENSE) © 2026 Dory contributors.
