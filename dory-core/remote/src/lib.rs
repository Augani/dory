//! `dory-remote` — the host-only remote stack embedded in `doryd` (never in the guest agent). It
//! reaches a `dory-agent` running in daemon mode on a remote VPS over SSH, speaking the identical
//! protobuf protocol used over VZ vsock — the "same messages, different transport" half of seam 1.
//!
//! - [`agent_client::AgentClient`] — transport-agnostic typed RPC over any byte stream (handshake +
//!   mux + pb). Reusable for vsock, unix, or SSH.
//! - [`ssh`] — the russh SSH transport: connect, key auth, tunnel a channel to the agent daemon, and
//!   run `AgentClient` over it. Host-key verification is mandatory ([`ssh::HostKeyPolicy`]).
//!
//! Not yet built (blocked on decision D5 — conflict policy sign-off): chunked/resumable file sync
//! and the reconciler. The transport and RPC below are the unblocked foundation they build on.

pub mod agent_client;
pub mod error;
pub mod ssh;
pub mod sync_push;

pub use agent_client::AgentClient;
pub use error::RemoteError;
pub use ssh::{AgentEndpoint, HostKeyPolicy, SshAgent, SshConfig};
pub use sync_push::{push, PushStats, SyncTarget};
