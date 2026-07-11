//! `dory-agent` library surface: the platform-independent pieces the binary composes, exposed so
//! they can be unit-tested and driven directly. The binary (`main.rs`) is a thin wrapper.
//!
//! - [`dispatch`] — decode an `AgentRequest`, run the method, encode an `AgentResponse`.
//! - [`daemon`] — the control server over a TCP/unix listener (remote-VPS mode): the same
//!   `handshake + mux + dispatch` the guest vsock server runs, minus vsock, so it is portable and
//!   host-testable.
//! - [`proc_net`] — `/proc/net` listening-port parsing (Linux runtime; pure parser is testable
//!   anywhere).
//! - `vsock_server` (Linux only) — the guest PID-1 control + docker byte-stream server.

pub mod daemon;
pub mod dispatch;
pub mod exec;
pub mod fsevents;
pub mod handler;
pub mod proc_net;
pub mod reaper;
pub mod sync_apply;
pub mod telemetry;

#[cfg(target_os = "linux")]
pub mod terminal;
#[cfg(target_os = "linux")]
pub mod vsock_server;
