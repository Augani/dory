# Dory-owned Linux and macOS virtualization: complete delivery plan

- **Status:** Proposed quality-first implementation charter; implementation requires phase approval
- **Date:** 2026-08-30
- **Owners:** Dory virtualization, compiler/runtime, firmware, devices, desktop, security,
  release, legal, and quality teams
- **Only product host:** Apple-silicon Mac
- **Guests:** ARM64 Linux, x86_64 Linux, ARM64 macOS, and x86_64 macOS
- **Intel-host policy:** Unavailable; fail before component download, media mutation, or VM creation
- **Parent architecture:**
  [`virtual-workspace-platform.md`](virtual-workspace-platform.md), especially Milestone 5; this
  plan supersedes conflicting Linux/macOS runtime selections
- **Performance contract:**
  [`linux-vm-performance-contract.md`](linux-vm-performance-contract.md), whose measurement method
  is generalized here while conflicting future-runtime choices are superseded
- **Prior evidence:**
  [`linux-and-macos-virtualization-evidence-2026-08-29.md`](linux-and-macos-virtualization-evidence-2026-08-29.md)

## 1. Executive decision

Dory will build its virtualization product around Dory-owned execution, machine, firmware,
device, media, lifecycle, and qualification contracts.

> **Dory will not ship, invoke, link, or persist a dependency on QEMU. Linux runs on DoryHV;
> architecture mismatch runs through DoryDBT; native ARM64 macOS uses Apple's supported VZMac
> path; x86_64 macOS uses a Dory-owned Intel Mac machine model over DoryDBT. The complete feature
> is available only on Apple-silicon Macs.**

This is not the shortest path. It is the path that gives Dory control over latency, resource
accounting, compatibility, security boundaries, diagnostics, release cadence, and long-term
product identity.

The commitment has two honest performance classes:

1. **Native-ISA guests must feel effectively native.** The cost of the VM should be difficult to
   notice in ordinary development, desktop, storage, networking, and interactive workloads.
2. **Cross-ISA guests target category-leading translated quality.** They must feel responsive and
   useful, with Phase 0 naming the comparison products, physical references, and workloads. The
   product must never claim that arbitrary translated computation is indistinguishable from native
   execution. Translation has unavoidable costs.

Quality outranks schedule. Missing a release gate changes the date, staffing, or exposed support
matrix. It does not lower correctness, security, performance, or compatibility thresholds.

## 2. Product promise

The program objective—and the definition of complete—is all four requested guest targets on
Apple-silicon Macs:

| Guest on Apple silicon | Execution engine | Machine/platform | Product intent |
|---|---|---|---|
| ARM64 Linux | `DoryNativeHVArm64` | `DoryARMVirt-v1` | Target: supported; near-native |
| x86_64 Linux | `DoryDBTX86ToARM64` | `DoryPC-v1` | Committed; translated |
| ARM64 macOS | `DoryVZMacAdapter` | Apple Mac platform artifacts persisted by Dory | Target: supported; near-native |
| x86_64 macOS | `DoryDBTX86ToARM64` | `DoryIntelMac-v1` | Committed destination; gate-controlled |

“Committed destination” means the architecture and work program remain in this plan. A public
version, date, or compatibility claim is earned only after legal, firmware, CPU, device,
stability, update, and performance gates pass.

x86_64 macOS is a **legacy guest line**, not a route to future macOS releases. Apple states that
macOS Tahoe 26 is the final macOS release for Intel Macs. Dory may therefore qualify only lawful,
exact Intel-capable releases—Tahoe 26 or earlier—and only while their update and security posture
meets Dory's release policy. No later macOS release is promised for the x86_64 guest cell.
Because this program's schedule may outlive the usable servicing window, Phase 0A must decide
temporal viability before Mac-specific platform investment rather than assuming a candidate will
still be supportable years later.

No cell is called supported while it feels like a remote console wrapped around a VM. Keyboard,
mouse, trackpad, speakers, microphone, camera, USB, clipboard, sharing, display resizing,
selection of any connected physical screen, and a functionally dedicated physical-display mode are
part of product completion, not optional polish. Independent multi-guest-display topology is also
mandatory for Dory-owned machine paths. Native ARM64 macOS advertises it only if a future final
public Apple VZMac path lifts the current one-display limit; splitting or mirroring one framebuffer
never counts as independent guest displays.

### 2.1 Apple-silicon-only host boundary

This feature has no Intel-host support tier, preview, hidden fallback, or future compatibility
promise. On an Intel Mac, the resolver returns `unsupportedHostArchitecture` before it downloads a
runtime component, creates a workspace, converts media, allocates a disk, or launches a runner.

The desktop, CLI, agent API, component catalog, documentation, and support matrix all expose the
same boundary. Existing x86 Hypervisor.framework code may be retained only in an internal test
harness for architectural and machine-model comparison. It is not linked into the public runtime,
advertised as a capability, or accepted by production launch resolution.

This boundary deliberately removes all ARM-to-x86 translation and Apple-silicon Mac emulation on
Intel from the program. “Both architectures” means both guest architectures on an Apple-silicon
host.

### 2.2 What Dory-owned means

Dory owns and versions:

- VM definitions, launch resolution, operations, recovery, and diagnostics;
- the ARM64 native execution adapter over Hypervisor.framework;
- x86_64-to-ARM64 full-system translation;
- architectural CPU profiles and snapshot state;
- ARM virtual, PC, and Intel Mac machine models;
- reusable device cores and transports;
- Dory-specific firmware platforms and reproducible firmware builds;
- disk/image inspection, conversion, sparse allocation, verification, and repair;
- display, input, audio, clipboard, file sharing, networking, and guest-agent protocols;
- compatibility data, performance evidence, release receipts, and rollback.

Dory cannot and must not claim ownership of Apple silicon, private Apple platform internals,
Apple-signed firmware, macOS, or the Mac platform supplied by Virtualization.framework. Native
ARM64 macOS deliberately uses Apple's public, supported platform while Dory owns the product
around it.

### 2.3 Image-led product and distribution boundary

The user-facing model is guest- and media-led:

> **Choose Linux or macOS, choose ARM64 or x86_64, provide lawful compatible media, and let Dory
> resolve an explicit qualified platform.**

Distributions and OS versions are compatibility facts and optional templates, not hidden engine
dependencies. Dory must inspect the actual image, explain the resolved architecture and support
tier before mutation, and never route based only on a filename or template label.

Large translators, firmware sets, guest drivers, symbol packages, and research paths remain
independently signed optional components. The base application does not silently download them,
does not include installation media, and remains useful for already-installed native capabilities.
Component absence produces a precise install choice; it never changes the requested guest or
engine behind the user's back.

## 3. Non-negotiable architectural rules

1. **No QEMU production dependency.** No executable, library, source-derived translator,
   control protocol, disk utility, machine version, process, or runtime manifest entry.
2. **No silent backend substitution.** A requested architecture and support tier resolve to one
   explicit launch composition or a precise error.
3. **Engine and machine are independent.** An execution engine runs CPUs; a machine model supplies
   firmware, interrupts, buses, devices, clocks, reset, and power behavior.
4. **One machine ABI across translation tiers.** `DoryPC-v1` must behave the same under the
   interpreter, baseline JIT, and optimizing JIT.
5. **Architectural state is durable; translated code is disposable.** Snapshots never persist host
   JIT code.
6. **Compatibility is versioned.** CPU, machine, firmware, device, snapshot, guest-agent, and
   migration ABIs have separate versions.
7. **Fast paths do not bypass truth or safety.** Performance work preserves exact exceptions,
   memory ordering, cancellation, bounds checks, lifecycle semantics, and diagnostics.
8. **Media is never guessed from a filename.** Dory inspects, verifies, fingerprints, and records
   the exact boot artifact.
9. **macOS assets are not redistributed.** IPSWs, installers, ROMs, protected identities, keys,
   and Apple firmware stay under their applicable licenses and provenance rules.
10. **A boot screen is not support.** Installation, reboot, update, recovery, devices, workload
    stability, sleep/wake where applicable, snapshot, clone, and rollback all qualify separately.
11. **Natural device behavior is mandatory.** Every core human-facing device class in section 12
    must work across every supported guest cell with native Mac permission, hot-plug, routing,
    display, and recovery behavior.

An isolated developer may compare behavior against an external black-box implementation during
research. Such a tool is not installed by Dory, is not a primary design source, is not required by
CI, and cannot become a release dependency. Architecture and platform specifications remain the
normative sources.

## 4. Support vocabulary and gates

Every host/guest cell has exactly one public state:

| State | Meaning |
|---|---|
| `research` | Feasibility work only; no compatibility or delivery promise |
| `experimental` | Opt-in; known gaps; no durable-workload guarantee |
| `preview` | Install and common workloads work; migrations may still be constrained |
| `supported` | Full release gates, documented matrix, rollback, and support policy pass |
| `deprecated` | Still serviced for a stated interval; no new feature promise |
| `unsupported` | Resolver rejects launch with a stable reason code |

A path advances only when all relevant gates pass:

- **G0 — Legal and provenance:** lawful media/firmware path, clean-room boundaries, licenses,
  entitlements, signing, and distribution approved.
- **G1 — Architectural correctness:** ISA semantics, exceptions, ordering, privileged state, and
  deterministic reference suites pass.
- **G2 — Boot and install:** supported media installs from zero state and reboots into its disk.
- **G3 — Device completeness:** storage, network, time, entropy, power, keyboard, mouse, trackpad,
  speakers, microphone, camera, USB, display resize, physical-screen selection/assignment,
  clipboard, sharing, and required platform devices pass the section 12 contract. Independent
  multi-display topology also passes for Dory-owned machine paths and any VZMac release that claims
  it.
- **G4 — Lifecycle:** stop, force-stop, pause, resume, recovery, update, clone, snapshot, and rollback
  preserve the defined contract.
- **G5 — Performance:** the tier-specific budgets in section 7 pass on physical release machines.
- **G6 — Reliability:** long-duration, resource pressure, repeated-cycle, and fault-injection suites
  pass without corruption or orphaned resources.
- **G7 — Security:** hostile-guest, parser, JIT, device, image, entitlement, sandbox, and update
  reviews pass.
- **G8 — Operability:** structured diagnostics, support bundles, stable errors, compatibility
  receipts, and deterministic cleanup pass.
- **G9 — Desktop experience:** the complete create-to-running, device, display, snapshot/backup,
  recovery, and diagnostics journeys pass with native Mac behavior, restart-safe state, window
  restoration, accessibility, localization, and an always-reachable input/display escape path.

No phase can waive a gate merely because later work might fix it.

## 5. Current Dory foundation

Dory is not starting from an empty repository. The current DoryHV code already includes valuable
native foundations:

- a production ARM64 Hypervisor.framework path and an existing x86 path usable as internal
  reference evidence only;
- ARM64 direct-kernel boot with a stable physical layout, FDT, GICv3, SMP, RTC, serial, and
  VirtIO-MMIO;
- an early x86 PVH/direct-kernel path that must never make Intel hosts product-eligible;
- VirtIO block, network, vsock, entropy, balloon, GPU, filesystem, input, and sound work;
- renderer, network, share, host-integration, and operation infrastructure;
- a VZ-based implementation that provides useful EFI/ISO and native Mac lifecycle evidence.

The important gaps are also explicit:

- generic Dory-owned ARM UEFI installation and persistent NVRAM;
- a complete x86 PC model with UEFI, ACPI, APIC/IOAPIC, timers, PCIe, USB, SMP, and installed-disk
  boot;
- ISA interpreters, intermediate representation, JIT backends, code caches, invalidation, and
  precise translated exceptions;
- an Intel Mac model and its platform/identity devices;
- durable architectural snapshots and migration compatibility;
- Dory-owned safe disk tooling and firmware provenance;
- release-grade performance, security, differential, fuzz, and physical-device qualification.

### 5.1 Immediate schema debt

Before a schema containing QEMU-specific backend, accelerator, or machine identities becomes
durable, Dory must replace those identities with the compositional contracts in this plan.
Existing values may remain only in an explicitly versioned legacy decoder long enough to produce a
safe migration or a clear unsupported error. New definitions must never write them.

The contract migration must occur before broad feature work because persisted product identity is
hard to remove later.

### 5.2 Existing QEMU-shaped surface and disposition

The no-QEMU decision is prospective architecture plus explicit migration work; it is not a claim
that the current tree has no such surface. Phase 0B must inventory it by behavior, not blindly
delete strings.

| Current surface | Required disposition |
|---|---|
| Backend/capability/schema/planner/UI values such as `qemu-hvf` | Stop new writes; migrate or reject legacy values; replace with Dory engine/machine identities |
| Experimental QEMU Windows component and documentation | Keep disabled, then remove; Windows needs a separate Dory-owned charter if it returns |
| Guest binfmt registration for QEMU user-mode helpers | Never use it to satisfy a whole-guest target; replace or retire under a separate application-translation decision |
| gvproxy's named QEMU frame/port adapter | It is a protocol compatibility fact, not a VMM dependency; replace it with a Dory-owned framed network path before strict product-wide independence is declared |
| ARM layout/device comments and upstream comparisons | Retain when they document interoperability or evidence; they do not select or ship a runtime |
| Benchmarks mentioning external implementations | Retain only as labeled comparative evidence; release tests must not require them |
| Public/supporting docs that prescribe a QEMU future | Update to this architecture and mark historical documents as non-normative |

Repository and artifact gates distinguish factual text from dependencies. Source comments may say
where an interoperable convention came from. A build fails when production code links, invokes,
downloads, persists, requires, or negotiates the prohibited runtime/control surface.

Where an older Dory document prescribes a QEMU runtime for Linux or macOS, this plan supersedes that
choice. The older document remains useful only for current-state evidence until Phase 0B aligns it.

## 6. Target architecture

Launch resolution is a composition, not a backend name:

```text
guest intent + inspected media + host facts + support policy
                              |
                              v
 execution engine + CPU profile + machine model + firmware
                 + device ABI + media chain + qualification receipt
```

The control plane resolves and records every element. The runner receives an immutable,
fully-resolved launch description and cannot choose a different route.

### 6.1 Module boundaries

| Module | Responsibility |
|---|---|
| `DoryExecutionContracts` | Architectural CPU state, exits, interrupts, clocks, memory, cancellation, snapshots |
| `DoryNativeHVArm64` | ARM64 Hypervisor.framework vCPU execution only |
| `DoryDBTCore` | IR, interpreter coordination, dispatcher, code cache, invalidation, precise faults |
| `DoryDBTX86` | x86 decode, semantics, paging, privilege, CPU profiles |
| `DoryDBTCodegenARM64` | Baseline and optimizing ARM64 host code generation |
| `DoryMachineARMVirt` | `DoryARMVirt-v1`, FDT/ACPI policy, GIC, PCIe/MMIO, reset, UEFI |
| `DoryMachinePC` | `DoryPC-v1`, ACPI, APIC/IOAPIC, timers, PCIe, USB, reset, UEFI |
| `DoryMachineIntelMac` | `DoryIntelMac-v1`, Mac boot policy, SMC/NVRAM/SMBIOS identity, Mac devices |
| `DoryVirtio` | Transport-neutral device cores plus MMIO and PCI transports |
| `DoryFirmware` | Dory EDK II platforms, variable stores, reproducible builds, provenance |
| `DoryDiskFormats` | Raw/sparse formats, safe inspection, conversion, verification, repair |
| `DoryVZMacAdapter` | Native Mac restore, platform identity, auxiliary storage, lifecycle |
| `DoryVMControl` | Definition resolution, operation journal, ownership, cancellation, recovery |
| `DoryVMRunner` | Isolated per-VM process, resources, event loop, sandbox, diagnostics |
| `DoryVMDevices` | Storage, network, display, input, audio, sharing, agent devices |
| `DoryHostDeviceBroker` | XPC authority, TCC/entitlements, USB leases, route changes, revocation |
| `DoryDisplayCoordinator` | Guest topology, host-screen assignment, full-screen spaces, frame pacing |
| `DoryMediaBridge` | Camera and microphone capture, audio routing, conversion, A/V synchronization |
| `DoryDesktopExperience` | Native Mac VM library, create/install, runtime windows, devices, recovery, accessibility |
| `DoryVMQualification` | Conformance, compatibility, performance, release receipts |

Dependencies point inward toward small contracts. Machine and device modules do not import the
desktop application. Execution engines do not inspect workspaces or choose firmware. UI code does
not construct low-level VMs directly.

### 6.2 Process model

Each VM has one signed, isolated runner process because Hypervisor.framework supports one VM
instance per process and because per-VM failure/resource containment is a product requirement.

The controller:

- validates user intent and media;
- resolves a launch composition;
- creates an operation record and lease;
- starts the runner with least privilege;
- supervises readiness, cancellation, termination, and cleanup;
- persists only durable state and bounded diagnostics.

The runner:

- creates the native or translated CPU engine;
- instantiates the selected machine and devices;
- owns mapped guest memory and JIT memory if applicable;
- reports typed progress and health events;
- never mutates the durable definition without a controller transaction;
- exits completely when its lease is revoked.

## 7. Performance and quality contract

“Almost negligible that it is a VM” is a release criterion for native-ISA paths, not marketing
language. Dory will measure deltas against a reproducible baseline on the same physical host,
thermal state, power state, storage medium, guest build, and workload.

### 7.1 Measurement rules

- Publish host model, chip, RAM, macOS build, firmware, Dory build, guest build, CPU profile,
  machine ABI, device ABI, and sample count with every result.
- Compare native paths both to host-native work where meaningful and to a minimal correct
  Hypervisor.framework or VZ harness so Dory overhead is visible separately.
- Compare translated paths to named physical machines and to the same guest workload; never blend
  native and translated results into one headline.
- Record median, p95, p99, worst stable interval, variance, energy, temperature, memory pressure,
  and throttling. A single best run is not evidence.
- Warm and cold results remain separate. Caches, sparse allocation, and host filesystem effects are
  reported rather than hidden.
- Display tests publish resolution, scale, color format, refresh rate, number of displays, guest
  compositor, and host display topology. Audio/camera tests publish device, format, sample/frame
  rate, route, and permission state.
- Release gates run on physical low-, middle-, and high-tier supported Macs, not only CI VMs.

### 7.2 Native-path release budgets

Phase 0 establishes calibrated baselines; later phases may tighten but cannot silently loosen the
following initial budgets:

| Dimension | Supported-path budget |
|---|---|
| Dory orchestration overhead | No more than 3% median over the minimal identical HV/VZ harness |
| CPU throughput | At least 95% of the normalized native baseline at suite median; exceptions documented per workload |
| Sequential virtual storage | At least 90% of the safe host-backed baseline |
| 4 KiB random storage | At least 80% of the safe host-backed baseline with bounded p99 tail |
| NAT/virtual network throughput | At least 90% of the selected host-network baseline |
| Interactive latency | No more than 8 ms added p95 by Dory's display/input path; full p95 under 50 ms on the reference setup |
| Single display | Sustained 60 Hz at each qualified resolution with no more than 0.5% Dory-caused missed presentations in the 30-minute motion workload |
| Independent multiple displays, where the cell claims them | Two simultaneous qualified displays at 60 Hz on a capable reference Mac, independently paced and without cross-display stalls |
| Display assignment | Enter, leave, reassign, reconnect, and wake without guest reboot, lost windows, stuck capture, or more than one second of Dory-caused unresponsiveness |
| Desktop UI state propagation | User intent is acknowledged or a durable pending state is visible within 100 ms p95 when no macOS prompt or guest response is required |
| Library at scale | Useful content appears within 500 ms for the Phase 0 frozen 1,000-machine fixture; search/filter and incremental controller changes render within 100 ms p95 |
| App-shell main thread | No synchronous disk/network/runner work; no Dory-caused stall over 100 ms and p99 stall no worse than 50 ms in the 30-minute UI qualification trace |
| Window restoration | Restored desktop/display windows become correctly placed and interactive within two seconds after durable controller/display truth is available |
| Input | No stuck key/button/modifier; no duplicate natural scrolling; pointer/keyboard path stays within the interactive-latency budget |
| Audio | Zero underruns in the one-hour qualification workload; route changes recover without guest reboot; Phase 0 freezes an added-latency budget no weaker than 20 ms p95 where the host route permits |
| Camera | Sustained qualified format—target 1080p30 on the mid-tier host—with bounded frame drops and less than 40 ms p95 audio/video skew |
| USB | Attach, detach, reset, permission revoke, and reattach preserve host/guest ownership; bulk, interrupt, control, and required isochronous workloads pass |
| Idle behavior | No busy polling; bounded wakeups and less than 1.5% host CPU after the settling interval |
| Memory | No unbounded cache growth; overhead budgeted per device and code path; pressure recovery proven |
| Lifecycle | No orphan process, mount, tap/interface, lease, or lock after 10,000 start/stop fault cycles |

Where host security or data integrity conflicts with throughput, safety wins and the benchmark
records the cost.

The current VZMac API's one-display maximum does not inherit the independent-multiple-display
budget. ARM64 macOS must still meet resize, pacing, and assignment of its guest display to any
chosen physical Mac screen; Dory exposes no multi-display claim until a final public path exists.

### 7.3 Translated-path budgets

Cross-ISA quality is defined by workload classes, not an impossible universal percentage:

- desktop interaction meets the same input, display-assignment, applicable multi-display, audio,
  camera, and USB naturalness budgets; lower CPU throughput does not excuse a broken device
  experience;
- boot, login, application launch, compilation, browser, filesystem, network, and sustained compute
  have separate published baselines and minimums;
- no translated target advances beyond preview until its representative workload suite is useful
  on the lowest supported host tier;
- compatibility never silently switches from JIT to a permanently slow global interpreter;
- interpreter fallback is allowed per block for correctness and is observable in diagnostics;
- optimization regressions fail CI even when correctness tests still pass;
- energy, thermal throttling, code-cache churn, and pause latency are first-class gates.

The x86_64 macOS path does not inherit the Linux translator's support state. Its Mac platform,
drivers, update behavior, and workloads qualify independently.

### 7.4 Hot-path design rules

- Give each vCPU a dedicated run loop and avoid controller/UI hops on exits.
- Use batched event notification, interrupt coalescing, and lock-free or low-contention queues where
  correctness permits.
- Keep disk, network, display, and translation code paths copy-minimal and allocation-bounded.
- Preallocate bounded metadata and use backpressure; never trade an out-of-memory failure for a
  benchmark win.
- Separate control-path observability from hot-path logging; use counters/ring buffers and sample
  expensive events.
- Profile before optimizing. Each optimization includes a benchmark, correctness test, rollback
  switch, and architecture note.
- Never weaken flush, barrier, atomic, exception, or cancellation semantics to improve a score.

## 8. Execution-engine contracts

`DoryExecutionContracts` is deliberately smaller than a machine:

```swift
public protocol DoryCPUExecutionEngine {
    associatedtype ArchitecturalState: Codable & Sendable

    func createVCPU(id: UInt32, initialState: ArchitecturalState) throws -> DoryVCPU
    func mapMemory(_ region: DoryGuestMemoryRegion) throws
    func unmapMemory(_ range: DoryGuestAddressRange) throws
    func inject(_ interrupt: DoryArchitecturalInterrupt, into vcpu: UInt32) throws
    func run(_ vcpu: DoryVCPU, until deadline: DoryVirtualDeadline?) throws -> DoryCPUExit
    func captureState() throws -> [ArchitecturalState]
}
```

The real API may differ, but the separation is mandatory. Exits describe architectural effects;
they do not expose a framework-specific or translator-specific union to machine code.

Required contracts include:

- guest physical memory and dirty-page tracking;
- vCPU creation, topology, reset, pause, and cancellation;
- interrupt injection and acknowledgement;
- virtual monotonic/wall clocks and deterministic test clocks;
- MMIO/PIO exits and restartability;
- architectural faults with exact access metadata;
- atomic snapshot barriers;
- trace points that do not alter guest-visible ordering.

## 9. DoryHV native execution

### 9.1 ARM64 native path

The existing ARM path becomes `DoryNativeHVArm64` plus `DoryARMVirt-v1` rather than one tightly
coupled machine.

Work:

1. Extract guest-memory, vCPU, exit, clock, interrupt, and cancellation contracts.
2. Freeze the working physical layout as `DoryARMVirt-v1` with a complete ABI table.
3. Preserve direct-kernel boot as a fast, managed-image profile.
4. Add Dory UEFI, persistent variable storage, ISO boot, installed-disk boot, reboot, and firmware
   update policy.
5. Move device implementations behind transport-neutral cores and versioned MMIO/PCI transports.
6. Complete dirty-page tracking, pause barriers, save/restore, and deterministic fault handling.
7. Tune SMP, GIC delivery, timers, block, network, display, and memory pressure against section 7.
8. Make generic ARM64 Linux install media the supported path; managed distributions remain
   conveniences, never the architecture.

### 9.2 x86_64 native reference harness — non-product

The existing x86 PVH path may remain as an internal engineering harness because physical x86
execution is useful for CPU and machine-model differential tests. It is not a delivery path.

- Compile it only in internal lab configurations excluded from public component manifests.
- Do not expose it through production resolution, UI, CLI, agent APIs, templates, or support data.
- Do not spend product scope turning it into an Intel-host installer runtime.
- Use it only where it materially isolates an x86 CPU, interrupt, firmware, or device question.
- Treat all general PC functionality as `DoryMachinePC` work that must pass under DoryDBT on Apple
  silicon.
- Make the clean public build and packaging audit prove the x86 native harness is absent.

The product remains Apple-silicon-only even when an internal lab uses an Apple-branded Intel Mac as
a reference system.

## 10. DoryDBT translated execution

DoryDBT is a compiler/runtime program, not a fallback flag. It is built from specifications and
clean-room tests with its own security boundary.

### 10.1 Correctness-first executable specification

The x86_64 guest ISA begins with an interpreter that provides:

- exact architectural registers and flags;
- instruction decode and length rules;
- privilege, paging, translation lookaside, fault, and exception behavior;
- floating-point/vector state and exception policy;
- atomics, barriers, memory-order semantics, and interrupt boundaries;
- deterministic single-step, trace, and replay modes;
- differential test hooks against physical reference CPUs.

The interpreter is the executable correctness oracle for the JIT. It is not discarded when code
generation arrives.

### 10.2 Intermediate representation

The ISA-neutral IR must represent, without hidden host assumptions:

- fixed-width integer and bit operations;
- condition codes and lazy/materialized flags;
- floating-point and vector operations with explicit rounding/exceptions;
- typed loads/stores, endian conversion, atomics, fences, and ordering domains;
- guest virtual-to-physical translation and permission checks;
- precise fault points and recoverable instruction boundaries;
- privileged operations, system registers, I/O, and interrupt checks;
- helper calls with declared side effects;
- deoptimization from optimized host code back to architectural state.

Every IR optimization has equivalence/property tests. Baseline code generation ships before an
optimizing tier. Optimization is never allowed to obscure precise exceptions or self-modifying
code behavior.

### 10.3 Runtime and code cache

- Translate small blocks first, then form bounded traces/regions using measured hotness.
- Key translations by guest physical address, CPU profile, privilege, paging context, and semantic
  mode as required for correctness.
- Track executable guest pages and invalidate translations on relevant writes, remaps, TLB events,
  breakpoint changes, and snapshot restore.
- Create exactly one `MAP_JIT` region in the translator runner and suballocate it; do not create a
  mapping for each block.
- Enforce strict write-xor-execute transitions, guard pages, quotas, generation counters, and
  deterministic eviction.
- Publish generated ARM64 instructions only after the required host instruction-cache invalidation
  (`sys_icache_invalidate`) and a release-ordered state transition makes the block executable.
- Published blocks are immutable. Invalidation removes lookup visibility first; epoch/hazard or an
  equivalent quiescence protocol proves that no vCPU can execute the old generation before its
  code-cache slot is rewritten, evicted, or reused.
- Never load guest-provided native code directly into the host process.
- Never serialize generated host instructions into a portable snapshot.
- Make exits, helper calls, cache misses, invalidations, interpreter fallbacks, and compilation
  time measurable without high-volume logging.

The translator runner uses the hardened runtime and only the narrow JIT entitlement required by
Apple's platform. It must not depend on disabling library validation or accepting unsigned
executable memory.

Phase 0 must also validate the current `com.apple.security.cs.jit-write-allowlist`,
`pthread_jit_write_with_callback_np`, and instruction-cache publication contract for the minimum
host OS. Where Dory adopts the allowlist API, callbacks are compiled into the signed executable,
fixed before untrusted guest input, narrowly scoped, and validate attacker-controlled context
before emitting instructions.

### 10.4 x86_64 guest to ARM64 host

This is the first translated direction because it unlocks x86_64 Linux and later Intel macOS on
the primary host.

Apple's Intel-binary support inside an ARM64 Linux VM is process-level translation. Apple
explicitly does not support using it to install or boot an Intel Linux distribution, so it is not
an execution engine for this matrix and cannot replace DoryDBT.

Required CPU work includes:

- protected/long mode, segmentation edge cases, paging, TLB behavior, and precise page faults;
- CPUID and MSR profiles frozen by name and version;
- x86 condition flags, string instructions, unaligned access, and atomic read-modify-write;
- x87, MMX where required, SSE through SSE4, and staged AVX/AVX2 profiles;
- local APIC, interrupts, exceptions, debug state, and SMP startup;
- preservation of x86 total-store-order behavior on ARM's weaker memory model;
- deterministic time/counter virtualization;
- self-modifying code, cross-vCPU invalidation, and executable-page protection changes.

Delivery order:

1. userspace instruction conformance;
2. privileged interpreter and a uniprocessor direct-kernel Linux boot;
3. baseline ARM64 JIT and differential parity;
4. paging, interrupts, SMP, ordering, FP/vector, and code invalidation;
5. `DoryPC-v1` UEFI/ISO install and installed Linux;
6. optimizing tiers, device fast paths, thermal control, and product qualification;
7. Mac-specific CPU profiles only after Linux establishes translator correctness.

### 10.5 DoryDBT release gates

- ISA suites and randomized instruction generators pass against physical CPUs.
- Interpreter and JIT architectural state match at block and exception boundaries.
- Multicore litmus tests cover ordering, atomics, interrupts, TLB shootdown, and invalidation.
- Kernel build, browser, compiler, database, compression, crypto, and desktop workloads pass.
- Hostile guest code cannot escape memory/JIT/device boundaries.
- Translation cache growth and compilation latency remain within declared budgets.
- Stress tests prove that invalidation removes lookup visibility before any published block is
  reclaimed and that epoch/hazard quiescence prevents code-cache slot reuse while any vCPU can
  still execute the prior generation.
- Optimizer miscompilation has deterministic capture, replay, bisect, and per-feature rollback.
- Every advertised CPU feature has tests; unimplemented features are absent from CPUID/system
  registers rather than trapped unpredictably.

## 11. Machine, firmware, and device ABIs

### 11.1 ABI identity

Every launch records identities similar to:

```text
execution.engine = dory.native-hv.arm64@1
cpu.profile       = dory.arm64.generic-v1
machine.model     = dory.armvirt@1
firmware.abi      = dory.edk2.armvirt@1
device.abi        = dory.virtio@1
snapshot.format   = dory.vmstate@1
```

Versions advance only for guest-visible changes. Implementation optimizations that preserve the
ABI do not force a new machine version. Compatibility code must remain bounded, tested, and tied to
supported migration windows.

### 11.2 `DoryARMVirt-v1`

Freeze and document:

- physical address layout and RAM constraints;
- GIC version, distributor/redistributor layout, and vCPU topology;
- timer, RTC, serial, power/reset, and entropy devices;
- PCIe ECAM/MMIO windows and VirtIO-MMIO compatibility layout;
- FDT nodes, ACPI policy if added, boot registers, and UEFI handoff;
- interrupt numbers, DMA coherency, alignment, and hot-plug rules;
- variable-store format and recovery behavior.

Existing addresses may remain compatible with common ARM virtual hardware. Compatibility does not
create a runtime dependency or external ownership of Dory's frozen ABI.

### 11.3 `DoryPC-v1`

Freeze and document:

- physical memory map, low-memory reservations, PCIe windows, and firmware regions;
- CPU topology, CPUID/MSR profile binding, reset, AP startup, APIC/IOAPIC routing;
- ACPI/SMBIOS tables, timers, RTC, power management, and reboot/shutdown;
- PCIe enumeration, BARs, MSI/MSI-X, VirtIO PCI, and selected compatibility devices;
- USB topology where required;
- UEFI variables, boot order, optical/removable behavior, and recovery.

The model is identical under the x86 interpreter, baseline ARM64 JIT, and optimizing ARM64 JIT.
An internal native-x86 reference harness may verify behavior but is not part of the product ABI or
support matrix.

### 11.4 Dory firmware

Dory will maintain narrowly scoped EDK II platform ports for its own machine ABIs. It may use
upstream EDK II under its license, but it will not adopt a firmware binary or platform port that
assumes another VMM's private machine contract.

Firmware requirements:

- reproducible, pinned-source builds with SBOM and provenance;
- Dory-owned platform descriptions and build configuration;
- measured size, startup, NVRAM, boot order, recovery, and capsule/update policy;
- per-VM variable stores with atomic writes, backup, schema, and repair;
- Secure Boot UI and key ownership that never invents or redistributes Apple secrets;
- compatibility tests across every supported installer and installed-OS update.

## 12. Reusable device architecture

Device cores are independent from transport and execution engine:

```text
guest driver -> MMIO or PCI transport -> device core -> bounded host service
```

The same block semantics, for example, must be usable through VirtIO-MMIO on ARM and VirtIO PCI on
the PC model.

### 12.1 Baseline device matrix

| Capability | ARM Linux | x86 Linux | ARM macOS/VZ | x86 macOS/Dory Intel Mac |
|---|---|---|---|---|
| Boot disk | VirtIO block/NVMe as qualified | VirtIO block/NVMe as qualified | VZ storage device | Installer-compatible device, then optimized path |
| Install media | Virtual optical/removable | Virtual optical/removable | IPSW restore/recovery | Installer-compatible optical/removable path |
| Network | VirtIO net | VirtIO net | VZ network device | Compatible NIC first; optimized Dory device later |
| Display | VirtIO GPU + Metal renderer | VirtIO GPU + Metal renderer | VZ Mac graphics only | Firmware framebuffer first; PVG/accelerated path separately gated |
| Multiple displays | Multiple VirtIO GPU scanouts | Multiple VirtIO GPU scanouts | Current public VZMac API: maximum one guest display; future support separately gated | Multiple Dory Mac scanouts/guest-driver path |
| Dedicated physical display | Dory display coordinator | Dory display coordinator | One VZ guest display assignable to any chosen physical screen | Dory display coordinator |
| Input/trackpad | VirtIO input plus qualified USB HID | VirtIO input plus qualified USB HID | VZ keyboard, pointing, and Mac trackpad APIs | Installer-compatible USB HID plus optimized Dory input |
| Speakers/microphone | VirtIO sound input/output | VirtIO sound input/output | VZ audio input/output follows host default route; fixed routing separately gated | Compatible audio plus optimized Dory audio |
| Camera | Virtual UVC bridge and/or USB passthrough | Virtual UVC bridge and/or USB passthrough | Final public VZ USB passthrough if qualified; otherwise a separately qualified guest-side bridge/driver | Virtual UVC/USB plus required guest support |
| USB passthrough | Dory xHCI/host broker | Dory xHCI/host broker | Final public VZ passthrough API when qualified | Dory xHCI/host broker |
| Time/RTC | Dory platform devices | Dory PC platform devices | VZ platform | Dory Intel Mac platform devices |
| Entropy | VirtIO RNG | VirtIO RNG | VZ entropy | Qualified platform/optimized device |
| Sharing | Dory guest agent + VirtIO FS | Dory guest agent + VirtIO FS | Supported VZ/Dory integration | Dory guest agent after bootstrap |
| Clipboard | Dory guest agent | Dory guest agent | Supported Dory/VZ integration | Dory guest agent after bootstrap |

“Compatible first” means the minimum lawful device the stock installer already supports. It does
not mean copying an undocumented external machine. Optimized custom devices require signed guest
drivers, update compatibility, recovery, uninstall, and security review.

### 12.2 Device correctness rules

- Validate every descriptor, length, address, queue, feature bit, and state transition as hostile.
- Cap queue depth, outstanding bytes, file descriptors, memory mappings, and host operations.
- Define cancellation and reset at every asynchronous boundary.
- Preserve flush, discard, barrier, durability, and short-I/O semantics.
- Snapshot device state only at an explicit quiescent barrier.
- Fuzz parsers, descriptor chains, state restoration, hot-unplug, and malformed guest-agent frames.
- Make device latency histograms and queue pressure observable without logging guest data.

### 12.3 Natural device and desktop contract

Display, keyboard, mouse, trackpad, speakers, microphone, camera, USB, network, clipboard, and file
sharing are core product systems. They do not graduate as post-launch polish. A guest cell remains
preview or unavailable until every core class required for a natural desktop passes its behavioral,
permission, performance, recovery, and privacy gates.

“All devices work” means two complementary promises:

1. Dory directly supports and qualifies the standard device classes people expect from a Mac
   desktop.
2. Dory provides broad USB passthrough so vendor-specific devices can use their normal guest
   drivers where macOS permits safe capture.

It cannot honestly mean that every device ever produced is certified. The compatibility ledger
records exact vendor/product/firmware/guest-driver tuples, while unsupported host-critical or
uncapturable devices show an explicit reason instead of failing after attachment.

Guest-visible custom devices and drivers are versioned, independently signed components with
update, rollback, recovery, and uninstall tests. A software path is acceptable only when it meets
the declared feature and performance contract; Metal presentation alone is never mislabeled as
guest GPU acceleration.

Every supported cell lets the user move its desktop to any connected physical screen and reserve
that screen in Dedicated Display mode. Independent multiple guest displays are a separate
capability: mandatory for the Dory-owned ARM/PC/Intel-Mac machine paths, but not claimed for VZMac
while Apple's public Mac graphics configuration permits only one display.

### 12.4 Display topology and dedicated-display mode

Dory treats guest displays, host windows, and physical screens as separate objects joined by a
durable assignment:

```text
guest display/scanout -> Dory presentation surface -> selected physical Mac display
```

Required on every supported guest cell:

- one resizable guest desktop in a normal Mac window;
- native full screen on a chosen physical display;
- **Dedicated Display**, where one chosen Mac display becomes functionally Dory Desktop: no Dory
  chrome, one guest display fills it, input follows it naturally, and the host has a documented
  emergency release gesture;
- move and reassign that guest desktop among any available physical screens without a guest reboot.

Additionally required for the Dory-owned machine paths and any future VZMac release that claims
independent multiple displays:

- one guest display per independent window;
- a dedicated display set, where two or more chosen physical displays map one-to-one to guest
  displays while unselected screens remain normal macOS desktops;
- an optional spanning mode only after mixed scale, orientation, and refresh behavior qualifies.

The host compositor and macOS safety controls still exist; Dory must not call this raw GPU or
kernel-exclusive display ownership. From the user's perspective, however, the selected display is
reserved for Dory Desktop until they release or reassign it.

The display coordinator must:

- identify physical displays by stable system identity and persist the requested mapping, while
  falling back safely if a screen is absent or its identity changes;
- support internal/external displays, mixed Retina scale, resolution, rotation, refresh rate,
  color space, HDR only where qualified, clamshell mode, and different screen origins;
- negotiate guest resolution/DPI from actual backing pixels rather than window points;
- add, remove, resize, reorder, and reassign displays without guest reboot wherever the public or
  Dory device ABI supports it, and surface a precise restart requirement otherwise;
- maintain independent frame pacing and backpressure per display so one slow screen cannot stall
  the others;
- preserve assignment through host sleep/wake, display power cycling, cable/dock changes, Spaces,
  Mission Control, and app relaunch;
- never strand a black full-screen window, hidden confirmation dialog, lost pointer, or inaccessible
  VM when a display disappears;
- restore the host's presentation options, cursor state, and window placement exactly on exit or
  crash.

The current public `VZMacGraphicsDeviceConfiguration.displays` contract permits a maximum of one
display. Dory can present that guest display on any chosen physical Mac screen, including Dedicated
Display, but cannot truthfully expose an independent multi-monitor guest topology. That capability
stays blocked/research until a future final public Apple API supports it; duplicating, cropping, or
splitting the one framebuffer does not qualify. Dory-owned Linux paths use multiple VirtIO GPU
scanouts. `DoryIntelMac-v1` requires a multi-scanout display device and guest support before x86_64
macOS is called desktop-complete.

Every cell is qualified with its guest display moved among one-, two-, and three-physical-screen
host topologies, including mixed DPI/refresh/orientation, dock reconnect, clamshell, sleep/wake,
full-screen transition, reassignment, and runner crash. Independent two-guest-display cases apply
only to cells that claim that capability.

### 12.5 Keyboard, pointer, and trackpad behavior

- Forward physical key identity and text/IME composition through separate paths so layouts,
  dead keys, Unicode input, shortcuts, and compose sequences remain correct.
- Preserve left/right modifiers, function/media keys, key repeat, caps state, and release events.
- Define host-reserved shortcuts and one always-available escape/capture-release chord.
- Support absolute and relative pointer modes, pointer lock, confinement, acceleration policy,
  high-resolution scrolling, buttons, pressure where available, and cursor-shape updates.
- Apply natural-scroll inversion exactly once. Preserve trackpad gesture phases, momentum,
  cancellation, magnify, rotate, swipe, and secondary-click semantics where the guest path can
  represent them.
- On focus loss, permission change, screen reassignment, pause, sleep, runner crash, or disconnect,
  synthesize safe releases so no key, button, touch, or modifier remains stuck.
- Meet VoiceOver, keyboard navigation, reduced-motion, contrast, and accessible escape-path
  requirements in both windowed and Dedicated Display modes.

### 12.6 USB ownership and passthrough

`DoryHostDeviceBroker` owns enumeration and attachment authority. The VM runner receives only a
bounded capability for the selected device, never ambient IOKit or USB access.

- Require explicit user selection and an exclusive per-device lease; at most one VM owns a device.
- Identify devices by stable topology plus descriptor identity and handle re-enumeration without
  attaching a different device silently.
- Support control, bulk, interrupt, and required isochronous transfers, reset, suspend, wake,
  cancellation, hot-plug, surprise removal, and host-controller error recovery.
- Validate descriptors and cap transfer sizes, queue depth, timeouts, bandwidth, and outstanding
  host memory.
- Refuse internal keyboards/trackpads, the boot/system disk, host security devices, and other
  host-critical hardware unless a separately reviewed safe policy exists.
- For USB storage, unmount/eject host filesystems before capture and require guest detach before
  host remount; never expose one writable filesystem to host and guest concurrently.
- Treat cameras, audio interfaces, smart cards, security keys, serial adapters, game controllers,
  storage, and common developer hardware as distinct qualification families.
- Do not hijack the Mac's internal Bluetooth controller. Bluetooth peripherals require an explicit
  supported bridge or a qualified passed-through USB Bluetooth adapter.
- Release the lease and restore host access after normal detach, guest shutdown, permission revoke,
  runner crash, controller crash, or host wake.

For VZMac, Dory uses USB passthrough only after the relevant public API is final on the minimum host
OS and the exact device family passes attach/detach/save/restore testing. A beta API can inform
research but cannot be a supported release dependency.

The current VZ USB passthrough and AccessoryAccess surfaces are beta and use their own device,
consent, UI-process, and entitlement rules. Phase 0 must prove the exact final process/authority
split under release signing; the design must not assume that a headless USB broker can perform an
operation the public API reserves for a UI-bearing app.

### 12.7 Camera, microphone, speakers, and media routing

The media bridge makes host capture devices appear as normal guest devices: virtual UVC or a
qualified USB path for cameras, and VirtIO/platform audio input/output for microphones and
speakers. Dory-owned device paths must support device selection, default-route following, and
explicit fixed-device routing. Current VZ host-audio sources/sinks use the Mac's default input and
output; VZMac fixed-device routing is advertised only after a final public API or a lawful,
update-stable guest-side bridge proves it.

- Request camera or microphone permission just in time, before capture, and never treat denial as a
  generic VM failure.
- Include `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` plus the minimal
  `com.apple.security.device.camera` and `com.apple.security.device.audio-input` entitlements in
  only the signed process that performs capture.
- Show an unambiguous Dory indicator whenever frames or samples are forwarded and offer immediate
  mute, stop-camera, detach, and route controls from Dedicated Display mode.
- Stop and zero sensitive buffers on revoke, detach, VM stop, runner loss, and operation
  cancellation; never place pixels or samples in normal logs, traces, snapshots, or support bundles.
- Support negotiated formats, resolution, frame rate, orientation, mirroring policy, sample rate,
  channel layout, clock drift, resampling, echo policy, and A/V synchronization.
- Use bounded pools and zero/copy-minimal pipelines; apply backpressure by dropping stale camera
  frames rather than accumulating latency.
- Handle AirPods, USB audio, HDMI/display audio, aggregate devices, default-route changes, device
  disappearance, Bluetooth profile changes, and host sleep/wake without guest reboot.
- Keep microphone and speaker permissions/routes independent. A user may allow output while denying
  input.

The executable that instantiates `VZHostAudioInputStreamSource` performs microphone capture and
must itself own the usage description, entitlement, and TCC authorization. Dory cannot assume that
moving unrelated media work into a separate broker transfers this framework-owned authority.

### 12.8 Network, sharing, and clipboard naturalness

- Default networking is outbound NAT with no unsolicited inbound exposure. Port forwarding is
  explicit, conflict-checked, scoped, reversible, and reported in the launch receipt.
- DNS, DHCP, MTU, IPv4/IPv6, VPN changes, captive networks, interface handoff, wake, and host route
  changes reconcile without requiring a VM reboot.
- Shared folders define case sensitivity, symlink escape policy, xattrs, permissions, locking,
  coherence, rename, deletion, cancellation, disconnect, and cache invalidation per guest.
- Clipboard direction is independently configurable for host-to-guest and guest-to-host; payloads
  are typed, size-bounded, rate-limited, cancelable, and never logged.
- File drag/drop and transfer use the authenticated Tools channel, explicit destination authority,
  progress, conflict policy, quarantine scanning hooks, and cancellation cleanup.

### 12.9 Host permissions, isolation, and multi-VM admission

- The sandboxed app declares only the camera, audio-input, USB, client/server network, and
  user-selected-file entitlements actually used by the responsible process.
- Persistent file/share access uses security-scoped bookmarks with balanced access lifetimes;
  runners receive open descriptors or scoped capabilities, not interpolated paths.
- Camera/microphone access also requires localized Info.plist usage descriptions and current TCC
  authorization. Missing or denied permission is a first-class capability state.
- Device/media/display brokers run as narrow XPC services, authenticate peers by audit token, UID,
  signing Team ID, designated requirement, operation lease, and VM identity, and reject unexpected
  clients before decoding large payloads.
- Direct distribution and Mac App Store feasibility are evaluated separately; Dory never weakens
  sandboxing with temporary broad exceptions to make a device work.
- Admission control budgets displays, pixel rate, camera bandwidth, audio streams, USB isochronous
  bandwidth, pinned memory, file descriptors, and worker processes across concurrent VMs.
- A second VM gets a clear busy/resource decision rather than stealing a physical device or
  degrading the first VM below its support contract.

The support matrix lists individual device families and behaviors. “USB supported,” “camera
supported,” “GPU supported,” or “desktop ready” is never inferred from one working model or boot.

### 12.10 Dory Desktop UI and interaction model

Dory Desktop must feel like a native Mac workspace, not a remote-console utility. Guest content is
primary; virtualization mechanics appear when they help the user make a decision and disappear
when the machine is healthy.

#### 12.10.1 Information architecture

The desktop product has these stable surfaces:

1. **Library:** all machines, searchable by name/OS/architecture/workload, with truthful state,
   support tier, native/translated badge, last use, storage, backup health, and required attention.
   Missing components never hide a machine.
2. **Create/Import:** choose Linux or macOS, ARM64 or x86_64, workload, media/source, resources,
   required devices, translation consent, storage, networking, Tools, and backup policy. Media
   inspection and compatibility evidence appear before creation.
3. **Review Plan:** show the resolved engine, CPU profile, machine/firmware/device ABI, native versus
   translated performance class, component downloads, permissions, disk impact, unsupported items,
   and exact changes before mutation.
4. **Operation Center:** durable install/restore/import/convert/update progress with named phases,
   speed/ETA where reliable, cancellation state, first causal error, cleanup status, and
   recover/retry/delete choices.
5. **Desktop Window:** the guest display with content-first controls, connection/device health,
   window/full-screen/Dedicated Display actions, capture state, and an always-reachable escape path.
6. **Displays:** a visual map of Mac screens and guest displays for drag-to-assign, arrangement,
   resolution/scale/refresh, add/remove, mirror/span policy, and Dedicated Display sets. Controls
   are capability-gated; VZMac's current one-display maximum is shown, not worked around visually.
7. **Devices:** USB, camera, microphone, speakers, keyboard/trackpad, clipboard, sharing, and
   network routes with host/guest ownership, permission, compatibility, active-use, and attach state.
8. **Snapshots & Backups:** timeline/graph, cold/quiesced/live truth, size, parentage, retention,
   backup destination/verification, restore, clone/fork, merge, and protected deletion.
9. **Settings & Diagnostics:** CPU/memory/storage/network/devices/Tools/update policy, launch
   receipt, performance/graphics truth, bounded logs, doctor, support bundle, and scoped repair.

#### 12.10.2 Creation and first-run experience

- Start from four clear choices: ARM64 Linux, x86_64 Linux, ARM64 macOS, or legacy x86_64 macOS.
  The legacy choice shows its exact Tahoe 26-or-earlier availability and servicing window and is
  disabled with a stable explanation when no qualified build is available.
- Explain translated execution before download or disk allocation, including the measured workload
  tier and power/thermal implications; consent is explicit and durable.
- Accept drag/drop or file-panel media, then show detected OS, architecture, boot mode, size,
  digest/provenance, compatibility, and confidence. Ambiguity asks for a decision without guessing.
- Present sensible desktop/server/sandbox defaults, but keep advanced CPU, memory, disk, firmware,
  network, display, and device settings available in one reviewable plan.
- Preflight camera, microphone, USB, file/share, and display needs with plain-language reasons.
  Request TCC permission only at the moment the user enables the feature.
- Make downloads, restore, install, first reboot, Tools installation, and readiness one continuous
  operation timeline that survives closing the window or restarting Dory.
- End at the running desktop, not a generic “operation completed” toast.

#### 12.10.3 Runtime window and natural controls

- Resize continuously with sharp Retina output and stable aspect/scale policy; do not flash,
  stretch stale frames indefinitely, or block the main thread while the guest catches up.
- Auto-hide runtime chrome in full-screen/Dedicated Display while keeping a deliberate edge reveal,
  menu command, command palette, and emergency escape shortcut.
- Show native/translated, software/accelerated graphics, active camera/mic, captured input, shared
  clipboard, USB ownership, network isolation, recording/diagnostic capture, and degraded/safe mode
  truth without clutter.
- Use standard Mac menus, toolbar conventions, sheets, context menus, drag/drop, window restoration,
  Dock/Window menu behavior, notifications, and keyboard shortcuts. Destructive actions state data
  impact and never hide behind icon-only controls.
- Pause, suspend, stop, force-off, close-window, and quit are distinct. Closing a display does not
  silently power off a running VM; the chosen policy is visible and reversible.
- Permission loss, device removal, network change, runner recovery, and component update appear as
  local actionable status, not generic modal errors over the guest.

#### 12.10.4 Visual display assignment

The Displays surface mirrors the physical arrangement reported by macOS and the virtual arrangement
reported by the guest. A user can drag a guest display onto a physical screen and choose:

- window on that screen;
- native full screen;
- Dedicated Display;
- add to a multi-screen Dory Desktop set; or
- return to automatic/windowed placement.

The multi-screen-set action appears only when the resolved guest path has independently qualified
multiple displays. Every path still lets the user choose which one physical screen becomes the
full Dory Desktop.

Before taking over a screen, Dory shows the selected display name/resolution, the guest display,
escape shortcut, and a timed confirmation. If the display disappears or the user does not confirm,
Dory rolls back automatically. Controls needed to release a dedicated screen remain reachable from
another host screen, the menu bar, and the escape chord. Reconnection restores the saved mapping
only when identity and topology are unambiguous.

#### 12.10.5 Device and privacy center

- Group available, attached, busy, host-critical, permission-denied, unsupported, and disconnected
  devices with exact reasons.
- Attaching shows the target VM, whether host use will stop, required guest driver, persistence
  policy, and known qualification status.
- Camera/microphone tiles include live privacy indication, selected source/route, mute/stop,
  permission settings shortcut, and per-VM “ask every time/remember/never” policy.
- Audio output and input are separate. Route changes show transient recovery without stealing focus.
- USB detach/eject distinguishes a safe guest eject from forced detach and reports when host
  remount/use is safe.
- Multi-VM conflicts offer a deliberate detach-and-move operation; they never silently steal.

#### 12.10.6 State, architecture, and performance

SwiftUI may own the library/settings shell, with focused AppKit/Metal hosting for high-frequency
display, multi-window, full-screen, input-capture, menu, and accessibility behavior. The exact UI
framework is subordinate to these boundaries:

- views render immutable controller projections and send typed intents; they never mutate runner,
  disk, device, or operation state directly;
- each display window has an identity and coordinator, while one VM-level session owns lifecycle;
- high-rate frames/input/telemetry bypass SwiftUI observable-state churn and the main actor;
- progress/event reductions are generation- and sequence-aware, restart-safe, and testable without
  launching a VM;
- screen/device lists reconcile by stable identity and preserve user intent without retaining stale
  host objects;
- UI work never blocks vCPU, renderer, audio, camera, USB, storage, or network loops.

#### 12.10.7 Accessibility and localization

- Full keyboard navigation, VoiceOver names/values/actions, focus order, reduced motion,
  increase-contrast, differentiate-without-color, text scaling, and clear capture escape are release
  gates.
- Guest content and Dory chrome have distinguishable accessibility boundaries; screen readers can
  reach host controls without trapping input in the guest.
- Operation progress and state changes announce meaningfully without flooding.
- All strings, permission explanations, errors, shortcuts, layouts, and input assumptions support
  localization, right-to-left UI where applicable, and non-US keyboard layouts.

#### 12.10.8 UI qualification

UI tests cover every state and transition: no machines, component absent/installing/broken,
inspection ambiguity, insufficient disk, permission denied, install/cancel/retry/recover, running,
pause/suspend/stop, display hot-plug, Dedicated Display rollback, USB conflict, camera/mic active,
snapshot/backup failure, runner crash, host restart, update/rollback, unsupported host, and all four
guest cells.

Physical UI qualification includes one-, two-, and three-screen host setups where the Mac supports
them, moving a single guest display among each screen, and independent guest multi-display only for
capable cells. It also covers mixed DPI/refresh/orientation, clamshell/dock cycles, Spaces/Mission
Control, keyboard-only and VoiceOver operation, long localized strings, low motion/contrast
settings, and rapid repeated enter/leave Dedicated Display. Screenshot tests alone cannot qualify
interaction, focus, timing, permissions, or display ownership.

## 13. macOS tracks

### 13.1 Native ARM64 macOS with VZMac

Virtualization.framework is the supported route for ARM64 macOS guests on Apple silicon. Dory
retains this route because replacing Apple's private Mac platform would reduce compatibility and
legal certainty, not increase meaningful product control.

Dory owns:

- IPSW discovery/import workflow and provenance receipt;
- hardware-model compatibility validation;
- machine identifier, hardware model, auxiliary-storage lifecycle, and clone uniqueness;
- restore progress, cancellation, recovery, update, and rollback operations;
- disk/network/display/input/audio configuration exposed by public APIs;
- snapshots where the selected platform/API supports a safe contract;
- UI, diagnostics, support bundle, release qualification, and compatibility policy.

Gates include clean restore, interrupted restore recovery, Recovery boot, OS update, clone identity,
networking, display resizing, input, audio, long-duration use, host sleep/wake behavior, and every
supported host/guest OS pair.

### 13.2 Paravirtualized graphics

Apple's public ParavirtualizedGraphics framework is a candidate for Dory-owned VMM paths because it
can expose a PCI graphics device backed by Metal when the guest has compatible support. It is not
assumed to solve every path and is not a documented alternate device injected into `VZMacAdapter`.
It is research for Dory-owned machine paths, especially `DoryIntelMac-v1`.

Before adoption, Dory must prove:

- public API and entitlement availability on the minimum host OS;
- lawful, update-stable guest driver availability for the exact guest;
- compatibility with the selected native or translated machine model;
- snapshot/reset/display lifecycle behavior;
- performance, memory pressure, and hostile-command validation;
- no dependence on deprecated option-ROM packaging or redistributed protected material.

Host-side Metal presentation of a software framebuffer improves display delivery but is not guest
GPU acceleration. The UI and diagnostics must state which path is active.

### 13.3 `DoryIntelMac-v1`

The Intel Mac guest model is built for the Apple-silicon product. Bring it up under the exact x86
interpreter before enabling JIT tiers so machine/device failures remain distinguishable from
translation failures. An internal, non-shipping native-x86 harness may supply differential
evidence, but it never creates Intel-host product support.

Required workstreams:

- select and freeze lawful Tahoe 26-or-earlier x86_64 macOS candidate versions for Dory
  qualification; Apple exposes no supported x86_64-macOS-on-Apple-silicon platform route, and
  later macOS releases do not support Intel Macs;
- define the x86 CPU, CPUID, MSR, topology, timer, and interrupt profile;
- implement UEFI/boot policy, NVRAM, SMBIOS identity, SMC behavior, reset, and power management;
- implement installer-supported PCIe, storage, network, USB/input, audio, and display paths;
- create unique per-VM identity without embedding or redistributing protected Apple identities;
- support installer, Recovery, installed boot, reboot, update, clone, snapshot, and rollback;
- start with a correct software framebuffer;
- gate any accelerated Mac GPU/guest-driver program separately;
- test the exact same machine ABI under interpreter, baseline JIT, and optimizing JIT;
- optionally compare selected behavior with an internal physical/native-x86 reference harness.

Release requires legal review of the Apple software license for the intended Apple-silicon Mac
host, use case, number of instances, distribution model, and service model. Product resolution must
also enforce the Apple-silicon-only boundary independently of licensing. Dory does not bypass
Secure Boot, SMC, ROM, key, activation, or identity protections.

### 13.4 x86_64 macOS on Apple silicon

This path composes `DoryDBTX86ToARM64` with the frozen, prequalified `DoryIntelMac-v1` platform
candidate. Phase 7, not platform bring-up alone, earns product qualification.

The sequence is strict:

1. approve the requested Tahoe 26-or-earlier x86_64 macOS version, media, license, servicing
   window, and reference evidence;
2. pass its CPU profile against DoryDBT interpreter and JIT suites;
3. boot the frozen machine's firmware/recovery under the interpreter, then each JIT tier;
4. install from lawful media and reboot from the installed disk on Apple silicon;
5. qualify interrupts, time, storage, network, input, display, audio, SMP, updates, and recovery;
6. meet translated responsiveness, sustained workload, energy, and stability gates;
7. ship only the OS versions and features that actually passed.

A spinning boot indicator, login window, or successful benchmark cannot independently establish
support.

## 14. Media and Dory-owned disk tooling

Dory replaces external image utilities with `DoryDiskFormats` and small, audited format modules.

### 14.1 Required capabilities

- streaming inspection with strict size/offset/recursion limits;
- content fingerprinting, architecture and boot-catalog detection, partition/filesystem metadata,
  and confidence/evidence output;
- raw sparse disk creation, resize, allocation accounting, block maps, clone, and verification;
- selected qcow2, VMDK, and VHDX import/export only after format-specific threat models and tests;
- copy-on-write layers, atomic metadata, crash recovery, and explicit backing-chain ownership;
- ISO/UDF reading sufficient for boot/media inspection without mounting untrusted images in the
  controller process;
- resumable conversion with source immutability checks and destination transaction markers;
- structured repair that never silently discards guest data;
- fuzzing and corpus tests for every parser and converter.

Write support is earned per format. Read-only import may ship first. Unsupported or ambiguous
images produce typed guidance instead of an unsafe best guess.

### 14.2 Provenance receipt

Every imported artifact records:

- content digest and byte length;
- detected container, partitions, boot modes, and architectures;
- acquisition/source information supplied or verified by the user;
- parser and rule versions;
- signature/notarization or vendor metadata where available;
- transformations and their input/output digests;
- compatibility decisions and warnings.

The receipt excludes secrets and is safe to include in a redacted support bundle.

### 14.3 Acquisition, helper, and cache authority

Every media reference has an explicit source kind: user-selected local file, verified HTTPS
download, Apple restore-image URL, signed template artifact, existing workspace disk, or imported
Dory bundle. A source is never silently treated as a writable working disk.

Untrusted inspection and conversion run in a dedicated, unprivileged media-helper process:

- the app obtains user consent through a file panel/security-scoped bookmark, opens with no-follow
  semantics, validates a regular file, and passes a read-only descriptor/capability rather than a
  path string;
- the helper rejects symlinks where not explicitly allowed, devices, FIFOs, sockets, sparse-size
  deception, offset overflow, overlapping tables, recursive backing chains, decompression bombs,
  and archive/path traversal;
- source identity is revalidated before and after long inspection/conversion to prevent TOCTOU;
- output is written to a new staging object with restrictive permissions, fsynced, verified, and
  atomically published; source bytes are never modified in place;
- controller, runner, renderer, media helper, and guest never inherit descriptors they do not own.

Downloads are transactional and independently resumable:

- enforce HTTPS and a documented redirect/trust policy;
- record URL, redirects, ETag/Last-Modified where available, expected/observed length, digest,
  signature/vendor evidence, and resume ranges;
- enforce declared and absolute byte limits before and during transfer;
- store incomplete bytes only as a `.partial` object with a durable resume record;
- on resume, prove the remote object still matches; otherwise restart without combining versions;
- verify content before atomic publication and never make a partial file selectable as media;
- preserve a fully offline local-file path with no network or catalog dependency.

Storage distinguishes immutable source, content-addressed cache, mutable working disk, snapshot
layer, and published/export object. Cache objects have digest identity, reference-counted leases,
quota, last-use metadata, and atomic garbage collection. Eviction touches only unreferenced cache
objects and can never remove a running VM disk, snapshot parent, active operation input, backup, or
rollback artifact.

### 14.4 Install and restore transaction

Generic installation follows named checkpoints:

`inspect -> qualify -> reserve space -> create staged disk -> attach install media -> boot
installer -> confirm installed bootability -> eject install media -> first disk boot -> publish`

- Preflight accounts for source, converted image, target disk, snapshot headroom, restore expansion,
  and rollback bytes.
- The installer never writes the original ISO/IPSW/import source.
- Completion means the installation medium is detached and a clean first boot from the target disk
  reaches authenticated guest readiness; detecting a process or firmware screen is insufficient.
- Retry resumes only from a checkpoint proven idempotent. Otherwise Dory creates a fresh staging
  destination and quarantines the uncertain one.
- Cancellation waits for runner/helper acknowledgement and durable compensation before reporting
  completion.

VZMac restore additionally validates the IPSW, supported configuration requirements, hardware
model, auxiliary-storage destination, VM stopped state, host free space, and Apple API support
before mutation. Interrupted or canceled restore produces an explicit recover/restart/delete choice;
it never presents a partial disk as an installed Mac.

## 15. Definitions, resolution, and operations

### 15.1 Guest-neutral definition

A durable VM definition expresses intent and pinned compatibility, not a monolithic backend enum:

```yaml
schemaVersion: 7
workload: desktop
guest:
  family: linux
  architecture: x86_64
  bootMode: uefi
  distributionHint: null
platform:
  executionEngine: dory.dbt.x86-to-arm64@1
  cpuProfile: dory.x86_64.compat-v1
  machineModel: dory.pc@1
  firmwareABI: dory.edk2.pc@1
  deviceABI: dory.virtio@1
resources:
  cpuCount: 4
  memoryBytes: 8589934592
media:
  sourceKind: installedWorkspaceDisk
  bootDisk: disks/system.dorydisk
  installMedia: null
capabilities:
  required: [display.multi, input.trackpad, audio.input, camera, usb.passthrough]
  preferred: [graphics.accelerated, display.hdr]
translationConsent: explicit
tools:
  policy: optional
permissions:
  camera: askWhenAttached
  microphone: askWhenAttached
  usb: askPerDevice
backup:
  policy: daily
retention:
  snapshots: keepLast7
qualification:
  receipt: receipts/launch.json
```

Exact schema syntax is decided in Phase 0. Required semantics are:

- host facts and user intent resolve deterministically;
- automatic resolution may occur only before first boot or under an explicit migration;
- first boot pins every guest-visible ABI;
- unsupported combinations fail before mutation;
- the operation journal records the resolved composition;
- UI and CLI display native versus translated execution truthfully;
- workload (`desktop`, `server`, or `sandbox`) selects defaults, not a different lifecycle engine;
- source kind, media role, required/preferred capabilities, explicit translation consent, Tools
  policy, permissions/isolation, backup/recovery/update, display assignment, and retention are
  durable intent;
- distribution identity remains a label, provisioning hint, and qualification dimension—not a
  backend key or lifecycle branch.

The public desktop/CLI/agent API has the same verbs and receipts for `inspect`, `resolve`, `create`,
`install`, `import`, `start`, `pause`, `suspend`, `stop`, `snapshot`, `clone`, `backup`, `restore`,
`export`, `delete`, `doctor`, and authorized `repair`. Accessibility labels, full keyboard
operation, progress announcements, safe focus/capture escape, and non-color-only state are part of
the desktop contract.

### 15.2 Operation model

All long-running work uses the existing durable operation principles:

- stable operation ID, VM ID, owner, kind, phase, progress, and timestamps;
- compare-and-swap ownership/lease;
- idempotent phase boundaries and resumable safe work;
- explicit cancellation acknowledgement;
- terminal state written only after durable cleanup;
- bounded events and typed error causes;
- safe recovery after controller, runner, or host termination.

Restore, install, image conversion, first boot, snapshot, clone, migration, update, and deletion are
operations. A canceled operation cannot continue mutating state in an unowned process.

Each operation has an explicit checkpoint/compensation table. Creation and installation minimally
cover `validated`, `spaceReserved`, `workspaceStaged`, `mediaPrepared`, `runnerStarted`,
`guestInstalled`, `firstBootReady`, and `published`. At every checkpoint Dory tests controller
termination, runner/helper termination, host restart, cancellation, low disk, permission loss, and
device loss.

- Preserve the first causal error; record cleanup outcome separately instead of overwriting it.
- Compensation deletes only resources whose ownership and completeness are proven by the operation
  receipt.
- Uncertain or partly guest-mutated disks move to a bounded quarantine with reason, size, owner,
  inspect/recover/delete actions, and expiry policy; they are never silently reused or erased.
- Publication is one atomic commit of definition, workspace identity, disk authority, and initial
  readiness state.
- Retry creates a new attempt/lease and resumes only from a checkpoint whose idempotence and inputs
  still validate.
- Readiness requires authenticated guest/framework evidence plus device checks, not PID existence,
  an open port, a firmware frame, or elapsed time.

### 15.3 Schema migration

1. Inventory every desktop, server, sandbox, custom-media VM, definition, disk/layer, MAC address,
   firmware/auxiliary store, identity, share, port, permission, snapshot, backup, and template link.
2. Inventory every persisted backend/accelerator/machine value plus EFI, direct-kernel, installed
   boot-bundle, media-role, and distribution-coupled decision.
3. Provide a read-only dry run that reports exact preserved, transformed, unsupported, and
   quarantine outcomes before mutation.
4. Define lossless mappings only where CPU, machine, firmware, device, media, and identity semantics
   truly match; never relabel an incompatible disk as migrated.
5. Preserve VM/workspace IDs, user disks and bytes, network identity, shares, ports, display
   choices, backups, and recoverable platform identity unless the receipt calls out a required
   change.
6. Mark old QEMU-shaped identities and distro-led execution values as decode-only. CI rejects new
   production branches keyed by a distribution name.
7. Decouple templates into optional provisioning metadata without changing the user's installed
   machine authority.
8. Back up definitions and required metadata, test downgrade/rollback fixtures, and write a signed
   migration receipt before commit.
9. Refuse automatic conversion when semantics are not equivalent; keep the source bootable under a
   bounded maintenance path or offer explicit export/reinstall while leaving bytes untouched.
10. Stop all legacy writes before the new schema ships; no dual-write compatibility layer.
11. Remove legacy decoding only after its documented support window, fixture coverage, and field
   evidence permit it.

### 15.4 Dory Tools and interface parity

Dory Tools is an optional, authenticated, versioned guest-integration package. It supplies only
features that cannot be expressed through standard virtual hardware, such as readiness,
graceful-shutdown acknowledgement, clipboard, file transfer, share coordination, resize hints,
and high-level diagnostics.

- Transport uses a mutually authenticated per-VM channel with credential rotation and replay
  protection.
- Messages are length-bounded, versioned, cancellable, and safe when either side is newer.
- No root shell, general host filesystem access, or ambient host credential is implied.
- Tools reports authenticated guest instance identity, IP/routes, wall/monotonic time health,
  display readiness, and shutdown state without becoming the source of CPU/machine truth.
- Snapshot quiesce has an explicit freeze/flush/ack/thaw protocol with timeout and guaranteed thaw
  compensation.
- Provisioning is journaled, idempotent, secret-redacted, and split into distro-neutral actions plus
  optional cloud-init, Ignition, Kickstart, preseed, or package-manager/provider adapters.
- Linux packaging remains distro-neutral at the protocol layer; distro packages are adapters.
- Publish static ARM64 and x86_64 guest packages with systemd, OpenRC, runit, and documented manual
  modes where qualified; no init system is a host-side execution dependency.
- macOS guest tooling follows Apple's signing and system-extension/driver rules.
- Tools install/update is an explicit operation with signature verification, compatibility
  negotiation, health check, last-known-good rollback, and an offline package path.
- A guest without Tools still boots, displays, stores data, networks, and shuts down through
  standard platform mechanisms where possible.

Every supported operation is representable consistently through the desktop, CLI, and agent-facing
API. Interfaces expose the same resolved plan, progress phases, cancellation state, stable errors,
and qualification truth. No interface gets a private backend shortcut.

## 16. Snapshots, clones, and portability

Lifecycle states are distinct:

- **pause** stops vCPU progress temporarily while the runner and volatile state remain live;
- **suspend** persists a validated engine-supported saved state and releases the runner;
- **stop** performs guest shutdown or a clearly labeled force-off and leaves only durable storage;
- an invalid or incompatible saved state never blocks an explicit cold boot from intact disks.

Snapshot capability graduates in order:

1. **Cold disk snapshot:** stopped VM, crash-consistent storage/definition state; mandatory baseline.
2. **Quiesced disk snapshot:** Dory Tools freezes/flushes, Dory commits storage, and Tools is always
   thawed; mandatory for supported “application-consistent” wording.
3. **Live memory snapshot:** pre-copy/dirty tracking plus an atomic CPU/device/time barrier; ships
   only after a versioned save/restore ABI, pause budget, memory-pressure, and fault tests pass.

A live DoryHV or DoryDBT snapshot contains:

- architectural vCPU state under a named CPU profile;
- guest RAM or an incremental dirty-page chain;
- machine, interrupt, timer, firmware-variable, and device state;
- disk-layer identities and durability points;
- engine-independent virtual time;
- exact ABI identities and a compatibility manifest.

No snapshot contains:

- translated host code or raw JIT pointers;
- host file descriptors, mappings, dispatch objects, or framework objects;
- reusable Apple identifiers, keys, or media;
- undocumented process memory.

For DoryHV and DoryDBT, restore follows `validate -> reserve -> open media -> restore devices ->
restore memory -> restore architectural CPUs -> arm clocks/interrupts -> run`. Any failure before
`run` leaves the source snapshot and disks unchanged.

VZMac uses a separate contract because Apple owns its architectural CPU and platform state. Dory
may offer:

- a framework saved-state snapshot only after the exact `VZVirtualMachineConfiguration` validates
  save/restore support, atomically bound to its hardware model, machine identifier, devices, CPU,
  memory, disk-layer generation, auxiliary-storage generation, configuration digest, and guest,
  host-OS, and framework versions; or
- a cold snapshot consisting of quiesced disks, auxiliary storage, hardware model, machine
  identifier, durable definition, and operation receipt.

Dory never claims to inspect or serialize VZMac architectural vCPU/device internals. VZMac state
does not restore through a DoryHV/DoryDBT engine or participate in cross-engine portability.
Apple's framework saved-state file is encrypted with a key tied to the physical host and must be
restored on that same host. Newer-software state is rejected by older software, and a host update
can make prior state incompatible. Dory therefore labels VZMac live/suspend state as same-physical-
host-only, validates it before use, retains a cold-boot recovery path, and never treats it as a
portable backup or clone artifact.

Portable restore is allowed only when CPU profile, machine, firmware, device, snapshot, storage,
host architecture, and guest licensing rules all match. An x86 guest snapshot may move between
interpreter and JIT tiers only when its translator-state contract permits it; no cross-host-ISA
migration is part of this Apple-silicon-only product. This rule does not make VZ framework saved
state portable: VZMac cross-host move/export uses cold or Tools-quiesced disk, auxiliary/platform,
definition, and identity state and performs a fresh boot on the destination.

Cloning creates new writable disks, operation identity, MAC addresses, agent credentials, and Mac
platform identity where required. Shared immutable bases are content-addressed and reference
counted transactionally.

The UI distinguishes:

- **snapshot clone**, which retains a documented parent/layer relationship;
- **full clone**, which becomes independently owned after verified copy/materialization; and
- **fork as new**, which intentionally regenerates every guest/network/platform identity and runs
  first-boot integration.

Snapshot deletion, merge/flatten, parent loss, interrupted merge, low disk, chain-depth limits,
concurrent backup, and garbage collection have fault-injection tests. No child is orphaned and no
referenced parent is reclaimed.

For VZMac, Dory persists the public hardware model, machine identifier, and auxiliary storage, but
does not invent or promise portability for framework-managed service identity. Host-derived iCloud
identity can change after a host move or concurrent clone and can require guest reauthentication;
clone, restore, and export UX must warn and test that behavior.

Backups are independent from snapshots. A backup has a content manifest, definition/ABI receipt,
disk/layer closure, optional cold or quiesced consistency receipt, encryption policy, destination
authority, retention, verification, and periodic restore drill. Backup failure cannot corrupt the
running workspace or its snapshot chain. VZMac backup/export excludes framework live state and
uses the cold/quiesced portable set with a verified fresh-boot restore drill.

Import/export uses a versioned `.dorymachine` bundle (the exact extension may change) with a signed
or digest-bound manifest, bounded relative paths, no symlink traversal, exact byte counts, ABI and
license requirements, and media exclusions. Import is an untrusted media operation into staging;
export never includes macOS installers, Apple firmware/identity secrets, host bookmarks,
credentials, clipboard, camera/audio data, or generated JIT code. Publication occurs only after a
full staged restore/bootability validation or an explicit unqualified-import receipt.

## 17. Security, privacy, legal, and clean-room controls

### 17.1 Threat boundaries

Treat as hostile:

- guest kernels, drivers, firmware, and userspace;
- ISO/disk/container metadata;
- network packets and virtual device descriptors;
- guest-agent and clipboard/file-share messages;
- snapshot and migration inputs;
- translated instructions and self-modifying guest code;
- display pixels, camera frames, microphone samples, keystrokes, pointer/gesture events, clipboard
  payloads, file paths, and USB transfers, which are private even when not malicious.

### 17.2 Required controls

- one least-privilege runner per VM;
- separate least-privilege media-inspector/converter, renderer/display, media-capture, network, and
  USB-broker processes where their authority or hostile surface differs;
- minimal entitlements per signed component;
- hardened runtime, strict W^X JIT policy, guard pages, and quotas;
- no dynamic guest-selected host libraries or plugins;
- brokered file/network/share access using capabilities scoped to the VM;
- checked arithmetic and bounded allocation in all parsers/devices;
- memory-safe implementation for new parsers and protocol surfaces where practical;
- fuzzing, sanitizers, static analysis, dependency/SBOM review, and reproducible builds;
- secrets excluded from logs, traces, snapshots, crash reports, and support bundles;
- signed component catalog, atomic activation, rollback, and revocation;
- independent security review before each translated or custom Mac path advances.

All XPC listeners authenticate the connecting audit token, effective UID, signing Team ID,
designated requirement, expected service identity, VM/operation lease, and protocol version before
accepting privileged work. Large or attacker-controlled payloads are decoded only after admission.
Production control never falls back to unauthenticated TCP, debug sockets, user-selected executable
fragments, shell interpolation, or path authority where a descriptor/capability can be used.

Logs and flight recordings default to structure, counters, hashes, sizes, timings, and stable error
codes. They exclude pixels, frames, audio, keys, pointer content, clipboard payloads, guest packets,
file contents, secrets, and full user paths. Any exceptional capture requires explicit bounded
consent, visible state, encryption, expiry, and deletion.

Repair is separate from diagnosis. Read-only inspection needs no mutation consent; every repair
lists intended changes, backs up affected metadata, scopes authority to exact resources, supports
cancellation where safe, records compensation, and never deletes an uncertain disk merely to make
the status green.

Entitlements are assigned to the narrow responsible executable:

| Executable/service | Required entitlement contract |
|---|---|
| DoryHV ARM64 runner | `com.apple.security.hypervisor` |
| VZMac runner | `com.apple.security.virtualization`; when it instantiates host audio input, also `com.apple.security.device.audio-input`, `NSMicrophoneUsageDescription`, and TCC authorization |
| DoryDBT runner | `com.apple.security.cs.allow-jit` plus the Phase 0-selected JIT write-allowlist entitlement/API |
| Host USB authority selected by the final API | `com.apple.security.device.usb` where required; if final AccessoryAccess is adopted, its current beta contract additionally uses `com.apple.developer.accessory-access.usb` in the UI-bearing process prescribed by the API |
| Camera capture service | `com.apple.security.device.camera` plus `NSCameraUsageDescription` |
| Microphone capture service | `com.apple.security.device.audio-input` plus `NSMicrophoneUsageDescription` |

Phase 0 builds separately signed/notarized entitlement probes under the actual direct-distribution
and sandbox profiles. A development build, inherited entitlement, or unsandboxed test does not
prove the release configuration.

### 17.3 Clean-room/IP policy

- Public architecture, firmware, device, and format specifications are primary sources.
- Behavior experiments record inputs/outputs and provenance.
- Proprietary code is not copied, translated, decompiled, or treated as an implementation source.
- Contributors disclose incompatible prior access where counsel requires separation.
- Any optional black-box comparison is isolated from production source and is never a build/test
  requirement.
- License and notice obligations are reviewed for EDK II and every imported dependency.

### 17.4 Apple platform gate

Counsel reviews the then-current Apple software license and program terms for every macOS release,
distribution model, Apple-silicon host type, use case, and instance model. Releases must satisfy
both the Apple-branded-host license requirements and Dory's stricter Apple-silicon-only resolver
boundary, preserve applicable limits, and never redistribute Boot ROMs, firmware, protected
identity material, or macOS installation assets.

This plan is an engineering charter, not legal approval.

### 17.5 Optional component supply chain

Each optional execution, firmware, driver, symbol, or tooling component has:

- a stable component ID unrelated to an external runtime;
- exact version and content digest;
- host architecture and minimum/maximum OS compatibility;
- code-signing identity, notarization state, entitlements, SBOM, license notices, and provenance;
- declared engine/CPU/machine/firmware/device ABI compatibility;
- atomic staged activation, health probe, last-known-good pointer, rollback, and revocation;
- offline verification and a clean-machine install test;
- a retention/deletion policy that cannot remove bytes used by a running VM or durable rollback.

Runtime component updates never rewrite a guest-visible ABI implicitly. A component can add an
optimization under an existing ABI only after compatibility and performance evidence proves the
behavior is unchanged.

### 17.6 Whole-release integrity

One immutable release manifest binds the app, daemon, helpers, runners, optional components, guest
Tools/drivers, firmware, checksums, signatures, entitlements, notarization tickets, SBOMs, license
notices, update feed, rollback set, website/download metadata, GitHub assets, and Homebrew metadata
that comprise one release. Independent channels may publish at different times only through a
staged manifest state that cannot advertise an unavailable or mismatched tuple.

Release rehearsal starts from a clean supported Mac with no VM components, installs through every
supported channel, verifies exact bytes and capabilities, upgrades existing machines, rolls back,
operates offline where promised, and proves removed/revoked components cannot be selected.

## 18. Diagnostics and product truth

Every VM exposes a compact launch receipt:

- guest family/build/architecture and inspected media digest;
- native or translated engine and direction;
- CPU profile, machine, firmware, device, and snapshot ABI;
- host model/OS and required entitlements/components;
- graphics mode: software presentation, paravirtualized GPU, or other qualified path;
- compatibility/support state and evidence version;
- performance tier and any active safe-mode feature disablement.

Stable error families include:

- unsupported host/guest architecture pair;
- missing or incompatible component;
- media ambiguous/corrupt/unsupported;
- firmware/identity/provenance failure;
- entitlement/signing/JIT denial;
- CPU feature or machine ABI mismatch;
- device negotiation failure;
- snapshot/migration incompatibility;
- performance guardrail or resource exhaustion;
- cancellation, lease loss, or incomplete recovery.

Support bundles are bounded, redacted, inspectable before export, and never include guest disk
contents, clipboard contents, keys, Apple identities, or high-volume instruction traces by default.

### 18.1 Component absence and readiness truth

The base Dory app, daemon, container engine, machine listing, backups, and diagnostics start and
remain usable with every optional VM/DBT/firmware/driver component absent. Machines remain visible
and inspectable while a required component is `absent`, `downloading`, `staged`, `verifying`,
`ready`, `broken`, `revoked`, or `rollbackAvailable`; the UI never hides data because its runtime is
missing.

Readiness is a versioned snapshot plus ordered event stream:

- every snapshot and event carries VM identity, runner generation, monotonic sequence, operation
  lease, timestamp, and evidence source;
- subscribers obtain a snapshot and then events without an observation gap or event-before-snapshot
  race;
- readiness distinguishes runner, firmware, storage, network, display, Tools, desktop, and
  required-device states;
- daemon/app restart reconciles workspace, journal, process, component, device lease, and readiness
  state before accepting mutation;
- stale runner generations and late events cannot revive or overwrite a newer state.

### 18.2 Doctor, repair, and flight recorder

`dory doctor` and its desktop equivalent are read-only by default. They validate definitions,
media/disk closure, free space, component bytes/signatures, entitlements/TCC state, runner/helper
health, leases, ports, device availability, display assignment, snapshot chains, backups, migration
state, and release-manifest consistency.

Repair requires an explicit scoped action. Each repair previews changes, names reversible and
irreversible steps, preserves the first diagnosis, backs up metadata, journals checkpoints and
compensation, verifies the result, and leaves uncertain user disks quarantined rather than deleted.
“Repair all” cannot grant privacy permission, replace media, rewrite a machine ABI, or discard data.

Each process maintains a bounded in-memory/on-disk flight recorder of typed lifecycle, exit,
device, JIT, permission, display, and operation events. It uses quotas and rotation, survives the
relevant crash boundary, joins events by stable IDs, and follows the privacy exclusions in section
17. Raw pixels, audio, keystrokes, clipboard, packets, and instruction streams are opt-in diagnostic
artifacts with separate consent and expiry, never default flight-recorder content.

## 19. Qualification system

### 19.1 Test layers

1. **Pure unit/property tests:** address arithmetic, rings, formats, decoders, IR, firmware tables,
   schema, and state machines.
2. **Differential CPU tests:** interpreter/JIT versus physical reference CPUs and specification
   vectors.
3. **Machine/device integration:** synthetic firmware and guest drivers exercise interrupts, DMA,
   reset, hot-unplug, malformed requests, and snapshot barriers.
4. **Installer matrix:** clean ISO/IPSW install, reboot, recovery, and disk-full/interruption cases.
5. **OS/workload matrix:** boot/update/kernel/driver/application suites for exact supported builds.
6. **Lifecycle chaos:** controller kill, runner kill, host reboot, low disk, low memory, network loss,
   cancellation, and repeated recovery.
7. **Natural-device matrix:** keyboard/layout/IME, mouse/trackpad/gestures, single/dedicated displays
   on every cell and independent multiple displays on cells that claim them, speakers/microphones/
   routes, cameras/formats, USB transfer/device families, network, sharing, clipboard, hot-plug,
   permission revoke, sleep/wake, and concurrent ownership.
8. **Dory Desktop UI/system interaction:** every section 12.10 state and journey, immutable
   projection/intent behavior, operation restart, window restoration, display/input escape,
   permission/device conflicts, accessibility, localization, and physical Mac interaction.
9. **Performance/thermal:** section 7 workloads and desktop-shell traces on physical release
   machines.
10. **Security:** fuzzing, hostile guest/device/agent/JIT cases, sandbox escape review, and signed
   artifact verification.
11. **Release qualification:** clean-machine install, upgrade, rollback, component absence, and
   support-bundle drills.

The qualification primary key is the exact tuple of Dory/release-manifest version, Mac model/chip,
host macOS build, guest family/version/build/architecture/media digest, execution engine and
translator revision, CPU profile, machine/firmware/device/snapshot ABI, component/Tools/driver
versions, desktop build/projection schema, graphics mode, locale/input layout, accessibility
configuration, TCC state, physical/guest display topology, and attached physical-device/firmware
tuple. Evidence from one tuple never silently qualifies another.

Linux qualification spans representative Debian-, Fedora-, SUSE-, Arch-, Alpine-, immutable-, and
desktop-family media without making any distribution a runtime dependency. macOS qualifies only
exact candidate/restore builds and update transitions permitted by the platform and license.

### 19.2 Compatibility ledger

The issue and failure evidence preserved in the archived plan becomes a machine-readable regression
ledger. Each entry has:

- evidence source and normalized failure class;
- affected host, guest, engine, CPU, machine, firmware, device, and media dimensions;
- deterministic reproduction or fixture;
- prevention invariant and owning test;
- first fixed version and protected ABI;
- status, waiver owner, expiry, and release impact.

No manually curated “works for me” list replaces this ledger.

Every applicable failure class and prevention invariant in the archived evidence must be linked to
an owning automated/manual test, a documented non-applicability reason, or an approved time-bounded
waiver. An undispositioned applicable class blocks the affected support claim.

### 19.3 Release receipt

For each supported cell, CI and physical labs produce a signed receipt containing artifact digests,
test matrix, performance distributions, UI/accessibility/localization results, natural-device and
physical-display results, known limitations, security/provenance approvals, rollback artifact, and
compatibility-ledger version. The desktop/CLI support claim is generated from these receipts.

### 19.4 Minimum release thresholds

- 100% of required create/install/import/cancel/retry/stop/snapshot/clone/backup/restore/delete and
  checkpoint fault cases pass for the exact supported tuple.
- Zero open known defects involving data loss/corruption, host escape, unauthorized device/media
  capture, identity collision, unbounded resource use, stuck input capture, orphan runner/lease,
  unreachable escape, stranded/black Dedicated Display, unrestored host screen/window/cursor,
  incorrect privacy indication, wrong-VM device assignment, stale-generation UI action, silent
  ABI/backend/graphics fallback, or unrecoverable update/rollback.
- A 24-hour single-VM desktop/workload/device soak and an 8-hour supported-concurrency soak pass on
  each release host tier, including display and device hot-plug plus network/route changes.
- The full device matrix passes physical probes; simulators cannot qualify USB, camera,
  microphone/audio routing, multi-display pacing, sleep/wake, or thermals.
- All performance budgets pass from cold and warm state with no unexplained regression outside the
  approved noise model.
- Clean-user and component-absent tests pass before any upgrade test can count as release evidence.
- Security, legal/provenance, whole-release manifest, rollback rehearsal, support bundle, doctor,
  and disaster-restore drills have current sign-off.

## 20. Delivery program

Work is incremental, but the four-target product is complete only when all four guest targets meet
their final definitions of done. A gate may end an affected research path with a signed terminal
`no-ship` decision when a lawful, secure, or technically supportable implementation is impossible.
That closes the workstream responsibly; it does not count as delivery of that target or completion
of this plan.

### 20.1 Dependency graph and parallel work

Phase numbers group outcomes; they do not require unnecessary serialization.

```text
0A charter/ABI/legal
 +----> 0B control/schema ---------------------> 3 ARM64 macOS
 |            \                                   ^
 |             +--> 1 native foundation --------+----> 2 ARM64 Linux
 |
 +----> 4 x86 DBT foundation ----> 5 DoryPC + x86 Linux ----+--> 7 x86 macOS
                                  |                         ^
 1 native machine/device --------+----> 6 Intel Mac platform+

8 continuous hardening, qualification, and release work overlaps every implementation phase
```

Dependency rules:

- 0A gates all implementation; 0B starts after the definition/ABI decisions it consumes are
  approved.
- Phase 1 begins after the execution ABI is frozen and may overlap the rest of 0B.
- Phase 2 needs Phase 1 plus the relevant resolver/operation slice of 0B.
- Phase 3 needs 0B plus runner, operation, and lifecycle foundations from Phase 1; it does not wait
  for ARM64 Linux qualification.
- Phase 4 starts after 0A's ISA, IR, JIT, security, and clean-room gates and can proceed in parallel
  with native guest work.
- Phase 5 needs the Phase 1 shared machine/device boundaries and Phase 4's correct interpreter/JIT.
- Phase 6 can begin when Phase 4 and the required Phase 5 CPU, firmware, bus, and device primitives
  stabilize; it does not wait for every x86 Linux optimization.
- Phase 7 requires Phase 4's translator gates, the required stabilized CPU/bus/device primitives
  from Phase 5, and Phase 6's frozen Mac platform candidate; it does not wait for every x86 Linux
  productization or optimization task when the finite legacy servicing window favors safe parallel
  work.
- Phase 8 continuously feeds regressions and release evidence back into every active phase.

### 20.2 Cross-cutting natural-device and Dory Desktop UI workstream

**Incremental estimate:** 200–380 engineer-weeks across Phases 0A–8

This workstream owns `DoryDesktopExperience`, `DoryHostDeviceBroker`, `DoryDisplayCoordinator`,
`DoryMediaBridge`, UI state projections and intents, common input/audio/USB/display cores, host
permissions, accessibility, and physical UI/device labs. Its product/state design begins in Phase
0A, its foundations land in Phases 0B–1, it adds an adapter and experience slice in each guest
phase, and it remains release-blocking throughout qualification.

Exit requires, on all four guest cells:

- windowed, full-screen, Dedicated Display, and reassignment to any selected physical screen on
  every cell; plus multi-window and multi-display-set workflows on cells that claim independent
  multiple guest displays;
- keyboard/mouse/trackpad naturalness and accessibility;
- speaker, microphone, camera, and route-change behavior;
- broad USB passthrough plus qualified device-family tuples;
- display/device hot-plug, host sleep/wake, permission revoke, runner crash, and multi-VM isolation;
- Library, Create/Import, Review Plan, Operation Center, Desktop Window, Displays, Devices,
  Snapshots & Backups, and Settings & Diagnostics surfaces with restart-safe state;
- complete keyboard and VoiceOver operation, focus/capture escape, reduced-motion/contrast/text
  adaptations, localization, and right-to-left/non-US-input qualification;
- durable install/recovery progress, truthful degraded states, and actionable component,
  permission, device, and runner failures without hidden backend substitution;
- the latency, pacing, A/V sync, zero-underrun, and resource budgets in sections 7 and 12.

The estimate is additional to a boot-and-basic-device VMM. It is included in the overall program
envelope in section 21.

### Phase 0A — Charter, measurements, legal, and ABI design

**Estimate:** 20–35 engineer-weeks

Deliver:

- approved four-cell Apple-silicon guest matrix and Intel-host rejection boundary;
- no-QEMU policy and automated repository/artifact check;
- product baselines on physical Apple-silicon machines;
- signed-off Dory Desktop information architecture, interaction/state specification, accessibility
  baseline, and physical multi-display/device qualification plan;
- optional, non-critical-path physical-x86 reference measurements where they improve differential
  testing without creating a Dory Intel-host runtime deliverable;
- initial execution, CPU, machine, firmware, device, snapshot, and definition ADRs;
- frozen Library/control-response/main-thread/window-restoration/display-transition UI budgets and
  deterministic interaction fixtures;
- JIT entitlement/prototype, single-`MAP_JIT`-region proof, callback-allowlist decision,
  instruction-cache publication plus epoch/hazard reclamation proof, and security threat model;
- release-signed feasibility probes for every required VZMac display, input, speaker/microphone,
  camera, and USB path, including final public API status, entitlement/TCC behavior, and lawful
  update-stable guest support;
- firmware/media/macOS legal and provenance decisions;
- an x86_64 macOS temporal-viability decision that names exact Tahoe 26-or-earlier candidates,
  freezes the minimum vendor-security/servicing horizon required at projected public launch, models
  the Phase 6–7 schedule, and defines the reevaluation cadence;
- staffing, lab, release, and regression-ledger ownership.

Exit:

- no prohibited runtime identity is written by the new schema;
- a signed minimal interpreter/JIT probe works under the intended release configuration;
- every required VZMac device class has a viable final public or otherwise lawful supported path,
  or the ARM64 macOS cell remains below `supported` with an explicit stop decision;
- at least one x86_64 macOS candidate can meet the frozen servicing horizon at the conservative
  projected Phase 7 launch date, or the x86_64 macOS product path records terminal `no-ship` before
  substantial Mac-specific implementation investment;
- budgets and reference machines are frozen;
- unresolved legal or platform questions are explicit stop gates.

### Phase 0B — Contract and control-plane migration

**Estimate:** 35–60 engineer-weeks

Deliver:

- compositional definitions and resolver;
- immutable runner launch contract;
- immutable desktop projections, typed intents, generation/sequence-aware event reduction, and UI
  fixtures for every resolver and operation state;
- operation/recovery integration;
- legacy decode-only migration and receipts;
- truthful CLI/UI engine, architecture, machine, graphics, and support status;
- component/signing/rollback manifest changes.

Exit:

- new definitions contain no QEMU-specific accelerator, backend, protocol, or machine identity;
- resolver golden tests cover every matrix cell and failure;
- old definitions migrate safely or fail without mutation;
- deterministic projection/intent fixtures pass restart, duplicate/out-of-order event,
  stale-generation action, cancellation, and operation-reconciliation tests for every UI state.

### Phase 1 — Native foundation extraction and performance harness

**Estimate:** 45–80 engineer-weeks

Deliver:

- `DoryExecutionContracts` and per-VM runner isolation;
- a `DoryDesktopExperience` shell exercised against deterministic fake runners, screens, devices,
  permissions, operation journals, and failure/restart sequences;
- extracted ARM native engine;
- transport-neutral device cores;
- host-device broker, display-topology, input, media-routing, and permission contracts;
- SwiftUI shell plus focused AppKit/Metal display-window boundaries, screen/device simulation,
  capture-escape handling, and main-thread/hot-path isolation tests;
- architectural clock, interrupt, dirty-page, pause, and snapshot foundations;
- benchmark, trace, deterministic replay, and physical-lab harnesses.

Exit:

- existing native direct-kernel workloads have no material regression;
- controller overhead meets the 3% budget;
- 10,000 lifecycle/fault cycles leave no orphan resources;
- the fake-runner/device/screen suite passes keyboard/VoiceOver navigation, capture escape,
  display-loss rollback, permission/device conflict, and window/session restoration;
- Library, state-propagation, main-thread-hitch, and restoration measurements meet the frozen UI
  budgets before a real guest adapter depends on the shell.

### Phase 2 — `DoryARMVirt-v1` generic ARM64 Linux

**Estimate:** 45–80 engineer-weeks

Deliver:

- frozen ARM machine ABI;
- Dory EDK II ARM platform, UEFI variables, ISO and disk boot;
- generic installer, reboot, recovery, snapshot, and device support;
- performance tuning and compatibility matrix.

Exit:

- representative ARM64 distributions install from unmodified compatible media, reboot, update,
  and pass lifecycle/device/performance gates on DoryHV;
- the ARM64 Linux desktop passes multi-display, Dedicated Display, input, audio, camera, and USB
  gates on its qualified device matrix;
- Linux does not require Virtualization.framework's high-level Linux machine path.

### Phase 3 — Native ARM64 macOS product path

**Estimate:** 30–55 engineer-weeks

Deliver:

- production `DoryVZMacAdapter`;
- restore/media provenance, identity, auxiliary storage, recovery, update, clone, diagnostics, and
  qualification;
- qualified public graphics/input/audio/network/storage paths.

Exit:

- selected ARM64 macOS versions pass restore through sustained workload and update gates on the
  supported Apple-silicon matrix;
- VZMac's one supported guest display resizes, paces, and moves among any chosen physical screen,
  including Dedicated Display; the UI truthfully reports Apple's current maximum-one-display limit;
- input/trackpad, speaker/microphone, camera, and qualified USB paths pass without hidden unsupported
  fallbacks;
- every required device path uses a final qualified public API/bridge and update-stable guest
  support; an absent path blocks the phase rather than weakening the device contract;
- performance and graphics mode are truthfully reported.

### Phase 4 — DoryDBT interpreter, IR, and x86-to-ARM bring-up

**Estimate:** 100–180 engineer-weeks

Deliver:

- x86 interpreter and executable architecture specification;
- ISA-neutral IR;
- physical-CPU differential harness and deterministic replay;
- baseline ARM64 JIT, bounded code cache, invalidation, precise faults;
- direct-kernel uniprocessor Linux bring-up.

Exit:

- conformance suites pass at agreed coverage;
- interpreter and JIT agree at every sampled boundary;
- a Linux kernel/userspace boots without hiding unsupported instructions;
- JIT security review passes its first gate.

### Phase 5 — `DoryPC-v1` and x86-to-ARM Linux productization

**Estimate:** 270–490 engineer-weeks

Deliver:

- paging, privilege, SMP, APIC, TSO preservation, x87/SSE and staged AVX profiles;
- PC memory, interrupt, timer, ACPI, PCIe, USB, reset, and power model;
- Dory EDK II PC platform, NVRAM, ISO, installed-disk, and recovery boot;
- `DoryPC-v1` UEFI installation under the interpreter and each JIT tier;
- optimizing tiers and block/network/display fast paths;
- hostile-guest, thermal, long-duration, compatibility, and workload qualification.

Exit:

- selected x86_64 Linux media install, update, recover, and run the published workload matrix on
  Apple silicon;
- `DoryPC-v1` is frozen and behaves identically across interpreter, baseline JIT, and optimizing
  JIT tiers;
- the x86_64 Linux desktop passes the same natural-device contract as ARM64 Linux;
- translated performance budgets pass on the lowest supported Apple-silicon host tier.

### Phase 6 — `DoryIntelMac-v1` platform on Apple silicon

**Estimate:** 140–260 engineer-weeks

Deliver:

- approved lawful Tahoe 26-or-earlier x86_64 macOS guest version/media policy with an explicit
  servicing and security-support floor;
- minimum boot CPU profile plus UEFI/boot, SMC, NVRAM, SMBIOS/identity, interrupt, timer, reset, and
  power behavior;
- minimum storage, input, and software-display path needed for firmware/recovery/installer bring-up;
- interpreter-first platform isolation followed by baseline-JIT parity;
- draft snapshot, clone, identity, and rollback semantics;
- optional, non-critical-path native-x86 differential evidence.

Exit:

- the platform candidate reaches the approved firmware/recovery/installer milestone under the
  interpreter and baseline JIT with identical machine-visible transitions;
- legal/provenance/security gates pass;
- no protected firmware or identity is redistributed;
- Intel hosts remain rejected by every production interface;
- the phase is explicitly not an install, update, workload, or public-support qualification.

### Phase 7 — x86_64 macOS on Apple silicon

**Estimate:** 280–650 engineer-weeks

Deliver:

- complete advertised Mac CPU profile in DoryDBT and validate all optimizing tiers;
- complete installer, storage, network, input, software display, audio, time, SMP, power, and
  identity paths on the same `DoryIntelMac-v1`;
- install, update, recovery, snapshot/clone/rollback, desktop/workload, and responsiveness
  hardening;
- graphics acceleration research only behind its independent gate.

Exit:

- selected lawful Tahoe 26-or-earlier x86_64 macOS builds pass clean install, update, recovery,
  devices, lifecycle, stability, workload, security, legal, and translated performance gates on
  Apple silicon;
- multi-display/Dedicated Display, input, audio, camera, USB, permission, route-change, and
  sleep/wake qualification match the core desktop contract.

### Phase 8 — Continuous hardening and release trains

**Estimate:** 40–80 engineer-weeks per major release train, overlapping feature phases

Deliver:

- new supported host OS and ARM64 guest qualification, new x86_64 Linux qualification within its
  published profile, and only approved update/security transitions for exact Tahoe 26-or-earlier
  x86_64 macOS builds;
- physical lab, compatibility ledger, fuzz/security, performance, update, rollback, and support
  evidence;
- desktop interaction, accessibility, localization, physical display/device, permission, and
  restart/recovery regression evidence;
- migration windows and ABI retirement;
- regression repair without weakening established thresholds.

## 21. Staffing and realistic envelope

This program requires a stable specialist team, not occasional feature work.

Core disciplines:

- x86 and ARM architecture/operating systems;
- compiler, interpreter, JIT, optimization, and memory models;
- VMM, firmware, ACPI/FDT, PCIe, interrupts, storage, network, audio, input, and graphics;
- macOS platform, driver, signing, entitlement, and release engineering;
- Swift control plane, desktop UX, operations, and recovery;
- performance engineering and physical-lab automation;
- security, fuzzing, supply chain, clean-room process, and specialist legal counsel;
- compatibility, QA, documentation, and support readiness.

Planning envelope:

- **Four Apple-silicon-hosted guest targets:** approximately **1,150–2,300 engineer-weeks** before
  ongoing release trains, likely **5–8 years** with a sustained **10–14-person specialist team**
  and parallel workstreams.

There is no Intel-host parity estimate because Intel-host delivery is outside the product boundary.
Removing that work is a scope decision, not deferred backlog.

Estimates are ranges, not commitments. They include integration and qualification, not only code.
The actual critical path depends on hiring, Apple API/legal constraints, guest-driver viability,
physical hardware, and discoveries in CPU/platform conformance.

## 22. Repository change map

| Area | Planned change |
|---|---|
| `Packages/ContainerizationEngine` | Split DoryHV engine, machine, device, runner, and contracts; preserve tested behavior |
| New DoryDBT packages | Interpreter, IR, decoders, code generators, cache/runtime, conformance tools |
| New machine packages | ARM virtual, PC, and Intel Mac guest models for Apple-silicon hosts |
| New firmware package/tooling | Pinned EDK II sources/config, reproducible builders, ABI/provenance manifests |
| `dory-core-swift/Sources/DoryOperations` | Guest-neutral definitions, resolver, migration, operation receipts, no new QEMU identities |
| `dory-core-swift/Sources/DoryVMMKit` | VZMac adapter and temporary migration baselines; no generic Linux ownership |
| Media/image tooling | Dory-owned parsers, sparse disks, conversion, provenance, fuzz corpora |
| `DoryDesktopExperience`/CLI | All nine stable UI surfaces, immutable state/intents, AppKit/Metal display/input boundaries, accessibility/localization, truthful status, install, diagnostics, and recovery |
| Components/release | Signed optional DBT/firmware/driver components, atomic activation, rollback, SBOM |
| Tests/qualification | ISA, machine, device, installer, lifecycle, performance, security, physical matrix |
| Documentation | ABI specifications, compatibility ledger, legal gates, runbooks, support policy |

Before implementation begins, each row receives an ADR, owner, test strategy, measurable exit gate,
and dependency list.

## 23. Risk register and stop/replan gates

| Risk | Consequence | Control and stop gate |
|---|---|---|
| DBT correctness scope is underestimated | Silent corruption or unusable compatibility | Interpreter-first, physical differential tests, precise state; do not preview before G1 |
| Cross-ISA performance misses product value | Years of work yields a technically bootable but poor product | Phase baselines, staged workload gates, optimizing tier only after evidence; record terminal `no-ship` if necessary—changing the four-target scope requires a separate product decision |
| Intel Mac guest model lacks lawful firmware/device path | x86_64 macOS cannot ship | Legal/provenance gate plus interpreter-first and optional internal reference evidence before product integration |
| x86_64 macOS has a finite guest lineage and servicing window | The 5–8-year program could finish after every candidate fails Dory's security floor | Phase 0 models projected launch and freezes a minimum remaining servicing horizon; reevaluate continuously; record terminal `no-ship` before Mac-specific investment if no candidate can meet it |
| Mac graphics acceleration is unavailable | Desktop experience may remain limited | Software path truthfully labeled; public PVG/driver research is independent; no false GPU claim |
| Public VZMac remains limited to one guest display | ARM64 macOS cannot offer an independent multi-monitor guest desktop | Guarantee assignment of that one guest display to any chosen physical screen; label the limit; keep independent VZMac multi-display blocked until a final public Apple path passes qualification |
| Apple platform/API/entitlement changes | Native Mac or JIT release blocked | Minimal adapters, CI on betas, signed probes, rollback, and per-release gate |
| A required public VZ/device API or lawful guest driver is absent or beta | ARM64 macOS cannot meet the natural-device contract | Qualify only final public APIs and exact guest/device tuples; keep the cell below supported or issue terminal `no-ship` rather than inventing a private fallback |
| UI state diverges from durable controller truth | Wrong controls, lost operations, or destructive action against stale state | Immutable generation-aware projections, typed intents, state-model tests, receipts, and restart reconciliation |
| Display loss or input capture strands the user | Black screen, trapped keyboard/pointer, or inaccessible host controls | Stable screen identity, escape chord, timed confirmation, automatic rollback, and one-/two-/three-screen physical chaos tests |
| Multi-display and physical-device bandwidth exceeds a host tier | Stutter, A/V failure, or cross-VM device theft | Per-tier pixel/audio/camera/USB admission budgets, exclusive leases, backpressure, and truthful busy/degraded states |
| Intel hosts accidentally remain reachable | Unsupported configurations consume effort or mutate data | One resolver gate, public-build symbol/component audit, and negative tests across every interface |
| Firmware fork becomes unmaintainable | Security/update burden | Narrow Dory platform ports, upstream-first fixes, reproducible builds, ABI discipline |
| Parser/device attack surface expands | Host compromise/data loss | Isolation, bounds, fuzzing, memory-safe code, quotas, independent security review |
| Machine ABI churn breaks guests/snapshots | Update and recovery failures | Freeze versioned ABIs, compatibility fixtures, migration receipts, bounded windows |
| Performance optimization harms semantics | Rare corruption or race failures | Litmus/property/replay suites per optimization, feature rollback, no threshold waiver |
| Team churn destroys specialist knowledge | Schedule and quality collapse | Paired ownership, ADRs/specs, reproducible labs, conformance corpus, succession plans |
| “Build everything” expands without boundaries | Product never converges | Own guest-visible value; reuse lawful standards/frameworks where they preserve control |

Any failed legal, security, architectural correctness, or lawful-media gate stops the affected path.
It does not authorize bypasses or undocumented workarounds. If the stop is terminal, the signed
`no-ship` record means the affected target—and therefore the four-target product—remains
undelivered; it is not an alternate definition of done.

## 24. Required ADRs before feature implementation

1. Execution-engine and machine-model boundary.
2. Guest physical memory and dirty-page contract.
3. Clock, interrupt, cancellation, and snapshot barriers.
4. `DoryARMVirt-v1` ABI.
5. `DoryPC-v1` ABI.
6. CPU-profile naming, feature exposure, and migration rules.
7. DoryDBT interpreter/IR/precise-exception model.
8. JIT memory, single-region suballocation, callback allowlist, instruction-cache publication,
   immutable blocks, lookup removal, epoch/hazard quiescence before slot reuse, signing,
   entitlement, isolation, and crash recovery.
9. VirtIO core/transport split and device-version policy.
10. Dory EDK II source, build, update, and provenance policy.
11. Disk format threat model, sparse/COW semantics, and conversion transactions.
12. VZMac identity, restore, update, snapshot, and clone lifecycle.
13. Intel Mac model legal/provenance/identity boundary.
14. Graphics truth model and acceleration gates.
15. Definition schema migration and legacy decode window.
16. Component signing, activation, rollback, and no-QEMU artifact verification.
17. Performance methodology, host tiers, budgets, and regression policy.
18. Compatibility ledger and signed release receipts.
19. Host-device broker authority, XPC peer authentication, TCC ownership, USB leases, and
    multi-VM admission.
20. Display topology ABI, renderer/presentation boundaries, multi-window mapping, Dedicated Display
    safety, input capture, and topology recovery.
21. Camera and audio capture/routing, guest transport, privacy indicators, permission revocation,
    synchronization, and fault recovery.
22. Dory Desktop immutable projection/typed-intent architecture, operation reconciliation,
    SwiftUI–AppKit–Metal boundaries, accessibility, localization, and UI performance budgets.
23. Media helper, descriptor authority, download/cache lifecycle, inspection, and install
    transaction.
24. Cold, quiesced, and live snapshot compatibility plus backup/import/export/clone/fork semantics.
25. Operation checkpoints, compensation, quarantine, first-error retention, and repair consent.
26. Whole-release immutable manifest, clean-machine rehearsal, rollback, and distribution parity.

## 25. Final definition of done

The program described by this plan is complete only when all of the following are true.

### 25.1 Ownership and architecture

- Shipped artifacts contain and invoke no QEMU executable, library, translator code, machine
  version, control protocol, or disk utility.
- Runtime manifests, dependency graphs, process scans, signing inventories, and clean-machine tests
  prove that absence.
- Definitions persist Dory execution, CPU, machine, firmware, device, snapshot, and media identities
  only.
- Native Linux defaults to DoryHV. Cross-architecture Linux defaults to the exact DoryDBT direction.
- Native ARM64 macOS uses the supported VZMac path with Dory-owned lifecycle and provenance.
- x86_64 macOS uses the frozen Dory Intel Mac model and DoryDBT on Apple silicon.
- Every production interface rejects Intel hosts before download, media conversion, workspace
  creation, disk allocation, or runner launch.
- Public builds contain no ARM-to-x86 translator, x86 host code generator, or native-x86 runtime
  component for this feature.
- Engine and machine models are independently testable and versioned.
- The base app and controller start, list every machine, and expose component install/doctor/repair
  states when every optional virtualization component is absent, installing, broken, or rolled back.
- One immutable whole-release manifest binds the app, controller, runners, optional components,
  Tools/drivers, checksums/SBOMs, update feed, rollback set, and every distribution channel.

### 25.2 Four guest targets

On the supported Apple-silicon host matrix:

- ARM64 Linux installs from representative compatible media, reboots, updates, recovers, and meets
  native performance and lifecycle gates.
- x86_64 Linux does the same through x86-to-ARM DoryDBT and meets published translated gates.
- ARM64 macOS restores from lawful compatible media, reboots, updates, recovers, and meets native
  VZMac gates.
- x86_64 macOS installs from a lawful, exact Tahoe 26-or-earlier build, reboots, updates, recovers,
  and meets the Intel Mac platform plus translated gates for its published servicing interval.

Each cell also passes storage, network, display, keyboard/mouse/trackpad, time, entropy, speakers,
microphone, camera, clipboard, sharing, core USB behavior, snapshot/clone, long-duration,
resource-pressure, fault-injection, security, and rollback qualification. Vendor-specific USB
support remains limited to exact device/firmware tuples in the compatibility ledger; the core
attach/detach/ownership/recovery contract is mandatory.

If any cell ends in terminal `no-ship`, the reason and evidence are retained, but the four-target
product and this definition of done remain incomplete.

### 25.3 Performance and quality

- Native paths meet section 7 on every supported physical host tier and feel effectively native in
  the declared workload suite.
- Translated paths publish honest per-workload evidence and meet responsiveness/usefulness gates on
  the lowest supported tier.
- There is no hidden interpreter-wide fallback, busy polling, unbounded code/device cache, or
  controller hop on a hot path.
- No known correctness, corruption, security, lifecycle, or orphan-resource issue is waived to
  achieve a score or date.
- Every supported claim is backed by a signed release receipt and an available rollback artifact.
- Every applicable failure class in the archived evidence is bound to a passing prevention test,
  a documented non-applicability decision, or an unexpired approved waiver; none is left
  undispositioned.
- Every minimum release threshold in section 19.4 passes for the exact supported tuples; passing a
  narrower smoke test cannot satisfy this definition of done.

### 25.4 Dory Desktop and natural devices

- All nine stable Dory Desktop surfaces in section 12.10 ship from the same durable controller
  truth used by the CLI and agent API; no view directly mutates VM, disk, device, or operation
  state.
- Create/Import and Review Plan expose guest architecture, native versus translated execution,
  measured performance class, resolved machine/firmware/device ABIs, media evidence, permissions,
  components, disk impact, and unsupported items before mutation.
- Closing windows, quitting Dory, runner failure, controller restart, permission revocation, and
  host restart preserve or reconcile lifecycle and operation truth without silent power-off,
  device theft, lost progress, or stale destructive controls.
- Keyboard, mouse, trackpad, speakers, microphone, camera, USB, clipboard, sharing, networking,
  display resize, and device/route/topology hot-plug pass the exact natural-device contract on
  every supported guest cell and host tier.
- On every cell, users can map the guest desktop onto any selected physical Mac screen in windowed,
  native full-screen, or Dedicated Display mode with stable identity, sharp scaling, an
  always-reachable escape path, timed confirmation, and automatic rollback.
- On Dory-owned machine paths, users can additionally map several independent guest displays onto
  several physical screens with independent pacing. VZMac exposes no such claim while Apple's
  final public API remains limited to one guest display; mirroring/splitting is not presented as a
  substitute.
- Physical one-, two-, and three-screen labs qualify mixed scale/refresh/orientation, Spaces,
  Mission Control, clamshell/dock/sleep/wake, screen loss, reconnect, and concurrent VM behavior.
- Full keyboard navigation, VoiceOver, focus order, reduced motion, increased contrast, text
  scaling, non-color-only meaning, localization, right-to-left layouts, non-US keyboards, and
  capture escape pass release qualification.
- UI/render/input/device work stays within the latency, main-thread, memory, energy, and resource
  budgets in sections 7 and 12; degraded modes and unsupported hardware are labeled truthfully.

### 25.5 Safety and legality

- All firmware, dependencies, media workflows, JIT entitlements, guest drivers, Apple identities,
  and macOS uses pass current provenance, license, signing, security, and legal review.
- Dory redistributes no macOS media, Apple firmware, ROM, key, or protected identity material.
- Hostile guest, parser, device, guest-agent, snapshot, and JIT testing passes.
- Support bundles are bounded, redacted, inspectable, and useful.

Intel-host support is explicitly outside this plan and is not deferred work. Changing that boundary
requires a new product decision and a separately approved plan.

## 26. Primary references

Normative implementation decisions must cite the current versions of primary sources and record the
selected Xcode SDK header contract; an array-shaped or beta API is not evidence that a capability is
supported. Starting points include:

- Apple Hypervisor framework documentation:
  <https://developer.apple.com/documentation/hypervisor>
- Apple Hypervisor entitlement:
  <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.hypervisor>
- Apple Virtualization framework documentation:
  <https://developer.apple.com/documentation/virtualization>
- Apple Virtualization entitlement:
  <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization>
- Apple's supported macOS-on-Apple-silicon VM workflow:
  <https://developer.apple.com/documentation/virtualization/virtualize-macos-on-a-mac>
- Apple guidance for Intel binaries inside ARM Linux VMs:
  <https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms>
- Apple's statement that macOS Tahoe 26 is the final release for Intel Macs:
  <https://developer.apple.com/videos/play/wwdc2025/102/>
- macOS Tahoe release notes confirming the Intel transition boundary:
  <https://developer.apple.com/documentation/macos-release-notes/macos-26_4-release-notes>
- Apple VZMac display collection contract—currently maximum one display—and Apple DTS
  clarification that multiple displays are not currently supported:
  <https://developer.apple.com/documentation/virtualization/vzmacgraphicsdeviceconfiguration/displays>,
  <https://developer.apple.com/forums/thread/825515>
- Apple Virtualization audio input/output bridging and the current default-input source:
  <https://developer.apple.com/documentation/virtualization/audio>
  <https://developer.apple.com/documentation/virtualization/vzhostaudioinputstreamsource>
  <https://developer.apple.com/documentation/virtualization/vzhostaudiooutputstreamsink>
- Apple Virtualization USB device and passthrough API status, including the currently beta
  passthrough configuration and AccessoryAccess entitlement:
  <https://developer.apple.com/documentation/virtualization/usb-devices>,
  <https://developer.apple.com/documentation/virtualization/vzusbpassthroughdeviceconfiguration>,
  <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.accessory-access.usb>
- Apple save/restore configuration validation and saved-state operations:
  <https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration/validatesaverestoresupport%28%29>
  <https://developer.apple.com/documentation/virtualization/vzvirtualmachine/savemachinestate%28to%3Acompletionhandler%3A%29>
  <https://developer.apple.com/documentation/virtualization/vzvirtualmachine/restoremachinestate%28from%3Acompletionhandler%3A%29>
- AppKit screen discovery, topology, scale, refresh, and display timing:
  <https://developer.apple.com/documentation/appkit/nsscreen>
- Apple camera and microphone permission, usage-description, and entitlement guidance:
  <https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media>
  <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.camera>
  <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input>
- Apple ParavirtualizedGraphics framework documentation:
  <https://developer.apple.com/documentation/paravirtualizedgraphics>
- Apple hardened runtime JIT entitlement:
  <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit>
- Apple guidance for JIT compilers on Apple silicon:
  <https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon>
- Apple software license agreements:
  <https://www.apple.com/legal/sla/>
- Arm Architecture Reference Manual and system architecture specifications:
  <https://developer.arm.com/Architectures>
- Intel 64 and IA-32 Architectures Software Developer Manuals:
  <https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html>
- UEFI specifications:
  <https://uefi.org/specifications>
- ACPI specifications:
  <https://uefi.org/specifications>
- PCI Express specifications and public resources:
  <https://pcisig.com/specifications>
- VirtIO specification:
  <https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html>
- EDK II project documentation and source:
  <https://github.com/tianocore/tianocore.github.io/wiki/EDK-II>

The repository audit and external-project failure research remain preserved in
[`linux-and-macos-virtualization-evidence-2026-08-29.md`](linux-and-macos-virtualization-evidence-2026-08-29.md).
Those observations supply regression cases; this document supplies the current product decision,
architecture, gates, sequence, and definition of done.
