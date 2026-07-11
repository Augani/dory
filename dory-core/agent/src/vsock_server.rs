//! The guest-side vsock server (Linux only). Accepts the control channel (mux over RPC dispatch) and
//! the docker byte-stream (spliced to the guest `dockerd`). Cross-checks for the musl targets; runs
//! for real only inside a Dory guest.
#![cfg(target_os = "linux")]

use std::sync::Arc;
use std::time::Duration;

use dory_proto::channels::{PORT_CONTROL, PORT_DOCKER, PORT_FSEVENTS, PORT_SHELL};
use dory_proto::half_close::splice;
use dory_proto::handshake::{handshake, Hello};
use dory_proto::mux::{Handler, HandlerFuture, Mux};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::Semaphore;
use tokio::time::timeout;
use tokio_vsock::{VsockAddr, VsockListener, VMADDR_CID_ANY, VMADDR_CID_HOST};

use crate::dispatch::agent_build;
use crate::handler::handle;

const GUEST_DOCKER_SOCK: &str = "/var/run/docker.sock";
const MAX_CONCURRENT_FSEVENT_CONNECTIONS: usize = 4;
const FSEVENT_READ_TIMEOUT: Duration = Duration::from_secs(2);
const FSEVENT_WRITE_TIMEOUT: Duration = Duration::from_secs(2);

fn is_host_peer(peer: &VsockAddr) -> bool {
    peer.cid() == VMADDR_CID_HOST
}

pub async fn run() -> std::io::Result<()> {
    tokio::try_join!(
        serve_control(),
        serve_docker(),
        serve_shell(),
        serve_fsevents()
    )?;
    Ok(())
}

/// Host-edit event batches. This is a dedicated host-only channel rather than part of the remote
/// control API: event delivery is meaningful only for local virtio-fs shares and must follow the
/// host VMM's cache-invalidation barrier.
async fn serve_fsevents() -> std::io::Result<()> {
    let listener = VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, PORT_FSEVENTS))?;
    let permits = Arc::new(Semaphore::new(MAX_CONCURRENT_FSEVENT_CONNECTIONS));
    let dedupe = Arc::new(crate::fsevents::FSEventDedupeStore::default());
    loop {
        let (stream, peer) = listener.accept().await?;
        if !is_host_peer(&peer) {
            continue;
        }
        // Do not let stalled or bursty host connections accumulate tasks. The host can retry a
        // dropped batch after its invalidation barrier; each admitted connection has I/O deadlines.
        let Ok(permit) = Arc::clone(&permits).try_acquire_owned() else {
            continue;
        };
        let dedupe = Arc::clone(&dedupe);
        tokio::spawn(async move {
            let _permit = permit;
            let _ = handle_fsevent_batch(stream, dedupe).await;
        });
    }
}

async fn handle_fsevent_batch(
    mut stream: tokio_vsock::VsockStream,
    dedupe: Arc<crate::fsevents::FSEventDedupeStore>,
) -> std::io::Result<()> {
    // One deadline covers the complete frame so a peer cannot slow-drip a permitted connection.
    let body = timeout(FSEVENT_READ_TIMEOUT, async {
        let body_len = stream.read_u32_le().await? as usize;
        if body_len > crate::fsevents::MAX_FRAME_BYTES {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "fsevent batch exceeds maximum frame size",
            ));
        }
        let mut body = vec![0_u8; body_len];
        stream.read_exact(&mut body).await?;
        Ok(body)
    })
    .await
    .map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "timed out reading fsevent batch",
        )
    })??;
    let batch = crate::fsevents::decode_batch_body(&body).map_err(|error| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("invalid fsevent batch: {error:?}"),
        )
    })?;
    let operation_id = batch.operation_id;
    let path_count = batch.paths.len() as u32;
    let outcome =
        tokio::task::spawn_blocking(move || dedupe.execute(&batch, crate::fsevents::nudge_paths))
            .await
            .map_err(|error| std::io::Error::other(format!("fsevent worker failed: {error}")))?;
    let response = match outcome {
        Ok(outcome) => crate::fsevents::encode_response_frame(operation_id, &outcome),
        Err(error) => crate::fsevents::encode_error_response_frame(
            operation_id,
            path_count,
            match error {
                crate::fsevents::DedupeError::ConflictingOperationId => {
                    crate::fsevents::ResponseStatus::ConflictingOperationId
                }
                crate::fsevents::DedupeError::CapacityExhausted => {
                    crate::fsevents::ResponseStatus::CapacityExhausted
                }
                crate::fsevents::DedupeError::ExecutionFailed => {
                    crate::fsevents::ResponseStatus::ExecutionFailed
                }
            },
        ),
    };
    timeout(FSEVENT_WRITE_TIMEOUT, async {
        stream.write_all(&response).await?;
        tokio::io::AsyncWriteExt::shutdown(&mut stream).await
    })
    .await
    .map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "timed out writing fsevent response",
        )
    })?
}

/// Control channel: one mux per connection, handler = the RPC dispatcher.
async fn serve_control() -> std::io::Result<()> {
    let listener = VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, PORT_CONTROL))?;
    loop {
        let (mut stream, peer) = listener.accept().await?;
        if !is_host_peer(&peer) {
            continue;
        }
        tokio::spawn(async move {
            if handshake(&mut stream, &Hello::current(agent_build()))
                .await
                .is_err()
            {
                return;
            }
            let handler: Handler = Arc::new(|req: Vec<u8>| {
                Box::pin(async move { handle(&req).await }) as HandlerFuture
            });
            // The mux owns the connection via its own spawned reader/writer tasks; it serves until
            // the peer closes, at which point those tasks unwind.
            let _mux = Mux::start(stream, handler);
        });
    }
}

/// Docker byte stream: splice each client to the guest dockerd socket, half-close preserved.
async fn serve_docker() -> std::io::Result<()> {
    let listener = VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, PORT_DOCKER))?;
    loop {
        let (client, peer) = listener.accept().await?;
        if !is_host_peer(&peer) {
            continue;
        }
        tokio::spawn(async move {
            match UnixStream::connect(GUEST_DOCKER_SOCK).await {
                Ok(dockerd) => {
                    let _ = splice(client, dockerd).await;
                }
                Err(_) => { /* dockerd not up yet; drop the client */ }
            }
        });
    }
}

/// Interactive shell byte stream: each connection gets an independent guest PTY.
async fn serve_shell() -> std::io::Result<()> {
    let listener = VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, PORT_SHELL))?;
    loop {
        let (client, peer) = listener.accept().await?;
        if !is_host_peer(&peer) {
            continue;
        }
        tokio::spawn(async move {
            let _ = crate::terminal::serve_shell_stream(client).await;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_only_listener_policy_accepts_host_and_rejects_guest_cids() {
        assert!(is_host_peer(&VsockAddr::new(VMADDR_CID_HOST, PORT_CONTROL)));
        assert!(!is_host_peer(&VsockAddr::new(3, PORT_CONTROL)));
        assert!(!is_host_peer(&VsockAddr::new(VMADDR_CID_ANY, PORT_CONTROL)));
    }
}
