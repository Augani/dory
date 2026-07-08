//! End-to-end over a real transport: the REAL agent daemon (`dory_agent::daemon::serve`, which runs
//! the production handshake + mux + dispatch) answering the REAL `AgentClient`, over TCP loopback.
//! Together with the SSH loopback test in `ssh.rs` (which bridges direct-streamlocal to a fake
//! agent), this closes the loop: real client + real server speaking the vsock protocol over a
//! non-vsock transport — exactly the remote-VPS path minus the SSH hop.

use dory_remote::AgentClient;
use tokio::net::{TcpListener, TcpStream};

#[tokio::test]
async fn agent_client_drives_real_dispatch_over_tcp() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = dory_agent::daemon::serve(listener).await;
    });

    let stream = TcpStream::connect(addr).await.unwrap();
    let client = AgentClient::connect(stream, "doryd-test")
        .await
        .expect("handshake with real agent");

    // Real dispatch, not a fake: proto version negotiated, agent build string from the binary.
    let info = client.info().await.expect("info rpc");
    assert_eq!(info.proto_version, 1, "PROTO_VERSION");
    assert!(
        info.agent_build.starts_with("dory-agent/"),
        "real agent build string, got {}",
        info.agent_build
    );

    // clock_sync round-trips; on a host the agent has no privilege to set the clock, so synced=false
    // — the point is the typed RPC completes against real dispatch, not the side effect.
    let clock = client
        .clock_sync(1_700_000_000_000_000_000)
        .await
        .expect("clock rpc");
    assert!(!clock.synced, "host dispatch declines to set the clock");

    // ports_watch: real /proc/net parse on Linux, empty on a non-Linux host — must not error.
    let _ports = client.ports_watch().await.expect("ports rpc");

    // telemetry: real /proc parse on Linux, zeros on host — must round-trip through real dispatch.
    let _telemetry = client.telemetry().await.expect("telemetry rpc");

    // Concurrent calls are id-routed by the mux — fire several and confirm each resolves.
    let (a, b, c) = tokio::join!(client.info(), client.info(), client.info());
    assert!(
        a.is_ok() && b.is_ok() && c.is_ok(),
        "concurrent RPCs all resolve"
    );
}
