//! Host-authoritative push: make a remote directory an exact replica of a local tree. The host is
//! the source of truth. The driver walks the local tree, asks the remote for its manifest, computes
//! the [`dory_sync::plan`], streams each changed file in resumable chunks (honoring the remote's
//! staged-bytes offset), and deletes files the host no longer has.
//!
//! The driver is generic over [`SyncTarget`] so its chunking/resume logic is unit-tested against a
//! fake, while [`crate::AgentClient`] is the production target over the real transport.

use std::path::Path;

use dory_pb::agent::{
    SyncDeleteRequest, SyncFileStatusRequest, SyncManifestRequest, SyncPutChunkRequest,
};
use dory_sync::{plan, walk_manifest, Hash, Manifest, CHUNK_BYTES, HASH_LEN};

use crate::agent_client::AgentClient;
use crate::error::RemoteError;

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct PushStats {
    pub files_sent: u64,
    pub bytes_sent: u64,
    pub files_deleted: u64,
}

/// The remote endpoint of a push. Modeled as a trait so the driver is testable without a transport.
/// Futures are `Send` so `doryd` can drive a push from a spawned task.
pub trait SyncTarget {
    fn remote_manifest(
        &self,
        root: &str,
    ) -> impl std::future::Future<Output = Result<Manifest, RemoteError>> + Send;
    /// Bytes already staged for `(path, hash)` from an interrupted push — the resume offset.
    fn staged_bytes(
        &self,
        root: &str,
        path: &str,
        hash: &Hash,
    ) -> impl std::future::Future<Output = Result<u64, RemoteError>> + Send;
    /// Apply one chunk; returns the remote's new staged offset.
    fn put_chunk(
        &self,
        req: SyncPutChunkRequest,
    ) -> impl std::future::Future<Output = Result<u64, RemoteError>> + Send;
    fn delete(
        &self,
        root: &str,
        paths: &[String],
    ) -> impl std::future::Future<Output = Result<u32, RemoteError>> + Send;
}

pub async fn push<T: SyncTarget>(
    local_root: &Path,
    remote_root: &str,
    target: &T,
) -> Result<PushStats, RemoteError> {
    let root = local_root.to_path_buf();
    let local = tokio::task::spawn_blocking(move || walk_manifest(&root))
        .await
        .map_err(|e| RemoteError::Io(std::io::Error::other(e)))??;
    let remote = target.remote_manifest(remote_root).await?;
    let plan = plan(&local, &remote);

    let mut stats = PushStats::default();
    for rel in &plan.transfer {
        let entry = local
            .get(rel)
            .expect("transfer paths are drawn from the local manifest");
        let bytes = tokio::fs::read(local_root.join(rel)).await?;

        // Resume: pick up where the remote left off, unless its staged size is past our file (stale).
        let staged = target.staged_bytes(remote_root, rel, &entry.hash).await?;
        let mut offset: usize = if staged <= bytes.len() as u64 {
            staged as usize
        } else {
            0
        };

        loop {
            let end = (offset as usize + CHUNK_BYTES).min(bytes.len());
            let chunk = bytes[offset..end].to_vec();
            let last = end == bytes.len();
            let sent = chunk.len() as u64;
            // The peer's returned next_offset is NOT trusted for indexing: a buggy/hostile agent
            // could return an out-of-bounds value and panic the slice below (panic=abort => doryd
            // dies). The host knows the true position; advance by what we sent.
            let _ = target
                .put_chunk(SyncPutChunkRequest {
                    root: remote_root.to_string(),
                    path: rel.clone(),
                    hash: entry.hash.to_vec(),
                    offset: offset as u64,
                    data: chunk,
                    last,
                    mode: entry.mode,
                    mtime_ns: entry.mtime_ns,
                })
                .await?;
            stats.bytes_sent += sent;
            offset = end;
            if last {
                break;
            }
        }
        stats.files_sent += 1;
    }

    if !plan.delete.is_empty() {
        stats.files_deleted += target.delete(remote_root, &plan.delete).await? as u64;
    }
    Ok(stats)
}

impl SyncTarget for AgentClient {
    async fn remote_manifest(&self, root: &str) -> Result<Manifest, RemoteError> {
        let resp = self
            .sync_manifest(SyncManifestRequest {
                root: root.to_string(),
            })
            .await?;
        let mut entries = Vec::with_capacity(resp.entries.len());
        for e in resp.entries {
            let hash: Hash = e
                .hash
                .as_slice()
                .try_into()
                .map_err(|_| RemoteError::Decode)?;
            entries.push(dory_sync::FileEntry {
                path: e.path,
                size: e.size,
                mtime_ns: e.mtime_ns,
                mode: e.mode,
                hash,
            });
        }
        Ok(Manifest { entries })
    }

    async fn staged_bytes(&self, root: &str, path: &str, hash: &Hash) -> Result<u64, RemoteError> {
        let resp = self
            .sync_file_status(SyncFileStatusRequest {
                root: root.to_string(),
                path: path.to_string(),
                hash: hash.to_vec(),
            })
            .await?;
        Ok(resp.have_bytes)
    }

    async fn put_chunk(&self, req: SyncPutChunkRequest) -> Result<u64, RemoteError> {
        Ok(self.sync_put_chunk(req).await?.next_offset)
    }

    async fn delete(&self, root: &str, paths: &[String]) -> Result<u32, RemoteError> {
        let resp = self
            .sync_delete(SyncDeleteRequest {
                root: root.to_string(),
                paths: paths.to_vec(),
            })
            .await?;
        Ok(resp.deleted)
    }
}

const _: () = assert!(HASH_LEN == 32);

#[cfg(test)]
mod tests {
    use super::*;
    use dory_sync::hash_bytes;
    use std::collections::HashMap;
    use std::sync::Mutex;

    struct TempTree {
        root: std::path::PathBuf,
    }
    impl TempTree {
        fn new(tag: &str) -> TempTree {
            let root =
                std::env::temp_dir().join(format!("dory-push-{}-{}", std::process::id(), tag));
            let _ = std::fs::remove_dir_all(&root);
            std::fs::create_dir_all(&root).unwrap();
            TempTree { root }
        }
        fn write(&self, rel: &str, contents: &[u8]) {
            let p = self.root.join(rel);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, contents).unwrap();
        }
    }
    impl Drop for TempTree {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    #[derive(Default)]
    struct Recorded {
        chunks: Vec<SyncPutChunkRequest>,
        deleted: Vec<String>,
    }

    /// A fake remote that records everything, returns a preset manifest, and can pretend a file is
    /// partly staged (to exercise resume). Reassembles received chunks per path for assertions.
    struct FakeTarget {
        remote: Manifest,
        preset_staged: HashMap<String, u64>,
        /// If set, put_chunk returns this bogus next_offset — models a buggy/hostile agent.
        bogus_next_offset: Option<u64>,
        rec: Mutex<Recorded>,
    }
    impl FakeTarget {
        fn new(remote: Manifest) -> FakeTarget {
            FakeTarget {
                remote,
                preset_staged: HashMap::new(),
                bogus_next_offset: None,
                rec: Mutex::new(Recorded::default()),
            }
        }
        fn assembled(&self, path: &str) -> Vec<u8> {
            let rec = self.rec.lock().unwrap();
            let mut out = Vec::new();
            for c in rec.chunks.iter().filter(|c| c.path == path) {
                if c.offset as usize > out.len() {
                    out.resize(c.offset as usize, 0);
                }
                out.truncate(c.offset as usize);
                out.extend_from_slice(&c.data);
            }
            out
        }
    }

    impl SyncTarget for FakeTarget {
        async fn remote_manifest(&self, _root: &str) -> Result<Manifest, RemoteError> {
            Ok(self.remote.clone())
        }
        async fn staged_bytes(
            &self,
            _root: &str,
            path: &str,
            _hash: &Hash,
        ) -> Result<u64, RemoteError> {
            Ok(self.preset_staged.get(path).copied().unwrap_or(0))
        }
        async fn put_chunk(&self, req: SyncPutChunkRequest) -> Result<u64, RemoteError> {
            let honest = req.offset + req.data.len() as u64;
            self.rec.lock().unwrap().chunks.push(req);
            Ok(self.bogus_next_offset.unwrap_or(honest))
        }
        async fn delete(&self, _root: &str, paths: &[String]) -> Result<u32, RemoteError> {
            self.rec.lock().unwrap().deleted.extend_from_slice(paths);
            Ok(paths.len() as u32)
        }
    }

    #[tokio::test]
    async fn push_sends_all_files_to_an_empty_remote_and_reassembles_intact() {
        let t = TempTree::new("empty-remote");
        let big = vec![7u8; CHUNK_BYTES + 123]; // spans >1 chunk
        t.write("a.txt", b"hello");
        t.write("dir/b.bin", &big);

        let target = FakeTarget::new(Manifest::default());
        let stats = push(&t.root, "/remote", &target).await.unwrap();

        assert_eq!(stats.files_sent, 2);
        assert_eq!(stats.bytes_sent, (5 + big.len()) as u64);
        assert_eq!(stats.files_deleted, 0);
        assert_eq!(target.assembled("a.txt"), b"hello");
        assert_eq!(target.assembled("dir/b.bin"), big);
        // The final chunk of each file is flagged `last`.
        let rec = target.rec.lock().unwrap();
        assert!(
            rec.chunks
                .iter()
                .rfind(|c| c.path == "dir/b.bin")
                .unwrap()
                .last
        );
    }

    #[tokio::test]
    async fn push_resumes_from_the_remote_staged_offset() {
        let t = TempTree::new("resume");
        let data = vec![9u8; 10];
        t.write("f", &data);

        let mut target = FakeTarget::new(Manifest::default());
        target.preset_staged.insert("f".to_string(), 4); // remote already has 4 bytes
        let stats = push(&t.root, "/remote", &target).await.unwrap();

        let rec = target.rec.lock().unwrap();
        let first = rec.chunks.iter().find(|c| c.path == "f").unwrap();
        assert_eq!(
            first.offset, 4,
            "resume must start at the staged offset, not 0"
        );
        // Only the remaining 6 bytes are sent.
        assert_eq!(stats.bytes_sent, 6);
    }

    #[tokio::test]
    async fn push_skips_unchanged_and_deletes_extras() {
        let t = TempTree::new("reconcile");
        t.write("same.txt", b"identical");
        t.write("changed.txt", b"new");

        // Remote already has same.txt (matching hash), changed.txt (different), and gone.txt (extra).
        let remote = Manifest {
            entries: vec![
                dory_sync::FileEntry {
                    path: "same.txt".into(),
                    size: 9,
                    mtime_ns: 0,
                    mode: 0o644,
                    hash: hash_bytes(b"identical"),
                },
                dory_sync::FileEntry {
                    path: "changed.txt".into(),
                    size: 3,
                    mtime_ns: 0,
                    mode: 0o644,
                    hash: hash_bytes(b"OLD"),
                },
                dory_sync::FileEntry {
                    path: "gone.txt".into(),
                    size: 1,
                    mtime_ns: 0,
                    mode: 0o644,
                    hash: hash_bytes(b"x"),
                },
            ],
        };
        let target = FakeTarget::new(remote);
        let stats = push(&t.root, "/remote", &target).await.unwrap();

        assert_eq!(stats.files_sent, 1, "only changed.txt is sent");
        assert_eq!(stats.files_deleted, 1);
        let rec = target.rec.lock().unwrap();
        assert!(
            rec.chunks.iter().all(|c| c.path == "changed.txt"),
            "same.txt must not be re-sent"
        );
        assert_eq!(rec.deleted, vec!["gone.txt".to_string()]);
    }

    #[tokio::test]
    async fn push_does_not_trust_a_bogus_agent_next_offset() {
        let t = TempTree::new("bogus-offset");
        // Multi-chunk file so the loop iterates and would re-index with the bogus offset.
        t.write("f", &vec![3u8; CHUNK_BYTES + 50]);
        let mut target = FakeTarget::new(Manifest::default());
        target.bogus_next_offset = Some(u64::MAX); // a hostile/buggy agent

        // Must complete without panicking (panic=abort would kill doryd) and send the whole file.
        let stats = push(&t.root, "/remote", &target).await.unwrap();
        assert_eq!(stats.bytes_sent, (CHUNK_BYTES + 50) as u64);
        assert_eq!(target.assembled("f"), vec![3u8; CHUNK_BYTES + 50]);
    }

    #[tokio::test]
    async fn push_commits_an_empty_file() {
        let t = TempTree::new("empty-file");
        t.write("empty", b"");
        let target = FakeTarget::new(Manifest::default());
        let stats = push(&t.root, "/remote", &target).await.unwrap();
        assert_eq!(stats.files_sent, 1);
        let rec = target.rec.lock().unwrap();
        let chunks: Vec<_> = rec.chunks.iter().filter(|c| c.path == "empty").collect();
        assert_eq!(chunks.len(), 1, "empty file is one last chunk");
        assert!(chunks[0].last && chunks[0].data.is_empty());
    }
}
