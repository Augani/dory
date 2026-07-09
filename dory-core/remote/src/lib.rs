//! `dory-remote` — the host-only remote stack embedded in `doryd` (never in the guest agent). It
//! reaches a `dory-agent` running in daemon mode on a remote VPS over SSH, speaking the identical
//! protobuf protocol used over VZ vsock — the "same messages, different transport" half of seam 1.
//!
//! - [`agent_client::AgentClient`] — transport-agnostic typed RPC over any byte stream (handshake +
//!   mux + pb). Reusable for vsock, unix, or SSH.
//! - [`ssh`] — the russh SSH transport: connect, key auth, tunnel a channel to the agent daemon, and
//!   run `AgentClient` over it. Host-key verification is mandatory ([`ssh::HostKeyPolicy`]).
//! - [`sync_push`] — host-authoritative chunked file sync (D5): manifest diff, chunked puts,
//!   deletes; the guest-side reconciler lives in `dory-sync`.

pub mod agent_client;
pub mod error;
pub mod keys;
pub mod ssh;
pub mod sync_push;

pub use agent_client::AgentClient;
pub use error::RemoteError;
pub use keys::{private_key_from_openssh, public_key_from_openssh};
pub use ssh::{AgentEndpoint, HostKeyPolicy, SshAgent, SshConfig};
pub use sync_push::{push, PushStats, SyncTarget};
