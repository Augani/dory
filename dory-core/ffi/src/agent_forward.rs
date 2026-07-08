//! Docker-tier agent control over dory-hv's raw vsock forward socket.
//!
//! doryd opens one unix connection to dory-hv's `--agent-vsock-forward` socket, prefixes it with the
//! standard `HostToGuest { cid, PORT_CONTROL }` preamble, then runs the existing transport-agnostic
//! `AgentClient` over that stream. The guest control protocol stays in Rust; Swift only sees typed
//! records and small control results.

use std::os::fd::FromRawFd;
use std::sync::Arc;

use dory_proto::channels::PORT_CONTROL;
use dory_proto::preamble::{write_preamble, Direction, Preamble};
use dory_remote::AgentClient;
use tokio::net::UnixStream;

use crate::remote::{
    exec_result, AgentInfoFfi, ExecEnvFfi, ExecResultFfi, RemoteFfiError, TelemetryFfi,
};

#[derive(uniffi::Record)]
pub struct ListenPortFfi {
    pub protocol: String,
    pub port: u32,
}

#[derive(uniffi::Record)]
pub struct PortEventFfi {
    pub action: String,
    pub protocol: String,
    pub port: u32,
}

#[derive(uniffi::Record)]
pub struct PortsWatchFfi {
    pub ports: Vec<ListenPortFfi>,
    pub added: Vec<PortEventFfi>,
    pub removed: Vec<PortEventFfi>,
}

#[derive(uniffi::Object)]
pub struct AgentControl {
    runtime: std::sync::Mutex<Option<tokio::runtime::Runtime>>,
    client: AgentClient,
}

#[uniffi::export]
pub fn connect_agent_over_forward(
    forward_socket_path: String,
    cid: u32,
) -> Result<Arc<AgentControl>, RemoteFfiError> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(failed)?;
    let client = runtime.block_on(async move {
        let mut stream = UnixStream::connect(&forward_socket_path)
            .await
            .map_err(failed)?;
        write_preamble(
            &mut stream,
            &Preamble {
                direction: Direction::HostToGuest,
                cid,
                port: PORT_CONTROL,
            },
        )
        .await
        .map_err(failed)?;
        AgentClient::connect(stream, "doryd-agent-forward")
            .await
            .map_err(RemoteFfiError::from)
    })?;
    Ok(Arc::new(AgentControl {
        runtime: std::sync::Mutex::new(Some(runtime)),
        client,
    }))
}

#[uniffi::export]
pub fn connect_agent_over_fd(fd: i32) -> Result<Arc<AgentControl>, RemoteFfiError> {
    if fd < 0 {
        return Err(failed("invalid fd"));
    }
    // Ownership of this fd transfers to Rust. Swift callers should pass a dup of any fd still
    // owned by framework objects such as VZVirtioSocketConnection.
    let stream = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    stream.set_nonblocking(true).map_err(failed)?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(failed)?;
    let client = runtime.block_on(async move {
        let stream = UnixStream::from_std(stream).map_err(failed)?;
        AgentClient::connect(stream, "dory-vmm-agent-fd")
            .await
            .map_err(RemoteFfiError::from)
    })?;
    Ok(Arc::new(AgentControl {
        runtime: std::sync::Mutex::new(Some(runtime)),
        client,
    }))
}

#[uniffi::export]
impl AgentControl {
    pub fn info(&self) -> Result<AgentInfoFfi, RemoteFfiError> {
        let guard = self.runtime.lock().unwrap();
        let runtime = guard.as_ref().ok_or_else(shutdown_error)?;
        let i = runtime.block_on(self.client.info())?;
        Ok(AgentInfoFfi {
            proto_version: i.proto_version,
            kernel: i.kernel,
            agent_build: i.agent_build,
            uptime_secs: i.uptime_secs,
        })
    }

    pub fn clock_sync(&self, host_epoch_ns: i64) -> Result<bool, RemoteFfiError> {
        let guard = self.runtime.lock().unwrap();
        let runtime = guard.as_ref().ok_or_else(shutdown_error)?;
        Ok(runtime
            .block_on(self.client.clock_sync(host_epoch_ns))?
            .synced)
    }

    pub fn ports_watch(&self) -> Result<PortsWatchFfi, RemoteFfiError> {
        let guard = self.runtime.lock().unwrap();
        let runtime = guard.as_ref().ok_or_else(shutdown_error)?;
        let p = runtime.block_on(self.client.ports_watch())?;
        Ok(PortsWatchFfi {
            ports: p
                .ports
                .into_iter()
                .map(|p| ListenPortFfi {
                    protocol: p.protocol,
                    port: p.port,
                })
                .collect(),
            added: p.added.into_iter().map(port_event).collect(),
            removed: p.removed.into_iter().map(port_event).collect(),
        })
    }

    pub fn telemetry(&self) -> Result<TelemetryFfi, RemoteFfiError> {
        let guard = self.runtime.lock().unwrap();
        let runtime = guard.as_ref().ok_or_else(shutdown_error)?;
        let t = runtime.block_on(self.client.telemetry())?;
        Ok(TelemetryFfi {
            mem_total_kb: t.mem_total_kb,
            mem_available_kb: t.mem_available_kb,
            psi_some_avg10: t.psi_some_avg10,
            psi_full_avg10: t.psi_full_avg10,
        })
    }

    pub fn exec(
        &self,
        argv: Vec<String>,
        cwd: String,
        env: Vec<ExecEnvFfi>,
        timeout_ms: u64,
        output_limit_bytes: u64,
    ) -> Result<ExecResultFfi, RemoteFfiError> {
        let guard = self.runtime.lock().unwrap();
        let runtime = guard.as_ref().ok_or_else(shutdown_error)?;
        let out = runtime.block_on(self.client.exec(
            argv,
            cwd,
            env.into_iter().map(|item| (item.key, item.value)).collect(),
            timeout_ms,
            output_limit_bytes,
        ))?;
        Ok(exec_result(out))
    }
}

impl Drop for AgentControl {
    fn drop(&mut self) {
        if let Some(runtime) = self.runtime.lock().unwrap().take() {
            runtime.shutdown_background();
        }
    }
}

fn port_event(e: dory_pb::agent::PortEvent) -> PortEventFfi {
    PortEventFfi {
        action: e.action,
        protocol: e.protocol,
        port: e.port,
    }
}

fn failed(error: impl std::fmt::Display) -> RemoteFfiError {
    RemoteFfiError::Failed {
        message: error.to_string(),
    }
}

fn shutdown_error() -> RemoteFfiError {
    RemoteFfiError::Failed {
        message: "agent control already shut down".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use dory_proto::preamble::read_preamble;
    use std::os::fd::IntoRawFd;
    use std::sync::mpsc;
    use tokio::net::UnixListener;

    #[test]
    fn connects_to_real_agent_handler_over_forward_socket() {
        let base = std::env::temp_dir();
        let path = base.join(format!(
            "dory-ffi-agent-forward-{}-{}.sock",
            std::process::id(),
            unique_suffix()
        ));
        let _ = std::fs::remove_file(&path);
        let (ready_tx, ready_rx) = mpsc::channel();
        let (preamble_tx, preamble_rx) = mpsc::channel();
        let server_path = path.clone();

        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            runtime.block_on(async move {
                let listener = UnixListener::bind(&server_path).unwrap();
                ready_tx.send(()).unwrap();
                if let Ok((mut stream, _)) = listener.accept().await {
                    let preamble = read_preamble(&mut stream).await.unwrap();
                    preamble_tx.send(preamble).unwrap();
                    dory_agent::daemon::serve_conn(stream).await;
                    std::future::pending::<()>().await;
                }
            });
        });

        ready_rx.recv().unwrap();
        let control =
            connect_agent_over_forward(path.to_string_lossy().into_owned(), 7).expect("connect");

        let preamble = preamble_rx.recv().unwrap();
        assert_eq!(preamble.direction, Direction::HostToGuest);
        assert_eq!(preamble.cid, 7);
        assert_eq!(preamble.port, PORT_CONTROL);

        let info = control.info().expect("info");
        assert_eq!(info.proto_version, dory_proto::handshake::PROTO_VERSION);
        assert!(info.agent_build.starts_with("dory-agent/"));

        let _ = control
            .clock_sync(1_700_000_000_000_000_000)
            .expect("clock sync");
        let _ = control.ports_watch().expect("ports watch");
        let _ = control.telemetry().expect("telemetry");
        let exec = control
            .exec(
                vec!["/bin/sh".into(), "-lc".into(), "printf ffi-exec".into()],
                String::new(),
                Vec::new(),
                5_000,
                1024,
            )
            .expect("exec");
        assert_eq!(exec.exit_code, 0);
        assert_eq!(exec.stdout, b"ffi-exec");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn connects_to_real_agent_handler_over_owned_fd() {
        let (client, server) = std::os::unix::net::UnixStream::pair().unwrap();
        let client_fd = client.into_raw_fd();
        let (ready_tx, ready_rx) = mpsc::channel();

        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            runtime.block_on(async move {
                server.set_nonblocking(true).unwrap();
                let stream = UnixStream::from_std(server).unwrap();
                ready_tx.send(()).unwrap();
                dory_agent::daemon::serve_conn(stream).await;
                std::future::pending::<()>().await;
            });
        });

        ready_rx.recv().unwrap();
        let control = connect_agent_over_fd(client_fd).expect("connect");
        let info = control.info().expect("info");
        assert_eq!(info.proto_version, dory_proto::handshake::PROTO_VERSION);
        assert!(info.agent_build.starts_with("dory-agent/"));
    }

    fn unique_suffix() -> u64 {
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT: AtomicU64 = AtomicU64::new(0);
        NEXT.fetch_add(1, Ordering::Relaxed)
    }
}
