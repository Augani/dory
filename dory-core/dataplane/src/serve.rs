//! The docker socket serving loop. Accepts a client on `dory.sock` and classifies **every request
//! on the connection** — the docker CLI pools keep-alive connections, so classifying only the first
//! request would let a `create` sent after a `GET /_ping` bypass the compatibility rewrites and the
//! GPU gate entirely.
//!
//! The shape per connection: one backend connection (dialed lazily on the first request), a blind
//! response pump backend→client (responses are never parsed), and a request loop client→backend
//! that tracks request boundaries (content-length framed). A `create` body is rewritten in place;
//! a hijack/upgrade request (attach/exec/build/load) drops the rest of the connection into a raw
//! splice; everything else streams through verbatim. Half-close is preserved in both directions:
//! client EOF becomes backend `SHUT_WR`, backend EOF becomes client `SHUT_WR`.
//!
//! Docker clients never pipeline (a request is only sent after the previous response), which is
//! what makes the blind response pump and the direct 501 write safe.
//!
//! The backend is abstracted so the embedding VMM supplies the real transport (the captive vsock
//! stream), while tests supply an in-memory `dockerd`.

use std::collections::BTreeSet;
use std::future::Future;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpListener, UdpSocket};
use std::os::unix::io::{FromRawFd, RawFd};
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::io::{AsyncReadExt, AsyncWriteExt, WriteHalf};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::Mutex;
use tokio::task::JoinHandle;
use tokio::time::timeout;

use crate::classify::{classify, Disposition};
use crate::create_rewrite::{rewrite_create_body, RewriteOpts};
use crate::http_head::{head_end, parse_head, MAX_HEAD_BYTES};

pub const ACTIVITY_ACK_TIMEOUT: Duration = Duration::from_secs(210);

pub struct ServeOpts {
    pub gpu_supported: bool,
    pub activity: Option<ActivityReporter>,
}

#[derive(Clone)]
pub struct ActivityReporter {
    path: Arc<PathBuf>,
}

impl ActivityReporter {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path: Arc::new(path),
        }
    }

    async fn begin(&self, method: &str, path: &str) {
        self.send(format!("begin\t{method}\t{path}\n")).await;
    }

    async fn end(&self) {
        self.send("end\n".to_string()).await;
    }

    async fn send(&self, line: String) {
        if let Ok(mut stream) = UnixStream::connect(&*self.path).await {
            let _ = stream.write_all(line.as_bytes()).await;
            let _ = stream.shutdown().await;
            let mut ack = [0u8; 8];
            let _ = timeout(ACTIVITY_ACK_TIMEOUT, stream.read(&mut ack)).await;
        }
    }
}

/// A docker create body is small JSON (a few KB). Anything past this is malformed or hostile and is
/// rejected before it can overflow the request-length arithmetic.
const MAX_CREATE_BODY: usize = 8 * 1024 * 1024;
const MAX_INSPECT_BODY: usize = 2 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum HostPortProtocol {
    Tcp,
    Udp,
}

/// Fixed host ports requested by Docker create. Dory's dockerd runs in the guest, so it cannot see
/// listeners already occupying the corresponding macOS port. Probe those ports before forwarding
/// create; otherwise Docker reports success while the host forwarder retries invisibly forever.
fn requested_fixed_host_ports(body: &[u8]) -> BTreeSet<(HostPortProtocol, SocketAddr)> {
    let Ok(root) = serde_json::from_slice::<serde_json::Value>(body) else {
        return BTreeSet::new();
    };
    let Some(bindings) = root
        .get("HostConfig")
        .and_then(|value| value.get("PortBindings"))
        .and_then(serde_json::Value::as_object)
    else {
        return BTreeSet::new();
    };
    let mut requested = BTreeSet::new();
    for (container_port, entries) in bindings {
        let Some((_, protocol)) = container_port.rsplit_once('/') else {
            continue;
        };
        let protocol = match protocol.to_ascii_lowercase().as_str() {
            "tcp" | "tcp6" => HostPortProtocol::Tcp,
            "udp" | "udp6" => HostPortProtocol::Udp,
            _ => continue,
        };
        let Some(entries) = entries.as_array() else {
            continue;
        };
        for entry in entries {
            let Some(host_port) = entry
                .get("HostPort")
                .and_then(serde_json::Value::as_str)
                .and_then(|value| value.parse::<u16>().ok())
                .filter(|port| *port != 0)
            else {
                continue;
            };
            // Dory maps privileged guest publications to an unprivileged host port by contract.
            let local_port = if host_port < 1024 {
                60_000 + host_port
            } else {
                host_port
            };
            let host_ip = entry
                .get("HostIp")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("")
                .trim_matches(['[', ']']);
            let addresses: Vec<IpAddr> = match host_ip {
                "127.0.0.1" => vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
                "::1" => vec![IpAddr::V6(Ipv6Addr::LOCALHOST)],
                "localhost" | "" | "0.0.0.0" | "::" => vec![
                    IpAddr::V4(Ipv4Addr::LOCALHOST),
                    IpAddr::V6(Ipv6Addr::LOCALHOST),
                ],
                value => value.parse::<IpAddr>().map_or_else(
                    |_| {
                        vec![
                            IpAddr::V4(Ipv4Addr::LOCALHOST),
                            IpAddr::V6(Ipv6Addr::LOCALHOST),
                        ]
                    },
                    |address| vec![address],
                ),
            };
            for address in addresses {
                requested.insert((protocol, SocketAddr::new(address, local_port)));
            }
        }
    }
    requested
}

fn preflight_fixed_host_ports(body: &[u8]) -> Result<(), String> {
    enum Probe {
        Tcp(TcpListener),
        Udp(UdpSocket),
    }
    let mut probes = Vec::new();
    for (protocol, address) in requested_fixed_host_ports(body) {
        let probe = match protocol {
            HostPortProtocol::Tcp => TcpListener::bind(address).map(Probe::Tcp),
            HostPortProtocol::Udp => UdpSocket::bind(address).map(Probe::Udp),
        }
        .map_err(|error| {
            let protocol = match protocol {
                HostPortProtocol::Tcp => "tcp",
                HostPortProtocol::Udp => "udp",
            };
            format!("host port {address}/{protocol} is unavailable: {error}")
        })?;
        probes.push(probe);
    }
    // Keep every probe open until the full set succeeds, so duplicate/wildcard requests cannot
    // pass by observing ports released by an earlier iteration of the same create request.
    for probe in &probes {
        match probe {
            Probe::Tcp(listener) => {
                let _ = listener.local_addr();
            }
            Probe::Udp(socket) => {
                let _ = socket.local_addr();
            }
        }
    }
    Ok(())
}

async fn inspect_container_for_start<B: Backend>(
    backend: &B,
    start_path: &str,
) -> std::io::Result<Vec<u8>> {
    let container = start_path
        .strip_prefix("/containers/")
        .and_then(|path| path.strip_suffix("/start"))
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::InvalidInput, "invalid start path")
        })?;
    let mut stream = backend.connect().await?;
    stream
        .write_all(
            format!(
                "GET /containers/{container}/json HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n"
            )
            .as_bytes(),
        )
        .await?;
    let mut response = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    let head_len = loop {
        if let Some(length) = head_end(&response) {
            break length;
        }
        if response.len() > MAX_HEAD_BYTES {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "container inspect response head is too large",
            ));
        }
        let count = stream.read(&mut chunk).await?;
        if count == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "container inspect ended before its response head",
            ));
        }
        response.extend_from_slice(&chunk[..count]);
    };
    let head = std::str::from_utf8(&response[..head_len]).map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "container inspect response head is not UTF-8",
        )
    })?;
    if !head.starts_with("HTTP/1.1 200 ") && !head.starts_with("HTTP/1.0 200 ") {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "container inspect did not return 200",
        ));
    }
    if is_chunked(head) {
        loop {
            match decode_chunked_body(&response[head_len..], MAX_INSPECT_BODY) {
                ChunkedBody::Complete { body, .. } => return Ok(body),
                ChunkedBody::NeedMore => {
                    if response.len().saturating_sub(head_len) > MAX_INSPECT_BODY + MAX_HEAD_BYTES {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            "chunked container inspect response exceeded its bound",
                        ));
                    }
                    let count = stream.read(&mut chunk).await?;
                    if count == 0 {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::UnexpectedEof,
                            "chunked container inspect response is incomplete",
                        ));
                    }
                    response.extend_from_slice(&chunk[..count]);
                }
                ChunkedBody::TooLarge => {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "chunked container inspect response body is too large",
                    ));
                }
                ChunkedBody::Malformed => {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "chunked container inspect response is malformed",
                    ));
                }
            }
        }
    }
    let body_length = content_length(head).ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "container inspect response has no content length",
        )
    })?;
    if body_length > MAX_INSPECT_BODY {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "container inspect response body is too large",
        ));
    }
    while response.len() < head_len + body_length {
        let count = stream.read(&mut chunk).await?;
        if count == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "container inspect response body is incomplete",
            ));
        }
        response.extend_from_slice(&chunk[..count]);
        if response.len() > head_len + MAX_INSPECT_BODY {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "container inspect response exceeded its bound",
            ));
        }
    }
    Ok(response[head_len..head_len + body_length].to_vec())
}

async fn preflight_container_start<B: Backend>(backend: &B, start_path: &str) -> Option<String> {
    let inspect = match timeout(
        Duration::from_secs(3),
        inspect_container_for_start(backend, start_path),
    )
    .await
    {
        Ok(Ok(body)) => body,
        // A non-200 inspect response means dockerd already knows why this container cannot be
        // started. Forward the original start request so the client receives dockerd's exact
        // status and message instead of replacing it with a Dory preflight error.
        Ok(Err(error)) if error.kind() == std::io::ErrorKind::NotFound => return None,
        Ok(Err(error)) => {
            return Some(format!(
                "could not verify macOS host ports before container start: {error}"
            ));
        }
        Err(_) => {
            return Some(
                "could not verify macOS host ports before container start: inspect timed out"
                    .to_string(),
            );
        }
    };
    let mut last_error = None;
    // A prior Dory container may have just stopped. Give the two-second host-forwarder reconcile
    // interval time to release its listener before treating it as an external collision.
    for _ in 0..30 {
        match preflight_fixed_host_ports(&inspect) {
            Ok(()) => return None,
            Err(error) => last_error = Some(error),
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    last_error
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

/// A backend that dials a unix socket per connection: a plain `dockerd` socket, or the guest
/// `dockerd` reachable directly.
pub struct UnixBackend {
    pub path: std::path::PathBuf,
    pub retry_for: Option<Duration>,
}

impl Backend for UnixBackend {
    type Stream = UnixStream;
    fn connect(&self) -> Pin<Box<dyn Future<Output = std::io::Result<UnixStream>> + Send + '_>> {
        let path = self.path.clone();
        let retry_for = self.retry_for;
        Box::pin(async move { connect_with_optional_retry(path, retry_for).await })
    }
}

/// The docker-tier backend: dial `dory-hv`'s forward socket and write a `HostToGuest` preamble for
/// the docker port, so `dory-hv` opens a fresh guest vsock stream to `dockerd` and pumps raw bytes.
/// After the preamble the stream is a transparent pipe to the guest `dockerd`.
pub struct ForwardBackend {
    pub forward_socket: PathBuf,
    pub cid: u32,
    pub port: u32,
    pub retry_for: Option<Duration>,
}

impl Backend for ForwardBackend {
    type Stream = UnixStream;
    fn connect(&self) -> Pin<Box<dyn Future<Output = std::io::Result<UnixStream>> + Send + '_>> {
        let path = self.forward_socket.clone();
        let (cid, port) = (self.cid, self.port);
        let retry_for = self.retry_for;
        Box::pin(async move {
            let mut stream = connect_with_optional_retry(path, retry_for).await?;
            let preamble = dory_proto::preamble::Preamble {
                direction: dory_proto::preamble::Direction::HostToGuest,
                cid,
                port,
            };
            dory_proto::preamble::write_preamble(&mut stream, &preamble)
                .await
                .map_err(std::io::Error::other)?;
            Ok(stream)
        })
    }
}

async fn connect_with_optional_retry(
    path: PathBuf,
    retry_for: Option<Duration>,
) -> std::io::Result<UnixStream> {
    let Some(retry_for) = retry_for else {
        return UnixStream::connect(path).await;
    };
    let deadline = Instant::now() + retry_for;
    loop {
        match UnixStream::connect(&path).await {
            Ok(stream) => return Ok(stream),
            Err(error) if should_retry_connect(&error) && Instant::now() < deadline => {
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            Err(error) => return Err(error),
        }
    }
}

fn should_retry_connect(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::NotFound
            | std::io::ErrorKind::ConnectionRefused
            | std::io::ErrorKind::AddrNotAvailable
    )
}

async fn handle_conn<B: Backend>(
    client: UnixStream,
    backend: Arc<B>,
    opts: Arc<ServeOpts>,
) -> std::io::Result<()> {
    let (client_read, client_write) = client.into_split();
    let mut proxy = Proxy {
        backend,
        client_write: Arc::new(Mutex::new(client_write)),
        upstream_write: None,
        pump: None,
    };
    let mut activity_started = false;
    let served = proxy.drive(client_read, &opts, &mut activity_started).await;
    // Whatever ended the request loop (client EOF, hijack finished, reject, error), give dockerd
    // request-EOF so it finishes its last response and closes; the pump then half-closes the client.
    if let Some(mut upstream_write) = proxy.upstream_write.take() {
        let _ = upstream_write.shutdown().await;
    }
    if let Some(pump) = proxy.pump.take() {
        let _ = pump.await;
    }
    if activity_started {
        if let Some(activity) = &opts.activity {
            activity.end().await;
        }
    }
    served
}

/// Per-connection proxy state: the backend write half (dialed lazily so a rejected or garbage first
/// request never opens a guest stream) and the blind response pump that owns backend→client.
struct Proxy<B: Backend> {
    backend: Arc<B>,
    client_write: Arc<Mutex<OwnedWriteHalf>>,
    upstream_write: Option<WriteHalf<B::Stream>>,
    pump: Option<JoinHandle<()>>,
}

impl<B: Backend> Proxy<B> {
    /// The backend connection, dialed on first use. Dialing also starts the response pump, which
    /// relays backend bytes to the client without parsing them and half-closes the client's write
    /// side when the backend is done sending.
    async fn upstream(&mut self) -> std::io::Result<&mut WriteHalf<B::Stream>> {
        if self.upstream_write.is_none() {
            let stream = self.backend.connect().await?;
            let (mut upstream_read, upstream_write) = tokio::io::split(stream);
            let writer = self.client_write.clone();
            self.pump = Some(tokio::spawn(async move {
                let mut buf = vec![0u8; 64 * 1024];
                loop {
                    let n = match upstream_read.read(&mut buf).await {
                        Ok(n) if n > 0 => n,
                        _ => break,
                    };
                    let mut w = writer.lock().await;
                    if w.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
                let mut w = writer.lock().await;
                let _ = w.shutdown().await;
            }));
            self.upstream_write = Some(upstream_write);
        }
        Ok(self.upstream_write.as_mut().expect("upstream just dialed"))
    }

    /// The request loop: parse each request head, classify, and forward with the request body
    /// tracked to its boundary so the next head is parsed too. Returns when the client stops
    /// sending or the connection degrades to a raw splice (hijack / chunked tail).
    async fn drive(
        &mut self,
        mut client_read: OwnedReadHalf,
        opts: &ServeOpts,
        activity_started: &mut bool,
    ) -> std::io::Result<()> {
        let mut buf: Vec<u8> = Vec::with_capacity(8192);
        let mut tmp = [0u8; 8192];
        loop {
            let head_len = loop {
                if let Some(end) = head_end(&buf) {
                    break end;
                }
                if buf.len() > MAX_HEAD_BYTES {
                    return Ok(()); // never found a head terminator; drop
                }
                let n = client_read.read(&mut tmp).await?;
                if n == 0 {
                    return Ok(()); // keep-alive close (or half-close) between requests
                }
                buf.extend_from_slice(&tmp[..n]);
            };
            let Some(head) = parse_head(&buf) else {
                return Ok(());
            };
            let head_text = std::str::from_utf8(&buf[..head_len])
                .unwrap_or("")
                .to_string();
            if head.path == "/_ping" && opts.activity.is_some() {
                let mut w = self.client_write.lock().await;
                let _ = w.write_all(ping_response(&head.method).as_bytes()).await;
                let _ = w.shutdown().await;
                return Ok(());
            }
            if head.path != "/_ping" && !*activity_started {
                if let Some(activity) = &opts.activity {
                    activity.begin(&head.method, &head.path).await;
                }
                *activity_started = true;
            }

            match classify(&head) {
                Disposition::Hijack => {
                    // The connection stops being HTTP here (attach/exec upgrade, build/load
                    // stream): replay what is buffered and splice the rest raw.
                    let upstream_write = self.upstream().await?;
                    upstream_write.write_all(&buf).await?;
                    let _ = tokio::io::copy(&mut client_read, upstream_write).await;
                    return Ok(());
                }
                Disposition::CreateRewrite => {
                    let (create_body, body_end) = if is_chunked(&head_text) {
                        loop {
                            match decode_chunked_body(&buf[head_len..], MAX_CREATE_BODY) {
                                ChunkedBody::Complete { body, consumed } => {
                                    break (body, head_len + consumed)
                                }
                                ChunkedBody::NeedMore => {
                                    // Bound framing and trailers as well as decoded JSON. This also
                                    // prevents a peer from sending an endless unterminated size line.
                                    if buf.len().saturating_sub(head_len)
                                        > MAX_CREATE_BODY + MAX_HEAD_BYTES
                                    {
                                        let mut w = self.client_write.lock().await;
                                        let _ = w
                                            .write_all(&http_error(
                                                413,
                                                "Payload Too Large",
                                                "chunked create body too large",
                                            ))
                                            .await;
                                        let _ = w.shutdown().await;
                                        return Ok(());
                                    }
                                    let n = client_read.read(&mut tmp).await?;
                                    if n == 0 {
                                        let mut w = self.client_write.lock().await;
                                        let _ = w
                                            .write_all(&http_error(
                                                400,
                                                "Bad Request",
                                                "incomplete chunked create body",
                                            ))
                                            .await;
                                        let _ = w.shutdown().await;
                                        return Ok(());
                                    }
                                    buf.extend_from_slice(&tmp[..n]);
                                }
                                ChunkedBody::TooLarge => {
                                    let mut w = self.client_write.lock().await;
                                    let _ = w
                                        .write_all(&http_error(
                                            413,
                                            "Payload Too Large",
                                            "create body too large",
                                        ))
                                        .await;
                                    let _ = w.shutdown().await;
                                    return Ok(());
                                }
                                ChunkedBody::Malformed => {
                                    let mut w = self.client_write.lock().await;
                                    let _ = w
                                        .write_all(&http_error(
                                            400,
                                            "Bad Request",
                                            "malformed chunked create body",
                                        ))
                                        .await;
                                    let _ = w.shutdown().await;
                                    return Ok(());
                                }
                            }
                        }
                    } else {
                        let want = content_length(&head_text).unwrap_or(0);
                        // A create body is small JSON. An absurd/overflowing Content-Length is
                        // malformed or hostile: reject it rather than overflow head_len+want —
                        // with panic=abort a reverse-range slice panic would crash the dataplane.
                        if want > MAX_CREATE_BODY {
                            let mut w = self.client_write.lock().await;
                            let _ = w
                                .write_all(&http_error(
                                    413,
                                    "Payload Too Large",
                                    "create body too large",
                                ))
                                .await;
                            let _ = w.shutdown().await;
                            return Ok(());
                        }
                        let request_end = head_len + want; // no overflow: want <= MAX_CREATE_BODY
                        while buf.len() < request_end {
                            let n = client_read.read(&mut tmp).await?;
                            if n == 0 {
                                break;
                            }
                            buf.extend_from_slice(&tmp[..n]);
                        }
                        let body_end = request_end.min(buf.len());
                        (buf[head_len..body_end].to_vec(), body_end)
                    };
                    let rewrite = rewrite_create_body(
                        &create_body,
                        &RewriteOpts {
                            gpu_supported: opts.gpu_supported,
                        },
                    );
                    match rewrite {
                        Ok(new_body) => {
                            let new_head = rebuild_head(&head_text, new_body.len());
                            let upstream_write = self.upstream().await?;
                            upstream_write.write_all(&new_head).await?;
                            upstream_write.write_all(&new_body).await?;
                        }
                        Err(e) => {
                            // Written directly to the client: safe because docker clients don't
                            // pipeline, so no backend response can be in flight for this slot.
                            let mut w = self.client_write.lock().await;
                            let _ = w
                                .write_all(&http_error(501, "Not Implemented", &e.to_string()))
                                .await;
                            let _ = w.shutdown().await;
                            return Ok(());
                        }
                    }
                    buf.drain(..body_end);
                }
                disposition @ (Disposition::ContainerStartPreflight | Disposition::Passthrough) => {
                    if disposition == Disposition::ContainerStartPreflight {
                        if let Some(error) =
                            preflight_container_start(self.backend.as_ref(), &head.path).await
                        {
                            let mut w = self.client_write.lock().await;
                            let _ = w.write_all(&http_error(409, "Conflict", &error)).await;
                            let _ = w.shutdown().await;
                            return Ok(());
                        }
                    }
                    if is_chunked(&head_text) {
                        // No docker CLI flow sends a chunked passthrough body (the big streams
                        // are hijack-classified), so rather than parse chunk framing, degrade to
                        // a raw tail from this request on — the pre-loop behavior.
                        let upstream_write = self.upstream().await?;
                        upstream_write.write_all(&buf).await?;
                        let _ = tokio::io::copy(&mut client_read, upstream_write).await;
                        return Ok(());
                    }
                    let want = content_length(&head_text).unwrap_or(0);
                    // Guard the same overflow class as the create branch (panic=abort => whole-
                    // process crash). A passthrough body over usize is malformed; drop the conn.
                    let Some(request_end) = head_len.checked_add(want) else {
                        return Ok(());
                    };
                    if buf.len() >= request_end {
                        let upstream_write = self.upstream().await?;
                        upstream_write.write_all(&buf[..request_end]).await?;
                        buf.drain(..request_end);
                    } else {
                        // Stream the rest of the body through without buffering it whole; bytes
                        // past the boundary belong to the next request and stay in `buf`.
                        let mut remaining = request_end - buf.len();
                        let upstream_write = self.upstream().await?;
                        upstream_write.write_all(&buf).await?;
                        buf.clear();
                        while remaining > 0 {
                            let n = client_read.read(&mut tmp).await?;
                            if n == 0 {
                                return Ok(());
                            }
                            let forward = n.min(remaining);
                            upstream_write.write_all(&tmp[..forward]).await?;
                            remaining -= forward;
                            if forward < n {
                                buf.extend_from_slice(&tmp[forward..n]);
                            }
                        }
                    }
                }
            }
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

fn is_chunked(head_text: &str) -> bool {
    for line in head_text.split("\r\n") {
        if let Some((name, value)) = line.split_once(':') {
            if name.trim().eq_ignore_ascii_case("transfer-encoding")
                && value.to_ascii_lowercase().contains("chunked")
            {
                return true;
            }
        }
    }
    false
}

enum ChunkedBody {
    NeedMore,
    Complete { body: Vec<u8>, consumed: usize },
    TooLarge,
    Malformed,
}

/// Decode one RFC 9112 chunked request body. `consumed` stops exactly after the terminating empty
/// trailer line so a keep-alive request already buffered behind it remains available to the loop.
fn decode_chunked_body(input: &[u8], max_decoded: usize) -> ChunkedBody {
    fn crlf(input: &[u8]) -> Option<usize> {
        input.windows(2).position(|window| window == b"\r\n")
    }

    let mut decoded = Vec::new();
    let mut position = 0usize;
    loop {
        let Some(line_len) = crlf(&input[position..]) else {
            return ChunkedBody::NeedMore;
        };
        if line_len > MAX_HEAD_BYTES {
            return ChunkedBody::Malformed;
        }
        let size_line = &input[position..position + line_len];
        let size_token = size_line
            .split(|byte| *byte == b';')
            .next()
            .unwrap_or_default();
        let Ok(size_text) = std::str::from_utf8(size_token) else {
            return ChunkedBody::Malformed;
        };
        let Ok(size) = usize::from_str_radix(size_text.trim(), 16) else {
            return ChunkedBody::Malformed;
        };
        position += line_len + 2;
        if size == 0 {
            // Consume optional trailer fields through their terminating empty line.
            loop {
                let Some(trailer_len) = crlf(&input[position..]) else {
                    return ChunkedBody::NeedMore;
                };
                if trailer_len > MAX_HEAD_BYTES {
                    return ChunkedBody::Malformed;
                }
                position += trailer_len + 2;
                if trailer_len == 0 {
                    return ChunkedBody::Complete {
                        body: decoded,
                        consumed: position,
                    };
                }
            }
        }
        if size > max_decoded.saturating_sub(decoded.len()) {
            return ChunkedBody::TooLarge;
        }
        let Some(chunk_end) = position.checked_add(size) else {
            return ChunkedBody::TooLarge;
        };
        let Some(framed_end) = chunk_end.checked_add(2) else {
            return ChunkedBody::TooLarge;
        };
        if input.len() < framed_end {
            return ChunkedBody::NeedMore;
        }
        if &input[chunk_end..framed_end] != b"\r\n" {
            return ChunkedBody::Malformed;
        }
        decoded.extend_from_slice(&input[position..chunk_end]);
        position = framed_end;
    }
}

/// Rebuild the request head with a corrected `Content-Length` (the rewrite changes the body length).
/// A decoded chunked create is forwarded as ordinary fixed-length JSON, so its framing headers must
/// not survive alongside Content-Length.
fn rebuild_head(head_text: &str, content_length: usize) -> Vec<u8> {
    let block = head_text.trim_end_matches("\r\n\r\n");
    let mut lines: Vec<String> = Vec::new();
    for (i, line) in block.split("\r\n").enumerate() {
        // Keep the request line (i == 0); drop framing headers replaced by Content-Length.
        if i > 0
            && line.split_once(':').is_some_and(|(n, _)| {
                let name = n.trim();
                name.eq_ignore_ascii_case("content-length")
                    || name.eq_ignore_ascii_case("transfer-encoding")
                    || name.eq_ignore_ascii_case("trailer")
            })
        {
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

fn ping_response(method: &str) -> &'static str {
    if method.eq_ignore_ascii_case("HEAD") {
        "HTTP/1.1 200 OK\r\nApi-Version: 1.47\r\nDocker-Experimental: false\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    } else {
        "HTTP/1.1 200 OK\r\nApi-Version: 1.47\r\nDocker-Experimental: false\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
    }
}

fn json_string(s: &str) -> String {
    serde_json::Value::String(s.to_string()).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Mutex;
    use tokio::io::AsyncReadExt;

    static NEXT_SOCKET_ID: AtomicU64 = AtomicU64::new(0);

    /// A keep-alive-faithful fake dockerd: serves any number of requests per connection, parsing
    /// each head + content-length body, recording the raw request bytes, and answering per path.
    /// An attach request upgrades the connection: 101, then echo raw bytes until EOF.
    struct FakeDockerd {
        captured: Arc<Mutex<Vec<u8>>>,
    }

    impl Backend for FakeDockerd {
        type Stream = UnixStream;
        fn connect(
            &self,
        ) -> Pin<Box<dyn Future<Output = std::io::Result<UnixStream>> + Send + '_>> {
            let captured = self.captured.clone();
            Box::pin(async move {
                let (ours, theirs) = UnixStream::pair()?;
                tokio::spawn(fake_dockerd_conn(theirs, captured));
                Ok(ours)
            })
        }
    }

    async fn fake_dockerd_conn(mut s: UnixStream, captured: Arc<Mutex<Vec<u8>>>) {
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        loop {
            let head_len = loop {
                if let Some(end) = head_end(&buf) {
                    break end;
                }
                match s.read(&mut tmp).await {
                    Ok(n) if n > 0 => buf.extend_from_slice(&tmp[..n]),
                    _ => return,
                }
            };
            let head_text = String::from_utf8_lossy(&buf[..head_len]).into_owned();
            let want = content_length(&head_text).unwrap_or(0);
            while buf.len() < head_len + want {
                match s.read(&mut tmp).await {
                    Ok(n) if n > 0 => buf.extend_from_slice(&tmp[..n]),
                    _ => return,
                }
            }
            let request_end = head_len + want;
            captured
                .lock()
                .unwrap()
                .extend_from_slice(&buf[..request_end]);
            let request_line = head_text.lines().next().unwrap_or("").to_string();

            if request_line.contains("/attach") {
                if s.write_all(b"HTTP/1.1 101 UPGRADED\r\n\r\n").await.is_err() {
                    return;
                }
                let leftover = buf[request_end..].to_vec();
                if !leftover.is_empty() {
                    captured.lock().unwrap().extend_from_slice(&leftover);
                    if s.write_all(&leftover).await.is_err() {
                        return;
                    }
                }
                loop {
                    match s.read(&mut tmp).await {
                        Ok(n) if n > 0 => {
                            captured.lock().unwrap().extend_from_slice(&tmp[..n]);
                            if s.write_all(&tmp[..n]).await.is_err() {
                                return;
                            }
                        }
                        _ => break,
                    }
                }
                let _ = s.shutdown().await;
                return;
            }

            let response: &[u8] = if request_line.contains("/containers/create") {
                b"HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n"
            } else {
                b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
            };
            if s.write_all(response).await.is_err() {
                return;
            }
            buf.drain(..request_end);
        }
    }

    /// Records every byte it receives, never responds; closes on client EOF. For asserting raw-tail
    /// forwarding where the CL-framed fake would mis-parse.
    struct RawSink {
        captured: Arc<Mutex<Vec<u8>>>,
    }

    impl Backend for RawSink {
        type Stream = UnixStream;
        fn connect(
            &self,
        ) -> Pin<Box<dyn Future<Output = std::io::Result<UnixStream>> + Send + '_>> {
            let captured = self.captured.clone();
            Box::pin(async move {
                let (ours, theirs) = UnixStream::pair()?;
                tokio::spawn(async move {
                    let mut s = theirs;
                    let mut tmp = [0u8; 4096];
                    loop {
                        match s.read(&mut tmp).await {
                            Ok(n) if n > 0 => captured.lock().unwrap().extend_from_slice(&tmp[..n]),
                            _ => break,
                        }
                    }
                });
                Ok(ours)
            })
        }
    }

    struct StaticInspectBackend {
        body: String,
        chunked: bool,
    }

    struct FailingInspectBackend;

    impl Backend for FailingInspectBackend {
        type Stream = UnixStream;

        fn connect(
            &self,
        ) -> Pin<Box<dyn Future<Output = std::io::Result<UnixStream>> + Send + '_>> {
            Box::pin(async {
                Err(std::io::Error::new(
                    std::io::ErrorKind::ConnectionRefused,
                    "fixture inspect transport failed",
                ))
            })
        }
    }

    impl Backend for StaticInspectBackend {
        type Stream = UnixStream;

        fn connect(
            &self,
        ) -> Pin<Box<dyn Future<Output = std::io::Result<UnixStream>> + Send + '_>> {
            let body = self.body.clone();
            let chunked = self.chunked;
            Box::pin(async move {
                let (ours, mut theirs) = UnixStream::pair()?;
                tokio::spawn(async move {
                    let mut request = Vec::new();
                    let mut chunk = [0u8; 4096];
                    while head_end(&request).is_none() {
                        match theirs.read(&mut chunk).await {
                            Ok(count) if count > 0 => request.extend_from_slice(&chunk[..count]),
                            _ => return,
                        }
                    }
                    assert!(
                        String::from_utf8_lossy(&request).starts_with("GET /containers/demo/json "),
                        "unexpected inspect request: {}",
                        String::from_utf8_lossy(&request)
                    );
                    let response = if chunked {
                        format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{:x}\r\n{}\r\n0\r\n\r\n",
                            body.len(), body
                        )
                    } else {
                        format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                            body.len(), body
                        )
                    };
                    let _ = theirs.write_all(response.as_bytes()).await;
                    let _ = theirs.shutdown().await;
                });
                Ok(ours)
            })
        }
    }

    async fn bind_temp_listener() -> (UnixListener, std::path::PathBuf) {
        let dir = std::env::temp_dir();
        let id = NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed);
        let path = dir.join(format!("dory-serve-{}-{id}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        (UnixListener::bind(&path).unwrap(), path)
    }

    async fn spawn_fake(gpu_supported: bool) -> (Arc<Mutex<Vec<u8>>>, std::path::PathBuf) {
        let captured = Arc::new(Mutex::new(Vec::new()));
        let backend = Arc::new(FakeDockerd {
            captured: captured.clone(),
        });
        let (listener, path) = bind_temp_listener().await;
        tokio::spawn(serve(
            listener,
            backend,
            Arc::new(ServeOpts {
                gpu_supported,
                activity: None,
            }),
        ));
        (captured, path)
    }

    /// Read exactly one HTTP response (head + content-length body) off the connection.
    async fn read_response(client: &mut UnixStream) -> String {
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        let head_len = loop {
            if let Some(end) = head_end(&buf) {
                break end;
            }
            let n = client.read(&mut tmp).await.expect("read response");
            assert!(
                n > 0,
                "eof before a full response head; got: {}",
                String::from_utf8_lossy(&buf)
            );
            buf.extend_from_slice(&tmp[..n]);
        };
        let want = content_length(std::str::from_utf8(&buf[..head_len]).unwrap_or("")).unwrap_or(0);
        while buf.len() < head_len + want {
            let n = client.read(&mut tmp).await.expect("read response body");
            assert!(n > 0, "eof mid response body");
            buf.extend_from_slice(&tmp[..n]);
        }
        String::from_utf8_lossy(&buf[..head_len + want]).into_owned()
    }

    fn create_request(body: &str) -> String {
        format!(
            "POST /v1.47/containers/create HTTP/1.1\r\nHost: d\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        )
    }

    const LOOPBACK_BODY: &str =
        r#"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}]}}}"#;

    #[test]
    fn fixed_host_port_preflight_rejects_an_existing_macos_listener() {
        let occupied = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = occupied.local_addr().unwrap().port();
        let body = format!(
            r#"{{"HostConfig":{{"PortBindings":{{"80/tcp":[{{"HostIp":"127.0.0.1","HostPort":"{port}"}}]}}}}}}"#
        );

        let error = preflight_fixed_host_ports(body.as_bytes()).unwrap_err();

        assert!(error.contains(&port.to_string()), "got: {error}");
        assert!(error.contains("tcp"), "got: {error}");
    }

    #[test]
    fn host_port_preflight_skips_dynamic_ports_and_maps_privileged_ports() {
        let dynamic = br#"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":""}],"53/udp":[{"HostPort":"0"}]}}}"#;
        assert!(requested_fixed_host_ports(dynamic).is_empty());

        let fixed = br#"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostIp":"127.0.0.1","HostPort":"80"}]}}}"#;
        assert_eq!(
            requested_fixed_host_ports(fixed),
            BTreeSet::from([(
                HostPortProtocol::Tcp,
                SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 60_080),
            )])
        );
    }

    #[tokio::test]
    async fn container_start_preflight_inspects_then_rejects_occupied_host_port() {
        let occupied = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = occupied.local_addr().unwrap().port();
        let backend = StaticInspectBackend {
            body: format!(
                r#"{{"HostConfig":{{"PortBindings":{{"8080/tcp":[{{"HostIp":"127.0.0.1","HostPort":"{port}"}}]}}}}}}"#
            ),
            chunked: true,
        };

        let error = preflight_container_start(&backend, "/containers/demo/start")
            .await
            .expect("occupied port must be rejected");

        assert!(error.contains(&port.to_string()), "got: {error}");
        assert!(error.contains("tcp"), "got: {error}");
    }

    #[tokio::test]
    async fn container_start_preflight_fails_closed_when_inspect_transport_fails() {
        let error = preflight_container_start(&FailingInspectBackend, "/containers/demo/start")
            .await
            .expect("an unverifiable host-port set must block start");

        assert!(
            error.contains("could not verify macOS host ports"),
            "got: {error}"
        );
        assert!(
            error.contains("fixture inspect transport failed"),
            "got: {error}"
        );
    }

    #[tokio::test]
    async fn create_body_is_rewritten_before_forwarding() {
        let (captured, path) = spawn_fake(false).await;

        let mut client = UnixStream::connect(&path).await.unwrap();
        client
            .write_all(create_request(LOOPBACK_BODY).as_bytes())
            .await
            .unwrap();
        client.shutdown().await.unwrap();
        let mut resp = Vec::new();
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            client.read_to_end(&mut resp),
        )
        .await;

        let got_text = String::from_utf8_lossy(&captured.lock().unwrap()).into_owned();
        assert!(
            got_text.contains("/containers/create"),
            "backend got the request"
        );
        // The loopback HostIp must have been emptied before forwarding.
        assert!(
            got_text.contains("\"HostIp\":\"\""),
            "HostIp rewritten; got: {got_text}"
        );
        assert!(got_text.contains("host-gateway"), "ExtraHosts injected");
        assert!(
            String::from_utf8_lossy(&resp).starts_with("HTTP/1.1 201"),
            "201 relayed back"
        );
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn chunked_create_body_is_decoded_rewritten_and_forwarded_as_fixed_length() {
        let (captured, path) = spawn_fake(false).await;
        let body =
            r#"{"HostConfig":{"Binds":["/tmp/test/.dory/engine.sock:/var/run/docker.sock:ro"]}}"#;
        let split = body.len() / 2;
        let request = format!(
            "POST /v1.54/containers/create HTTP/1.1\r\nHost: d\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nTrailer: X-Proof\r\n\r\n{:X};fixture=yes\r\n{}\r\n{:X}\r\n{}\r\n0\r\nX-Proof: complete\r\n\r\n",
            split,
            &body[..split],
            body.len() - split,
            &body[split..]
        );

        let mut client = UnixStream::connect(&path).await.unwrap();
        // Fragment the framing too: the proxy must keep reading until the zero chunk and trailers.
        let midpoint = request.len() / 2;
        client
            .write_all(&request.as_bytes()[..midpoint])
            .await
            .unwrap();
        tokio::task::yield_now().await;
        client
            .write_all(&request.as_bytes()[midpoint..])
            .await
            .unwrap();
        let response = read_response(&mut client).await;
        assert!(response.starts_with("HTTP/1.1 201"), "got: {response}");
        client.shutdown().await.unwrap();

        let got = String::from_utf8_lossy(&captured.lock().unwrap()).into_owned();
        assert!(
            got.contains("/containers/create"),
            "backend got create: {got}"
        );
        assert!(
            got.contains("/var/run/docker.sock:/var/run/docker.sock:ro"),
            "Dory socket bind rewritten: {got}"
        );
        assert!(!got.to_ascii_lowercase().contains("transfer-encoding"));
        assert!(!got.to_ascii_lowercase().contains("trailer:"));
        assert!(got.to_ascii_lowercase().contains("content-length:"));
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn gpu_request_gets_501_and_is_not_forwarded() {
        let (captured, path) = spawn_fake(false).await;

        let body = r#"{"HostConfig":{"DeviceRequests":[{"Capabilities":[["gpu"]]}]}}"#;
        let mut client = UnixStream::connect(&path).await.unwrap();
        client
            .write_all(create_request(body).as_bytes())
            .await
            .unwrap();
        let mut resp = Vec::new();
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            client.read_to_end(&mut resp),
        )
        .await;

        let resp_text = String::from_utf8_lossy(&resp);
        assert!(resp_text.starts_with("HTTP/1.1 501"), "got: {resp_text}");
        assert!(
            captured.lock().unwrap().is_empty(),
            "backend must NOT be dialed for an unsupported GPU request"
        );
        let _ = std::fs::remove_file(&path);
    }

    /// THE keep-alive regression (proven on hardware 2026-07-07): the docker CLI reuses one
    /// connection for `GET /_ping` then `POST create`. The second request must still be classified
    /// and rewritten, not spliced through raw.
    #[tokio::test]
    async fn keepalive_second_request_create_is_still_rewritten() {
        let (captured, path) = spawn_fake(false).await;

        let mut client = UnixStream::connect(&path).await.unwrap();
        client
            .write_all(b"GET /_ping HTTP/1.1\r\nHost: d\r\n\r\n")
            .await
            .unwrap();
        let ping = read_response(&mut client).await;
        assert!(ping.starts_with("HTTP/1.1 200"), "ping relayed: {ping}");

        client
            .write_all(create_request(LOOPBACK_BODY).as_bytes())
            .await
            .unwrap();
        let create = read_response(&mut client).await;
        assert!(
            create.starts_with("HTTP/1.1 201"),
            "create relayed: {create}"
        );
        client.shutdown().await.unwrap();

        let got_text = String::from_utf8_lossy(&captured.lock().unwrap()).into_owned();
        assert!(got_text.contains("/_ping"), "ping reached the backend");
        assert!(
            got_text.contains("\"HostIp\":\"\""),
            "create on the REUSED connection was rewritten; got: {got_text}"
        );
        assert!(
            got_text.contains("host-gateway"),
            "ExtraHosts injected on the reused connection"
        );
        let _ = std::fs::remove_file(&path);
    }

    /// Supabase's Go Docker client pulls all stack images, consumes each streamed response, then
    /// reuses a pooled connection for Vector's create. A pull is not an HTTP upgrade and must not
    /// permanently turn that connection into an unclassified raw splice.
    #[tokio::test]
    async fn keepalive_create_after_streamed_image_pull_is_still_rewritten() {
        let (captured, path) = spawn_fake(false).await;
        let mut client = UnixStream::connect(&path).await.unwrap();

        client
            .write_all(
                b"POST /v1.54/images/create?fromImage=alpine&tag=3.20 HTTP/1.1\r\nHost: d\r\nContent-Length: 0\r\n\r\n",
            )
            .await
            .unwrap();
        assert!(read_response(&mut client).await.starts_with("HTTP/1.1 200"));

        let body =
            r#"{"HostConfig":{"Binds":["/tmp/test/.dory/engine.sock:/var/run/docker.sock:ro"]}}"#;
        client
            .write_all(create_request(body).as_bytes())
            .await
            .unwrap();
        assert!(read_response(&mut client).await.starts_with("HTTP/1.1 201"));
        client.shutdown().await.unwrap();

        let got = String::from_utf8_lossy(&captured.lock().unwrap()).into_owned();
        assert!(
            got.contains("/images/create"),
            "pull reached backend: {got}"
        );
        assert!(
            got.contains("/var/run/docker.sock:/var/run/docker.sock:ro"),
            "post-pull create was rewritten: {got}"
        );
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn keepalive_gpu_create_after_ping_is_rejected_and_never_reaches_dockerd() {
        let (captured, path) = spawn_fake(false).await;

        let mut client = UnixStream::connect(&path).await.unwrap();
        client
            .write_all(b"GET /_ping HTTP/1.1\r\nHost: d\r\n\r\n")
            .await
            .unwrap();
        assert!(read_response(&mut client).await.starts_with("HTTP/1.1 200"));

        let body = r#"{"HostConfig":{"DeviceRequests":[{"Capabilities":[["gpu"]]}]}}"#;
        client
            .write_all(create_request(body).as_bytes())
            .await
            .unwrap();
        let mut resp = Vec::new();
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            client.read_to_end(&mut resp),
        )
        .await;

        assert!(
            String::from_utf8_lossy(&resp).starts_with("HTTP/1.1 501"),
            "501 on the reused connection"
        );
        let got_text = String::from_utf8_lossy(&captured.lock().unwrap()).into_owned();
        assert!(got_text.contains("/_ping"), "ping reached the backend");
        assert!(
            !got_text.contains("/containers/create"),
            "GPU create must NOT reach the backend: {got_text}"
        );
        let _ = std::fs::remove_file(&path);
    }

    /// A hijack mid-connection (ping, then attach) must replay the head and splice raw with
    /// half-close: the client's SHUT_WR after sending stdin still lets the echoed stream back.
    #[tokio::test]
    async fn keepalive_hijack_after_ping_splices_with_half_close() {
        let (captured, path) = spawn_fake(false).await;

        let mut client = UnixStream::connect(&path).await.unwrap();
        client
            .write_all(b"GET /_ping HTTP/1.1\r\nHost: d\r\n\r\n")
            .await
            .unwrap();
        assert!(read_response(&mut client).await.starts_with("HTTP/1.1 200"));

        client
            .write_all(b"POST /v1.47/containers/abc/attach?stream=1 HTTP/1.1\r\nHost: d\r\nUpgrade: tcp\r\nConnection: Upgrade\r\n\r\nstdin-bytes")
            .await
            .unwrap();
        client.shutdown().await.unwrap();

        let mut resp = Vec::new();
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            client.read_to_end(&mut resp),
        )
        .await;
        let resp_text = String::from_utf8_lossy(&resp);
        assert!(
            resp_text.contains("101 UPGRADED"),
            "upgrade relayed: {resp_text}"
        );
        assert!(
            resp_text.contains("stdin-bytes"),
            "post-upgrade bytes echoed back after client SHUT_WR: {resp_text}"
        );
        let got_text = String::from_utf8_lossy(&captured.lock().unwrap()).into_owned();
        assert!(
            got_text.contains("/attach"),
            "attach head reached the backend"
        );
        assert!(
            got_text.contains("stdin-bytes"),
            "raw hijack bytes reached the backend"
        );
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn activity_reports_meaningful_connection_but_exempts_ping() {
        let (activity_listener, activity_path) = bind_temp_listener().await;
        let events = Arc::new(Mutex::new(Vec::<String>::new()));
        let event_sink = events.clone();
        tokio::spawn(async move {
            for _ in 0..2 {
                let (mut s, _) = activity_listener.accept().await.unwrap();
                let mut line = Vec::new();
                s.read_to_end(&mut line).await.unwrap();
                event_sink
                    .lock()
                    .unwrap()
                    .push(String::from_utf8_lossy(&line).into_owned());
            }
        });

        let captured = Arc::new(Mutex::new(Vec::new()));
        let backend = Arc::new(FakeDockerd { captured });
        let (listener, path) = bind_temp_listener().await;
        tokio::spawn(serve(
            listener,
            backend,
            Arc::new(ServeOpts {
                gpu_supported: false,
                activity: Some(ActivityReporter::new(activity_path.clone())),
            }),
        ));

        let mut client = UnixStream::connect(&path).await.unwrap();
        client
            .write_all(b"GET /_ping HTTP/1.1\r\nHost: d\r\n\r\n")
            .await
            .unwrap();
        assert!(read_response(&mut client).await.starts_with("HTTP/1.1 200"));

        let mut client = UnixStream::connect(&path).await.unwrap();
        client
            .write_all(b"GET /version HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            .await
            .unwrap();
        assert!(read_response(&mut client).await.starts_with("HTTP/1.1 200"));
        client.shutdown().await.unwrap();
        let mut drain = Vec::new();
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            client.read_to_end(&mut drain),
        )
        .await;

        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if events.lock().unwrap().len() >= 2 {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();

        let got = events.lock().unwrap().clone();
        assert_eq!(got[0], "begin\tGET\t/version\n");
        assert_eq!(got[1], "end\n");
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(&activity_path);
    }

    /// A chunked passthrough body has no boundary we track; the connection degrades to a raw tail
    /// and every byte still reaches the backend verbatim.
    #[tokio::test]
    async fn chunked_passthrough_degrades_to_raw_tail() {
        let captured = Arc::new(Mutex::new(Vec::new()));
        let backend = Arc::new(RawSink {
            captured: captured.clone(),
        });
        let (listener, path) = bind_temp_listener().await;
        tokio::spawn(serve(
            listener,
            backend,
            Arc::new(ServeOpts {
                gpu_supported: false,
                activity: None,
            }),
        ));

        let raw = b"PUT /v1.47/containers/abc/archive?path=/ HTTP/1.1\r\nHost: d\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n";
        let mut client = UnixStream::connect(&path).await.unwrap();
        client.write_all(raw).await.unwrap();
        client.shutdown().await.unwrap();
        let mut resp = Vec::new();
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            client.read_to_end(&mut resp),
        )
        .await;

        let got = captured.lock().unwrap().clone();
        assert_eq!(got, raw.to_vec(), "chunked request forwarded byte-exact");
        let _ = std::fs::remove_file(&path);
    }

    /// An absurd Content-Length on a create must not panic (with panic=abort that would abort the
    /// whole dataplane process). It is rejected with a 413 and the backend is never dialed.
    #[tokio::test]
    async fn absurd_content_length_on_create_is_rejected_not_a_panic() {
        let (captured, path) = spawn_fake(false).await;

        let mut client = UnixStream::connect(&path).await.unwrap();
        // usize::MAX Content-Length with only the head on the wire.
        client
            .write_all(b"POST /v1.47/containers/create HTTP/1.1\r\nHost: d\r\nContent-Length: 18446744073709551615\r\n\r\n")
            .await
            .unwrap();
        let mut resp = Vec::new();
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            client.read_to_end(&mut resp),
        )
        .await;

        assert!(
            String::from_utf8_lossy(&resp).starts_with("HTTP/1.1 413"),
            "got: {}",
            String::from_utf8_lossy(&resp)
        );
        assert!(
            captured.lock().unwrap().is_empty(),
            "backend must not be dialed for a rejected create"
        );
        let _ = std::fs::remove_file(&path);
    }

    /// The same overflow class on a passthrough request must drop the connection cleanly, not panic.
    #[tokio::test]
    async fn absurd_content_length_on_passthrough_does_not_panic() {
        let captured = Arc::new(Mutex::new(Vec::new()));
        let backend = Arc::new(RawSink { captured });
        let (listener, path) = bind_temp_listener().await;
        tokio::spawn(serve(
            listener,
            backend,
            Arc::new(ServeOpts {
                gpu_supported: false,
                activity: None,
            }),
        ));

        let mut client = UnixStream::connect(&path).await.unwrap();
        client
            .write_all(b"POST /v1.47/containers/abc/update HTTP/1.1\r\nHost: d\r\nContent-Length: 18446744073709551615\r\n\r\n")
            .await
            .unwrap();
        let mut resp = Vec::new();
        // The connection is dropped; read_to_end returns without a panic bringing down the process.
        let r = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            client.read_to_end(&mut resp),
        )
        .await;
        assert!(r.is_ok(), "connection should close, not hang");
        let _ = std::fs::remove_file(&path);
    }

    /// ForwardBackend must write a HostToGuest docker-port preamble before the request, exactly what
    /// dory-hv expects to open a guest vsock stream — then the (rewritten) request follows.
    #[tokio::test]
    async fn forward_backend_writes_preamble_then_request() {
        use dory_proto::preamble::{read_preamble, Direction};

        // Fake dory-hv forward: read the preamble, then the forwarded request.
        let (fwd_listener, fwd_path) = bind_temp_listener().await;
        let got_preamble = Arc::new(Mutex::new(None));
        let got_request = Arc::new(Mutex::new(Vec::new()));
        let (gp, gr) = (got_preamble.clone(), got_request.clone());
        tokio::spawn(async move {
            let (mut s, _) = fwd_listener.accept().await.unwrap();
            let preamble = read_preamble(&mut s).await.unwrap();
            *gp.lock().unwrap() = Some(preamble);
            let mut req = Vec::new();
            let mut tmp = [0u8; 4096];
            loop {
                match tokio::time::timeout(std::time::Duration::from_millis(300), s.read(&mut tmp))
                    .await
                {
                    Ok(Ok(n)) if n > 0 => req.extend_from_slice(&tmp[..n]),
                    _ => break,
                }
            }
            *gr.lock().unwrap() = req;
            let _ = s
                .write_all(b"HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n")
                .await;
            let _ = s.shutdown().await;
        });

        let backend = Arc::new(ForwardBackend {
            forward_socket: fwd_path.clone(),
            cid: 3,
            port: dory_proto::channels::PORT_DOCKER,
            retry_for: None,
        });
        let (listener, path) = bind_temp_listener().await;
        tokio::spawn(serve(
            listener,
            backend,
            Arc::new(ServeOpts {
                gpu_supported: false,
                activity: None,
            }),
        ));

        let mut client = UnixStream::connect(&path).await.unwrap();
        client
            .write_all(create_request(LOOPBACK_BODY).as_bytes())
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
        assert_eq!(preamble.port, dory_proto::channels::PORT_DOCKER);
        let request = String::from_utf8_lossy(&got_request.lock().unwrap()).into_owned();
        assert!(
            request.contains("/containers/create"),
            "forwarded request: {request}"
        );
        assert!(
            request.contains("\"HostIp\":\"\""),
            "body rewritten: {request}"
        );

        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(&fwd_path);
    }
}
