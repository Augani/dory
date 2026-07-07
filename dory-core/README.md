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
| `remote` (`dory-remote`) | **host** (doryd) | agent RPC over SSH: `AgentClient` (transport-agnostic handshake+mux+pb typed RPC) + `ssh` (russh 0.54 connect/key-auth/tunnel via direct-streamlocal or direct-tcpip; mandatory `HostKeyPolicy`). The same protobuf protocol that rides vsock rides an SSH channel. | ✅ built, 6 tests incl. a full in-process real-russh loopback (info RPC over SSH) + host-key-rejection; host-only, not in the guest musl build |

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

## Proven on hardware (2026-07-07)

The docker-tier spine ran end-to-end on a real VM: docker CLI → `dory.sock` → dataplane
(`examples/forward_serve`) → `ForwardBackend` preamble → `dory-hv --agent-vsock-forward` → guest
vsock 1026 → `dockerd`. Verified byte-exact: `version`/`ps`, `run --rm` (attach half-close), `-i`
stdin-EOF streaming, a full `pull`, `exec` on a running container (hijack mid-connection), and —
after the keep-alive fix below — `--gpus` answered by the dataplane's 501 and a real `docker
create -p 127.0.0.1:…` stored in the daemon with `HostIp` emptied **and** both host-gateway
`ExtraHosts`, all through the CLI's pooled connection.

Two integration-found bugs, both fixed with regression tests:
- **Keep-alive classification gap**: the serve loop classified only the first request per
  connection, then spliced raw — a create reused after `GET /_ping` bypassed create-rewrite/GPU
  gating. Now every request head is classified (lazy backend dial, blind response pump, raw splice
  only on hijack/chunked-tail).
- **`"ExtraHosts": null`**: the Go CLI marshals an empty list as explicit `null`, which
  `entry().or_insert_with()` kept, silently skipping the host-gateway injection.

The *legacy* Go-agent RPC (port 1024) wedged with `malformedFrame` in 2 of 3 runs (port-watch
polling, minutes into uptime; even the guest shutdown listener died) — field evidence for the
cutover; the Rust path stayed healthy throughout.

## Not yet built (integration, next sessions)

- **`remote` sync half** — the russh transport + `AgentClient` are built (above); the
  **chunked/resumable file sync + reconciler** are deferred pending decision **D5** (conflict policy
  + resumability semantics) in `../docs/architecture/rust-sidecar.md §15`. The transport is the
  unblocked foundation they build on.
- **`dory-agent` daemon mode** — the agent's mux/dispatch server currently binds vsock only; the VPS
  daemon needs the same server over a TCP/unix listener (the socket `remote`'s `direct-streamlocal`
  tunnels to). Small: reuse `serve_control`'s handshake+`Mux::start(dispatch)` on a `TcpListener`.
- The Swift side: `doryd` (control plane, launchd) and `dory-vmm` (VZ per-VM, embeds the dataplane
  via FFI, owns the captive vsock fds). The `startDataplane(listenFd, …)` /
  `startDataplaneForward(listenFd, …)` FFI entries are **done** (see `ffi`), and `dory-hv` now
  serves the matching `--agent-vsock-forward` listener (preamble → fresh guest vsock stream, tested
  in `DoryHVTests/AgentVsockForwardTests`); what remains is the production Swift caller in
  doryd/dory-vmm and the on-hardware integration run (docker run/exec/pull/build through
  dory.sock → dataplane → forward → guest dockerd).
- VZ VM boot + a guest rootfs running `dory-agent` as PID 1; the big-bang cutover checklist.
