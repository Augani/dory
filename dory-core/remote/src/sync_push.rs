//! Host-authoritative push: make a remote directory an exact replica of a local tree. The host is
//! the source of truth. The driver walks the local tree, asks the remote for its manifest, computes
//! the [`dory_sync::plan`], streams each changed file in resumable chunks (honoring the remote's
//! staged-bytes offset), and deletes files the host no longer has.
//!
//! The driver is generic over [`SyncTarget`] so its chunking/resume logic is unit-tested against a
//! fake, while [`crate::AgentClient`] is the production target over the real transport.

use std::io::SeekFrom;
use std::path::Path;

use dory_pb::agent::{
    SyncDeleteRequest, SyncDirectoryEntry, SyncFileStatusRequest, SyncManifestRequest,
    SyncPutChunkRequest, SyncTreeRequest,
};
use dory_sync::{
    plan, walk_tree, DirectoryEntry, Hash, Manifest, TreeSnapshot, CHUNK_BYTES, HASH_LEN,
};
use tokio::io::{AsyncReadExt, AsyncSeekExt};

use crate::agent_client::AgentClient;
use crate::error::RemoteError;

// A conflicting writer can atomically replace a destination after an identical peer consumed this
// transfer's shared staging file. Re-query/restart a bounded number of times rather than failing a
// benign race forever; the bound prevents an actively churning/hostile peer from causing a wedge.
const MAX_CONFLICT_RECOVERIES_PER_FILE: usize = 16;

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct PushStats {
    pub files_sent: u64,
    pub bytes_sent: u64,
    pub files_deleted: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushPhase {
    Preparing,
    Transferring,
    Finalizing,
    Completed,
    Cancelled,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushProgress {
    pub phase: PushPhase,
    pub files_total: u64,
    pub files_completed: u64,
    pub bytes_total: u64,
    pub bytes_completed: u64,
    pub current_path: Option<String>,
}

impl Default for PushProgress {
    fn default() -> Self {
        Self {
            phase: PushPhase::Preparing,
            files_total: 0,
            files_completed: 0,
            bytes_total: 0,
            bytes_completed: 0,
            current_path: None,
        }
    }
}

/// A control-plane observer for a push. Implementations must return quickly: callbacks execute on
/// the transfer task between bounded data-plane operations. Progress is absolute (not a delta), so
/// polling consumers can safely coalesce updates. Cancellation is cooperative and checked before
/// and after every remote mutation and every file chunk.
pub trait PushObserver: Send + Sync {
    fn update(&self, progress: &PushProgress);
    fn is_cancelled(&self) -> bool;
}

struct IgnorePushProgress;

impl PushObserver for IgnorePushProgress {
    fn update(&self, _progress: &PushProgress) {}

    fn is_cancelled(&self) -> bool {
        false
    }
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
    /// Apply one chunk; returns the remote's new staged offset and whether the full file is already
    /// committed. `committed` may be true before this caller sends its last chunk when an identical
    /// concurrent push won the race; the caller can then stop without re-sending the same bytes.
    fn put_chunk(
        &self,
        req: SyncPutChunkRequest,
    ) -> impl std::future::Future<Output = Result<(u64, bool), RemoteError>> + Send;
    fn delete(
        &self,
        root: &str,
        paths: &[String],
    ) -> impl std::future::Future<Output = Result<u32, RemoteError>> + Send;
    /// Reconcile complete directory topology. `Ok(false)` means the peer only implements the v1
    /// file protocol; callers may retain v1 behavior only when no empty directory would be lost.
    fn reconcile_tree(
        &self,
        root: &str,
        files: &[String],
        directories: &[DirectoryEntry],
        finalize: bool,
    ) -> impl std::future::Future<Output = Result<bool, RemoteError>> + Send;
}

pub async fn push<T: SyncTarget>(
    local_root: &Path,
    remote_root: &str,
    target: &T,
) -> Result<PushStats, RemoteError> {
    push_observed(local_root, remote_root, target, &IgnorePushProgress).await
}

pub async fn push_observed<T: SyncTarget, O: PushObserver>(
    local_root: &Path,
    remote_root: &str,
    target: &T,
    observer: &O,
) -> Result<PushStats, RemoteError> {
    let mut progress = PushProgress::default();
    observer.update(&progress);
    let result =
        push_observed_inner(local_root, remote_root, target, observer, &mut progress).await;
    if result.is_err() && progress.phase != PushPhase::Cancelled {
        progress.phase = PushPhase::Failed;
        progress.current_path = None;
        observer.update(&progress);
    }
    result
}

async fn push_observed_inner<T: SyncTarget, O: PushObserver>(
    local_root: &Path,
    remote_root: &str,
    target: &T,
    observer: &O,
    progress: &mut PushProgress,
) -> Result<PushStats, RemoteError> {
    require_not_cancelled(observer, progress)?;
    let root = local_root.to_path_buf();
    let local = tokio::task::spawn_blocking(move || walk_tree(&root))
        .await
        .map_err(|e| RemoteError::Io(std::io::Error::other(e)))??;
    require_not_cancelled(observer, progress)?;
    let remote = target.remote_manifest(remote_root).await?;
    require_not_cancelled(observer, progress)?;
    let plan = plan(&local.manifest, &remote);
    progress.files_total = u64::try_from(plan.transfer.len()).map_err(|_| RemoteError::Decode)?;
    progress.bytes_total = plan.transfer.iter().try_fold(0u64, |total, path| {
        let size = local.manifest.get(path).ok_or(RemoteError::Decode)?.size;
        total.checked_add(size).ok_or(RemoteError::Decode)
    })?;
    progress.phase = PushPhase::Transferring;
    observer.update(progress);
    let file_paths = local
        .manifest
        .entries
        .iter()
        .map(|entry| entry.path.clone())
        .collect::<Vec<_>>();
    let directory_protocol = target
        .reconcile_tree(remote_root, &file_paths, &local.directories, false)
        .await?;
    require_not_cancelled(observer, progress)?;
    if !directory_protocol && has_empty_directory(&local) {
        return Err(RemoteError::CapabilityUnavailable("sync-push@2"));
    }

    let mut stats = PushStats::default();
    let mut completed_file_bytes = 0u64;
    for rel in &plan.transfer {
        require_not_cancelled(observer, progress)?;
        let entry = local
            .manifest
            .get(rel)
            .expect("transfer paths are drawn from the local manifest");
        let mut file = tokio::fs::File::open(local_root.join(rel)).await?;

        // Resume: pick up where the remote left off, unless its staged size is past our file (stale).
        let staged = target.staged_bytes(remote_root, rel, &entry.hash).await?;
        let mut offset = if staged <= entry.size { staged } else { 0 };
        let mut conflict_recoveries = 0usize;
        progress.current_path = Some(rel.clone());
        progress.bytes_completed = completed_file_bytes + offset;
        observer.update(progress);

        loop {
            require_not_cancelled(observer, progress)?;
            file.seek(SeekFrom::Start(offset)).await?;
            let remaining = entry.size.checked_sub(offset).ok_or(RemoteError::Decode)?;
            let chunk_len = remaining.min(CHUNK_BYTES as u64) as usize;
            let mut chunk = vec![0u8; chunk_len];
            file.read_exact(&mut chunk).await?;
            let end = offset + chunk_len as u64;
            let last = end == entry.size;
            let sent = chunk.len() as u64;
            // The peer's returned next_offset is NOT trusted for indexing: a buggy/hostile agent
            // could return an out-of-bounds value and panic the slice below (panic=abort => doryd
            // dies). The host knows the true position; advance by what we sent.
            let outcome = target
                .put_chunk(SyncPutChunkRequest {
                    root: remote_root.to_string(),
                    path: rel.clone(),
                    hash: entry.hash.to_vec(),
                    offset,
                    data: chunk,
                    last,
                    mode: entry.mode,
                    mtime_ns: entry.mtime_ns,
                })
                .await;
            require_not_cancelled(observer, progress)?;
            let (next_offset, committed) = match outcome {
                Ok(outcome) => outcome,
                Err(RemoteError::Rpc { code: 409, .. })
                    if conflict_recoveries < MAX_CONFLICT_RECOVERIES_PER_FILE =>
                {
                    conflict_recoveries += 1;
                    let staged = target.staged_bytes(remote_root, rel, &entry.hash).await?;
                    offset = if staged <= entry.size { staged } else { 0 };
                    progress.bytes_completed = completed_file_bytes + offset;
                    observer.update(progress);
                    continue;
                }
                Err(error) => return Err(error),
            };
            stats.bytes_sent += sent;
            offset = end;
            progress.bytes_completed = completed_file_bytes + offset;
            observer.update(progress);
            // We never use the peer's offset as a local slice index. A committed response is the
            // one exception where it affects control flow, so require proof that the peer claims
            // the complete local length. The final request must likewise be acknowledged as a
            // complete commit; inconsistent responses are protocol decode failures, not success.
            if committed && next_offset != entry.size {
                return Err(RemoteError::Decode);
            }
            if last && !committed {
                return Err(RemoteError::Decode);
            }
            if last || committed {
                break;
            }
        }
        stats.files_sent += 1;
        completed_file_bytes = completed_file_bytes
            .checked_add(entry.size)
            .ok_or(RemoteError::Decode)?;
        progress.files_completed = stats.files_sent;
        progress.bytes_completed = completed_file_bytes;
        progress.current_path = None;
        observer.update(progress);
    }

    progress.phase = PushPhase::Finalizing;
    progress.current_path = None;
    observer.update(progress);
    require_not_cancelled(observer, progress)?;
    if directory_protocol {
        stats.files_deleted = plan.delete.len() as u64;
        let finalized = target
            .reconcile_tree(remote_root, &file_paths, &local.directories, true)
            .await?;
        require_not_cancelled(observer, progress)?;
        if !finalized {
            return Err(RemoteError::CapabilityUnavailable("sync-push@2"));
        }
    } else if !plan.delete.is_empty() {
        stats.files_deleted += target.delete(remote_root, &plan.delete).await? as u64;
        require_not_cancelled(observer, progress)?;
    }

    // The manifest is a point-in-time source authority. Re-read it after all remote mutations so a
    // concurrently changed, truncated, or appended source cannot be reported as an exact replica.
    // Retrying is safe: the protocol is content-addressed and resumable.
    let root = local_root.to_path_buf();
    let final_local = tokio::task::spawn_blocking(move || walk_tree(&root))
        .await
        .map_err(|e| RemoteError::Io(std::io::Error::other(e)))??;
    if final_local != local {
        return Err(RemoteError::SourceChanged);
    }
    require_not_cancelled(observer, progress)?;
    progress.phase = PushPhase::Completed;
    progress.files_completed = progress.files_total;
    progress.bytes_completed = progress.bytes_total;
    progress.current_path = None;
    observer.update(progress);
    Ok(stats)
}

fn require_not_cancelled<O: PushObserver>(
    observer: &O,
    progress: &mut PushProgress,
) -> Result<(), RemoteError> {
    if !observer.is_cancelled() {
        return Ok(());
    }
    progress.phase = PushPhase::Cancelled;
    progress.current_path = None;
    observer.update(progress);
    Err(RemoteError::Cancelled)
}

fn has_empty_directory(snapshot: &TreeSnapshot) -> bool {
    snapshot.directories.iter().any(|directory| {
        let prefix = format!("{}/", directory.path);
        !snapshot
            .manifest
            .entries
            .iter()
            .any(|file| file.path.starts_with(&prefix))
    })
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

    async fn put_chunk(&self, req: SyncPutChunkRequest) -> Result<(u64, bool), RemoteError> {
        let resp = self.sync_put_chunk(req).await?;
        Ok((resp.next_offset, resp.committed))
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

    async fn reconcile_tree(
        &self,
        root: &str,
        files: &[String],
        directories: &[DirectoryEntry],
        finalize: bool,
    ) -> Result<bool, RemoteError> {
        let info = self.info().await?;
        let supported = info
            .capabilities
            .iter()
            .any(|capability| capability.id == "sync-push" && capability.version >= 2);
        if !supported {
            return Ok(false);
        }
        AgentClient::sync_tree(
            self,
            SyncTreeRequest {
                root: root.to_string(),
                files: files.to_vec(),
                directories: directories
                    .iter()
                    .map(|directory| SyncDirectoryEntry {
                        path: directory.path.clone(),
                        mode: directory.mode,
                    })
                    .collect(),
                finalize,
            },
        )
        .await?;
        Ok(true)
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
        fn mkdir(&self, rel: &str) {
            std::fs::create_dir_all(self.root.join(rel)).unwrap();
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
        tree_calls: Vec<(Vec<String>, Vec<DirectoryEntry>, bool)>,
    }

    /// A fake remote that records everything, returns a preset manifest, and can pretend a file is
    /// partly staged (to exercise resume). Reassembles received chunks per path for assertions.
    struct FakeTarget {
        remote: Manifest,
        preset_staged: HashMap<String, u64>,
        /// If set, put_chunk returns this bogus next_offset — models a buggy/hostile agent.
        bogus_nonfinal_next_offset: Option<u64>,
        premature_commit_next_offset: Option<u64>,
        bogus_final_next_offset: Option<u64>,
        suppress_final_commit: bool,
        conflict_once_at_offset: Option<u64>,
        conflict_fired: Mutex<bool>,
        mutate_source_after_first_chunk: Option<(std::path::PathBuf, Vec<u8>)>,
        source_mutation_fired: Mutex<bool>,
        directory_protocol: bool,
        rec: Mutex<Recorded>,
    }
    impl FakeTarget {
        fn new(remote: Manifest) -> FakeTarget {
            FakeTarget {
                remote,
                preset_staged: HashMap::new(),
                bogus_nonfinal_next_offset: None,
                premature_commit_next_offset: None,
                bogus_final_next_offset: None,
                suppress_final_commit: false,
                conflict_once_at_offset: None,
                conflict_fired: Mutex::new(false),
                mutate_source_after_first_chunk: None,
                source_mutation_fired: Mutex::new(false),
                directory_protocol: true,
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
        async fn put_chunk(&self, req: SyncPutChunkRequest) -> Result<(u64, bool), RemoteError> {
            if let Some((path, replacement)) = &self.mutate_source_after_first_chunk {
                let mut fired = self.source_mutation_fired.lock().unwrap();
                if !*fired {
                    std::fs::write(path, replacement).unwrap();
                    *fired = true;
                }
            }
            if self.conflict_once_at_offset == Some(req.offset) {
                let mut fired = self.conflict_fired.lock().unwrap();
                if !*fired {
                    *fired = true;
                    return Err(RemoteError::Rpc {
                        code: 409,
                        message: "staging was consumed by a concurrent commit".into(),
                    });
                }
            }
            let honest = req.offset + req.data.len() as u64;
            let premature = !req.last && self.premature_commit_next_offset.is_some();
            let committed = (req.last && !self.suppress_final_commit) || premature;
            let next_offset = if req.last {
                self.bogus_final_next_offset.unwrap_or(honest)
            } else if premature {
                self.premature_commit_next_offset.unwrap()
            } else {
                self.bogus_nonfinal_next_offset.unwrap_or(honest)
            };
            self.rec.lock().unwrap().chunks.push(req);
            Ok((next_offset, committed))
        }
        async fn delete(&self, _root: &str, paths: &[String]) -> Result<u32, RemoteError> {
            self.rec.lock().unwrap().deleted.extend_from_slice(paths);
            Ok(paths.len() as u32)
        }
        async fn reconcile_tree(
            &self,
            _root: &str,
            files: &[String],
            directories: &[DirectoryEntry],
            finalize: bool,
        ) -> Result<bool, RemoteError> {
            if self.directory_protocol {
                self.rec.lock().unwrap().tree_calls.push((
                    files.to_vec(),
                    directories.to_vec(),
                    finalize,
                ));
            }
            Ok(self.directory_protocol)
        }
    }

    struct RecordingObserver {
        updates: Mutex<Vec<PushProgress>>,
        cancel_after_bytes: Option<u64>,
    }

    impl RecordingObserver {
        fn new(cancel_after_bytes: Option<u64>) -> Self {
            Self {
                updates: Mutex::new(Vec::new()),
                cancel_after_bytes,
            }
        }
    }

    impl PushObserver for RecordingObserver {
        fn update(&self, progress: &PushProgress) {
            self.updates.lock().unwrap().push(progress.clone());
        }

        fn is_cancelled(&self) -> bool {
            let Some(limit) = self.cancel_after_bytes else {
                return false;
            };
            self.updates
                .lock()
                .unwrap()
                .last()
                .is_some_and(|progress| progress.bytes_completed >= limit)
        }
    }

    #[tokio::test]
    async fn push_binds_empty_directories_in_prepare_and_finalize_passes() {
        let t = TempTree::new("empty-directories");
        t.mkdir("project/empty/deep");
        t.write("project/src/main.rs", b"fn main() {}");

        let target = FakeTarget::new(Manifest::default());
        let stats = push(&t.root, "/remote", &target).await.unwrap();
        assert_eq!(stats.files_sent, 1);
        let calls = &target.rec.lock().unwrap().tree_calls;
        assert_eq!(calls.len(), 2);
        assert!(!calls[0].2);
        assert!(calls[1].2);
        assert_eq!(calls[0].0, vec!["project/src/main.rs"]);
        assert_eq!(
            calls[0]
                .1
                .iter()
                .map(|entry| entry.path.as_str())
                .collect::<Vec<_>>(),
            vec![
                "project",
                "project/empty",
                "project/empty/deep",
                "project/src"
            ]
        );
        assert_eq!(calls[0].0, calls[1].0);
        assert_eq!(calls[0].1, calls[1].1);
    }

    #[tokio::test]
    async fn v1_peer_rejects_empty_directories_but_keeps_file_only_compatibility() {
        let with_empty = TempTree::new("v1-empty");
        with_empty.mkdir("empty");
        let mut target = FakeTarget::new(Manifest::default());
        target.directory_protocol = false;
        let error = push(&with_empty.root, "/remote", &target)
            .await
            .unwrap_err();
        assert!(matches!(
            error,
            RemoteError::CapabilityUnavailable("sync-push@2")
        ));

        let files_only = TempTree::new("v1-files");
        files_only.write("nested/file.txt", b"compatible");
        let stats = push(&files_only.root, "/remote", &target).await.unwrap();
        assert_eq!(stats.files_sent, 1);
        assert_eq!(target.assembled("nested/file.txt"), b"compatible");
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
                .all(|chunk| chunk.data.len() <= CHUNK_BYTES),
            "the push driver must never allocate a whole-file transport buffer"
        );
        assert!(
            rec.chunks
                .iter()
                .rfind(|c| c.path == "dir/b.bin")
                .unwrap()
                .last
        );
    }

    #[tokio::test]
    async fn observed_push_reports_absolute_bounded_progress() {
        let t = TempTree::new("progress");
        let big = vec![7u8; CHUNK_BYTES + 123];
        t.write("a.txt", b"hello");
        t.write("dir/b.bin", &big);

        let target = FakeTarget::new(Manifest::default());
        let observer = RecordingObserver::new(None);
        let stats = push_observed(&t.root, "/remote", &target, &observer)
            .await
            .unwrap();

        assert_eq!(stats.files_sent, 2);
        let updates = observer.updates.lock().unwrap();
        assert_eq!(updates.first().unwrap().phase, PushPhase::Preparing);
        assert_eq!(updates.last().unwrap().phase, PushPhase::Completed);
        assert_eq!(updates.last().unwrap().files_total, 2);
        assert_eq!(updates.last().unwrap().files_completed, 2);
        assert_eq!(updates.last().unwrap().bytes_total, (5 + big.len()) as u64);
        assert_eq!(
            updates.last().unwrap().bytes_completed,
            (5 + big.len()) as u64
        );
        assert!(updates.iter().all(|progress| {
            progress.files_completed <= progress.files_total
                && progress.bytes_completed <= progress.bytes_total
        }));
        assert!(updates.windows(2).all(|window| {
            window[0].files_completed <= window[1].files_completed
                && window[0].bytes_completed <= window[1].bytes_completed
        }));
        assert!(updates
            .iter()
            .any(|progress| progress.current_path.as_deref() == Some("dir/b.bin")));
    }

    #[tokio::test]
    async fn observed_push_cancels_between_chunks_before_finalization() {
        let t = TempTree::new("cancel");
        t.write("large.bin", &vec![3u8; CHUNK_BYTES * 2 + 1]);
        let target = FakeTarget::new(Manifest::default());
        let observer = RecordingObserver::new(Some(CHUNK_BYTES as u64));

        let error = push_observed(&t.root, "/remote", &target, &observer)
            .await
            .unwrap_err();

        assert!(matches!(error, RemoteError::Cancelled));
        assert_eq!(target.rec.lock().unwrap().chunks.len(), 1);
        let updates = observer.updates.lock().unwrap();
        let final_progress = updates.last().unwrap();
        assert_eq!(final_progress.phase, PushPhase::Cancelled);
        assert_eq!(final_progress.files_completed, 0);
        assert_eq!(final_progress.bytes_completed, CHUNK_BYTES as u64);
        assert_eq!(final_progress.bytes_total, (CHUNK_BYTES * 2 + 1) as u64);
    }

    #[tokio::test]
    async fn observed_push_reports_a_terminal_protocol_failure() {
        let t = TempTree::new("failed-progress");
        t.write("file", b"contents");
        let mut target = FakeTarget::new(Manifest::default());
        target.suppress_final_commit = true;
        let observer = RecordingObserver::new(None);

        let error = push_observed(&t.root, "/remote", &target, &observer)
            .await
            .unwrap_err();

        assert!(matches!(error, RemoteError::Decode));
        let updates = observer.updates.lock().unwrap();
        assert_eq!(updates.last().unwrap().phase, PushPhase::Failed);
        assert_eq!(updates.last().unwrap().current_path, None);
        assert_eq!(updates.last().unwrap().files_completed, 0);
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
        assert!(rec.deleted.is_empty(), "v2 topology pass owns deletion");
        assert_eq!(
            &rec.tree_calls[0].0,
            &["changed.txt".to_string(), "same.txt".to_string()]
        );
    }

    #[tokio::test]
    async fn push_does_not_trust_a_bogus_agent_next_offset() {
        let t = TempTree::new("bogus-offset");
        // Multi-chunk file so the loop iterates and would re-index with the bogus offset.
        t.write("f", &vec![3u8; CHUNK_BYTES + 50]);
        let mut target = FakeTarget::new(Manifest::default());
        target.bogus_nonfinal_next_offset = Some(u64::MAX); // a hostile/buggy agent

        // Must complete without panicking (panic=abort would kill doryd) and send the whole file.
        let stats = push(&t.root, "/remote", &target).await.unwrap();
        assert_eq!(stats.bytes_sent, (CHUNK_BYTES + 50) as u64);
        assert_eq!(target.assembled("f"), vec![3u8; CHUNK_BYTES + 50]);
    }

    #[tokio::test]
    async fn push_rejects_a_premature_or_size_inconsistent_commit() {
        let t = TempTree::new("premature-commit");
        t.write("f", &vec![3u8; CHUNK_BYTES + 50]);
        let mut target = FakeTarget::new(Manifest::default());
        target.premature_commit_next_offset = Some(1);
        let err = push(&t.root, "/remote", &target).await.unwrap_err();
        assert!(matches!(err, RemoteError::Decode));
        assert_eq!(target.rec.lock().unwrap().chunks.len(), 1);

        let t = TempTree::new("bad-final-offset");
        t.write("f", b"small");
        let mut target = FakeTarget::new(Manifest::default());
        target.bogus_final_next_offset = Some(4);
        let err = push(&t.root, "/remote", &target).await.unwrap_err();
        assert!(matches!(err, RemoteError::Decode));

        let t = TempTree::new("uncommitted-final");
        t.write("f", b"small");
        let mut target = FakeTarget::new(Manifest::default());
        target.suppress_final_commit = true;
        let err = push(&t.root, "/remote", &target).await.unwrap_err();
        assert!(matches!(err, RemoteError::Decode));
    }

    #[tokio::test]
    async fn push_stops_on_a_size_consistent_concurrent_commit() {
        let t = TempTree::new("concurrent-commit");
        let size = CHUNK_BYTES + 50;
        t.write("f", &vec![3u8; size]);
        let mut target = FakeTarget::new(Manifest::default());
        target.premature_commit_next_offset = Some(size as u64);

        let stats = push(&t.root, "/remote", &target).await.unwrap();
        assert_eq!(stats.files_sent, 1);
        assert_eq!(stats.bytes_sent, CHUNK_BYTES as u64);
        assert_eq!(target.rec.lock().unwrap().chunks.len(), 1);
    }

    #[tokio::test]
    async fn push_requeries_and_restarts_after_a_concurrent_staging_conflict() {
        let t = TempTree::new("recover-conflict");
        let data = vec![0x5A; CHUNK_BYTES + 50];
        t.write("f", &data);
        let mut target = FakeTarget::new(Manifest::default());
        target.conflict_once_at_offset = Some(CHUNK_BYTES as u64);

        let stats = push(&t.root, "/remote", &target).await.unwrap();
        assert_eq!(stats.files_sent, 1);
        assert!(*target.conflict_fired.lock().unwrap());
        assert_eq!(target.assembled("f"), data);
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

    #[tokio::test]
    async fn push_fails_closed_when_the_local_source_changes_mid_transfer() {
        let t = TempTree::new("source-drift");
        let original = vec![0x11; CHUNK_BYTES + 50];
        let replacement = vec![0x22; CHUNK_BYTES + 50];
        t.write("f", &original);

        let mut target = FakeTarget::new(Manifest::default());
        target.mutate_source_after_first_chunk = Some((t.root.join("f"), replacement));

        let error = push(&t.root, "/remote", &target).await.unwrap_err();
        assert!(matches!(error, RemoteError::SourceChanged));
        assert!(*target.source_mutation_fired.lock().unwrap());
    }
}
