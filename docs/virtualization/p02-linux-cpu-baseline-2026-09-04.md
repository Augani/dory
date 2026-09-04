# P02 Linux CPU baseline

Dory's first supported Linux CPU level is the x86-64 psABI baseline. The
qualification identifier is
`p02-linux-cpu-baseline-selected-profiles-2026-09-04`, and it applies only to
the exact `dory.x86_64.compat-v1` and
`dory.x86_64.intel-compatible-v1` profile values. A profile with the same name
and a different capability, address-width, clock, or identity envelope does
not inherit this qualification.

The executable requirement table covers CMOV, CX8, x87, FXSR, MMX, SSE and
SSE2 advertisement. It audits OSFXSR and SCE separately as guest-controlled
CR4 and IA32_EFER gates, following the x86-64 psABI micro-architecture-level
table. The Linux boot runner accepts only profiles carrying this exact
evidence-bound baseline assessment.

The retained evidence consists of the current source-level baseline contract
and feature-policy regressions together with the independently validated
[selected-profile probes](evidence/p02-correctness-2026-09-04/selected-paging-profile-probes-through-run-62-validation.json).
Those probes bind two different Linux kernels and musl/glibc userspace archives
to the two selected profiles, require exact workload receipts, and reach
host-observed ACPI S5. Earlier evidence correctly left P02-10 open because no
executable Linux ISA-level contract or qualification policy existed at that
source revision; this policy supplies that missing boundary without changing
the retained probe results.

This qualification is limited to Dory's one-vCPU Linux guest contract and its
selected profiles. It does not identify a physical Intel processor, qualify a
release, or establish complete distribution, multi-vCPU, optimizing-JIT,
performance, or physical-reference coverage.

Neither selected profile qualifies as x86-64-v2. Both advertise CX16 and
LAHF/SAHF, but intentionally omit POPCNT, SSE3, SSSE3, SSE4.1 and SSE4.2. A
synthetic profile advertising every feature remains unqualified because CPUID
advertisement alone is not semantic evidence. x86-64-v3 and AVX-512 remain
outside this supported baseline.
