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
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey" alt="Platform">
</p>

> ⭐ **If Dory saves you memory (or money), please [star the repo](https://github.com/Augani/dory). It genuinely helps others find it.**

![Dory: containers, images, volumes, networks, and Linux machines](website/public/demo.gif)

## Why Dory

- **Its own engine, built for the Mac.** Dory ships `dory-hv`, its own hypervisor engine on
  Apple's Hypervisor.framework: one persistent Linux VM runs *everything*, instead of one VM per
  container, and memory is genuinely handed back to macOS as workloads idle (free-page reporting,
  not a balloon that never deflates). Measured **~4.7× less idle memory** than per-container VMs
  (2 containers: ~122 MB vs ~574 MB), and the gap widens with every container you add.
  Measure it yourself with [`scripts/benchmark-compare.sh`](scripts/benchmark-compare.sh) and the
  public [benchmark playbook](BENCHMARKS.md).
- **Small and silent, permanently.** A native app with ~0% idle CPU. No indexers, no
  phone-home, no fans. That's a design constraint, not a version note.
- **Free for everyone, forever.** No per-seat license, no "commercial use" tier, no account,
  no sign-in. GPL-3.0, full source right here. (A [sourced comparison](website/public/comparison.md)
  exists if you want one, so judge for yourself.)
- **Your `docker` CLI just works, even on a clean Mac.** Dory bundles the Docker CLI, Compose
  plugin, and `kubectl`, serves the Docker API on `~/.dory/dory.sock`, and registers a `dory`
  Docker context. `docker run`, `docker compose`, your existing scripts and tools drive it
  unchanged, with the engine socket promoted over vsock so stdout, stderr, attach/exec, and stdin
  EOF behave like a normal Docker daemon.
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
- Bundled host tools: Docker CLI, Docker Compose v2, and `kubectl` are shipped inside Dory.app;
  while doryd is running it keeps `~/.dory/bin` and the `dory` Docker context reconciled so clean
  Macs do not need Docker Desktop, Homebrew, or a manual install step.

**Self-diagnosing runtime**
- `dory doctor`, `dory network`, and `dory mount` check the socket, Docker context, registry,
  DNS, published ports, `*.dory.local` routes, bind mounts, file-change visibility, disk, memory,
  and helper setup, with JSON output for support and automation.
- `dory disk` and `dory routes` show where Docker/Dory storage is going and what owns each
  published port or local domain.
- `dory network --save-probe registry.company.test:443` stores credential-free private network
  probes for VPN, split-DNS, and internal-registry checks.
- `dory cleanup` shows safe cleanup actions for stopped containers, dangling images, build cache,
  and oversized logs; it only changes state with `--apply`, and volume cleanup is opt-in.
- `dory repair` offers non-destructive socket, context, DNS, route, domain, port, dockerd, engine,
  and guest-agent recovery actions before users reach for a full reset. `dory repair all --apply`
  only touches subsystems that are actually unhealthy.
- `dory support bundle` writes one redacted diagnostic zip and prints the path to attach to a
  GitHub issue; `dory logs collect` is the same support-safe collection flow for users who think
  in logs first.
- `dory mode` and `dory idle status` expose the Auto-Idle foundation; `dory idle proxy` can run
  the opt-in always-listening socket proxy for headless dogfooding. The proxy wakes a sleeping
  headless engine on Docker API use, forwards the request, and records its idle/wake state.
- In the app-managed path, Dory can attach to a sleeping `doryd` without waking `dory-hv`, and the
  idle policy stops an empty engine while keeping Docker and machine state on disk.

**Kubernetes, one click**
- k3s inside the shared VM with selectable Kubernetes versions.
- Cluster browser: pods, deployments, services, config maps, secrets, ingresses, all with live
  health, pod exec, scale / restart / rollout controls, and `kubectl apply` from the app.

**Linux machines**
- Full Ubuntu / Debian / Fedora / Alpine / Arch VMs with snapshots, terminal access, and
  use-case recipes (Node, Python, Go, Rust, …) that provision the machine ready-to-code,
  plus a composer to hand-pick runtimes, tools, and packages. Machines are real isolated Linux VMs,
  not Docker containers.
- Every machine has a `name.dory.local` address. The UI shows the copyable terminal command
  (`dory ssh <name>` or `dory machine shell <name>`), and custom addresses can be assigned during
  creation.
- Your home directory is shared into the engine, so `docker run -v ~/project:/app` just works.

**Networking that disappears**
- Published ports on `localhost`, automatic **`*.dory.local` domains** for every container, and
  local **HTTPS** issued by a local CA. All consent-gated, nothing installed silently.
- While `doryd` is running it reconciles container domains, loopback routes, low-port redirects,
  and machine routes for assigned VM addresses, so the app does not need to stay open for local
  networking.
- Internal guest control ports stay private; only Docker-published ports and explicit Dory routes
  are exposed on macOS loopback.
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
- On supported Macs, Dory ships its bundled engine, kernel, networking helper, Docker tools,
  Compose, and Kubernetes tooling. No Docker Desktop, Colima, OrbStack, Homebrew, or Apple
  `container` install is required for the built-in shared-VM path.
- **Migration** imports your images and containers from Docker Desktop or OrbStack, with a preflight
  confidence report that lists what transfers, what needs attention, and the estimated image disk.
- **Managed settings** exposes local, MDM-friendly defaults for engine route, domains, DNS/proxy
  ports, Auto-Idle, file sharing, scoped mounts, credential-store hiding, env allow-list, and
  telemetry mode `none`.

See [COMPATIBILITY.md](COMPATIBILITY.md) for the honest, per-feature status matrix.

## Install

```sh
brew install --cask Augani/dory/dory
```

…or download the notarized `.dmg` from [Releases](https://github.com/Augani/dory/releases/latest),
drag Dory to Applications, and open it. First launch guides you through the rest; supported Macs do
not need a separate Docker install.

### Pick your flavor

Every release ships native app artifacts, so you install only what you need:

| Asset | What it is |
|---|---|
| `Dory-x.y.z-arm64.dmg` / `.zip` | **Full app** optimized for Apple silicon — zero prerequisites, works on a clean Mac |
| `Dory-x.y.z-x86_64.dmg` / `.zip` | **Full app** optimized for Intel Macs — zero prerequisites, works on a clean Mac |
| `Dory-x.y.z-universal.dmg` / `.zip` | **Full app** for both Apple silicon and Intel |
| `Dory-x.y.z.dmg` / `.zip` | Compatibility alias for the universal build, used by the Homebrew cask |
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
scripts/test-dory-doctor.sh # fast diagnostics, bundle, repair, and Auto-Idle proxy smoke
scripts/p0-smoke.sh     # strict release smoke against a running Dory socket
scripts/nonnative-build-smoke.sh # focused linux/amd64-on-arm64 BuildKit smoke
scripts/benchmark-compare.sh --dry-run # auditable cross-engine benchmark plan
```

Or open `Dory.xcodeproj` in Xcode and Run.

### Optional system integration

These need a one-time admin grant (the same one OrbStack asks for) and are run by you, never
silently:

```sh
scripts/enable-networking.sh    # *.dory.local domains + trust the local CA
scripts/enable-kubernetes.sh    # bootstrap k3s in the shared VM
```

### Diagnostics

When something feels off, start here:

```sh
dory doctor --active
dory network --active
dory mount
dory disk
dory cleanup
dory routes
dory repair
dory network --list-probes
dory support bundle
dory logs collect --json
dory idle status
dory idle proxy --foreground
```

For scripted checks, add `--json` to the commands that support it.
For release benchmark evidence, use the installed app path so the raw artifacts record the exact
build under test:

```sh
BENCH_WORKDIR="$PWD/.benchmark-results" \
scripts/benchmark-compare.sh \
  --dory-app /Applications/Dory.app \
  --engines dory,orbstack,docker-desktop \
  --metrics memory,cpu,network,fs \
  --memory-counts 0,1,3,5,10
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

For the 0.3 local release, the focus is clean-Mac packaging, benchmark evidence, compatibility
smoke, Linux machines, migration confidence, managed settings, and agent-safe local foundations.
Remote engines, cloud backup/relay, and phone workflows are deliberately after the local release is
solid. Follow the [releases](https://github.com/Augani/dory/releases), and open an issue if you want
to shape what comes first.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[GPL-3.0](LICENSE) © 2026 Dory contributors.
