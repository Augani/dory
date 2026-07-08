//! Request/response multiplexing over a single control connection.
//!
//! The legacy wedge: every RPC opened a fresh vsock connection and did a lockstep write-then-read
//! with a shared unguarded id, so any concurrent reuse interleaved response bytes and every read
//! could be mislabeled `malformedFrame`. This mux removes the whole class:
//!
//! - **One writer.** All outbound messages are serialized through an `mpsc` into a single writer
//!   task, so two producers can never interleave bytes on the wire.
//! - **An id-keyed router.** Every request carries a `u64` id; the reader task routes each response
//!   to the waiting caller's oneshot by id, so responses may complete out of order without confusion.
//! - **Full duplex.** The same connection serves inbound requests via a handler and issues outbound
//!   requests via [`Mux::call`]; the `REQUEST`/`RESPONSE` kind byte disambiguates, and each end only
//!   routes responses into its own pending map, so the two ends' id spaces never collide.
//!
//! Wire message (inside one [`crate::frame`] frame): `id: u64 LE` · `kind: u8` · `payload`.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{mpsc, oneshot};

use crate::frame::{read_frame, write_frame, FrameError};

const KIND_REQUEST: u8 = 1;
const KIND_RESPONSE: u8 = 2;
const HEADER_BYTES: usize = 9; // 8 (id) + 1 (kind)

/// A handler for inbound requests: given the request payload, produce a response payload.
pub type HandlerFuture = Pin<Box<dyn Future<Output = Vec<u8>> + Send>>;
pub type Handler = Arc<dyn Fn(Vec<u8>) -> HandlerFuture + Send + Sync>;

/// A handler that answers every request with an empty body — for an end that only makes calls.
pub fn no_handler() -> Handler {
    Arc::new(|_req| Box::pin(async { Vec::new() }))
}

#[derive(Debug, thiserror::Error)]
pub enum MuxError {
    #[error("mux connection closed")]
    Closed,
    #[error("mux frame: {0}")]
    Frame(#[from] FrameError),
}

fn encode_msg(id: u64, kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(HEADER_BYTES + payload.len());
    v.extend_from_slice(&id.to_le_bytes());
    v.push(kind);
    v.extend_from_slice(payload);
    v
}

fn decode_msg(frame: &[u8]) -> Option<(u64, u8, &[u8])> {
    if frame.len() < HEADER_BYTES {
        return None;
    }
    let id = u64::from_le_bytes(frame[0..8].try_into().ok()?);
    Some((id, frame[8], &frame[HEADER_BYTES..]))
}

type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<Vec<u8>>>>>;

/// A live multiplexed connection. Cloneable is not needed — share via `Arc<Mux>`.
pub struct Mux {
    next_id: AtomicU64,
    pending: Pending,
    out: mpsc::Sender<Vec<u8>>,
}

impl Mux {
    /// Start the mux over `stream`, spawning the writer and reader tasks. `handler` answers inbound
    /// requests; use [`no_handler`] for a call-only end.
    pub fn start<S>(stream: S, handler: Handler) -> Arc<Mux>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let (mut reader, mut writer) = tokio::io::split(stream);
        let (out_tx, mut out_rx) = mpsc::channel::<Vec<u8>>(256);
        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));

        // Single writer: the only place bytes are put on the wire.
        tokio::spawn(async move {
            while let Some(msg) = out_rx.recv().await {
                if write_frame(&mut writer, &msg).await.is_err() {
                    break;
                }
            }
        });

        // Reader: demux responses to callers, dispatch requests to the handler.
        let pending_r = pending.clone();
        let out_r = out_tx.clone();
        tokio::spawn(async move {
            loop {
                let frame = match read_frame(&mut reader).await {
                    Ok(f) => f,
                    Err(_) => break, // Eof or transport error: shut the mux down
                };
                let Some((id, kind, payload)) = decode_msg(&frame) else {
                    continue; // ignore a runt message rather than kill the connection
                };
                match kind {
                    KIND_RESPONSE => {
                        let waiter = pending_r.lock().unwrap().remove(&id);
                        if let Some(tx) = waiter {
                            let _ = tx.send(payload.to_vec());
                        }
                    }
                    KIND_REQUEST => {
                        let handler = handler.clone();
                        let out = out_r.clone();
                        let payload = payload.to_vec();
                        // Handle concurrently; the response is one framed message tagged with `id`,
                        // serialized through the single writer, so it can never interleave.
                        tokio::spawn(async move {
                            let resp = handler(payload).await;
                            let _ = out.send(encode_msg(id, KIND_RESPONSE, &resp)).await;
                        });
                    }
                    _ => {}
                }
            }
            // Connection gone: drop every waiter so in-flight callers unblock with `Closed`.
            pending_r.lock().unwrap().clear();
        });

        Arc::new(Mux {
            next_id: AtomicU64::new(1),
            pending,
            out: out_tx,
        })
    }

    /// Convenience: a call-only end (inbound requests answered with an empty body).
    pub fn client<S>(stream: S) -> Arc<Mux>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        Mux::start(stream, no_handler())
    }

    /// Issue a request and await its response. Concurrent calls are safe and may complete in any
    /// order — each is routed by its own id.
    pub async fn call(&self, payload: &[u8]) -> Result<Vec<u8>, MuxError> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        if self
            .out
            .send(encode_msg(id, KIND_REQUEST, payload))
            .await
            .is_err()
        {
            self.pending.lock().unwrap().remove(&id);
            return Err(MuxError::Closed);
        }
        rx.await.map_err(|_| MuxError::Closed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::io::duplex;

    fn echo_handler() -> Handler {
        // Echo the payload back, but sleep LONGER for lower-numbered requests so responses come back
        // out of order — proving the router keys on id, not arrival order.
        Arc::new(|req: Vec<u8>| {
            Box::pin(async move {
                let n = *req.first().unwrap_or(&0) as u64;
                tokio::time::sleep(Duration::from_millis(50 - n.min(49))).await;
                let mut resp = b"echo:".to_vec();
                resp.extend_from_slice(&req);
                resp
            })
        })
    }

    #[tokio::test]
    async fn concurrent_calls_route_by_id_out_of_order() {
        let (a, b) = duplex(64 * 1024);
        let client = Mux::client(a);
        let _server = Mux::start(b, echo_handler());

        // Fire 32 concurrent calls with distinct payloads; each must get ITS OWN echo despite the
        // server completing them in reverse order.
        let mut handles = Vec::new();
        for i in 0..32u8 {
            let client = client.clone();
            handles.push(tokio::spawn(async move {
                let resp = client.call(&[i, 0xAA, i]).await.unwrap();
                (i, resp)
            }));
        }
        for h in handles {
            let (i, resp) = h.await.unwrap();
            let mut expected = b"echo:".to_vec();
            expected.extend_from_slice(&[i, 0xAA, i]);
            assert_eq!(
                resp, expected,
                "call {i} got the wrong response — ids crossed"
            );
        }
    }

    #[tokio::test]
    async fn full_duplex_both_ends_call() {
        // Both ends serve AND call; ids are per-end so numeric overlap must not confuse routing.
        let (a, b) = duplex(64 * 1024);
        let end_a = Mux::start(a, {
            Arc::new(|req: Vec<u8>| {
                Box::pin(async move { [b"A:".to_vec(), req].concat() }) as HandlerFuture
            })
        });
        let end_b = Mux::start(b, {
            Arc::new(|req: Vec<u8>| {
                Box::pin(async move { [b"B:".to_vec(), req].concat() }) as HandlerFuture
            })
        });

        let (ra, rb) = tokio::join!(end_a.call(b"ping"), end_b.call(b"ping"));
        assert_eq!(ra.unwrap(), b"B:ping"); // A's call handled by B
        assert_eq!(rb.unwrap(), b"A:ping"); // B's call handled by A
    }

    #[tokio::test]
    async fn call_after_close_errors_not_hangs() {
        let (a, b) = duplex(1024);
        let client = Mux::client(a);
        drop(b); // peer gone
                 // The reader sees EOF and clears pending; the call must return Closed, never hang.
        let res = tokio::time::timeout(Duration::from_secs(5), client.call(b"x")).await;
        assert!(matches!(res, Ok(Err(MuxError::Closed))), "got {res:?}");
    }
}
