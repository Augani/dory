//! Daemon-mode control server: the same protocol as the guest vsock server (`vsock_server`), but
//! over a TCP or unix listener. This is how `dory-agent` runs on a remote VPS — `doryd`'s `remote`
//! stack SSH-tunnels a channel to this listener and speaks the identical `handshake + mux + dispatch`
//! it speaks over VZ vsock. No vsock here, so it is portable and exercised on the host in tests.

use std::sync::Arc;

use dory_proto::handshake::{handshake, Hello};
use dory_proto::mux::{Handler, HandlerFuture, Mux};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpListener;

use crate::dispatch::agent_build;
use crate::handler::handle;

/// Accept loop over a bound TCP listener; one control mux per connection.
pub async fn serve(listener: TcpListener) -> std::io::Result<()> {
    loop {
        let (stream, _peer) = listener.accept().await?;
        tokio::spawn(async move {
            serve_conn(stream).await;
        });
    }
}

/// Serve one control connection: versioned handshake, then a mux whose handler is the dispatcher.
/// Generic over the stream so a unix/vsock/loopback transport reuses it. The mux owns the connection
/// via its own reader/writer tasks (which hold clones of the outbound sender), so returning here
/// does not close it — it serves until the peer disconnects, exactly like the vsock server.
pub async fn serve_conn<S>(mut stream: S)
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    if handshake(&mut stream, &Hello::current(agent_build()))
        .await
        .is_err()
    {
        return;
    }
    let handler: Handler =
        Arc::new(|req: Vec<u8>| Box::pin(async move { handle(&req).await }) as HandlerFuture);
    let _mux = Mux::start(stream, handler);
}
