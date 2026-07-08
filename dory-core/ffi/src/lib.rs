//! `dory-ffi` — seam 2: the UniFFI staticlib the Swift `doryd`/`dory-vmm` link.
//!
//! The iron rule: this boundary carries **configuration, file descriptors, and stats — never
//! data-plane bytes**. Swift hands the Rust engine an fd and a compiled config; from then on bytes
//! flow socket-to-socket entirely inside Rust ([`dory_proto::half_close`]), zero per-packet
//! crossings. Every exported entry is panic-safe (UniFFI wraps calls so a Rust panic surfaces as a
//! Swift error rather than unwinding across the boundary — UB).
//!
//! This slice exposes the small control surface that is ready: the protocol version and the
//! create-body rewrite. The `serve(listen_fd, config) -> Handle` entry that hands Rust the captive
//! docker socket fd lands with the VMM integration.

uniffi::setup_scaffolding!();

mod agent_forward;
pub(crate) mod remote;

/// The wire protocol version doryd and the agent must agree on.
#[uniffi::export]
pub fn proto_version() -> u32 {
    dory_proto::handshake::PROTO_VERSION
}

/// Result of a create-body rewrite. `ok == false` carries a human-readable `error` (e.g. a GPU
/// request on an engine without GPU) and an empty `body`.
#[derive(uniffi::Record)]
pub struct RewriteResult {
    pub ok: bool,
    pub body: Vec<u8>,
    pub error: String,
}

/// Apply the shared-VM container-create rewrites to a JSON body. Control-plane only: this is a small
/// config message, not a data-plane stream.
#[uniffi::export]
pub fn rewrite_create_body(body: Vec<u8>, gpu_supported: bool) -> RewriteResult {
    match dory_dataplane::rewrite_create_body(&body, &dory_dataplane::RewriteOpts { gpu_supported })
    {
        Ok(out) => RewriteResult {
            ok: true,
            body: out,
            error: String::new(),
        },
        Err(e) => RewriteResult {
            ok: false,
            body: Vec::new(),
            error: e.to_string(),
        },
    }
}

/// A running docker dataplane, owned by the embedding VMM/doryd process. This is the real seam-2
/// pattern: Swift binds `dory.sock`, hands the listener **fd** and the backend config across the FFI,
/// and from then on every byte flows socket-to-socket inside Rust — none crosses back into Swift.
#[derive(uniffi::Object)]
pub struct DoryDataplane {
    // Keeping the runtime here keeps the serving tasks alive; it is shut down in the background on
    // drop so releasing the object is safe from any thread (Swift, or a tokio worker in tests) —
    // a plain Runtime drop blocks and panics inside an async context.
    runtime: std::sync::Mutex<Option<tokio::runtime::Runtime>>,
    task: std::sync::Mutex<Option<tokio::task::AbortHandle>>,
}

#[uniffi::export]
impl DoryDataplane {
    /// Stop serving. Idempotent; also happens on drop.
    pub fn shutdown(&self) {
        if let Some(handle) = self.task.lock().unwrap().take() {
            handle.abort();
        }
    }
}

impl Drop for DoryDataplane {
    fn drop(&mut self) {
        if let Some(runtime) = self.runtime.lock().unwrap().take() {
            runtime.shutdown_background();
        }
    }
}

/// Start serving docker on `listen_fd` (an already-bound AF_UNIX listener the caller owns and hands
/// over), proxying to the guest `dockerd` reachable at `dockerd_socket_path`. Two worker threads —
/// dev-tool traffic doesn't need more, and idle RSS stays small.
#[uniffi::export]
pub fn start_dataplane(
    listen_fd: i32,
    dockerd_socket_path: String,
    gpu_supported: bool,
) -> std::sync::Arc<DoryDataplane> {
    spawn_dataplane(
        listen_fd,
        std::sync::Arc::new(dory_dataplane::UnixBackend {
            path: dockerd_socket_path.into(),
        }),
        gpu_supported,
        None,
    )
}

/// The docker-tier variant: serve `listen_fd` and reach the guest `dockerd` by dialing `dory-hv`'s
/// `--agent-vsock-forward` socket with a `HostToGuest {cid, port}` preamble per connection.
#[uniffi::export]
pub fn start_dataplane_forward(
    listen_fd: i32,
    forward_socket_path: String,
    cid: u32,
    port: u32,
    gpu_supported: bool,
) -> std::sync::Arc<DoryDataplane> {
    spawn_dataplane(
        listen_fd,
        std::sync::Arc::new(dory_dataplane::ForwardBackend {
            forward_socket: forward_socket_path.into(),
            cid,
            port,
            retry_for: None,
        }),
        gpu_supported,
        None,
    )
}

/// Docker-tier dataplane with doryd-side activity reporting. The activity socket receives one
/// tab-separated line per meaningful docker connection: `begin<TAB>METHOD<TAB>PATH\n`, then `end\n`.
/// `/_ping` is intentionally exempt. Backend dials retry while doryd wakes the helper.
#[uniffi::export]
pub fn start_dataplane_forward_with_activity(
    listen_fd: i32,
    forward_socket_path: String,
    cid: u32,
    port: u32,
    gpu_supported: bool,
    activity_socket_path: String,
) -> std::sync::Arc<DoryDataplane> {
    spawn_dataplane(
        listen_fd,
        std::sync::Arc::new(dory_dataplane::ForwardBackend {
            forward_socket: forward_socket_path.into(),
            cid,
            port,
            retry_for: Some(std::time::Duration::from_secs(30)),
        }),
        gpu_supported,
        Some(dory_dataplane::serve::ActivityReporter::new(
            activity_socket_path.into(),
        )),
    )
}

fn spawn_dataplane<B: dory_dataplane::Backend>(
    listen_fd: i32,
    backend: std::sync::Arc<B>,
    gpu_supported: bool,
    activity: Option<dory_dataplane::serve::ActivityReporter>,
) -> std::sync::Arc<DoryDataplane> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("build dataplane runtime");
    let opts = std::sync::Arc::new(dory_dataplane::ServeOpts {
        gpu_supported,
        activity,
    });
    let task = runtime.spawn(async move {
        let _ = dory_dataplane::serve_fd(listen_fd, backend, opts).await;
    });
    std::sync::Arc::new(DoryDataplane {
        runtime: std::sync::Mutex::new(Some(runtime)),
        task: std::sync::Mutex::new(Some(task.abort_handle())),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proto_version_matches_proto_crate() {
        assert_eq!(proto_version(), dory_proto::handshake::PROTO_VERSION);
    }

    #[test]
    fn rewrite_reports_gpu_error_across_the_boundary_shape() {
        let body = br#"{"HostConfig":{"DeviceRequests":[{"Capabilities":[["gpu"]]}]}}"#.to_vec();
        let r = rewrite_create_body(body, false);
        assert!(!r.ok);
        assert!(r.error.contains("GPU"));
    }

    #[test]
    fn rewrite_adds_extra_hosts() {
        let r = rewrite_create_body(br#"{"Image":"alpine"}"#.to_vec(), true);
        assert!(r.ok);
        let v: serde_json::Value = serde_json::from_slice(&r.body).unwrap();
        assert!(v["HostConfig"]["ExtraHosts"].as_array().unwrap().len() >= 2);
    }

    /// The real seam-2 path: bind a listener (as Swift would), hand its raw fd to `start_dataplane`,
    /// and confirm a docker create through that socket reaches the backend with the body rewritten —
    /// all bytes staying inside Rust.
    #[tokio::test]
    async fn start_dataplane_serves_a_handed_over_fd() {
        use std::os::unix::io::IntoRawFd;
        use std::sync::Mutex;
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::{UnixListener, UnixStream};

        let base = std::env::temp_dir();
        let pid = std::process::id();
        let sock = base.join(format!("dory-ffi-serve-{pid}.sock"));
        let dockerd = base.join(format!("dory-ffi-dockerd-{pid}.sock"));
        let _ = std::fs::remove_file(&sock);
        let _ = std::fs::remove_file(&dockerd);

        // Fake dockerd: record the request it receives, reply 201.
        let dockerd_listener = UnixListener::bind(&dockerd).unwrap();
        let captured = std::sync::Arc::new(Mutex::new(Vec::new()));
        let cap = captured.clone();
        tokio::spawn(async move {
            if let Ok((mut s, _)) = dockerd_listener.accept().await {
                let mut got = Vec::new();
                let mut tmp = [0u8; 4096];
                loop {
                    match tokio::time::timeout(
                        std::time::Duration::from_millis(300),
                        s.read(&mut tmp),
                    )
                    .await
                    {
                        Ok(Ok(n)) if n > 0 => got.extend_from_slice(&tmp[..n]),
                        _ => break,
                    }
                }
                *cap.lock().unwrap() = got;
                let _ = s
                    .write_all(b"HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n")
                    .await;
                let _ = s.shutdown().await;
            }
        });

        // The "Swift-created" dory.sock listener, handed over as a raw fd.
        let listener = std::os::unix::net::UnixListener::bind(&sock).unwrap();
        let fd = listener.into_raw_fd();
        let dp = start_dataplane(fd, dockerd.to_string_lossy().into_owned(), false);

        tokio::time::sleep(std::time::Duration::from_millis(100)).await; // let it start accepting
        let body = r#"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}]}}}"#;
        let req = format!(
            "POST /v1.47/containers/create HTTP/1.1\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        );
        let mut client = UnixStream::connect(&sock).await.unwrap();
        client.write_all(req.as_bytes()).await.unwrap();
        let mut resp = Vec::new();
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            client.read_to_end(&mut resp),
        )
        .await;

        let got = String::from_utf8_lossy(&captured.lock().unwrap()).into_owned();
        assert!(
            got.contains("/containers/create"),
            "backend got the request: {got}"
        );
        assert!(
            got.contains("\"HostIp\":\"\""),
            "loopback HostIp rewritten before forwarding: {got}"
        );

        dp.shutdown();
        let _ = std::fs::remove_file(&sock);
        let _ = std::fs::remove_file(&dockerd);
    }

    /// The docker-tier seam: `start_dataplane_forward` must reach the backend through dory-hv's
    /// forward socket, preamble first — the fd handover plus the ForwardBackend dial in one path.
    #[tokio::test]
    async fn start_dataplane_forward_writes_the_preamble_then_the_request() {
        use dory_proto::preamble::{read_preamble, Direction};
        use std::os::unix::io::IntoRawFd;
        use std::sync::Mutex;
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::{UnixListener, UnixStream};

        let base = std::env::temp_dir();
        let pid = std::process::id();
        let sock = base.join(format!("dory-ffi-fwd-serve-{pid}.sock"));
        let fwd = base.join(format!("dory-ffi-fwd-{pid}.sock"));
        let _ = std::fs::remove_file(&sock);
        let _ = std::fs::remove_file(&fwd);

        let fwd_listener = UnixListener::bind(&fwd).unwrap();
        let got_preamble = std::sync::Arc::new(Mutex::new(None));
        let got_request = std::sync::Arc::new(Mutex::new(Vec::new()));
        let (gp, gr) = (got_preamble.clone(), got_request.clone());
        tokio::spawn(async move {
            if let Ok((mut s, _)) = fwd_listener.accept().await {
                let preamble = read_preamble(&mut s).await.unwrap();
                *gp.lock().unwrap() = Some(preamble);
                let mut req = Vec::new();
                let mut tmp = [0u8; 4096];
                loop {
                    match tokio::time::timeout(
                        std::time::Duration::from_millis(300),
                        s.read(&mut tmp),
                    )
                    .await
                    {
                        Ok(Ok(n)) if n > 0 => req.extend_from_slice(&tmp[..n]),
                        _ => break,
                    }
                }
                *gr.lock().unwrap() = req;
                let _ = s
                    .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
                    .await;
                let _ = s.shutdown().await;
            }
        });

        let listener = std::os::unix::net::UnixListener::bind(&sock).unwrap();
        let fd = listener.into_raw_fd();
        let dp = start_dataplane_forward(fd, fwd.to_string_lossy().into_owned(), 3, 1026, false);

        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        let mut client = UnixStream::connect(&sock).await.unwrap();
        client
            .write_all(b"GET /v1.47/version HTTP/1.1\r\nHost: d\r\n\r\n")
            .await
            .unwrap();
        let mut resp = Vec::new();
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            client.read_to_end(&mut resp),
        )
        .await;

        let preamble = got_preamble
            .lock()
            .unwrap()
            .clone()
            .expect("preamble received");
        assert_eq!(preamble.direction, Direction::HostToGuest);
        assert_eq!(preamble.cid, 3);
        assert_eq!(preamble.port, 1026);
        let request = String::from_utf8_lossy(&got_request.lock().unwrap()).into_owned();
        assert!(
            request.contains("GET /v1.47/version"),
            "forwarded request: {request}"
        );
        assert!(
            String::from_utf8_lossy(&resp).starts_with("HTTP/1.1 200"),
            "reply relayed"
        );

        dp.shutdown();
        let _ = std::fs::remove_file(&sock);
        let _ = std::fs::remove_file(&fwd);
    }
}
