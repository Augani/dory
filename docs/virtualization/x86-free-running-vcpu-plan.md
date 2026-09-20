# x86 free-running vCPU implementation plan

Status: **approved engineering sequence; not yet a release claim**

Implementation checkpoint (2026-09-20): commit `376846fd9` builds on package B's production
single-vCPU cutover. The owning worker now drains that vCPU's events, interrupt/NMI delivery,
pending-work generation, and translation invalidation, including maintenance while parked on a
published result. Every vCPU physical-memory view and the port bus also share a conservative
machine device domain. The complete PC target passes 401 tests in 53 suites, and the device-heavy
Thread Sanitizer matrix passes 99 tests in 9 suites. The retained clean signed PVH evidence still
belongs to exact commit `298d6668e`; it has not been relabeled as current-head evidence. Packages C
and D have implemented foundations but remain open for multi-worker and asynchronous-backend
qualification; packages E-G remain open, and requests above one vCPU still use the bounded legacy
scheduler.

This plan converts the existing machine-lifetime host workers into a real multiprocessor runtime
without weakening deterministic replay, memory ordering, translation invalidation, device safety,
or failure ownership. It is subordinate to `x86-smp-memory-contract.md`: completing a work package
below does not qualify SMP until the mandatory matrix passes.

## Current boundary

`DoryPCVCPURuntime` owns one persistent host thread per vCPU. With one vCPU,
`DoryPCDirectKernelMachine.run` submits one run-session worker loop. The worker owns processor
events, interrupt/NMI delivery, and translation acknowledgement; the coordinator services clocks,
machine lifecycle, device work, and exact result/directive handoffs. A parked owner remains
available for maintenance without advertising architectural idleness. With more than one vCPU the
runtime still chooses a processor, submits bounded execution, waits, and repeats. The only
overlapping multiprocessor path admits one frozen register-only instruction per vCPU; that proves
host-thread overlap, not Linux SMP.

The following foundations already exist and must be preserved:

- per-vCPU architectural state, interpreter, paging unit, translated-memory view, baseline JIT,
  optimizing JIT, native TLB, executable region, and pending-work byte;
- machine-scoped ordinary/locked backing-range coordination and fail-closed direct mapping;
- machine-scoped translation invalidation publication with required/acknowledged generations;
- current Virtio/xHCI DMA routing through coordinated PC RAM and code-lifetime invalidation;
- one machine-scoped recursive device-entry domain shared by every vCPU MMIO view and the port bus,
  while ordinary RAM and DMA synchronization remain outside that domain;
- private executable storage whose executor lock spans native entry, invalidation, retirement, and
  rotation; and
- a serial deterministic clock/replay policy used by conformance tests.

## Non-negotiable invariants

1. A vCPU's architectural state, paging context, JIT context, native TLB, and executable-cache
   cursor have exactly one owning host worker while a run is active.
2. Product SMP uses host-monotonic time. Deterministic replay remains an explicit serial scheduler;
   it is never silently implemented by reducing an SMP request to coordinator slices.
3. A public operation observes the machine either running or fully quiescent. Pause, stop, reset,
   snapshot, and error return only after every worker acknowledges the same quiescence generation.
4. Pending work is generation based. Clearing a local JIT poll byte may not erase an interrupt,
   lifecycle event, invalidation, cancellation, or timer edge published concurrently.
5. A translation invalidation is acknowledged only after the target has left old native code,
   invalidated its paging/native-TLB state, and crossed an acquire boundary. Publication completes
   only after every required target acknowledges.
6. First-failure selection is deterministic and all workers are joined before the failure escapes.
   No worker may retain state, RAM authority, device callbacks, or executable-code entry after the
   execution gate is released.
7. Instruction-budget accounting never wraps and never silently overshoots. Reserved but unretired
   budget is returned when a worker yields, faults, halts, or is cancelled.
8. Device models are not presumed thread-safe. Every shared MMIO, port-I/O, configuration, DMA
   completion, and interrupt path is either independently synchronized and audited or routed
   through a machine-owned serialization domain with a documented lock order.

## Target runtime objects

### `DoryPCRunSession`

Complete and instantiate one machine-owned session per public `run` invocation. The finished type
must contain:

- an immutable run generation, exception policy, clock mode, and initial instruction budget;
- a condition-protected stop state with a documented priority order: host failure, triple fault,
  power/reset, requested cancellation, then exhausted instruction budget;
- checked instruction reservations and per-vCPU returned/retired counts;
- per-vCPU pending-work required and acknowledged generations;
- per-vCPU quiescence required and acknowledged generations;
- one result mailbox per worker plus a coordinator wake generation; and
- run-local execution and CPU-time counters merged only after quiescence.

The session lock protects metadata only. It must never call a device, acquire the RAM range
coordinator, enter generated code, or perform interrupt delivery while held.

### Persistent worker loop

Package B uses a deliberate transitional form: one vCPU stays in one worker job, but publishes an
exact result and parks while the coordinator owns clocks, events, interrupts, and lifecycle work.
Packages C and F move those per-vCPU responsibilities below the handoff boundary.

Extend `DoryPCHostWorker` with a machine-lifetime vCPU command protocol rather than repeatedly
installing closures in a single-slot mailbox. Commands are `start(session)`, `wake(generation)`,
`quiesce(generation)`, and `terminate`. A started worker loops locally:

1. observe pending-work and quiescence generations;
2. apply events owned by that processor;
3. acknowledge any required translation invalidation;
4. deliver that processor's pending interrupt/NMI at an architectural boundary;
5. reserve a bounded instruction chunk from the run session;
6. execute through its selected interpreter/JIT using only its own architectural state;
7. return unused budget and publish the execution result/counters; and
8. continue without returning ownership to the coordinator unless work requires a machine-wide
   rendezvous.

Native code continues polling the per-vCPU byte. The worker clears it only with a
compare-generation acknowledgement after draining every reason visible in that generation.

### Coordinator loop

The public `run` call keeps `DoryPCExecutionGate` ownership and becomes a control loop, not a slice
scheduler. It starts every eligible worker once, then services:

- host-monotonic clock advancement and timer publication;
- power/reset and external cancellation;
- machine-wide lifecycle transitions that explicitly request quiescence;
- device events that cannot safely run on a vCPU worker;
- completion and first-failure arbitration; and
- the all-workers-quiescent barrier before return.

The coordinator never reads or mutates live architectural state. Per-vCPU inspection happens only
after that worker acknowledges quiescence.

## Work packages

### A. Session and quiescence protocol

Add the session type and protocol tests before changing guest execution. Prove lost-wakeup
immunity, exact budget reservation/return, generation wrap behavior, first-failure stability,
idempotent stop, and all-worker acknowledgement. Keep the existing scheduler as the only caller
until these tests pass under Thread Sanitizer.

Progress: complete for the package-B handoff boundary. Run identity, exact result/directive
mailboxes, checked reservation return, stable failure/stop selection, run-local counter merge, and
coordinator/worker stop handoff are wired into the one-vCPU production path and pass the focused
debug, optimized, and Thread-Sanitizer suites. Multi-vCPU quiescence remains part of packages C/F.

### B. Single-vCPU long-running cutover

Run one vCPU through the new worker loop while retaining the existing coordinator for clocks and
events. Require byte-identical architectural outcomes and stop reasons across interpreter,
baseline, and optimizing tiers. Repeat the PVH campaign before admitting more than one vCPU. This
isolates protocol/lifecycle regressions from SMP memory failures.

Progress: implementation and promotion evidence complete at `298d6668e`. Tests prove one worker
submission and one worker thread across repeated handoffs in interpreter, baseline, and optimizing
tiers, exact budget/counter parity, monotonically advancing run generations, failure reservation
return, and stop-before-join behavior. Two clean signed exact-commit PVH runs completed all seven
userspace workloads and ACPI S5. Package B remains complete; package C progress is recorded below.

### C. Per-vCPU events and invalidations

Move `applyProcessorEvents(forProcessor:)`, interrupt/NMI delivery, and translation acknowledgement
onto the owning worker. Extend the current global generation-coupled drain/ack into per-vCPU
session generations. Page-table-write publication may originate on any worker; publication wakes
every required target and cannot complete until all target acknowledgements arrive.

Tests must cover an invalidation published while a target is:

- in interpreted code;
- in baseline and optimizing native code;
- halted waiting for an interrupt;
- entering quiescence; and
- faulting or stopping concurrently.

Progress through `9d618792e`: the single-vCPU session couples wake publication to per-vCPU pending
generations, places mutable processor state in per-vCPU slots, and routes events, interrupt/NMI
delivery, page-table invalidation acknowledgement, and parked-owner maintenance through the owner
worker. Quiescence reopens when new work races an acknowledgement. Focused debug and Thread
Sanitizer suites pass, including repeated host-clock halt/interrupt delivery. Still open: activate
this protocol for every simultaneous worker, then cover interpreted/native/halted/quiescing/fault
and stop races without coordinator-return acknowledgement.

### D. Device and shared-state concurrency audit

Inventory every object reachable from `DoryPCPhysicalMemoryBus` and `DoryPCPortIOBus`. Record for
each operation whether it is immutable, per-vCPU, internally locked, or protected by the new
machine device domain. Add synchronization before enabling general parallel memory operands.

The detailed inventory and callback rules live in `x86-device-shared-state-audit.md`. Run-session
metadata is isolated and may not be held across device or memory work. Guest entry takes the
machine domain before device-local state. Physical routing is an immutable snapshot; port routing
uses a short configuration lock. Device callbacks release local configuration locks before waiting
on backend work or RAM range authority. DMA bytes and code-generation invalidation become visible
before completion or interrupt publication. Memory synchronization stays outside the machine
device domain so asynchronous DMA can complete while guest device access is blocked.

Progress at `376846fd9`: all vCPU physical buses and the port bus share one recursive guest-entry
domain; separate machines are isolated; ordinary RAM remains concurrent; nested routing is safe;
and a full-suite-discovered xHCI MMIO/DMA lock cycle is fixed and retained as a regression. The full
PC target and a 99-test device-heavy Thread Sanitizer matrix pass. Still open: finish callback-graph
review for built-in clocks, host input, reset, deferred completion, and interrupt sinks; audit every
admitted `platformMMIODevices`/`pciFunctions` extension; and pass the same matrix under sustained
two-vCPU execution.

### E. General two-vCPU execution

Delete the frozen register-only admission restriction only after packages A-D pass. Start with the
interpreter/interpreter pair, then baseline/baseline, then mixed and optimizing pairs. Each new pair
is denied by default until its TSO, locked-operation, invalidation, DMA, SMC, and code-cache cells
pass. Keep raw host-address predictors disabled.

### F. Lifecycle and observability

Implement pause, resume, stop, reset, snapshot, and teardown through the same quiescence generation.
Telemetry reads immutable worker-published snapshots; it never takes architectural ownership from
a running worker. CPU-time and execution counters remain per worker and merge exactly once at run
completion. Crash/fault diagnostics identify the source vCPU and retain every worker's final
acknowledged generation.

### G. Scale and release qualification

After two-vCPU correctness, add four-vCPU execution and demonstrate at least 1.6x sustained
shared-memory throughput at two vCPUs without changing correctness policy. Run the complete matrix
from `x86-smp-memory-contract.md`, then the exact signed/notarized PVH and UEFI lifecycle campaigns
on every supported host/tier tuple.

## Required tests before each promotion

The following are promotion gates, not optional stress tests:

- Thread Sanitizer runs for session, device, APIC, translation, and lifecycle suites;
- 10,000-iteration lost-wakeup, concurrent stop/failure, and quiescence-generation tests;
- Store Buffering, Load Buffering, Message Passing, IRIW, fences, and every locked family across
  all admitted tier pairs;
- page-table rewrite plus targeted/global invalidation while remote native TLB hits are active;
- CPU and DMA mutation of an executing code page, including protected-host-page rotation;
- overlapping and disjoint RAM/DMA traffic, split-page faults, and 16-byte operations;
- pause/snapshot/reset/poweroff during interpreter fallback and native execution;
- exact instruction-budget and stop-reason checks under simultaneous worker completion; and
- repeated clean PVH boot/workload/poweroff followed by UEFI install, reboot, cold boot, update,
  shutdown, recovery, and fault injection.

## Commit sequence

Keep each step bisectable and leave the public x86 gate closed:

1. session/quiescence type plus isolated tests;
2. generation-safe pending-work drain plus tests;
3. single-vCPU worker-loop cutover and parity receipts;
4. worker-owned event/interrupt/invalidation delivery;
5. device/shared-state audit and synchronization;
6. interpreter/interpreter two-vCPU admission plus litmus tests;
7. baseline and mixed-tier admissions, then optimizing pairs;
8. four-vCPU scale, performance/SLO evidence, and lifecycle hardening; and
9. exact notarized PVH/UEFI matrix followed by a separate explicit product-policy change.

Steps 1-3 are complete. Step 4 is complete for the single-vCPU owner path but not multi-worker
activation. Step 5 has its conservative guest-entry boundary and inventory; asynchronous-path and
extension qualification remain open. Steps 6-9 have not been promoted.

No commit may enable a pair, vCPU count, predictor, profile, or public product path before its own
evidence lands. Historical receipts never substitute for the exact implementation candidate.
