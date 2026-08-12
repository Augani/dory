//! The guest-side vsock server (Linux only). Accepts the control channel (mux over RPC dispatch) and
//! the docker byte-stream (spliced to the guest `dockerd`). Cross-checks for the musl targets; runs
//! for real only inside a Dory guest.
#![cfg(target_os = "linux")]

use std::sync::Arc;
use std::time::Duration;

use dory_proto::channels::{PORT_CONTROL, PORT_DOCKER, PORT_FSEVENTS, PORT_SHELL, PORT_SSH_AGENT};
use dory_proto::half_close::splice;
use dory_proto::handshake::{handshake, Hello};
use dory_proto::mux::{Handler, HandlerFuture, Mux};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::Semaphore;
use tokio::time::timeout;
use tokio_vsock::{VsockAddr, VsockListener, VMADDR_CID_ANY, VMADDR_CID_HOST};

use crate::dispatch::agent_build;
use crate::handler::handle;

const GUEST_DOCKER_SOCK: &str = "/var/run/docker.sock";
const GUEST_SSH_AUTH_SOCK: &str = "/run/host-services/ssh-auth.sock";
const MAX_CONCURRENT_SSH_AGENT_CONNECTIONS: usize = 64;
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
        serve_fsevents(),
        serve_ssh_agent()
    )?;
    Ok(())
}

/// A real Linux Unix socket for containers, backed by one guest→host vsock connection per SSH
/// agent client. Host special files never enter virtio-fs, avoiding both cross-kernel AF_UNIX
/// ambiguity and the pre-FUSE FIFO blocking class.
async fn serve_ssh_agent() -> std::io::Result<()> {
    use std::os::unix::fs::{FileTypeExt, PermissionsExt};

    let directory = std::path::Path::new(GUEST_SSH_AUTH_SOCK)
        .parent()
        .expect("SSH agent socket has a parent");
    std::fs::create_dir_all(directory)?;
    std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o755))?;
    match std::fs::symlink_metadata(GUEST_SSH_AUTH_SOCK) {
        Ok(metadata) if metadata.file_type().is_socket() => {
            std::fs::remove_file(GUEST_SSH_AUTH_SOCK)?;
        }
        Ok(_) => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                "refusing to replace non-socket SSH agent path",
            ));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let listener = UnixListener::bind(GUEST_SSH_AUTH_SOCK)?;
    std::fs::set_permissions(GUEST_SSH_AUTH_SOCK, std::fs::Permissions::from_mode(0o666))?;
    let permits = Arc::new(Semaphore::new(MAX_CONCURRENT_SSH_AGENT_CONNECTIONS));
    loop {
        let (client, _) = listener.accept().await?;
        let Ok(permit) = Arc::clone(&permits).try_acquire_owned() else {
            continue;
        };
        tokio::spawn(async move {
            let _permit = permit;
            let host = timeout(
                Duration::from_secs(5),
                tokio_vsock::VsockStream::connect(VsockAddr::new(VMADDR_CID_HOST, PORT_SSH_AGENT)),
            )
            .await;
            if let Ok(Ok(host)) = host {
                let _ = splice(client, host).await;
            }
        });
    }
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

async fn handle_fsevent_batch<S>(
    mut stream: S,
    dedupe: Arc<crate::fsevents::FSEventDedupeStore>,
) -> std::io::Result<()>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
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

    use std::path::PathBuf;

    use crate::fsevents::{encode_batch_frame, ResponseStatus, MAX_FRAME_BYTES, PROTOCOL_VERSION};

    struct Response {
        operation_id: u64,
        path_count: u32,
        status: u32,
        failed_indices: Vec<u32>,
    }

    fn decode_response(frame: &[u8]) -> Response {
        let body_len = u32::from_le_bytes(frame[0..4].try_into().unwrap()) as usize;
        assert_eq!(frame.len(), 4 + body_len);
        assert_eq!(
            u32::from_le_bytes(frame[4..8].try_into().unwrap()),
            PROTOCOL_VERSION
        );
        let failed_count = u32::from_le_bytes(frame[24..28].try_into().unwrap()) as usize;
        let failed_indices = (0..failed_count)
            .map(|index| {
                let start = 28 + index * 4;
                u32::from_le_bytes(frame[start..start + 4].try_into().unwrap())
            })
            .collect();
        Response {
            operation_id: u64::from_le_bytes(frame[8..16].try_into().unwrap()),
            path_count: u32::from_le_bytes(frame[16..20].try_into().unwrap()),
            status: u32::from_le_bytes(frame[20..24].try_into().unwrap()),
            failed_indices,
        }
    }

    /// Feeds `request` to the fsevent handler and returns the handler result plus everything the
    /// handler wrote back to the peer.
    async fn exchange(
        request: &[u8],
        dedupe: Arc<crate::fsevents::FSEventDedupeStore>,
    ) -> (std::io::Result<()>, Vec<u8>) {
        let (mut peer, guest) = tokio::io::duplex(256 * 1024);
        peer.write_all(request).await.expect("write request");
        let result = handle_fsevent_batch(guest, dedupe).await;
        let mut response = Vec::new();
        peer.read_to_end(&mut response)
            .await
            .expect("read response");
        (result, response)
    }

    #[test]
    fn host_only_listener_policy_accepts_host_and_rejects_guest_cids() {
        assert!(is_host_peer(&VsockAddr::new(VMADDR_CID_HOST, PORT_CONTROL)));
        assert!(!is_host_peer(&VsockAddr::new(3, PORT_CONTROL)));
        assert!(!is_host_peer(&VsockAddr::new(VMADDR_CID_ANY, PORT_CONTROL)));
    }

    #[tokio::test]
    async fn a_valid_batch_is_nudged_and_answered_with_per_path_results() {
        let directory = std::env::temp_dir().join(format!("dory-fsevents-{}", std::process::id()));
        std::fs::create_dir_all(&directory).expect("create batch directory");
        let existing = directory.join("present");
        std::fs::write(&existing, b"payload").expect("write batch file");
        // Nudging walks up to an existing ancestor, so only a path whose every ancestor is missing
        // (the filesystem root is never nudged) can fail.
        let unreachable = PathBuf::from("/dory-absent-fsevent-root/child");
        let paths = vec![existing.clone(), unreachable];

        let request = encode_batch_frame(7, &paths).expect("encode batch");
        let (result, response) = exchange(&request, Arc::default()).await;

        result.expect("handled batch");
        let decoded = decode_response(&response);
        assert_eq!(decoded.operation_id, 7);
        assert_eq!(decoded.path_count, 2);
        assert_eq!(decoded.status, ResponseStatus::Success as u32);
        // Only the path whose parent directory does not exist can fail to be nudged.
        assert_eq!(decoded.failed_indices, vec![1]);

        std::fs::remove_dir_all(&directory).expect("clean batch directory");
    }

    #[tokio::test]
    async fn reusing_an_operation_id_for_different_paths_is_reported_as_a_conflict() {
        let dedupe = Arc::new(crate::fsevents::FSEventDedupeStore::default());
        let first = encode_batch_frame(11, &[PathBuf::from("/tmp")]).expect("encode batch");
        let second = encode_batch_frame(11, &[PathBuf::from("/var")]).expect("encode batch");

        let (first_result, _) = exchange(&first, Arc::clone(&dedupe)).await;
        first_result.expect("handled first batch");
        let (second_result, response) = exchange(&second, dedupe).await;

        second_result.expect("handled second batch");
        let decoded = decode_response(&response);
        assert_eq!(decoded.operation_id, 11);
        assert_eq!(decoded.path_count, 1);
        assert_eq!(
            decoded.status,
            ResponseStatus::ConflictingOperationId as u32
        );
        assert!(decoded.failed_indices.is_empty());
    }

    #[tokio::test]
    async fn oversized_and_undecodable_frames_are_rejected_without_a_response() {
        let mut oversized = ((MAX_FRAME_BYTES + 1) as u32).to_le_bytes().to_vec();
        oversized.extend_from_slice(&[0_u8; 16]);
        let (result, response) = exchange(&oversized, Arc::default()).await;
        assert_eq!(
            result.unwrap_err().kind(),
            std::io::ErrorKind::InvalidData,
            "declared body length above the frame cap must be refused"
        );
        assert!(response.is_empty());

        let mut wrong_version = 16_u32.to_le_bytes().to_vec();
        wrong_version.extend_from_slice(&(PROTOCOL_VERSION + 1).to_le_bytes());
        wrong_version.extend_from_slice(&1_u64.to_le_bytes());
        wrong_version.extend_from_slice(&0_u32.to_le_bytes());
        let (result, response) = exchange(&wrong_version, Arc::default()).await;
        assert_eq!(result.unwrap_err().kind(), std::io::ErrorKind::InvalidData);
        assert!(response.is_empty());
    }

    #[tokio::test]
    async fn a_slow_drip_frame_hits_the_read_deadline() {
        // The length prefix promises a body that never arrives, which is exactly the stall the
        // per-connection deadline exists to bound.
        let (peer, guest) = tokio::io::duplex(1024);
        let mut peer = peer;
        peer.write_all(&64_u32.to_le_bytes())
            .await
            .expect("write length prefix");
        let result = handle_fsevent_batch(guest, Arc::default()).await;
        assert_eq!(result.unwrap_err().kind(), std::io::ErrorKind::TimedOut);
        drop(peer);
    }
}
