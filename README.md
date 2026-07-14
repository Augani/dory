<p align="center">
  <img src="website/public/logo.svg" width="120" alt="Dory logo">
</p>

<h1 align="center">Dory</h1>

<p align="center">
  <b>Docker &amp; Linux containers, native to your Mac.</b><br>
  A free, open-source alternative to Docker Desktop and OrbStack. One self-contained SwiftUI app
  that ships its own engine, Docker tools, Kubernetes tooling, and one shared VM for all
  containers.
</p>

> **Platform focus:** the production release is for Apple Silicon Macs. Intel support is a later
> roadmap phase and is not included in current public artifacts or Homebrew installs.

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
  not a balloon that never deflates). Reproduce the current measurements with
  [`scripts/benchmark-compare.sh`](scripts/benchmark-compare.sh) and the public
  [benchmark playbook](BENCHMARKS.md); Dory does not publish a memory multiplier until total
  process-tree measurements against current competitors are repeatable.
- **Designed to stay quiet at idle.** A native app with no indexers, bundled browser, or
  phone-home loop. Every release candidate must pass the attributed eight-hour CPU/RSS/FD plateau
  gate; exact numbers are published only with the matching immutable-candidate evidence.
- **Free for everyone, forever.** No per-seat license, no "commercial use" tier, no account,
  no sign-in. GPL-3.0, full source right here. (A [sourced comparison](website/public/comparison.md)
  exists if you want one, so judge for yourself.)
- **Your `docker` CLI just works, even on a clean Mac.** Dory bundles the Docker CLI, Buildx,
  Compose, and `kubectl`, serves the Docker API on `~/.dory/dory.sock`, and registers a `dory`
  Docker context. `docker run`, `docker compose`, your existing scripts and tools drive it
  unchanged, with the engine socket promoted over vsock so stdout, stderr, attach/exec, and stdin
  EOF behave like a normal Docker daemon.
- **One managed data drive.** Images, containers, named volumes, custom networks, machine disks,
  snapshots, and local exports live together at
  `~/Library/Application Support/Dory/Dory.dorydrive`. Replaceable sockets, logs, kernels, and VM
  boot state stay in `~/.dory`; deleting or rebuilding that runtime state does not delete workloads.
  Dory remembers the selected drive outside that cache and binds external drives to their APFS
  volume UUID, so a renamed volume is rediscovered while a missing or same-name replacement volume
  fails closed instead of producing a fresh empty Docker store.
  Docker storage starts at a sparse 128 GiB logical capacity and can grow safely to 2 TiB from
  Settings or with `dory data grow GIB`; `dory data capacity` reports logical capacity separately
  from physical Mac storage. Dory refuses shrinking instead of risking an ext4 truncation.
  Homebrew uninstall and `--zap` also preserve the data drive, so removing the app is never an
  implicit request to erase containers or volumes. To move `DORY_DATA_DRIVE` outside Dory's
  Application Support directory, it must be a `.dorydrive` on mounted local APFS storage under
  `/Volumes`; privacy-protected Desktop, Documents, Downloads, iCloud, and CloudStorage paths are
  rejected before the engine starts so a
  cold launch cannot depend on a transient macOS permission grant.
- **Full-drive backup that does not inflate sparse disks.** With the engine stopped,
  `dory data backup ./Dory-Backup.dorybackup` writes bounded content-addressed chunks to a private
  sibling partial, reads every chunk back, and publishes the archive only after its
  manifest-bound completion marker is durable. `dory data verify` rejects incomplete, truncated,
  tampered, or path-escaping archives. `dory data restore BACKUP TARGET.dorydrive` rebuilds sparse
  extents and filesystem metadata into a new partial drive, independently inventories it, and
  refuses to replace any existing drive. Full-drive backups intentionally live outside the drive
  they protect; `dory data use TARGET.dorydrive` is a separate explicit selection step. If the
  daemon is loaded, that command deliberately stops the engine and machine VMs, switches the
  verified idle drive, then restarts and probes `doryd`; a drive attached to another engine is
  rejected.
- **Native, not Electron.** One Swift/SwiftUI app: menu-bar agent + full dashboard, launch
  animation to launch-at-login, light and dark. No Chromium, no Node, no telemetry.

## What you get

**Docker, complete**
- Containers with live stats, logs, embedded terminal, env inspection; create / start / stop /
  restart / delete from the UI or CLI.
- Images: pull, **build** from a context folder, run, prune, **registry sign-in**, full inspect.
- Volumes (with a file browser) and networks (subnet / gateway / attached-container inspect).
- Bind mounts keep native macOS paths for both your home and attached drives under `/Volumes`, so
  `-v /Volumes/MySSD/project:/app` targets the real external disk instead of guest-only storage.
- **Compose**: `up` / `down` with `.env` + variable interpolation, `depends_on` ordering, and
  `service_healthy` waiting.
- Bundled host tools: Docker CLI, Buildx, Docker Compose v2, and `kubectl` ship inside Dory.app;
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
- `dory mode` and `dory idle status` control daemon-owned Auto-Idle. `doryd` keeps the Docker socket
  available while the heavy engine sleeps, coalesces concurrent wake requests, records blockers and
  every sleep/wake transition, and stops only after the configured policy proves the engine idle.
- The Health screen explains why Dory is awake, shows the incident timeline, and exposes bounded
  in-place repairs for DNS, domains, routes, published ports, and the guest agent. A workload-aware
  engine restart is separate and explicit.

**Kubernetes, one click**
- k3s inside the shared VM with selectable Kubernetes versions.
- Cluster browser: pods, deployments, services, config maps, secrets, ingresses, all with live
  health, pod exec, scale / restart / rollout controls, and `kubectl apply` from the app.

**Linux machines**
- Full Ubuntu / Debian / Fedora / Alpine / Arch VMs with snapshots, terminal access, and
  use-case recipes (Node, Python, Go, Rust, …) that provision the machine ready-to-code,
  plus a composer to hand-pick runtimes, tools, and packages. Machines are real isolated Linux VMs,
  not Docker containers.
- The full app includes a supported baseline kernel/rootfs pair. Custom machine images use the
  fail-closed [signed machine-image contract](MACHINE_IMAGE_CONTRACT.md); arbitrary DKMS or
  kernel replacement inside the immutable Docker engine guest is intentionally unsupported.
- Every machine has a `name.dory.local` address. The UI shows the copyable terminal command
  (`dory ssh <name>` or `dory machine shell <name>`), and custom addresses can be assigned during
  creation.
- Running machines show real guest CPU and used/total memory on the two-second UI refresh. The
  versioned `dorydctl machine stats <name>` JSON contract also reports network RX/TX, block I/O,
  process count, and uptime; stopped or unreadable machines show `—`, never fabricated zeroes.
- Your home directory is shared into the engine, so `docker run -v ~/project:/app` just works.
  Host shares intentionally use plain virtio-fs: DAX host-share options are rejected until Dory can
  quiesce guest CPUs across a failed reverse invalidation without risking stale reads or late writes.

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
- **In-guest GPU compute (experimental, Apple silicon)**: an opt-in virtio-gpu **Venus/Vulkan** path — containers
  running Mesa's Venus driver see the Apple GPU through virglrenderer → MoltenVK → Metal
  (`vulkaninfo` enumerates it, compute queues included). Toggle it in Settings; the renderer ships
  inside the app. Not raw GPU passthrough; fences and heavy async workloads are still maturing.
- **Intel (x86/amd64) images** run on Apple silicon through Dory's bundled FEX runtime — enabled by
  default for new installs, on the same engine and network, with nested seccomp support for package
  managers and BuildKit. No separate x86 VM or Rosetta install. The accepted runtime, data-drive,
  and support boundaries are documented in
  [the Apple Silicon architecture decision](docs/architecture/apple-silicon-runtime.md).

**Zero-friction start**
- On supported Macs, Dory ships its bundled engine, kernel, networking helper, Docker tools,
  Compose, and Kubernetes tooling. No Docker Desktop, Colima, OrbStack, Homebrew, or Apple
  `container` install is required for the built-in shared-VM path.
- **Migration** imports images, container writable-layer files, named-volume data, custom networks,
  and full container definitions
  from Docker Desktop or OrbStack, preserving running/stopped state. Its preflight report lists what
  transfers, what needs attention, and exact volume/capacity requirements; collisions and
  nonportable contracts fail closed instead of overwriting unrelated Dory data. Empty, detached,
  contract-compatible same-name volumes can be adopted after preflight while preserving labels;
  failed adoption restores the original empty volume metadata. Non-empty or attached conflicts
  remain blocked. Dory never pauses source workloads implicitly: a running container with writable
  volume or container-layer changes must be stopped or paused by the user before its data is copied,
  preventing torn database and filesystem snapshots. Sparse engine disks default to 128 GiB, can
  grow explicitly to 2 TiB, and use virtio discard at boot/shutdown to return deleted ext4 blocks
  to macOS before capacity admission.
- **Managed settings** exposes local, MDM-friendly defaults for engine route, domains, DNS/proxy
  ports, Auto-Idle, file sharing, scoped mounts, credential-store hiding, env allow-list, and
  telemetry mode `none`.

See [COMPATIBILITY.md](COMPATIBILITY.md) for the honest, per-feature status matrix.

## Install

```sh
brew install --cask Augani/dory/dory
```

Homebrew links the `dory` CLI and installs Dory's bundled Docker, Compose, Buildx, and `kubectl`
integration. Open Dory once to start the engine; no separate Docker installation is required. The
daemon and Docker socket remain available after the window closes or the app exits unless you
explicitly turn off **Keep doryd running after quit** in Settings.

…or download the notarized `.dmg` from [Releases](https://github.com/Augani/dory/releases/latest),
drag Dory to Applications, and open it. First launch guides you through the rest; supported Macs do
not need a separate Docker install.

### Apple Silicon downloads

The production release ships arm64 artifacts only:

| Asset | What it is |
|---|---|
| `Dory-x.y.z-arm64.dmg` / `.zip` | **Full app** optimized for Apple silicon — zero prerequisites, works on a clean Mac |
| `Dory-x.y.z.dmg` / `.zip` | Compatibility alias for the arm64 build, used by the Homebrew cask |
| `Dory-x.y.z-lite.zip` | **App only** (~6 MB) — front an engine you already run (Colima, Docker Desktop, OrbStack, Rancher Desktop, Podman) |
| `dory-engine-x.y.z-arm64.tar.gz` | **Headless engine runtime**, no GUI — `./dory-engine start`, then `docker context use dory-engine`. Its private runtime state stays under `~/.dory/standalone`; FEX/amd64 is on by default and `--no-amd64` is the opt-out. |

## Uninstall

Homebrew stops Dory and removes its CLI, Docker context, plugins, LaunchAgent, and approved network
helper automatically:

```sh
brew uninstall --cask Augani/dory/dory
```

For a DMG installation, quit Dory and run `dory uninstall` before deleting `Dory.app`. Ordinary
uninstall and Homebrew `--zap` both preserve the selected `.dorydrive`, including images,
containers, volumes, networks, and machines. Dory never treats app removal as permission to erase
workload data.

## Engine backends

Dory defaults to its own engine, and **Settings → Engine Backend** switches it Colima-style — no
reinstall, no environment variables:

| Backend | Model |
|---|---|
| **Dory engine** *(default)* | One persistent `dockerd`-in-VM for all containers. macOS 15+ uses `dory-hv`, Dory's own Hypervisor.framework engine; macOS 14 uses the bundled Virtualization.framework `dory-vmm` fallback. Standalone: no Docker install required. Memory reclaim, x86 emulation, Kubernetes, and Linux machines. |
| **Existing engine** | Transparent proxy to an engine already on your Mac — auto-detects Colima, Docker Desktop, OrbStack, Rancher Desktop, and Podman sockets. Dory becomes the GUI, domains, and port UX on top. |
| **Custom socket** | Point Dory at any Docker-compatible unix socket. |

(`DORY_RUNTIME=shared|docker` remains as a development override.)

### SSH agent forwarding

Dory's built-in engine exposes the familiar guest socket
`/run/host-services/ssh-auth.sock`. Mount it only into containers that need your host agent:

```sh
docker run --rm \
  -v /run/host-services/ssh-auth.sock:/agent.sock \
  -e SSH_AUTH_SOCK=/agent.sock \
  your-image ssh-add -L
```

The socket is a dedicated same-user vsock bridge to the macOS `SSH_AUTH_SOCK`; it is not an
arbitrary host Unix-socket passthrough and is not mounted into containers automatically. A process
that can access an SSH agent can request signatures, so grant this mount only to trusted workloads.

## Requirements

> **Intel roadmap:** Intel implementation work remains in the source tree, but it is deliberately
> outside the current production contract. Public releases, Sparkle updates, qualification, and the
> Homebrew cask are Apple-Silicon-only until a later Intel hardware campaign is complete.

- **Requires an Apple Silicon Mac running macOS 14 (Sonoma) or later.**
- **The raw `dory-hv` engine needs macOS 15 (Sequoia) or later.** It provides Dory's custom
  shared-VM VMM path.
- **On macOS 14**, a full bundle routes the shared Docker VM through the bundled `dory-vmm`
  Virtualization.framework fallback instead of trying to launch an incompatible `dory-hv`.
- **On an install without bundled engine assets**, Dory runs as a native app against any
  Docker-compatible engine you install (Colima, Docker Desktop, Rancher Desktop, Podman, or
  OrbStack).
- Xcode 26 or later for development; public release builds are pinned to Xcode 26.6.

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

Latest local snapshot on an Apple M2 Pro, 16 GB RAM, macOS 27.0 build 26A5368g
(July 8, 2026; runs were isolated one engine at a time):

| Engine | Docker server | CPU median, 256 MiB sha256 | C2C network median | Bind mount, 2000 files |
|---|---:|---:|---:|---:|
| Dory 0.3.1 build 2 | 27.5.1 | 2.1020 s | 97.7721 Gbps | 0.6880 s |
| OrbStack | 29.4.0 | 1.7190 s | 90.1203 Gbps | 0.2220 s |
| Colima | 29.5.2 | 1.5750 s | 80.9901 Gbps | 0.1590 s |

Raw artifacts are under `.benchmark-results/20260708T184829Z-32856`,
`.benchmark-results/20260708T185520Z-45964`, and `.benchmark-results/20260708T185955Z-63870`.
The same runs captured idle-memory rows, but those rows are intentionally not summarized here
because macOS compression made several host-memory deltas negative during the sequential runs.

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
