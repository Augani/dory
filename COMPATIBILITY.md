# Dory Compatibility Matrix

This is the honest, maintained statement of what Dory does. It reflects the **current
implementation**, which talks to a Docker Engine API backend through a pluggable runtime layer
designed to also target Apple's `container` engine when present.

Legend: ✅ works · 🟡 works with Dory-specific behavior · 🛠️ implemented, activation gated ·
⛔ unsupported / not yet · 🔒 blocked by an external gate.

## Docker Engine API (via Dory's socket `~/.dory/dory.sock`)

On the Docker backend, Dory's socket is a **full transparent proxy**: every request is forwarded
verbatim and the response streamed back unchanged. It is uniformly correct for normal, streaming, and
hijacked (upgrade) endpoints, with all request headers preserved (registry auth, etc.). The
per-endpoint translation below is what the **Apple `container`** and mock backends present, since
they have no Docker socket to forward to.

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
| **Shared VM** (`DORY_RUNTIME=shared`) | ✅ yes | **One shared VM for all containers** (OrbStack-style) | Dory provisions one persistent Linux micro-VM running `dockerd` (DinD), publishes its socket to the host, and drives it with the verified Docker runtime. Apple silicon uses the native `dory-hv` tier today. Intel prefers the raw `dory-hv` tier when signed PVH kernel/initfs assets are bundled, then resolves to the Virtualization.framework shared-engine tier when amd64 VZ assets and the helper are bundled, with Docker-compatible proxy fallback when assets or hypervisor support are missing. Verified on Apple silicon: standalone (engine 29.5.3, no OrbStack), workloads share one VM. Measured on Apple silicon: 2 containers = **1 VM @ ~122 MB** vs **~574 MB** as 3 per-container VMs. Persistent `/var/lib/docker` (overlayfs preserved across restarts); configurable CPUs/memory; idempotent reuse. |
| **Docker-compatible host engine** | ❌ proxies host engine | Docker Desktop / OrbStack / Colima / Rancher Desktop / Podman | Transparent proxy to the detected local engine socket (`DOCKER_HOST`, Docker contexts, and common engine sockets). This is the fallback path for unsupported hosts, missing bundled assets, and installs where the built-in engine is disabled. Compatibility follows the installed host engine. Companion GUI, not standalone. |
| **Apple `container`** | ✅ yes | **One VM per container** | Native per-container micro-VMs; heavier for multi-container stacks. Requires macOS 26+ on Apple silicon and is runtime-gated. |

## OrbStack parity surface

All verified end-to-end on the shared-VM backend (default). System-wide binds (:53/:80/:443) and the
CA trust install remain consent-gated, the same one-time admin grant OrbStack needs.

| Capability | Status | Notes |
|---|---|---|
| Native GUI (menu bar + main window) | ✅ | All screens, both themes; one-click toggles for k8s/machines/shared-VM |
| Standalone engine + shared-VM memory | ✅ | Default backend; Dory runs its own `dockerd` in one VM, no OrbStack/Docker. ~4.7× leaner than per-container |
| `localhost` access to published ports | ✅ | `HostPortForwarder`; verified `localhost:port → 200`, dynamic add/teardown |
| Automatic `*.dory.local` domains | ✅ | `DoryDNS` resolver + `DoryReverseProxy`; verified `http://name.dory.local → 200`. System-wide via consent script |
| Automatic local HTTPS | ✅ | `DoryTLSProxy` terminates TLS with a `LocalCA` identity; verified `https://name.dory.local → 200` |
| **Bind-mount file sharing** | ✅ | Home dir shared into the VM (virtiofs); verified `docker run -v ~/proj:/app` reads/writes host files live |
| One-click Kubernetes | ✅ | `KubernetesProvisioner` runs k3s in the shared VM; verified host `kubectl` + pod deploy; GUI "Enable" button |
| Linux machines (Ubuntu/Debian/Fedora/Alpine) | ✅ | `MachineProvider` via `container machine`; verified real machine create/list/start/stop/delete; GUI picker |
| Non-native CPU emulation | ✅ (qemu, with limits) | Auto-installs qemu binfmt for the opposite host architecture: amd64 on Apple silicon, arm64 on Intel. Apple silicon verification: `--platform linux/amd64` reports `x86_64`. Intel arm64 emulation is wired symmetrically and awaits the Intel readiness gate. **Heavy amd64 workloads can segfault** under qemu-user on the default `dory-hv` engine - SQL Server (`mcr.microsoft.com/mssql/server`), Oracle, and some AVX/threading-heavy images hit `qemu: uncaught target signal 11`. This is a qemu-user emulation limit, not a Dory bug, and Rosetta cannot run on `dory-hv` (raw Hypervisor.framework). The fast x86 path on Apple silicon is the Virtualization.framework helper: `dory vm --arch amd64 --rosetta` / `DORY_ENGINE_ROSETTA=1`. (GitHub #3) |
| Volume file browser | ✅ | `VolumeBrowser`; verified list + read files inside volumes; GUI sheet |
| Terminal / SSH into containers + machines | ✅ | `TerminalLauncher` opens Terminal.app against Dory's socket/engine |
| Docker Desktop / OrbStack migration | ✅ | `MigrationAssistant` imports images + containers into Dory's shared VM; Docker-compatible sources stream image archives directly when possible, so local/private images do not require a registry pull or a full tarball buffered in app memory |
| `*.k8s.dory.local` service domains | ✅ HTTP + HTTPS | `KubeServiceProxy` runs `kubectl proxy`; the reverse/TLS proxy rewrites `<svc>.<ns>.k8s.dory.local` → the API service proxy. Verified `http`+`https → 200`. TLS cert carries per-namespace wildcard SANs (`*.default.k8s.dory.local`, `*.kube-system.k8s.dory.local`); other namespaces would need their wildcard added |
| `dory` CLI (OrbStack's `orb`) | ✅ | `scripts/dory` wraps the engine, machines, and kubectl |

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
| Rosetta-speed x86 | ✅ **delivered** | `dory vm --arch amd64 --rosetta -- <cmd>` → `uname -m == x86_64`. Verified through the CLI |
| Reverse / bidirectional file mount | ✅ **delivered** | `dory vm --mount host:guest -- <cmd>` reads/writes host files in the container. Verified |
| Audio passthrough | ✅ **delivered** | `dory vm --devices`: a `VZInstanceExtension` injects `VZVirtioSoundDevice`. Verified audio device configured |
| USB device passthrough | 🚧 **in progress** | `dory vm --devices` attaches a `VZXHCIController`, but **no host USB device is passed through** - it is an empty controller (`USB controllers attached: 1` confirms the controller, not a device). Real per-device passthrough is the usbip-over-vsock path (roadmap Track 3.6), pending the `--usb` hardware gate |
| Dynamic memory balloon → macOS | ✅ **delivered** | `dory vm --devices` attaches a balloon and reclaims RAM at runtime via the public `vzVirtualMachine`, verified `1024MiB → 512MiB reclaimed to macOS` |

**Rosetta, file mount, audio, and the memory balloon are delivered** through the bundled,
entitlement-signed `dory-vm` helper, surfaced by the
`dory` CLI (`dory vm`). The default shared-VM engine is untouched. (A GUI entry point for the
in-process engine is not yet wired up.)

## Packaging: does the user need anything besides Dory.app?

The goal is a single download. Status:

| Component | Bundled? | How |
|---|---|---|
| In-process engine (`dory-vm` helper) | ✅ verified | `scripts/bundle-engine.sh` builds + signs the `dory-vmboot` helper (links Apple's `containerization` framework, ~100 MB) into `Contents/Helpers/dory-vm` with the `com.apple.security.virtualization` entitlement. |
| VM kernel + initfs | ✅ verified | Compressed into `Contents/Resources/dory-vm-kernel.zst` (~6 MB) + `dory-vm-initfs.ext4.zst` (~30 MB); decompressed once on first launch via the bundled `zstd`. |
| Engine image (`docker:dind`) | pulled on first run | NOT bundled (OrbStack model): the helper pulls it on first boot. `DORY_BUNDLE_LEGACY=1` bundles it + the `container` toolchain for a fully-offline build. |
| `docker` CLI | not needed | Dory hosts a Docker-compatible socket and points the `docker` context at it, so `docker` just works; the CLI itself isn't bundled. |
| macOS 14+ (Sonoma) | app requirement | The SwiftUI app and Docker-compatible host-engine mode build and run with a macOS 14 deployment target, matching OrbStack's floor. The app links no Virtualization/Hypervisor code and uses no macOS-15-only API. |
| macOS 15+ (Sequoia) | built-in engine requirement | The bundled `dory-hv`/`dory-vm` engine needs macOS 15: the Apple-silicon path uses the in-kernel GIC interrupt API (`hv_gic_*`) introduced in macOS 15, and the engine package plus its Virtualization USB config are 15.0. On macOS 14 Dory runs in Docker-compatible proxy mode. |
| Apple silicon built-in engine | verified standalone engine | The native `dory-hv` shared engine is verified on Apple silicon. |
| Intel built-in engine | beta, hardware-gated | The universal app, raw `dory-hv` x86 selection, PVH asset selection, amd64 VZ fallback assets, and Virtualization.framework tier routing are implemented. Full Intel readiness still requires a physical Intel Mac with Hypervisor.framework support. |
| macOS 26+ on Apple silicon | Apple `container` backend requirement | Apple's per-container `container` backend requires it; Dory gates that backend at runtime. |

So: **a self-contained standalone Dory.app works on Apple silicon**, verified end-to-end (`DORY_BUNDLE_ENGINE=1`): a re-signed bundle that passes `codesign --verify --deep --strict`, **~155 MB on disk / ~80 MB zipped** (the engine helper dominates; the "image pulled on first run" keeps it from being larger), requiring no Homebrew, no Docker Hub, no Docker Desktop. On Intel, the raw `dory-hv` tier is wired as a beta when PVH assets are bundled, with the Virtualization.framework helper as the amd64 fallback; until the Intel hardware readiness gate is green, Dory still has the Docker-compatible fallback path. Building a self-contained bundle needs the guest kernel/initfs assets available on the release runner.

## Architectural / environment notes

- **Shared VM vs one-VM-per-container.** Dory offers BOTH: the Apple `container` backend is
  one-VM-per-container, while the **Shared VM backend** runs all containers in one VM like
  OrbStack. Measured ~4.7× less memory for 2 containers (122 MB vs 574 MB), with the gap widening
  per container. This closes the headline memory gap and makes Dory a standalone engine.
- **File-sharing performance** under the Apple `container` runtime + a real bind-mount dev loop is
  not yet benchmarked here.
- **Distribution.** Signing works locally; **notarization requires an Apple Developer account**
  (external gate). The Homebrew Cask and an auto-updater are scaffolding still to add.
- The app runs **unsandboxed** (like Docker Desktop/OrbStack) to reach the engine socket and
  host its own socket.
