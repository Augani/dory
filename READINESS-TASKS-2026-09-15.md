# ARM64 Ubuntu release-readiness closeout — 2026-09-15

## Release boundary

This closeout has one possible supported cell: **Ubuntu Server 24.04.4 ARM64** (`ubuntu-server-24.04.4-arm64`) on the existing M2 Pro host class (`Mac14,10`, 16 GiB, frozen operating-system build). The candidate configuration is 4 vCPUs, 8 GiB memory, a 64 GiB blank disk, the recorded Dory ARM firmware, and committed app, daemon, and runner revisions.

`DoryReleaseSupportPolicy` is the single capability source for public admission. Linux ARM64 is available; Linux x86_64, Fedora, and macOS are unavailable for this release. The UI presents the reason and the daemon rejects public creation independently. The x86 scheduler remains an internal correctness path only.

No item in this document authorizes publishing a release.

## Reconciled review ledger

- [x] Phase 0 build/test hygiene (`51ddd9790`) — implemented; qualification pending.
- [x] Phase 2.1 reset relaunch (`306bb9474`) — implemented; qualification pending.
- [x] Phase 2.2 ARM UEFI graphical console and keyboard (`8c8966d7e`) — implemented; qualification pending.
- [x] Phase 2.3 guest-fault behavior (`2e19ccea1`) — implemented; qualification pending.
- [x] Phase 2.4 mapped-page retry/`restorePage` escalation (`4116d4fb3`) — implemented; qualification pending.
- [x] Phase 2.5 durable `VIRTIO_BLK_T_FLUSH` path (`3da9ef9b7`) — implemented; qualification pending.
- [x] Phases 2.6–2.8 are implemented history, but outside this release boundary and still qualification pending.
- [x] The review's `guest/` finding is superseded: `583840fc1e` intentionally removed that tree. Managed Dory desktop-image production remains deferred; do not restore it for this candidate.

## Execution checklist

### 1. Internal x86 correctness work

- [ ] Run focused free-run scheduler regressions, including deterministic scheduling, global-budget accounting, wake-up, stop, and UEFI paths.
- [ ] Run the complete serial, timeout-protected `ContainerizationEngine` and `dory-core-swift` correctness suites.
- [ ] Commit the scheduler work only after both gates pass; record command output and revision in the evidence bundle.
- [ ] Keep x86 launch gated from public creation and out of the release matrix/campaign.

### 2. ARM production-facing regressions

- [ ] UEFI framebuffer is visible and keyboard navigation completes through GRUB.
- [ ] Installer reboot and in-guest `sudo reboot` relaunch without losing display, storage, networking, vsock, or renderer ownership.
- [ ] Guest-fault injection exercises retry and mapped-page escalation to the expected terminal behavior.
- [ ] `VIRTIO_BLK_T_FLUSH` uses the durable-storage path and reports injected full-flush failures.
- [ ] Retain focused test output for each check; implementation tests alone do not mark the cell qualified.

### 3. Freeze a clean candidate

- [ ] Record the Ubuntu 24.04.4 ARM64 ISO SHA-256 from the vendor artifact; do not substitute an unpinned or mutable input.
- [ ] Record firmware, app, daemon, runner, and component hashes from clean committed revisions.
- [ ] Verify the M2 Pro host class and candidate resources (4 vCPUs, 8 GiB RAM, 64 GiB blank disk).
- [ ] Confirm the candidate has no uncommitted work and contains no deferred guest family.

### 4. Two clean qualification campaigns

Run twice from independently clean frozen inputs. Store evidence under `docs/virtualization/evidence/readiness-2026-09-15/` without fabricating records for runs not yet performed.

- [ ] Fresh install and graphical UEFI/GRUB input.
- [ ] Installer reboot, cold reopen, package install/update, and agent command.
- [ ] Storage durability/recovery and full cleanup/resource-ownership checks.
- [ ] Preserve raw console and framebuffer output, command results, source/component hashes, environment facts, and failed attempts.

### 5. Release decision gate

- [x] Release matrix and catalog-facing capability text name only the Ubuntu ARM64 public cell and keep `releaseQualified: false`.
- [ ] Attach both campaign evidence records to the matrix review.
- [ ] Record independent approvals from the release owner, runtime owner, and security reviewer.
- [ ] Mark a release candidate qualified only after all evidence and approvals are present. Do not publish as part of this work.

## Deferred explicitly

macOS ARM64, Fedora, managed Dory desktop images, PCIe/xHCI, Linux snapshots, graphics qualification, and all customer-facing x86 availability are deferred from this milestone.
