# Dory Compatibility Matrix

This is the honest, maintained statement of what Dory does. It reflects the **current
implementation**, which talks to a Docker Engine API backend through a pluggable runtime layer
designed to also target Apple's `container` engine when present.

Legend: ✅ works · 🟡 works with Dory-specific behavior · 🛠️ implemented, activation gated ·
⛔ unsupported / not yet · 🔒 blocked by an external gate.

## Docker Engine API (via Dory's socket `~/.dory/dory.sock`)

On the Docker backend, Dory's socket is a **full transparent proxy**: every request is forwarded
verbatim and the response streamed back unchanged — uniformly correct for normal, streaming, and
hijacked (upgrade) endpoints, with all request headers preserved (registry auth, etc.). The
per-endpoint translation below is what the **Apple `container`** and mock backends present, since
they have no Docker socket to forward to.

| Capability | Status | Notes |
|---|---|---|
| `docker version` / `info` / `_ping` | ✅ | Docker backend: real engine response (transparent passthrough). Apple/mock: Dory-branded. Verified with the real `docker` CLI |
| `docker ps` / list containers | ✅ | Real containers, correct names/status/ports/timestamps |
| Container start / stop / restart / remove | ✅ | `POST /containers/{id}/...`, `DELETE /containers/{id}` |
| `docker images` / list | ✅ | Translated from the runtime snapshot (Apple/mock) |
| Container create (with body) | ✅ | image, cmd, env, ports, labels, network, restart policy; image refs starting with `-` rejected at the boundary |
| Exec (create + start + inspect) | ✅ | Used by the Compose health prober |
| Image pull | ✅ | `POST /images/create` |
| Network create / remove | ✅ | `POST /networks/create`, `DELETE /networks/{id}` |
| Volume remove | ✅ | `DELETE /volumes/{id}` |
| Logs (`docker logs`, `-f`) | ✅ | Docker backend: live follow proxied verbatim. Apple/mock: de-framed via streaming transport |
| Stats (mem live, CPU%) | ✅ | Docker backend: `docker stats` streamed through the proxy. Apple/mock: two-sample CPU sampler |
| Events (`docker events`) | ✅ | Docker backend: proxied (live engine events). Apple/mock: synthesized via `EventSynthesizer` |
| `docker exec` (`-i`, `-it` TTY) + `attach` | ✅ | Bidirectional hijack proxy with correct half-close (stdin EOF) + exit codes; TTY (`/dev/pts/0`) verified |
| `docker cp` (archive get/put) | ✅ | Both directions verified (incl. chunked request bodies) |
| `docker build` (classic + **BuildKit**) | ✅ | Both verified end-to-end via Dory's socket (BuildKit gRPC session proxied) |
| Any other Docker endpoint (Docker backend) | ✅ | Transparent proxy — distribution, swarm, plugins, etc. all pass through |
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
| Named/anonymous volumes | 🟡 | Anonymous-volume tracker built; full volume wiring iterative |
| Profiles / multiple files / overrides | ⛔ | Parsed-aware; merge logic not yet |
| `network_mode: service:` / shared pid/ipc | ⛔ | Co-schedule into one machine — by design, against Apple `container` |

## Engine backends

| Backend | Standalone? | Memory model | Notes |
|---|---|---|---|
| **Shared VM** (`DORY_RUNTIME=shared`) | ✅ yes | **One shared VM for all containers** (OrbStack-style) | Dory provisions one persistent Linux micro-VM on Apple's `container` engine running `dockerd` (DinD), publishes its socket to the host, and drives it with the verified Docker runtime. Verified: standalone (engine 29.5.3, no OrbStack), workloads share one VM. Measured: 2 containers = **1 VM @ ~122 MB** vs **~574 MB** as 3 per-container VMs. Persistent `/var/lib/docker` (overlayfs preserved across restarts); configurable CPUs/memory; idempotent reuse. |
| **Docker** (default) | ❌ proxies host engine | host Docker/OrbStack | Transparent proxy to `/var/run/docker.sock`. Companion GUI, not a replacement. |
| **Apple `container`** | ✅ yes | **One VM per container** | Native per-container micro-VMs; heavier for multi-container stacks. |

## OrbStack parity surface

All verified end-to-end on the shared-VM backend (default). System-wide binds (:53/:80/:443) and the
CA trust install remain consent-gated — the same one-time admin grant OrbStack needs.

| Capability | Status | Notes |
|---|---|---|
| Native GUI (menu bar + main window) | ✅ | All screens, both themes; one-click toggles for k8s/machines/shared-VM |
| Standalone engine + shared-VM memory | ✅ | Default backend; Dory runs its own `dockerd` in one VM — no OrbStack/Docker. ~4.7× leaner than per-container |
| `localhost` access to published ports | ✅ | `HostPortForwarder`; verified `localhost:port → 200`, dynamic add/teardown |
| Automatic `*.dory.local` domains | ✅ | `DoryDNS` resolver + `DoryReverseProxy`; verified `http://name.dory.local → 200`. System-wide via consent script |
| Automatic local HTTPS | ✅ | `DoryTLSProxy` terminates TLS with a `LocalCA` identity; verified `https://name.dory.local → 200` |
| **Bind-mount file sharing** | ✅ | Home dir shared into the VM (virtiofs); verified `docker run -v ~/proj:/app` reads/writes host files live |
| One-click Kubernetes | ✅ | `KubernetesProvisioner` runs k3s in the shared VM; verified host `kubectl` + pod deploy; GUI "Enable" button |
| Linux machines (Ubuntu/Debian/Fedora/Alpine) | ✅ | `MachineProvider` via `container machine`; verified real machine create/list/start/stop/delete; GUI picker |
| x86/amd64 emulation | ✅ (qemu) | Auto-installs qemu binfmt; verified `--platform linux/amd64 → x86_64`. Rosetta fast-path is a documented gap |
| Volume file browser | ✅ | `VolumeBrowser`; verified list + read files inside volumes; GUI sheet |
| Terminal / SSH into containers + machines | ✅ | `TerminalLauncher` opens Terminal.app against Dory's socket/engine |
| Docker Desktop / OrbStack migration | ✅ | `MigrationAssistant` imports images + containers into Dory's shared VM |
| `*.k8s.dory.local` service domains | ✅ HTTP + HTTPS | `KubeServiceProxy` runs `kubectl proxy`; the reverse/TLS proxy rewrites `<svc>.<ns>.k8s.dory.local` → the API service proxy. Verified `http`+`https → 200`. TLS cert carries per-namespace wildcard SANs (`*.default.k8s.dory.local`, `*.kube-system.k8s.dory.local`); other namespaces would need their wildcard added |
| `dory` CLI (OrbStack's `orb`) | ✅ | `scripts/dory` wraps the engine, machines, and kubectl |

### Remaining gaps — all blocked on ONE thing: `apple/containerization` framework integration

Every feature achievable through Apple's `container` CLI + the dind architecture is done. The four
items below were each investigated and shown to need low-level VM control the CLI does not expose —
device passthrough, memory ballooning, Rosetta device, custom mounts. They all become feasible once
Dory links the `apple/containerization` Swift package and drives the VM in-process (the same
integration the [packaging](#packaging) section roadmaps).

**Foundation built + PROVEN END-TO-END.** `Packages/ContainerizationEngine/` is an additive Swift
package (separate from the shipping app) that links `apple/containerization` and drives the Linux VM
directly via Virtualization.framework. It does not just compile — a signed boot harness
(`dory-vmboot`, adhoc-signed with `com.apple.security.virtualization`) **boots a real Linux VM
in-process and runs a container**, verified by exit code:

- `exit 42` — VM booted + container ran (kernel + initfs + image store all working in-process).
- `exit 77` — an **amd64 image ran via Rosetta** (`uname -m == x86_64`) → **Rosetta-fast x86 PROVEN**.
- `exit 99` — same run also read a **host file through a `Mount.share`** (`/shared/marker.txt`) →
  **bidirectional file sharing PROVEN**.

**Shipped to users via `dory vm`.** The engine is packaged as a bundled, entitlement-signed helper
(`Helpers/dory-vm`, built + signed by `scripts/bundle-engine.sh`) that the `dory` CLI and the app
invoke — exactly how Dory already invokes `container`/`docker`/`kubectl`, so the app gains the
features without linking the framework's large dependency tree.

| Capability | Status | Delivery |
|---|---|---|
| Rosetta-speed x86 | ✅ **delivered** | `dory vm --arch amd64 --rosetta -- <cmd>` → `uname -m == x86_64`. Verified through the CLI |
| Reverse / bidirectional file mount | ✅ **delivered** | `dory vm --mount host:guest -- <cmd>` reads/writes host files in the container. Verified |
| USB / audio passthrough | ✅ **delivered** | `dory vm --devices`: a `VZInstanceExtension` injects an XHCI USB controller + `VZVirtioSoundDevice`. Verified `USB controllers attached: 1` |
| Dynamic memory balloon → macOS | ✅ **delivered** | `dory vm --devices` attaches a balloon and reclaims RAM at runtime via the public `vzVirtualMachine` — verified `1024MiB → 512MiB reclaimed to macOS` |

**All four are delivered** through the bundled, entitlement-signed `dory-vm` helper, surfaced by the
`dory` CLI (`dory vm`). The default shared-VM engine is untouched. (A GUI entry point for the
in-process engine is not yet wired up.)

## Packaging — does the user need anything besides Dory.app?

The goal is a single download. Status:

| Component | Bundled? | How |
|---|---|---|
| In-process engine (`dory-vm` helper) | ✅ verified | `scripts/bundle-engine.sh` builds + signs the `dory-vmboot` helper (links Apple's `containerization` framework, ~100 MB) into `Contents/Helpers/dory-vm` with the `com.apple.security.virtualization` entitlement. |
| VM kernel + initfs | ✅ verified | Compressed into `Contents/Resources/dory-vm-kernel.zst` (~6 MB) + `dory-vm-initfs.ext4.zst` (~30 MB); decompressed once on first launch via the bundled `zstd`. |
| Engine image (`docker:dind`) | pulled on first run | NOT bundled (OrbStack model) — the helper pulls it on first boot. `DORY_BUNDLE_LEGACY=1` bundles it + the `container` toolchain for a fully-offline build. |
| `docker` CLI | not needed | Dory hosts a Docker-compatible socket and points the `docker` context at it, so `docker` just works; the CLI itself isn't bundled. |
| **macOS 26+** | requirement, not a download | Apple's virtualization/containerization stack requires it — the unavoidable floor. |

So: **a self-contained Dory.app works** — verified end-to-end (`DORY_BUNDLE_ENGINE=1`): a re-signed bundle that passes `codesign --verify --deep --strict`, **~155 MB on disk / ~80 MB zipped** (the engine helper dominates; the "image pulled on first run" keeps it from being larger), requiring only macOS 26+ — no Homebrew, no Docker Hub, no Docker Desktop. Building it needs the kernel/initfs from a machine that has run Apple's `container`, so the release runner must be self-hosted (hosted CI has no virtualization).

## Architectural / environment notes

- **Shared VM vs one-VM-per-container.** Dory offers BOTH: the Apple `container` backend is
  one-VM-per-container, while the **Shared VM backend** runs all containers in one VM like
  OrbStack — measured ~4.7× less memory for 2 containers (122 MB vs 574 MB), with the gap widening
  per container. This closes the headline memory gap and makes Dory a standalone engine.
- **File-sharing performance** under the Apple `container` runtime + a real bind-mount dev loop is
  not yet benchmarked here.
- **Distribution.** Signing works locally; **notarization requires an Apple Developer account**
  (external gate). The Homebrew Cask and an auto-updater are scaffolding still to add.
- The app runs **unsandboxed** (like Docker Desktop/OrbStack) to reach the engine socket and
  host its own socket.
