//! Dev harness for the docker-tier integration: serve a docker socket through a [`ForwardBackend`]
//! pointed at `dory-hv --agent-vsock-forward`. This is the same serve path `dory-ffi`'s
//! `startDataplaneForward` drives, runnable standalone for on-hardware smoke tests:
//!
//! ```sh
//! dory-hv engine … --agent-vsock-forward /tmp/fwd.sock &
//! cargo run -p dory-dataplane --example forward_serve -- /tmp/dory.sock /tmp/fwd.sock
//! docker -H unix:///tmp/dory.sock run --rm alpine echo hi
//! ```

use dory_dataplane::{serve, ForwardBackend, ServeOpts};
use std::sync::Arc;
use tokio::net::UnixListener;

const USAGE: &str = "usage: forward_serve <listen.sock> <forward.sock> [cid] [port]";

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> std::io::Result<()> {
    let mut args = std::env::args().skip(1);
    let listen = args.next().expect(USAGE);
    let forward = args.next().expect(USAGE);
    let cid: u32 = args.next().map(|s| s.parse().expect(USAGE)).unwrap_or(3);
    let port: u32 = args
        .next()
        .map(|s| s.parse().expect(USAGE))
        .unwrap_or(dory_proto::channels::PORT_DOCKER);

    let _ = std::fs::remove_file(&listen);
    let listener = UnixListener::bind(&listen)?;
    eprintln!("forward_serve: {listen} -> {forward} (cid {cid}, port {port})");
    serve(
        listener,
        Arc::new(ForwardBackend {
            forward_socket: forward.into(),
            cid,
            port,
            retry_for: None,
        }),
        Arc::new(ServeOpts {
            gpu_supported: false,
            activity: None,
        }),
    )
    .await
}
