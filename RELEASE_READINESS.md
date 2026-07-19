# Dory 0.4 release readiness

Last updated: 2026-07-19.

## Decision

**NO-GO for 0.4 today.** The source implementation program in
`DORY_V0.4_RESEARCH_REPORT.md` is complete, including all three capacity-remains items. Dory's
GitHub issues are treated as fixed. The remaining work is exact notarized-candidate and physical or
long-duration environment proof; source tests cannot manufacture that release evidence.

## Evidence contract

A release may be called ready only when all of the following are true:

- The ordinary Rust, Swift-package, app, UI, offline-contract, security, dependency, and packaging
  jobs are connected to GitHub Actions and pass from a clean checkout.
- The candidate app, daemon, VMM, guest agent, kernel, rootfs, Docker CLI, Compose, Buildx, kubectl,
  gvproxy, optional components, update payload, and SBOM are hash-bound into one qualification
  manifest.
- Full and exact-selection migration, update/rollback, data-drive backup/restore, scheduled machine
  bundle/boot verification, sandbox isolation, readiness/recovery, file sharing, compatibility,
  resource ceilings, and data durability pass against those exact bytes.
- Hardware-only gates retain evidence for macOS 14 and current macOS, physical sleep/wake,
  corporate split-DNS/VPN/proxy/custom-CA paths, source-preserving LAN, and external APFS media.
- Every row in `COMPETITOR_ISSUE_COVERAGE.md` is `FULL`; source coverage alone cannot promote an
  exact-artifact row.

## Current 0.4 blockers

The Must Ship implementation contracts and the capacity-remains Build Activity, exact-selection
migration, and verified scheduled-backup contracts are present. Remaining blockers are candidate
and environment proof, not open GitHub bugs or unimplemented 0.4 product work:

- Produce one clean, notarized v0.4 candidate and bind its app, daemon, VMM, guest, components,
  update archive, release manifest, and SBOM hashes.
- Run the exact-candidate compatibility, eight-hour endurance, greater-than-24-hour connection,
  physical-network, corporate VPN/DNS/proxy/CA, sleep/wake, external-drive, full and partial
  migration, data-drive backup/restore, scheduled machine bundle/boot verification, sandbox,
  Docker-control-plane, and interrupted-update campaigns.
- Run the dedicated clean-account Dory/OrbStack/Colima performance campaign and attach its verified
  evidence ZIP to the matching release.
- Re-run the completed destructive keyboard/menu/CLI confirmation-and-undo audit against the exact
  release UI and retain its evidence.
- Promote every `SOURCE` coverage row in `COMPETITOR_ISSUE_COVERAGE.md` that requires hardware or an
  exact candidate to `FULL` only after its retained evidence passes.

USB passthrough is not a blocker because 0.4 now truthfully exposes discovery only; attach, detach,
and replay remain outside the advertised contract until the guest USB/IP RPC is complete.
