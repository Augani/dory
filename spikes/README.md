# Pre-code spikes for the VZ + Rust re-platform

De-risking proofs for [../docs/architecture/rust-sidecar.md](../docs/architecture/rust-sidecar.md). All three are GREEN.

## 1. Memory (§9) — SETTLED: keep `dory-hv` for the docker tier

Not a code spike; settled by SDK inspection + field evidence (2026-07-07):
- macOS 27 VZ ships **only** `VZVirtioTraditionalMemoryBalloonDevice` — one `targetVirtualMachineMemorySize` knob, no free-page reporting at any version.
- Lowering the target does **not** drop the host VM-process RSS (Lima measured 1731→1748 MB up; Apple Feedback FB22614752; Apple `container` docs: freed pages "are not relinquished to the host"). Stock VZ returns ≈0 passively; only VM stop/restart frees host RAM.
- `dory-hv`'s free-page-reporting returns it live (`net 370 MiB` reclaim gauge; 1.0 vs 1.6 GB A/B). OrbStack proves reclaim-on-VZ is possible but only via its own bespoke dynamic-memory layer.
- **Decision:** `dory-hv` (free-page reporting) for the docker shared-VM tier; VZ per-VM for machines.

## 2. Half-close (`spikes/half-close`) — PASS

`cargo run` (native macOS). Drives the docker-attach pattern — client writes stdin, `shutdown(SHUT_WR)`, keeps reading; peer replies *after* the half-close — through both `tokio::io::copy_bidirectional` and a hand-rolled per-direction splice over `UnixStream`.

```
PASS  copy_bidirectional: half-close preserved; post-half-close reply delivered in full
PASS  manual_splice: half-close preserved; post-half-close reply delivered in full
```

Finding: modern tokio (1.95) `copy_bidirectional` is correct — the "collapses both directions on either EOF" concern was stale behavior. A 5 s timeout guards against a silent hang counting as pass. The manual splice is the proven fallback if a future stream type's `poll_shutdown` misbehaves.

## 3. vsock (`spikes/vsock`) — PASS (`cargo check`, guest targets)

AF_VSOCK is Linux-only, so this is `cargo check` for the guest musl targets (running needs a VZ guest). Proven:
- **Cross-compiles to both guest arches:** `aarch64-unknown-linux-musl` + `x86_64-unknown-linux-musl` — 2/2 check OK with `tokio-vsock 0.7.2`.
- **API covers both directions:** `VsockListener::bind/accept` (host→guest: docker 1026, control 1024) and `VsockStream::connect(VMADDR_CID_HOST)` (guest→host dial-back: AI bridge). `VMADDR_CID_HOST`/`VMADDR_CID_ANY` present.
- **Spliceable:** `VsockStream` implements `AsyncRead`/`AsyncWrite` (`tokio::io::split`/`copy` compile), so it drops into `copy_bidirectional` like a unix socket.
- **Half-close survives the vsock hop:** tokio-vsock's `AsyncWrite::poll_shutdown` calls `shutdown(std::net::Shutdown::Write)` = a real socket `SHUT_WR` (verified in crate source `stream.rs:263`, `split.rs:57`). VsockStream also exposes an inherent synchronous `shutdown(Shutdown)` for explicit control.

Caveats (not blockers):
- **Runtime connect under VZ** (guest AF_VSOCK ↔ host `VZVirtioSocketDevice`) is not exercised here — but the current Go agent already does AF_VSOCK successfully under the custom VMM, and under VZ it is standard Linux AF_VSOCK + `VZVirtioSocketDevice`. Confirm on the first real guest bring-up.
- **Full static link** needs a musl cross-linker (or a Linux CI runner / `cross`); `cargo check` proves the crate + API + platform. Wire the guest-agent build in CI on Linux.

## Verdict

The one hard fork (memory) is decided; the two engineering unknowns (half-close truncation, vsock crate/target/API) are proven. Nothing architectural remains blocking — the rest is implementation.
