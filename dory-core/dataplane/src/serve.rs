//! The docker socket serving loop. Accepts a client on `dory.sock`, reads just the request head,
//! classifies it, and either (a) rewrites a `create` body and forwards the reconstructed request, or
//! (b) replays the head and splices the raw connection to the backend (guest `dockerd`). A GPU
//! request on an engine without GPU is answered with a 501 and never dialed to the backend.
//!
//! The backend is abstracted so the embedding VMM supplies the real transport (the captive vsock
//! stream), while tests supply an in-memory `dockerd`.

use std::future::Future;
use std::os::unix::io::{FromRawFd, RawFd};
use std::pin::Pin;
use std::sync::Arc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};

use crate::classify::{classify, Disposition};
use crate::create_rewrite::{rewrite_create_body, RewriteOpts};
use crate::http_head::{head_end, parse_head, MAX_HEAD_BYTES};
use dory_proto::half_close::splice;

pub struct ServeOpts {
    pub gpu_supported: bool,
}

/// Supplies a fresh connection to the guest `dockerd` per client. In production `Stream` is the
/// captive vsock stream owned by the VMM; in tests it is an in-memory `UnixStream`.
pub trait Backend: Send + Sync + 'static {
    type Stream: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static;
    fn connect(&self) -> Pin<Box<dyn Future<Output = std::io::Result<Self::Stream>> + Send + '_>>;
}

/// Accept loop. One spawned task per connection; a failed connection never takes down the listener.
pub async fn serve<B: Backend>(
    listener: UnixListener,
    backend: Arc<B>,
    opts: Arc<ServeOpts>,
) -> std::io::Result<()> {
    loop {
        let (client, _addr) = listener.accept().await?;
        let backend = backend.clone();
        let opts = opts.clone();
        tokio::spawn(async move {
            let _ = handle_conn(client, backend, opts).await;
        });
    }
}

/// Serve on an already-bound listener fd handed over from the embedding process (Swift/doryd binds
/// `dory.sock` and passes the fd across the FFI). Takes ownership of `listen_fd`. The listener is put
/// into non-blocking mode for tokio.
pub async fn serve_fd<B: Backend>(
    listen_fd: RawFd,
    backend: Arc<B>,
    opts: Arc<ServeOpts>,
) -> std::io::Result<()> {
    // SAFETY: the caller transfers ownership of a valid, bound AF_UNIX listener fd.
    let std_listener = unsafe { std::os::unix::net::UnixListener::from_raw_fd(listen_fd) };
    std_listener.set_nonblocking(true)?;
    let listener = UnixListener::from_std(std_listener)?;
    serve(listener, backend, opts).await
}

/// A backend that dials a unix socket per connection: the guest `dockerd` reachable through the
/// vsock forward socket in production, or a plain dockerd socket.
pub struct UnixBackend {
    pub path: std::path::PathBuf,
}

impl Backend for UnixBackend {
    type Stream = UnixStream;
    fn connect(&self) -> Pin<Box<dyn Future<Output = std::io::Result<UnixStream>> + Send + '_>> {
        let path = self.path.clone();
        Box::pin(async move { UnixStream::connect(path).await })
    }
}

async fn handle_conn<B: Backend>(
    mut client: UnixStream,
    backend: Arc<B>,
    opts: Arc<ServeOpts>,
) -> std::io::Result<()> {
    let mut buf = Vec::with_capacity(8192);
    let mut tmp = [0u8; 8192];
    let head_len = loop {
        if let Some(end) = head_end(&buf) {
            break end;
        }
        if buf.len() > MAX_HEAD_BYTES {
            return Ok(()); // never found a head terminator; drop
        }
        let n = client.read(&mut tmp).await?;
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&tmp[..n]);
    };

    let Some(head) = parse_head(&buf) else {
        return Ok(());
    };

    if classify(&head) == Disposition::CreateRewrite {
        return handle_create(client, backend, opts, &buf, head_len).await;
    }

    // Passthrough / hijack: replay the buffered head (+ any body bytes already read), then splice.
    let mut upstream = backend.connect().await?;
    upstream.write_all(&buf).await?;
    splice(client, upstream).await?;
    Ok(())
}

async fn handle_create<B: Backend>(
    mut client: UnixStream,
    backend: Arc<B>,
    opts: Arc<ServeOpts>,
    buf: &[u8],
    head_len: usize,
) -> std::io::Result<()> {
    let head_text = std::str::from_utf8(&buf[..head_len]).unwrap_or("");
    let want = content_length(head_text).unwrap_or(0);

    // Body bytes already buffered after the head, plus whatever remains on the wire.
    let mut body = buf[head_len..].to_vec();
    let mut tmp = [0u8; 8192];
    while body.len() < want {
        let n = client.read(&mut tmp).await?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&tmp[..n]);
    }

    match rewrite_create_body(&body, &RewriteOpts { gpu_supported: opts.gpu_supported }) {
        Ok(new_body) => {
            let new_head = rebuild_head(head_text, new_body.len());
            let mut upstream = backend.connect().await?;
            upstream.write_all(&new_head).await?;
            upstream.write_all(&new_body).await?;
            splice(client, upstream).await?;
            Ok(())
        }
        Err(e) => {
            let _ = client
                .write_all(&http_error(501, "Not Implemented", &e.to_string()))
                .await;
            Ok(())
        }
    }
}

fn content_length(head_text: &str) -> Option<usize> {
    for line in head_text.split("\r\n") {
        if let Some((name, value)) = line.split_once(':') {
            if name.trim().eq_ignore_ascii_case("content-length") {
                return value.trim().parse().ok();
            }
        }
    }
    None
}

/// Rebuild the request head with a corrected `Content-Length` (the rewrite changes the body length).
fn rebuild_head(head_text: &str, content_length: usize) -> Vec<u8> {
    let block = head_text.trim_end_matches("\r\n\r\n");
    let mut lines: Vec<String> = Vec::new();
    for (i, line) in block.split("\r\n").enumerate() {
        // Keep the request line (i == 0); drop any existing content-length header.
        if i > 0 && line.split_once(':').is_some_and(|(n, _)| n.trim().eq_ignore_ascii_case("content-length")) {
            continue;
        }
        lines.push(line.to_string());
    }
    lines.push(format!("Content-Length: {content_length}"));
    let mut out = lines.join("\r\n");
    out.push_str("\r\n\r\n");
    out.into_bytes()
}

fn http_error(status: u16, reason: &str, message: &str) -> Vec<u8> {
    let body = format!("{{\"message\":{}}}", json_string(message));
    format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
    .into_bytes()
}

fn json_string(s: &str) -> String {
    serde_json::Value::String(s.to_string()).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tokio::io::AsyncReadExt;

    /// A backend that hands each connection to an in-memory fake dockerd which records the full
    /// request it receives and replies 201.
    struct FakeDockerd {
        captured: Arc<Mutex<Vec<u8>>>,
    }

    impl Backend for FakeDockerd {
        type Stream = UnixStream;
        fn connect(&self) -> Pin<Box<dyn Future<Output = std::io::Result<UnixStream>> + Send + '_>> {
            let captured = self.captured.clone();
            Box::pin(async move {
                let (ours, theirs) = UnixStream::pair()?;
                tokio::spawn(async move {
                    let mut s = theirs;
                    let mut got = Vec::new();
                    let mut tmp = [0u8; 4096];
                    loop {
                        let n = s.read(&mut tmp).await.unwrap_or(0);
                        if n == 0 {
                            break;
                        }
                        got.extend_from_slice(&tmp[..n]);
                        if let Some(he) = head_end(&got) {
                            let cl = content_length(std::str::from_utf8(&got[..he]).unwrap_or(""))
                                .unwrap_or(0);
                            if got.len() >= he + cl {
                                break;
                            }
                        }
                    }
                    *captured.lock().unwrap() = got;
                    let _ = s
                        .write_all(b"HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n")
                        .await;
                    let _ = s.shutdown().await;
                });
                Ok(ours)
            })
        }
    }

    async fn bind_temp_listener() -> (UnixListener, std::path::PathBuf) {
        let dir = std::env::temp_dir();
        let path = dir.join(format!("dory-serve-{}-{}.sock", std::process::id(), fastrand()));
        let _ = std::fs::remove_file(&path);
        (UnixListener::bind(&path).unwrap(), path)
    }

    // Tiny nondeterministic-enough suffix without adding a dep (process id + address of a local).
    fn fastrand() -> u64 {
        let x = Box::new(0u8);
        let addr = &*x as *const u8 as u64;
        addr ^ std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos() as u64).unwrap_or(0)
    }

    #[tokio::test]
    async fn create_body_is_rewritten_before_forwarding() {
        let captured = Arc::new(Mutex::new(Vec::new()));
        let backend = Arc::new(FakeDockerd {
            captured: captured.clone(),
        });
        let (listener, path) = bind_temp_listener().await;
        let opts = Arc::new(ServeOpts { gpu_supported: false });
        tokio::spawn(serve(listener, backend, opts));

        let body = r#"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}]}}}"#;
        let req = format!(
            "POST /v1.47/containers/create HTTP/1.1\r\nHost: d\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        );
        let mut client = UnixStream::connect(&path).await.unwrap();
        client.write_all(req.as_bytes()).await.unwrap();
        // Read the 201 so the exchange completes.
        let mut resp = Vec::new();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), client.read_to_end(&mut resp)).await;

        let got = captured.lock().unwrap().clone();
        let got_text = String::from_utf8_lossy(&got);
        assert!(got_text.contains("/containers/create"), "backend got the request");
        // The loopback HostIp must have been emptied before forwarding.
        assert!(got_text.contains("\"HostIp\":\"\""), "HostIp rewritten; got: {got_text}");
        assert!(got_text.contains("host-gateway"), "ExtraHosts injected");
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn gpu_request_gets_501_and_is_not_forwarded() {
        let captured = Arc::new(Mutex::new(Vec::new()));
        let backend = Arc::new(FakeDockerd {
            captured: captured.clone(),
        });
        let (listener, path) = bind_temp_listener().await;
        let opts = Arc::new(ServeOpts { gpu_supported: false });
        tokio::spawn(serve(listener, backend, opts));

        let body = r#"{"HostConfig":{"DeviceRequests":[{"Capabilities":[["gpu"]]}]}}"#;
        let req = format!(
            "POST /containers/create HTTP/1.1\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        );
        let mut client = UnixStream::connect(&path).await.unwrap();
        client.write_all(req.as_bytes()).await.unwrap();
        let mut resp = Vec::new();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), client.read_to_end(&mut resp)).await;

        let resp_text = String::from_utf8_lossy(&resp);
        assert!(resp_text.starts_with("HTTP/1.1 501"), "got: {resp_text}");
        assert!(captured.lock().unwrap().is_empty(), "backend must NOT be dialed for an unsupported GPU request");
        let _ = std::fs::remove_file(&path);
    }
}
