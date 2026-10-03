# Local x86 memory cost report — 3 October 2026

This is a development cost report for [PLAN P2-05](PLAN.md#25-p2-05--profile-the-accepted-engine-before-redesigning-it), not desktop or release qualification. The [structured measurements](X86-MEMORY-COST-REPORT-2026-10-03.json) retain run UUIDs, executable hashes, source identity, outcomes and comparison limits. The reviewed candidate is `92050555203d22b38f26712e0dadaa982fc3f513` on Apple Silicon, macOS 27.2 and final Xcode 27.0 (27A266a), outside the frozen release matrix.

The configuration remains compat-v1, one vCPU, 1 GiB RAM, deterministic clock, baseline JIT with Tier1 emission, checked callbacks and **every raw host-target predictor disabled**. The pinned Alpine kernel/initrd, symbols and manifest are unchanged for the boot comparisons.

## Changes with observed benefit

- `0d1535500`: reuse an already normalized one-range memory lease array. One matched 120M slice improved 87.237→80.679 s (7.52%), with identical architecture, execution/timer state and JIT cumulative counters. Three interleaved uncontended lease microbenchmarks improved 26–34%; those measure only bookkeeping. Locks, writer priority, admission and multi-range coalescing remain intact.
- `6ace97242`: cache page-table tracking conformance of immutable backing memory. Mutable tracking, routes, fault handling and generation checks remain live. A first pair overlapping conformance work was slower 84.084→86.960s and is retained. Sequential after/before/after repeats were80.052 / 83.913 / 79.420 s, suggesting about 5% improvement, with lower worker CPU time. Fresh UUIDs differ; small native/interpreter attribution and repeated stop-state differences make these engineering timings rather than exact replay proof.
- `920505552`: bounded first-reply network diagnostics in the test harness. It captures at most 56 bytes between machine quanta; the watchdog publishes only cached data. Its regression test verifies bounded reads, serialization, unavailable reads and unchanged device state.

All 2,179 DBT/PC/decode Swift tests and four XCTest registrations (one opt-in skip) passed. Thirteen memory-coordinator tests passed under Thread Sanitizer; all 37 harness tests passed after correcting an initial test compile error. The current app builds for testing with signing disabled. Native Mac checks passed 232 XCTest registrations (one prepared-guest skip) and 23 Swift tests. The original portable clone/import test passed unchanged after real available storage naturally increased; no storage guard or fixture was relaxed.

The exact current executable `d77e4579d5d471febe395a4d4d04777d2dcff71a9b2a2f08f71760d8cd4cd44d` completed seven pinned Linux userspace workloads and actual ACPI S5 at 741,714,348 instructions in 573.503 s. It ran concurrently with an isolated IO guest, so this is a correctness receipt, not a whole-boot speed comparison.

**Every default 120M-instruction/120s run still stops before userspace.** Extended 1B / 900s correctness limits do not establish ordinary desktop budgets. The initial isolated IO run completed eight block rounds/flushes but failed its fixed guest Ethernet deadline after one echo; its complete success gate and host verification remain false. Neither successful boot nor host presentation alone proves an accelerated desktop.

## Ranked costs

1. **Checked writes and lease bookkeeping:** two sampled stacks contain checked-write, physical page-tracking, protocol-conformance and normalization work. The two committed changes remove redundant work here. Inclusive stack counts overlap and are not disjoint CPU shares.
2. **Short blocks with repeated validation:** the original complete receipt has 736,933,670 native instructions in 237,344,188 blocks (3.10 per block), 237,220,427 native dispatch entries and 242,174,455 code-generation checks. Translation-cache hits/misses are 139,051,021 / 65,378,169 (68.02% hits). Compile decline counts alone do not attribute executed work.
3. **Owner/worker cutovers:** 741,569 harness run calls; thread CPU reports 488.55s processor execution, 58.83s coordinator wait and 526.40s total. These categories overlap. This harness does not measure daemon/app RPC stages.

## Next three optimizations

1. Measure an atomic scalar tracked-write interface that avoids allocating a byte array. Preserve byte order/width, live tracked-page rejection, fault ordering, cross-page fallback, locking and code invalidation. Require allocation evidence plus independent memory/DMA vectors and complete userspace/IO checks.
2. Reduce repeated dispatch/generation work only within a proven bounded execution lease. Retain disabled raw predictors and cover SMC, DMA, aliases, remapping, code reclamation and pending-work boundaries before measuring guest throughput.
3. Measure bounded owner/worker batching with pending-work deadlines and deterministic clock/interrupt checkpoints preserved. Separate harness cost from daemon RPC timing; do not infer a desktop speedup from a runner microbenchmark.

Retain one-change-at-a-time comparisons and all failed receipts. Physical Mac and full installed Linux desktop/GPU campaigns still require owned prepared guests and current candidate/runtime ownership. App UI checks require the installed Dory app to quit under the repository test guard; no running user app or daemon was stopped for this report.
