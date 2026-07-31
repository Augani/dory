# Changelog

## Unreleased

### Fixed

- Fixed `dory mcp serve` on macOS, where launching the embedded Python server via
  `python3 /dev/fd/3 … 3<<'PY'` could exit immediately with no MCP output under Apple Python
  and bash. The server is now written to a temporary file before execution so stdin remains free
  for stdio MCP.
- Renamed stdio MCP tool identifiers from dotted names (`dory.engine_status`) to underscore names
  (`dory_engine_status`) so MCP hosts that only accept `[a-zA-Z0-9_-]` no longer drop every tool.

## 0.4.2 - 2026-07-22

### Added

- Added Agent-ready named sandboxes with a core coding toolkit, optional or automatically detected
  project toolchains, persistent caches, an explicit read-write workspace, and a clean prepared
  baseline that can be restored with `dory sandbox reset`.
- Exposed named sandbox create, exec, reset, inspect, list, and kill operations to local agents
  through Dory's CLI, versioned agent guide, and stdio MCP server.

### Fixed

- Fixed sandbox runs racing the Linux machine agent during start, snapshot, and rollback. Dory now
  waits for full machine readiness, restores firewall policy after restarts, and cleans up failed
  setup without leaving an incomplete machine behind.
- Fixed allowlisted outbound sandbox DNS using a hardcoded resolver address. Dory now applies the
  active guest resolver and preserves a named sandbox's network policy when it is reused.
- Fixed `linux/amd64` Go builds on Apple Silicon that could crash randomly during asynchronous
  preemption, including Go 1.26 builds based on Alpine 3.23.
- Fixed bind-mounted host folders rejecting writes from containers whose user ID differs from the
  signed-in macOS user, while preserving the requesting container user's ownership inside the VM.
- Fixed OrbStack image migration when an archive repeats tag or OCI index records for the same
  immutable image. Dory now safely coalesces those aliases and still rejects true multi-image
  archives.

## 0.4.1 - 2026-07-22

### Fixed

- Fixed Linux desktop creation using the Debian root filesystem lookup even when Ubuntu or Kali
  was selected, which could report `missingAsset("root filesystem")` after the correct component
  was installed.

## 0.4.0 - 2026-07-21

### Added

- Graduated agent sandboxes to a supported dedicated-VM contract: non-root execution, read-only
  mount defaults, enforced deny/allowlist/full egress, ephemeral secret and SSH-agent grants,
  CPU/memory/disk/process/FD/wall caps, named reuse, manifests, kill/list/inspect commands,
  rollback, daemon-owned crash-safe TTL cleanup, a published threat model, and an exact-candidate
  inside-VM negative qualification gate.
- Added a versioned nine-stage readiness contract for cold start, wake, and recovery, with
  reason codes, per-stage timing/deadlines, repair ownership, `dory readiness --json`, and a Health
  timeline that never treats a running VM as proof that Docker works.
- Added compact resource diagnostics for attributed physical footprint, FDs, threads, guest
  used/cache/reclaimable memory, sparse and guest disk usage, conservative reclaim previews,
  watcher roots/backpressure, owned network resources, and early monotonic-growth warnings.
- Added a guided, reversible corporate connectivity profile for macOS/PAC observation, dockerd,
  BuildKit/container proxy injection, registry mirrors, scoped CAs, split DNS and VPN subnet
  collisions, with exact per-probe DNS/route/proxy/CA provenance and automatic startup/network/wake
  reconciliation.
- Added transactional Sparkle, component, configuration, and data-schema upgrade coordination:
  signed candidate/schema preflight, exact last-known-good records, verified snapshot references,
  next-launch Docker/volume/container/port/Kubernetes smoke tests, automatic safe rollback, and an
  owner-only recovery export when durable data cannot be downgraded safely.
- Added Updates UI plus `dory upgrade status|recovery --json` for inspecting active, rolled-back, or
  recovery-required transactions without reading private journal files directly.
- Added an exact-candidate performance publication contract and clean-account release campaign for
  isolated/default and matched/interleaved Dory, OrbStack, and Colima runs. Raw Rails/Bundler, npm,
  pnpm, Composer, registry, external-network, correctness, provenance, and cleanup evidence is
  digest-verified and attached to the matching release instead of reduced to screenshots.
- Added Build Activity for Dory-launched builds, including durable history, live status, cache use,
  logs, and cancellation without claiming ownership of builds started by unrelated clients.
- Added exact partial migration selection with automatic dependency closure, selected-scope
  capacity and portability checks, transactional rollback, source-drift rejection, and a final
  selected/imported/verified/omitted completeness report.
- Added daemon-owned scheduled local machine backups with owner-only durable schedules, retention,
  bundle re-import verification on every run, disposable boot verification on the first and
  configured periodic runs, atomic publication, status/UI/CLI controls, and strict separation from
  manual snapshots.
- Published one production architecture and capability-status contract covering Dory.app, doryd,
  raw-HV, the macOS 14 VZ fallback, the shared Rust dataplane/guest protocol, networking, durable
  storage, update safety, and trust boundaries.
- Published post-0.4 implementation designs and promotion gates for safe image import, an MCP
  catalog/gateway, remote workspaces, image update checks, bounded mDNS relay, and GPU stabilization.

### Fixed

- Added a Finder Location for Dory storage that appears while Dory is running, disappears when the
  app and engine stop, and shows local files without cloud download badges.
- Made the Docker data disk sparse and grow on demand, added regular filesystem trimming, and
  capped automatic BuildKit cache retention at 2 GB so unused space is returned to macOS.
- Fixed `linux/amd64` containers and builds on Apple Silicon that require a 4 KiB page size,
  including Alpine 3.23 images using jemalloc.
- Added host-ID compatibility and safer OrbStack migration handling so imported Docker data keeps
  the correct ownership and metadata.

- Replaced Docker promotion polling with lifecycle transition waiters and implemented bounded
  guest-agent reconnect, socket-forwarder replacement, dockerd-only restart, route reconcile, and
  data-drive revalidation without deleting workloads or resetting the VM.
- Removed the production escape hatch to the retired app-owned local engine and deleted two orphaned
  Apple containerization/VM-boot prototype source paths that were not build targets or dependencies.

- Added weekly Dependabot coverage, Rust/npm vulnerability audits, pull-request dependency review,
  CodeQL for Swift and TypeScript, and fail-closed source security contracts to public CI.
- Upgraded the remote SSH stack to the allocation-safe russh 0.60.3 line, removed unused RSA
  algorithms from every compiled target, and upgraded UniFFI to 0.32 to eliminate unmaintained
  bincode and paste dependencies.
- Authenticated doryd XPC peers by effective user and, for production builds, Dory team/signing
  identity before exporting the daemon control surface.
- Removed unused JIT, unsigned-executable-memory, and virtualization entitlements from the main app;
  virtualization remains scoped to the dedicated signed VMM helpers.
- Removed the unauthenticated guest-network Docker API on TCP 2375. Dory now keeps dockerd on its
  private Unix socket and uses the existing vsock relay for all supported host access.
- Made USB capability reporting fail closed: the app and CLI now expose host discovery but clearly
  disable passthrough attach, detach, and replay until the missing guest USB/IP RPC is implemented.
- Made migration capacity validation use the selected Docker data drive's real ext4 capacity rather
  than a fixed 120 GiB ceiling, with safe growth guidance when an import needs more space.
- Replaced the fragile PF-only dependency for local ports 80, 443, and other published low TCP
  ports with Dory-owned wildcard listeners that accept loopback peers only, preserving standard-port
  custom domains when macOS does not evaluate the nested PF redirect anchor.
- Extended active Doctor domain checks through the real standard HTTP and HTTPS ingress paths so a
  working high-port proxy can no longer hide a broken low-port listener or redirect.
- Routed destructive keyboard, menu, row, context-menu, CLI, migration, cleanup, component, and
  missing-drive paths through explicit-scope confirmation or recoverable undo contracts, with
  offline source gates preventing a shortcut from bypassing the confirming UI.

## 0.3.2 - 2026-07-17

### Added

- Replaced fixed app editions with a smaller Docker Core app and signed, removable Kubernetes,
  Linux Machines, Linux Desktop runtime, Debian, Ubuntu, and Kali components stored on the selected
  Dory data drive.
- Added a pre-download component selector that safely carries the chosen optional payloads into
  Dory for signed-size review and explicit installation confirmation.
- Retired the separate public lite app so direct downloads present one Docker Core app and optional
  signed components instead of overlapping app editions.
- Added exact and leftmost-wildcard custom domain mappings in Settings > Network and the CLI. Dory
  now routes nginx-style `/etc/hosts` domains through its built-in HTTP and trusted HTTPS proxies.

### Changed

- Reused Docker Core's signed engine kernel and rootfs for the macOS 14 fallback instead of storing
  duplicate compatibility copies, removing about 112 MB from the installed Core app.
- Quitting Dory now stops its background engine by default. People who want an always-running
  engine can explicitly enable **Keep engine running after quit**.

### Fixed

- Fixed built-in safe home sharing so names such as `library` are hidden only at the shared home
  root, while nested project directories such as Composer package paths remain visible.
- Fixed the Network authorization button so the guided admin operation succeeds before optional
  background-service registration and Login Items approval.
- Fixed local HTTPS authorization failing after the admin prompt. Dory now adds its CA to the
  current user's login keychain through an interactive macOS trust prompt, while the privileged
  helper is limited to resolver and PF changes.
- Fixed custom local domains returning 502 after ports 80 and 443 were authorized.
- Fixed local HTTPS identity refreshes accumulating certificates and private keys in the user's
  login keychain.
- Fixed stale container details remaining open after the selected container disappeared or no
  longer matched the current view, and added toolbar controls for hiding navigation and details.
- Fixed reopening Dory from the Dock or menu bar when the app was running without a visible window.
- Fixed `linux/amd64` builds on IPv4-only host networks by withholding unreachable IPv6 DNS
  answers while preserving native IPv6 when the Mac has a routable IPv6 path.

## 0.3.1 - 2026-07-16

### Added

- Added a dedicated Linux Desktops experience with managed Debian 13, Ubuntu 24.04 LTS, and Kali
  rolling Xfce guests, configurable users and resources, scoped Mac folders, snapshots, and
  persistent disks on the selected Dory data drive.
- Added Retina-sharp, dynamically resizing desktop windows with a true 2x guest framebuffer and
  matching Xfce scaling.
- Added separate lean and all-inclusive Desktop builds so people who only need containers,
  Kubernetes, and headless Linux do not download the graphical guest images.
- Added edition-specific signed update feeds so Lean and Desktop installations stay on their chosen
  footprint during future upgrades.
- Added a preferred external terminal setting for Terminal, iTerm2, Ghostty, Warp, WezTerm,
  Alacritty, Kitty, the system default, or another selected application.
- Added a configurable Docker bridge subnet for avoiding VPN or local-network conflicts.

### Changed

- Rewrote the public README around the full Docker, Kubernetes, Linux Desktop, migration, storage,
  networking, diagnostics, settings, and automation surface.
- Rebuilt the GitHub Pages site for people and agents, including `llms.txt`, a complete agent
  reference, a versioned JSON capability map, focused operations and compatibility guides, and an
  interactive code-built Dory interface.
- Clarified the Apple Silicon host contract, Desktop and lean editions, preview sandbox policy,
  USB/IP workflow, and deferred Intel work.

### Fixed

- Fixed first-run privileged networking registration when macOS reports an absent service record as
  not found even though the signed helper is present in the app bundle.
- Hardened graphical guest creation, first boot, image provenance, and packaged-helper cleanup.

## 0.3.0 - 2026-07-15

The first self-contained Apple Silicon release.

### Added

- Built-in shared-VM container engine with persistent local storage.
- Bundled Docker CLI, Buildx, Compose v2, and `kubectl`.
- Container, image, volume, network, Compose, and Kubernetes management in the native app.
- Linux machines with terminal access, snapshots, resource controls, and development recipes.
- Managed `.dorydrive` storage with backup, verify, restore, selection, and growth commands.
- Migration preflight and import for local Docker-compatible engines.
- Local domains, HTTPS, diagnostics, support bundles, and targeted repair actions.
- Apple Silicon support for common amd64 images through the bundled FEX runtime.
- Full app, lite app, DMG, ZIP, Homebrew, and headless-engine distribution formats.

### Changed

- Public releases focus on Apple Silicon; Intel Mac support is deferred until dedicated hardware
  validation is complete.
- Uninstall preserves the selected data drive unless the user explicitly removes workload data.
- Runtime caches and VM boot state are separated from the durable data drive.

### Fixed

- Improved engine restart, socket recovery, bind-mount coherence, Compose lifecycle, port reuse,
  registry authentication, BuildKit cancellation, and non-native execution behavior.
- Removed test-runner payloads from public app archives to avoid misleading macOS damage warnings.

## 0.2.0 - 2026-07-02

- Introduced the Docker-compatible local runtime, container UI, networking, and initial Linux
  machine support.

## 0.1.0 - 2026-06-19

- Initial open-source preview.
