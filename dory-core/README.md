# dory-core

The Rust portion of Dory's production architecture. It owns the shared host/guest wire protocol,
guest agent, host-side Docker dataplane, remote SSH/sync implementation, exact volume-transfer
helper, and the UniFFI static library linked by Swift `doryd`, `dory-vmm`, and `dory-hv`.

See [`../ARCHITECTURE.md`](../ARCHITECTURE.md) for the complete process, storage, and trust-boundary
contract. This workspace is not a sidecar or a future re-platform: its dataplane and guest protocol
are part of the shipping local engine.

## Crates

| Crate | Runs on | Purpose | Status |
|---|---|---|---|
| `proto` (`dory-proto`) | host + guest | the one wire protocol: `frame` (LE u32, 16 MiB, **timeout ≠ corruption**), `mux` (single-writer + id-router request/response), `half_close` (asymmetric SHUT_WR splice), `handshake` (versioned Hello), `channels` (port catalog), `preamble` (forward frame) | ✅ built, 16 tests |
| `pb` (`dory-pb`) | host + guest | **seam 1**: the one `.proto` (agent RPC + control API), `prost`-generated; Swift consumes the same via `swift-protobuf` | ✅ built, 4 tests |
| `agent` (`dory-agent`) | **guest** (static-musl) + **remote VPS** | lib+bin. PID-1 guest mode: vsock mux server (RPC dispatch: clock/info/ports) + docker byte-stream bridge. `--daemon <addr>` mode: the same handshake+mux+dispatch over a TCP listener (the socket doryd's `remote` SSH-tunnels to). | ✅ built; dispatch + daemon host-tested, vsock server cross-compiles arm64+x86_64 musl |
| `dataplane` (`dory-dataplane`) | host | docker proxy logic: `http_head`, `classify` (passthrough/hijack/create-rewrite), `create_rewrite` (loopback HostIp, host-gateway ExtraHosts, `--gpus`), doryd activity events for idle/wake | ✅ built, 28 tests |
| `ffi` (`dory-ffi`) | host | **seam 2**: UniFFI staticlib (control-only: config/fds/stats, never data-plane bytes). Docker tier: `startDataplane(listenFd, …)` + `startDataplaneForward(listenFd, forwardSocketPath, cid, port, …)` + activity reporting. Guest control: `connectAgentOverForward(forwardSocketPath, cid) -> AgentControl`. Remote tier: `remoteConnect(config) -> RemoteAgent` with `.info()`/`.push(localRoot, remoteRoot)` (OpenSSH keys + host-key policy in, stats out; bytes stay in Rust). | ✅ built, 8 tests incl. real in-process forward/SSH servers + agent daemon paths; Swift consumer compiled, linked against the release staticlib, and ran |
| `remote` (`dory-remote`) | **host** (doryd) | agent RPC over SSH: `AgentClient` (transport-agnostic handshake+mux+pb typed RPC) + `ssh` (russh 0.54 connect/key-auth/tunnel via direct-streamlocal or direct-tcpip; mandatory `HostKeyPolicy`) + `sync_push` (host-authoritative push driver over a `SyncTarget` trait). The same protobuf protocol that rides vsock rides an SSH channel. | ✅ built, tests incl. a full in-process real-russh loopback + host-key-rejection + real-agent-over-TCP + end-to-end sync convergence; host-only, not in the guest musl build |
| `sync` (`dory-sync`) | host + guest | shared, pure: `FileEntry`/`Manifest`, `walk_manifest` (sha256 content hashes), and the host-authoritative reconciler `plan` (transfer where hash differs/missing, delete where remote-only). | ✅ built, 7 tests; cross-compiles to musl |
| `transfer-helper` (`dory-transfer-helper`) | **guest helper container** (static Linux/arm64) | Canonical byte-path-safe volume manifests, strict archive-content preflight, xattr/ownership/mode/time repair, sparse-hole restoration, and exact target rescan. Sockets are explicit exclusions and device nodes fail closed. | ✅ built reproducibly; real Engine archive qualification |

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

# exact named-volume helper (Apple Silicon launch):
../scripts/build-transfer-helper.sh

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

## Extension boundaries

- **Sync extensions** — host-authoritative push and reconciliation are built and proven end-to-end;
  the host is the source of truth. Future extensions include bidirectional/two-way conflict
  surfacing, and chunk-level content-addressed dedup across files (an optimization).
- **Remote workspace product UX** — the protocol, SSH transport, pinned host-key policy, Keychain key
  lookup, and host-authoritative push exist. Persistent reconnect, offline/conflict UX, and a full
  remote-workspace threat model remain preview work, not gaps in the local Docker dataplane.
- **USB passthrough** — host discovery and bridge scaffolding exist. The guest vhci attach/detach RPC
  is intentionally unavailable, so public app and CLI surfaces expose discovery only.
- **GPU** — Venus/Vulkan remains an opt-in preview on the arm64 raw-HV tier. It is not a stable 0.4
  cross-host GPU API.
