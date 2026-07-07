//! Platform-independent agent RPC dispatch: decode an [`AgentRequest`], run the method, encode an
//! [`AgentResponse`]. This is the handler the mux invokes per request; keeping it free of vsock lets
//! it be unit-tested on any host. Side-effecting methods (clock set) are `cfg`-gated to Linux.

use dory_pb::agent::{self, agent_request::Method, agent_response::Result as Res};
use prost::Message;

/// Decode a request payload, dispatch, and return the encoded response payload. A malformed request
/// yields a well-formed error response (never a panic), so one bad frame can't take down the mux.
pub fn dispatch(req_bytes: &[u8]) -> Vec<u8> {
    let response = match agent::AgentRequest::decode(req_bytes) {
        Ok(req) => handle_method(req.method),
        Err(_) => err(400, "malformed AgentRequest"),
    };
    response.encode_to_vec()
}

pub fn agent_build() -> String {
    concat!("dory-agent/", env!("CARGO_PKG_VERSION")).to_string()
}

pub fn err(code: i32, message: &str) -> agent::AgentResponse {
    agent::AgentResponse {
        result: Some(Res::Error(agent::RpcError {
            code,
            message: message.to_string(),
        })),
    }
}

/// Run the non-I/O methods (clock/info/ports). The async, filesystem-touching sync methods are
/// routed by [`crate::handler`] before they reach here; if one arrives here it is a routing bug, so
/// it is answered with an error rather than silently ignored.
pub fn handle_method(method: Option<Method>) -> agent::AgentResponse {
    let result = match method {
        Some(Method::ClockSync(r)) => Res::ClockSync(agent::ClockSyncResponse {
            synced: set_clock(r.host_epoch_ns),
        }),
        Some(Method::Info(_)) => Res::Info(info()),
        Some(Method::PortsWatch(_)) => Res::PortsWatch(ports_watch()),
        Some(_) => return err(500, "sync method must be dispatched via the async handler"),
        None => return err(400, "empty method"),
    };
    agent::AgentResponse {
        result: Some(result),
    }
}

fn info() -> agent::InfoResponse {
    agent::InfoResponse {
        proto_version: dory_proto::handshake::PROTO_VERSION,
        kernel: kernel(),
        agent_build: agent_build(),
        uptime_secs: uptime_secs(),
    }
}

fn kernel() -> String {
    unsafe {
        let mut u: libc::utsname = std::mem::zeroed();
        if libc::uname(&mut u) != 0 {
            return String::new();
        }
        let sysname = std::ffi::CStr::from_ptr(u.sysname.as_ptr()).to_string_lossy();
        let release = std::ffi::CStr::from_ptr(u.release.as_ptr()).to_string_lossy();
        format!("{sysname} {release}")
    }
}

#[cfg(target_os = "linux")]
fn uptime_secs() -> u64 {
    std::fs::read_to_string("/proc/uptime")
        .ok()
        .and_then(|s| s.split_whitespace().next().map(str::to_owned))
        .and_then(|s| s.parse::<f64>().ok())
        .map(|f| f as u64)
        .unwrap_or(0)
}

#[cfg(not(target_os = "linux"))]
fn uptime_secs() -> u64 {
    0
}

#[cfg(target_os = "linux")]
fn set_clock(host_epoch_ns: i64) -> bool {
    if host_epoch_ns <= 0 {
        return false;
    }
    let tv = libc::timespec {
        tv_sec: (host_epoch_ns / 1_000_000_000) as _,
        tv_nsec: (host_epoch_ns % 1_000_000_000) as _,
    };
    unsafe { libc::clock_settime(libc::CLOCK_REALTIME, &tv) == 0 }
}

#[cfg(not(target_os = "linux"))]
fn set_clock(_host_epoch_ns: i64) -> bool {
    false // no privilege to set the host clock from a unit test
}

fn ports_watch() -> agent::PortsWatchResponse {
    // Read the guest listener tables and return the current set; the host (doryd) diffs successive
    // snapshots, so the agent stays stateless. On a non-Linux host these reads simply return nothing.
    let mut ports = Vec::new();
    for (path, protocol) in [
        ("/proc/net/tcp", "tcp"),
        ("/proc/net/tcp6", "tcp"),
        ("/proc/net/udp", "udp"),
        ("/proc/net/udp6", "udp"),
    ] {
        if let Ok(table) = std::fs::read_to_string(path) {
            for (proto, port) in crate::proc_net::parse_listeners(&table, protocol) {
                ports.push(agent::ListenPort {
                    protocol: proto,
                    port: port as u32,
                });
            }
        }
    }
    ports.sort_by(|a, b| (a.port, &a.protocol).cmp(&(b.port, &b.protocol)));
    ports.dedup();
    agent::PortsWatchResponse {
        ports,
        added: Vec::new(),
        removed: Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use dory_pb::agent;

    fn encode(method: agent::agent_request::Method) -> Vec<u8> {
        agent::AgentRequest {
            method: Some(method),
        }
        .encode_to_vec()
    }

    #[test]
    fn info_reports_proto_version_and_build() {
        let out = dispatch(&encode(agent::agent_request::Method::Info(
            agent::InfoRequest {},
        )));
        let resp = agent::AgentResponse::decode(out.as_slice()).unwrap();
        match resp.result {
            Some(Res::Info(i)) => {
                assert_eq!(i.proto_version, dory_proto::handshake::PROTO_VERSION);
                assert!(i.agent_build.starts_with("dory-agent/"));
                assert!(!i.kernel.is_empty());
            }
            other => panic!("expected Info, got {other:?}"),
        }
    }

    #[test]
    fn clock_sync_returns_well_formed_response() {
        let out = dispatch(&encode(agent::agent_request::Method::ClockSync(
            agent::ClockSyncRequest {
                host_epoch_ns: 1_700_000_000_000_000_000,
            },
        )));
        let resp = agent::AgentResponse::decode(out.as_slice()).unwrap();
        assert!(matches!(resp.result, Some(Res::ClockSync(_))));
    }

    #[test]
    fn malformed_request_yields_error_not_panic() {
        let out = dispatch(&[0xFF, 0xFF, 0xFF, 0xFF]);
        let resp = agent::AgentResponse::decode(out.as_slice()).unwrap();
        match resp.result {
            Some(Res::Error(e)) => assert_eq!(e.code, 400),
            other => panic!("expected Error, got {other:?}"),
        }
    }

    #[test]
    fn empty_method_is_an_error() {
        let out = dispatch(&agent::AgentRequest { method: None }.encode_to_vec());
        let resp = agent::AgentResponse::decode(out.as_slice()).unwrap();
        assert!(matches!(resp.result, Some(Res::Error(_))));
    }

    /// The whole assembled RPC spine over an in-memory connection: handshake -> mux -> dispatch ->
    /// protobuf, exactly as doryd <-> the guest agent will talk, minus the vsock transport.
    #[tokio::test]
    async fn full_rpc_spine_over_mux() {
        use dory_proto::handshake::{handshake, Hello};
        use dory_proto::mux::{Handler, HandlerFuture, Mux};
        use std::sync::Arc;
        use tokio::io::duplex;

        let (mut client_io, mut server_io) = duplex(64 * 1024);

        // Agent side: handshake, then serve the dispatcher over the mux.
        let server = tokio::spawn(async move {
            handshake(&mut server_io, &Hello::current("agent")).await.unwrap();
            let handler: Handler =
                Arc::new(|req: Vec<u8>| Box::pin(async move { dispatch(&req) }) as HandlerFuture);
            let mux = Mux::start(server_io, handler);
            // Keep the mux (and thus the connection) alive for the duration of the calls.
            tokio::time::sleep(std::time::Duration::from_secs(3)).await;
            drop(mux);
        });

        // doryd side: handshake, then make RPC calls.
        let peer = handshake(&mut client_io, &Hello::current("doryd")).await.unwrap();
        assert_eq!(peer.build, "agent");
        let client = Mux::client(client_io);

        let info_req = agent::AgentRequest {
            method: Some(agent::agent_request::Method::Info(agent::InfoRequest {})),
        }
        .encode_to_vec();
        let raw = client.call(&info_req).await.unwrap();
        let resp = agent::AgentResponse::decode(raw.as_slice()).unwrap();
        match resp.result {
            Some(Res::Info(i)) => {
                assert_eq!(i.proto_version, dory_proto::handshake::PROTO_VERSION);
                assert!(i.agent_build.starts_with("dory-agent/"));
            }
            other => panic!("expected Info, got {other:?}"),
        }

        server.abort();
    }
}
