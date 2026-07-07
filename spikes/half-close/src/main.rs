// Spike: does a Rust proxy preserve TCP/unix half-close (SHUT_WR) the way `docker run`/attach needs?
//
// The docker-attach failure mode: the client sends stdin, then half-closes its WRITE side
// (shutdown(SHUT_WR)) but keeps READING stdout. A naive proxy that tears down BOTH directions when
// either read hits EOF will truncate the container's stdout. This spike drives exactly that pattern
// through (A) tokio::io::copy_bidirectional and (B) a hand-rolled per-direction splice, and asserts
// the reply written by the peer AFTER the client's half-close still arrives in full.

use std::time::Duration;
use tokio::io::{copy_bidirectional, AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

const STDIN: &[u8] = b"STDIN-DATA-FROM-CLIENT";
const REPLY_AFTER_HALFCLOSE: &[u8] = b"REPLY-WRITTEN-AFTER-CLIENT-HALF-CLOSED";

// The peer ("container dockerd side"): read stdin to EOF (which only arrives if the client's SHUT_WR
// propagated across the proxy), then write a reply, then close. If the proxy collapsed both
// directions on the client's EOF, this reply never reaches the client.
async fn peer(mut s: UnixStream) -> String {
    let mut got = Vec::new();
    let mut tmp = [0u8; 512];
    loop {
        let n = s.read(&mut tmp).await.expect("peer read");
        if n == 0 {
            break;
        }
        got.extend_from_slice(&tmp[..n]);
    }
    s.write_all(REPLY_AFTER_HALFCLOSE).await.expect("peer write reply");
    s.shutdown().await.expect("peer shutdown");
    String::from_utf8_lossy(&got).into_owned()
}

// The docker CLI side: write stdin, half-close the write half, then read the reply to EOF.
async fn client(mut s: UnixStream) -> String {
    s.write_all(STDIN).await.expect("client write stdin");
    s.shutdown().await.expect("client SHUT_WR"); // half-close write; keep reading
    let mut got = Vec::new();
    let mut tmp = [0u8; 512];
    loop {
        let n = s.read(&mut tmp).await.expect("client read reply");
        if n == 0 {
            break;
        }
        got.extend_from_slice(&tmp[..n]);
    }
    String::from_utf8_lossy(&got).into_owned()
}

// Manual asymmetric splice: copy each direction independently, and when a direction hits EOF,
// shut down ONLY the corresponding write half (never the other direction). This is the fallback the
// design names if copy_bidirectional ever regresses.
async fn manual_splice(a: UnixStream, b: UnixStream) {
    let (mut ar, mut aw) = a.into_split();
    let (mut br, mut bw) = b.into_split();
    let a2b = tokio::spawn(async move {
        tokio::io::copy(&mut ar, &mut bw).await.ok();
        bw.shutdown().await.ok(); // a EOF -> shut down write to b only
    });
    let b2a = tokio::spawn(async move {
        tokio::io::copy(&mut br, &mut aw).await.ok();
        aw.shutdown().await.ok();
    });
    let _ = tokio::join!(a2b, b2a);
}

async fn run_case(use_copy_bidirectional: bool) -> Result<(), String> {
    let (client_end, proxy_a) = UnixStream::pair().map_err(|e| e.to_string())?;
    let (peer_end, proxy_b) = UnixStream::pair().map_err(|e| e.to_string())?;

    let proxy = tokio::spawn(async move {
        if use_copy_bidirectional {
            let mut a = proxy_a;
            let mut b = proxy_b;
            copy_bidirectional(&mut a, &mut b).await.ok();
        } else {
            manual_splice(proxy_a, proxy_b).await;
        }
    });

    let peer_task = tokio::spawn(peer(peer_end));
    let client_task = tokio::spawn(client(client_end));

    let all = async {
        let got_stdin = peer_task.await.map_err(|e| e.to_string())?;
        let got_reply = client_task.await.map_err(|e| e.to_string())?;
        proxy.await.map_err(|e| e.to_string())?;
        Ok::<(String, String), String>((got_stdin, got_reply))
    };

    // A broken half-close would block the client's read forever -> catch as FAIL, not a hang.
    let (got_stdin, got_reply) = tokio::time::timeout(Duration::from_secs(5), all)
        .await
        .map_err(|_| "TIMEOUT (half-close likely collapsed both directions; client read never got EOF)".to_string())??;

    if got_stdin.as_bytes() != STDIN {
        return Err(format!("peer got wrong stdin: {got_stdin:?}"));
    }
    if got_reply.as_bytes() != REPLY_AFTER_HALFCLOSE {
        return Err(format!(
            "client did NOT get the post-half-close reply (got {got_reply:?}) — proxy truncated the peer->client direction"
        ));
    }
    Ok(())
}

#[tokio::main]
async fn main() {
    let mut failures = 0;
    for (name, use_cb) in [("copy_bidirectional", true), ("manual_splice", false)] {
        match run_case(use_cb).await {
            Ok(()) => println!("PASS  {name}: half-close preserved; post-half-close reply delivered in full"),
            Err(e) => {
                println!("FAIL  {name}: {e}");
                failures += 1;
            }
        }
    }
    if failures == 0 {
        println!("\nSPIKE RESULT: half-close over UnixStream is correct — docker attach/exec will not truncate.");
    } else {
        println!("\nSPIKE RESULT: {failures} case(s) failed.");
        std::process::exit(1);
    }
}
