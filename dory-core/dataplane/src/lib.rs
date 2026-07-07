//! `dory-dataplane` — the host-side docker proxy embedded in the VMM helper (`dory-vmm` for VZ,
//! `dory-hv` for the docker tier) via FFI. It serves `dory.sock`, classifies each request, applies
//! the shared-VM create rewrites, and splices the connection to the guest `dockerd` over the vsock
//! bridge — bytes never cross into Swift. `payload never touches doryd`.
//!
//! This crate holds the pure, unit-tested logic (head parse, classify, create rewrite). The socket
//! accept loop + vsock dial + the [`dory_proto::half_close`] splice are wired by the embedding VMM
//! process (which owns the captive vsock fds); [`proxy_disposition`] is the single entry the serving
//! loop calls per connection once the head has arrived.

pub mod classify;
pub mod create_rewrite;
pub mod http_head;
pub mod serve;

pub use classify::Disposition;
pub use create_rewrite::{rewrite_create_body, RewriteError, RewriteOpts};
pub use http_head::{parse_head, RequestHead};
pub use serve::{serve, serve_fd, Backend, ServeOpts, UnixBackend};

/// What the serving loop should do with a connection whose head is `buf`. `None` means the head is
/// not yet complete — read more bytes. `/_ping` is reported as passthrough here; the idle-activity
/// exemption for it lives in the serving loop, not the classifier.
pub fn proxy_disposition(buf: &[u8]) -> Option<Disposition> {
    let head = parse_head(buf)?;
    Some(classify::classify(&head))
}
