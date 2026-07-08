//! Length-delimited framing — the one on-wire framing used everywhere (vsock, unix, SSH).
//!
//! A frame is a little-endian `u32` length prefix followed by exactly that many payload bytes.
//! Endianness is pinned LE to match virtio/FUSE (the legacy RPC prefix was big-endian, which was a
//! cross-language footgun). The maximum frame is 16 MiB.
//!
//! The critical property that killed the old `malformedFrame` wedge: a **timeout is not a frame
//! error**. This codec never times out on its own — a slow or idle peer simply parks the read
//! future. Callers that want a deadline wrap a read in `tokio::time::timeout` and get an `Elapsed`,
//! which is categorically distinct from [`FrameError`]. Genuine wire problems map to precise
//! variants: a clean EOF at a frame boundary is [`FrameError::Eof`] (no more frames, normal), an EOF
//! mid-frame is [`FrameError::Corrupt`] (truncated), and an oversized length is
//! [`FrameError::TooLarge`] (rejected before allocating).

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Maximum accepted frame payload, in bytes (16 MiB).
pub const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;

/// The prefix is a fixed 4-byte little-endian `u32`.
pub const PREFIX_BYTES: usize = 4;

#[derive(Debug, thiserror::Error)]
pub enum FrameError {
    /// The declared/attempted payload length exceeds [`MAX_FRAME_BYTES`].
    #[error("frame length {0} exceeds maximum {MAX_FRAME_BYTES}")]
    TooLarge(usize),
    /// The stream ended cleanly on a frame boundary. Not an error condition for a reader loop —
    /// it means "no more frames", the normal way a peer signals end of stream.
    #[error("stream closed at frame boundary")]
    Eof,
    /// The stream ended partway through a length prefix or payload — the frame is truncated.
    #[error("stream closed mid-frame (truncated/corrupt)")]
    Corrupt,
    /// An underlying transport I/O error (never a timeout — see the module docs).
    #[error("frame io: {0}")]
    Io(#[from] std::io::Error),
}

impl FrameError {
    /// True when the reader should stop cleanly rather than log an error: a frame-boundary EOF.
    pub fn is_clean_eof(&self) -> bool {
        matches!(self, FrameError::Eof)
    }
}

/// Fully read `buf` from `r`. Returns `Ok(true)` when filled, `Ok(false)` when the stream ends
/// **before any byte** (a clean boundary), and `Err(UnexpectedEof)` when it ends after a partial
/// read (truncation). This 3-way distinction is what lets `read_frame` tell `Eof` from `Corrupt`.
async fn read_exact_or_boundary_eof<R: AsyncRead + Unpin>(
    r: &mut R,
    buf: &mut [u8],
) -> std::io::Result<bool> {
    let mut filled = 0;
    while filled < buf.len() {
        let n = r.read(&mut buf[filled..]).await?;
        if n == 0 {
            if filled == 0 {
                return Ok(false);
            }
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "stream ended mid-frame",
            ));
        }
        filled += n;
    }
    Ok(true)
}

/// Write one frame: the LE length prefix then the payload. Rejects oversized payloads before writing
/// anything, so a bad caller can't emit a half-frame.
pub async fn write_frame<W: AsyncWrite + Unpin>(
    w: &mut W,
    payload: &[u8],
) -> Result<(), FrameError> {
    if payload.len() > MAX_FRAME_BYTES {
        return Err(FrameError::TooLarge(payload.len()));
    }
    let prefix = (payload.len() as u32).to_le_bytes();
    w.write_all(&prefix).await?;
    w.write_all(payload).await?;
    Ok(())
}

/// Read one frame. See the module docs for the error taxonomy. Never allocates the payload buffer
/// until the declared length has passed the [`MAX_FRAME_BYTES`] bound, so a hostile prefix cannot
/// trigger a 4 GiB allocation.
pub async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> Result<Vec<u8>, FrameError> {
    let mut prefix = [0u8; PREFIX_BYTES];
    match read_exact_or_boundary_eof(r, &mut prefix).await {
        Ok(true) => {}
        Ok(false) => return Err(FrameError::Eof),
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Err(FrameError::Corrupt),
        Err(e) => return Err(e.into()),
    }

    let len = u32::from_le_bytes(prefix) as usize;
    if len > MAX_FRAME_BYTES {
        return Err(FrameError::TooLarge(len));
    }
    if len == 0 {
        return Ok(Vec::new());
    }

    let mut payload = vec![0u8; len];
    match read_exact_or_boundary_eof(r, &mut payload).await {
        Ok(true) => Ok(payload),
        // A declared but entirely-absent or partially-read payload is a truncated frame.
        Ok(false) => Err(FrameError::Corrupt),
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => Err(FrameError::Corrupt),
        Err(e) => Err(e.into()),
    }
}

/// Encode a frame into a freshly allocated buffer (prefix + payload), for callers that batch writes.
pub fn encode(payload: &[u8]) -> Result<Vec<u8>, FrameError> {
    if payload.len() > MAX_FRAME_BYTES {
        return Err(FrameError::TooLarge(payload.len()));
    }
    let mut out = Vec::with_capacity(PREFIX_BYTES + payload.len());
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(payload);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::io::duplex;

    #[tokio::test]
    async fn round_trips_various_sizes() {
        for size in [0usize, 1, 4, 255, 256, 65_536, MAX_FRAME_BYTES] {
            let payload = vec![0xABu8; size];
            let (mut a, mut b) = duplex(MAX_FRAME_BYTES + 1024);
            let writer = tokio::spawn(async move {
                write_frame(&mut a, &payload).await.unwrap();
                payload
            });
            let got = read_frame(&mut b).await.unwrap();
            let sent = writer.await.unwrap();
            assert_eq!(got, sent, "size {size}");
        }
    }

    #[tokio::test]
    async fn multiple_frames_in_sequence() {
        let (mut a, mut b) = duplex(4096);
        tokio::spawn(async move {
            for i in 0..5u8 {
                write_frame(&mut a, &[i; 10]).await.unwrap();
            }
        });
        for i in 0..5u8 {
            assert_eq!(read_frame(&mut b).await.unwrap(), vec![i; 10]);
        }
        // After the last frame, the writer's half drops -> clean boundary EOF.
        assert!(matches!(read_frame(&mut b).await, Err(FrameError::Eof)));
    }

    #[tokio::test]
    async fn clean_eof_at_boundary() {
        let (a, mut b) = duplex(64);
        drop(a);
        let err = read_frame(&mut b).await.unwrap_err();
        assert!(err.is_clean_eof(), "expected Eof, got {err:?}");
    }

    #[tokio::test]
    async fn truncated_prefix_is_corrupt() {
        let (mut a, mut b) = duplex(64);
        tokio::spawn(async move {
            // Only 2 of the 4 prefix bytes, then close.
            a.write_all(&[0x01, 0x00]).await.unwrap();
        });
        assert!(matches!(read_frame(&mut b).await, Err(FrameError::Corrupt)));
    }

    #[tokio::test]
    async fn truncated_payload_is_corrupt() {
        let (mut a, mut b) = duplex(64);
        tokio::spawn(async move {
            // Prefix declares 10 bytes; send only 3, then close.
            a.write_all(&10u32.to_le_bytes()).await.unwrap();
            a.write_all(&[1, 2, 3]).await.unwrap();
        });
        assert!(matches!(read_frame(&mut b).await, Err(FrameError::Corrupt)));
    }

    #[tokio::test]
    async fn oversized_declared_length_rejected_without_allocating() {
        let (mut a, mut b) = duplex(64);
        tokio::spawn(async move {
            // Declare a huge frame; we must reject on the prefix, never try to read/allocate it.
            let huge = (MAX_FRAME_BYTES as u32) + 1;
            a.write_all(&huge.to_le_bytes()).await.unwrap();
        });
        match read_frame(&mut b).await {
            Err(FrameError::TooLarge(n)) => assert_eq!(n, MAX_FRAME_BYTES + 1),
            other => panic!("expected TooLarge, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn oversized_write_rejected() {
        let (mut a, _b) = duplex(64);
        let payload = vec![0u8; MAX_FRAME_BYTES + 1];
        assert!(matches!(
            write_frame(&mut a, &payload).await,
            Err(FrameError::TooLarge(_))
        ));
    }

    /// THE anti-wedge property: a slow/idle peer produces a timeout at the CALL SITE, never a
    /// `FrameError`. read_frame parks; `tokio::time::timeout` yields `Elapsed`; the two are distinct.
    #[tokio::test(start_paused = true)]
    async fn timeout_is_not_a_frame_error() {
        let (_a, mut b) = duplex(64); // keep _a alive so there is no EOF; just no data ever arrives
        let res = tokio::time::timeout(Duration::from_secs(5), read_frame(&mut b)).await;
        assert!(
            res.is_err(),
            "the deadline must elapse (Elapsed), not resolve to a FrameError"
        );
        // read_frame itself never yielded a FrameError; the error is a timeout owned by the caller.
    }
}
