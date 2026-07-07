// Spike: does `tokio-vsock` give the Rust guest agent everything it needs, and cross-compile to the
// guest musl targets? This is `cargo check`-only from macOS (AF_VSOCK is Linux; running needs a VZ
// guest). We prove: (1) it builds for aarch64/x86_64-unknown-linux-musl, (2) the API covers a
// LISTENER (host->guest streams: docker, agent RPC) and a CID_HOST connect (guest->host dial-back:
// the AI bridge), (3) VsockStream is a real async R/W with a shutdown (half-close over vsock).
//
// The whole thing is behind cfg(target_os="linux") because tokio-vsock is Linux-only; on macOS the
// crate still resolves for `cargo check --target ...-linux-musl`.

#[cfg(target_os = "linux")]
mod guest {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio_vsock::{VsockAddr, VsockListener, VsockStream, VMADDR_CID_ANY, VMADDR_CID_HOST};

    // Host -> guest: the agent listens on a vsock port (docker=1026, control=1024, etc.).
    pub async fn serve(port: u32) -> std::io::Result<()> {
        let listener = VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, port))?;
        loop {
            let (mut stream, _peer) = listener.accept().await?;
            tokio::spawn(async move {
                let mut buf = [0u8; 4096];
                // real AsyncRead/AsyncWrite -> can be spliced with copy_bidirectional
                let n = stream.read(&mut buf).await.unwrap_or(0);
                let _ = stream.write_all(&buf[..n]).await;
                // Async half-close via the AsyncWrite trait — this is what copy_bidirectional's
                // poll_shutdown drives. (VsockStream ALSO exposes an inherent, synchronous
                // `shutdown(std::net::Shutdown::Write)` for an explicit socket-level SHUT_WR.)
                let _ = tokio::io::AsyncWriteExt::shutdown(&mut stream).await;
                stream.shutdown(std::net::Shutdown::Write).ok();
            });
        }
    }

    // Guest -> host dial-back: connect to VMADDR_CID_HOST (=2) — the AI bridge / host-service pattern.
    pub async fn dial_host(port: u32) -> std::io::Result<VsockStream> {
        VsockStream::connect(VsockAddr::new(VMADDR_CID_HOST, port)).await
    }

    // Prove the stream is spliceable both ways (what the dataplane actually does).
    pub async fn splice_demo(a: VsockStream, b: VsockStream) {
        let (mut ar, mut aw) = tokio::io::split(a);
        let (mut br, mut bw) = tokio::io::split(b);
        let f = async move {
            tokio::io::copy(&mut ar, &mut bw).await.ok();
            bw.shutdown().await.ok();
        };
        let g = async move {
            tokio::io::copy(&mut br, &mut aw).await.ok();
            aw.shutdown().await.ok();
        };
        tokio::join!(f, g);
    }

    pub fn assert_constants() {
        // These must exist for the port catalog + dial-back.
        let _host: u32 = VMADDR_CID_HOST;
        let _any: u32 = VMADDR_CID_ANY;
    }
}

fn main() {
    #[cfg(target_os = "linux")]
    {
        guest::assert_constants();
        // Reference the async fns so they're type-checked (not run on macOS / without a guest).
        let _ = guest::serve;
        let _ = guest::dial_host;
        let _ = guest::splice_demo;
        println!("vsock guest API type-checks: listener + CID_HOST connect + async R/W + shutdown");
    }
    #[cfg(not(target_os = "linux"))]
    println!("host build: nothing to run (AF_VSOCK is Linux-only)");
}
