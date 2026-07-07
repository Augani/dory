//! The guest-side vsock server (Linux only). Accepts the control channel (mux over RPC dispatch) and
//! the docker byte-stream (spliced to the guest `dockerd`). Cross-checks for the musl targets; runs
//! for real only inside a Dory guest.
#![cfg(target_os = "linux")]

use std::sync::Arc;

use dory_proto::channels::{PORT_CONTROL, PORT_DOCKER};
use dory_proto::half_close::splice;
use dory_proto::handshake::{handshake, Hello};
use dory_proto::mux::{Handler, HandlerFuture, Mux};
use tokio::net::UnixStream;
use tokio_vsock::{VsockAddr, VsockListener, VMADDR_CID_ANY};

use crate::dispatch::agent_build;
use crate::handler::handle;

const GUEST_DOCKER_SOCK: &str = "/var/run/docker.sock";

pub async fn run() -> std::io::Result<()> {
    tokio::try_join!(serve_control(), serve_docker())?;
    Ok(())
}

/// Control channel: one mux per connection, handler = the RPC dispatcher.
async fn serve_control() -> std::io::Result<()> {
    let listener = VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, PORT_CONTROL))?;
    loop {
        let (mut stream, _peer) = listener.accept().await?;
        tokio::spawn(async move {
            if handshake(&mut stream, &Hello::current(agent_build())).await.is_err() {
                return;
            }
            let handler: Handler =
                Arc::new(|req: Vec<u8>| Box::pin(async move { handle(&req).await }) as HandlerFuture);
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
        let (client, _peer) = listener.accept().await?;
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
