# Linux capability and qualification matrix

- **Status:** Living ledger; source presence is not a support claim
- **Date:** 2026-08-26
- **Architecture:** [`linux-virtual-workspace-architecture.md`](linux-virtual-workspace-architecture.md)

> **2026-08-25 recovery decision:**
> [`linux-iso-and-gpu-recovery-review.md`](linux-iso-and-gpu-recovery-review.md) separates the
> runnable ARM64 EFI/software baseline from exact-media support and optional acceleration. It also
> records the retired Venus-only/dual-contract contradiction. The schema-3 dual VirGL2/Venus
> package and real-bootstrap admission path now resolve that implementation fault, but hardware 3D
> remains Unqualified until the exact release-signed physical application gates pass.

## Status vocabulary

Each row tracks four separate axes:

| Axis | Values | Meaning |
|---|---|---|
| Implementation | Absent / Partial / Present | Whether mechanism source exists |
| Reachability | None / Internal / Product | Whether a normal user flow can select and operate it |
| Qualification | None / Developer / Candidate | Strength of retained exact-build evidence |
| Support | Unavailable / Unqualified / Preview / Supported | User-facing promise |

`Supported` and `Preview` require signed candidate evidence. `Preview` may have explicit exclusions;
`Unqualified` means it can be inspected or exercised by developers but is not a release promise.

## Backend facts

| Capability | VZ, shipping macOS 26 | RawHV current branch | VZ custom VirtIO, macOS 27 beta | QEMU/HVF |
|---|---|---|---|---|
| ARM64 Linux ISO/UEFI install | Present; baseline | Rejected by adapter | Expected VZ baseline | Present upstream |
| Installed disk boots its own EFI path | Present | Absent; host direct-boot bundle only, with no firmware/NVRAM | Expected VZ baseline | Present upstream |
| 2D Linux display/input | Present; Apple-documented | Present in source | Expected VZ baseline/custom | Present upstream |
| Linux guest VirGL/OpenGL | No public API | Isolated signed XPC worker advertises real capset 2 and presents VirGL scanout through the bounded Metal transport | Research hypothesis | Upstream renderer requires additional macOS work |
| Linux guest Venus/Vulkan | No public API | The same isolated worker advertises real capset 4 and presents descriptor-backed Venus scanout through Metal | Research hypothesis | Upstream renderer requires additional macOS work |
| Synthetic USB mass storage hot-plug | Present | Possible through other paths; not equivalent | Present | Present upstream |
| Physical USB capture | No public API | Tools-dependent USB/IP/VHCI mechanism with bounded Phase-0 parser and I/O lifecycle; no isochronous and not native xHCI | Beta API; entitlement/consent required | Experimental/device-limited on macOS |
| VirtioFS shares | Present | Present in source | Expected VZ baseline | Present upstream |
| NAT | Present | Present through gvproxy | Expected VZ baseline | Present upstream |
| Host-only/offline | Product/source paths exist; qualify | Source paths exist; qualify | Expected | Present upstream |
| Bridged/L2 | Restricted entitlement/profile | Not true generic bridge | Restricted entitlement/profile | Host-dependent |
| Same-host saved state | Present from macOS 14; qualify exact tuple | Not durable/complete | Custom device must participate correctly | Accelerator/device dependent |
| Portable snapshot | Separate disk/NVRAM contract required | Partial | Separate disk/NVRAM contract required | qcow2/QMP available; product contract still required |
| Stable hardware ABI | VZ config must be fingerprinted | Durable development foundation present: `DoryVMContracts` owns append-only ARM64 ABI-v1 roles/slots, IDs, reconciliation and fingerprinting; plan schema 5 persists the topology and resolved launch uses its explicit sparse slots. Not release-qualified | Must be defined | Requires pinned versioned machine/device tuple |
| Renderer/device parser isolation | VZ-owned 2D | Present in the candidate: separately signed sandboxed XPC, bounded command/descriptor budgets, schema-3 dual bundle inventory, exact peer CDHash, real-bootstrap receipt, and fresh live receipt comparison before command-lane activation | Dory responsibility for custom device | Process/sandbox configuration required |

No row implies that capabilities from different columns can be combined. The resolver selects one
backend that satisfies the complete requested topology and lifecycle contract.

## Current Linux product ledger

| Area | Implementation | Reachability | Qualification | Support now | Graduation evidence |
|---|---|---|---|---|---|
| VZ ARM64 ISO/UEFI install and boot | Present | Product | Developer | Unqualified | Exact distro install/update/reboot/recovery matrix |
| VZ 2D desktop | Present | Product | Developer | Unqualified | Scaling, full-screen, input, long-duration frame correctness |
| VZ same-host saved state | Present | Product UI overbroad | Developer | Unqualified | UI gating, exact host tuple, sleep/device churn, disk/NVRAM binding |
| RawHV durable hardware topology | Present: schema-5 plan authority, stable logical IDs/reconciliation, sparse launch attachment, deterministic ARM/x86 surfaces, canonical fingerprint | Product resolved path | Developer tests | Unqualified | Preserve ABI/migration goldens and qualify exact candidates/device combinations |
| RawHV managed direct boot | Present: canonical schema-v4 authority fixes admitted memory, vCPU count, scheduling-policy revision, one system-disk queue per admitted vCPU, read-write FD 3 system disk, read-only FD 4 kernel, and optional read-only FD 5 initrd; one trusted-root machine-directory lease supplies fixed leaves and private staging, with post-admission/pre-spawn generation revalidation; boot blobs carry exact bounded byte counts and SHA-256 | Product resolved path | Developer tests | Unqualified | Atomic boot-artifact update contract, remaining resource brokers, physical scheduling/multiqueue/durability campaigns, crash/data gates, and exact-candidate qualification |
| RawHV generic installed Linux | Absent: no firmware/NVRAM and no installed-disk EFI execution; the verified kernel/initrd bundle remains host-side direct boot | None | None | Unavailable | UEFI, persistent NVRAM, storage ABI, arbitrary distro/update evidence |
| RawHV VirGL OpenGL | Present in the dual signed worker: exact capset 2, classic 3D command lane, ANGLE Metal libraries inventoried inside the XPC, shared-texture scanout, producer fences, and device-loss fail-stop. Activation requires a candidate-bound real-bootstrap receipt and fresh live equality | Product resolved hardware-3D path | Developer tests | Unqualified | Exact release signature plus physical direct-rendering VirGL identity, mapped sustained GL workload, compositor/apps, resize/reset/device-loss and multi-distro evidence |
| RawHV Venus Vulkan | Present in the same dual signed worker: exact capset 4, GNU-libc-compatible Mesa Vulkan 1.3 pack, descriptor-backed Metal scanout, sync-fd/fence contracts, XCB surface and swapchain probes. Activation shares the same real-bootstrap receipt and live equality gate | Product resolved hardware-3D path | Developer tests | Unqualified | Exact release signature plus physical Venus ICD identity, surface/swapchain/presentation, sustained native Zed, recovery/integrity and exact guest/kernel cells |
| RawHV multi-display | Present in source | Internal/product experiment | None | Unqualified | Stable IDs, Retina/full-screen/resize/reorder/reconnect matrix |
| CPU display fallback | Present; generation-aware lifetime/release plus zero-copy ordinary mailbox drain, sparse backlog cells, process-wide byte authority, and exact received/copy/upload/drop/pending telemetry projected through the daemon schema. Producer-side 2D extraction still copies the complete backing before damage | Internal | Developer: 25 focused mailbox/telemetry tests, seeded overlap/hole property, runner build | Unqualified | Make producer extraction damage-proportional, then pass reset/quiesce, fragmented damage, bounded backlog, FPS/latency/CPU and physical display matrix |
| Audio output/input | Partial | Product | None | Unqualified | Typed profiles, permission UX, latency/churn/recovery matrix |
| Clipboard | Present with tools | Product | None | Unqualified | Protocol/version/size/MIME/security/restart matrix |
| RawHV vsock/control bridges | Partial: three host-Unix endpoints share owned one-shot listeners with 16-session admission and bounded stop; core packet/credit budgets and guest-triggered SSH/AI services remain open | Product/internal | Developer | Unqualified | Exact VirtIO packet/CID/type/credit tests, aggregate budgets, capacity-aware callers, unregister/reset/drain, fuzz and sustained guest workloads |
| Shares | Present; launch authority remains pathname-based | Product | Developer | Unqualified | Brokered directory handles plus ownership/case/TOCTOU/live-mutation/recovery tests |
| NAT/forwarding | Present through gvproxy; launch/control authority remains CLI/path/socket-based | Product | Developer | Unqualified | Brokered handles plus VPN/Wi-Fi/sleep/port collision/gvproxy crash matrix |
| Host-only/offline | Present/dirty gvproxy work | Product | Developer | Unqualified | Exact component provenance and connectivity/isolation evidence |
| Bridged networking | Restricted/partial | Not normal product | None | Unavailable | Entitlement approval, honest semantics, physical network matrix |
| Synthetic removable storage | Backend-dependent | Partial | None | Unqualified | Stable identity, attach/detach/restore/recovery evidence |
| RawHV physical USB/IP | Partial; bounded Phase 0 has exact decoding, 4 MiB/request, 8 requests and 16 MiB in flight per device, 8 bridge connections, finite host-I/O watchdogs, and bounded detach; no isochronous | Partial/tools-only | None | Unqualified | Daemon broker/compensation, asynchronous same-stream UNLINK, reset/unplug/class evidence, and retained physical-device qualification |
| VZ physical USB | Beta API only; current beta notes include save failure and detach/restore crash cases | None | None | Unavailable | Final macOS 27 API/entitlement/consent, deterministic saved-state rejection, and physical device matrix |
| Cold snapshot/clone/export/import | Partial | Product | Developer | Unqualified | Full disk/NVRAM/ABI manifests, interruption and cross-host tests |
| Guest-quiesced snapshot | Partial/tools-dependent | Product | None | Unqualified | Requested/effective semantics, one journal, thaw/restart recovery |
| Support bundle/flight recorder | Partial | Product/internal | Developer | Unqualified | Normalized schema, bounds, path safety, privacy/redaction tests |

## Exact qualification key

Durable launch authority is now distinct from qualification evidence. Current resolved-plan
repository wrapper schema 3 requires exact compact canonical JSON, authenticates the canonical
nested schema-5 plan, and rejects reordered, alternate lexical, or unknown record/plan fields.
Historical integrity wrapper schema 2 authenticates plan schemas 2 through 4 but returns them only
as `requiresReplanning`; contradictory stored migration provenance is rejected. Wrapper schema 1 is
unauthenticated and also replan-only. These properties protect plan authority, but do not qualify a
backend, guest image, GPU path, USB device, or release candidate.

Resolved RawHV launch-envelope schema 4 likewise establishes exact launch authority rather than a
support claim. It fixes admitted memory, vCPU, scheduling-policy revision, and system-disk
multiqueue topology plus ordered FD
3/4/5 disk/kernel/initrd roles, access modes, positive bounded sizes, boot-blob digests, topology
disk identity, and direct-boot profile consistency. The resolved helper rejects split CPU/memory
flags and materializes the exact queue count from the envelope. Disk and boot
admission now starts from the selected drive's exact broker-owned trusted root and uses one pinned
machine-directory generation. Shares, gvproxy, saved state, snapshots, and lifecycle/control
sockets remain path or CLI authority, and expensive boot admission still runs under a broad manager
lock. RawHV still has no firmware/NVRAM, its direct GPU path remains fail-closed, and its USB/IP
endpoint remains Dory-Tools/VHCI-only rather than native xHCI.

Every retained record is addressed by a canonical digest over at least:

- Dory version/build/source commit and signed app-tree digest;
- macOS version/build, Mac model/SoC/GPU, memory class, and provisioned entitlements;
- backend binary digest, backend API maturity, and virtual-hardware ABI fingerprint;
- firmware/NVRAM policy, disk controller/format, NIC and complete device topology;
- guest distribution/image digest, architecture, kernel, Mesa, compositor, and Dory Tools version;
- exact dual VirGL2/Venus virglrenderer source partition, patches and fail-closed build flags;
  static MoltenVK inputs plus the XPC-local ANGLE Metal pair; absence of an unreviewed dynamic host
  renderer graph; final worker/runner/app Code
  Directory identities; Mesa/kernel UAPI, generated protocol, guest loader closure, and worker
  profile as one indivisible tuple;
- physical USB identity/class and transfer types when requested;
- lifecycle/snapshot requirements and test-suite/methodology version.

Evidence has issuance, expiry, revocation, and supersession metadata. A newer component, host OS,
guest kernel, renderer, or topology does not inherit an older record automatically.
Every Linux support claim remains keyed to an exact qualified native-ARM64 ISO or managed-media
cell. Evidence from one distro, media digest, guest kernel, or host candidate never projects to
another cell merely because it also identifies as ARM64 Linux.

## Required test groups

| Group | Minimum retained evidence |
|---|---|
| Contract/migration | exact canonical bytes/digests, strict current-authority unknown-field rejection, authenticated legacy replan fixtures, contradictory-provenance and downgrade rejection, append-only hardware-ABI golden files |
| Security/parser | fuzz corpus, checked bounds, sanitizer runs, resource ceilings, vsock credit/RX-starvation and session admission, reset/cancel concurrency, malformed guest/control input |
| Provision/recovery | crash injection at every phase, orphan cleanup, disk-full, port/claim/bookmark compensation, concurrent workspaces |
| Boot/update | clean install, kernel/bootloader update, restart, forced stop, host reboot, migration and repair |
| GPU/display | renderer/API identity, no software substitution, real GL/Vulkan workloads, frame pacing, resize/Retina/full-screen/multi-display, fence/device loss |
| Storage | fsync/power loss, range rejection, discard/zeroes/cache policy, resize, snapshot/clone/export/import integrity |
| Network | NAT/host-only/offline, forwarding collisions, DNS, VPN, Wi-Fi changes, sleep/wake, gvproxy crash |
| Input/audio | keyboard layouts, absolute/relative pointer, cursor, microphone consent, latency, device churn and recovery |
| Sharing/integration | permissions, case behavior, TOCTOU/volume replacement, clipboard limits/types, tools update/rollback, missing-tools degradation |
| USB | authorization/claim/release, attach/detach/reset/unplug, helper/daemon crash, deadlines, representative classes and transfer types |
| Lifecycle | graceful/forced stop, pause, host sleep, saved-state compatibility, cold/quiesced snapshot semantics and rejection paths |
| Release | signed app/components, SBOM, qualification binding, schema-2 catalog, notarization, clean-machine install/update/rollback |

The RawHV USB/IP limits above are security invariants, not a passthrough support claim. Guest frames
are decoded exactly, oversized and isochronous submissions fail before payload allocation or host
I/O, and an UNLINK may abort only its session-owned sequence when that request is the sole active
operation on the physical pipe; a shared pipe returns `EBUSY`. Detach and deinitialization use
bounded abort/drain watchdogs. The current synchronous bridge cannot consume a same-stream UNLINK
while its SUBMIT is blocked, so precise timely cancellation still requires an asynchronous
reader/executor/reply design. The guest endpoint remains Linux VHCI reached through USB/IP and Dory
Tools, not a native virtual xHCI controller.

## Release projection rule

The UI displays the resolver's exact result:

- **Supported:** complete exact-candidate evidence and no active exclusion;
- **Preview:** candidate evidence exists, but a displayed bounded exclusion remains;
- **Unqualified:** implementation may exist, but exact release evidence is missing;
- **Unavailable:** the selected host/backend cannot provide the capability.

The UI never turns “source exists,” a local probe, or a fallback backend into Supported. Unknown
custom EFI media remains Unqualified until its exact architecture and backend combination is proven.
