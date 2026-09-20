# x86 free-running vCPU implementation plan

Status: **approved engineering sequence; not yet a release claim**

Implementation checkpoint (2026-09-20): commit `ab0268045` adds the isolated
`DoryPCRunSession` foundation and eleven debug/optimized/Thread-Sanitizer protocol tests. Commit
`fc6ab7fd8` closes the current serialized dispatcher's native pending-byte lost-clear race with a
generation-coupled publication/acknowledgement boundary and four deterministic race tests. The
session remains intentionally unwired; packages B-G and the remainder of package A below are open.

This plan converts the existing machine-lifetime host workers into a real multiprocessor runtime
without weakening deterministic replay, memory ordering, translation invalidation, device safety,
or failure ownership. It is subordinate to `x86-smp-memory-contract.md`: completing a work package
below does not qualify SMP until the mandatory matrix passes.

## Current boundary

`DoryPCVCPURuntime` owns one persistent host thread per vCPU, but
`DoryPCDirectKernelMachine.run` still chooses a processor, submits one bounded execution slice,
waits for it, mutates clocks/devices/lifecycle state centrally, and repeats. The only overlapping
path admits one frozen register-only instruction per vCPU. That path proves host-thread overlap,
not a Linux SMP runtime.

The following foundations already exist and must be preserved:

- per-vCPU architectural state, interpreter, paging unit, translated-memory view, baseline JIT,
  optimizing JIT, native TLB, executable region, and pending-work byte;
- machine-scoped ordinary/locked backing-range coordination and fail-closed direct mapping;
- machine-scoped translation invalidation publication with required/acknowledged generations;
- current Virtio/xHCI DMA routing through coordinated PC RAM and code-lifetime invalidation;
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

Progress: the isolated metadata core and its concurrency proofs are complete. Before package A is
closed, the production worker command protocol still needs run identity, result mailboxes,
run-local counter merge ownership, and explicit coordinator/worker quiescence handoff. No public
or guest execution path uses the session yet.

### B. Single-vCPU long-running cutover

Run one vCPU through the new worker loop while retaining the existing coordinator for clocks and
events. Require byte-identical architectural outcomes and stop reasons across interpreter,
baseline, and optimizing tiers. Repeat the PVH campaign before admitting more than one vCPU. This
isolates protocol/lifecycle regressions from SMP memory failures.

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

### D. Device and shared-state concurrency audit

Inventory every object reachable from `DoryPCPhysicalMemoryBus` and `DoryPCPortIOBus`. Record for
each operation whether it is immutable, per-vCPU, internally locked, or protected by the new
machine device domain. Add synchronization before enabling general parallel memory operands.

The lock order is fixed:

1. run-session metadata;
2. device-local or machine device-domain lock;
3. physical-memory route snapshot;
4. RAM range lease;
5. code-lifetime generation/protection operation.

No callback may acquire an earlier level while holding a later one. DMA copies must release device
configuration locks before waiting on RAM range authority; completion/interrupt publication occurs
after DMA bytes and code-generation invalidation are visible.

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

No commit may enable a pair, vCPU count, predictor, profile, or public product path before its own
evidence lands. Historical receipts never substitute for the exact implementation candidate.
