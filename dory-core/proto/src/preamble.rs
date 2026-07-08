//! The forward preamble.
//!
//! `dory-hv` (the docker-tier VMM) forwards one raw unix connection to doryd per guest vsock stream,
//! prefixing each with this single frame so doryd learns the direction/cid/port **without parsing
//! any application protocol** — that keeps `dory-hv` honestly protocol-free. The preamble is a normal
//! [`crate::frame`], so a truncated/oversized one is rejected before doryd trusts the port.

use crate::frame::{read_frame, write_frame, FrameError};
use tokio::io::{AsyncRead, AsyncWrite};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// Guest opened the stream (docker client inside guest, AI dial-back).
    GuestToHost,
    /// Host opened the stream (doryd dialing a guest listener).
    HostToGuest,
}

impl Direction {
    fn to_byte(self) -> u8 {
        match self {
            Direction::GuestToHost => 0,
            Direction::HostToGuest => 1,
        }
    }
    fn from_byte(b: u8) -> Option<Direction> {
        match b {
            0 => Some(Direction::GuestToHost),
            1 => Some(Direction::HostToGuest),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Preamble {
    pub direction: Direction,
    pub cid: u32,
    pub port: u32,
}

const PREAMBLE_BYTES: usize = 9; // direction(1) + cid(4 LE) + port(4 LE)

#[derive(Debug, thiserror::Error)]
pub enum PreambleError {
    #[error("preamble frame: {0}")]
    Frame(#[from] FrameError),
    #[error("malformed preamble")]
    Malformed,
}

impl Preamble {
    pub fn encode(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(PREAMBLE_BYTES);
        v.push(self.direction.to_byte());
        v.extend_from_slice(&self.cid.to_le_bytes());
        v.extend_from_slice(&self.port.to_le_bytes());
        v
    }

    pub fn decode(b: &[u8]) -> Option<Preamble> {
        if b.len() != PREAMBLE_BYTES {
            return None;
        }
        Some(Preamble {
            direction: Direction::from_byte(b[0])?,
            cid: u32::from_le_bytes(b[1..5].try_into().ok()?),
            port: u32::from_le_bytes(b[5..9].try_into().ok()?),
        })
    }
}

pub async fn write_preamble<W: AsyncWrite + Unpin>(
    w: &mut W,
    p: &Preamble,
) -> Result<(), PreambleError> {
    write_frame(w, &p.encode()).await?;
    Ok(())
}

pub async fn read_preamble<R: AsyncRead + Unpin>(r: &mut R) -> Result<Preamble, PreambleError> {
    let frame = read_frame(r).await?;
    Preamble::decode(&frame).ok_or(PreambleError::Malformed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::duplex;

    #[tokio::test]
    async fn round_trips_both_directions() {
        for direction in [Direction::GuestToHost, Direction::HostToGuest] {
            let p = Preamble {
                direction,
                cid: 3,
                port: crate::channels::PORT_DOCKER,
            };
            let (mut a, mut b) = duplex(64);
            let sent = p.clone();
            tokio::spawn(async move { write_preamble(&mut a, &sent).await.unwrap() });
            assert_eq!(read_preamble(&mut b).await.unwrap(), p);
        }
    }

    #[tokio::test]
    async fn rejects_wrong_length() {
        let (mut a, mut b) = duplex(64);
        // A valid frame carrying a too-short body -> Malformed, not a panic.
        tokio::spawn(async move { write_frame(&mut a, &[0u8; 3]).await.unwrap() });
        assert!(matches!(
            read_preamble(&mut b).await,
            Err(PreambleError::Malformed)
        ));
    }
}
