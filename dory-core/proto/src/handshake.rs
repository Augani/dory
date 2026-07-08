//! The versioned handshake.
//!
//! The first control-channel frame each side sends is a [`Hello`]. If the protocol versions disagree
//! the peer gets a clean [`HandshakeError::VersionMismatch`] and the connection is refused — never
//! the old failure mode where a version skew surfaced as a `malformedFrame` wedge. After a
//! successful handshake the control channel is handed to [`crate::mux`].

use crate::frame::{read_frame, write_frame, FrameError};
use tokio::io::{AsyncRead, AsyncWrite};

/// Bumped on any breaking change to the wire protocol.
pub const PROTO_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hello {
    pub proto_version: u32,
    pub build: String,
}

impl Hello {
    pub fn current(build: impl Into<String>) -> Hello {
        Hello {
            proto_version: PROTO_VERSION,
            build: build.into(),
        }
    }

    fn encode(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(4 + self.build.len());
        v.extend_from_slice(&self.proto_version.to_le_bytes());
        v.extend_from_slice(self.build.as_bytes());
        v
    }

    fn decode(b: &[u8]) -> Option<Hello> {
        if b.len() < 4 {
            return None;
        }
        Some(Hello {
            proto_version: u32::from_le_bytes(b[0..4].try_into().ok()?),
            build: String::from_utf8_lossy(&b[4..]).into_owned(),
        })
    }
}

#[derive(Debug, thiserror::Error)]
pub enum HandshakeError {
    #[error("protocol version mismatch: local {local}, peer {peer}")]
    VersionMismatch { local: u32, peer: u32 },
    #[error("handshake frame: {0}")]
    Frame(#[from] FrameError),
    #[error("malformed hello")]
    Malformed,
}

/// Exchange Hellos over `stream` and return the peer's Hello, or a clean error on version skew /
/// malformed greeting. Writes the local Hello first, then reads the peer's — safe over a duplex
/// because a frame write completes into the transport buffer before the read.
pub async fn handshake<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    local: &Hello,
) -> Result<Hello, HandshakeError> {
    write_frame(stream, &local.encode()).await?;
    let frame = read_frame(stream).await?;
    let peer = Hello::decode(&frame).ok_or(HandshakeError::Malformed)?;
    if peer.proto_version != local.proto_version {
        return Err(HandshakeError::VersionMismatch {
            local: local.proto_version,
            peer: peer.proto_version,
        });
    }
    Ok(peer)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::duplex;

    #[tokio::test]
    async fn matching_versions_exchange_builds() {
        let (mut a, mut b) = duplex(4096);
        let host =
            tokio::spawn(async move { handshake(&mut a, &Hello::current("doryd-0.4")).await });
        let peer = handshake(&mut b, &Hello::current("agent-0.4"))
            .await
            .unwrap();
        let host_saw = host.await.unwrap().unwrap();
        assert_eq!(peer.build, "doryd-0.4");
        assert_eq!(host_saw.build, "agent-0.4");
    }

    #[tokio::test]
    async fn version_mismatch_is_a_clean_error() {
        let (mut a, mut b) = duplex(4096);
        let older = Hello {
            proto_version: PROTO_VERSION + 1,
            build: "newer".into(),
        };
        let a_task = tokio::spawn(async move { handshake(&mut a, &older).await });
        let res = handshake(&mut b, &Hello::current("current")).await;
        assert!(
            matches!(res, Err(HandshakeError::VersionMismatch { .. })),
            "got {res:?}"
        );
        // Both ends detect it — no wedge, no hang.
        assert!(matches!(
            a_task.await.unwrap(),
            Err(HandshakeError::VersionMismatch { .. })
        ));
    }
}
