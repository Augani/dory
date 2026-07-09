use dory_proto::handshake::HandshakeError;
use dory_proto::mux::MuxError;

#[derive(Debug, thiserror::Error)]
pub enum RemoteError {
    #[error("ssh transport: {0}")]
    Ssh(String),
    #[error("ssh authentication failed for user {0}")]
    AuthFailed(String),
    #[error("agent rpc timed out after {0:?}")]
    Timeout(std::time::Duration),
    #[error("handshake: {0}")]
    Handshake(#[from] HandshakeError),
    #[error("mux: {0}")]
    Mux(#[from] MuxError),
    #[error("could not decode agent response")]
    Decode,
    #[error("agent rpc error {code}: {message}")]
    Rpc { code: i32, message: String },
    #[error("agent returned an unexpected response variant")]
    UnexpectedVariant,
    #[error(transparent)]
    Io(#[from] std::io::Error),
}
