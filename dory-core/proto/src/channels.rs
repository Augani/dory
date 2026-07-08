//! The vsock port catalog, shared by host (doryd + the dory-hv forward) and guest (dory-agent).
//!
//! Only the control port is multiplexed (agent RPC via [`crate::mux`]). Every other port is a raw
//! byte stream forwarded as its own connection, so concurrency is by connection and one slow docker
//! attach can never head-of-line-block the control channel.

/// Multiplexed agent RPC: clock, ports, fsevents, exec, info.
pub const PORT_CONTROL: u32 = 1024;
/// usbip byte stream.
pub const PORT_USBIP: u32 = 1025;
/// Docker byte-stream bridge (host `dory.sock` ↔ guest `dockerd`), one connection per docker client.
pub const PORT_DOCKER: u32 = 1026;
/// Interactive machine shell PTY byte stream, one connection per attached terminal.
pub const PORT_SHELL: u32 = 1027;

/// Guest-initiated dial-back targets on the host (the AI bridge): the guest connects to
/// `VMADDR_CID_HOST` on these ports and doryd forwards to `127.0.0.1:<same>`.
pub const HOST_PORTS_AI: &[u32] = &[11434, 1234, 18190];

/// A raw byte-stream port (its own forwarded connection, spliced) vs the muxed control port.
pub fn is_stream_port(port: u32) -> bool {
    port != PORT_CONTROL
}
