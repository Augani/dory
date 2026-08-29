# Linux virtual workspace delivery plan

- **Status:** Active implementation plan
- **Date:** 2026-08-26
- **Architecture:** [`linux-virtual-workspace-architecture.md`](linux-virtual-workspace-architecture.md)
- **Capability ledger:** [`linux-capability-and-qualification-matrix.md`](linux-capability-and-qualification-matrix.md)
- **Performance contract:** [`linux-vm-performance-contract.md`](linux-vm-performance-contract.md)

## Current release decision

Keep hardware-accelerated desktop and Linux 1.0 claims closed. The portable baseline is separate:
a structurally compatible native ARM64 EFI ISO must remain installable, bootable, and usable with
Virtualization.framework 2D/software graphics even when no accelerator record or Dory Tools are
present. The branch is not a production acceleration candidate until the P0 security/trust gates
and architecture cutover below are complete. Existing package tests establish a regression
baseline; they are not physical VM qualification.

Current strengths to preserve include signed-plan and durable-authority work, lifecycle journals,
artifact verification, host-share identity checks, RawHV VirtIO mechanisms, guest tooling,
telemetry, and accelerated renderer experiments. The plan avoids a rewrite of proven mechanisms;
it removes the inverted ownership and unstable contracts around them.

Cleanup is part of every slice. Once a typed authority replaces a flag, environment value, inferred
allocator, listener loop, or adapter, the old implementation and its obsolete tests are removed in
the same change. Compatibility code is retained only when it decodes an identified historical
schema into replan/migration input; no compatibility path may also authorize a new launch.

Current immutable guest precursor proof, which is build evidence rather than physical
qualification:

- the accelerated ARM64 Linux 6.12.106 kernel was rebuilt from the exact pinned source with all
  eight zero-fuzz patches and independently reverified against input fingerprint
  `53f9eec131736cf44bd2c4caae9d150f26fba86e0b63d170fd8398db4291f998`; `Image-desktop` is
  `d60981a8d87287fff2ee111264080f0c3a009394001df64e7851059a4d7c2eb1` and its zstd artifact is
  `f5082b6d66751fc8041465dfe649b303f1758c4a6c5e9caa1e132b2bf3484b98`;
- the Ubuntu ARM64 managed-desktop rootfs passed its exact package, graphics-pack, and update-bundle
  verifier; the ext4 image is
  `c0dfd7c9c0f7d57a13e1d05e4f2608c5fd22c7b1e36b7b8668a77aa57460223b` and its zstd artifact is
  `1b1ea305002a7e9a2e97e7c7cf92bb7c07336abc66a4a0b9aa766255cdc0c07a`.

Neither artifact may enter the public support catalog until the exact application/component
precursor passes isolated physical Mesa VirGL desktop, Venus/Zed, and whole-VM qualification and
finalization binds the same bytes.

## Stop-the-line findings

| Priority | Finding | Required outcome |
|---|---|---|
| P0 | Guest-controlled VirtIO queue layouts, descriptor arithmetic, nesting, and allocation are not uniformly bounded | One hardened parser, checked arithmetic, strict limits, reset epochs, fuzz/property corpus |
| Closed P0 foundation | Virtio-vsock accepted unbounded work and guest-triggered host services created detached or independently capped relays | Core packet/CID/type/credit/queue limits and one per-VM typed service admission authority now cover every guest-triggered host service, with generation-safe reset/quiesce/drain and 103 focused tests. Retain fuzzing and booted-Linux starvation/wraparound/reset stress before qualification |
| Closed P0 foundation | VirtioFS host syscalls and `FuseServer` now execute behind the authenticated, sandboxed per-workspace `DoryFSWorker`; the VMM retains bounded descriptor validation, exact share capability/bootstrap authority, one shared workspace admission ledger, and publication commit/discard ownership rather than an in-process filesystem fallback | Retain this as a release stop until physical blocked-syscall, root-swap, malformed-worker-reply, worker-crash/reap, reset, and multi-share saturation campaigns prove the exact signed production bundle; this structural cutover is not physical qualification |
| P0 | Resolved RawHV disk and boot now come from one broker-owned, trusted-root machine-directory generation, but shares, gvproxy, saved state, snapshots, and lifecycle/control sockets still use path or CLI authority | Extend trusted-root/resource brokers to the remaining authorities; retain bounded I/O, power-loss, malformed-request, and replacement-race gates |
| Closed P0 foundation | Component assembly and support-bearing catalog publication previously formed a circular release dependency | `build-components.py assemble` now emits an immutable unqualified candidate inventory without SBOM, qualification, or catalog inputs. Qualification and SBOM bind that exact inventory; `finalize` verifies the bindings, copies unchanged candidate bytes to separate output, and only then emits and signs the schema-2 catalog. Retain public-release preflight until the real qualification producer and all publish gates are wired |
| P0 | The release workflow's existing performance job measures container-engine workflows and cannot authorize Linux VM performance; the signed whole-VM bundle verifier is not yet connected to physical release evidence | Keep container-engine evidence separately named. Publication must depend on a physical Linux VM campaign covering every exact supported native-ARM64 media cell, verify the signed bundle in release-qualified mode against all immutable candidate identities and a source-reviewed public key, and fail closed before the first publication action |
| P0 | Qualification-manifest schema 1 has no performance-bundle reference, and `build-components.py finalize` currently publishes qualification IDs for every validated record without proving that the proposed record set equals the verified Linux VM performance-cell set. Its media binding also admits only candidate-packaged `dory-bundled` media, so it cannot authorize exact external VZ ISO cells | Land the campaign producer, authenticated machine-readable verifier receipt, manifest schema 2, runtime resolver migration, and finalizer bijection in one cutover. Every Linux record must carry one verified bundle-inventory digest; missing, duplicate, extra, mismatched, or wildcard/extrapolated cells fail before catalog construction. Do not add digest-only placeholder fields while the producer/receipt contract is absent |
| P0 | Normal schema-1 catalog activation permits legacy path/environment launch authority | New machines fail closed; legacy authority is an explicit, audited existing-machine migration only |
| Closed P1 foundation | Optional RawHV devices previously renumbered later MMIO/IRQ addresses | Durable append-only ABI-v1 roles, schema-5 topology reconciliation, explicit sparse launch slots, fingerprints, and golden/property fixtures now preserve holes and survivors; retain this as a compatibility invariant |
| P1 | Generic RawHV Linux does not boot the installed disk's EFI path | Keep generic ISO/UEFI on VZ or implement qualified UEFI/NVRAM; narrow managed-image claim |
| P1 | Shared-texture graphics has typed lease/release ownership, but Dory's pinned Linux 6.12.106 does not include the framebuffer writer-fence change before `RESOURCE_FLUSH` | The upstream producer-wait backport is now in the managed accelerated kernel profile; retain acceleration fail-closed until the signed renderer worker consumes that exact boundary and passes reorder/destruction/device-loss evidence |
| P1 | The accepted host architecture is one sandboxed, one-shot XPC worker with a dual VirGL2-plus-Venus contract. Schema-3 tuple `dory-dual-metal-20260826` binds capsets `[2,4]`, the statically linked virglrenderer/libepoxy/MoltenVK closure, the XPC-local ANGLE Metal pair, and exact runner/worker identities. The worker has no ambient Homebrew, Vulkan Loader/ICD, renderer-path, sync-path, or environment authority; independent Mach-O, zero-rpath, entitlement, CDHash, inventory, and deep-signature checks are structural evidence | Pass the first producer-fence-waited synchronized Metal frame, installed production-signed launch, physical Mesa VirGL desktop and Venus/Zed cells, reset/device-loss recovery, 10,000-frame integrity, and whole-VM performance gates. Structural packaging remains evidence, not GPU qualification |
| P1 | USB/IP requires Dory Tools, rejects isochronous transfers, and has incomplete compensation/deadlines | Daemon USB broker; honest tools-only preview; xHCI or final VZ physical-USB qualification |
| Closed P1 foundation | MachineManager used one process-wide operation lock and singular pending-start state | A reference-counted per-workspace coordinator now serializes same-workspace mutation while independent workspaces progress; canonical multi-workspace acquisition, exact compare-and-commit, 100 MachineManager tests, and the focused coordinator/launch/lifecycle/planning/resolved gates pass. Daemon-wide shutdown admission remains separate work |
| Closed P1 foundation | `spawnPreparedMachine` previously retained the global machine-table lock while hashing/copying large disk and boot resources | A UUID launch reservation and immutable authority snapshot are captured under the lock; runtime setup, share/saved-state checks, RawHV hashing/staging, handoff creation, and process configuration run outside it; exact generation, configuration, state, object identity, authority, and reservation comparison gates commit. Four concurrency, 34 resolved-plan, 6 share-authority, and 7 saved-state tests pass |
| P1 | Readiness is reduced to first frame/generic state | Named readiness facts and backend event stream |

`DoryVirglRendererShim` retains the concrete fix for the former 36-byte Swift versus 40-byte C
`virgl_renderer_resource_info` overwrite. Its production bridge is direct-static-only and requires
both `DORY_VIRGL_RENDERER_STATIC_LINKED` and `DORY_VIRGL_RENDERER_DUAL_METAL`. VirGL2 uses the
callback-provided ANGLE Metal display, while Venus uses the statically linked MoltenVK path; the
build deliberately does not define `VIRGL_RENDERER_USE_EGL`. Libepoxy may resolve only the two
sealed ANGLE libraries through fixed `@loader_path` names; no caller-controlled path/environment or
ambient loader authority is accepted. Development use without the static compile contract returns
`ENOSYS`. This is required source/ABI closure, not completion of the graphics gate.

## Phase 0 — Preserve evidence and close immediate unsafe boundaries

**Goal:** Stop adding feature breadth while the current mechanisms can be attacked or corrupt data.

Deliverables:

- retain the imported C virgl resource-info shim and its compile-time size/offset assertions while
  enforcing the direct-static-only dual-Metal contract: VirGL2 through the XPC-local ANGLE pair and
  Venus through static MoltenVK, without ambient loader/path/environment authority;
- add a build-time compatibility probe against the exact pinned virglrenderer header before an
  artifact can be published;
- fix CPU scanout generation and add delayed-release/resource-ID reuse tests;
- replace guest queue arithmetic with checked primitives and explicit limits;
- reject invalid queue sizes/layouts and nested indirect descriptors;
- impose per-command bytes/segments/allocation limits before GPU decoding;
- enforce the VirtIO socket-device packet, tuple, credit, and bounded-resource contract, including
  guest-triggered service admission and reset/drain;
- move VirtioFS host work behind the documented bounded worker contract; reject malformed
  direction/order and queue/opcode routing before work, reserve the complete response, and enforce
  request, memory, node, handle, directory-cursor, lock-owner, and FD budgets;
- preserve the canonical schema-v5 compute/multiqueue and FD 3 system-disk, FD 4 kernel, optional
  FD 5 initrd, and hardware-3D-only FD 6 renderer-bootstrap authority
  while converting the remaining path/CLI resources to brokered handles;
- delete each replaced split launch flag, environment authority, inferred slot allocator, listener
  loop, compatibility wrapper, and obsolete test in the slice that supersedes it;
- add fuzz targets for VirtIO descriptor chains, GPU commands, block requests, USB/IP, vsock agent,
  and helper control protocols;
- keep direct-texture hardware 3D, physical USB, and RawHV saved-state claims unavailable or
  preview until their exact physical gates pass.

Exit gate:

- sanitizers and fuzz corpus show no crash, out-of-bounds access, unbounded allocation, image growth,
  or stale-pointer use;
- package suites and malformed-input regression suites pass;
- zero-symbol checks and dependency guards prove there is no dormant duplicate production
  authority;
- no release artifact can be assembled without exact ABI and provenance checks.

Progress through 2026-08-26:

| Slice | Closed now | Still open before the phase exit gate |
|---|---|---|
| Dual renderer worker source boundary | Imported C resource-info layout/call and 40-byte assertions remain. The production bridge binds direct symbols only under the static dual-Metal compile contract and returns `ENOSYS` in development. Schema-3 tuple `dory-dual-metal-20260826` inventories capsets `[2,4]`: VirGL2/vrend/libepoxy uses the callback-provided XPC-local ANGLE Metal display, while Venus uses the static MoltenVK backend. The sealed runner graph admits no ambient renderer, Homebrew, Vulkan Loader/ICD, or path/environment authority; libepoxy's only dynamic resolution is the fixed `@loader_path` ANGLE pair. Exact identities propagate through launch and worker peer admission, while independent verification covers ARM64-only allowed dependencies, zero rpaths, exact entitlements, nested signatures, and immutable inventory | Produce physical first-frame and producer-fence evidence, then pass installed production-signed launch, reset/device-loss recovery, 10,000-frame integrity, physical Mesa VirGL desktop and Venus/Zed cells, and whole-VM budgets. Do not revive the former in-process or ambient dynamic renderer graph as fallback |
| VirtIO split queues | Raw MMIO values are no longer clamped; queue size/layout/alignment, checked ring arithmetic, one negotiated indirect level, descriptor/segment/byte bounds, full feature-set validation, queue epochs/held leases, stale and cross-queue completion rejection, and adversarial reset tests. Publication exposes a typed published-or-revoked outcome, and hardened device drains use a throwing pending-count query instead of silently treating a corrupt ring as empty. GPU, vsock, sound, block, net, RNG, input, balloon, and VirtioFS now consume typed count/pop/publication failures with finite turn budgets instead of the former swallowed queue loops | Replace the remaining internal non-escapable convention and `@unchecked Sendable`; migrate any residual compatibility consumer; replace remaining default full-chain copies with protocol-specific limits before allocation; bound outstanding host I/O; add transport-wide FAILED propagation, structured fatal telemetry, and fuzz/property/sanitizer gates |
| VirtioFS request/resource authority | Primary-source and code-path audit defines the cutover: strict readable-prefix/optional-writable-suffix admission (readable-only forgets), hiprio opcode routing, full success-response reservation, bounded raw request IPC, daemon-authorized opaque root capabilities, launch-envelope quotas, incremental `READDIRPLUS`, lifecycle generations, and terminate/reap recovery in a sandboxed per-workspace worker. Frontend admission now copies a bounded host-owned request under the queue lease, releases it before the single generic `FuseServer` execution seam, and revalidates the generation for atomic publication; unrestricted full-chain reads and the special-case execution fan-out are gone. The daemon resolves reclaim and 1...8 request-queue policy into typed helper arguments, all helper-side `DORY_FUSE_*` and `DORY_ENGINE_RECLAIM_MODE` switches plus their ad-hoc stats/trace code are deleted, and a source-boundary test prevents their return. Eager whole-directory reads/sorts/entry snapshots are gone: `READDIRPLUS` now consumes a live descriptor-relative stream, retains append-only stable name cookies only as bounded replies consider them, re-looks up entries at reply time, and enforces aggregate entry/name-byte quotas with deterministic `EOVERFLOW` and release recovery. `HostFS` also accepts an already-authorized directory FD, duplicates it with CLOEXEC, and never reopens its non-authoritative event path; a replacement-race test proves a new directory at the same path cannot retarget the share. Canonical data-root paths now retain physical `realpath(3)` spellings so the no-follow root broker does not reject Foundation-generated `/tmp` or `/var` aliases. The path-free bootstrap contract binds one workspace/generation to 1...64 canonical shares, opaque bookmarks, pinned roots, guest ownership and per-share ceilings; it rejects an aggregate envelope above 4 MiB before assembly and its 10 focused tests pass. The real `DoryHVRunner.app` target directly compiles `dory-hv`, contains no launcher/secondary payload, and passes isolated Xcode build, Mach-O, entitlement and deep/strict signing inspection. Existing green evidence also includes 70 `HostFS` tests, one 177-test HostFS/quota/`FuseServer`/frontend/`VirtioFS` batch, 3 helper-policy, 35 daemon-configuration, and 11 worker-broker tests. The signed macOS 27 topology probe remains design evidence: raw `Contents/Helpers/dory-hv` cannot see the outer app's private XPC namespace, whereas concurrent runner executables receive distinct service processes | Implement the signed App Sandbox XPC worker target and one-shot bookmark/root-identity acceptance; add the runner-local dependency and `Contents/XPCServices` signing chain, authenticated IPC, outer-app/runtime-authority cutover, worker/frontend execution cutover, and exact nested-graph release binding. Prove the namespace result on every supported macOS release plus malformed layout, short response, quota recovery, blocked syscall, root replacement, XPC reuse, reset, worker-crash, and negative filesystem access |
| Vsock transport and bridges | Core virtio-vsock validates exact header/payload/direction, enforces Linux's 64 KiB packet ceiling plus per-turn chain/byte budgets, performs transactional fragmented RX publication, clamps peer credit with wrapping `u32` arithmetic, preserves packets across starvation/revocation, and exposes terminal per-queue fault telemetry. One per-VM `VirtioVsockServiceAdmissionAuthority` now owns typed per-service and aggregate capacity, two-phase generation leases, reset revocation, terminal quiesce, owned stop callbacks, and overload/late-publication telemetry. Agent RPC/socket/forward, Docker, filesystem events, host AI, SSH-agent, shell, and USBIP sessions all traverse it; raw register/connect entry points are internal and the remaining raw connects occur only after the bounded listener acquires the shared lease. Duplicate bridge-local limits/counters, detached relay service, public bypasses, and the unowned AgentChannel relay are gone. The recorded focused gates cover 103 tests, and both production builds pass | Run booted-Linux simultaneous Docker/SSH/AI/USBIP starvation, wraparound, reset, and reconnect stress; decide whether service QoS needs reserved minima rather than fail-closed aggregate caps; export durable daemon telemetry; replace bounded thread-per-session relays only if an evented/XPC design proves better; add transport-wide FAILED propagation, fuzzing, and physical evidence. `SOCK_SEQPACKET` and migration remain explicitly unsupported |
| Virtio-net and exact VZ NIC configuration | The modern 12-byte virtio-net header, strict descriptor direction and size rules, MTU enforcement, bounded ingress backlog and drain work, reset-safe lifecycle/path identity, and structured fault/overload telemetry are covered by 23 focused tests. A direct VZ configuration probe established that file-handle MTU 1280 is invalid and 1500 is valid. Connected exact VZ NICs now default to and require 1500, fail smaller values before gvproxy filesystem/process side effects, and leave the generic/RawHV/disconnected minimum at 1280. The isolated VZ batch passes 113/113 structural tests plus `dory-vmm` and `doryd` builds | This is correctness/build closure, not speed evidence. Add multi-queue/RSS only through a reviewed ABI revision; bind native VZ NAT versus file-handle/gvproxy and exact VZ storage mode in signed qualification; complete VPN, sleep/wake, host-network-change, sustained throughput, packet-loss, CPU, latency, and physical guest qualification |
| USB ownership and tools preview | USB contracts are shared through the `DoryVMContracts` leaf, and the daemon-to-helper transaction binds operation, bus, lifecycle, claim, and guest generations. Stop is serialized and bounded; uncertain host mutations retain the exact physical claim until they drain, and terminal guest state can safely retire guest-side uncertainty without another RPC. Engine and desktop owners consume the typed terminal outcome; 89 focused USB tests and both production builds pass | This closes ownership safety for the existing tools-only USB/IP preview, not universal passthrough. Add a native xHCI path or qualify final Virtualization.framework physical USB, preserve explicit consent and class policy, add isochronous support where claimed, and pass physical capture/reset/unplug/sleep/crash tests |
| Virtio block and RawHV disk/boot launch authority | Block requests now have exact descriptor layouts, a 16 MiB transfer ceiling, a 256-chain drain budget, full pre-I/O range/capacity validation, exact zero-padded 20-byte device identity, typed queue publication/revocation, global flush fencing, and explicit malformed-request, queue-fault, completion-fault, and bounded-drain telemetry. Ambient `DORY_BLK_*` behavior switches are gone; 31 focused and existing block tests plus 4 daemon telemetry tests pass. Canonical launch-envelope schema 5 binds admitted memory/vCPUs, scheduling-policy revision 1, and one system-disk queue per admitted vCPU, rejects split resolved CPU/memory flags, and fixes ordered authority at read-write FD 3 for the topology-bound system disk, read-only FD 4 for the exact kernel, optional read-only FD 5 for the exact initrd, and hardware-3D-only read-only FD 6 for the immutable renderer bootstrap. AppKit retains `userInteractive`; sustained vCPU, block, network TX/RX, and shared-filesystem work use the bound `userInitiated` profile, with three focused policy tests and a clean full package build. Production activation binds the selected data drive's exact machines root; one brokered machine-directory generation supplies the fixed disk/kernel leaves and private staging through `openat`/`unlinkat`, followed by post-admission and immediate pre-spawn lease revalidation. Boot blobs are size-bounded (256 MiB kernel, 512 MiB initrd), hashed, reopened read-only, revalidated and unlinked before transfer. Hardware-3D launch likewise revalidates exact signed tuple evidence, binds the expanded admitted kernel, and stages canonical FD 6 bytes into a reopened read-only unlinked file. The daemon retains disk, boot, and renderer authorities across bounded startup retry; launch uses closed stdin, descriptor-clean `posix_spawn`, PID-safe supervision, and no resolved pathname fallback. Launch admission now uses an immutable reservation/snapshot outside the broad machine-table lock and exact compare-and-commit before spawn | Convert shares, gvproxy, lifecycle/control sockets, saved state, snapshots, and other resources to brokered handles; preserve the renderer authority through final production-app packaging/signing; define resize/snapshot coordination; make host I/O bounded or cancelable; add physical scheduling-profile and single-versus-multiqueue responsiveness, throughput, latency, CPU and durability evidence, cross-device fixtures where privileged infrastructure permits, shrink-race, fuzz, power-loss, disk-full, crash-recovery, and exact-candidate evidence. This authority does not add RawHV firmware/NVRAM or qualify generic installed Linux |
| Remaining baseline VirtIO devices | RNG, input, balloon, guest-memory reclaim, and sound now use strict direction/layout validation, finite per-request and per-kick budgets, reset-safe publication, and explicit failure statistics. Input overload reconciles published key state; balloon reports typed mapped/released/reclaimed outcomes and moves all reclaim behind an enqueue-only, generation-fenced utility worker with one report per fair turn. RNG likewise moves CSPRNG generation and ring draining behind an enqueue-only, generation-fenced utility worker, caps work at 4 KiB per request and eight requests per fair turn, and exposes worker/yield/coalescing/revocation/entropy-latency counters. Sound bounds PCM buffers/periods/in-flight work and uses a generation-safe watchdog. The focused suites pass 9 RNG, 5 input, 7 balloon, 4 reclaim-state, and 12 sound tests; isolated Release `DoryHV` and `dory-hv` builds are green after RNG integration | Add true per-period host-audio cancellation when the host API can support it; qualify audio underrun/device change/sleep-wake, keyboard rollover and pointer/scroll behavior, memory pressure/reclaim, and CSPRNG behavior in physical Linux guests; fuzz every descriptor surface |
| GPU presentation ownership and launch authority | CPU and worker-backed paths retain typed generations, single-use presentation authority, bounded execution, producer-wait kernel policy, and fail-closed fence errors. The production worker admits exactly VirGL2 capset 2 and Venus capset 4 from schema-3 tuple `dory-dual-metal-20260826`; the exact ANGLE pair, static virgl/libepoxy/MoltenVK inputs, tuple definition, link contract, runner, and worker identities propagate through signed-XPC qualification and exact peer admission. Independent packaging verification covers ARM64/allowed dependencies, zero rpaths, signature, entitlement, CDHash, and inventory. Candidate renderer/XPC, Metal-device, or GPU-quiescence failures exit through status 86, suppress the exact runner/inventory/worker candidate for six hours, and stop the uncertain VM generation | Prove the first producer-fence-waited Metal frame, installed production-signed launch, recovery, 10,000-frame integrity, physical Mesa VirGL desktop and Venus/Zed cells, and whole-VM budgets. The next automatic plan may restart into its declared software recovery level; a hardware-only request errors. There is still no release-qualified synchronized physical frame or sustained application/performance evidence, so hardware acceleration remains fail-closed |
| Component publication | The green `scripts/test-build-components.sh` adversarial suite proves the ordering foundation: assembly succeeds without SBOM, qualification, signature, or catalog inputs and emits a canonical unqualified inventory; qualification and SBOM must bind that exact inventory; finalization rejects missing/extra/mutated bytes or mismatched evidence, copies unchanged bytes to separate output, and only then emits and signs the support-bearing schema-2 catalog. Public release preflight still fails closed | Produce the candidate-bound signed physical qualification manifest, connect the real qualification producer to assemble → SBOM → qualify → finalize in release CI, then retain signing, notarization, atomic publish, clean-machine install/update/rollback, crash/recovery, and exact-candidate gates before removing the public stop |
| RawHV MMIO and durable topology ownership | `DoryVMContracts` is a Foundation/CryptoKit leaf with the append-only ARM64 ABI-v1 role table, stable logical IDs, strict topology validation, deterministic allocator/reconciler, canonical bytes and an encoder-independent SHA-256 fingerprint stream. `ResolvedMachinePlan` schema 5 persists the reconciled topology; exact definition revision/digest and device-set revalidation gate start. The resolved launch envelope carries it, DesktopMode materializes logical roles at explicit sparse slots, and ARM/x86 boot surfaces preserve holes deterministically. Every compatibility entry point now passes its known slot explicitly, so the duplicate inferred dense allocator and its wrapper/test are gone. The runtime MMIO bus now validates and sorts cold attachments, seals the table before vCPU startup, and gives each vCPU a lock-free repeated-region cache with binary-search misses; 4 focused tests and the `DoryHV` target are green | Extend topology only through reviewed ABI evolution; retain compatibility fixtures and add exact-candidate MMIO exit/service-time, CPU, SMP, device-throughput and mixed-load qualification. This closure does not provide GPU acceleration, native xHCI, or generic installed-Linux boot |
| Resolved-plan repository authority | Current wrapper schema 3 writes and reads one compact sorted-key JSON form, authenticates canonical nested plan bytes, requires decode/re-encode identity, and rejects lexical mutation, reordering, and unknown record or nested-plan fields. Historical integrity wrapper schema 2 authenticates plan schemas 2–4 only and returns them as validated replan inputs; contradictory persisted provenance is rejected. Wrapper schema 1 is unauthenticated and replan-only | Keep schema-4 digest/migration goldens and current canonical-byte fixtures append-only; do not let any legacy wrapper enter normal launch authority |

These closures reduce immediate risk but do not complete Phase 0: the remaining cells are release
gates, not optional cleanup.

## Phase 1 — Extract Linux contracts without behavior change

**Goal:** Express every current Linux workspace without importing the legacy control plane into a
runtime target.

Completed contract/ABI foundation:

- the `DoryVMContracts` Foundation/CryptoKit leaf now owns the RawHV ARM64 ABI-v1 topology, stable
  logical IDs, typed append-only roles, strict canonical decoding, allocator/reconciler, and
  versioned fingerprint stream, with a dependency guard;
- the `DoryRendererWorkerWireContracts` Foundation/CryptoKit leaf now owns canonical renderer
  inventory, bootstrap, receipt, command, operation-payload, lease, and XPC bytes shared by daemon,
  runner, and worker rather than a runner-private duplicate;
- ABI-v1 fixes slots 0...30 by role, leaves slot 31 unassignable, represents absence as a hole, and
  treats multi-display as one GPU function;
- `ResolvedMachinePlan` schema 5 persists the exact reconciled topology and canonical definition
  digest; start revalidates the current definition revision/digest, device set, and runtime evidence;
- resolved RawHV launch carries that topology and attaches each materialized backend through the
  explicit sparse slot API, with deterministic ARM/x86 boot-surface checks;
- `RuntimeLaunchEnvelope` schema 5 is canonical resolved authority for admitted memory, vCPU count,
  scheduling-policy revision, one explicit system-disk queue per admitted vCPU, ordered FD 3
  system disk, FD 4 kernel, optional FD 5 initrd, and hardware-3D-only read-only FD 6 renderer
  bootstrap slots. It binds the disk logical ID to the topology, binds boot/bootstrap blobs to exact
  sizes/digests, rejects split resolved CPU/memory flags, and enforces managed-kernel versus
  installed-bundle root/initrd consistency. Existing daemon and runner code revalidates the plan,
  binds the expanded admitted kernel, stages/consumes immutable read-only FD 6, and establishes the
  broker before vCPU start. Schema-3 dual-worker inventory, production identity propagation, exact
  worker-peer admission, and structural nested packaging/signing are closed. Release-signed,
  notarized installed physical launch remains open;
- `RawHVMachineRunner` now gives the boot vCPU and full `Machine.run()` lifetime one dedicated,
  joinable POSIX owner thread across Desktop, Engine, and probes; teardown shares one native join
  and never relies on libdispatch or a cooperative executor for Hypervisor.framework ownership;
- repository wrapper schema 3 is exact canonical JSON authority; authenticated wrapper-schema-2
  plan schemas 2...4 and unauthenticated wrapper schema 1 are readable only for replanning.

Remaining deliverables:

- define and extract `WorkspaceSpec v2`, the broader resolved-plan and `RuntimeLaunchEnvelope`
  contracts, operation/event/readiness DTOs, and `ResolvedShareAttachment` without importing the
  legacy control plane into runtime/mechanism targets;
- define and fingerprint the VZ configuration ABI;
- finish byte-preserving workspace-definition migration and downgrade rejection;
- keep expanding golden JSON/device-tree, canonicalization/digest, migration, and property tests as
  each remaining contract moves;
- `DoryDesktopHostKit` extraction for reusable display/input/audio/clipboard primitives;
- `DoryGuestProtocolClient` extraction around the Rust wire client;
- remove `dory-hv -> DorydKit` and `dory-hv -> DoryVMMKit` dependencies;
- backend adapters stop embedding `DoryMachineConfiguration` and stop re-encoding plan choices into
  environment variables.

Exit gate:

- existing managed desktop, headless, and custom ISO definitions migrate losslessly;
- current behavior is reproducible from one immutable launch envelope;
- a dependency test rejects imports from runtime/mechanism targets into control-plane targets.

## Phase 2 — Make the daemon the sole orchestration authority

**Goal:** One durable, recoverable transaction owns every external effect.

Deliverables:

- per-workspace coordinator/actor replacing process-wide lifecycle serialization;
- unified stable condition, active operation, operation journal, and recovery reconciler;
- daemon-owned create/install/run/readiness transaction;
- resource brokers for file descriptors, artifacts, ports, gvproxy, network attachments, USB claims,
  bookmarks, and process trees;
- async/event-driven backend sessions and lifecycle capability dispatch;
- named readiness facts: process, boot, correct-size display, network, storage, guest protocol, and
  every required integration/device;
- idempotent compensation and orphan reconciliation.

Crash-injection gate:

- terminate app, daemon, runtime, renderer, gvproxy, and guest agent before and after every journal
  phase;
- prove no leaked claim, port, bookmark, process, temporary disk, incomplete catalog activation, or
  falsely-ready workspace;
- prove two workspaces progress concurrently while same-workspace mutations remain serialized.

## Phase 3 — Decide the production backend with evidence

**Goal:** Avoid permanently funding the wrong VMM architecture.

Run a bounded macOS 27 beta VZ custom VirtIO spike before promoting RawHV as the permanent Linux
backend. The spike is isolated from production contracts and uses the same guest-visible
virtio-gpu protocol expected by stock Linux.

Required prototype evidence:

- accepted standard virtio-gpu device identity, PCI class, queues, and feature negotiation;
- stock Ubuntu and Fedora ARM64 kernels bind `virtio_gpu` without a Dory kernel driver;
- stock/pinned Mesa negotiates both VirGL2 capset 2 and Venus/resource-blob capset 4 through the
  isolated dual renderer, without an ambient host renderer or loader path;
- shared-memory mappings and real workloads meet latency/throughput budgets;
- correct fences, resize, cursor, device-loss recovery, pause, and host sleep;
- custom device save/restore is correct, or the combination rejects saved state deterministically;
- renderer command handling is isolated from the VM control path;
- physical USB authorization, capture, hot-unplug, and cleanup work for allowed classes;
- signing, entitlement, notarization, and distribution path are confirmed against final OS APIs.

Decision gate:

- choose VZ custom VirtIO if it provides standards-compatible acceleration, lifecycle integration,
  isolation, and a supportable final API;
- otherwise retain VZ as generic/recovery backend and continue hardening the RawHV renderer
  candidate, with acceleration unavailable until all synchronization, isolation, and qualification
  gates pass;
- do not introduce QEMU merely to avoid this decision.

## Phase 4 — Complete the selected Linux runtime path

### Baseline VZ path

- arbitrary compatible ARM64 ISO/UEFI install and boot;
- reject x86_64-only distro media before allocation with a precise architecture explanation;
- persistent EFI/NVRAM identity;
- stable disks, NAT/host-only/offline profiles, VirtioFS, input/audio, and 2D display;
- distribution-owned software Mesa remains sufficient for login and ordinary applications; Dory
  Tools and the managed graphics pack are optional integrations, not boot prerequisites;
- exact connected file-handle NIC MTU of at least 1500, while the generic/RawHV/disconnected
  contract retains 1280; signed qualification binds native NAT versus file-handle/gvproxy and the
  exact storage controller/media/cache/synchronization mode;
- synthetic USB mass-storage hot-plug;
- qualified same-host pause/save/restore with exact compatibility binding;
- explicit rejection of unsupported 3D or physical USB on the host OS/backend in use.

### RawHV path, if retained

- hardened, fuzzed VirtIO core and fixed hardware ABI;
- generic UEFI/NVRAM or a clearly bounded managed-image boot contract with atomic boot-artifact sync;
- replace the legacy installer-ISO-derived kernel/initrd shortcut with the architecture's reversible
  acceleration-activation transaction: signed direct-boot artifacts, installed-disk generation,
  guest ABI preflight, exact guest/host renderer tuple, one candidate boot, and a VZ EFI rollback;
- keep arbitrary installed ISOs on the software VZ baseline until their exact kernel/direct-boot
  bundle proves the producer-complete framebuffer fence before `RESOURCE_FLUSH`; the managed Linux
  6.12.106 backport is not permission to project hardware acceleration onto an unknown distro;
- publish ABI-keyed, relocatable guest graphics packs from the signed catalog: build against an
  explicit oldest-supported libc sysroot, use a relative Vulkan ICD manifest and origin-relative
  non-libc DSO closure, and prove every symbol version, loader interface, soname, window-system,
  compositor, render-node, and kernel requirement before mutating a guest;
- qualify managed Ubuntu in its declared compatibility cell: Xorg, `GSK_RENDERER=gl`, and
  `MOZ_ENABLE_WAYLAND=0`, with mapped sustained GTK and Firefox workloads. These settings are
  managed-image policy and must never be injected into an arbitrary user's distro;
- daemon-opened storage/resources and no policy/path discovery in the helper;
- bounded device queues and observable backpressure;
- build the final signed, sandboxed dual renderer worker from the reviewed virglrenderer partition:
  VirGL2/vrend through static libepoxy and the sealed XPC-local ANGLE Metal pair, plus Venus through
  static MoltenVK; keep the host Vulkan Loader/ICD, ambient Homebrew dependencies, runtime
  path/environment selection, and every dynamic lookup except libepoxy's fixed `@loader_path`
  resolution of those two sealed ANGLE libraries absent;
- propagate the exact doryd release identity through the suspended-runner CDHash gate and enforce
  the candidate-specific renderer-worker identity before XPC activation;
- retain typed texture leases/fences/releases and a separately visible CPU path. A status-86
  candidate renderer failure stops the uncertain VM generation, suppresses only the exact
  runner/inventory/worker tuple for six hours, and lets the next automatic plan select declared
  software recovery; hardware-only requests fail explicitly rather than silently downgrading;
- stable xHCI-class guest contract plus daemon USB broker, or an honest Dory-Tools USB/IP preview;
- snapshot/pause semantics implemented completely or rejected before presentation.

Exit gate:

- no runtime owns control-plane policy; no daemon special-cases a backend to emulate its contract;
- UI operations are resolver projections and cannot request unsupported behavior.

## Phase 5 — Linux workspace completeness

Implement and qualify, in this order:

1. installation, boot, shutdown, restart, host sleep/wake, and recovery;
2. storage durability, disk resize, snapshot consistency, clone/export/import;
3. display scaling/Retina/full-screen/multi-display where the selected backend supports it;
4. keyboard, absolute/relative pointer, cursor, audio output/input, and recovery from device changes;
5. NAT, host-only, disconnected, forwarding, VPN/Wi-Fi behavior, then restricted bridge profiles;
6. shares with ownership/case/TOCTOU semantics, clipboard, and transfer/drag-drop;
7. optional Dory Tools update/rollback and health;
8. synthetic removable storage and qualified physical USB classes;
9. support bundles, redaction, resource budgets, and long-duration soak.

No row graduates because a code path exists. Use the living capability ledger and exact-candidate
evidence bundle.

## Phase 6 — Release transaction and physical qualification

The release build must be one ordered authority:

1. build and sign the exact application, runtime, and immutable component assets;
2. emit an unqualified candidate inventory of their hashes without making support claims;
3. create and verify the exact-app SBOM;
4. run one complete physical Linux VM campaign for every exact proposed support cell against that
   immutable inventory and produce authenticated verifier receipts;
5. construct and sign qualification-manifest schema 2, binding each Linux record to exactly one
   verified cell and bundle-inventory digest;
6. require finalization to prove that the proposed Linux record set and verified receipt set are
   equal, then assemble the support-bearing catalog from the unchanged inventory, SBOM, and
   qualification manifest;
7. sign/publish catalog and assets atomically;
8. validate a clean-machine install, launch, update, rollback, and recovery using published bytes.

The `build-components.py` foundation now enforces the candidate/catalog portion of this order.
`assemble` accepts no SBOM, qualification, signature, or catalog input and emits a canonical
unqualified candidate inventory. Qualification and the SBOM bind that exact inventory. `finalize`
requires those matching evidence inputs and the qualification signature, verifies the candidate's
exact file set and bytes, copies unchanged bytes into a separate output, and only then emits and
signs the support-bearing schema-2 catalog. The green
`scripts/test-build-components.sh` suite covers missing, extra, mutated, mismatched, and unsafe
candidate/final-output cases.

This closes the former circular-ordering foundation, not the release. Public publication remains
fail-closed. The current performance verifier proves one signed bundle, but it does not yet emit
the authenticated support-cell receipt that finalization needs, no physical campaign producer
supplies the exact proposed record set, schema-1 qualification records carry no bundle reference,
and finalization accepts no performance inputs. Because those gaps span the producer, verifier
result, manifest/resolver, and finalizer, a schema-only or digest-only change would be partial
authority and is intentionally not implemented. After the coherent cutover above, signing and
notarization, atomic publication, clean-machine install/update/rollback, daemon/runtime crash and
recovery, and the remaining exact-candidate gates must all pass before any release or support claim.

Minimum physical matrix dimensions:

- Mac model/SoC/GPU and supported memory sizes;
- final macOS version/build and provisioned entitlements;
- Dory/backend/hardware-ABI/renderer/component hashes;
- guest image, kernel, Mesa, firmware, and Dory Tools hashes;
- exact VZ network datapath and storage controller/media/cache/synchronization policy;
- device topology and physical USB class/device;
- clean install, upgrade, migration, rollback, host reboot, daemon/runtime crash, and disk pressure.

Representative workloads include desktop compositors, browsers, Zed/VS Code class editors,
OpenGL/Vulkan samples and sustained applications, compilers, package/kernel updates, media, large
file/fsync workloads, network forwarding/VPN, shares, audio, multi-display, USB reset/unplug, and
snapshot/save recovery.

## Workstream ownership and merge order

| Workstream | Owns | Must not bypass |
|---|---|---|
| Contracts/ABI | schemas, topology, canonicalization, migration fixtures | runtime implementation or UI policy |
| VirtIO security | queue parser, block/device bounds, fuzz harnesses | feature expansion |
| Control plane | coordinator, journal, brokers, recovery, async backend contract | guest device implementation |
| VZ backend/spike | VZ launch fragments, custom VirtIO research, saved-state evidence | production assumptions from beta APIs |
| RawHV runtime | Hypervisor/device mechanisms and launch-envelope consumer | daemon types, bookmarks, product policy |
| Graphics | renderer ABI/worker, fences/leases, presentation | generic `accelerated` claims |
| USB | broker, controller/proxy, consent and compensation | boolean passthrough claims |
| Supply chain | candidate build, SBOM, qualification, catalog, trust cutover | legacy fallback |
| Product UI | spec editing and resolver/status projections | filesystem/process/backend selection |
| Qualification | runners, physical matrix, retained evidence | changing runtime behavior except test hooks |

Merge order is security stabilization, contracts/ABI, migration, control-plane transaction, backend
adapters, runtime decomposition, device completion, UI projection, then release/qualification.

## Definition of Linux 1.0

Linux 1.0 is complete only when a user can install a supported ARM64 Linux distribution, use it for
real desktop and development workloads, update it, attach only devices the selected backend
truthfully supports, suspend or snapshot only when semantics are guaranteed, recover from crashes
and host reboot without data loss, and inspect exact reasons for unavailable features.

“Boots,” “has source code,” “worked on one developer Mac,” and “falls back silently” are not release
criteria.
