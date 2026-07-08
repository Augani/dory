# Dory Compatibility Matrix

This is the honest, maintained statement of what Dory does, current as of **0.3.0**. The shipping
standalone path is Dory's own engine (`dory-hv`, our VMM on Hypervisor.framework): one Linux VM,
Dory's own socket, bundled Docker/Compose/kubectl tools, and no host Docker install. Settings →
Engine Backend can instead point Dory at any existing Docker-compatible engine (Colima, Docker
Desktop, OrbStack, Rancher Desktop, Podman) or a custom socket, Colima-style.

Legend: ✅ works · 🟡 works with Dory-specific behavior · 🛠️ implemented, activation gated ·
⛔ unsupported / not yet · 🔒 blocked by an external gate.

## Docker Engine API (via Dory's socket `~/.dory/dory.sock`)

On the Docker backend, Dory's socket is a **full transparent proxy**: every request is forwarded
verbatim and the response streamed back unchanged. It is uniformly correct for normal, streaming, and
hijacked (upgrade) endpoints, with all request headers preserved (registry auth, etc.). The
per-endpoint translation notes are retained for the mock runtime and the future Apple `container`
backend model; the shipping shared-VM path fronts a real `dockerd` socket.

| Capability | Status | Notes |
|---|---|---|
| `docker version` / `info` / `_ping` | ✅ | Docker backend: real engine response (transparent passthrough). Apple/mock: Dory-branded. Verified with the real `docker` CLI |
| `docker ps` / list containers | ✅ | Real containers, correct names/status/ports/timestamps; supports `id`, `name`, `status`, `label`, `ancestor`, `before`, `since`, `exited`, `health`, `volume`, `network`, `publish`, and `expose` filters; `size=1` adds `SizeRw`/`SizeRootFs` for `docker ps -s` |
| Container start / stop / restart / remove | ✅ | `POST /containers/{id}/...`, `DELETE /containers/{id}` |
| `docker images` / list | ✅ | Translated from the runtime snapshot (Apple/mock), including `reference`, `label`, `dangling`, `before`, and `since` filters on `/images/json` |
| Container create (with body) | ✅ | image, cmd, env, ports, labels, network/network-disabled DNS, DNS domain, restart policy, platform query, cidfile, runtime handler; image refs starting with `-` rejected at the boundary |
| Container inspect | ✅ | `GET /containers/{id}/json`; includes common create-time `Config`/`HostConfig` fields, port bindings, mounts, and `NetworkSettings.Networks`; `size=1` adds `SizeRw`/`SizeRootFs` for `docker inspect --size` |
| Exec (create + start + inspect) | ✅ | Used by the Compose health prober |
| Image pull | ✅ | `POST /images/create` |
| Image search (`docker search`) | ✅ | `GET /images/search`; Docker/shared-VM backends search through dockerd. Translated backends query Docker Hub (`index.docker.io/v1/search`) and merge the results with the user's matching local images (local entries tagged, deduped first), falling back to local-only when the registry is unreachable. `is-official`/`is-automated`/`stars` filters and `limit` apply to the merged list |
| Registry auth (`docker login`) | ✅ | `POST /auth`; Docker/shared-VM backends validate through dockerd, translated backends persist Docker auth config for subsequent pulls |
| Image tag (`docker tag`) | ✅ | `POST /images/{name}/tag`; Docker/shared-VM backends proxy/forward to dockerd, Apple backend maps to `container image tag` |
| Image push (`docker push`) | ✅ | `POST /images/{name}/push`; Docker/shared-VM backends stream native dockerd progress with registry auth, Apple backend maps to `container image push` |
| Image save / load / commit | ✅ | `GET /images/{name}/get`, `GET /images/get?names=...`, `POST /images/load`, `POST /commit`; Docker/shared-VM backends use daemon-native multi-image save, translated backends use a runtime-provided batch archive when available and otherwise report unsupported |
| Network list / create / remove / connect / disconnect | 🟡 | `GET /networks` includes `id`, `name`, `driver`, `scope`, `type`, and `label` filters on translated backends; create/remove/connect/disconnect endpoints exist, but Apple's `container` CLI has no post-create connect/disconnect command yet |
| Volume list / create / remove / prune | ✅ | `GET /volumes` includes `name`, `driver`, `dangling`, and `label` filters on translated backends; `POST /volumes/create`, `DELETE /volumes/{id}`, `POST /volumes/prune` |
| System disk usage (`docker system df`) | ✅ | `GET /system/df`; translated from runtime snapshot images, containers, volumes, and empty BuildKit cache when unavailable |
| Logs (`docker logs`, `-f`) | ✅ | Docker backend: live follow proxied verbatim. Apple/mock: Docker raw-stream frames with `tail`, `timestamps`, stdout/stderr suppression, and finite follow via runtime streaming |
| Stats (mem live, CPU%) | ✅ | Docker backend: `docker stats` streamed through the proxy. Apple/mock: two-sample CPU sampler |
| Events (`docker events`) | ✅ | Docker backend: proxied (live engine events). Apple/mock: synthesized via `EventSynthesizer` |
| `docker exec` (`-i`, `-it` TTY) + `attach` | ✅ | Bidirectional hijack proxy with correct half-close (stdin EOF) + exit codes; TTY (`/dev/pts/0`) verified |
| `docker cp` / `docker export` (archive get/put/export) | ✅ | `GET`/`PUT /containers/{id}/archive` and `GET /containers/{id}/export`; archive PUT includes chunked request bodies |
| `docker build` (classic + **BuildKit**) | ✅ | Both verified end-to-end via Dory's socket (BuildKit gRPC session proxied) |
| Any other Docker endpoint (Docker backend) | ✅ | Transparent proxy (distribution, swarm, plugins, etc. all pass through) |
| Full create-body flag coverage | 🟡 | Apple/mock translation maps common flags; the long tail is iterative (Docker backend forwards everything) |

## Compose

| Capability | Status | Notes |
|---|---|---|
| Parse `compose.yaml` | ✅ | Block + flow YAML, quotes, comments (subset; no anchors/block scalars) |
| Variable interpolation + `.env` | ✅ | `$VAR`, `${VAR:-default}`, `${VAR-default}`, `$$` |
| `depends_on` (short + long form) | ✅ | `service_started` / `service_healthy` / `service_completed_successfully` |
| Dependency ordering | ✅ | Topological start order, cycle + dangling-dep detection |
| Healthchecks | ✅ | Exec-based probing + Docker-faithful state machine |
| `up` / `down` | ✅ | Native engine; AND the real `docker compose up/down` CLI drives Dory's socket (verified) |
| GUI Compose view | ✅ | Projects grouped by service with per-project + per-service start/stop |
| Named/anonymous volumes | 🟡 | Declared top-level volumes are created as `<project>_<vol>` with compose labels on `up`, service references to them are project-prefixed, and `down(removeVolumes:)` removes them (`compose down -v`); anonymous volumes pass through to the runtime. `external: true` volumes and long-form `type: volume` mounts not special-cased yet |
| Profiles | ✅ | Unprofiled services start by default; `COMPOSE_PROFILES` and `*` activate profiled services. Targeted service activation is not exposed in the GUI |
| Multiple files / overrides | 🟡 | Default override files plus `COMPOSE_FILE` ordered merge for common fields, including inline `!reset` (drop a key) and `!override` (replace instead of merge) tags; block-form tags (tag on the `key:` line with the value indented below) not yet |
| `network_mode: service:` / shared pid/ipc | ⛔ | Co-schedule into one machine (by design, against Apple `container`) |

## Engine backends

| Backend | Standalone? | Memory model | Notes |
|---|---|---|---|
| **Dory engine** (default; `DORY_RUNTIME=shared`) | ✅ yes | **One shared VM for all containers** (OrbStack-style) | Dory provisions one persistent Linux micro-VM running `dockerd` (DinD) on `dory-hv`, publishes its socket to the host over vsock with full half-close fidelity, and drives it with the verified Docker runtime. The engine keeps a TCP fallback while the guest agent starts, then promotes to the vsock bridge so `docker run`, attach, exec, logs, and Compose preserve stdout/stderr and stdin EOF correctly. Internal guest control ports are reserved and are not auto-forwarded as public localhost services. Intel prefers the raw `dory-hv` tier when signed PVH kernel/initfs assets are bundled, with Docker-compatible proxy fallback when assets or hypervisor support are missing. Verified on Apple silicon: standalone (engine 29.6.x, no Docker Desktop/OrbStack/Colima), workloads share one VM. Measured on Apple silicon: 2 containers = **1 VM @ ~122 MB** vs **~574 MB** as 3 per-container VMs. Persistent `/var/lib/docker` (preserved across restarts); memory is returned to macOS as workloads idle. Also available headless as the `dory-engine` runtime tarball. |
| **Existing engine** (Settings → Engine Backend; `DORY_RUNTIME=docker`) | ❌ proxies host engine | Docker Desktop / OrbStack / Colima / Rancher Desktop / Podman | First-class selectable backend (not just a fallback): transparent proxy to the detected local engine socket (`DOCKER_HOST`, Docker contexts, and common engine sockets), or a custom socket path. Compatibility follows the installed host engine. Companion GUI, not standalone. |

## Diagnostics and Auto-Idle foundation

| Capability | Status | Notes |
|---|---|---|
| `dory doctor` | ✅ | Checks socket/API, Docker CLI and context, registry DNS/TLS, host/container DNS comparison, published ports, local domains, bind mounts, watcher visibility, VM clock, disk, memory, and helper setup. Supports `--json`, `--active`, focused `--only` groups, and bundle creation. |
| Redacted diagnostic bundle | ✅ | `dory bundle` and `dory doctor --bundle` write a zip containing doctor output, route/disk/idle summaries, selected environment, config, and log tails with token/password/basic/bearer redaction. |
| Network readiness CLI | ✅ | `dory network --active` starts a labeled HTTP probe container and verifies registry reachability, container DNS, localhost port publishing, and `*.dory.local` routing. |
| Corporate/private network probes | ✅ foundation | `dory network --save-probe HOST[:PORT]`, `--list-probes`, and one-time `--probe HOST[:PORT]` store credential-free host/port probes. `dory network` includes them in host DNS, TCP/TLS, and active host/container DNS comparison. |
| Mount readiness CLI | ✅ | `dory mount` validates bind-mount read/write/truncate/path-with-spaces, symlink/readlink propagation, and host edit visibility against a live Dory engine. |
| Disk, route, and cleanup inspectors | ✅ | `dory disk` reports host free space, Docker `/system/df` categories, Dory state/log/VM disk estimates; `dory cleanup` dry-runs safe cleanup for stopped containers, dangling images, build cache, logs, and opt-in volumes; `dory routes` lists published ports, inferred local domains, owners, and port conflicts. |
| Non-destructive repair CLI | ✅ foundation | `dory repair [target]` covers socket, Docker context, DNS cache, routes, domains, ports, dockerd reachability, the `engine` (headless restart), and guest-agent wake/clock resync signalling. `dory repair all --apply` only acts on subsystems that report a problem. GUI recovery actions and true in-app subsystem restarts remain. |
| P0 release smoke | ✅ | `scripts/p0-smoke.sh` gates doctor, network, mount, Docker CLI stdout, Compose up/down, and localhost port publish against a running Dory socket. It now passes against the rebuilt/relaunched app bundle. |
| Runtime mode settings | 🛠️ foundation | `dory mode manual|auto-idle|always-on|battery-saver|show` persists the user's intended availability mode, and `dory idle status` explains current sleep blockers such as running containers, published ports, pinned labels, and Kubernetes config. |
| App-managed Auto-Idle | 🛠️ foundation | The app can attach to a sleeping `doryd` without calling `engineStart()`, so simply opening Dory does not wake `dory-hv`. doryd's Docker-tier idle policy stops an empty engine and keeps state on disk; active or unknown workloads are suspended/preserved instead of discarded. Focused app and core tests cover the sleeping attach path and idle stop policy. |
| Socket-level Auto-Idle wake/sleep proxy | 🛠️ headless foundation | `dory idle proxy --foreground` keeps a Docker-compatible socket available, wakes the headless engine on API use, forwards requests to `engine.sock`, writes `idle-state.json` state transitions, and can stop the engine after the idle policy has no blockers. `dory idle proxy-status [--json]` reports the last recorded transition. `scripts/test-dory-doctor.sh` now covers the deterministic socket bind -> fake-engine wake -> forwarded `/_ping` -> state-file path. `dory idle launch-agent` can print/install the opt-in LaunchAgent. Wake UX polish, concurrent-client behavior, and release soak gates remain. |

## OrbStack parity surface

All verified end-to-end on the shared-VM backend (default). System-wide binds (:53/:80/:443) and the
CA trust install remain consent-gated, the same one-time admin grant OrbStack needs.

| Capability | Status | Notes |
|---|---|---|
| Native GUI (menu bar + main window) | ✅ | All screens, both themes; one-click toggles for k8s/machines/shared-VM |
| Standalone engine + shared-VM memory | ✅ | Default backend; Dory runs its own `dockerd` in one VM, no OrbStack/Docker/Colima/Apple container install. ~4.7× leaner than per-container |
| `localhost` access to published ports | ✅ | `HostPortForwarder`; verified `localhost:port → 200`, dynamic add/teardown |
| Automatic `*.dory.local` domains | ✅ | `DoryDNS` resolver + `DoryReverseProxy`; verified `http://name.dory.local → 200`. System-wide via consent script |
| Automatic local HTTPS | ✅ | `DoryTLSProxy` terminates TLS with a `LocalCA` identity; verified `https://name.dory.local → 200` |
| **Bind-mount file sharing** | ✅ | Home dir shared into the VM (virtiofs); verified `docker run -v ~/proj:/app` reads/writes host files live |
| Apple GPU AI workloads | ✅ host-service bridge | Containers can reach Metal-backed macOS services at `host.dory.internal` on ports `11434` (Ollama), `1234` (LM Studio/OpenAI-compatible local servers), and `18190` (readiness/custom). Verified from the default Docker bridge and a user-defined bridge network |
| In-guest GPU compute (Venus/Vulkan) | 🟡 experimental, working | Opt-in via **Settings → GPU Acceleration**: virtio-gpu with Mesa's Venus driver in the container → virglrenderer → MoltenVK → Metal. Verified end-to-end: `vulkaninfo` in a Debian container enumerates `Virtio-GPU Venus (Apple M2 Pro)` with compute queues, and real fence workloads pass (25 `vkQueueSubmit` + `vkWaitForFences` cycles). Device-level virtio-gpu fence signalling is implemented (deferred completion via virglrenderer's async callbacks); Venus's own sync rides its shared-memory ring. The renderer ships inside Dory.app (no Homebrew needed); the container needs Mesa Venus (`mesa-vulkan-drivers` + `--device /dev/dri/renderD128`). Not raw GPU passthrough — no such thing exists on Apple silicon for any hypervisor; API remoting is the platform's strongest form of GPU access |
| One-click Kubernetes | ✅ | `KubernetesProvisioner` runs k3s in the shared VM; verified host `kubectl` + pod deploy; GUI "Enable" button |
| Linux machines (Ubuntu/Debian/Fedora/Alpine) | ✅ | Full Linux machines are isolated VMs, not Docker containers. doryd owns one `dory-vmm` helper per machine with durable machine definitions, status, start/stop/delete, snapshots, terminal/shell attach, mounts, ports, resources, recipes, and assignable `*.dory.local` addresses. The UI shows copyable terminal commands such as `dory ssh dev` / `dory machine shell dev`. |
| Non-native CPU emulation | ✅ (qemu, with limits) | Opt-in via **Settings → Run Intel (x86/amd64) images**: registers qemu binfmt in the guest so `--platform linux/amd64` runs on Dory's own engine (verified: alpine and debian report `x86_64`/`amd64`, pulls fetch the right platform variant). First x86 use installs the qemu handlers via `tonistiigi/binfmt` (cached afterwards). **Heavy amd64 workloads can segfault** under qemu-user — SQL Server (`mcr.microsoft.com/mssql/server`), Oracle, and some AVX/threading-heavy images hit `qemu: uncaught target signal 11`. This is a qemu-user emulation limit, not a Dory bug; Rosetta cannot run on a raw Hypervisor.framework VMM, and the former Virtualization.framework Rosetta engine switch was retired (its guest handshake was unreliable). (GitHub #3) |
| Volume file browser | ✅ | `VolumeBrowser`; verified list + read files inside volumes; GUI sheet |
| Terminal / SSH into containers + machines | ✅ | `TerminalLauncher` opens Terminal.app against Dory's socket/engine |
| Docker Desktop / OrbStack migration | ✅ | `MigrationAssistant` imports images + containers into Dory's shared VM; Docker-compatible sources stream image archives directly when possible, so local/private images do not require a registry pull or a full tarball buffered in app memory. The preflight confidence report lists transfer items, attention items, estimated image disk, Compose projects, bind mounts, volume references, privileged containers, host-network containers, and published ports before any write. |
| Managed local settings | ✅ foundation | Settings can generate an MDM/config-friendly JSON profile covering engine route, domains, DNS/proxy ports, Auto-Idle policy, file-sharing policy, scoped sandbox mounts, hidden credential stores, env allow-list, and telemetry mode `none`. No server is required. |
| `*.k8s.dory.local` service domains | ✅ HTTP + HTTPS | `KubeServiceProxy` runs `kubectl proxy`; the reverse/TLS proxy rewrites `<svc>.<ns>.k8s.dory.local` → the API service proxy. Verified `http`+`https → 200`. TLS cert carries per-namespace wildcard SANs (`*.default.k8s.dory.local`, `*.kube-system.k8s.dory.local`); other namespaces would need their wildcard added |
| `dory` CLI (OrbStack's `orb`) | ✅ | `scripts/dory` wraps the engine, machines, kubectl, diagnostics, disk/routes, repair, and runtime mode/idle status |

### Apple containerization helper: low-level VM controls delivered

Several features need low-level VM control the `container` CLI does not expose: audio, memory
ballooning, the Rosetta device, custom mounts - all delivered through the bundled `dory-vm` helper,
which links the `apple/containerization` Swift package and drives the VM in-process. USB *device*
passthrough is the exception: the helper attaches a USB controller but does not yet pass a host
device through - real per-device passthrough is the usbip-over-vsock path (roadmap Track 3.6).

**Foundation built + PROVEN END-TO-END.** `Packages/ContainerizationEngine/` is an additive Swift
package (separate from the shipping app) that links `apple/containerization` and drives the Linux VM
directly via Virtualization.framework. It does not just compile. A signed boot harness
(`dory-vmboot`, adhoc-signed with `com.apple.security.virtualization`) **boots a real Linux VM
in-process and runs a container**, verified by exit code:

- `exit 42`: VM booted + container ran (kernel + initfs + image store all working in-process).
- `exit 77`: an **amd64 image ran via Rosetta** (`uname -m == x86_64`) → **Rosetta-fast x86 PROVEN**.
- `exit 99`: same run also read a **host file through a `Mount.share`** (`/shared/marker.txt`) →
  **bidirectional file sharing PROVEN**.

**Shipped to users via `dory vm`.** The engine is packaged as a bundled, entitlement-signed helper
(`Helpers/dory-vm`, built + signed by `scripts/bundle-engine.sh`) that the `dory` CLI and the app
invoke, exactly how Dory already invokes `container`/`docker`/`kubectl`, so the app gains the
features without linking the framework's large dependency tree.

| Capability | Status | Delivery |
|---|---|---|
| Rosetta-speed x86 | 🟡 one-off VMs only | `dory vm --arch amd64 --rosetta -- <cmd>` → `uname -m == x86_64` for single-shot VMs. The Rosetta *shared-engine* switch was retired in 0.3 (its guest handshake stalled); day-to-day x86 images run on Dory's own engine via the qemu binfmt toggle instead |
| Reverse / bidirectional file mount | ✅ **delivered** | `dory vm --mount host:guest -- <cmd>` reads/writes host files in the container. Verified |
| Audio passthrough | ✅ **delivered** | `dory vm --devices`: a `VZInstanceExtension` injects `VZVirtioSoundDevice`. Verified audio device configured |
| USB device passthrough | 🚧 **in progress** | `dory vm --devices` attaches a `VZXHCIController`, but **no host USB device is passed through** - it is an empty controller (`USB controllers attached: 1` confirms the controller, not a device). Real per-device passthrough is the usbip-over-vsock path (roadmap Track 3.6), pending the `--usb` hardware gate |
| Dynamic memory balloon → macOS | ✅ **delivered** | `dory vm --devices` attaches a balloon and reclaims RAM at runtime via the public `vzVirtualMachine`, verified `1024MiB → 512MiB reclaimed to macOS` |

**Rosetta, file mount, audio, and the memory balloon are delivered** through the bundled,
entitlement-signed `dory-vm` helper, surfaced by the
`dory` CLI (`dory vm`). The default shared-VM engine is untouched. (A GUI entry point for the
in-process engine is not yet wired up.)

## Packaging: does the user need anything besides Dory.app?

The goal is a single download, and since 0.3 every release ships three flavors so you take only
what you need:

| Flavor | Contents |
|---|---|
| `Dory-x.y.z.dmg` / `.zip` | Full app: bundled engine, kernel (headless + GPU), offline engine rootfs, Venus GPU renderer, Docker/Compose/kubectl CLIs |
| `Dory-x.y.z-lite.zip` | The app alone (~6 MB): fronts an engine you already run via Settings → Engine Backend |
| `dory-engine-x.y.z-arm64.tar.gz` | Headless engine runtime (Colima-style): `dory-hv`, `gvproxy`, kernel, guest agent, and a `dory-engine start/stop/status` launcher that publishes `~/.dory/engine.sock` and a `dory-engine` docker context |

Status of the full flavor:

| Component | Bundled? | How |
|---|---|---|
| In-process engine (`dory-hv` + `dory-vm` helpers) | ✅ verified | `scripts/bundle-engine.sh` builds + signs the Hypervisor.framework `dory-hv` helper, `gvproxy`, and the Virtualization.framework fallback helper into `Contents/Helpers` with the required entitlements. |
| VM kernel + initfs | ✅ verified | Compressed into `Contents/Resources/*.lzfse`; decompressed once on first launch with Apple's Compression framework. No external `zstd` binary or dylib is required. |
| Engine rootfs / `dockerd` payload | ✅ bundled for offline releases; internal one-time fetch in dev bundles | Offline releases include `dory-engine-rootfs.ext4.lzfse` when the release runner provides `DORY_ENGINE_ROOTFS` or a prepared rootfs. Development bundles can still fetch `docker:dind` once internally on first boot. Neither path requires Docker Desktop, Colima, OrbStack, Homebrew, or Apple `container` on the user's Mac. |
| `docker` CLI + Compose + `kubectl` | ✅ bundled | `Contents/Helpers/docker`, `docker-compose`, and `kubectl` ship with the app. Optional shell integration links them into `~/.dory/bin` and installs the Compose plugin into `~/.docker/cli-plugins`, all per-user and reversible. |
| macOS 14+ (Sonoma) | app requirement | The SwiftUI app and Docker-compatible host-engine mode build and run with a macOS 14 deployment target, matching OrbStack's floor. The app links no Virtualization/Hypervisor code and uses no macOS-15-only API. |
| macOS 15+ (Sequoia) | built-in engine requirement | The bundled `dory-hv`/`dory-vm` engine needs macOS 15: the Apple-silicon path uses the in-kernel GIC interrupt API (`hv_gic_*`) introduced in macOS 15, and the engine package plus its Virtualization USB config are 15.0. On macOS 14 Dory runs in Docker-compatible proxy mode. |
| Apple silicon built-in engine | verified standalone engine | The native `dory-hv` shared engine is verified on Apple silicon. |
| Intel built-in engine | beta, hardware-gated | The universal app, raw `dory-hv` x86 selection, PVH asset selection, amd64 VZ fallback assets, and Virtualization.framework tier routing are implemented. Full Intel readiness still requires a physical Intel Mac with Hypervisor.framework support. |
| macOS 26+ on Apple silicon | Apple `container` backend requirement | Apple's per-container `container` backend requires it; Dory will gate that backend at runtime when the feature-equivalent path ships. |

So: **a self-contained standalone Dory.app works on Apple silicon**, verified end-to-end
(`DORY_BUNDLE_ENGINE=1`): a re-signed bundle that passes `codesign --verify --deep --strict`,
ships the helpers, CLIs, kernel/initfs, networking, and optional offline engine rootfs, and
requires no Homebrew, no Docker Desktop, no Colima, no OrbStack, and no Apple `container` install.
On Intel, the raw `dory-hv` tier is wired as a beta when PVH assets are bundled, with the
Virtualization.framework helper as the amd64 fallback; until the Intel hardware readiness gate is
green, Dory still has the Docker-compatible fallback path. Building a self-contained bundle needs
the guest kernel/initfs assets available on the release runner, and a fully offline first boot also
needs a prepared engine rootfs.

## Tool compatibility (`dory compat`)

"Docker-compatible" breaks at the edges: tools assume Docker Desktop or `/var/run/docker.sock`, read
`DOCKER_HOST`, or need Ryuk and socket bind mounts. `dory compat` measures those real workflows,
names the exact env/config mismatch, and ships a copy-paste recipe per tool with a verification
command (`dory compat --recipe <tool>`). The compatibility CI harness (`scripts/compat-smoke.sh`)
gates the recipe surface in CI and runs the engine-backed smoke tests during release readiness.

| Tool/workflow | What `dory compat` checks | Fix it points to |
|---|---|---|
| Docker CLI | CLI on PATH, socket reachable, `DOCKER_HOST`/context targets Dory | `docker context use dory` |
| Docker Compose v2 | Bundled `docker compose` plugin resolves | Shell integration puts the plugin on PATH |
| VS Code Dev Containers | App installed, `docker` on PATH, engine route | `"dev.containers.dockerPath"` + `dory` context |
| Cursor Dev Containers | Same as VS Code (fork) | Same recipe |
| Testcontainers | `DOCKER_HOST` or `/var/run/docker.sock` resolves to Dory; Ryuk note | `export DOCKER_HOST=unix://~/.dory/dory.sock` |
| GitHub Actions `act` | Default `/var/run/docker.sock` vs Dory | `act --container-daemon-socket unix://…` |
| Supabase local | CLI present + engine reachable | `docker context use dory` then `supabase start` |
| LocalStack | CLI present + engine reachable | `localstack start -d`, verify `:4566/_localstack/health` |
| Skaffold/Tilt (Kubernetes) | `kubectl` + a kubeconfig/context | `kubectl config use-context dory` |

Each row's recipe has a verification command; run `dory compat` for the live status on your machine
and `dory compat --recipe` for the full set.

## Architectural / environment notes

- **Shared VM vs one-VM-per-container.** Dory offers BOTH: the Apple `container` backend is
  one-VM-per-container, while the **Shared VM backend** runs all containers in one VM like
  OrbStack. Measured ~4.7× less memory for 2 containers (122 MB vs 574 MB), with the gap widening
  per container. This closes the headline memory gap and makes Dory a standalone engine.
- **File-sharing performance** under the Apple `container` runtime + a real bind-mount dev loop is
  not yet benchmarked here.
- **Distribution.** Release automation builds Apple-silicon, Intel, and universal app artifacts,
  signs them with Developer ID, submits them for notarization when Apple credentials are present,
  staples the tickets, generates the Sparkle appcast, and bumps/syncs the Homebrew Cask. The
  remaining external gate is operational: the release runner must have the Developer ID/notary
  credentials, Sparkle key, Homebrew tap token, and bundled engine assets before publishing.
- The app runs **unsandboxed** (like Docker Desktop/OrbStack) to reach the engine socket and
  host its own socket.
