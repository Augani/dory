//! Daemon-mode control server: the same protocol as the guest vsock server (`vsock_server`), but
//! over a TCP or unix listener. This is how `dory-agent` runs on a remote VPS — `doryd`'s `remote`
//! stack SSH-tunnels a channel to this listener and speaks the identical `handshake + mux + dispatch`
//! it speaks over VZ vsock. No vsock here, so it is portable and exercised on the host in tests.

use std::net::SocketAddr;
use std::sync::Arc;

use dory_proto::handshake::{handshake, Hello};
use dory_proto::mux::{Handler, HandlerFuture, Mux};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpListener;

use crate::dispatch::agent_build;
use crate::handler::handle;

/// The control protocol carries `Exec`, and daemon mode has no in-band authentication: it is
/// reachable only through the SSH tunnel doryd opens to the loopback listener. Enforce that
/// contract at both ends — refuse to serve a routable listener, and drop non-loopback peers — so a
/// misconfigured `--daemon <addr>` cannot turn into unauthenticated remote execution.
pub fn is_loopback_listen_addr(address: &SocketAddr) -> bool {
    address.ip().is_loopback()
}

pub fn is_loopback_peer(peer: &SocketAddr) -> bool {
    match peer.ip() {
        std::net::IpAddr::V4(address) => address.is_loopback(),
        std::net::IpAddr::V6(address) => {
            address.is_loopback() || address.to_ipv4_mapped().is_some_and(|v4| v4.is_loopback())
        }
    }
}

/// Accept loop over a bound TCP listener; one control mux per connection.
pub async fn serve(listener: TcpListener) -> std::io::Result<()> {
    let local = listener.local_addr()?;
    if !is_loopback_listen_addr(&local) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!(
                "dory-agent daemon refuses to serve unauthenticated control on {local}: \
                 bind a loopback address and reach it through an SSH tunnel"
            ),
        ));
    }
    loop {
        let (stream, peer) = listener.accept().await?;
        if !is_loopback_peer(&peer) {
            continue;
        }
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, Ipv6Addr};

    #[test]
    fn only_loopback_listeners_may_serve_unauthenticated_control() {
        assert!(is_loopback_listen_addr(&SocketAddr::from((
            Ipv4Addr::LOCALHOST,
            2377
        ))));
        assert!(is_loopback_listen_addr(&SocketAddr::from((
            Ipv6Addr::LOCALHOST,
            2377
        ))));
        assert!(!is_loopback_listen_addr(&SocketAddr::from((
            Ipv4Addr::UNSPECIFIED,
            2377
        ))));
        assert!(!is_loopback_listen_addr(&SocketAddr::from((
            Ipv6Addr::UNSPECIFIED,
            2377
        ))));
        assert!(!is_loopback_listen_addr(&SocketAddr::from((
            Ipv4Addr::new(203, 0, 113, 7),
            2377
        ))));
    }

    #[test]
    fn only_loopback_peers_are_admitted() {
        assert!(is_loopback_peer(&SocketAddr::from((
            Ipv4Addr::new(127, 0, 0, 2),
            40000
        ))));
        assert!(is_loopback_peer(&SocketAddr::from((
            Ipv6Addr::LOCALHOST,
            40000
        ))));
        // IPv4-mapped loopback arrives on a dual-stack listener as ::ffff:127.0.0.1.
        assert!(is_loopback_peer(&SocketAddr::from((
            Ipv4Addr::LOCALHOST.to_ipv6_mapped(),
            40000
        ))));
        assert!(!is_loopback_peer(&SocketAddr::from((
            Ipv4Addr::new(192, 168, 1, 10),
            40000
        ))));
        assert!(!is_loopback_peer(&SocketAddr::from((
            Ipv4Addr::new(192, 168, 1, 10).to_ipv6_mapped(),
            40000
        ))));
    }

    #[tokio::test]
    async fn serve_refuses_a_routable_listener() {
        let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0)).await.unwrap();
        let error = serve(listener).await.expect_err("wildcard bind must fail");
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
    }
}
