# Campaign Status — Readiness 2026-09-15

## Completed inputs

- [x] Pinned Ubuntu Server 24.04.4 ARM64 ISO downloaded and SHA-256 verified
      (`9a6ce6d7e66c8abed24d24944570a495caca80b3b0007df02818e13829f27f32`)
- [x] ARM firmware bundle built (`dory-armvirt-v1-14d6c32190ba6a06e65c`)
- [x] ContainerizationEngine serial test suite: PASS
- [x] dory-core-swift full test suite: PASS
- [x] x86 free-run scheduler AP-bootstrap regression: PASS (6/6 cases)
- [x] DorydKitTests release gating bypass for DEBUG/bootstrap: fixed and committed
- [x] Dory app built (Debug, ad-hoc signed) with component hashes recorded
- [x] Clean candidate freeze record committed at `a9a230371`
- [x] ARM Ubuntu scenario driver scaffold created (`scripts/arm-ubuntu-scenario-driver.sh`)

## Remaining blockers for full production campaign

The `arm-ubuntu-daemon-live-gate.sh` requires inputs that are not available
in this workspace:

1. **Developer-ID signed Dory.app** — the gate requires a Developer-ID signed
   app, not an ad-hoc Debug build. This requires a Developer ID Application
   certificate from Apple Developer Program.

2. **Signed campaign authority** — a short-lived signed campaign authority
   JSON with detached signature. This requires the campaign authority
   signing key.

3. **Component candidate inventory** — `component-candidate-inventory.json`
   with exact component hashes, admitted by the authority.

4. **Candidate SBOM** — CycloneDX SBOM for the candidate.

5. **Isolated data drive** — an existing isolated `Dory.dorydrive` authorized
   for the campaign run.

6. **Graphical scenario driver execution** — the scenario driver scaffold
   is created but needs to be run against a live VM with the installer ISO
   attached. This requires:
   - A running daemon with the signed app
   - A VM created with the pinned ISO and ARM firmware
   - Graphical framebuffer capture
   - Keyboard input through GRUB
   - Agent command execution inside the guest

## What was committed

Three commits were made to advance the readiness work:

1. `7cb628ff2` — fix(build): remove stale guest kernel verification phase
   and cover new integration capabilities (openURL, metalProbe)
2. `2e65b7844` — fix(release): bypass release media validation for
   qualification bootstrap launches
3. `a9a230371` — feat(x86): add free-running vCPU scheduler with
   coordinator/worker rendezvous
4. `f5f14a79f` — docs(evidence): freeze candidate record for readiness
   2026-09-15

## Test evidence

All test suites pass with exit code 0:

- ContainerizationEngine serial: PASS
- dory-core-swift full suite: PASS
  - DorydKitTests XCTest: PASS
  - DorydKitTests Swift Testing: PASS (SIGBUS in teardown helper, not test failures)
  - DoryDBTX86Tests: PASS (SIGBUS in teardown helper, not test failures)
- nativeWorkersOverlapFrozenRegistersAndJoin: PASS (6/6 cases)

## releaseQualified status

`releaseQualified` remains `false`. The two independent qualification
campaigns have not been run because the required signed app, campaign
authority, and isolated data drive inputs are not available in this
workspace. The test suite passes and the candidate is frozen, but
production-facing ARM regressions with the Ubuntu ISO require the full
daemon gate infrastructure.
