# x86 device and shared-state concurrency audit

Status: **machine and built-in callback boundaries implemented; lifecycle and external-adapter
qualification open**

Implementation checkpoint: `d35b9a62c` on 2026-09-20. This document is a source inventory and
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
| Local APIC and I/O APIC windows | MMIO | Machine domain at the bus; wrapper and APIC models use local locks. Direct injection, timer expiry, interrupt-command, and EOI callbacks route only after local state is snapshotted and the source lock is released. Direct and timer callback re-entry regressions inspect APIC state synchronously. | Exercise simultaneous IPI, EOI, timer, reset, and quiescence throughout sustained owner execution. |
| HPET | MMIO | Machine domain for registers; model-local lock for clock/timer state; the interrupt route is snapshotted under the local lock and invoked afterward. A callback re-entry regression synchronously inspects HPET state. | Extend concurrent comparator-write and clock-advance coverage through reset and teardown. |
| PCI ECAM and BAR window | MMIO | Machine domain spans route resolution and target callback. ECAM/BAR attachment tables are sealed; PCI configuration, MSI-X, and function models retain local locks. | Audit every admitted function's configuration/BAR lock order and hot-unplug/reset behavior. |
| Virtio PCI block, entropy, network, GPU, input, and sound | PCI BAR/ECAM plus DMA | Machine domain for guest register access. The transport has a state lock, per-queue recursive processing locks, generation-scoped deferred completions, and range-coordinated guest memory. | Run reset/reconfigure/completion/interrupt races under sustained SMP for every backend; prove callbacks are made after configuration locks are released. |
| xHCI and USB HID/UVC | PCI BAR plus DMA | Machine domain for guest registers. xHCI and USB models have local locks; transfer handlers are snapshotted and invoked outside those locks, transfer context writes use coordinated guest memory, and DMA synchronization is outside the machine device domain. HID/UVC handler re-entry and xHCI disconnect/reset/in-flight races are covered. | Expand the campaigns to concurrent vCPU MMIO, repeated attachment lifecycle, and code/page-table DMA targets. |
| PIC, ELCR, PIT, system-control port, RTC, UART, PS/2 controller | Port I/O | Machine domain spans routing and the port callback. Each mutable model has a local lock. PIC pending-work publication and PIT/RTC/UART/PS2 interrupt sinks now invoke only after releasing the source lock; synchronous state-re-entry regressions cover each path. A two-owner guest UART loop survives 512 concurrent host clock, input, APIC, and power publications. | Extend the bounded campaign through pause, reset, snapshot, and teardown during sustained owner execution. |
| ACPI PM event/control/timer and reset ports | Port I/O | Machine domain for guest access; `DoryPCPowerController` owns mutable lifecycle state under a local lock, snapshots publication, and invokes pending work afterward. Concurrent-pair async poweroff joins both owners. | Couple reset, snapshot, and teardown to all-worker quiescence and prove no callback survives lifecycle generation changes. |
| PCI INTx and MSI delivery | Callback from PCI models | INTx aggregation and APIC targets use local locks; sinks and target identifiers are snapshotted before cross-device calls, and pending-work publication is generation based. This path does not rely on the guest device domain. | Cover simultaneous MSI/INTx mode changes, reset, and teardown throughout sustained owner execution. |
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

The internal two-vCPU interpreter qualification policy enforces this boundary in code: admission
fails closed when either caller-supplied collection is non-empty. The built-in callback source-lock
audit below does not qualify any extension, direct shared mapping, or future backend adapter.

## Evidence at this checkpoint

- The complete PC target passes 440 tests across 56 Swift Testing suites in debug and optimized
  release modes. The pinned Linux integration test is separately skipped when its four artifact
  environment variables are absent; that skip is not boot evidence.
- The complete current 440-test PC target passes under Thread Sanitizer with no race report. This
  includes the device-domain, physical-memory, port-I/O, PCI, Virtio, xHCI, APIC, translation,
  concurrent run-session, and new guest-code litmus suites rather than only the older 99-test
  device subset.
- Source review confirms that HPET, RTC, PIT, UART, PS/2, power, USB HID/UVC, multiprocessor
  routing, I/O APIC routing, PCI MSI/MSI-X/INTx, Virtio ready/reset, GPU display, and xHCI device
  calls snapshot cross-component work before invoking it outside their local locks. The review
  found two exceptions: local-APIC pending-work publication and PIC pending-work publication ran
  under their source locks. Both now release the lock first and have synchronous re-entry tests.
- Focused callback regressions cover direct and timer APIC publication, PIC and PIT publication,
  UART, PS/2, RTC, HPET, and USB HID/UVC handlers. An admitted two-owner interpreter machine also
  executes real UART guest I/O while 512 host iterations inject UART/PS2 input, advance PIT/RTC/HPET,
  and publish per-vCPU APIC work before asynchronous poweroff joins both owners. The same test
  passes under Thread Sanitizer.
- Deterministic tests prove one machine serializes MMIO against port I/O across separate vCPU bus
  views, ordinary RAM remains live, independent machines do not contend, synchronous nested
  routing is reentrant, and DMA synchronization cannot be blocked by a guest device callback.
- Existing Virtio/xHCI tests cover generation-scoped deferred completion, reset and disconnect
  races, range-authority overlap/disjoint behavior, and translated-code invalidation.

## Promotion rule

This checkpoint supplies the conservative guest-entry boundary and the built-in callback
source-lock audit used by the narrow internal interpreter pair. It does not complete package D or
authorize pair promotion. Package D closes only after pause/reset/snapshot/hot-unplug/teardown are
coupled to sustained all-worker quiescence, every admitted extension has a reviewed callback graph,
the complete two-vCPU lifecycle race matrix passes, and the exact candidate has retained TSan and
lifecycle receipts. Until then, extension-device SMP, general multiprocessor promotion, and the
public x86 Linux gate remain closed.
