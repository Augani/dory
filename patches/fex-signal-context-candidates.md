# FEX signal-context patch roles

`fex-restore-complete-signal-context.patch` is the **shipped** input selected by
`guest/initfs/vendor/fex-2607-dory1/rebuild.sh`. Its SHA-256 is
`e06507751d42ff359b2257d413fc07d145483e4739b286596c1e12d6dde45e90`.
It matches the retained FEX/FEXServer binaries and ARM64 initfs stamp.

`fex-signal-context-hostaltstack-candidate.patch` preserves the **unpromoted**
September 6 experiment formerly stored at the shipped patch path. Its SHA-256 is
`66abe2067bd469efdbeafdc3cd9862b86efc7000c70cf8ee8d4230f7a53c53f6`.
It adds explicit syscall continuation metadata, complete edited-context handling,
and host-owned alternate-stack teardown. Focused historical successes do not
close default Go preemption: the retained candidate also fails that workload.

Apply either signal patch, never both, after the pinned container-isolation and
ProcessorID patches to upstream commit
`1cc4b93e7a71c883ec021b71359f136394dc1f3c`. Both complete sequences were checked
against that revision. The candidate is deliberately absent from production
input fingerprints and rebuild selection. A16 requires default-mode regression,
adjacent application, reproducible build and rollback evidence before promotion.

Historical receipts retain their original paths and hashes. Resolve their patch
identity by hash: do not rewrite historical evidence to reflect this filename
separation. This change restores the existing production source binding; it does
not repair the remaining asynchronous signal-publication defect.
