# Linux virtual workspace architecture

> The 2026-08-25 ISO/application recovery decision and current GPU root-cause review are recorded in
> [`linux-iso-and-gpu-recovery-review.md`](linux-iso-and-gpu-recovery-review.md). Its portable EFI
> baseline and fail-safe acceleration rules are incorporated here and remain normative.

- **Status:** Proposed Linux execution architecture; required before a public Linux release
- **Date:** 2026-08-26
- **Scope:** ARM64 Linux guests on Apple-silicon Macs
- **Parent decision:** [`virtual-workspace-platform.md`](virtual-workspace-platform.md)
- **Delivery and gates:** [`linux-virtual-workspace-delivery-plan.md`](linux-virtual-workspace-delivery-plan.md)
- **Living support ledger:** [`linux-capability-and-qualification-matrix.md`](linux-capability-and-qualification-matrix.md)

## Decision summary

Dory will first become a dependable Linux virtual-workspace product. Windows and macOS guest work
is deferred. The current branch is useful implementation evidence, but it is not a release
architecture: product policy, durable state, backend selection, helper mechanics, host resources,
guest provisioning, and presentation are still coupled.

The Linux product will be rebuilt around six non-negotiable decisions:

1. **One desired-state contract and one immutable resolved launch plan.** A backend never receives
   legacy paths, an environment dictionary, or a mutable `DoryMachineConfiguration`.
2. **One daemon-owned transaction per workspace operation.** The app submits intent. `doryd` owns
   provisioning, host resources, helper processes, readiness, compensation, and recovery.
3. **An explicit, append-only virtual-hardware ABI.** Optional devices never renumber existing
   devices. Disk, NIC, display, input, audio, share, and USB-controller identity is stable.
4. **Conjunctive, evidence-backed capabilities.** “Implemented” is not “supported.” A requested
   workspace runs only when one backend satisfies the entire request with exact-candidate evidence.
5. **Untrusted device input is isolated and bounded.** Guest-controlled queues and GPU command
   streams are parsers at a security boundary, not ordinary in-process Swift data.
6. **One implementation owns each production authority.** Replaced flags, environment bridges,
   inferred allocators, listener loops, and backend-specific launch adapters are deleted with their
   obsolete tests. A legacy decoder may remain only as an explicit, read-only migration boundary;
   it cannot also launch or mutate a workspace.

No new Linux feature claim may bypass these contracts by adding another conditional to
`MachineManager`, `DesktopMode`, the create sheet, helper environment variables, or a parallel
"temporary" adapter. Dead and duplicate production paths are release defects, not cleanup debt.

## Platform facts that bound the design

There is no production-stable macOS backend today that simultaneously supplies full ARM64 Linux,
documented Linux guest 3D, general physical USB passthrough, and reliable saved-state lifecycle.

- On shipping macOS 26, Virtualization.framework is the strongest complete-VM baseline. Apple
  documents its Linux graphics device as **Virtio GPU 2D** and exposes scanouts, not VirGL, Venus,
  renderer selection, resource blobs, or Linux Metal acceleration.
- VZ USB controller hot-plug introduced in macOS 15 is not the same as arbitrary physical-device
  capture. Before macOS 27, its public concrete device is synthetic USB mass storage.
- macOS 27 beta adds physical USB capture through Accessory Access and a custom VirtIO device API.
  The custom device exposes queues, negotiated features, guest-memory mappings, shared-memory
  regions, and save/restore callbacks. Those primitives justify a standards-compatible
  virtio-gpu/VirGL/Venus experiment, but do not prove that such a device is supportable. Apple's
  current beta release notes also record passed-through USB save failures and detach/restore crash
  cases, so physical USB and saved state remain an explicitly rejected combination until final APIs
  and retained device-class evidence replace those beta constraints.
- Hypervisor.framework can support a Dory-owned VMM and translated VirGL/Venus renderer, but Dory
  then owns every device ABI, parser, lifecycle transition, snapshot rule, and compatibility test.
- QEMU/HVF offers broad emulation and CPU acceleration, but upstream does not document a turnkey
  accelerated macOS virtio-gpu renderer. Adding it now would add another hardware and snapshot ABI
  without resolving Dory's hardest macOS graphics and USB requirements.

Consequently, backend choice remains a resolver result, not a product identity:

- **VZ on shipping macOS:** baseline for generic ARM64 ISO/UEFI Linux, 2D display, native host
  integration, synthetic mass-storage hot-plug, and qualified same-host saved state.
- **RawHV:** managed-Linux development path with experimental renderer mechanisms; guest 3D remains
  unavailable until its security, synchronization, isolation, lifecycle, and qualification gaps
  are closed.
- **VZ custom VirtIO on macOS 27:** time-boxed research candidate for converging VZ lifecycle and
  physical USB with Dory 3D. Beta-only until final APIs and physical evidence exist.
- **QEMU/HVF:** deferred; reconsider only for a requirement it uniquely and reliably satisfies,
  such as cross-architecture TCG.

This is capability-based selection, not silent failover. A saved workspace records the selected
backend and ABI. Changing either is a visible, separately authorized migration.

## Target ownership and dependency graph

```text
Product UI
    │ intent / projections only
    ▼
doryd control plane
    ├── WorkspaceRepository + per-workspace coordinator
    ├── OperationJournal + RecoveryReconciler
    ├── CapabilityResolver + QualificationStore
    ├── Artifact/FD/Port/USB/Network resource brokers
    └── BackendRegistry
             │ immutable launch envelope + capability handles
             ▼
        per-VM runtime
        ├── VZLinuxRuntime
        └── RawHVLinuxRuntime ── typed renderer protocol ── RendererWorker
             │ events / readiness facts                  untrusted GPU stream
             ▼
        presentation attachment + Dory Tools protocol
```

The corresponding Swift target direction is:

```text
DoryVMContracts
├── DoryHVCore ─────────────── RawHVLinuxRuntime
├── DoryDesktopHostKit ─────── RawHVLinuxRuntime, DoryVMMKit
└── DorydKit ───────────────── Linux backend adapters

DoryRendererWorkerWireContracts
├── DoryOperations, DorydKit ── launch authority and tuple admission
└── DoryRendererWorkerContracts ── worker/runtime protocol adapter

DoryGuestProtocolClient
├── RawHVGuestIntegration
└── VZGuestIntegration
```

Dependency rules:

- `DoryVMContracts` is Foundation-only and contains no AppKit, Virtualization, Hypervisor, IOKit,
  Rust FFI, daemon, persistence, or filesystem-authority code.
- `DoryRendererWorkerWireContracts` is a Foundation/CryptoKit leaf. It owns canonical renderer
  identities, bootstrap/receipt bytes, bounded operation payloads, leases, and the XPC interface;
  it contains no AppKit, Metal, Hypervisor, renderer implementation, daemon, or product policy.
- `DoryHVCore` contains CPU, memory, interrupt, MMIO, VirtIO, and boot mechanisms. It never imports
  `DorydKit`, `DoryVMMKit`, or product policy.
- `DoryDesktopHostKit` contains reusable host presentation/input/audio primitives, not VM lifecycle.
- `DoryGuestProtocolClient` owns the versioned wire client without importing the daemon.
- `doryd` owns bookmarks, path authorization, persistent identity, device claims, ports, gvproxy,
  component leases, process supervision, policy, and recovery.
- A runtime receives resolved resources. It never discovers host paths, chooses components, claims
  physical USB directly, provisions guest policy, or decides whether a degraded fallback is allowed.

The first leaf extractions are complete. `DoryVMContracts` now owns the RawHV ARM64 ABI-v1 topology,
typed device roles, bounded stable logical IDs, role-aware slot allocator/reconciler, strict Codable
validation, and a versioned canonical SHA-256 fingerprint stream. It depends only on Foundation and
CryptoKit and has a manifest guard against control-plane, UI, Virtualization, and Hypervisor imports.
`DoryRendererWorkerWireContracts` now provides the second shared leaf, so the daemon and runner bind
the same canonical renderer inventory, bootstrap, capability receipt, command, and lease bytes rather
than recreating a runner-private protocol. It likewise depends only on Foundation and CryptoKit.
The broader `WorkspaceSpec`, resolved-plan, launch-envelope, event, and readiness extraction remains
Phase 1 work; the topology leaf does not imply that those existing DTOs have already moved.

## Canonical contracts

### Desired state: `WorkspaceSpec`

`WorkspaceSpec` describes user intent and stable identity. It contains no host paths and no selected
backend. Its device graph uses stable logical IDs and typed requirements:

- guest family and architecture;
- CPU and memory policy;
- boot intent and firmware policy;
- storage attachments with role, controller, format, durability, discard, and identity;
- a list of NICs with stable IDs and attachment requirements;
- display requirements and stable display IDs;
- typed pointer, keyboard, audio-input, and audio-output profiles;
- shares with guest semantics, not host bookmarks;
- synthetic removable media and physical USB requirements as different capabilities;
- lifecycle, snapshot, guest-integration, and readiness requirements.

The document is versioned, canonicalized, content-digested, and losslessly migrated. Unknown fields
are not discarded. A migration may preserve legacy read compatibility, but new writes never encode
policy in an environment dictionary.

### Resolution: `ResolvedMachinePlan`

The pure resolver combines a spec with a signed inventory and host facts. Its immutable result
binds:

- exact backend and backend build;
- virtual-hardware ABI and explicit device addresses;
- component, guest media, kernel, initrd, firmware, tools, renderer, and shader-translation digests;
- exact support/qualification record and its expiry or revocation state;
- resolved resource requirements and security profile;
- ordered, structured reasons for every rejected alternative;
- migration and restore compatibility identifiers.

The plan is an authorization object. Launch fails closed if its spec revision, host facts,
artifacts, qualification, entitlements, or security profile no longer match.

The durable RawHV authority is now `ResolvedMachinePlan` schema 5. It persists the complete
`DoryRawHVVirtualHardwareTopology`, including logical device IDs, typed roles, occupied MMIO slots,
ABI/backend/architecture identity, and canonical fingerprint input. Planning reconciles against the
previous topology so surviving logical IDs retain their slots; start validates the persisted device
set against the current definition rather than allocating again.

Plan publication records the exact canonical definition revision and SHA-256. Before launch, the
daemon canonicalizes the current definition again and requires machine identity, plan revision,
definition revision, and definition digest to match exactly, followed by fresh runtime-evidence and
topology revalidation. A definition whose canonical bytes or digest differ is rejected even if it
appears semantically similar.

Repository framing is a separate versioned authority from the nested plan schema. Current wrapper
schema 3 is one compact, sorted-key JSON representation: reads require the persisted record bytes to
equal that canonical representation, authenticate the canonical nested-plan bytes, and require a
decode/re-encode match so reordered, alternate lexical, or unknown record/plan fields fail closed.
Historical integrity wrapper schema 2 may contain plan schemas 2 through 4 only. Its original digest
is verified against the persisted historical plan shape, its stored source-schema and migration
provenance must be internally consistent, and it is returned only as `requiresReplanning` input.
Unauthenticated wrapper schema 1 is likewise replan-only. No legacy wrapper can authorize launch.

### Execution: `RuntimeLaunchEnvelope`

The daemon translates a resolved plan exactly once. The versioned launch envelope contains:

- backend-specific mechanism configuration;
- logical device IDs and fixed ABI addresses;
- inherited descriptor slots or broker handles for disks, directories, sockets, and control
  channels;
- bounded resource limits;
- operation and plan identity;
- event, readiness, and graceful-shutdown endpoints.

It does not contain arbitrary environment settings or ask the helper to reopen security-sensitive
paths. The daemon validates and opens storage with the correct file-kind, ownership, symlink,
locking, size, and mutability policy, then passes a capability-style descriptor.

Descriptor admission may be expensive. The control plane records an immutable per-workspace launch
generation while briefly holding its machine-table lock, performs hashing/copying and broker I/O
outside that lock, and compare-and-commits the same generation immediately before spawn. It never
holds a process-wide machine lock across hundreds of MiB of boot or disk I/O, and a second workspace
is not serialized behind the first workspace's artifact admission.

Resolved RawHV launch now uses one canonical schema-v5 envelope with immutable compute,
system-disk multiqueue, and ordered
descriptor-slot contract:

- admitted memory, vCPU count, and scheduling-policy revision are exact envelope fields, not
  independent helper flags; scheduling revision 1 reserves `userInteractive` for AppKit while
  sustained vCPU, block, network, and shared-filesystem work use `userInitiated`; the current
  production policy binds one system-disk queue per admitted vCPU and the helper materializes that
  exact count;
- the boot vCPU and complete `Machine.run()` lifetime belong to one dedicated, joinable POSIX
  owner thread rather than a dispatch queue or cooperative task executor; Desktop, Engine, and
  probes join that owner before device teardown, while AppKit stays on the main thread;
- MMIO attachment remains a cold boot transaction: windows are validated, sorted, and sealed
  before SMP execution; every vCPU owns a local repeated-region cache and falls back to binary
  search, so adding optional devices does not impose an attachment-order scan on every guest exit;
- autonomous free-page reporting is distinct from target-driven balloon control: RawHV validates a
  complete report, then reclaims it on a bounded serial utility worker, one report per fair turn;
  reset and QueueReady changes advance a generation behind a lifecycle fence so queued work cannot
  mutate host mappings or publish used entries after revocation;
- entropy requests follow the same vCPU-ownership rule: a queue notification only admits and
  coalesces work for one serial utility worker, which fills at most 4 KiB per request and completes
  at most eight requests per fair turn; reset and QueueReady generation fences revoke queued and
  in-flight work before any late guest publication;

- FD 3 is the daemon-opened read-write system disk. Its exact capacity and stable logical-device ID
  are bound to the persisted topology; the daemon holds an exclusive inode lease across bounded
  startup retries.
- FD 4 is a read-only kernel authority with an exact positive byte count, lowercase SHA-256, and a
  256 MiB ceiling.
- Optional FD 5 is a read-only initrd authority with an exact positive byte count, lowercase
  SHA-256, and a 512 MiB ceiling.
- FD 6 is a read-only, fixed-size 336-byte canonical renderer bootstrap exactly when resolved
  graphics is `hardwareAccelerated3D`; software launches must omit it. Its exact byte count and lowercase
  SHA-256 are part of the envelope, and any missing, extra, reordered, writable, noncanonical, or
  hash-mismatched renderer authority fails launch.

Kernel and initrd inputs are verified and copied into fresh private staging inodes, reopened
read-only, revalidated by inode/size/digest, and unlinked before transfer. Schema v5 rejects missing,
extra, duplicated, reordered, incorrectly named, wrongly accessed, or noncanonical descriptor
authority. Its typed direct-boot profile permits either a managed kernel rooted at `/dev/vda` with
no initrd, or an installed-Linux boot bundle rooted at a disk partition with FD 5 present. The
resolved helper consumes these descriptors and cannot simultaneously accept path authority.

The FD 6 bootstrap is immutable launch authority, not a feature flag. Before creating it, the
production daemon must verify the canonical renderer inventory, every exact host component, the
nested runner/worker identities, the guest Mesa identity, and the exact **expanded kernel bytes**
admitted at FD 4. The bootstrap binds those identities, the workspace/generation, protocol source
tuple, and bounded capability limits. A compressed source archive, catalog label, or former dynamic
renderer inventory cannot stand in for the exact inventoried dual-worker graph and kernel bytes the
VM will use.

The daemon admission/staging and runner FD 6 consumer establish the structural bootstrap contract:
persisted component evidence is revalidated, canonical bytes are placed in a reopened read-only
unlinked descriptor, and the runner exact-reads and validates it before constructing the VM or
starting any vCPU. The admitted production identity is schema-3 tuple
`dory-dual-metal-20260826`: one worker, VirGL2 capset 2 through its XPC-local ANGLE Metal pair, and
Venus capset 4 through static MoltenVK. Its canonical inventory binds the exact runner, worker,
ANGLE libraries, guest Mesa, and expanded managed-kernel bytes.

The signed doryd entitlement contains the exact runner CDHash, renderer-worker CDHash, and compiled
tuple-definition identity. `HvProcess` launches the runner suspended, validates the live child Code
Directory hash, and terminates it on mismatch before resume. Qualification invokes the nested XPC
from the already signed runner and records a canonical request/reply transcript; live activation
starts a fresh worker generation and requires exact equality of the inventory, identities, capset
digests, feature bits, managed kernel, and Mesa receipt before opening the command lane. This is
admission structure, not physical GPU evidence.

A launch-time capability receipt remains separate from the live gate. Accelerated readiness may be
published only after the first worker-backed scanout has waited on the producer fence and completed
Metal command-buffer presentation. An admitted-candidate XPC/renderer failure, candidate Metal
device loss, or candidate GPU-quiescence fault leaves the helper through status 86. The daemon
stops startup retries, durably suppresses the exact runner/inventory/worker candidate for six
hours, and stops the uncertain VM generation without changing its disk. The next automatic plan
may start the already-declared software recovery level; an explicit hardware-only request remains
an unavailable-plan error. This is never an unsafe in-VM renderer downgrade. None of the current
structural evidence is a release-qualified booted-Linux frame, sustained VirGL or Zed result, or
whole-VM performance result.

The same envelope carries the exact persisted RawHV topology; the helper matches materialized
backends by logical ID and role, attaches each one at its explicit sparse slot, and rejects a
materialized MMIO set that differs from the durable plan. This remains transitional rather than a
complete capability envelope: shares, gvproxy, and lifecycle/control sockets still cross as path or
CLI authority, and the envelope still imports broad operation-layer device DTOs.
`DoryTrustedDirectoryRoot` establishes the component-by-component, no-follow, pinned-dirfd and
permanent-quarantine primitive. Production activation now requires the configured state authority
to equal the selected data drive's exact machines root, acquires a `DoryMachineStateBroker`, and
injects it into `MachineManager`. Each resolved RawHV launch acquires one private mode-0700 machine
directory generation. `rootfs.ext4`, the fixed `kernel` leaf, and all private boot staging are
opened, created, reopened, and unlinked relative to that same borrowed dirfd; disk and boot can no
longer be admitted from separately reopened pathname generations. The lease revalidates the trusted
root and current machine entry after admission and immediately before process configuration, and
root, child, or mode drift releases every admitted descriptor without invoking the process starter.

This closes only resolved RawHV disk and boot authority. Shares, gvproxy, runtime/control sockets,
saved state, snapshots, and several repositories remain path-backed. Launch admission now records a
UUID reservation and immutable authority snapshot under the machine-table lock, performs runtime
setup, share/saved-state validation, RawHV hashing/staging, handoff construction, and process
configuration outside it, then compare-and-commits the exact generation, configuration, operation,
state, object identity, runtime authority, and reservation before spawn. Failure cleanup holds the
matching reservation until process, handoff, and descriptor teardown completes, so unrelated
workspaces continue while a launch is admitted without reopening a duplicate ownership path.

### Observation: runtime facts, not mutable desired state

Observed state is a projection of an append-only operation/event stream. Required fact groups are:

- process and backend state;
- boot, display, network, guest-tools, storage, audio, and requested-device readiness;
- device health and bounded metrics;
- active operation and stable condition;
- exact plan, ABI, artifact, and qualification identities;
- structured degradation and recovery reasons.

The UI never infers readiness from a helper PID, one frame, or a generic `running` boolean.

## Backend contract

`MachineBackend` becomes asynchronous and event-driven. Conceptually it must support:

```swift
protocol MachineBackend: Sendable {
    func probe(_ host: HostFacts) async -> BackendProbe
    func resolve(_ request: BackendResolutionRequest) async throws -> BackendPlanFragment
    func launch(_ envelope: RuntimeLaunchEnvelope,
                resources: RuntimeResourceSet,
                events: RuntimeEventSink) async throws -> RuntimeSession
    func recover(_ record: RuntimeRecoveryRecord,
                 events: RuntimeEventSink) async throws -> RuntimeSession?
}
```

Lifecycle commands operate on `RuntimeSession` and declare supported semantics for pause, graceful
shutdown, forced stop, saved state, snapshot coordination, live reconfiguration, and device attach.
Unsupported operations return a typed reason before UI presentation. Control-plane code must not
branch on VZ or RawHV to implement backend lifecycle behavior.

### VZ exact network and storage configuration

The generic NIC capability contract continues to admit MTUs from 1280 so RawHV and a disconnected
device can represent a valid 1280-byte link. A connected exact VZ NIC is a narrower mechanism:
Virtualization.framework's file-handle attachment rejects 1280 and validates 1500 on the supported
host probe. Consequently, connected file-handle/gvproxy VZ plans have an exact minimum and default
MTU of 1500. An explicit connected value below 1500 fails during pure plan/configuration validation,
before gvproxy directories, sockets, processes, or other external side effects are created. A
disconnected VZ NIC may retain the generic 1280 minimum because no file-handle attachment is built.

The isolated verification batch passed 113/113 structural tests and both `dory-vmm` and `doryd`
production builds. That proves deterministic validation and ordering, not network speed. Release
qualification must bind the exact VZ network datapath—including native VZ NAT versus
file-handle/gvproxy—and the exact storage controller, attachment, cache, synchronization, and media
mode. Results from one such cell cannot authorize or characterize another.

VZ host services now follow the guest contract instead of starting every legacy endpoint for every
VM. Generic EFI/ISO launches create only the lifecycle/control server; direct-kernel Linux launches
add agent and shell proxies; the Docker proxy and one-second dynamic-port discovery loop exist only
for the Docker engine role. This removes Docker socket polling from generic Linux and is source/build
closure, not a measured speedup. VZ still consumes split CLI fields rather than one immutable launch
envelope, so the exact service profile, resources, storage policy, network datapath, media authority,
and operation identity must move into that envelope before qualification.

## Virtual-hardware ABI

Every guest-visible device has a stable `DeviceAddress` selected by a named ABI version. The ABI
defines, at minimum:

- bus/controller identity;
- MMIO/PCI address and interrupt;
- boot and enumeration order;
- stable disk serial, NIC MAC, display ID, share tag, and USB-controller identity;
- reserved slots for absent optional devices;
- feature bits and config-space semantics;
- migration compatibility and a fingerprint recorded in snapshots/exports.

RawHV ARM64 ABI-v1 is now an explicit append-only role table:

| MMIO slot(s) | Durable role | ABI-v1 rule |
|---|---|---|
| 0 | System disk | Fixed singleton |
| 1 | Graphics | Fixed singleton; all scanouts/displays remain one GPU function |
| 2 | Entropy | Fixed singleton |
| 3 | Balloon | Fixed singleton |
| 4 | Vsock | Fixed singleton |
| 5 | Keyboard | Fixed optional singleton; absence is a hole |
| 6 | Pointer | Fixed optional singleton; absence is a hole |
| 7 | Audio | Fixed optional combined input/output function; absence is a hole |
| 8–11 | Network functions | Up to four stable logical functions |
| 12–19 | Auxiliary block or removable storage | Shared eight-slot range |
| 20–29 | Directory shares | Up to ten stable logical functions |
| 30 | USB controller | Reserved role/address; the current runtime does not materialize native xHCI |
| 31 | Reserved | Unassignable in ABI-v1 |

Published meanings and ranges are not repurposed inside ABI-v1. Removing an optional device leaves
a hole. Reconciliation preserves every surviving logical-ID/role assignment, rejects role mutation,
duplicates, reserved/out-of-range slots and shared-range overflow, and assigns new variable devices
to the lowest free slot in their role range deterministically.

The mechanism layer owns sparse `attachVirtioSlot(_:at:)` attachment and emits only occupied slots
in deterministic ARM DTB and x86 PVH/MPTABLE surfaces. The resolved product launch consumes the
schema-5 topology and uses those exact slots, then verifies that the attached set equals the durable
plan. Non-resolved compatibility entry points also pass their already-known local slot explicitly;
the second, inferred dense append allocator has been removed. Their local dense ordering remains a
compatibility behavior, not a product ABI. Canonical topology bytes, an encoder-independent
fingerprint stream, allocator/reconciliation fixtures, and ARM/x86 sparse-surface tests provide the
durable ABI foundation. They are contract evidence, not release qualification.

## Lifecycle and transaction model

Each workspace has one coordinator/actor. Independent workspaces may progress concurrently; two
mutations of the same workspace serialize through its durable operation journal.

MachineManager now enforces that topology directly. The former process-wide `operationLock` and
singular pending-start state are gone; a reference-counted per-workspace coordinator serializes
same-workspace work while unrelated workspaces continue, and canonically sorted multi-workspace
acquisition prevents lock-order inversion. Launch admission snapshots immutable authority outside
the machine table lock and compare-and-commits the reservation, configuration, operation, runtime
identity header, and already-validated plan SHA-256. It does not recursively compare the expanding
full plan value—the old derived equality overflowed the stack under a real integration fixture.
The coordinator, launch, lifecycle, planning, resolved-plan, and 100-test MachineManager gates pass.

A create-and-run transaction owns these phases:

1. validate intent and resolve an exact qualified plan;
2. acquire component and host-resource leases;
3. inspect/stage media and create storage/NVRAM atomically;
4. persist the workspace and operation before external effects;
5. spawn the selected runtime with an immutable envelope;
6. install/boot and collect named readiness facts;
7. provision optional Dory Tools capabilities transactionally;
8. commit success, or compensate every claimed resource and persist a recoverable failure.

The app must not implement this transaction with best-effort deletion. Recovery is idempotent after
termination at every phase. Host sleep, daemon restart, helper crash, USB removal, and port loss are
events reconciled against the same durable operation/state model.

Saved VM state and portable snapshots remain different contracts:

- saved state is backend- and host-bound, includes explicit compatibility evidence, and may be
  unavailable for a device combination;
- snapshots bind the full disk graph, firmware/NVRAM, device ABI, component tuple, requested and
  effective consistency kind, and checksum tree;
- external devices are recorded as dependencies, never pretended to be snapshot-atomic.

## Linux boot policy

Generic user-owned ARM64 ISO/UEFI Linux initially runs through VZ. RawHV has no firmware or
persistent NVRAM and does not execute the installed disk's EFI path. It currently direct-boots
either the managed FD 4 kernel contract or a verified installed-Linux bundle materialized as FD 4
kernel plus FD 5 initrd. The bundle is host-side direct-boot authority, not generic installed-Linux
support, and it cannot justify an arbitrary distro after the guest changes its kernel, modules,
bootloader, or security policy without a newly admitted matching bundle.

“Compatible” means a native ARM64 installer with standard EFI and VirtIO support. Apple Silicon
cannot hardware-virtualize an x86_64 distro ISO; that is a separate whole-system emulation tier,
not a failure of the ARM64 EFI baseline.

RawHV may graduate in one of two explicit forms:

1. implement and qualify UEFI, persistent NVRAM, and the stable storage/controller ABI; or
2. remain a managed-image backend with an atomic, signed guest/host boot-artifact synchronization
   protocol and a narrower product claim.

Dory Tools may improve readiness, sharing, clipboard, resize, USB/IP preview, and quiescing. A
generic Linux VM must still boot and remain usable without guest mutation; missing tools produce
explicit unsatisfied/degraded capabilities.

### Generic-install to accelerated-runtime transition

Supporting user-owned media and supporting an accelerated runtime are two different transactions.
The first must remain distribution-neutral: any compatible native ARM64 ISO that passes bounded
media inspection installs and recovers through its own EFI/NVRAM path on VZ. Dory MUST NOT infer
that the installed system is acceleration-compatible merely because installation succeeded or
because a renderer exists on the host.

If RawHV remains the accelerated backend, moving an installed workspace to it requires an explicit,
reversible **acceleration activation** operation with these authorities:

- the exact installed-disk generation and root identity;
- a signed Dory kernel/initrd or another independently qualified direct-boot bundle, never a stale
  kernel copied from the original installer ISO;
- guest ABI facts for architecture, libc symbol baseline, Vulkan loader, window system,
  compositor, kernel features, and required shared-library sonames;
- exact guest Mesa VirGL2 and Venus runtime artifacts and successful in-guest preflight receipts;
- the matching host renderer, worker, fence, virtual-hardware ABI, and qualification records;
- a durable rollback target that boots the unchanged installed disk through VZ EFI.

The guest-integration resolver selects artifacts from ABI facts and capabilities, not branches such
as `if Ubuntu`. More than one ABI-compatible runtime may exist in the signed catalog. Unsupported
libc families, missing dependencies, unsupported kernels, or a failed renderer probe leave the
machine on the truthful VZ baseline or fail a mandatory acceleration request before launch. An
optional Venus failure may retain an independently qualified VirGL tier, but no plan selects
`llvmpipe` under an accelerated label.

The producer-complete scanout fence is the current portability boundary. Dory's managed Linux
6.12.106 profile includes the exact virtio-gpu writer-fence-before-`RESOURCE_FLUSH` backport and
hardening needed to authorize shared-texture presentation. An arbitrary installed distro, unknown
kernel, or distro update does not inherit that proof. Such media boots and runs ordinary
applications on the VZ software baseline, but it is not hardware accelerated until a matching
signed direct-boot bundle and graphics pack prove this same contract. Generic ISO compatibility
and managed/direct-boot acceleration must remain separate support claims.

### macOS 27 custom-VirtIO consolidation candidate

Apple's macOS 27 beta API introduces a second, potentially simpler acceleration architecture that
must be evaluated before RawHV becomes the only long-term answer. `VZCustomVirtioDevice` exposes
negotiated feature bits, device-specific configuration bytes, VirtIO queues, bounded guest-DRAM
mappings, and configured VirtIO shared-memory regions. Those are the mechanism classes required to
adapt Dory's existing virtio-gpu control/cursor queues and host-visible blob window while VZ retains
EFI, NVRAM, native vCPU execution, NVMe storage, networking, suspend, and generic ISO installation.

The source/API review is recorded in the machine-readable
[`vz-custom-virtio-gpu` architecture gate](architecture-gates/vz-custom-virtio-gpu.json). This is a
research candidate, not a capability claim or an immediate fix for the installed renderer path.
The API is beta and the currently selected Xcode 26.6 toolchain's macOS 26.5 SDK does not expose
public declarations, so no prototype can compile in the current release build.

The static standard GPU shell is representable: device ID 16, PCI display-other class `0x0380`, two
control/cursor queues, the fixed 16-byte configuration used when blob-alignment is not offered,
feature bits 0/2/3/4, and host-visible shared-memory region ID 1. VZ also exposes one-shot queue
element access, in-process guest-DRAM mappings, runtime shared-region map/unmap, DRIVER_OK, reset,
pause/resume/stop, and optional save/restore callbacks. These are API-shape facts only.

Four architecture gaps prevent selection today:

- the documented API has no guest device-configuration write callback. Exact virtio-gpu
  `events_clear` behavior is therefore unproved, and standard virtio-input cannot implement its
  required guest-written `select`/`subsel` capability queries;
- `VZGuestMemoryMapping` exposes only an in-process pointer, not the descriptor authority Dory's
  sandboxed renderer worker requires for retained guest backing. Worker-owned host-visible blobs
  may be mappable through VZ, but that exact lifetime and coherence remain a physical gate;
- custom GPU scanout has no VZ presentation or input-injection object. Dory's worker SHM/fence to
  Metal contract can remain the presentation mechanism, but it must move behind a reusable sink;
  VZ built-in input without a built-in graphics scanout is undocumented, and a hidden second GPU is
  not an accepted product architecture;
- Dory cannot serialize complete renderer contexts, resources, fences, mappings, and scanout
  leases. `supportsSaveRestore` must remain false and the resolver must reject saved-state
  requirements for this candidate.

Before selection, an Xcode/macOS 27 probe must prove all of the following on a stock upstream Linux
virtio-gpu driver:

- PCI identity, GPU configuration bytes, feature negotiation, queue reset, and shared-memory region
  layout exactly match the OASIS and Linux contracts used by Venus;
- host-visible blob map/unmap lifetime, guest-memory mapping invalidation, reboot, sleep/wake,
  worker loss, and device loss are generation-fenced, while saved state is rejected deterministically
  unless a complete renderer snapshot contract is added later;
- Dory's renderer worker and synchronized Metal scanout remain the only accelerated command and
  presentation path; no renderer code moves into `dory-vmm`;
- installation remains usable with the custom GPU topology, stock VZ input can target Dory's custom
  presentation surface, and neither result depends on a hidden second GPU, distro-specific boot
  ordering, or compositor configuration;
- the custom-device adapter meets the same Zed, browser, compositor, visual-integrity, recovery,
  whole-VM latency, CPU, memory, storage, and power budgets as the RawHV candidate.

The implementation boundary, if selected, is one backend-neutral VirtIO GPU semantic core with
separate RawHV-MMIO and VZ-custom-queue transport adapters. Queue elements, guest-memory authority,
host-visible mappings, lifecycle generations, and scanout sinks are explicit protocols. In
particular, a process-local VZ guest mapping fails closed for any renderer operation that retains
guest backing; it is never copied into an unversioned shadow allocation. Dory MUST NOT fork a
second renderer protocol, disguise a VZ element as a `VirtqueueChain`, or copy the GPU state machine
into `DoryVMMKit`. RawHV and shipping VZ remain unchanged while the gate is blocked; beta API
availability cannot silently change an existing workspace's backend.

Each signed guest graphics pack is an immutable, relocatable dependency closure keyed by
architecture, libc family and maximum required symbol version, Vulkan loader/driver interface,
WSI set, and renderer protocol tuple. The Vulkan manifest uses a path relative to itself, as the
Khronos loader contract permits. The current single-tree pack has no RPATH/RUNPATH and statically
links libdrm with hidden symbols; it does not ship a renamed interposable libdrm DSO. Remaining X11,
XCB, Wayland, compression, Vulkan-loader, libc, and interpreter sonames are versioned guest
interfaces, not ambient pack search paths. Dory does not replace or bundle a second glibc into an
arbitrary application process and does not rely on a session-wide `LD_LIBRARY_PATH`. The resolver
selects the oldest compatible pack, then a bounded preflight parses and compares the exact
`DT_NEEDED` and symbol-version closure, rejects RPATH/RUNPATH, `GLIBC_PRIVATE`, exported DRM
symbols, and unresolved eager bindings, verifies the system loader interface and selected
X11/Wayland surfaces, opens the exact virtio-gpu render node, loads the ICD in an isolated probe,
and records the device identity. Unexpected or unresolved dependencies fail before activation.
This turns distro portability into an explicit ABI match rather than a builder-image accident.

Activation stages artifacts without replacing the distribution's system Mesa, records every file
and configuration mutation, reboots once into the candidate, runs renderer and recovery probes,
and commits only after the new operation generation is healthy. Guest kernel, initramfs, libc,
Mesa/loader, bootloader, or disk-generation changes invalidate the receipt and trigger bounded
revalidation. Recovery always remains able to select the persisted VZ EFI/NVRAM path without
depending on Dory's guest pack. This transition is the only sound way to project acceleration from
a managed RawHV cell onto a workspace originally installed from arbitrary compatible media.

## Graphics architecture

Graphics is four contracts, not one `accelerated` boolean:

1. guest-visible virtio-gpu protocol and negotiated capsets;
2. command-stream renderer and API translation;
3. resource/fence/lease lifetime protocol;
4. display presentation and input mapping.

VirGL2/OpenGL and Venus/Vulkan remain different guest capabilities and both belong to the
production worker architecture. The legacy in-process `VirglRenderer`, ambient path/environment
loader authority, OpenGL.framework dependency, and library-validation exception remain deleted;
VirGL2 is not permission to restore them. Foreign C layouts and calls remain owned by imported C
headers/shims; Swift must not hand-reproduce writable C structs.

The production boundary is one separately signed, sandboxed, resource-limited, one-shot XPC worker. It
statically links the reviewed virglrenderer, libepoxy, and MoltenVK inputs and carries only its
sealed XPC-local ANGLE `libEGL`/`libGLESv2` Metal pair as runtime libraries. VirGL2/vrend renders
through a callback-provided ANGLE Metal display; Venus renders through the static MoltenVK backend.
The graph contains no host Vulkan Loader or ICD manifest, ambient Homebrew dependency, renderer or
sync path selection, or environment-selected implementation. Libepoxy's dynamic resolution is
restricted to fixed `@loader_path` names for the two sealed ANGLE libraries. This removes the
former verify-close-then-reopen-by-path authority gap instead of moving it.

The worker protocol makes the dual boundary enforceable. It admits exactly VirGL2 capset 2 and
Venus capset 4, validates command and resource limits before mutation, records the resource bind,
and grants a Metal scanout lease only to a resource created with the scanout bind. Capability
receipts and live activation compare exact capset digests and feature bits; an unavailable or
different renderer cannot masquerade as either advertised capability.

Production exports direct virgl symbols only when both
`DORY_VIRGL_RENDERER_STATIC_LINKED` and `DORY_VIRGL_RENDERER_DUAL_METAL` are defined; a development
build without that contract returns `ENOSYS` rather than discovering a library. The build
deliberately does not define `VIRGL_RENDERER_USE_EGL`: in this pinned external-winsys integration,
that preserves the callback-provided ANGLE Metal display rather than selecting an ambient EGL
winsys. CGL/OpenGL.framework, host Vulkan Loader/ICD, path/environment selection, and every dynamic
lookup except the fixed XPC-local ANGLE resolver remain forbidden.

Virglrenderer's `proxy_*` layer remains the in-worker Venus transport and lifecycle coordinator:
in thread mode it creates the socket pair, starts `render_server_main` on a C11 thread, and carries
commands and fences to the `vkr_renderer` backend. VirGL2/vrend executes in the same isolated
worker, not in the VM process. Production gates require both reviewed branches while continuing to
reject vtest, DRM, Neptune, video, external render-server executables, and ambient dynamic-loader
authority.

Schema-3 tuple `dory-dual-metal-20260826` binds the exact virgl, libepoxy, ANGLE, and MoltenVK pins
and patch bytes, selected source partitions and build flags, final worker Mach-O and Code Directory,
capsets `[2,4]`, guest Mesa pack, expanded managed kernel, runner, and outer application as one
candidate. A top-level version or former component inventory cannot authorize it. Structural
packaging and a canonical nested-XPC transcript prove identity and protocol closure; only the
physical gates below can qualify real GPU behavior.

The guest side remains standards-based. Mesa negotiates VirGL2 capset 2 for OpenGL and Venus capset
4 for Vulkan. The Vulkan 1.3 Venus pack uses the in-guest Vulkan Loader and standard
`VK_KHR_external_semaphore_fd` `SYNC_FD` operations; the host worker does not use that loader/ICD
architecture. Runtime preflight requires a non-CPU Venus device, robust access, dynamic rendering,
synchronization2, maintenance4, exact device/instance extensions, Zed's required atlas usages, and
a real SYNC_FD submit/fence round trip. Because boot preflight has no display, native WSI is a
second gate: the active desktop must create an XCB or Wayland surface and a 64x64 FIFO swapchain
before the exact Zed workload begins. See
[`vulkan-13-application-readiness.md`](architecture-gates/vulkan-13-application-readiness.md).

The current managed Ubuntu desktop qualification cell is deliberately narrower and independent of
that Vulkan-native compositor experiment: GNOME runs under Xorg, GTK4 uses `GSK_RENDERER=gl`, and
Firefox uses XWayland with `MOZ_ENABLE_WAYLAND=0`. Qualification must prove Mesa reports direct
VirGL rather than llvmpipe/softpipe/swrast, map sustained GTK and Firefox windows, and observe
host-visible frame changes. These settings are managed-image compatibility policy and are never
injected into an arbitrary user's distribution.

A future Venus-native desktop compositor uses a separate
**optimal-render-to-linear-scanout** contract. Physical qualification on the exact Apple M2
Pro/MoltenVK tuple proved that both Dory scanout formats reject
`VK_IMAGE_TILING_LINEAR` color-attachment queries with `VK_ERROR_FORMAT_NOT_SUPPORTED`. The exact
virglrenderer source nevertheless hard-codes `COLOR_ATTACHMENT` into its emulated LINEAR DRM
modifier and removes color-attachment usage before asking the host. Adding the missing blend bit
would therefore make the guest contract less truthful, not more capable. wlroots' exact Vulkan
renderer requires both color-attachment and blend features for a render modifier, while Weston's
Vulkan renderer also blends into its GBM output attachment. Swapping compositors cannot remove the
host limit. See the exact
[virglrenderer modifier emulation](https://github.com/utmapp/virglrenderer/blob/65cc14eb896f121ffc5130ce04815a923a03c41d/src/venus/vkr_physical_device.c),
[MoltenVK linear-feature decision](https://github.com/utmapp/MoltenVK/blob/ef1c5461774f5fbd224ddcfd91fd2c0ea23f0384/MoltenVK/MoltenVK/GPUObjects/MVKPixelFormats.mm),
[wlroots modifier admission](https://gitlab.freedesktop.org/wlroots/wlroots/-/blob/329a88e72424486180ff3339440fa9f8f711af02/render/vulkan/pixel_format.c), and
[Weston Vulkan blending path](https://gitlab.freedesktop.org/wayland/weston/-/blob/d1882b0a544ae2197b597a6e39478e719bc54302/libweston/renderer-vulkan/vulkan-pipeline.c).

The separate Venus-native compositor research profile is
`native-vulkan-optimal-copy-compositor-v2`:

1. Applications and the compositor render and blend into an optimal-tiled, device-local Vulkan
   image. Application WSI remains the normal Venus path; it is not redirected through CPU memory.
2. The KMS buffer is a one-plane `DRM_FORMAT_MOD_LINEAR` DMA-BUF admitted only for
   `VK_IMAGE_USAGE_TRANSFER_DST_BIT`, KMS scanout, and the required external-memory/fence contract.
3. The same GPU queue records an explicit image barrier and `vkCmdCopyImage` from the optimal image
   into that LINEAR buffer. Submission completion becomes the framebuffer's producer fence; the
   kernel must wait for it before `RESOURCE_FLUSH`.
4. No CPU map, readback, queue-idle wait, software compositor, or hidden fallback is allowed in the
   frame path. Damage-region copies, buffering depth, and frame pacing are measured optimizations,
   not permission to skip synchronization.

The checked host probe executes that exact blend-and-copy transaction and verifies mapped result
bytes for both BGRA8 and RGBA8. On the observed M2 Pro tuple, optimal color-attachment/blend plus
transfer-source, LINEAR transfer-destination, both image-format queries, both submissions, and both
readbacks passed. This is host-path mechanism evidence, not a guest compositor frame or a speed
result. The guest profile must still pass through Venus, an actual imported virtio-gpu DMA-BUF,
KMS framebuffer creation, producer-fence handoff, worker-backed Metal presentation, and the
candidate performance budgets.

Two implementation changes are prerequisites and must remain reviewable as independent contracts.
Virglrenderer must derive its emulated LINEAR modifier features from the actual host
`linearTilingFeatures` and must query the host with the caller's real usage instead of deleting
unsupported bits. The guest compositor integration must admit transfer-destination-only output
modifiers, keep its optimal render image private, and perform the final copy before release. Dory
will not carry an unconditional capability-bit patch or pretend a directly rendered LINEAR image
exists. Until both changes and the physical v2 gate pass, native Vulkan compositor acceleration
remains unavailable. That result is independent of the managed Ubuntu VirGL/Xorg qualification
cell.

The worker consumes untrusted guest commands only through the bounded XPC protocol. A shared
texture is represented by a typed lease containing generation, dimensions, format, producer
completion fence, and release token. Destruction occurs only after the consumer acknowledges
release. The generation-aware single-use presentation authority, per-scanout acknowledgement,
bounded executor, outcome-unknown quarantine, and late-callback rejection remain required; none is
permission to reintroduce a same-process renderer or `glFlush()`-based ownership assumption.

Producer completion is established at the guest KMS boundary, not invented by the host. Upstream
Linux commit `30f86b8f86ada845fbd0d853b3a3d238567ac2c2` makes virtio-gpu plane preparation call
`drm_gem_plane_helper_prepare_fb()`. The DRM helper attaches the framebuffer writer fence to the
plane state, and the atomic helper waits for it before the plane update emits `RESOURCE_FLUSH`.
Dory's pinned Linux 6.12.106 does not contain that change, so the managed accelerated profile backports it as
`0007-virtio-gpu-wait-for-scanout-producers.patch`; a following Dory hardening patch propagates
fence-capture errors instead of emitting an unowned flush. Only an exact guest artifact that proves
this contract may use `RESOURCE_FLUSH` as producer-complete presentation authority. Generic Linux,
unknown kernels, and panic/unsynchronized display paths do not inherit that claim.

The production handoff is therefore ordered as follows:

1. Mesa submits work and publishes the framebuffer writer fence through the virtio-gpu reservation
   object.
2. The qualified guest kernel waits for that producer fence before sending `RESOURCE_FLUSH`.
3. The signed renderer worker exports a bounded shared-memory resource plus immutable dimensions,
   format, stride, offset, resource generation, and a single-use release token. The outer display
   process reconstructs a retained Metal texture; no renderer pointer or ambient path crosses the
   worker boundary.
4. `RESOURCE_FLUSH` authorizes one damage update for that generation. Metal command-buffer
   completion acknowledges consumer release; only then may guest unref, reset, or resource-ID reuse
   retire the backing allocation.
5. Worker death, device loss, missing fence proof, format mismatch, timeout, or an outcome-unknown
   command revokes the renderer generation and stops the uncertain VM. Typed candidate failures
   use status 86 and durably suppress only the exact runner/inventory/worker identity for six
   hours. A later automatic plan may cold-start its declared software recovery level; a
   hardware-only request errors. No in-VM switch to `llvmpipe` is attempted.

The exact release identity comprises the signed doryd entitlement, suspended runner CDHash gate,
renderer-worker peer requirement, compiled schema-3 tuple definition, canonical inventory, and
nested-XPC transcript. Runtime activation starts a fresh worker and requires exact equality with
that evidence before accepting a command. Public support additionally requires the pinned detached
qualification signature; Developer-ID-sealed evidence authorizes preview hardware testing only,
and a present invalid signature never downgrades to preview.

The qualification gate records the exact kernel, guest Mesa and loader closure, VirGL2 capset 2 and
Venus capset 4 bytes and generated protocols, ANGLE/virgl/libepoxy/MoltenVK input inventory, final
worker/runner/app identities, and signed launch receipt. It must also prove
producer-fence-before-flush ordering, 10,000-frame alternating-pattern integrity, resize and
multi-scanout lifetime, sustained GTK/Firefox VirGL and Zed/Venus workloads, status-86 candidate
suppression and cold software recovery, device loss, memory pressure, pause/resume, and destruction
ordering with no stale frame, torn frame, ID reuse, or leaked handle. MMIO reset/quiesce and bounded
mailbox pressure remain part of the same gate. The CPU path stays visible and correct while this
gate is open.

The dual package, sealed-XPC receipt path, and crash circuit breaker are implementation evidence;
there is still no release-qualified synchronized physical Mesa desktop frame, sustained Zed result,
or GPU/whole-VM performance evidence. Hardware acceleration therefore remains unavailable for all
public support cells. Today it can graduate only for an exact managed/direct-boot media tuple that
includes the producer-complete fence contract. Arbitrary EFI-installed distros retain the portable
software baseline until their exact kernel and graphics pack independently prove that contract;
results never project by distribution name, kernel family, or architecture alone.

The macOS 27 VZ custom-device spike must prove stock Linux/Mesa negotiation, standard virtio-gpu
identity, queues, blobs/shared memory, display integration, fences, resize, device loss, pause, and
save/restore or deterministic rejection. It is killed if these cannot be isolated and qualified.

## USB architecture

USB is a topology and resource-ownership problem, not a boolean feature:

- `usb.synthetic.mass-storage.hotplug@1` means a synthetic removable storage device;
- `usb.physical.passthrough@1` means authorized capture of a particular physical device;
- a physical qualification includes controller path, stable identity policy, device class,
  transfer types, reset/unplug behavior, entitlement, user grant, and backend;
- bulk/control/interrupt support never implies isochronous support for cameras or audio devices.

`doryd` owns a USB broker. It discovers and authorizes devices, establishes stable identities,
claims/releases them, enforces deadlines, journals attachment, and performs compensating release if
any later step fails. A runtime receives a brokered handle. Helper exit, VM stop, daemon recovery,
host unplug, reset, and authorization revocation all have deterministic cleanup.

The existing RawHV path is USB/IP over vsock into Dory Tools `usb-vhci` and Linux VHCI. It is not a
native virtual xHCI controller and is a managed-tools mechanism, not universal USB passthrough.
Bounded Phase 0 now gives that mechanism:

- exact operation, direction, opcode, identity, endpoint, setup, reserved-field, and frame-length
  decoding, with oversized and isochronous submissions rejected before payload allocation or host
  I/O;
- a 4 MiB per-request transfer ceiling, at most eight concurrent requests and 16 MiB in flight per
  device, and at most eight active USB/IP bridge connections;
- finite control, bulk, and interrupt host-I/O deadlines, bounded terminal detach/deinitialization,
  and retained request/object state that cannot be reused by a late completion;
- session-and-sequence-scoped UNLINK: the target may be aborted only when it is the sole active
  request on its physical pipe; otherwise the request fails with `EBUSY` instead of aborting an
  unrelated operation.

These are security and lifecycle bounds, not qualification evidence. Isochronous transfers remain
unsupported and must not be advertised for cameras/audio. The bridge still executes a SUBMIT
synchronously, so it cannot read a same-stream UNLINK until that SUBMIT returns. Timely precise
cancellation requires separate stream reading, bounded request execution, and ordered reply
publication; Phase 0 fails closed rather than issuing a broader pipe/device abort. A native virtual
xHCI controller remains the preferred generic RawHV Linux architecture. VZ physical USB remains a
macOS 27 beta capability until the final API, entitlement, consent UX, and device-class matrix pass.

## VirtIO and storage security boundary

All guest queue parsing uses one hardened implementation with:

- exact power-of-two queue validation within negotiated maxima;
- checked address, length, index, sector, and offset arithmetic;
- one indirect-descriptor level, no nested indirect chains, cycle detection, and direction checks;
- per-device segment, command, transfer, and allocation limits;
- queue-generation/epoch validation across reset;
- owned bounded values across concurrency boundaries, never guest-memory raw pointers marked
  `@unchecked Sendable`;
- fuzz, property, malformed-input, cancellation, reset, and memory-pressure tests.

### VirtioFS request and resource authority

VirtioFS is a separate process boundary, not another long-running callback inside the VMM. The
VirtIO contract places one device-readable FUSE request prefix before an optional device-writable
response suffix, and reserves the hiprio queue for `FUSE_INTERRUPT`, `FUSE_FORGET`, and
`FUSE_BATCH_FORGET`. Linux constructs reply-bearing requests in exactly those two groups, but sends
`FUSE_FORGET` as a readable-only buffer and can omit the writable group whenever `FR_ISREPLY` is
false. The RawHV frontend therefore rejects a writable-before-readable transition, a later readable
segment, a reply-bearing request without a complete response suffix, a normal opcode on hiprio, or
a priority opcode on a normal request queue. Readable-only `FORGET` and `BATCH_FORGET` complete with
used length zero. The frontend never concatenates same-direction fragments around an invalid
transition into a plausible message.

An ordinary `posix_spawn` child is not the production security boundary. Apple documents XPC plus
App Sandbox as the preferred privilege-separation mechanism, and separately documents passing URL
bookmarks between processes for dynamically authorized file access. Dory therefore uses a signed,
sandboxed worker target supervised through XPC, with exactly one workspace authority set per worker
process. A reused service process must not accumulate roots from unrelated workspaces. The daemon
creates the opaque bookmark only from an explicit share authorization, pins the selected root's
descriptor identity, and sends both facts at bootstrap; request messages never contain host paths.
The worker resolves and starts the scoped resource, opens its root without following a replacement,
and proves that root matches the daemon-pinned identity before accepting FUSE traffic. Whether the
selected macOS/XPC packaging produces a distinct process per workspace, transports the root
descriptor as intended, and retains only the bookmark's dynamic sandbox right is a physical design
test, not an assumption. A raw executable that merely receives an FD fails this gate.

The packaging topology is now explicit. An ad-hoc-signed macOS 27 (`26A5416b`) probe demonstrated
that the current raw `Dory.app/Contents/Helpers/dory-hv` executable resolves `Bundle.main` to the
`Contents/Helpers` directory and cannot look up an XPC service embedded in the outer app (Foundation
invalidates the connection with Cocoa error 4099). It also proved that making the VMM the
`CFBundleExecutable` of a nested `DoryHVRunner.app`, with the worker directly inside that runner's
`Contents/XPCServices`, succeeds; two concurrent runner processes received distinct worker process
identities. A launcher that subsequently `exec`s a second payload under `Contents/Helpers` loses the
runner bundle namespace and fails the same lookup. Therefore Dory must compile the real `dory-hv`
sources as the nested runner application's executable, not wrap or copy an out-of-bundle command
line payload. This is one-host design evidence, not qualification: the same namespace/process
identity result remains required on every supported macOS release and candidate signing mode.

The in-process filesystem authority now has the descriptor handoff required by that design:
`HostFS` can take a borrowed, already-authorized directory descriptor, duplicates it with
`F_DUPFD_CLOEXEC`, and uses only that descriptor for filesystem operations. Its event path is
non-authoritative metadata. A replacement-race test renames the authorized directory, installs a
different directory at the same path, constructs `HostFS` from the original descriptor, and proves
the replacement is invisible while the caller's descriptor lease remains open. Bookmark
resolution, identity comparison, peer authentication, and the XPC target still belong to the
worker bootstrap gate rather than this seam.

The daemon's canonical-path producer now uses POSIX `realpath(3)` for the deepest existing
ancestor instead of Foundation URL standardization. On macOS 27 Foundation rewrites the physical
`/private/tmp` and `/private/var` directories back to the `/tmp` and `/var` alias spellings; a
correct `O_NOFOLLOW` descriptor walk then rejects those aliases. The physical spelling is retained
through derived policy paths, control characters are rejected before the C boundary, and tests
prove a prepared `/private/tmp` data root can be opened by the trusted no-follow root broker.

The machine-readable integration and qualification gate is
[`docs/architecture-gates/virtiofs-worker-xpc.json`](architecture-gates/virtiofs-worker-xpc.json).
The real `DoryHVRunner.app` Xcode target is now present: it directly compiles the existing VMM
sources as its `dory-hv` `CFBundleExecutable`, targets macOS 15, contains no launcher or secondary
payload, and passes an isolated Xcode build plus deep/strict signature inspection. The path-free
bootstrap contract also carries one workspace/generation, canonical capability-sorted shares,
opaque bounded bookmarks, pinned root identity, guest ownership policy, per-share ceilings, and a
strict receipt; aggregate envelope size is rejected before buffer assembly and 10 focused tests
pass. The source graph now also contains the real XPC-service target, worker-specific sandbox and
bookmark entitlements, runner-local `Contents/XPCServices` dependency/embed phases, bidirectional
fixed code-signing requirements, one accepted connection and one-shot root bootstrap, the outer-app
runner embed, and the RawHV runtime cutover. The gate remains `blocked` until an exact release
candidate proves the complete nested code graph/signatures/entitlements and passes the sandbox,
root-replacement, isolation, interruption, blocked-syscall, and crash physical matrix. None of this
source/build evidence is candidate qualification.

Admission is a transaction with three explicit phases:

1. Under the queue lease, the frontend records checked guest-physical regions, validates the exact
   ordered layout, copies at most the negotiated per-request input ceiling, validates the complete
   FUSE header/opcode/declarations, and reserves the whole success-or-error response envelope. A
   no-reply forget request is the only state-changing request admitted without a writable suffix.
   Before popping a chain, a typed frontend permit gate mirrors the broker's immutable in-flight
   ceiling. A full gate leaves the descriptor guest-owned and records its request queue in FIFO
   deferred order; each completed request releases exactly one fair resumption opportunity.
2. The lease is released before host filesystem work. A per-workspace `DoryFSWorker` receives one
   bounded frame over its authenticated private XPC channel and operates only through bootstrapped,
   identity-checked share roots. The frame carries a lifecycle generation, share capability ID,
   request ID, opcode class, response capacity, and deadline. The worker never maps guest memory,
   never receives a host path in a request, and cannot add a root after bootstrap.
3. The frontend accepts a bounded complete response only for the same live generation, then writes
   and publishes it atomically under a fresh queue-lease check. Queue reset can discard a late
   response without waiting for the host syscall. It cannot cause a response to be written into a
   replacement queue generation.

Every mutating opcode must have enough reserved space for its complete successful response before
the worker starts it. A short or malformed descriptor chain receives a complete transport error
when a FUSE header fits and otherwise completes with zero bytes without crossing the host mutation
boundary. Rollback of a newly allocated node or handle is defense in depth, not the correctness
mechanism; rename, write, setattr, fsync, link, lock, and removal are never started on the theory
that they can later be undone.

`DoryFSWorker` has launch-envelope limits, not environment tuning, partitioned per share and for the
whole workspace: active and aggregate request bytes, response bytes, nodes/identity descriptors,
file handles, directory cursors, advisory-lock owners, and reserved file-descriptor headroom.
`READ` and `WRITE` are capped by the negotiated FUSE maximum. `READDIRPLUS` is an incremental cursor
that looks up only entries that fit the current bounded response; it never reads, sorts, registers,
or retains an entire host directory. Quota tokens are returned on `FORGET`, `RELEASE`, `RELEASEDIR`,
connection reset, worker exit, and failed admission.

`FUSE_INTERRUPT` maps to a request-scoped cancellation message. Cancellation of a host syscall is
best effort, but VMM shutdown is bounded: stop admission, invalidate the generation, request worker
drain, then invalidate the XPC connection and require the supervised worker process to terminate
after the deadline. Because all share descriptors and locks live in that process, terminating it is
deterministic cleanup; a blocked host filesystem cannot pin MMIO reset or VM teardown. Unexpected
worker exit fails every share in that workspace and the workspace readiness fact rather than
silently restarting with lost handle identity.

The frontend exports protocol-boundary request, worker-response, and guest-published payload bytes;
completed, failed, in-flight, and peak request counts; and total and maximum
admission-to-completion latency. It closes both the request-gate lifecycle count and performance
in-flight count when transport loss or reset rejects publication. Payload bytes are deliberately
not labeled as physical copy bytes: Foundation and XPC allocation behavior requires separate
candidate-bound instruments.

The nested worker frame and outer RPC codecs stage only their fixed 72-byte and 16-byte headers,
append payload `Data` into one pre-sized encoded frame, and retain bounded `Data` slices while
decoding. This removes the source-visible payload-sized byte-array and rebasing allocations from
both decoder layers. It does not imply that XPC itself performs zero copies; physical allocation,
memory-bandwidth, and latency evidence remains a candidate requirement.

Inside the worker, FUSE header/opcode validation and `FuseServer` execution now consume the same
single bounded `[UInt8]` materialization. The previous second full request conversion is removed.
After the broker sends the encoded XPC frame, it retains only request/correlation identity, the
deadline, and bounded byte reservations through guest-publication acknowledgement. It no longer
keeps the complete request payload resident beside the encoded transport frame in that interval.

The production cutover now copies and validates one bounded host-owned request under
`withLeaseHeld`, releases the lease, crosses `DoryFSWorkerBroker` into the runner-local XPC service,
and publishes only after a fresh generation/lease check. `FuseServer` remains in-process only inside
the isolated worker (and the explicitly synthetic test channel), not inside the production VMM.
The unrestricted full-chain read, special-case execution fan-out, and helper-side `DORY_FUSE_*`
environment behavior/trace/stats switches are gone. Production request-queue and memory-reclaim
policy are typed daemon-resolved launch arguments. Eager directory snapshots are also gone: each
open handle owns a descriptor-relative cursor and append-only stable cookie slots, retains only
names incrementally considered for bounded replies, and is subject to aggregate entry/name-byte
quotas with deterministic `EOVERFLOW` and release recovery. Source and focused test closure does not
qualify directory sharing. The exact signed nested bundle plus malformed-chain, quota-recovery,
blocked-syscall, root-swap, sandbox-denial, XPC reuse, and crash physical campaigns remain required.
Sandbox qualification must
prove that a worker cannot open the user's home, a sibling of an authorized root, another live
workspace's root, or a stale/replaced bookmark target, while normal rename, hard-link, and open-file
semantics remain confined to the authorized root.

Virtio-vsock is part of this boundary, not merely an internal byte pipe. The OASIS VirtIO
socket-device contract requires the runtime to use exactly the header's `len` bytes, validate the
stream tuple and CIDs, reject unknown types with reset, honor wrapping `buf_alloc`/`fwd_cnt` credit
arithmetic, and stop processing new requests when bounded resources are exhausted. Dory must
therefore bound connection count, per-connection and aggregate receive memory, queued
host-to-guest packets, listener sessions, and host-port allocation. Duplicate tuples, missing RX
buffers, stalled preambles, reset, and teardown cannot overwrite state or grow detached workers
without limit.

The in-process boundary now enforces those budgets in two layers. Core virtio-vsock validates the
exact wire payload/direction, Linux's 64 KiB packet ceiling, wrapping credit arithmetic, finite
chain/byte work per turn, transactional fragmented RX publication, and reset epochs. Above it, one
per-VM service authority owns typed per-service and aggregate leases for agent RPC/socket/forward,
Docker, filesystem events, host AI, SSH-agent, shell, and USBIP sessions. Registration and session
publication are generation-bound; reset revokes active leases while retaining intended listeners,
terminal quiesce drains service-owned callbacks, and raw connection APIs are not public bypasses.
This removes the detached relay and duplicate bridge-local cap implementations. Physical
multi-service starvation/reset evidence, durable daemon telemetry, and any reserved QoS minima are
still qualification work.

Block requests are validated against the authorized descriptor's immutable capacity before I/O.
Out-of-range or overflowing access fails the request and cannot extend the image. Flush, discard,
write-zeroes, cache mode, power loss, snapshot, and host disk-full semantics are explicit.

No accelerated/device feature can graduate while an untrusted guest can crash, exhaust, or corrupt
the runtime through a malformed queue.

## Capability and support truth

Every capability record keeps four independent facts:

1. implementation: absent or present in source;
2. reachability: internal, product-visible, or none;
3. qualification: no evidence, developer evidence, or exact signed candidate evidence;
4. support: Unavailable, Unqualified, Preview, or Supported.

Support is conjunctive. For example, “accelerated Linux with physical USB and saved state” is
supported only if one selected backend and exact device set has evidence for all three together.
Evidence from different backends may not be combined into a fictional configuration.

Qualification identity binds the Dory build, macOS build, Mac model/GPU, backend and virtual-
hardware ABI, entitlements, guest image/kernel/Mesa, Dory Tools, renderer/ANGLE/MoltenVK,
schema-3 tuple and capset digests, firmware, storage format, requested devices, and test-suite
version. Missing, expired, revoked, or mismatched evidence fails new hardware-accelerated launches
closed. Existing machines receive an explicit migration/recovery path; they do not enter normal
legacy compatibility silently.

The performance-to-support authority is not yet complete. The schema-1 bundle verifier now derives
`matrixCellID` from a canonical descriptor bound to the exact signed candidate, installer,
installed guest, host identity/topologies, backend, resources, devices, graphics receipts,
harness, workload, and sampling plan; release admission also requires caller-supplied cell, ISO,
backend, and graphics bindings. Qualification-manifest schema 1 still has no per-record performance
reference, however, and component finalization currently turns every validated record identity
into catalog qualification metadata without consuming a Linux VM performance bundle. Adding an
unchecked digest field would create the appearance of authority without proving it. The remaining
cutover must therefore land as one schema and producer migration:

1. the physical campaign producer emits one canonical support-cell descriptor per proposed Linux
   record; its digest is the bundle's `matrixCellID` and includes exact media kind/source/digest,
   backend implementation/runtime, hardware ABI, graphics tier, device contract, host class,
   component identities, and runtime-plan digest;
2. extend the verifier's authenticated in-memory result into the canonical receipt consumed in the
   same verification transaction, containing that cell ID, bundle-inventory digest, performance
   signing-key ID, and every verified candidate binding; a detached unsigned JSON projection is
   not authority;
3. qualification-manifest schema 2 makes the precatalog candidate binding mandatory and gives each
   Linux record exactly one such receipt reference;
4. component finalization verifies every bundle against caller-supplied publication identities and
   the reviewed performance trust root, recomputes the record's canonical cell descriptor, and
   requires a bijection between proposed Linux records and verified receipts before emitting any
   catalog qualification IDs.

The receipt and record sets must reject missing, duplicate, extra, or differently keyed cells.
Generic VZ installer support also needs exact external-media campaign evidence: the current
finalizer admits only `dory-bundled` media already present in the candidate inventory, so it cannot
be widened to vendor or user ISO claims by distribution name. The final catalog remains downstream
of this comparison and is deliberately absent from the performance bundle, avoiding the former
post-qualification catalog cycle. Until the producer, receipt, schema, resolver, and finalizer land
together, schema-1 records are legacy/unqualified migration input for this purpose and the public
release stop remains in force.

## Release invariants

Linux cannot go live until all are true:

- catalog schema 2, qualification manifest, SBOM, signatures, and candidate hashes are generated in
  one correctly ordered release transaction;
- the normal daemon startup path does not enable legacy path/environment launch authority for new
  machines;
- VirtIO, vsock, and block P0 security gates pass resource-exhaustion, fuzzing, reset, and crash
  tests, and VirtioFS host work is isolated behind the bounded worker contract above;
- every production launch/device/listener authority has one owner; zero-symbol checks prove that
  replaced split flags, inferred allocators, unbounded listener loops, and compatibility launch
  shims are absent rather than dormant;
- the append-only RawHV ABI-v1 table, schema-5 topology, wrapper-schema-3 canonical authority, and
  authenticated wrapper-schema-2 legacy replan fixtures remain frozen and pass their compatibility
  gates;
- resolved RawHV schema-v5 compute/multiqueue and FD 3/4/5 launch authority retains canonical,
  replacement-race, descriptor-cleanliness, and retry/restart evidence; hardware-3D launches add
  the exact immutable FD 6 renderer bootstrap and software launches prove its absence;
- the final renderer graph is the signed schema-3 dual worker described above: only VirGL2 capset 2
  and Venus capset 4, with static virgl/libepoxy/MoltenVK inputs, the sealed XPC-local ANGLE pair,
  and no ambient host renderer, Vulkan Loader/ICD, Homebrew, path, or environment authority;
  doryd release identity is propagated through `HvProcess` and enforced by the runner's exact
  worker peer and live-receipt requirements before any untrusted renderer command executes;
- daemon-owned provisioning and compensation pass crash injection at every phase;
- selected backend claims match the capability ledger exactly;
- every proposed Linux support record has exactly one release-qualified performance receipt, the
  verified receipt set equals the proposed record set, and the record carries the authenticated
  bundle-inventory digest;
- generic compatible ARM64 EFI media retain a software-rendered VZ install/boot/application cell
  independent of optional tools or accelerator availability;
- GPU/USB claims have physical exact-candidate evidence for every claimed exact native-ARM64 Linux
  media cell. GPU claims additionally bind a managed/direct-boot producer-complete fence contract;
  neither claim may be projected from another ISO, kernel, or distro label;
- unsupported operations are absent or disabled in the UI with the resolver's exact reason;
- support bundles are bounded, path-safe, and redaction-tested.

## Primary research sources

- [Apple WWDC22: Create macOS or Linux virtual machines](https://developer.apple.com/videos/play/wwdc2022/10002/)
- [Apple: VZVirtioGraphicsDeviceConfiguration](https://developer.apple.com/documentation/virtualization/vzvirtiographicsdeviceconfiguration)
- [Apple: VZUSBController](https://developer.apple.com/documentation/virtualization/vzusbcontroller)
- [Apple: VZUSBPassthroughDeviceConfiguration (beta)](https://developer.apple.com/documentation/virtualization/vzusbpassthroughdeviceconfiguration)
- [Apple: Custom VirtIO drivers (beta)](https://developer.apple.com/documentation/virtualization/custom-drivers)
- [Apple WWDC26: Expand the capabilities of your Virtualization app](https://developer.apple.com/videos/play/wwdc2026/224/)
- [Apple: macOS 27 beta release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)
- [Apple WWDC23: Save and restore machine state](https://developer.apple.com/videos/play/wwdc2023/10007/)
- [Apple: Metal resource synchronization](https://developer.apple.com/documentation/metal/resource-synchronization)
- [Apple: Metal synchronization events](https://developer.apple.com/documentation/metal/about-synchronization-events)
- [OASIS VirtIO 1.4 specification](https://docs.oasis-open.org/virtio/virtio/v1.4/)
- [Linux virtio-fs host/guest filesystem documentation](https://docs.kernel.org/filesystems/virtiofs.html)
- [Linux virtio-fs driver request construction](https://github.com/torvalds/linux/blob/master/fs/fuse/virtio_fs.c)
- [Linux FUSE protocol UAPI](https://github.com/torvalds/linux/blob/master/include/uapi/linux/fuse.h)
- [Linux FUSE interrupt behavior](https://www.kernel.org/doc/html/latest/filesystems/fuse/fuse.html)
- [Apple: Creating XPC Services](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html)
- [Apple: Enabling App Sandbox](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)
- [Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Apple: Designing Secure Helpers and Daemons](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/DesigningSecureHelpers/DesigningSecureHelpers.html)
- [virglrenderer public API](https://gitlab.freedesktop.org/virgl/virglrenderer/-/blob/main/src/virglrenderer.h)
- [UTM dependency build and exact graphics pins](https://github.com/utmapp/UTM/blob/8e4de50817e76a83d6840212311627a78dd4f8b2/scripts/build_dependencies.sh)
- [UTM virglrenderer macOS render-server candidate](https://github.com/utmapp/virglrenderer/tree/65cc14eb896f121ffc5130ce04815a923a03c41d)
- [UTM QEMU virtio-gpu Metal scanout candidate](https://github.com/utmapp/qemu/tree/6601422e1fff2da1376faafb1e4c2c5cdb2d8003)
- [Linux virtio-gpu producer-fence fix](https://github.com/torvalds/linux/commit/30f86b8f86ada845fbd0d853b3a3d238567ac2c2)
- [Linux GEM plane synchronization helper](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/drm_gem_atomic_helper.c)
- [Mesa: VirGL](https://docs.mesa3d.org/drivers/virgl.html)
- [Mesa: Virtio-GPU Venus](https://docs.mesa3d.org/drivers/venus.html)
- [Khronos Vulkan loader driver-manifest and Linux discovery contract](https://github.com/KhronosGroup/Vulkan-Loader/blob/main/docs/LoaderDriverInterface.md)
- [Mesa local-build installation and Vulkan driver selection](https://docs.mesa3d.org/install.html)
- [Mesa 26.1.4 release and source digest](https://docs.mesa3d.org/relnotes/26.1.4.html)
- [Dory's pinned `0.10.4e-krunkit` renderer source](https://gitlab.freedesktop.org/slp/virglrenderer/-/tree/0.10.4e-krunkit)
- [QEMU VirtIO GPU documentation](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html)
- [QEMU Arm `virt` platform](https://www.qemu.org/docs/master/system/arm/virt.html)
- [libkrun](https://github.com/libkrun/libkrun)
- [Khronos MoltenVK](https://github.com/KhronosGroup/MoltenVK)
