# x86_64 qualification inputs

This directory owns the source recipes used to produce Dory's x86_64 Linux qualification
fixtures. The recipes are source inputs, not release evidence and not guest artifacts. Generated
kernels, initrds, firmware images, installer media, and disks remain outside Git and enter a
qualification campaign only through a validated
`DoryPCX86QualificationFixtureManifest` and the content-addressed fixture importer.

`Fixtures/` contains the deterministic PVH workloads previously stored under the deleted virtual
workspace guest tree. Their build-sensitive files were migrated byte-for-byte so their pinned
SHA-256 values and deterministic archive outputs remain reproducible. Documentation paths were
updated to the qualification-owned location.

The fixture producer rejects missing or changed inputs, verifies every upstream and derived digest,
and never treats construction as boot qualification. A runner receipt must separately bind the
manifest digest, source commit and dirty-tree state, release executable digest, host class, CPU
profile, execution tier, JIT policy, predictors, vCPU count, memory, and guest result.
