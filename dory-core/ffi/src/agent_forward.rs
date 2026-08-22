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
use dory_remote::{
    pull as pull_tree, pull_observed as pull_tree_observed, push, push_observed, AgentClient,
    PullLimits,
};
use tokio::net::UnixStream;

use crate::remote::{
    exec_result, AgentCapabilityFfi, AgentInfoFfi, ExecEnvFfi, ExecResultFfi, PullControl,
    PullStatsFfi, PushControl, PushStatsFfi, RemoteFfiError, TelemetryFfi,
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

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum LifecycleReceiptActionFfi {
    PreparePause,
    Resumed,
    PrepareStop,
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
            capabilities: i
                .capabilities
                .into_iter()
                .map(|capability| AgentCapabilityFfi {
                    id: capability.id,
                    version: capability.version,
                })
                .collect(),
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

    /// Push a host directory through the local VM agent transport. File bytes stay inside Rust;
    /// Swift supplies only the two roots and receives bounded aggregate statistics.
    pub fn push(
        &self,
        local_root: String,
        remote_root: String,
    ) -> Result<PushStatsFfi, RemoteFfiError> {
        let guard = self.runtime.lock().unwrap();
        let runtime = guard.as_ref().ok_or_else(shutdown_error)?;
        let stats = runtime.block_on(push(
            std::path::Path::new(&local_root),
            &remote_root,
            &self.client,
        ))?;
        Ok(PushStatsFfi {
            files_sent: stats.files_sent,
            bytes_sent: stats.bytes_sent,
            files_deleted: stats.files_deleted,
        })
    }

    pub fn push_controlled(
        &self,
        local_root: String,
        remote_root: String,
        control: Arc<PushControl>,
    ) -> Result<PushStatsFfi, RemoteFfiError> {
        control.claim()?;
        let guard = self.runtime.lock().unwrap();
        let runtime = guard.as_ref().ok_or_else(shutdown_error)?;
        let stats = runtime.block_on(push_observed(
            std::path::Path::new(&local_root),
            &remote_root,
            &self.client,
            control.as_ref(),
        ))?;
        Ok(PushStatsFfi {
            files_sent: stats.files_sent,
            bytes_sent: stats.bytes_sent,
            files_deleted: stats.files_deleted,
        })
    }

    /// Pull a guest tree into a new daemon-private host staging root. File bytes remain in Rust;
    /// Swift supplies only roots and explicit resource bounds.
    pub fn pull(
        &self,
        remote_root: String,
        local_root: String,
        max_files: u64,
        max_directories: u64,
        max_bytes: u64,
    ) -> Result<PullStatsFfi, RemoteFfiError> {
        let guard = self.runtime.lock().unwrap();
        let runtime = guard.as_ref().ok_or_else(shutdown_error)?;
        let stats = runtime.block_on(pull_tree(
            &remote_root,
            std::path::Path::new(&local_root),
            &self.client,
            PullLimits {
                max_files,
                max_directories,
                max_bytes,
            },
        ))?;
        Ok(PullStatsFfi {
            files_received: stats.files_received,
            directories_received: stats.directories_received,
            bytes_received: stats.bytes_received,
        })
    }

    pub fn pull_controlled(
        &self,
        remote_root: String,
        local_root: String,
        max_files: u64,
        max_directories: u64,
        max_bytes: u64,
        control: Arc<PullControl>,
    ) -> Result<PullStatsFfi, RemoteFfiError> {
        control.claim()?;
        let guard = self.runtime.lock().unwrap();
        let runtime = guard.as_ref().ok_or_else(shutdown_error)?;
        let stats = runtime.block_on(pull_tree_observed(
            &remote_root,
            std::path::Path::new(&local_root),
            &self.client,
            PullLimits {
                max_files,
                max_directories,
                max_bytes,
            },
            control.as_ref(),
        ))?;
        Ok(PullStatsFfi {
            files_received: stats.files_received,
            directories_received: stats.directories_received,
            bytes_received: stats.bytes_received,
        })
    }

    pub fn snapshot_freeze(&self, receipt_id: String) -> Result<String, RemoteFfiError> {
        snapshot_quiesce(
            self,
            dory_pb::agent::snapshot_quiesce_request::Action::Freeze,
            receipt_id,
        )
    }

    pub fn snapshot_thaw(&self, receipt_id: String) -> Result<(), RemoteFfiError> {
        snapshot_quiesce(
            self,
            dory_pb::agent::snapshot_quiesce_request::Action::Thaw,
            receipt_id,
        )
        .map(|_| ())
    }

    pub fn lifecycle_receipt(
        &self,
        action: LifecycleReceiptActionFfi,
        operation_id: String,
    ) -> Result<String, RemoteFfiError> {
        use dory_pb::agent::lifecycle_receipt_request::Action;

        let action = match action {
            LifecycleReceiptActionFfi::PreparePause => Action::PreparePause,
            LifecycleReceiptActionFfi::Resumed => Action::Resumed,
            LifecycleReceiptActionFfi::PrepareStop => Action::PrepareStop,
        };
        let guard = self.runtime.lock().unwrap();
        let runtime = guard.as_ref().ok_or_else(shutdown_error)?;
        let receipt =
            runtime.block_on(self.client.lifecycle_receipt(action, operation_id.clone()))?;
        if !receipt.acknowledged
            || receipt.action != action as i32
            || receipt.operation_id != operation_id
        {
            return Err(failed(
                "guest returned a mismatched lifecycle operation receipt",
            ));
        }
        Ok(receipt.operation_id)
    }

    pub fn usb_vhci_attach(
        &self,
        bus_id: String,
        port: u32,
        vsock_port: u32,
        device_id: u32,
        speed: u32,
    ) -> Result<(), RemoteFfiError> {
        let guard = self.runtime.lock().unwrap();
        let runtime = guard.as_ref().ok_or_else(shutdown_error)?;
        let response = runtime.block_on(self.client.usb_vhci_attach(
            dory_pb::agent::UsbVhciAttachRequest {
                bus_id: bus_id.clone(),
                port,
                vsock_port,
                device_id,
                speed,
            },
        ))?;
        if !response.attached
            || response.bus_id != bus_id
            || response.port != port
            || response.device_id != device_id
        {
            return Err(failed("guest returned a mismatched USB attach receipt"));
        }
        Ok(())
    }

    pub fn usb_vhci_detach(&self, bus_id: String, port: u32) -> Result<(), RemoteFfiError> {
        let guard = self.runtime.lock().unwrap();
        let runtime = guard.as_ref().ok_or_else(shutdown_error)?;
        let response = runtime.block_on(self.client.usb_vhci_detach(
            dory_pb::agent::UsbVhciDetachRequest {
                bus_id: bus_id.clone(),
                port,
            },
        ))?;
        if !response.detached || response.bus_id != bus_id || response.port != port {
            return Err(failed("guest returned a mismatched USB detach receipt"));
        }
        Ok(())
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

    pub fn exec_with_input(
        &self,
        argv: Vec<String>,
        cwd: String,
        env: Vec<ExecEnvFfi>,
        timeout_ms: u64,
        output_limit_bytes: u64,
        stdin: Vec<u8>,
    ) -> Result<ExecResultFfi, RemoteFfiError> {
        let guard = self.runtime.lock().unwrap();
        let runtime = guard.as_ref().ok_or_else(shutdown_error)?;
        let out = runtime.block_on(self.client.exec_with_input(
            argv,
            cwd,
            env.into_iter().map(|item| (item.key, item.value)).collect(),
            timeout_ms,
            output_limit_bytes,
            stdin,
        ))?;
        Ok(exec_result(out))
    }
}

fn snapshot_quiesce(
    control: &AgentControl,
    action: dory_pb::agent::snapshot_quiesce_request::Action,
    receipt_id: String,
) -> Result<String, RemoteFfiError> {
    let guard = control.runtime.lock().unwrap();
    let runtime = guard.as_ref().ok_or_else(shutdown_error)?;
    let result = runtime.block_on(control.client.snapshot_quiesce(action, receipt_id))?;
    if result.completed {
        Ok(result.receipt_id)
    } else {
        Err(failed(if result.detail.is_empty() {
            "guest declined snapshot quiesce"
        } else {
            result.detail.as_str()
        }))
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
    use std::os::unix::fs::PermissionsExt;
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
        let operation_id = "12345678-1234-4234-8234-123456789abc";
        assert_eq!(
            control
                .lifecycle_receipt(LifecycleReceiptActionFfi::PreparePause, operation_id.into())
                .expect("lifecycle receipt"),
            operation_id
        );
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
        let input = vec![0, 1, 2, 0xff, b'\n'];
        let echoed = control
            .exec_with_input(
                vec!["/bin/cat".into()],
                String::new(),
                Vec::new(),
                5_000,
                1024,
                input.clone(),
            )
            .expect("exec with input");
        assert_eq!(echoed.exit_code, 0);
        assert_eq!(echoed.stdout, input);
        let transfer_root = base.join(format!(
            "dory-ffi-agent-push-{}-{}",
            std::process::id(),
            unique_suffix()
        ));
        let local_root = transfer_root.join("local");
        let remote_root = transfer_root.join("remote");
        std::fs::create_dir_all(&local_root).unwrap();
        std::fs::create_dir_all(&remote_root).unwrap();
        std::fs::set_permissions(&transfer_root, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::write(local_root.join("payload.txt"), b"agent-push").unwrap();
        let transfer_control = crate::remote::new_push_control();
        let stats = control
            .push_controlled(
                local_root.to_string_lossy().into_owned(),
                remote_root.to_string_lossy().into_owned(),
                transfer_control.clone(),
            )
            .expect("push");
        assert_eq!(stats.files_sent, 1);
        assert_eq!(stats.bytes_sent, 10);
        assert_eq!(
            std::fs::read(remote_root.join("payload.txt")).unwrap(),
            b"agent-push"
        );
        let progress = transfer_control.progress();
        assert!(matches!(
            progress.phase,
            crate::remote::PushPhaseFfi::Completed
        ));
        assert_eq!(progress.files_total, 1);
        assert_eq!(progress.files_completed, 1);
        assert_eq!(progress.bytes_total, 10);
        assert_eq!(progress.bytes_completed, 10);
        assert!(progress.current_path.is_none());
        let reuse_error = control
            .push_controlled(
                local_root.to_string_lossy().into_owned(),
                remote_root.to_string_lossy().into_owned(),
                transfer_control,
            )
            .err()
            .expect("single-use control must reject reuse");
        assert!(reuse_error.to_string().contains("already used"));

        let pulled_root = transfer_root.join("pulled");
        let pull_control = crate::remote::new_pull_control();
        let pulled = control
            .pull_controlled(
                remote_root.to_string_lossy().into_owned(),
                pulled_root.to_string_lossy().into_owned(),
                100,
                100,
                1024 * 1024,
                pull_control.clone(),
            )
            .expect("pull");
        assert_eq!(pulled.files_received, 1);
        assert_eq!(pulled.directories_received, 0);
        assert_eq!(pulled.bytes_received, 10);
        assert_eq!(
            std::fs::read(pulled_root.join("payload.txt")).unwrap(),
            b"agent-push"
        );
        let pull_progress = pull_control.progress();
        assert!(matches!(
            pull_progress.phase,
            crate::remote::PullPhaseFfi::Completed
        ));
        assert_eq!(pull_progress.files_total, 1);
        assert_eq!(pull_progress.files_completed, 1);
        assert_eq!(pull_progress.bytes_total, 10);
        assert_eq!(pull_progress.bytes_completed, 10);
        assert!(pull_progress.current_path.is_none());
        let pull_reuse_error = control
            .pull_controlled(
                remote_root.to_string_lossy().into_owned(),
                transfer_root
                    .join("pulled-again")
                    .to_string_lossy()
                    .into_owned(),
                100,
                100,
                1024 * 1024,
                pull_control,
            )
            .err()
            .expect("single-use pull control must reject reuse");
        assert!(pull_reuse_error.to_string().contains("already used"));
        let _ = std::fs::remove_dir_all(&transfer_root);
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
