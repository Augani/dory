//! Seam 2 for the remote stack: the control surface `doryd` (Swift) links to drive a remote VPS —
//! connect over SSH, query the agent, and run a host-authoritative sync push. It obeys the iron
//! rule: only **configuration and stats** cross the FFI. The SSH bytes and the file chunks flow
//! entirely inside Rust (`dory_remote`); Swift passes a config and gets back a `PushStats`, never a
//! data-plane byte. Every entry is panic-safe via UniFFI.
//!
//! Blocking, not async: each call `block_on`s the object's own 2-worker runtime, so `doryd` drives
//! these off its main thread. The runtime is shut down in the background on drop (a plain `Runtime`
//! drop panics inside an async context).

use std::path::PathBuf;
use std::sync::Arc;

use dory_remote::{
    private_key_from_openssh, public_key_from_openssh, push, AgentEndpoint, HostKeyPolicy,
    SshAgent, SshConfig,
};

#[derive(Debug, uniffi::Error, thiserror::Error)]
pub enum RemoteFfiError {
    #[error("{message}")]
    Failed { message: String },
}

impl From<dory_remote::RemoteError> for RemoteFfiError {
    fn from(e: dory_remote::RemoteError) -> RemoteFfiError {
        RemoteFfiError::Failed {
            message: e.to_string(),
        }
    }
}

/// How to verify the server's host key. There is deliberately no "accept any" variant.
#[derive(uniffi::Enum)]
pub enum RemoteHostKey {
    /// Trust exactly this OpenSSH public key line (`ssh-ed25519 AAAA... comment`).
    Pinned { openssh_public_key: String },
    /// Consult an OpenSSH `known_hosts` file for `host:port`.
    KnownHosts {
        path: String,
        host: String,
        port: u16,
    },
}

/// Where the agent daemon listens on the remote.
#[derive(uniffi::Enum)]
pub enum RemoteEndpoint {
    UnixSocket { path: String },
    Tcp { host: String, port: u16 },
}

#[derive(uniffi::Record)]
pub struct RemoteConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    /// The client identity as an OpenSSH private-key PEM (doryd loads it from Keychain).
    pub openssh_private_key: String,
    pub host_key: RemoteHostKey,
    pub endpoint: RemoteEndpoint,
    pub build: String,
}

#[derive(uniffi::Record)]
pub struct AgentInfoFfi {
    pub proto_version: u32,
    pub kernel: String,
    pub agent_build: String,
    pub uptime_secs: u64,
}

#[derive(uniffi::Record)]
pub struct PushStatsFfi {
    pub files_sent: u64,
    pub bytes_sent: u64,
    pub files_deleted: u64,
}

#[derive(uniffi::Record)]
pub struct TelemetryFfi {
    pub mem_total_kb: u64,
    pub mem_available_kb: u64,
    pub psi_some_avg10: f64,
    pub psi_full_avg10: f64,
}

#[derive(uniffi::Record)]
pub struct ExecEnvFfi {
    pub key: String,
    pub value: String,
}

#[derive(uniffi::Record)]
pub struct ExecResultFfi {
    pub exit_code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub timed_out: bool,
    pub stdout_truncated: bool,
    pub stderr_truncated: bool,
}

/// A live remote connection owned by `doryd`. Holds its own runtime + the SSH session.
#[derive(uniffi::Object)]
pub struct RemoteAgent {
    runtime: std::sync::Mutex<Option<tokio::runtime::Runtime>>,
    agent: SshAgent,
}

impl RemoteConfig {
    fn into_ssh_config(self) -> Result<SshConfig, RemoteFfiError> {
        let host_key = match self.host_key {
            RemoteHostKey::Pinned { openssh_public_key } => {
                HostKeyPolicy::Pinned(public_key_from_openssh(&openssh_public_key)?)
            }
            RemoteHostKey::KnownHosts { path, host, port } => HostKeyPolicy::KnownHosts {
                path: PathBuf::from(path),
                host,
                port,
            },
        };
        let endpoint = match self.endpoint {
            RemoteEndpoint::UnixSocket { path } => AgentEndpoint::UnixSocket(path),
            RemoteEndpoint::Tcp { host, port } => AgentEndpoint::Tcp { host, port },
        };
        Ok(SshConfig {
            host: self.host,
            port: self.port,
            user: self.user,
            private_key: private_key_from_openssh(&self.openssh_private_key)?,
            host_key,
            endpoint,
            build: self.build,
        })
    }
}

/// Connect to the remote agent over SSH. Blocking; runs on a fresh 2-worker runtime the returned
/// object owns.
#[uniffi::export]
pub fn remote_connect(config: RemoteConfig) -> Result<Arc<RemoteAgent>, RemoteFfiError> {
    let ssh_config = config.into_ssh_config()?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|e| RemoteFfiError::Failed {
            message: e.to_string(),
        })?;
    let agent = runtime.block_on(SshAgent::connect(ssh_config))?;
    Ok(Arc::new(RemoteAgent {
        runtime: std::sync::Mutex::new(Some(runtime)),
        agent,
    }))
}

#[uniffi::export]
impl RemoteAgent {
    /// The agent's `info` (protocol version, kernel, build, uptime).
    pub fn info(&self) -> Result<AgentInfoFfi, RemoteFfiError> {
        let guard = self.runtime.lock().unwrap();
        let runtime = guard.as_ref().ok_or_else(shutdown_error)?;
        let i = runtime.block_on(self.agent.client.info())?;
        Ok(AgentInfoFfi {
            proto_version: i.proto_version,
            kernel: i.kernel,
            agent_build: i.agent_build,
            uptime_secs: i.uptime_secs,
        })
    }

    /// Guest memory + pressure telemetry (for doryd's balloon / idle decisions).
    pub fn telemetry(&self) -> Result<TelemetryFfi, RemoteFfiError> {
        let guard = self.runtime.lock().unwrap();
        let runtime = guard.as_ref().ok_or_else(shutdown_error)?;
        let t = runtime.block_on(self.agent.client.telemetry())?;
        Ok(TelemetryFfi {
            mem_total_kb: t.mem_total_kb,
            mem_available_kb: t.mem_available_kb,
            psi_some_avg10: t.psi_some_avg10,
            psi_full_avg10: t.psi_full_avg10,
        })
    }

    /// Run a bounded non-interactive command through the remote agent.
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
        let out = runtime.block_on(self.agent.client.exec(
            argv,
            cwd,
            env.into_iter().map(|item| (item.key, item.value)).collect(),
            timeout_ms,
            output_limit_bytes,
        ))?;
        Ok(exec_result(out))
    }

    /// Push `local_root` to `remote_root`, making the remote an exact replica (host-authoritative).
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
            &self.agent.client,
        ))?;
        Ok(PushStatsFfi {
            files_sent: stats.files_sent,
            bytes_sent: stats.bytes_sent,
            files_deleted: stats.files_deleted,
        })
    }
}

pub(crate) fn exec_result(out: dory_pb::agent::ExecResponse) -> ExecResultFfi {
    ExecResultFfi {
        exit_code: out.exit_code,
        stdout: out.stdout,
        stderr: out.stderr,
        timed_out: out.timed_out,
        stdout_truncated: out.stdout_truncated,
        stderr_truncated: out.stderr_truncated,
    }
}

fn shutdown_error() -> RemoteFfiError {
    RemoteFfiError::Failed {
        message: "remote agent already shut down".into(),
    }
}

impl Drop for RemoteAgent {
    fn drop(&mut self) {
        if let Some(runtime) = self.runtime.lock().unwrap().take() {
            runtime.shutdown_background();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use russh::keys::ssh_key::{rand_core::OsRng, Algorithm, LineEnding, PrivateKey};
    use russh::server::{self, Auth, Msg, Server as _, Session};
    use russh::{Channel, ChannelId};
    use std::sync::mpsc;

    // A minimal in-process SSH server on its own runtime+thread: accepts publickey auth and bridges a
    // direct-streamlocal channel to the REAL agent daemon handler. Returns (addr, host_pub_openssh).
    fn spawn_ssh_agent_server() -> (std::net::SocketAddr, String) {
        let host_key = PrivateKey::random(&mut OsRng, Algorithm::Ed25519).unwrap();
        let host_pub = host_key.public_key().to_openssh().unwrap();
        let (tx, rx) = mpsc::channel();

        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            rt.block_on(async move {
                let mut cfg = server::Config::default();
                cfg.keys.push(host_key);
                let cfg = Arc::new(cfg);
                let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
                    .await
                    .unwrap();
                tx.send(listener.local_addr().unwrap()).unwrap();
                loop {
                    if let Ok((stream, peer)) = listener.accept().await {
                        let mut srv = Srv;
                        let handler = srv.new_client(Some(peer));
                        let cfg = cfg.clone();
                        tokio::spawn(async move {
                            let _ = server::run_stream(cfg, stream, handler).await;
                            std::future::pending::<()>().await;
                        });
                    }
                }
            });
        });

        (rx.recv().unwrap(), host_pub)
    }

    #[derive(Clone)]
    struct Srv;
    impl server::Server for Srv {
        type Handler = Srv;
        fn new_client(&mut self, _addr: Option<std::net::SocketAddr>) -> Srv {
            Srv
        }
    }
    impl server::Handler for Srv {
        type Error = russh::Error;
        async fn auth_publickey(
            &mut self,
            _u: &str,
            _k: &russh::keys::PublicKey,
        ) -> Result<Auth, Self::Error> {
            Ok(Auth::Accept)
        }
        async fn channel_open_direct_streamlocal(
            &mut self,
            channel: Channel<Msg>,
            _socket_path: &str,
            _session: &mut Session,
        ) -> Result<bool, Self::Error> {
            // The real agent control server over the SSH channel.
            tokio::spawn(dory_agent::daemon::serve_conn(channel.into_stream()));
            Ok(true)
        }
        async fn data(
            &mut self,
            _c: ChannelId,
            _d: &[u8],
            _s: &mut Session,
        ) -> Result<(), Self::Error> {
            Ok(())
        }
    }

    // The full FFI path against a real SSH server + the real agent handler. Sync test (no ambient
    // runtime) so remote_connect's internal block_on is valid.
    #[test]
    fn ffi_connect_info_and_push_over_real_ssh() {
        let (addr, host_pub) = spawn_ssh_agent_server();

        let client_key = PrivateKey::random(&mut OsRng, Algorithm::Ed25519)
            .unwrap()
            .to_openssh(LineEnding::LF)
            .unwrap()
            .to_string();

        let agent = remote_connect(RemoteConfig {
            host: addr.ip().to_string(),
            port: addr.port(),
            user: "dory".into(),
            openssh_private_key: client_key,
            host_key: RemoteHostKey::Pinned {
                openssh_public_key: host_pub,
            },
            endpoint: RemoteEndpoint::UnixSocket {
                path: "/run/dory/agent.sock".into(),
            },
            build: "doryd-ffi-test".into(),
        })
        .expect("connect over ssh");

        let info = agent.info().expect("info");
        assert_eq!(info.proto_version, 1);
        assert!(info.agent_build.starts_with("dory-agent/"));

        // Push a small tree and confirm the real agent replicated it byte-exact.
        let base = std::env::temp_dir();
        let local = base.join(format!("dory-ffi-local-{}", std::process::id()));
        let remote = base.join(format!("dory-ffi-remote-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&local);
        let _ = std::fs::remove_dir_all(&remote);
        std::fs::create_dir_all(local.join("src")).unwrap();
        std::fs::write(local.join("src/main.rs"), b"fn main() {}").unwrap();
        std::fs::write(local.join("README.md"), b"# hi").unwrap();
        std::fs::create_dir_all(&remote).unwrap();

        let stats = agent
            .push(
                local.to_string_lossy().into_owned(),
                remote.to_string_lossy().into_owned(),
            )
            .expect("push");
        assert_eq!(stats.files_sent, 2);
        assert_eq!(
            std::fs::read(remote.join("src/main.rs")).unwrap(),
            b"fn main() {}"
        );

        let _ = std::fs::remove_dir_all(&local);
        let _ = std::fs::remove_dir_all(&remote);
    }

    #[test]
    fn a_wrong_pinned_host_key_fails_to_connect() {
        let (addr, _host_pub) = spawn_ssh_agent_server();
        let wrong_pub = PrivateKey::random(&mut OsRng, Algorithm::Ed25519)
            .unwrap()
            .public_key()
            .to_openssh()
            .unwrap();
        let client_key = PrivateKey::random(&mut OsRng, Algorithm::Ed25519)
            .unwrap()
            .to_openssh(LineEnding::LF)
            .unwrap()
            .to_string();
        let res = remote_connect(RemoteConfig {
            host: addr.ip().to_string(),
            port: addr.port(),
            user: "dory".into(),
            openssh_private_key: client_key,
            host_key: RemoteHostKey::Pinned {
                openssh_public_key: wrong_pub,
            },
            endpoint: RemoteEndpoint::UnixSocket { path: "/x".into() },
            build: "t".into(),
        });
        assert!(
            res.is_err(),
            "a mismatched host key must fail the connection"
        );
    }
}
