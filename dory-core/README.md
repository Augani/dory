# dory-core

The Rust workspace for the Dory re-platform (see [../docs/architecture/rust-sidecar.md](../docs/architecture/rust-sidecar.md)).
It holds the shared wire protocol, the guest agent, the host-side docker dataplane, and the UniFFI
staticlib the Swift `doryd`/`dory-vmm` link. The two seams of the design are both proven here.

## Crates

| Crate | Runs on | Purpose | Status |
|---|---|---|---|
| `proto` (`dory-proto`) | host + guest | the one wire protocol: `frame` (LE u32, 16 MiB, **timeout ≠ corruption**), `mux` (single-writer + id-router request/response), `half_close` (asymmetric SHUT_WR splice), `handshake` (versioned Hello), `channels` (port catalog), `preamble` (forward frame) | ✅ built, 16 tests |
| `pb` (`dory-pb`) | host + guest | **seam 1**: the one `.proto` (agent RPC + control API), `prost`-generated; Swift consumes the same via `swift-protobuf` | ✅ built, 4 tests |
| `agent` (`dory-agent`) | **guest** (static-musl) | PID-1 agent: vsock mux server (RPC dispatch: clock/info/ports) + docker byte-stream bridge | ✅ built; dispatch tested on host, vsock server cross-compiles arm64+x86_64 musl |
| `dataplane` (`dory-dataplane`) | host | docker proxy logic: `http_head`, `classify` (passthrough/hijack/create-rewrite), `create_rewrite` (loopback HostIp, host-gateway ExtraHosts, `--gpus`) | ✅ built, 15 tests |
| `ffi` (`dory-ffi`) | host | **seam 2**: UniFFI staticlib (control-only: config/fds/stats, never data-plane bytes). Exposes `startDataplane(listenFd, dockerdSocketPath, gpuSupported)` and the docker-tier `startDataplaneForward(listenFd, forwardSocketPath, cid, port, gpuSupported)` — the real fd-handover serves. | ✅ built, 5 tests; Swift bindings generated + a Swift consumer compiled & run against the staticlib; both fd-passing serves are tested end-to-end |

The `full_rpc_spine_over_mux` test in `agent` composes handshake → mux → dispatch → protobuf over an
in-memory connection — the whole RPC path, minus the vsock transport.

## What's proven

- **The `malformedFrame` wedge is gone by construction**: a stalled peer yields a caller-side
  `Elapsed`, never a frame error; concurrent RPCs are id-routed through one writer, so responses
  never interleave. (`proto::frame`, `proto::mux` tests.)
- **docker attach won't truncate**: the half-close splice preserves per-direction `SHUT_WR` over
  unix and (verified in `../spikes/`) vsock streams.
- **Both seams**: protobuf messages round-trip (seam 1); Swift calls the Rust staticlib end-to-end
  (seam 2).

## Build

```sh
cargo test --workspace            # all unit + integration tests
cargo clippy --workspace --all-targets -- -D warnings

# guest agent (Linux, static musl) — full link needs a musl cross-toolchain or a Linux CI runner:
cargo check -p dory-agent --target aarch64-unknown-linux-musl
cargo check -p dory-agent --target x86_64-unknown-linux-musl

# regenerate the Swift bindings (seam 2):
cargo build -p dory-ffi
cargo run -p dory-ffi --features bindgen --bin uniffi-bindgen -- \
  generate --library target/debug/libdory_ffi.dylib --language swift --out-dir ffi/generated
```

## Not yet built (integration, next sessions)

- `remote` crate (russh SSH transport + chunked sync + reconciler).
- The Swift side: `doryd` (control plane, launchd) and `dory-vmm` (VZ per-VM, embeds the dataplane
  via FFI, owns the captive vsock fds). The `startDataplane(listenFd, …)` /
  `startDataplaneForward(listenFd, …)` FFI entries are **done** (see `ffi`), and `dory-hv` now
  serves the matching `--agent-vsock-forward` listener (preamble → fresh guest vsock stream, tested
  in `DoryHVTests/AgentVsockForwardTests`); what remains is the production Swift caller in
  doryd/dory-vmm and the on-hardware integration run (docker run/exec/pull/build through
  dory.sock → dataplane → forward → guest dockerd).
- VZ VM boot + a guest rootfs running `dory-agent` as PID 1; the big-bang cutover checklist.
