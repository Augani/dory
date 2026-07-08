# Changelog

## 0.3.0 - Local Runtime Release Candidate

This release is focused on the local product: a clean-Mac app, low-memory runtime, Docker-compatible
workflow, Linux machines, migration confidence, managed settings, and public benchmark evidence.
Remote engines, cloud backup, relay services, and phone workflows remain intentionally deferred.

### Added

- Self-contained release shape with Apple-silicon, Intel, and universal app artifacts, plus a lite
  app and an arm64 headless engine tarball.
- Bundled Docker CLI, Docker Compose v2, and `kubectl` for clean Macs.
- doryd-backed engine ownership with durable on-disk state and Linux machine lifecycle.
- Full Linux machines as isolated VMs, not Docker containers, with addresses, terminal commands,
  snapshots, resource settings, mounts, ports, and recipes.
- Migration confidence report for Docker Desktop and OrbStack sources, including transfer items,
  attention items, estimated image disk, Compose projects, bind mounts, volume references, and
  risky container modes.
- Managed settings profile preview for local team rollout: engine route, domains, DNS/proxy ports,
  Auto-Idle policy, file-sharing policy, sandbox mount policy, hidden credential stores, env allow
  list, and telemetry mode `none`.
- App and menu-bar memory reporting for Dory processes.
- Public benchmark playbook and cross-engine GitHub workflow.

### Changed

- The app now attaches to a sleeping doryd without waking the heavy engine, so opening Dory does not
  by itself start `dory-hv`.
- doryd's idle policy can stop an empty Docker tier while keeping state on disk; active or unknown
  workloads are preserved.
- macOS 14 is the app floor. The built-in low-memory engine remains gated to macOS 15+ where Apple
  host APIs require it; macOS 14 can still use Dory with an existing Docker-compatible engine.
- Release bundling now uses the same default host CLI versions as the development build path.

### Fixed

- Prevented duplicate LaunchServices app instances with `LSMultipleInstancesProhibited`.
- Cleaned transient Xcode test products to avoid damaged `DoryUITests-Runner` quarantine/provenance
  prompts during local development.

### Known Limits

- Heavy amd64 images on Apple silicon still use qemu-user in the shared engine and can hit qemu
  segfault classes such as SQL Server and Oracle. Rosetta-speed amd64 is available only in one-off
  `dory vm` helper flows for now.
- Intel raw `dory-hv` support is wired and packaged, but full readiness remains gated by physical
  Intel Mac release testing.
- UDP forwarding, IPv6 localhost parity, and explicit LAN exposure are still tracked as network
  parity work before broad marketing claims.
