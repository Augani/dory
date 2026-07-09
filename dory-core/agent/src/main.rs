//! `dory-agent` — one static-musl binary that runs as PID 1 inside every Dory guest AND as the
//! remote-VPS daemon. Guest mode serves the vsock control mux + docker byte-stream bridge; daemon
//! mode (`--daemon <addr>`) serves the same control mux over TCP, reached through an SSH tunnel by
//! doryd's `remote` stack. On a non-Linux host there is no AF_VSOCK, so `main` only smoke-checks the
//! dispatcher (or runs the portable daemon for local testing).

#[cfg(target_os = "linux")]
#[tokio::main]
async fn main() -> std::io::Result<()> {
    if let Some(addr) = daemon_addr() {
        let listener = tokio::net::TcpListener::bind(&addr).await?;
        eprintln!("dory-agent: daemon serving control on {addr}");
        return dory_agent::daemon::serve(listener).await;
    }
    dory_agent::reaper::start_pid1_reaper_if_needed();
    dory_agent::vsock_server::run().await
}

#[cfg(not(target_os = "linux"))]
#[tokio::main]
async fn main() -> std::io::Result<()> {
    use dory_pb::agent::{agent_request::Method, AgentRequest, InfoRequest};
    use prost::Message;

    if let Some(addr) = daemon_addr() {
        let listener = tokio::net::TcpListener::bind(&addr).await?;
        eprintln!("dory-agent: daemon serving control on {addr} (host build, for local testing)");
        return dory_agent::daemon::serve(listener).await;
    }

    // Exercise the dispatcher so the host build stays honest; the real agent runs in a guest.
    let probe = AgentRequest {
        method: Some(Method::Info(InfoRequest {})),
    };
    let _ = dory_agent::dispatch::dispatch(&probe.encode_to_vec());
    eprintln!("dory-agent host build: dispatcher OK. The agent runs as PID 1 inside a Dory guest.");
    Ok(())
}

/// `--daemon <addr>` selects remote-VPS daemon mode; absent, the guest PID-1 path runs.
/// Daemon mode exposes `Exec` with no in-band authentication; it relies entirely on the transport
/// (loopback default + SSH tunnel). Never bind it to a routable address.
fn daemon_addr() -> Option<String> {
    let args: Vec<String> = std::env::args().collect();
    let idx = args.iter().position(|a| a == "--daemon")?;
    Some(
        args.get(idx + 1)
            .cloned()
            .unwrap_or_else(|| "127.0.0.1:2377".to_string()),
    )
}
