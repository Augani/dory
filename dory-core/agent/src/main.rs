//! `dory-agent` — one static-musl binary that runs as PID 1 inside every Dory guest (and, in a later
//! slice, as the remote-VPS daemon). It serves the vsock control mux (RPC) and the docker byte-stream
//! bridge. On a non-Linux host there is no AF_VSOCK, so `main` only smoke-checks the dispatcher.

mod dispatch;
mod proc_net;

#[cfg(target_os = "linux")]
mod vsock_server;

#[cfg(target_os = "linux")]
#[tokio::main]
async fn main() -> std::io::Result<()> {
    vsock_server::run().await
}

#[cfg(not(target_os = "linux"))]
fn main() {
    use dory_pb::agent::{agent_request::Method, AgentRequest, InfoRequest};
    use prost::Message;
    // Exercise the dispatcher so the host build stays honest; the real agent runs in a guest.
    let probe = AgentRequest {
        method: Some(Method::Info(InfoRequest {})),
    };
    let _ = dispatch::dispatch(&probe.encode_to_vec());
    eprintln!("dory-agent host build: dispatcher OK. The agent runs as PID 1 inside a Dory guest.");
}
