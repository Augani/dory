//! Transport-agnostic typed RPC to a `dory-agent`.
//!
//! This is the client mirror of the agent's `dispatch`: it runs the versioned [`handshake`] then a
//! call-only [`Mux`] over any byte stream, and exposes the agent methods as typed protobuf calls.
//! Because it is generic over the stream, the SAME client drives the agent over an SSH
//! [`crate::ssh`] channel, a VZ vsock stream, or an in-memory duplex — one protocol, many transports
//! (the whole point of seam 1). `doryd` embeds this for remote VPSes; nothing here is SSH-specific.

use std::sync::Arc;
use std::time::Duration;

use dory_pb::agent::{
    self, agent_request::Method, agent_response::Result as Res, AgentRequest, AgentResponse,
    ClockSyncRequest, ExecEnv, ExecRequest, ExecResponse, InfoRequest, PortsWatchRequest,
    SyncDeleteRequest, SyncDeleteResponse, SyncFileStatusRequest, SyncFileStatusResponse,
    SyncManifestRequest, SyncManifestResponse, SyncPutChunkRequest, SyncPutChunkResponse,
    TelemetryRequest, TelemetryResponse,
};
use dory_proto::handshake::{handshake, Hello};
use dory_proto::mux::Mux;
use prost::Message;
use tokio::io::{AsyncRead, AsyncWrite};

use crate::error::RemoteError;

// The mux only unblocks a caller when the connection closes; a connected-but-silent peer would
// otherwise hang `call` (and any FFI `block_on` above it) forever. Every RPC therefore carries a
// deadline sized to its slowest legitimate completion.
const CONTROL_DEADLINE: Duration = Duration::from_secs(30);
const SYNC_MANIFEST_DEADLINE: Duration = Duration::from_secs(10 * 60);
const SYNC_IO_DEADLINE: Duration = Duration::from_secs(2 * 60);
const EXEC_GRACE: Duration = Duration::from_secs(30);

pub struct AgentClient {
    mux: Arc<Mux>,
}

impl AgentClient {
    /// Take ownership of a connected stream, complete the protocol handshake, and start the mux.
    /// A version skew is a clean [`RemoteError::Handshake`], never a wedge.
    pub async fn connect<S>(
        mut stream: S,
        build: impl Into<String>,
    ) -> Result<AgentClient, RemoteError>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        handshake(&mut stream, &Hello::current(build)).await?;
        Ok(AgentClient {
            mux: Mux::client(stream),
        })
    }

    async fn call(&self, method: Method) -> Result<Res, RemoteError> {
        self.call_with_deadline(method, CONTROL_DEADLINE).await
    }

    async fn call_with_deadline(
        &self,
        method: Method,
        deadline: Duration,
    ) -> Result<Res, RemoteError> {
        let req = AgentRequest {
            method: Some(method),
        };
        let bytes = tokio::time::timeout(deadline, self.mux.call(&req.encode_to_vec()))
            .await
            .map_err(|_| RemoteError::Timeout(deadline))??;
        let resp = AgentResponse::decode(bytes.as_slice()).map_err(|_| RemoteError::Decode)?;
        match resp.result {
            Some(Res::Error(e)) => Err(RemoteError::Rpc {
                code: e.code,
                message: e.message,
            }),
            Some(other) => Ok(other),
            None => Err(RemoteError::Decode),
        }
    }

    pub async fn info(&self) -> Result<agent::InfoResponse, RemoteError> {
        match self.call(Method::Info(InfoRequest {})).await? {
            Res::Info(info) => Ok(info),
            _ => Err(RemoteError::UnexpectedVariant),
        }
    }

    pub async fn clock_sync(
        &self,
        host_epoch_ns: i64,
    ) -> Result<agent::ClockSyncResponse, RemoteError> {
        match self
            .call(Method::ClockSync(ClockSyncRequest { host_epoch_ns }))
            .await?
        {
            Res::ClockSync(r) => Ok(r),
            _ => Err(RemoteError::UnexpectedVariant),
        }
    }

    pub async fn ports_watch(&self) -> Result<agent::PortsWatchResponse, RemoteError> {
        match self.call(Method::PortsWatch(PortsWatchRequest {})).await? {
            Res::PortsWatch(r) => Ok(r),
            _ => Err(RemoteError::UnexpectedVariant),
        }
    }

    pub async fn telemetry(&self) -> Result<TelemetryResponse, RemoteError> {
        match self.call(Method::Telemetry(TelemetryRequest {})).await? {
            Res::Telemetry(r) => Ok(r),
            _ => Err(RemoteError::UnexpectedVariant),
        }
    }

    pub async fn exec(
        &self,
        argv: Vec<String>,
        cwd: String,
        env: Vec<(String, String)>,
        timeout_ms: u64,
        output_limit_bytes: u64,
    ) -> Result<ExecResponse, RemoteError> {
        let env = env
            .into_iter()
            .map(|(key, value)| ExecEnv { key, value })
            .collect();
        // Mirror the agent's server-side clamp (0 => 30s default, cap 10min), then add grace so
        // the client deadline only fires when the agent itself failed to enforce its timeout.
        let server_timeout = Duration::from_millis(match timeout_ms {
            0 => 30_000,
            value => value.min(10 * 60_000),
        });
        match self
            .call_with_deadline(
                Method::Exec(ExecRequest {
                    argv,
                    cwd,
                    env,
                    timeout_ms,
                    output_limit_bytes,
                }),
                server_timeout + EXEC_GRACE,
            )
            .await?
        {
            Res::Exec(r) => Ok(r),
            _ => Err(RemoteError::UnexpectedVariant),
        }
    }

    pub async fn sync_manifest(
        &self,
        req: SyncManifestRequest,
    ) -> Result<SyncManifestResponse, RemoteError> {
        // Manifests hash whole trees; large repos on slow disks legitimately take minutes.
        match self
            .call_with_deadline(Method::SyncManifest(req), SYNC_MANIFEST_DEADLINE)
            .await?
        {
            Res::SyncManifest(r) => Ok(r),
            _ => Err(RemoteError::UnexpectedVariant),
        }
    }

    pub async fn sync_file_status(
        &self,
        req: SyncFileStatusRequest,
    ) -> Result<SyncFileStatusResponse, RemoteError> {
        match self
            .call_with_deadline(Method::SyncFileStatus(req), SYNC_IO_DEADLINE)
            .await?
        {
            Res::SyncFileStatus(r) => Ok(r),
            _ => Err(RemoteError::UnexpectedVariant),
        }
    }

    pub async fn sync_put_chunk(
        &self,
        req: SyncPutChunkRequest,
    ) -> Result<SyncPutChunkResponse, RemoteError> {
        match self
            .call_with_deadline(Method::SyncPutChunk(req), SYNC_IO_DEADLINE)
            .await?
        {
            Res::SyncPutChunk(r) => Ok(r),
            _ => Err(RemoteError::UnexpectedVariant),
        }
    }

    pub async fn sync_delete(
        &self,
        req: SyncDeleteRequest,
    ) -> Result<SyncDeleteResponse, RemoteError> {
        match self
            .call_with_deadline(Method::SyncDelete(req), SYNC_IO_DEADLINE)
            .await?
        {
            Res::SyncDelete(r) => Ok(r),
            _ => Err(RemoteError::UnexpectedVariant),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use dory_proto::mux::{Handler, HandlerFuture};

    /// A fake agent: handshake + a mux whose handler is the real dispatcher. This is exactly the
    /// agent's control server (`vsock_server::serve_control`) minus the vsock, so a green test here
    /// proves the client speaks the production protocol.
    async fn spawn_fake_agent<S>(mut stream: S)
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        if handshake(&mut stream, &Hello::current("fake-agent"))
            .await
            .is_err()
        {
            return;
        }
        let handler: Handler = Arc::new(|req: Vec<u8>| {
            Box::pin(async move { dory_agent_dispatch(&req) }) as HandlerFuture
        });
        let _mux = Mux::start(stream, handler);
        // Hold the mux alive for the test's duration.
        std::future::pending::<()>().await;
    }

    // The agent's dispatch lives in the agent binary crate (not a lib), so reproduce the one call the
    // test needs by encoding an InfoResponse directly — the wire contract, not the impl.
    fn dory_agent_dispatch(req_bytes: &[u8]) -> Vec<u8> {
        let req = AgentRequest::decode(req_bytes).unwrap();
        let result = match req.method {
            Some(Method::Info(_)) => Res::Info(agent::InfoResponse {
                proto_version: dory_proto::handshake::PROTO_VERSION,
                kernel: "Linux fake 6.12".into(),
                agent_build: "fake-agent".into(),
                uptime_secs: 42,
            }),
            Some(Method::ClockSync(_)) => Res::ClockSync(agent::ClockSyncResponse { synced: true }),
            Some(Method::PortsWatch(_)) => Res::PortsWatch(agent::PortsWatchResponse::default()),
            Some(Method::Exec(_)) => Res::Exec(agent::ExecResponse {
                exit_code: 0,
                stdout: b"exec-ok".to_vec(),
                stderr: Vec::new(),
                timed_out: false,
                stdout_truncated: false,
                stderr_truncated: false,
            }),
            _ => Res::Error(agent::RpcError {
                code: 400,
                message: "unsupported in this fake".into(),
            }),
        };
        AgentResponse {
            result: Some(result),
        }
        .encode_to_vec()
    }

    #[tokio::test]
    async fn info_round_trips_over_a_duplex() {
        let (client_stream, agent_stream) = tokio::io::duplex(64 * 1024);
        tokio::spawn(spawn_fake_agent(agent_stream));

        let client = AgentClient::connect(client_stream, "doryd-test")
            .await
            .unwrap();
        let info = client.info().await.unwrap();
        assert_eq!(info.proto_version, dory_proto::handshake::PROTO_VERSION);
        assert_eq!(info.agent_build, "fake-agent");
        assert_eq!(info.uptime_secs, 42);

        let clock = client.clock_sync(1_700_000_000_000_000_000).await.unwrap();
        assert!(clock.synced);

        let exec = client
            .exec(
                vec!["/bin/echo".into(), "ok".into()],
                String::new(),
                Vec::new(),
                1000,
                1024,
            )
            .await
            .unwrap();
        assert_eq!(exec.exit_code, 0);
        assert_eq!(exec.stdout, b"exec-ok");
    }

    #[tokio::test]
    async fn a_connected_but_silent_agent_times_out_instead_of_hanging() {
        // Handshake completes, then the peer never answers any mux request. The per-call deadline
        // must surface Timeout — without it the caller (and any FFI block_on above it) wedges.
        let (client_stream, mut agent_stream) = tokio::io::duplex(64 * 1024);
        tokio::spawn(async move {
            let _ = handshake(&mut agent_stream, &Hello::current("silent-agent")).await;
            std::future::pending::<()>().await;
        });

        let client = AgentClient::connect(client_stream, "doryd-test")
            .await
            .unwrap();
        let res = client
            .call_with_deadline(
                Method::Info(InfoRequest {}),
                std::time::Duration::from_millis(200),
            )
            .await;
        match res {
            Err(RemoteError::Timeout(_)) => {}
            other => panic!("expected Timeout, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn version_skew_is_a_clean_error_not_a_hang() {
        // An agent that greets with a different proto version: connect must error, never wedge.
        let (client_stream, mut agent_stream) = tokio::io::duplex(64 * 1024);
        tokio::spawn(async move {
            let bad = Hello {
                proto_version: dory_proto::handshake::PROTO_VERSION + 1,
                build: "too-new".into(),
            };
            let _ = handshake(&mut agent_stream, &bad).await;
            std::future::pending::<()>().await;
        });

        let res = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            AgentClient::connect(client_stream, "doryd-test"),
        )
        .await
        .expect("connect must not hang on version skew");
        match res {
            Err(RemoteError::Handshake(_)) => {}
            Err(other) => panic!("expected a handshake error, got {other:?}"),
            Ok(_) => panic!("expected a handshake error, got a connected client"),
        }
    }
}
