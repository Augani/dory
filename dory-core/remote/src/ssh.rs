//! The SSH transport for [`AgentClient`]: `doryd` reaches a `dory-agent` running in daemon mode on
//! a remote VPS. It opens an SSH connection (russh client), authenticates with a key, and tunnels a
//! channel to wherever the agent daemon listens — a unix socket (`direct-streamlocal`) or a local
//! TCP port (`direct-tcpip`). The channel is a byte stream, so the *same* `handshake` + `mux` + pb
//! RPC that runs over VZ vsock runs over it unchanged — one protocol, a different transport.
//!
//! Host-key verification is mandatory and explicit ([`HostKeyPolicy`]); there is deliberately no
//! "accept any" variant, so a caller cannot silently disable MITM protection.

use std::path::PathBuf;
use std::sync::Arc;

use russh::client::{self, Handle, Handler};
use russh::keys::{PrivateKey, PrivateKeyWithHashAlg, PublicKey};

use crate::agent_client::AgentClient;
use crate::error::RemoteError;

/// Where the agent daemon listens on the remote host.
pub enum AgentEndpoint {
    /// A unix domain socket path on the remote (opened via `direct-streamlocal`).
    UnixSocket(String),
    /// A TCP port on the remote, typically bound to loopback (opened via `direct-tcpip`).
    Tcp { host: String, port: u16 },
}

/// How the server's host key is verified. No "accept any" variant exists on purpose.
pub enum HostKeyPolicy {
    /// Trust exactly this key (strongest — obtained out of band at provisioning / prior TOFU).
    Pinned(PublicKey),
    /// Consult an OpenSSH `known_hosts` file for `host:port`.
    KnownHosts {
        path: PathBuf,
        host: String,
        port: u16,
    },
}

pub struct SshConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    /// The client identity (loaded by the caller — from Keychain in `doryd`).
    pub private_key: PrivateKey,
    pub host_key: HostKeyPolicy,
    pub endpoint: AgentEndpoint,
    /// The build string sent in the protocol handshake Hello.
    pub build: String,
}

/// A live remote agent connection. Holds the SSH [`Handle`] so the session task stays alive for the
/// lifetime of the RPC client; dropping this closes the SSH connection.
pub struct SshAgent {
    _handle: Handle<ClientHandler>,
    pub client: AgentClient,
}

impl SshAgent {
    pub async fn connect(config: SshConfig) -> Result<SshAgent, RemoteError> {
        let SshConfig {
            host,
            port,
            user,
            private_key,
            host_key,
            endpoint,
            build,
        } = config;

        let ssh_config = Arc::new(client::Config::default());
        let handler = ClientHandler { policy: host_key };
        let mut handle = client::connect(ssh_config, (host.as_str(), port), handler)
            .await
            .map_err(|e| RemoteError::Ssh(e.to_string()))?;

        let key = PrivateKeyWithHashAlg::new(Arc::new(private_key), None);
        let auth = handle
            .authenticate_publickey(user.clone(), key)
            .await
            .map_err(|e| RemoteError::Ssh(e.to_string()))?;
        if !auth.success() {
            return Err(RemoteError::AuthFailed(user));
        }

        let channel = match endpoint {
            AgentEndpoint::UnixSocket(path) => handle.channel_open_direct_streamlocal(path).await,
            AgentEndpoint::Tcp { host, port } => {
                handle
                    .channel_open_direct_tcpip(host, port as u32, "127.0.0.1".to_string(), 0)
                    .await
            }
        }
        .map_err(|e| RemoteError::Ssh(e.to_string()))?;

        let client = AgentClient::connect(channel.into_stream(), build).await?;
        Ok(SshAgent {
            _handle: handle,
            client,
        })
    }
}

struct ClientHandler {
    policy: HostKeyPolicy,
}

impl Handler for ClientHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &PublicKey,
    ) -> Result<bool, Self::Error> {
        match &self.policy {
            // Compare key MATERIAL, not the whole PublicKey: `==` on ssh_key::PublicKey also compares
            // the comment, which is never sent over the wire, so a pinned key carrying a comment
            // would spuriously mismatch the presented (comment-less) host key.
            HostKeyPolicy::Pinned(pinned) => Ok(pinned.key_data() == server_public_key.key_data()),
            HostKeyPolicy::KnownHosts { path, host, port } => {
                // A parse/IO error on known_hosts is treated as "not known" — reject, never accept.
                Ok(
                    russh::keys::check_known_hosts_path(host, *port, server_public_key, path)
                        .unwrap_or(false),
                )
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use dory_pb::agent::{
        self, agent_request::Method, agent_response::Result as Res, AgentRequest, AgentResponse,
    };
    use dory_proto::handshake::{handshake, Hello};
    use dory_proto::mux::{Handler as MuxHandler, HandlerFuture, Mux};
    use prost::Message;
    use russh::keys::ssh_key::{rand_core::OsRng, Algorithm, PrivateKey};
    use russh::server::{self, Auth, Msg, Server as _, Session};
    use russh::{Channel, ChannelId};
    use tokio::net::TcpListener;

    /// A fresh throwaway ed25519 identity — generated per test so no key material lives in the repo.
    fn gen_key() -> PrivateKey {
        PrivateKey::random(&mut OsRng, Algorithm::Ed25519).expect("generate ed25519 key")
    }

    /// The agent daemon side over an arbitrary byte stream: the real handshake + a mux whose handler
    /// answers an InfoRequest. This is the agent's control server minus the transport.
    async fn run_fake_agent<S>(mut stream: S)
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
    {
        if handshake(&mut stream, &Hello::current("fake-remote-agent"))
            .await
            .is_err()
        {
            return;
        }
        let handler: MuxHandler = Arc::new(|req: Vec<u8>| {
            Box::pin(async move {
                let req = AgentRequest::decode(req.as_slice()).unwrap();
                let result = match req.method {
                    Some(Method::Info(_)) => Res::Info(agent::InfoResponse {
                        proto_version: dory_proto::handshake::PROTO_VERSION,
                        kernel: "Linux vps 6.12".into(),
                        agent_build: "fake-remote-agent".into(),
                        uptime_secs: 7,
                    }),
                    _ => Res::Error(agent::RpcError {
                        code: 400,
                        message: "unsupported".into(),
                    }),
                };
                AgentResponse {
                    result: Some(result),
                }
                .encode_to_vec()
            }) as HandlerFuture
        });
        let _mux = Mux::start(stream, handler);
        std::future::pending::<()>().await;
    }

    #[derive(Clone)]
    struct TestServer;

    impl server::Server for TestServer {
        type Handler = TestServerHandler;
        fn new_client(&mut self, _addr: Option<std::net::SocketAddr>) -> TestServerHandler {
            TestServerHandler
        }
    }

    struct TestServerHandler;

    impl server::Handler for TestServerHandler {
        type Error = russh::Error;

        async fn auth_publickey(
            &mut self,
            _user: &str,
            _key: &PublicKey,
        ) -> Result<Auth, Self::Error> {
            Ok(Auth::Accept)
        }

        // The exact production tunnel path: the client opens a direct-streamlocal channel to the
        // agent's socket; the server bridges that channel straight into the fake agent.
        async fn channel_open_direct_streamlocal(
            &mut self,
            channel: Channel<Msg>,
            _socket_path: &str,
            _session: &mut Session,
        ) -> Result<bool, Self::Error> {
            tokio::spawn(run_fake_agent(channel.into_stream()));
            Ok(true)
        }

        async fn channel_open_session(
            &mut self,
            _channel: Channel<Msg>,
            _session: &mut Session,
        ) -> Result<bool, Self::Error> {
            Ok(true)
        }

        async fn data(
            &mut self,
            _channel: ChannelId,
            _data: &[u8],
            _session: &mut Session,
        ) -> Result<(), Self::Error> {
            Ok(())
        }
    }

    /// Full end-to-end over REAL russh: an in-process SSH server accepts publickey auth and bridges
    /// a direct-streamlocal channel to a fake agent; our SshAgent::connect drives a real Info RPC
    /// over the SSH ChannelStream. Proves the same protobuf protocol rides SSH, exactly as it rides
    /// vsock — the production remote path minus a network.
    #[tokio::test]
    async fn info_rpc_over_real_ssh_direct_streamlocal() {
        let host_key = gen_key();
        let server_pub = host_key.public_key().clone();

        let mut server_config = server::Config::default();
        server_config.keys.push(host_key);
        let server_config = Arc::new(server_config);

        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let addr = listener.local_addr().unwrap();

        tokio::spawn(async move {
            let mut server = TestServer;
            if let Ok((stream, peer)) = listener.accept().await {
                let handler = server.new_client(Some(peer));
                let _ = russh::server::run_stream(server_config, stream, handler).await;
                // Hold the session open for the RPC.
                std::future::pending::<()>().await;
            }
        });

        let agent = SshAgent::connect(SshConfig {
            host: addr.ip().to_string(),
            port: addr.port(),
            user: "dory".into(),
            private_key: gen_key(),
            host_key: HostKeyPolicy::Pinned(server_pub),
            endpoint: AgentEndpoint::UnixSocket("/run/dory/agent.sock".into()),
            build: "doryd-test".into(),
        })
        .await
        .expect("ssh connect + agent handshake");

        let info = agent.client.info().await.expect("info rpc over ssh");
        assert_eq!(info.proto_version, dory_proto::handshake::PROTO_VERSION);
        assert_eq!(info.agent_build, "fake-remote-agent");
        assert_eq!(info.uptime_secs, 7);
    }

    /// A wrong pinned host key must be rejected — the connection fails rather than trusting an
    /// unverified server (MITM protection is not optional).
    #[tokio::test]
    async fn wrong_pinned_host_key_is_rejected() {
        let mut server_config = server::Config::default();
        server_config.keys.push(gen_key());
        let server_config = Arc::new(server_config);

        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let mut server = TestServer;
            if let Ok((stream, peer)) = listener.accept().await {
                let handler = server.new_client(Some(peer));
                let _ = russh::server::run_stream(server_config, stream, handler).await;
                std::future::pending::<()>().await;
            }
        });

        // Pin an UNRELATED key as the "expected host key" — a deliberate mismatch with the real host.
        let wrong_pub = gen_key().public_key().clone();
        let res = SshAgent::connect(SshConfig {
            host: addr.ip().to_string(),
            port: addr.port(),
            user: "dory".into(),
            private_key: gen_key(),
            host_key: HostKeyPolicy::Pinned(wrong_pub),
            endpoint: AgentEndpoint::UnixSocket("/run/dory/agent.sock".into()),
            build: "doryd-test".into(),
        })
        .await;
        assert!(
            res.is_err(),
            "a mismatched host key must fail the connection"
        );
    }
}
