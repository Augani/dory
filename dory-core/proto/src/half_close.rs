//! Bidirectional byte splice that preserves half-close.
//!
//! `docker` (and interactive `exec`/attach) half-closes its *write* half — `shutdown(SHUT_WR)` —
//! the moment stdin is done, while it keeps *reading* stdout. A proxy that tears down both
//! directions when either read hits EOF truncates the container's output. [`splice`] copies each
//! direction independently and, on that direction's EOF, shuts down **only** the corresponding write
//! half — so the other direction stays open until its own peer closes. Verified against `docker run`
//! attach in `spikes/`. Works over any `AsyncRead + AsyncWrite` (unix, vsock, TCP): the guarantee is
//! that the stream's `poll_shutdown` performs a real `shutdown(SHUT_WR)` (tokio `UnixStream`/`TcpStream`
//! and `tokio-vsock` `VsockStream` all do).

use tokio::io::{copy, AsyncRead, AsyncWrite, AsyncWriteExt};

/// Splice `a` and `b` until both directions close, returning `(a→b bytes, b→a bytes)`.
///
/// Each direction is copied to its peer's write half; when a source EOFs, its destination's write
/// half is shut down (half-close propagated) while the reverse direction keeps flowing. Returns the
/// first transport error encountered.
pub async fn splice<A, B>(a: A, b: B) -> std::io::Result<(u64, u64)>
where
    A: AsyncRead + AsyncWrite + Unpin,
    B: AsyncRead + AsyncWrite + Unpin,
{
    let (mut ar, mut aw) = tokio::io::split(a);
    let (mut br, mut bw) = tokio::io::split(b);

    let a_to_b = async {
        let n = copy(&mut ar, &mut bw).await?;
        // Source `a` reached EOF: propagate the half-close to `b`'s write side only.
        let _ = bw.shutdown().await;
        Ok::<u64, std::io::Error>(n)
    };
    let b_to_a = async {
        let n = copy(&mut br, &mut aw).await?;
        let _ = aw.shutdown().await;
        Ok::<u64, std::io::Error>(n)
    };

    let (ab, ba) = tokio::join!(a_to_b, b_to_a);
    Ok((ab?, ba?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::UnixStream;

    const STDIN: &[u8] = b"STDIN-FROM-DOCKER-CLIENT";
    const REPLY_AFTER_HALFCLOSE: &[u8] = b"CONTAINER-STDOUT-WRITTEN-AFTER-CLIENT-HALF-CLOSED";

    /// The docker-attach pattern: client writes stdin, half-closes write, keeps reading; the peer
    /// replies only AFTER seeing the client's EOF. If the splice collapsed both directions, the
    /// reply would be lost and the client read would hang (caught by the timeout).
    #[tokio::test]
    async fn preserves_half_close_for_attach() {
        let (client_end, proxy_a) = UnixStream::pair().unwrap();
        let (peer_end, proxy_b) = UnixStream::pair().unwrap();

        let proxy = tokio::spawn(async move { splice(proxy_a, proxy_b).await });

        let peer = tokio::spawn(async move {
            let mut s = peer_end;
            let mut got = Vec::new();
            let mut tmp = [0u8; 256];
            loop {
                let n = s.read(&mut tmp).await.unwrap();
                if n == 0 {
                    break;
                }
                got.extend_from_slice(&tmp[..n]);
            }
            s.write_all(REPLY_AFTER_HALFCLOSE).await.unwrap();
            s.shutdown().await.unwrap();
            got
        });

        let client = tokio::spawn(async move {
            let mut s = client_end;
            s.write_all(STDIN).await.unwrap();
            s.shutdown().await.unwrap(); // SHUT_WR: done sending stdin, keep reading stdout
            let mut got = Vec::new();
            let mut tmp = [0u8; 256];
            loop {
                let n = s.read(&mut tmp).await.unwrap();
                if n == 0 {
                    break;
                }
                got.extend_from_slice(&tmp[..n]);
            }
            got
        });

        let run = async {
            let peer_got = peer.await.unwrap();
            let client_got = client.await.unwrap();
            proxy.await.unwrap().unwrap();
            (peer_got, client_got)
        };
        let (peer_got, client_got) = tokio::time::timeout(Duration::from_secs(5), run)
            .await
            .expect("half-close collapsed: client read hung");

        assert_eq!(
            peer_got, STDIN,
            "peer must receive the stdin sent before half-close"
        );
        assert_eq!(
            client_got, REPLY_AFTER_HALFCLOSE,
            "client must receive the reply written AFTER its half-close (peer->client stayed open)"
        );
    }
}
