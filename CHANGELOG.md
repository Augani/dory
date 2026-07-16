# Changelog

## Next

- Rewrote the public README around the full shipped Docker, Kubernetes, Linux machine, migration,
  storage, networking, diagnostics, settings, and automation surface.
- Rebuilt the GitHub Pages site for people and agents, including `llms.txt`, a complete agent
  reference, a versioned JSON capability map, and focused operations and compatibility guides.
- Replaced static product screenshots on the site with an interactive code-built Dory interface.
- Clarified the Apple Silicon host contract, current Dory Linux boundary, preview sandbox policy,
  USB/IP workflow, and deferred Intel and graphical Linux work.
- Fixed first-run privileged networking registration when macOS reports an absent service record as
  not found even though the signed helper is present in the app bundle.

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
