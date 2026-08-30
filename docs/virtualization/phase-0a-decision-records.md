# Dory virtualization Phase 0A decision records

- **Authority:** `linux-and-macos-virtualization-delivery-plan.md`
- **Engineering approval:** user-directed implementation on 2026-08-30
- **Selected local SDK contract:** macOS SDK 27.0 from Command Line Tools
- **Scope:** Apple-silicon hosts; ARM64/x86_64 Linux and ARM64/x86_64 macOS guests
- **Approval boundary:** engineering direction is accepted. Legal opinions, Apple entitlement
  grants, signed/notarized release probes, and physical-lab qualification require their named
  authorities and cannot be inferred from this record.

These records are binding implementation constraints. An `Accepted` record authorizes engineering
work only after all dependencies and stop gates named in that record are satisfied. A record marked
`Blocked` prevents dependent feature work. Revisions require a new ADR revision, tests, and an
explicit migration or compatibility decision.

## ADR-001 — Execution engine and machine model boundary

- **Status:** Accepted for implementation.
- **Decision:** CPU execution, architectural exits, and memory mapping live behind
  `DoryExecutionContracts`; machine models own firmware, buses, interrupts, clocks, reset, and
  devices. A resolved launch pins both identities independently.
- **Owners:** Virtualization architecture and runtime.
- **Dependencies:** ADR-002, ADR-003, ADR-006, ADR-015.
- **Test strategy:** Contract tests run one fake engine against each machine and one machine against
  interpreter/native adapters without framework-specific exits escaping the boundary.
- **Exit gate:** No machine imports a desktop/control package; no engine inspects a workspace or
  selects firmware; launch receipts name both versioned identities.

## ADR-002 — Guest memory and dirty-page contract

- **Status:** Accepted for implementation.
- **Decision:** Guest memory uses checked, page-aligned regions with explicit ownership, overlap
  rejection, mapping generations, dirty epochs, bounded pinning, and an atomic snapshot barrier.
- **Owners:** Execution runtime and snapshot.
- **Dependencies:** ADR-001, ADR-003, ADR-024.
- **Test strategy:** Property tests cover range arithmetic and overlap; fault injection covers map,
  unmap, dirty rollover, pressure, cancellation, and restore races.
- **Exit gate:** Native and translated engines pass identical memory/dirty fixtures with no host
  pointer or mapping serialized into durable state.

## ADR-003 — Clock, interrupt, cancellation, and snapshot barriers

- **Status:** Accepted for implementation.
- **Decision:** Virtual monotonic and wall clocks, interrupt delivery/acknowledgement, cancellation,
  pause, and snapshot quiescence are engine-neutral, generation-bound, and restartable at precise
  architectural boundaries.
- **Owners:** Runtime, machine, and lifecycle.
- **Dependencies:** ADR-001, ADR-002, ADR-024, ADR-025.
- **Test strategy:** Deterministic clocks and replay cover interrupt races, cancellation at every
  exit, pause timeout, clock discontinuity, and late-event suppression.
- **Exit gate:** A barrier either captures one coherent generation or changes nothing; no canceled
  runner continues guest-visible mutation.

## ADR-004 — DoryARMVirt-v1 ABI

- **Status:** Accepted for design; freeze requires generated ABI tables.
- **Decision:** Preserve the working ARM physical layout as `dory.armvirt@1`, then specify RAM,
  GICv3, timers, RTC, serial, power, PCIe/MMIO, VirtIO transports, FDT/ACPI policy, UEFI handoff,
  interrupts, DMA, topology, hot-plug, and variable-store behavior.
- **Owners:** ARM machine and firmware.
- **Dependencies:** ADR-001, ADR-002, ADR-003, ADR-009, ADR-010.
- **Test strategy:** Golden ABI tables, FDT decoding, synthetic firmware, install/reboot/update, and
  snapshot compatibility fixtures.
- **Exit gate:** The ABI document and generated constants agree byte-for-byte and unmodified
  qualified ARM64 Linux media installs and reboots on the frozen model.

## ADR-005 — DoryPC-v1 ABI

- **Status:** Accepted for design; freeze follows interpreter correctness.
- **Decision:** `dory.pc@1` fixes its memory map, CPU topology binding, APIC/IOAPIC, timers, RTC,
  ACPI/SMBIOS, PCIe/BAR/MSI, VirtIO PCI, USB, reset/power, UEFI variables, and boot order independent
  of translator tier.
- **Owners:** PC machine, firmware, and x86 runtime.
- **Dependencies:** ADR-001, ADR-006, ADR-007, ADR-009, ADR-010.
- **Test strategy:** Identical machine-transition traces under interpreter, baseline JIT, optimizing
  JIT, and the non-shipping physical-x86 comparison harness.
- **Exit gate:** All tiers produce identical guest-visible state and install/reboot qualified
  x86_64 Linux media without a tier-specific device branch.

## ADR-006 — CPU profiles and migration rules

- **Status:** Accepted for implementation.
- **Decision:** CPU features are deny-by-default and exposed through immutable, versioned ARM64 or
  x86_64 profiles. First boot pins a profile; migration requires explicit semantic compatibility.
- **Owners:** CPU architecture and compatibility.
- **Dependencies:** ADR-001, ADR-007, ADR-018, ADR-024.
- **Test strategy:** CPUID/system-register golden tests, feature conformance, downgrade rejection,
  and snapshot/profile mismatch fixtures.
- **Exit gate:** Every advertised feature owns tests; unimplemented features are absent rather than
  trapping unpredictably; profile changes cannot silently alter an existing VM.

## ADR-007 — DoryDBT interpreter, IR, and precise exceptions

- **Status:** Accepted for implementation after clean-room and legal gates.
- **Decision:** An exact x86_64 interpreter is the executable specification. The ISA-neutral IR
  carries explicit flags, FP rounding/exceptions, memory ordering, fault points, side effects, and
  deoptimization boundaries; JIT tiers must agree with it.
- **Owners:** DBT compiler/runtime and CPU architecture.
- **Dependencies:** ADR-002, ADR-003, ADR-006, ADR-008, ADR-017.
- **Test strategy:** Specification vectors, randomized differential execution against physical x86,
  interpreter/JIT boundary comparison, multicore litmus tests, and deterministic replay.
- **Exit gate:** G1 conformance coverage is approved with zero unexplained state mismatch or hidden
  unsupported instruction before a translated cell advances.

## ADR-008 — JIT memory, publication, and reclamation

- **Status:** Accepted as a security design; release proof pending.
- **Decision:** One quota-bound `MAP_JIT` region is suballocated with guards. Signed, statically
  allowlisted C callbacks validate emission context, publish only after instruction-cache
  invalidation, and make blocks immutable. Lookup removal precedes epoch/hazard quiescence and slot
  reuse. No late-freeze entitlement is used unless a separately approved dependency requires it.
- **Owners:** DBT runtime and product security.
- **Dependencies:** ADR-007, ADR-016, ADR-017.
- **Test strategy:** Signed/notarized probe with `com.apple.security.cs.allow-jit` and
  `com.apple.security.cs.jit-write-allowlist`, hostile callback inputs, W^X assertions, concurrent
  invalidation/reuse stress, and crash recovery.
- **Exit gate:** The exact release configuration passes on every minimum host OS; callbacks are
  fixed before guest input; no stale generation executes after slot reuse.

## ADR-009 — VirtIO core and transport split

- **Status:** Accepted for implementation.
- **Decision:** Device semantics live in transport-neutral, hostile-input-validated cores; MMIO and
  PCI transports own discovery, register, queue-notification, and interrupt mechanics. Device ABI
  versions change only for guest-visible semantics.
- **Owners:** Device architecture and machine teams.
- **Dependencies:** ADR-001, ADR-004, ADR-005.
- **Test strategy:** The same block/network/input/sound/filesystem corpus runs through MMIO and PCI;
  fuzzing covers descriptors, reset, cancellation, snapshot, and malformed chains.
- **Exit gate:** No core imports a machine package and equivalent transports produce the same device
  transitions, durability, bounds, and diagnostics.

## ADR-010 — Dory EDK II source, build, update, and provenance

- **Status:** Accepted for design; source pin and license approval pending.
- **Decision:** Maintain narrow Dory ARMVirt and PC platform ports from pinned upstream EDK II.
  Reproducible outputs carry source digest, toolchain, SBOM, license, ABI, signature, variable-store,
  recovery, and update metadata. No protected Apple firmware is included.
- **Owners:** Firmware, supply chain, and legal.
- **Dependencies:** ADR-004, ADR-005, ADR-013, ADR-016, ADR-026.
- **Test strategy:** Reproducible clean builds, binary diff, NVRAM crash/repair, boot-order/update
  fixtures, license/SBOM verification, and installer matrices.
- **Exit gate:** Two clean builders produce identical signed candidates and provenance; each
  supported installer/update passes; counsel approves redistribution obligations.

## ADR-011 — Disk formats and conversion transactions

- **Status:** Accepted for implementation.
- **Decision:** `DoryDiskFormats` performs bounded streaming inspection and raw/sparse/COW
  operations. Optional formats earn read and write support separately. Conversion is descriptor-
  based, source-immutable, resumable, verified, fsynced, and atomically published from staging.
- **Owners:** Media/storage and security.
- **Dependencies:** ADR-023, ADR-024, ADR-025.
- **Test strategy:** Checked-arithmetic properties, parser fuzzing/corpora, sparse deception,
  recursive-chain, disk-full, cancellation, crash, TOCTOU, and round-trip fixtures.
- **Exit gate:** No untrusted media is mounted or opened by path in a privileged process; every
  published output has a digest-bound provenance receipt and recovery proof.

## ADR-012 — VZMac lifecycle and identity

- **Status:** Accepted for implementation subject to public API probes.
- **Decision:** `DoryVZMacAdapter` persists Apple public hardware model, unique machine identifier,
  auxiliary storage, configuration digest, and provenance. Restore/update/recovery/clone are
  journaled operations. Framework saved state is same-physical-host-only; cold boot remains viable.
- **Owners:** macOS virtualization and lifecycle.
- **Dependencies:** ADR-014, ADR-023, ADR-024, ADR-025.
- **Test strategy:** IPSW validation, interrupted restore, recovery, update, clone uniqueness,
  save/restore capability validation, host-update incompatibility, and fresh cold-boot recovery.
- **Exit gate:** Exact host/guest tuples pass lifecycle gates without invented portability or
  redistributed media/identity and without bypassing framework validation.

## ADR-013 — Intel Mac legal, provenance, and identity boundary

- **Status:** Blocked stop gate; counsel and temporal viability decision required.
- **Decision:** `DoryIntelMac-v1` may use only an exact lawful Tahoe 26-or-earlier x86_64 candidate,
  user-authorized media, and unique Dory-generated non-protected identity. Dory will not redistribute
  Apple ROMs, firmware, keys, identities, or bypass platform protections.
- **Owners:** Legal, security, Intel Mac platform, and release.
- **Dependencies:** ADR-005, ADR-006, ADR-010, ADR-017.
- **Test strategy:** Media/provenance review, license/use/instance/distribution analysis, servicing-
  horizon model, identity-collision tests, clean-room audit, and artifact scans.
- **Exit gate:** Counsel signs the exact candidate/use/distribution model and the conservative Phase
  7 launch retains the frozen security-servicing horizon; otherwise record terminal `no-ship`.

## ADR-014 — Graphics truth and acceleration gates

- **Status:** Accepted for implementation.
- **Decision:** Receipts and UI distinguish software framebuffer presentation, host-accelerated
  display, paravirtualized guest GPU, and hardware-accelerated 3D. Metal presentation alone is not
  guest acceleration. Each adapter and driver path qualifies independently.
- **Owners:** Graphics, desktop, qualification, and security.
- **Dependencies:** ADR-012, ADR-019, ADR-020.
- **Test strategy:** Capability/receipt golden tests, hostile command streams, reset/snapshot/device
  loss, memory pressure, frame pacing, and update-stable guest-driver qualification.
- **Exit gate:** No UI, CLI, API, or receipt can overstate graphics mode; acceleration remains absent
  when entitlement, public API, driver, correctness, or performance evidence is missing.

## ADR-015 revision 2 — Definition schema clean cut

- **Status:** Accepted for Phase 0B.
- **Supersedes:** ADR-015 revision 1 on 2026-08-30 after product confirmed the virtualization
  feature has never shipped and has no user definitions requiring migration.
- **Decision:** Schema 7 stores guest intent plus independently versioned engine, CPU, machine,
  firmware, device, snapshot, media, capability, consent, permission, backup, and qualification
  identities. Only schema 7 is readable or writable. Backend/distro-led values are rejected rather
  than decoded, migrated, dual-written, or retained behind compatibility shims.
- **Owners:** Control plane, migration, and compatibility.
- **Dependencies:** ADR-001, ADR-006, ADR-016, ADR-018, ADR-025.
- **Test strategy:** Golden resolution for every cell/error, rejection fixtures for every obsolete
  schema/backend value, unsupported-no-mutation tests, and source gates against legacy reads and
  writes.
- **Exit gate:** New definitions contain no prohibited identity; first boot pins all guest-visible
  ABIs; every obsolete fixture fails before mutation with a stable reason and recovery guidance.

## ADR-016 — Components, signing, activation, rollback, and no-QEMU audit

- **Status:** Accepted for implementation.
- **Decision:** Optional components have Dory IDs, exact digest, host/OS range, ABI compatibility,
  signing/notarization, entitlements, SBOM, licenses, provenance, atomic activation, last-known-good,
  rollback, and revocation. Source debt may only shrink; signed artifacts allow no QEMU identity.
- **Owners:** Components, release, supply chain, and security.
- **Dependencies:** ADR-010, ADR-015, ADR-026.
- **Test strategy:** Clean install/offline verification, signature/revocation/tamper/rollback tests,
  source-debt ceiling, strict extracted-artifact scan, and running-lease retention.
- **Exit gate:** Missing/broken/revoked components never hide machines or change the requested route;
  public artifacts pass the strict no-QEMU audit.

## ADR-017 — Performance methodology and budgets

- **Status:** Accepted; hardware matrix and baselines pending.
- **Decision:** Freeze low/mid/high physical Apple-silicon tiers and measure median, p95, p99, worst
  stable interval, variance, energy, temperature, pressure, and throttling. Cold/warm and native/
  translated results remain separate. Section 7 budgets are non-relaxing without a new ADR.
- **Owners:** Performance, physical lab, runtime, desktop, and release.
- **Dependencies:** ADR-007, ADR-014, ADR-019, ADR-020, ADR-021.
- **Test strategy:** Reproducible campaigns against identical HV/VZ harnesses and named physical x86
  references with signed host/guest/workload metadata and statistical noise policy.
- **Exit gate:** Reference models/workloads are frozen and every claimed tuple passes its exact
  throughput, latency, pacing, idle, memory, thermal, and lifecycle budget.
- **Current evidence:** The 2026-08-30 signed host probe inventories the available `Mac14,10`
  (Apple M2 Pro, 16 GiB) candidate, its exact firmware/macOS/boot/power/thermal/storage state, and
  two-display topology without recording hardware serials or user identity. The candidate is not
  yet assigned to a tier. The current schema-2 two-instruction lifecycle calibration retains 3,000
  position-balanced observations across five rounds and evaluates paired round medians. Its signed
  result is 4.05% median Dory overhead against the non-relaxing 3% budget, so it remains a
  reproducible optimization baseline rather than a pass; low/mid/high matrix and workload-campaign
  closure also remain stop gates. A separate 10,000,000-iteration host-native/minimal-HV/Dory loop
  passes at 0.39% median Dory overhead, 99.61% Dory/minimal-HV throughput, and 95.99% Dory/host-native
  throughput. This closes the sustained CPU dimension only for the available unassigned host; the
  low/middle/high references and remaining section 7 dimensions are still unmeasured. The signed
  host-storage campaign now freezes a safe comparator on that same host: five uncached 128 MiB
  rounds retain 20,000 raw latency observations and pass 20,160 deterministic read/write checks.
  Median results are 5,176.45 MiB/s sequential write, 1,364.71 MiB/s sequential read, 12,540.16
  random-read IOPS, and 7,624.35 random-write IOPS including the final durability sync; random-read
  p99 is 146.63 microseconds and random-write-submission p99 is 374.22 microseconds. This is a host
  baseline only: no Dory virtual-storage path has been compared, so the 90% sequential, 80% random,
  and bounded-p99 budgets remain open. Tier assignment, the other two physical hosts, and the
  energy/temperature/pressure/throttling campaigns also remain stop gates. A separate signed
  host-network campaign freezes the local TCP/IPv4 loopback comparator without external traffic.
  Five correctness-checked 256 MiB transfers per direction produce medians of 9,770.00 MiB/s upload
  and 5,322.30 MiB/s download; 10,000 retained 64-byte exchanges measure 15.71 microseconds median,
  23.25 microseconds p95, and 34.04 microseconds p99 round trip. This does not qualify a physical
  network link, and no Dory NAT or virtual path has been compared, so the 90% network budget remains
  open alongside the physical-tier matrix.

## ADR-018 — Compatibility ledger and release receipts

- **Status:** Accepted for implementation.
- **Decision:** Compatibility is keyed by the complete release/host/guest/engine/ABI/component/
  desktop/device tuple. Every applicable archived failure class maps to a test, non-applicability
  decision, or expiring waiver. Support claims are generated only from signed receipts.
- **Owners:** Qualification, compatibility, security, legal, and release.
- **Dependencies:** ADR-006, ADR-014, ADR-017, ADR-026.
- **Test strategy:** Schema validation, fixture linkage, waiver expiry, tuple mismatch, receipt
  signature, rollback binding, and support-matrix generation tests.
- **Exit gate:** No undispositioned applicable failure remains and each supported cell has a current
  signed G0–G9 receipt plus rollback artifact.

## ADR-019 — Host-device broker authority

- **Status:** Accepted for implementation subject to signed API probes.
- **Decision:** Narrow XPC brokers authenticate audit token, UID, Team ID, designated requirement,
  service identity, VM/operation lease, and protocol before payload decode. USB/camera/audio leases
  are explicit, exclusive where required, revocable, and admitted against global resource budgets.
- **Owners:** Host devices, security, media, and desktop.
- **Dependencies:** ADR-016, ADR-021, ADR-022.
- **Test strategy:** Forged-peer and oversized-payload tests, TCC denial/revoke, attach/detach/reset,
  multi-VM contention, sleep/crash recovery, and physical bulk/control/interrupt/isochronous probes.
- **Exit gate:** No device is silently stolen or remains captured after lease loss; final APIs,
  entitlements, TCC ownership, and exact device tuples pass signed release configuration tests.

## ADR-020 — Display topology and Dedicated Display safety

- **Status:** Accepted; VZMac independent multi-display remains unavailable.
- **Decision:** Guest scanouts, presentation surfaces, and physical screens have separate stable
  identities joined by durable assignments. Dedicated Display requires timed confirmation,
  always-reachable escape, automatic rollback, and exact host-state restoration. Dory-owned paths
  require independent per-display pacing.
- **Owners:** Display, desktop, input, and qualification.
- **Dependencies:** ADR-014, ADR-017, ADR-022.
- **Test strategy:** Fake and physical one/two/three-screen topology chaos, mixed DPI/refresh/
  orientation, Spaces, clamshell, sleep, disconnect, crash, confirmation timeout, and escape tests.
- **Exit gate:** No black/stranded screen or trapped input; every cell can assign one display to any
  screen; multi-display claims appear only for independently qualified scanouts.

## ADR-021 — Camera and audio privacy, routing, and synchronization

- **Status:** Accepted for implementation subject to final public paths.
- **Decision:** Camera and microphone capture remain in least-authority services with visible per-VM
  privacy state, explicit source/route, revocation, bounded conversion, backpressure, and A/V clock
  synchronization. VZ framework-owned audio authority stays with the VZ runner.
- **Owners:** Media bridge, host devices, desktop, and privacy/security.
- **Dependencies:** ADR-019, ADR-022.
- **Test strategy:** TCC first-run/deny/revoke, route/default-device changes, format conversion,
  underrun/drop/skew, sleep/hot-plug, crash, and multi-VM admission on physical devices.
- **Exit gate:** One-hour audio has zero Dory underruns, camera meets its qualified format/skew, and
  permission or route loss recovers or fails locally without capture leakage or guest reboot.

## ADR-022 — Desktop projection, intents, and framework boundaries

- **Status:** Accepted for implementation.
- **Decision:** All nine desktop surfaces render immutable generation/sequence-aware controller
  projections and emit typed intents. SwiftUI owns low-rate shell state; AppKit/Metal coordinators
  own display windows, capture, full screen, menus, and high-rate paths outside observable churn.
- **Owners:** Desktop experience, control plane, accessibility, and localization.
- **Dependencies:** ADR-015, ADR-019, ADR-020, ADR-021, ADR-025.
- **Test strategy:** Deterministic fake runners/devices/screens/permissions, restart and out-of-order
  events, stale intents, window restoration, keyboard/VoiceOver, reduced motion/contrast, RTL,
  localization, and main-thread trace fixtures.
- **Exit gate:** No view mutates runtime/storage/device state; all journeys reconcile after restart;
  UI propagation, library scale, restoration, input, and main-thread budgets pass.

## ADR-023 — Media helper, download/cache, and install transactions

- **Status:** Accepted for implementation.
- **Decision:** File panels/bookmarks grant authority; the app opens no-follow regular files and
  passes read-only descriptors to an unprivileged helper. Downloads and cache are digest-addressed,
  quota/lease-bound, resumable only with remote identity proof, and atomically published. Install
  follows the named inspect-to-first-boot checkpoints.
- **Owners:** Media, storage, control plane, and security.
- **Dependencies:** ADR-011, ADR-012, ADR-025.
- **Test strategy:** Symlink/device/FIFO rejection, TOCTOU, redirect/range/ETag changes, partial
  publication, quota/GC leases, disk-full/cancel/restart, source immutability, and first-boot proof.
- **Exit gate:** A partial or ambiguous source is never selectable or mutated; completion requires
  authenticated readiness after install media ejection and clean disk boot.

## ADR-024 — Snapshot, backup, import/export, clone, and fork semantics

- **Status:** Accepted for implementation.
- **Decision:** Cold, quiesced, and live snapshots are distinct capabilities. Durable Dory state has
  architectural CPU/memory/machine/device/time plus ABI manifests, never JIT code or host objects.
  VZMac live state is same-host-only. Backups and `.dorymachine` bundles are independently verified
  portable sets with explicit identity regeneration rules.
- **Owners:** Lifecycle, storage, VZMac, compatibility, and backup.
- **Dependencies:** ADR-002, ADR-003, ADR-006, ADR-011, ADR-012, ADR-025.
- **Test strategy:** Barrier/timeouts, chain loss/merge/GC, low disk, corrupt/mismatched state,
  framework incompatibility, clone collisions, hostile bundle paths, and periodic restore drills.
- **Exit gate:** Failure leaves source and disks unchanged, no child loses a referenced parent, and
  every portability claim passes a fresh-boot restore on the exact allowed tuple.

## ADR-025 — Operations, compensation, quarantine, and repair consent

- **Status:** Accepted for implementation.
- **Decision:** Every mutation is a leased durable operation with stable ID, owner, phase,
  checkpoints, bounded events, explicit cancellation acknowledgement, first-cause retention, and
  separately recorded cleanup. Compensation touches only proven-owned resources; uncertain guest-
  mutated disks enter bounded quarantine. Diagnosis is read-only; repair is previewed and scoped.
- **Owners:** Control plane, lifecycle, storage, diagnostics, and desktop.
- **Dependencies:** ADR-003, ADR-015, ADR-022, ADR-023, ADR-024.
- **Test strategy:** Kill controller/runner/helper/host, lose disk/permission/device/lease at every
  checkpoint, duplicate/reorder events, retry idempotence, quarantine expiry, and repair rollback.
- **Exit gate:** Terminal success/cancel/failure is written only after durable cleanup; no unowned
  process mutates; first errors survive; uncertain user data is never silently deleted or reused.

## ADR-026 — Whole-release manifest and distribution parity

- **Status:** Accepted for implementation.
- **Decision:** One immutable manifest binds app, daemon, helpers, runners, optional components,
  Tools/drivers, firmware, signatures, entitlements, notarization, SBOM/licenses, update feed,
  rollback, website, GitHub, and Homebrew metadata. Staging cannot advertise an unavailable tuple.
- **Owners:** Release, supply chain, security, legal, and support.
- **Dependencies:** ADR-010, ADR-016, ADR-017, ADR-018.
- **Test strategy:** Clean-machine install, absent-component operation, exact asset digest/signature,
  entitlement inventory, channel parity, offline path, upgrade, rollback, revocation, and public
  metadata convergence.
- **Exit gate:** Every channel resolves to the same qualified tuple and rollback set; a clean Mac
  can install, verify, operate, upgrade, and roll back without undeclared bytes or capabilities.

## Current Phase 0A stop gates

The following must remain visibly open until evidence is attached:

1. Counsel approval and temporal viability for an exact x86_64 macOS candidate (ADR-013).
2. Release-signed/notarized JIT entitlement and callback-allowlist proof (ADR-008).
3. Release-signed VZMac graphics, input, audio, camera, and USB feasibility probes on every minimum
   host OS; SDK 27.0 still states that `VZMacGraphicsDeviceConfiguration.displays` supports at most
   one display, while `VZUSBPassthroughDeviceConfiguration` is available from macOS 27.0. The
   2026-08-30 engineering probe built with Xcode 26.6/macOS SDK 26.5 constructs the documented
   graphics, input, audio, and XHCI configurations but finds no public camera or physical-USB
   declaration. Runtime-only USB class presence is not API authority, so this gate remains open.
4. Frozen low/mid/high physical Apple-silicon lab inventory and baseline evidence (ADR-017).
5. Named staffing, paired ownership, release authority, and regression-ledger approvers beyond role
   assignments in the program manifest.

No Phase 0B or feature implementation may treat these as passed merely because the architecture is
documented.
