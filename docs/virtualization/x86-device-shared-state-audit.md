# x86 device and shared-state concurrency audit

Status: **machine boundary implemented; asynchronous and external-adapter qualification open**

Implementation checkpoint: `376846fd9` on 2026-09-20. This document is a source inventory and
admission contract, not a release claim. It covers objects reachable from
`DoryPCPhysicalMemoryBus` and `DoryPCPortIOBus` in `DoryPCDirectKernelMachine` and records the work
that remains before general free-running SMP may use them.

## Machine boundary

Every physical-memory view owned by one machine and that machine's port-I/O bus share one
`DoryPCDeviceAccessCoordinator`. Guest CPU entry into MMIO, ECAM, PCI BAR, and port-I/O callbacks is
therefore serialized across all vCPUs. Ordinary RAM, native locked RAM helpers, DMA validation and
copying, and direct host-address translation do not take this domain; they continue to use the
machine's backing-address range authority.

The device domain is recursive only for synchronous routing inside one guest access. It is not a
general permission to introduce cycles. A callback may synchronously route another device access,
but it may not wait for work that requires a device-local lock it still holds.

Memory `synchronize()` deliberately remains outside the device domain. Virtio and xHCI use the same
guest-memory interface to publish DMA. Requiring the device domain for publication can deadlock
when a guest device access waits for an asynchronous transfer while its completion or disconnect
path needs to synchronize RAM. The full PC suite caught this exact xHCI cycle; the retained
regression proves that DMA publication can complete while a guest MMIO callback is blocked.

## Lock and callback order

The following rules replace an ambiguous assumption that all locks form one freely nestable list:

1. The run-session metadata lock is isolated. It is never held while calling a device, resolving a
   route, taking RAM authority, entering generated code, or publishing an interrupt.
2. A guest MMIO/PIO entry takes the machine device domain before invoking a device model. Port
   routing takes and releases its configuration lock inside that domain. Physical routing uses an
   immutable sealed snapshot and holds no routing lock when it enters the domain.
3. A device may take its own local state lock while entered through the machine domain. It must
   snapshot callbacks and configuration, release that local lock, and only then call another
   device, wait for a backend, acquire RAM range authority, or publish an interrupt.
4. DMA completely validates its ranges before acquiring backing-address leases. It publishes bytes
   and translated-code invalidation before a used-ring update, completion event, MSI, INTx, or
   legacy interrupt becomes observable.
5. Executable-code protection/generation work follows RAM range authority. No device or route lock
   may be acquired while code-lifetime authority is held.
6. `synchronize()`, backend completion, clock advancement, host input, USB connect/disconnect,
   snapshot, and diagnostic entry do not inherit the guest device domain. Their model-local locks
   and callback order must therefore be independently audited and tested.

No new callback may acquire an earlier authority while holding a later one. A new route or adapter
is denied by default until its order is documented here and represented in the concurrency tests.

## Built-in inventory

| Reachable object | Guest route | Current authority | Remaining qualification |
| --- | --- | --- | --- |
| Firmware configuration and firmware flash | Platform MMIO | Immutable after construction; guest entry also uses the machine domain. Flash bytes are installed as read-only host mappings. | Keep future writable firmware variables outside this classification until they have explicit persistence and concurrency ownership. |
| Local APIC and I/O APIC windows | MMIO | Machine domain at the bus; wrapper and APIC models use local locks. Interrupt-command and EOI callbacks route only after local state is snapshotted. | Exercise simultaneous IPI, EOI, timer, reset, and quiescence on free-running workers. |
| HPET | MMIO | Machine domain for registers; model-local lock for clock/timer state; interrupt sink reaches PIC/I/O APIC. | Prove callback-after-unlock ordering under concurrent clock advancement and comparator writes. |
| PCI ECAM and BAR window | MMIO | Machine domain spans route resolution and target callback. ECAM/BAR attachment tables are sealed; PCI configuration, MSI-X, and function models retain local locks. | Audit every admitted function's configuration/BAR lock order and hot-unplug/reset behavior. |
| Virtio PCI block, entropy, network, GPU, input, and sound | PCI BAR/ECAM plus DMA | Machine domain for guest register access. The transport has a state lock, per-queue recursive processing locks, generation-scoped deferred completions, and range-coordinated guest memory. | Run reset/reconfigure/completion/interrupt races under sustained SMP for every backend; prove callbacks are made after configuration locks are released. |
| xHCI and USB HID/UVC | PCI BAR plus DMA | Machine domain for guest registers. xHCI and USB models have local locks; transfer context writes use coordinated guest memory. DMA synchronization is outside the machine device domain. | Expand disconnect/reset/in-flight-transfer campaigns to concurrent vCPU MMIO, host input, and code/page-table DMA targets. |
| PIC, ELCR, PIT, system-control port, RTC, UART, PS/2 controller | Port I/O | Machine domain spans routing and the port callback. Each mutable model has a local lock; interrupt sinks reach PIC/I/O APIC after model state changes. | Qualify simultaneous clock/input/port access and interrupt deassertion under free-running workers. |
| ACPI PM event/control/timer and reset ports | Port I/O | Machine domain for guest access; `DoryPCPowerController` owns mutable lifecycle state under a local lock and publishes pending work. | Couple power/reset publication to all-worker quiescence and prove no callback survives teardown. |
| PCI INTx and MSI delivery | Callback from PCI models | INTx aggregation and APIC targets use local locks; pending-work publication is generation based. This path does not rely on the guest device domain. | Prove sink callbacks never run under a source lock that can be reacquired through EOI/reset and cover simultaneous MSI/INTx mode changes. |
| Physical and port route tables | MMIO/PIO dispatch | Construction locks plus sealed topology. Physical mappings publish an immutable snapshot; port resolution uses a short configuration lock and releases it before the callback returns. | If runtime hot-plug changes these tables, replace the construction-only model with an explicit versioned snapshot protocol. |

## External and extension boundaries

`platformMMIODevices` and `pciFunctions` are public extension points. The machine domain serializes
their guest CPU callbacks, but it cannot make their host/backend callbacks, direct shared mappings,
or private DMA thread-safe. An extension is not SMP-admissible until it supplies all of the
following:

- a complete callback/lock graph showing that no callback escapes while a configuration lock is
  held;
- DMA exclusively through `DoryPCPhysicalMemoryBus` or another adapter proven to share the exact
  `DoryX86MemoryAccessCoordinator` backing-address coordinate system;
- translated-code generation revocation before modifying executable bytes;
- page-table invalidation publication when DMA changes translation structures;
- completion/interrupt publication after DMA visibility; and
- reset, cancellation, hot-unplug, quiescence, and teardown tests under Thread Sanitizer.

The current direct-kernel x86 path exposes no independent writable host mapping adapter outside
the physical bus. `DoryPCDirectKernelMachine.invalidateCodePage(at:)` is an explicit future-facing
invalidation hook, not proof that an arbitrary mapping uses it correctly. Any future shared-memory,
file-backed, graphics, camera, or passthrough adapter remains denied until it satisfies this
section.

## Evidence at this checkpoint

- The complete PC target passes 401 tests across 53 Swift Testing suites in debug mode. The pinned
  Linux integration test is separately skipped when its four artifact environment variables are
  absent; that skip is not boot evidence.
- The device-heavy Thread Sanitizer matrix passes 99 tests across device-domain, physical-memory,
  port-I/O, PCI, Virtio, xHCI, and APIC suites with no race report.
- Deterministic tests prove one machine serializes MMIO against port I/O across separate vCPU bus
  views, ordinary RAM remains live, independent machines do not contend, synchronous nested
  routing is reentrant, and DMA synchronization cannot be blocked by a guest device callback.
- Existing Virtio/xHCI tests cover generation-scoped deferred completion, reset and disconnect
  races, range-authority overlap/disjoint behavior, and translated-code invalidation.

## Promotion rule

This checkpoint supplies the conservative guest-entry boundary required before general
two-vCPU execution. It does not complete package D by itself. Package D closes only after every
built-in asynchronous path and every admitted extension has a reviewed callback graph, the
free-running two-vCPU race matrix passes, and the exact candidate has retained TSan and lifecycle
receipts. Until then, general multiprocessor guest execution and the public x86 Linux gate remain
closed.
