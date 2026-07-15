# Changelog

## Next

- Incorporate feedback from the first Apple Silicon release.
- Improve external-drive, backup, migration, VPN, IPv6, sleep/wake, and recovery workflows.
- Expand ecosystem compatibility and reduce idle resource use.
- Keep Intel Mac support as a separate hardware-qualified release track.

## 0.3.0 — 2026-07-15

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

## 0.2.0 — 2026-07-02

- Introduced the Docker-compatible local runtime, container UI, networking, and initial Linux
  machine support.

## 0.1.0 — 2026-06-19

- Initial open-source preview.
