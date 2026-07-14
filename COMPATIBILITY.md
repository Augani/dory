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
per-endpoint translation notes are retained for the mock runtime and retired translated-runtime
experiments; the shipping shared-VM path fronts a real `dockerd` socket.

| Capability | Status | Notes |
|---|---|---|
| `docker version` / `info` / `_ping` | ✅ | Docker backend: real engine response (transparent passthrough). Mock/translated test runtimes: Dory-branded. Verified with the real `docker` CLI |
| `docker ps` / list containers | ✅ | Real containers, correct names/status/ports/timestamps; supports `id`, `name`, `status`, `label`, `ancestor`, `before`, `since`, `exited`, `health`, `volume`, `network`, `publish`, and `expose` filters; `size=1` adds `SizeRw`/`SizeRootFs` for `docker ps -s` |
| Container lifecycle | ✅ | Create/start/stop/kill/restart/pause/unpause/wait/remove requests retain Docker's exact routes, query flags, statuses, and errors. Shared-VM create adds host reachability/socket compatibility fields; start performs a bounded, fail-closed macOS host-port collision preflight before forwarding. Named Linux signals remain names end to end. |
| `docker images` / list | ✅ | Translated from the runtime snapshot (mock/translated test runtimes), including `reference`, `label`, `dangling`, `before`, and `since` filters on `/images/json` |
| Container create (with body) | ✅ | image, cmd, env, ports, labels, network/network-disabled DNS, DNS domain, restart policy, platform query, cidfile, runtime handler; image refs starting with `-` rejected at the boundary |
| Container inspect | ✅ | `GET /containers/{id}/json`; includes common create-time `Config`/`HostConfig` fields, port bindings, mounts, and `NetworkSettings.Networks`; `size=1` adds `SizeRw`/`SizeRootFs` for `docker inspect --size` |
| Exec (create + start + inspect) | ✅ | Used by the Compose health prober |
| Image pull | ✅ | `POST /images/create` |
| Image search (`docker search`) | ✅ | `GET /images/search`; Docker/shared-VM backends search through dockerd. Translated backends query Docker Hub (`index.docker.io/v1/search`) and merge the results with the user's matching local images (local entries tagged, deduped first), falling back to local-only when the registry is unreachable. `is-official`/`is-automated`/`stars` filters and `limit` apply to the merged list |
| Registry auth (`docker login`) | ✅ | `POST /auth`; Docker/shared-VM backends validate through dockerd, translated backends persist Docker auth config for subsequent pulls |
| Image tag (`docker tag`) | ✅ | `POST /images/{name}/tag`; Docker/shared-VM backends proxy/forward to dockerd |
| Image push (`docker push`) | ✅ | `POST /images/{name}/push`; Docker/shared-VM backends stream native dockerd progress with registry auth |
| Image save / load / commit | ✅ | `GET /images/{name}/get`, `GET /images/get?names=...`, `POST /images/load`, `POST /commit`; Docker/shared-VM backends use daemon-native multi-image save, translated backends use a runtime-provided batch archive when available and otherwise report unsupported |
| Network list / create / remove / connect / disconnect | ✅ | Docker/shared-VM backends proxy/forward native dockerd network APIs; translated test runtimes keep coverage for `id`, `name`, `driver`, `scope`, `type`, and `label` filters |
| Volume list / create / remove / prune | ✅ | `GET /volumes` includes `name`, `driver`, `dangling`, and `label` filters on translated backends; `POST /volumes/create`, `DELETE /volumes/{id}`, `POST /volumes/prune` |
| System disk usage (`docker system df`) | ✅ | `GET /system/df`; translated from runtime snapshot images, containers, volumes, and empty BuildKit cache when unavailable |
| Logs (`docker logs`, `-f`) | ✅ | Docker backend: live follow proxied verbatim with client cancellation/backpressure. Mock/translated test runtimes: Docker raw-stream frames with `tail`, `timestamps`, stdout/stderr suppression, and finite follow via runtime streaming |
| Stats (mem live, CPU%) | ✅ | Docker backend: `docker stats` streamed through the proxy. Mock/translated test runtimes: two-sample CPU sampler |
| Events (`docker events`) | ✅ | Docker backend: proxied (live engine events). Mock/translated test runtimes: synthesized via `EventSynthesizer` |
| `docker exec` (`-i`, `-it` TTY) + `attach` | ✅ | Bidirectional hijack proxy with correct half-close (stdin EOF) + exit codes; TTY (`/dev/pts/0`) verified |
| `docker cp` / `docker export` (archive get/put/export) | ✅ | `GET`/`PUT /containers/{id}/archive` and `GET /containers/{id}/export`; archive PUT includes chunked request bodies |
| `docker build` (classic + **BuildKit**) | ✅ | Both verified end-to-end via Dory's socket (BuildKit gRPC session proxied) |
| Any other Docker endpoint (Docker backend) | ✅ | Transparent proxy (distribution, swarm, plugins, etc. all pass through) |
| Full create-body flag coverage | 🟡 | Mock/translated test runtimes map common flags; the long tail is iterative (Docker backend forwards everything) |

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
| Named/anonymous volumes | 🟡 current-worktree proof | Current source preserves top-level `name`, `external`, `driver`, `driver_opts`, and labels; validates external volumes before creating project state; never creates/removes external volumes; resolves relative bind sources from the first Compose file; maps long-form volume/bind/tmpfs/image options; pulls image mounts; rejects undefined named volumes; and removes attached anonymous volumes on `down -v`. The 712-test app gate and isolated runtime named-volume gates pass; repeat on the final notarized artifact. |
| Profiles | ✅ | Unprofiled services start by default; `COMPOSE_PROFILES` and `*` activate profiled services. Targeted service activation is not exposed in the GUI |
| Multiple files / overrides | 🟡 current-worktree proof | Default override files plus `COMPOSE_FILE` ordered merge for common fields, including inline and block-form `!reset` (drop a key) and `!override` (replace instead of merge) tags. Focused tests pass; full Compose-spec merge breadth remains intentionally delegated to the bundled `docker compose` CLI and must be repeated on the final artifact. |
| `network_mode: service:` / shared pid/ipc | 🟡 current-worktree proof | Current source adds implicit dependency edges and rewrites service namespace references to the exact project container name before Docker create. Focused tests pass; exact final-artifact proof remains. |

## Engine backends

| Backend | Standalone? | Memory model | Notes |
|---|---|---|---|
| **Dory engine** (default; `DORY_RUNTIME=shared`) | ✅ yes | **One shared VM for all containers** (OrbStack-style) | Dory provisions one persistent Linux micro-VM running `dockerd` on `dory-hv`, publishes its socket to the host over vsock with full half-close fidelity, and drives it with the verified Docker runtime. The engine keeps a TCP fallback while the guest agent starts, then promotes to the vsock bridge so `docker run`, attach, exec, logs, and Compose preserve stdout/stderr and stdin EOF correctly. Internal guest control ports are reserved and are not auto-forwarded as public localhost services. Verified on Apple Silicon: standalone (engine 29.6.x, no Docker Desktop/OrbStack/Colima), workloads share one VM. Persistent workload state lives in the managed `Dory.dorydrive`, survives replacement of transient VM state, and guest free-page reporting can return idle pages to macOS. A defensible total-product memory win over current OrbStack has not yet been measured; see `BENCHMARKS.md`. Also available headless as the `dory-engine` runtime tarball. |
| **Existing engine** (Settings → Engine Backend; `DORY_RUNTIME=docker`) | ❌ proxies host engine | Docker Desktop / OrbStack / Colima / Rancher Desktop / Podman | First-class selectable backend (not just a fallback): transparent proxy to the detected local engine socket (`DOCKER_HOST`, Docker contexts, and common engine sockets), or a custom socket path. Compatibility follows the installed host engine. Companion GUI, not standalone. |

## Diagnostics and Auto-Idle

| Capability | Status | Notes |
|---|---|---|
| `dory doctor` | ✅ | Checks socket/API, Docker CLI and context, registry DNS/TLS, host/container DNS comparison, published ports, local domains, bind mounts, watcher visibility, VM clock, disk, memory, and helper setup. Supports `--json`, `--active`, focused `--only` groups, and bundle creation. |
| Agent-native CLI contract | ✅ | `dory agent guide --json`, `dory wait --json`, `dory events --json`, and `dory mcp serve [--read-only]` expose versioned schemas for non-interactive automation. While `doryd` is running it automatically reconciles bundled Docker/Compose/kubectl/Dory wrappers and the Docker context, so `dory install` is manual recovery only. |
| Redacted diagnostic bundle | ✅ | `dory bundle` and `dory doctor --bundle` write a zip containing doctor output, route/disk/idle summaries, selected environment, config, and log tails with token/password/basic/bearer redaction. |
| Network readiness CLI | ✅ | `dory network --active` starts a labeled HTTP probe container and verifies registry reachability, container DNS, localhost port publishing, and `*.dory.local` routing. |
| Corporate/private network probes | ✅ | `dory network --save-probe HOST[:PORT]`, `--list-probes`, and one-time `--probe HOST[:PORT]` store credential-free host/port probes. `dory network` includes them in host DNS, TCP/TLS, and active host/container DNS comparison. |
| Mount readiness CLI | ✅ | `dory mount` validates bind-mount read/write/truncate/path-with-spaces, symlink/readlink propagation, and host edit visibility against a live Dory engine. |
| Disk, route, and cleanup inspectors | ✅ | `dory disk` reports host free space, Docker `/system/df` categories, Dory state/log/VM disk estimates; `dory cleanup` dry-runs safe cleanup for stopped containers, dangling images, build cache, logs, and opt-in volumes; `dory routes` lists published ports, inferred local domains, owners, and port conflicts. |
| Non-destructive repair | ✅ | `dory repair [target] --apply`, `dorydctl network repair`, and the Health screen share the daemon-owned repair contract. DNS and domains restart in place, routes are re-derived, published ports are reconciled by dory-hv, and the guest agent must pass a fresh clock-sync RPC. Socket repair no longer reports success while its socket is absent. Docker API repair verifies health and fails closed with an explicit workload-aware engine restart decision instead of silently destroying workloads. `dory repair all --apply` acts only on subsystems that report a problem. |
| P0 release smoke | ✅ | `scripts/p0-smoke.sh` gates doctor, network, mount, Docker CLI stdout, Compose up/down, localhost port publish, and all six daemon-owned recovery targets against a running Dory socket. The port path must be acknowledged by dory-hv, and the published HTTP workload must remain reachable after repair. |
| Runtime mode settings | ✅ | `dory mode manual|auto-idle|always-on|battery-saver|show` persists the user's intended availability mode and last confirmed running/sleeping intent through doryd. Rejected app/CLI changes leave the applied value visible and unchanged. Always On starts after daemon/host restart; the other modes restore whether the engine was awake or deliberately sleeping. `dory idle status` reports doryd's live engine state and explains blockers such as running containers, published ports, pinned labels, and Kubernetes config. |
| App-managed Auto-Idle | ✅ | Opening Dory is an explicit request to make Docker usable, so the app promotes a sleeping doryd-owned tier to running. doryd remains the owner of runtime mode and may stop an empty engine again after the configured idle period while keeping state on disk; active or unknown workloads are preserved. Focused app and core tests cover app-triggered promotion and the idle stop policy. |
| Standalone archive Auto-Idle proxy | ✅ standalone only | `dory idle proxy --foreground` is limited to the separate headless archive. It keeps that archive's socket available, wakes its private engine on API use, and records standalone state. Dory.app and doryd do not read those proxy files: their status and history come from the live Docker tier and confirmed lifecycle incidents. Cold-wake tests cover half-close behavior, awake concurrency, and a 16-client herd whose engine start coalesces exactly once. |

## OrbStack parity surface

All verified end-to-end on the shared-VM backend (default). System-wide binds (:53/:80/:443) and the
CA trust install remain consent-gated, the same one-time admin grant OrbStack needs.

| Capability | Status | Notes |
|---|---|---|
| Native GUI (menu bar + main window) | ✅ | All screens, both themes; one-click toggles for k8s/machines/shared-VM |
| Standalone engine + shared-VM memory | ✅ architecture | Default backend; Dory runs its own `dockerd` in one VM, with guest free-page reporting and no OrbStack/Docker/Colima/Apple container install. Current total-product competitor measurements do not support a memory multiplier; see `BENCHMARKS.md`. |
| Native IPv6 + `localhost` publishing | ✅ current-source gate | Dory's provenance-pinned gvproxy derivative carries an IPv6 gVisor stack, NDP multicast switching, AAAA forwarding, and IPv4/IPv6 NAT. Docker's bridge assigns global-scope ULA addresses and registry AAAA works; the formal gate proves IPv6 TCP through gvproxy, restart persistence, and published TCP through both `127.0.0.1` and `[::1]`. Publication additionally requires external IPv6 TCP on the exact notarized artifact. Explicit IPv4-loopback bindings are never widened by LAN mode. |
| Automatic `*.dory.local` domains | ✅ | `DoryDNS` resolver + `DoryReverseProxy`; verified `http://name.dory.local → 200`. System-wide via consent script |
| Automatic local HTTPS | ✅ | `DoryTLSProxy` terminates TLS with a `LocalCA` identity; verified `https://name.dory.local → 200` |
| **Bind-mount file sharing** | 🔒 current source; exact physical gates pending | Home and `/Volumes` are shared into the VM at identical paths (virtiofs), so `docker run -v ~/proj:/app` and explicit `/Volumes/MySSD/...` binds resolve to host storage. Current source virtualizes guest `chown` UID/GID without changing host APFS ownership, rejects special-file opens without blocking a vCPU, and implements owner-isolated POSIX record locks and BSD `flock`, including interruptible blocking requests and release/crash cleanup. Mandatory gates cover two-container shared/exclusive/upgrade/range/blocking/crash behavior, 10,000-open FD stability, restrictive hard links, and marked dedicated-volume unmount/missing-bind rejection/remount without an internal shadow path. Home-path protocol/coherence proof is green; the exact notarized candidate and writable physical external APFS drive still require certification. Virtual ownership is engine-lifetime state, so normal image entrypoints should reapply it after an engine restart. |
| Apple GPU AI workloads | ✅ host-service bridge | Containers can reach Metal-backed macOS services at `host.dory.internal` on ports `11434` (Ollama), `1234` (LM Studio/OpenAI-compatible local servers), and `18190` (readiness/custom). Verified from the default Docker bridge and a user-defined bridge network |
| In-guest GPU compute (Venus/Vulkan) | 🟡 experimental, Apple silicon | Opt-in via **Settings → GPU Acceleration** on Apple silicon: virtio-gpu with Mesa's Venus driver in the container → virglrenderer → MoltenVK → Metal. Verified end-to-end on an Apple M2 Pro: `vulkaninfo` enumerates `Virtio-GPU Venus (Apple M2 Pro)` with compute queues, and real fence workloads pass (25 `vkQueueSubmit` + `vkWaitForFences` cycles). Public full releases require a provenance-verified arm64 GPU kernel and the renderer payload; the Intel toggle is disabled because no physical Intel Venus result or x86 GPU kernel is claimed. The container needs Mesa Venus (`mesa-vulkan-drivers` + `--device /dev/dri/renderD128`). Not raw GPU passthrough — API remoting is the platform's strongest form of GPU access |
| One-click Kubernetes | ✅ | `KubernetesProvisioner` runs k3s in the shared VM; verified host `kubectl` + pod deploy; GUI "Enable" button |
| Linux machines (Ubuntu/Debian/Fedora/Alpine) | 🔒 exact resource-cycle gate pending | Full Linux machines are isolated VMs, not Docker containers. doryd owns one `dory-vmm` helper per machine with durable machine definitions, status, start/stop/delete, snapshots, terminal/shell attach, mounts, ports, resources, recipes, and assignable `*.dory.local` addresses. Running cards sample real guest CPU and used/total memory every two seconds instead of showing allocated memory as usage; `dorydctl machine stats` exposes the versioned CPU, memory, network, block-I/O, process, and uptime contract. CPU/memory edits are enforced at the same 1–8 CPU and 1–16 GiB boundary in both UI and daemon before a running VM is stopped or its definition changes. The rebuilt 8/8 Apple-Silicon UI suite exercises both complete bounds without a crash; the exact public signed-artifact 1→8→2 guest-visible restart cycle and stats proof remain required. |
| Non-native CPU translation | ✅ FEX on Apple Silicon | New Apple Silicon installs enable Dory's bundled FEX/binfmt runtime by default; **Settings → Run Intel (x86/amd64) images** remains an opt-out. `--platform linux/amd64` uses the same networked arm64 VM, while Dory's OCI wrapper supplies FEX to ordinary containers, `docker exec`, and BuildKit. Gates cover Alpine/Debian execution, Node/npm build/test/runtime, Nix GC, GNU tar hard links, and an unmodified Arch `pacman` sandbox that installs its own nested seccomp filter. The runtime is provenance-pinned and offline; it does not pull `tonistiigi/binfmt` on Apple Silicon. Native arm64 remains faster, and an untested x86-only product is not implied merely by this development-image contract. (GitHub #3) |
| Volume file browser | ✅ | `VolumeBrowser`; verified list + read files inside volumes; GUI sheet |
| Terminal / SSH into containers + machines | ✅ | `TerminalLauncher` opens Terminal.app against Dory's socket/engine |
| Docker Desktop / OrbStack migration | ✅ full current-source gate | `MigrationAssistant` imports images, container writable layers, named-volume contents, user networks, and containers into Dory's shared VM. It preserves custom-network driver/IPAM/options and container endpoint intent, uses collision-resistant per-source ownership for safe retries, verifies same-tag images by portable config/rootfs contract, rejects unsafe collisions before writes, never pauses source workloads implicitly, and bounds/cancels multi-gigabyte transfers. Inventory and cleanup are transactional and capacity admission fails closed. The 66-test migration suite and disposable two-engine gate pass with two volumes, a 64 MiB checksum, metadata/links, custom IPAM, writable-layer recovery, state restoration, fixed-port handoff, and exact baseline cleanup. The gate is mandatory in Apple Silicon release qualification. |
| Managed local settings | ✅ foundation | Settings can generate an MDM/config-friendly JSON profile covering engine route, domains, DNS/proxy ports, Auto-Idle policy, file-sharing policy, scoped sandbox mounts, hidden credential stores, env allow-list, and telemetry mode `none`. No server is required. |
| `*.k8s.dory.local` service domains | ✅ HTTP + HTTPS | `doryd` keeps `kubectl proxy` and service-domain routes reconciled; the reverse/TLS proxy rewrites `<svc>.<ns>.k8s.dory.local` → the API service proxy. Verified `http`+`https → 200`. TLS cert carries per-namespace wildcard SANs (`*.default.k8s.dory.local`, `*.kube-system.k8s.dory.local`); other namespaces would need their wildcard added |
| `dory` CLI (OrbStack's `orb`) | ✅ | `scripts/dory` wraps the engine, machines, kubectl, diagnostics, disk/routes, repair, and runtime mode/idle status |

### Bundled VM helpers: local release surface

Several features need low-level VM control below Docker's API. For 0.3 the shipping local surfaces
are doryd's shared Docker engine VM (`dory-hv`) and isolated Linux machine VMs (`dory-vmm`, one
helper per machine). Older one-off VM experiments remain outside the app UI and are not release
positioning.

| Capability | Status | Delivery |
|---|---|---|
| Shared Docker engine VM | ✅ | doryd owns one persistent `dory-hv` helper for Docker/Compose/Kubernetes workloads and can stop an empty engine while preserving `/var/lib/docker` on disk. Current raw-HV and VZ helpers require an explicit state directory and take a nonblocking exclusive lock before attaching persistent storage, preventing two VMs from mounting the same ext4 disk. |
| Isolated Linux machines | ✅ | doryd owns one `dory-vmm` helper per machine; machines are real Linux VMs, not Docker containers. The app shows live guest CPU and used/total memory, and the CLI's versioned stats output includes network, block I/O, PIDs, and uptime. |
| Machine addresses | ✅ | Machine definitions include assignable addresses; the app and CLI surface copyable terminal commands such as `dory ssh dev` |
| Host file mounts | ✅ | Containers use Docker bind mounts through the shared engine; machine mount definitions are persisted by doryd and applied on restart |
| Common x86 / amd64 images | ✅ | Apple Silicon uses the bundled FEX runtime for the tested day-to-day contract: Alpine/Debian execution, Node/npm BuildKit build/test/runtime, Nix GC, nested-seccomp Arch/pacman, and GNU tar. It is on by default for new installs and can be disabled in Settings. Intel-host support is a later track. |
| Memory reclaim | 🟡 | Guest free-page reporting is implemented. Pressure-triggered target reclaim is the opt-in experimental `senpai` mode, not the production default. Auto-Idle can stop an empty engine while keeping state on disk. No total-product memory winner is claimed without attributed same-host measurements. |
| USB/audio passthrough | 🚧 | Not a 0.3 release claim. USB remains the usbip-over-vsock roadmap path; audio device UX is not exposed in the app |

## Packaging: does the user need anything besides Dory.app?

The public production track is Apple Silicon first. Intel remains a later roadmap phase and is not
part of the current release, Sparkle, Homebrew, or qualification contract:

| Flavor | Contents |
|---|---|
| `Dory-x.y.z.dmg` / `.zip` | Full arm64 app: bundled engine, provenance-verified Apple-silicon kernel/GPU payload, Venus renderer, offline engine rootfs, Docker/Compose/kubectl CLIs |
| `Dory-x.y.z.cdx.json` | CycloneDX 1.6 inventory cryptographically bound to every file and symlink in the exact shipped app and to its source commit |
| `Dory-x.y.z-lite.zip` | The app alone (~6 MB): fronts an engine you already run via Settings → Engine Backend |
| `dory-engine-x.y.z-arm64.tar.gz` | Headless engine runtime (Colima-style): `dory-hv`, `gvproxy`, the same Docker-create dataplane used by Dory.app, kernel, guest agent, and a `dory-engine start/stop/status` launcher that publishes `~/.dory/engine.sock` and a `dory-engine` docker context. Apple Silicon starts with bundled FEX/amd64 enabled; `--no-amd64` is the explicit opt-out. CPU, memory, translation, GPU, LAN, and selected data-drive settings persist across stop/start. `start --lan-visible` remains explicit opt-in; explicit loopback Docker binds remain loopback-only. |

Status of the full flavor:

| Component | Bundled? | How |
|---|---|---|
| In-process engine (`dory-hv` + `dory-vm` helpers) | ✅ verified | `scripts/bundle-engine.sh` builds + signs the Hypervisor.framework `dory-hv` helper, `gvproxy`, and the Virtualization.framework fallback helper into `Contents/Helpers` with the required entitlements. |
| VM kernel + initfs | ✅ verified | Compressed into `Contents/Resources/*.lzfse`; decompressed once on first launch with Apple's Compression framework. No external `zstd` binary or dylib is required. |
| Engine rootfs / `dockerd` payload | ✅ bundled for offline releases; internal one-time fetch in dev bundles | Offline releases include `dory-engine-rootfs.ext4.lzfse` when the release runner provides `DORY_ENGINE_ROOTFS` or a prepared rootfs. Development bundles can still fetch `docker:dind` once internally on first boot. Neither path requires Docker Desktop, Colima, OrbStack, Homebrew, or Apple `container` on the user's Mac. |
| `docker` CLI + Buildx + Compose + `kubectl` | ✅ bundled | `Contents/Helpers/docker`, `docker-buildx`, `docker-compose`, and `kubectl` ship with the app. Optional shell integration links them into `~/.dory/bin` and installs the Buildx and Compose plugins into `~/.docker/cli-plugins`, all per-user and reversible. |
| macOS 14+ (Sonoma) | app requirement | The SwiftUI app and Docker-compatible host-engine mode build and run with a macOS 14 deployment target, matching OrbStack's floor. The app links no Virtualization/Hypervisor code and uses no macOS-15-only API. |
| macOS 14+ (Sonoma) built-in engine | supported target | With matching guest assets, Sonoma routes the shared Docker VM through the bundled Virtualization.framework `dory-vmm` tier. If neither that tier nor the macOS-15+ raw `dory-hv` tier is available, Dory degrades explicitly to Docker-compatible proxy mode instead of claiming that its own engine is running. |
| Apple silicon built-in engine | verified standalone engine | The native `dory-hv` shared engine is verified on Apple silicon. |
| Intel built-in engine | roadmap, not shipped | Implementation remains available for later development, but no Intel/universal artifact is published or claimed complete in the Apple-Silicon-first release. |
| Apple Container backend | ⛔ unsupported / not required | Dory 0.3 does not expose or require Apple's separate `container` CLI. It may appear only as a benchmark competitor when installed separately on the same Mac. |

So: **a self-contained standalone Dory.app works on Apple silicon**, verified end-to-end
(`DORY_BUNDLE_ENGINE=1`): a re-signed bundle that passes `codesign --verify --deep --strict`,
ships the helpers, CLIs, kernel/initfs, networking, and optional offline engine rootfs, and
requires no Homebrew, no Docker Desktop, no Colima, no OrbStack, and no Apple `container` install.
Building a self-contained bundle needs the arm64 guest kernel/initfs assets available on the release
runner, and a fully offline first boot also needs a prepared engine rootfs.

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
| VS Code/Cursor Dev Containers | App installed, `docker` on PATH, engine route; the mandatory pinned official CLI gate proves image resolution, create/start, exec, host→container and container→host workspace coherence, and exact cleanup | `"dev.containers.dockerPath"` + `dory` context |
| Testcontainers | Host client uses Dory; Ryuk mounts the guest-local daemon socket | `export DOCKER_HOST=unix://$HOME/.dory/dory.sock TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock` |
| SSH agent in containers | The built-in raw-HV and macOS 14 VZ engines expose a dedicated guest-local socket backed by the current same-user macOS agent; release gates compare public identity hashes across one and eight concurrent clients and again after a VZ restart | `-v /run/host-services/ssh-auth.sock:/agent.sock -e SSH_AUTH_SOCK=/agent.sock`; mount only into trusted containers |
| GitHub Actions `act` | The host process uses Dory's macOS socket while runner containers mount the daemon's guest-local socket; the checksum-pinned gate executes a real workflow on a digest-pinned runner, proves two-way workspace coherence, and cleans every object | `export DOCKER_HOST=unix://$HOME/.dory/dory.sock`, then `act --container-daemon-socket unix:///var/run/docker.sock` |
| Supabase local | CLI present + engine reachable; the mandatory checksum-pinned 2.109.1 gate starts the complete default 12-container stack, preserves Docker SDK request classification after streamed pulls, maps Vector to the guest-local daemon socket, verifies every declared healthcheck plus Postgres/migration/seed, PostgREST, Auth, Storage, loopback-only listeners, stop, and exact cleanup | `export DOCKER_HOST=unix://$HOME/.dory/dory.sock`, then `supabase start` — no Supabase-specific socket override is required |
| LocalStack | The digest-pinned 4.14.0 gate proves a loopback-only dynamic host listener, health convergence, S3 bucket/object round-trip, SQS queue/message round-trip, and exact cleanup | `localstack start -d`, verify `:4566/_localstack/health` |
| Tilt | The checksum-pinned 0.37.5 gates run real `tilt ci` over both Docker Compose and a nested digest-pinned k3s cluster. They prove Compose health/two-way workspace coherence and Kubernetes rollout/NodePort HTTP, then run `tilt down` with namespace deletion and exact cleanup | Docker Compose works immediately; Kubernetes projects use a reachable kubeconfig/context |
| Skaffold (Kubernetes) | The checksum-pinned 2.23.0 gate deploys to digest-pinned k3s, waits for rollout, proves NodePort HTTP through a loopback-only Dory listener, deletes the namespace, and restores the exact Docker-object baseline | Point `KUBECONFIG` at the target cluster; the release gate exercises the candidate-bundled `kubectl` |

Each row's recipe has a verification command; run `dory compat` for the live status on your machine
and `dory compat --recipe` for the full set. The current isolated runtime passed
`@devcontainers/cli` 0.87.0, checksum-pinned `act` 0.2.89, digest-pinned LocalStack 4.14.0,
checksum-pinned Tilt 0.37.5 (Compose and Kubernetes), Skaffold 2.23.0 on k3s 1.36.2, and checksum-pinned Supabase CLI 2.109.1 end to end. Release qualification rejects missing, rehashed but
incomplete, version/image-mismatched, wrong-socket, widened-loopback, unhealthy, or non-clean
evidence.

## Architectural / environment notes

- **Shared VM vs one-VM-per-container.** Dory's shipping engine runs containers in one shared Linux
  VM. Apple's separate Container CLI is not a Dory backend; it is only a useful competitor row when
  installed on the same Mac for benchmark context. This makes Dory a standalone engine, but it is
  not evidence of a total-product memory win over current OrbStack or Docker Desktop; publish a
  multiplier only after the attribution-safe repeated campaign in `BENCHMARKS.md` is green.
- **File-sharing performance** for release claims must come from `scripts/benchmark-compare.sh`
  artifacts on the same Mac and engine versions being compared.
- **Distribution.** Release automation builds an Apple-silicon app artifact,
  signs it with Developer ID, submits it for notarization, staples the ticket, generates the
  Sparkle appcast, and bumps/syncs the Homebrew Cask. A clean-user gate now makes the real
  `Package.resolved`-pinned Sparkle updater replace and relaunch the previous public app, then
  verifies the complete installed tree, workload/settings state, and rollback. Strict Homebrew
  audit runs on an isolated compatible macOS job bound to the candidate ZIP/version/SHA, so the
  physical Xcode 26.6 release host does not need Xcode 27. The remaining external gate is
  operational execution with the Developer ID/notary credentials, Sparkle key, Homebrew tap token,
  and bundled engine assets before publishing.
- The app runs **unsandboxed** (like Docker Desktop/OrbStack) to reach the engine socket and
  host its own socket.
- Arbitrary host Unix sockets are not passed through virtiofs. SSH-agent access uses the single
  dedicated `/run/host-services/ssh-auth.sock` bridge and is opt-in per container mount.
