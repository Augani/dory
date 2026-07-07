//! `dory-sync` — the host-authoritative file-sync primitives shared by the host push driver
//! (`dory-remote`) and the agent apply handler (`dory-agent`). The host is the source of truth; the
//! remote is a replica. This crate holds the pure, transport-free logic: the [`Manifest`] model, the
//! reconciler [`plan`], the directory walk that builds a manifest, and the chunking constants.

mod hash;
mod manifest;
mod plan;

pub use hash::{hash_bytes, Hash, HASH_LEN};
pub use manifest::{walk_manifest, FileEntry, Manifest};
pub use plan::{plan, SyncPlan};

/// Chunk size for streamed file transfer. A create/build body is tiny; source trees are many small
/// files, so a modest chunk keeps memory flat and resumes at fine granularity while staying well
/// under the 16 MiB frame limit.
pub const CHUNK_BYTES: usize = 256 * 1024;
