# Phase 0A JIT entitlement and publication probe

`dory-jit-probe` is the isolated executable used to validate ADR-008 before DoryDBT exists. It is
not an emulator, a production translator, or release qualification by itself.

The probe has no Dory, Foundation, or dynamic-plugin dependency. Its signed callback is fixed at
link time and validates every caller-controlled pointer, size, alignment, generation, and output
value before writing. A successful schema-2 result proves all of the following in one process:

- exactly one quota-bound `MAP_JIT` code page between two inaccessible guard pages;
- `com.apple.security.cs.allow-jit` and
  `com.apple.security.cs.jit-write-allowlist` with hardened runtime and without disabled library
  validation or unsigned-executable-memory entitlement;
- publication only through the statically allowlisted `pthread_jit_write_with_callback_np`
  callback, followed by `sys_icache_invalidate` and a release-published generation;
- rejection of null, undersized, outside-region, misaligned, and stale-generation contexts;
- four concurrent readers and 1,000 guarded slot-reuse generations with no stale execution;
- executable-mode direct writes and both guard-page reads fault in child processes while the
  owning process retains and executes the current published generation.

The standalone probe intentionally does not request `com.apple.security.app-sandbox`. That
entitlement requires an application/container identity and causes a non-bundled command to be
terminated by `libsecinit` before `main`. The eventual DoryDBT runner still requires its separately
reviewed process sandbox; this probe proves only the narrow hardened-runtime JIT contract.

## Qualification boundary

The current physical result is recorded in
[`phase-0a-jit-probe-engineering-evidence-2026-08-30.json`](phase-0a-jit-probe-engineering-evidence-2026-08-30.json).
It passed 100 consecutive Developer-ID-signed runs on the recorded Apple-silicon host. Gatekeeper
correctly reports `Unnotarized Developer ID`, so ADR-008 and the Phase 0A stop gate remain open.

The stop gate closes only when the exact candidate is notarized and passes this probe on every
frozen minimum host OS and physical host tier. A local signature, a beta-host result, or this
source-controlled evidence record must never be presented as release qualification.
