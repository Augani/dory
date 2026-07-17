# Changelog

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
