# Dory x86 SMP memory and translation contract

Status: **normative target; release qualification incomplete**

This document defines the guest-visible contract that the translated x86 PC runtime must satisfy
before free-running SMP can become a supported configuration. It also records which parts are
implemented today. Passing an individual unit test or booting a guest does not weaken any rule
below. The implementation sequence and lifecycle/ownership design are recorded in
`x86-free-running-vcpu-plan.md`.

## Scope and terms

The contract applies to every vCPU execution tier, ordinary RAM, page-table walks, instruction
fetch, device DMA, and shared-memory adapters in one `DoryPCDirectKernelMachine`. MMIO ordering is
defined by each device boundary, but crossing MMIO may not weaken the ordering of surrounding RAM
accesses.

- **Program order** is the architectural order of one x86 vCPU after faults and restartable
  instruction progress are resolved.
- **Global memory order** is the single order in which stores and locked operations become visible
  to all vCPUs and coherent devices.
- **Single-copy atomic** means no observer can see a torn value for an architecturally atomic
  access.
- **Machine-scoped** means one authority is shared by all execution engines that can reach one
  machine's RAM. Independent virtual machines must not contend on that authority.
- A **publication boundary** is a release operation paired with an acquire observation. A Swift
  mutex is not, by itself, proof for generated code that bypasses that mutex.

## Required guest-visible behavior

### Ordinary RAM

The runtime must implement x86 TSO, not the weaker host Arm memory model:

1. Loads remain ordered with older loads.
2. Stores remain ordered with older loads and older stores.
3. A load may pass an older store only as permitted by x86 store-buffer semantics; it must observe
   the youngest older same-address store.
4. Stores become visible in one multicopy-atomic order. Two observers may not disagree on the
   order of two stores after both have observed either store.
5. Naturally aligned 1-, 2-, 4-, and 8-byte loads and stores are single-copy atomic. Wider and
   unaligned ordinary accesses receive only the atomicity guaranteed by x86.

Generated Arm loads/stores, Swift callback accesses, interpreter accesses, and device RAM accesses
must participate in this same model. It is invalid to rely on a lock used only by Swift while
generated code accesses the same allocation directly.

### Locked operations

Every valid x86 `LOCK` operation and every implicitly locked memory `XCHG` must:

- be indivisible with respect to ordinary and locked accesses from every vCPU and coherent device;
- occupy one total order shared by all locked operations in the machine;
- act as a full fence for older and younger loads and stores; and
- retain precise fault behavior: no register, flag, memory, or generation side effect may escape a
  failing preflight.

Aligned natural-width operations should use lock-free host atomics when the host proves them
lock-free. A machine-scoped fallback is permitted for an unaligned, split-page, split-cache-line,
or 16-byte operation only when ordinary accesses to the affected bytes are also excluded or made
atomic. Merely serializing locked helpers with each other is insufficient.

The machine's `DoryX86AtomicCoordinator` is the ownership boundary for fallback coordination. The
interpreter and every JIT executor for one machine share it through the append-only JIT context.
Different machines use different coordinators. The coordinator may not become a process-global
performance or failure domain.

### Fences and serializing boundaries

- `MFENCE` joins all prior loads/stores before all later loads/stores.
- `SFENCE` joins all prior stores before all later stores.
- `LFENCE` joins all prior loads before all later loads and retains the architectural execution
  barrier behavior selected by Dory's CPU profile.
- Locked instructions provide the full-fence behavior above without requiring an adjacent fence.
- MMIO callbacks, interrupt delivery, and device notification must use an explicit ordering
  boundary where the device model depends on prior RAM writes.

### Page tables and TLBs

A page-table write is an ordinary memory write until the guest executes the architecturally
required invalidation or control-register operation. Once that invalidation retires:

1. the initiating vCPU must not reuse an older translation;
2. every targeted remote vCPU must observe a newer address-space generation before it can retire a
   later access using the invalidated translation; and
3. a recycled translation-cache entry must never regain authority through generation wrap,
   address-space reuse, or code-cache reuse.

Free-running SMP therefore requires a generation publication protocol plus acknowledgement or an
equivalent epoch/hazard scheme. Invalidating only when a worker happens to return to a coordinator
is not sufficient.

### DMA and shared mappings

Device DMA reads observe CPU stores after the device's notification/order boundary. DMA writes are
published before completion interrupts or used-ring updates become visible to a vCPU. A device or
shared-mapping adapter that can modify bytes backing translated code must call
`invalidateTranslatedCodeGenerations(in:)` before reusing or exposing that backing. The range is
validated completely before generation or protection state changes.

DMA into page tables participates in the same translation invalidation rules; a device completion
cannot silently make stale native TLB entries authoritative.

### Self-modifying code and instruction fetch

Instruction fetch may use a resident translation only while all of these remain true:

- its exact guest bytes or generation token still match;
- its address-space, privilege, paging, and code-protection generations match; and
- no CPU, DMA, or shared-mapping write has obtained authority to modify an overlapping guest code
  page without first revoking that translation.

Guest code pages are 4 KiB even when the host allocation/protection granule is larger. Revoking one
host page must invalidate every tracked guest code page that overlaps it. A writer publishes the
new bytes before a later fetch can accept the new generation. An old block may finish only under a
documented epoch/hazard rule that prevents its storage from being recycled while executable.

## Current implementation boundary

As of implementation checkpoint `a10167e67` on 2026-09-20:

| Area | Implemented | Still required before SMP acceptance |
| --- | --- | --- |
| Machine ownership | One `DoryX86AtomicCoordinator` and one `DoryX86MemoryAccessCoordinator` are shared by all interpreters, baseline/optimizing executors, translated memory, and PC RAM for one machine; independent machines are isolated. `DoryX86PhysicalRAM` requires range-coordinated backing memory, and direct translated host mapping fails closed when that authority is unavailable. | Extend the same ownership into every future execution tier and RAM-sharing adapter. |
| Native aligned locked operations | The C helpers use lock-free sequentially consistent 1/2/4/8-byte host atomics; aligned 16-byte CAS is admitted only when the host proves it lock-free. Every helper also takes an ordinary backing-address range lease after the machine atomic gate and declines native execution when that authority is absent. | Qualify these paths in the full tier-pair and host matrix. |
| Mixed interpreter/JIT locked operations | Aligned 1/2/4/8-byte interpreter families use host compare/exchange transactions shared with native JIT helpers. Unaligned and split-backing locked fallbacks plus interpreter CMPXCHG16B take one exclusive multi-range lease after complete preflight, excluding overlapping ordinary/native access. The internal interpreter pair passes concurrent implicit XCHG and locked XADD/CMPXCHG guest loops plus 10,000 locked shared-memory increments. | Extend contention and precise-fault campaigns across translated/PC routing, protected code, every locked family, split cache lines/pages, 8/16-byte compare/exchange, every tier pair, and 1/2/4 vCPUs. |
| Ordinary scalar RAM | Every direct Arm load and store uses the backing-address authority and is followed by conservative `DMB ISH`; checked byte-array/mmap/translated/PC RAM paths enter ordinary leases, and aligned 1/2/4/8-byte Swift loads/stores use host atomics. A proven-overlap interpreter pair passes 2,000 protected-mode guest iterations each of Store Buffering, Load Buffering, Message Passing, and MFENCE substitution. | Complete IRIW, SFENCE/LFENCE, ordinary-reader/locked-writer mixtures, emitter/callback/bulk/string/DMA/shared-mapping/replay inspection, and every tier/count cell. Remove conservatism only with litmus and inspection authority. |
| TLB invalidation | A machine-scoped coordinator publishes targeted or global invalidations to every paging unit and baseline/optimizing native TLB, records a required generation per vCPU, and couples the run session to per-vCPU pending generations. Every owner can acknowledge invalidations on its worker, including maintenance while parked on a result. In addition to the external flush test, the internal interpreter pair now runs a guest protocol in which the AP fills and hits an old translation, the BSP rewrites the live PTE, the tracked write publishes a global flush, and guest `INVLPG` publishes the linear page. Both active owners acknowledge both kinds of generation before the AP observes the replacement physical page, then guest ACPI S5 joins the run. Page-table writes coalesce a global flush, and generation wrap performs a global reset. | Separate targeted and global invalidations into independent guest cells; cover local active hits and remote active interpreted/native hits; race halted, quiescing, fault, and stop states; then repeat for every tier pair. This first guest-driven interpreter cell is not full free-running TLB proof. |
| CPU SMC | Checked callbacks and protected host pages advance guest code generations; byte revalidation protects publication. Each vCPU owns private baseline/optimizing executable regions, and an executor lock spans resident lookup, native entry, invalidation, retirement, and storage rotation. A deterministic blocked-native-execution test proves invalidation cannot return while that executor is in generated code. | Add concurrent cross-vCPU mutation/fetch and publication tests. If executable storage ever becomes shared across executors, introduce an explicit epoch/hazard retirement protocol before permitting reuse. |
| DMA SMC | Current Virtio and xHCI DMA reads/writes route through `DoryPCPhysicalMemoryBus`, range-coordinated RAM, and translated-code lifetime invalidation. Tests cover overlapping exclusion, disjoint progress, and writes into protected code. | Inventory and qualify every external/shared-memory adapter, then add concurrent DMA/page-table/code mutation campaigns under free-running execution. |
| Device/shared state | Every vCPU physical-memory bus and the port-I/O bus share one machine-scoped guest-entry domain. MMIO, ECAM, PCI BAR, and port callbacks are serialized across vCPUs; ordinary RAM and DMA synchronization remain outside it. The built-in callback source-lock audit found and repaired APIC and PIC pending-work calls made under local locks. Re-entry regressions now cover APIC/PIC/PIT/UART/PS2/RTC/HPET/USB, and a two-owner guest UART loop survives concurrent host clock, input, interrupt, and power callbacks under Thread Sanitizer. The inventory and lock/callback rules are in `x86-device-shared-state-audit.md`. | Couple pause/reset/snapshot/hot-unplug/teardown to sustained all-worker quiescence, audit every public MMIO/PCI extension and future shared mapping, and pass the complete backend lifecycle matrix under sustained SMP. |
| Scheduling | `DoryPCVCPURuntime` owns one persistent host thread per vCPU for the machine lifetime; native blocks poll per-vCPU pending-work bytes, and all parallel error paths rendezvous every submitted worker before releasing machine ownership. An internal fail-closed policy admits exactly two host-monotonic interpreter owners with no caller extension devices. Both reserve disjoint global budget before a per-run rendezvous, execute bounded chunks concurrently, and join before state inspection. Default, native/mixed, extension-device, and public paths remain serial or denied. | Replace coordinator rendezvous batching with sustained owner-loop execution and all-worker quiescence; then qualify lifecycle, device, tier-pair, four-vCPU, and scaling behavior before production SMP admission. |
| Qualification | Instruction inspection covers the direct barriers; focused mixed-tier atomic, remote-invalidation, DMA-range, code-cache hazard, and built-in callback re-entry tests pass. Current head passes all 441 PC tests in 56 suites in debug, optimized release, and under Thread Sanitizer, plus 35 runner tests in 4 suites in the previously retained debug/release graph. The unchanged release groups also retain DBT 1,470/141, decode audit 135/22, firmware 48/12, and qualification 7/2 evidence. Four signed PVH workload/poweroff observations are retained for older exact commit `5c07bcf44`, not relabeled for current head. | Run the tier-pair TSO/atomic/TLB/DMA/SMC matrix on sustained workers at 1, 2, and 4 vCPUs and retain exact-candidate boot/lifecycle receipts. |

## Mandatory qualification matrix

The release campaign must exercise interpreter/interpreter, interpreter/baseline,
interpreter/optimizing, baseline/baseline, baseline/optimizing, and optimizing/optimizing pairs at
1, 2, and 4 vCPUs under both checked-callback and protected-host-page policies where applicable.
Each cell records source, binary, host, profile, policy, predictor set, and fixture hashes.

At minimum, the campaign must include:

- Store Buffering: record `r0 = 0 && r1 = 0` after `x=1; r0=y` / `y=1; r1=x` as
  **permitted** x86 Store→Load relaxation (the outcome is not required from a conservative runtime).
- Load Buffering: forbid `r0 = 1 && r1 = 1` after `r0=y; x=1` / `r1=x; y=1`.
- Message Passing: observing the publication flag forbids observing stale payload.
- IRIW: observers may not disagree on the order of independent stores.
- Locked increment/exchange/CMPXCHG families mixed with ordinary aligned readers and writers.
- Unaligned, cache-line-split, and page-split locked operands, including faulting second pages.
- `MFENCE`, `SFENCE`, `LFENCE`, and locked-operation fence substitutions.
- Page-table rewrite plus local and remote invalidation under native TLB hits.
- CPU and DMA code mutation while another vCPU repeatedly executes the affected page.
- Code-cache rotation while another vCPU holds a direct, IBTC, or shadow-return target.

Outcome counters must be deterministic where the architecture forbids an outcome; stress duration
alone is not authority. Inspection tests must additionally prove that every generated memory path
contains the intended Arm ordering primitive or calls a qualified helper. Any new emitter or memory
fast path is denied until it is present in both inspections and litmus cells.

## Activation rule

The public x86 Linux gate remains closed until every “still required” row above has code, tests, and
exact-candidate receipts. A machine-scoped coordinator removes cross-VM contention; it does not by
itself qualify free-running SMP or x86 TSO.
