//! Agent-side apply for host-authoritative sync. The host is the source of truth; these handlers
//! stage incoming chunks under `<root>/.dory-sync-tmp/<hash>` and atomically rename into place on the
//! last chunk (so a reader never sees a half-written file), verifying the full content hash before
//! commit. Staging by hash makes an interrupted push resumable: `file_status` reports how many bytes
//! are already staged, and the host resumes from there. Paths are confined to `root` — a `..` or
//! absolute path is rejected, never followed.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use dory_pb::agent::{
    SyncDeleteRequest, SyncDeleteResponse, SyncFileEntry, SyncFileStatusRequest,
    SyncFileStatusResponse, SyncManifestRequest, SyncManifestResponse, SyncPutChunkRequest,
    SyncPutChunkResponse,
};

const STAGING_DIR: &str = ".dory-sync-tmp";
// Every sync RPC for one canonical root shares a stripe, so a manifest is a stable snapshot with
// respect to agent puts/deletes. Fixed stripes avoid an attacker growing a lock map without bound.
const ROOT_LOCK_STRIPES: usize = 64;
// A fixed stripe table bounds memory while serializing operations for the same destination path.
// The hash is deliberately NOT part of this key: conflicting-content commits must linearize around
// destination hash checks, chmod, and rename. Stripe collisions only reduce concurrency.
const PATH_LOCK_STRIPES: usize = 64;

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("path escapes the sync root")]
    PathEscape,
    #[error("chunk offset {got} does not match staged size {expected}")]
    OffsetMismatch { got: u64, expected: u64 },
    #[error("content hash mismatch on commit")]
    HashMismatch,
    #[error("chunk range overflows uint64")]
    ChunkRangeOverflow,
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

impl SyncError {
    /// The RPC error code surfaced to the host (kept distinct so the driver can react).
    pub fn code(&self) -> i32 {
        match self {
            SyncError::PathEscape => 403,
            SyncError::OffsetMismatch { .. } => 409,
            SyncError::HashMismatch => 422,
            SyncError::ChunkRangeOverflow => 400,
            SyncError::Io(_) => 500,
        }
    }
}

pub async fn manifest(req: SyncManifestRequest) -> Result<SyncManifestResponse, SyncError> {
    let root = canonical_root(&req.root).await?;
    let _root_guard = root_lock(&root).write().await;
    let manifest = tokio::task::spawn_blocking(move || {
        dory_sync::walk_manifest_excluding(&root, &[STAGING_DIR])
    })
    .await
    .map_err(|e| SyncError::Io(std::io::Error::other(e)))??;
    let entries = manifest
        .entries
        .into_iter()
        .map(|e| SyncFileEntry {
            path: e.path,
            size: e.size,
            mtime_ns: e.mtime_ns,
            mode: e.mode,
            hash: e.hash.to_vec(),
        })
        .collect();
    Ok(SyncManifestResponse { entries })
}

pub async fn file_status(req: SyncFileStatusRequest) -> Result<SyncFileStatusResponse, SyncError> {
    let root = canonical_root(&req.root).await?;
    let _root_guard = root_lock(&root).read().await;
    let _guard = path_lock(&root, &req.path).lock().await;
    // Reject a bad path even on status so the host gets a consistent error surface.
    safe_join(&root, &req.path).await?;
    let staging = safe_join(&root, &staging_rel(&req.path, &req.hash)).await?;
    let have_bytes = match tokio::fs::metadata(&staging).await {
        Ok(m) => m.len(),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => 0,
        Err(e) => return Err(SyncError::Io(e)),
    };
    Ok(SyncFileStatusResponse { have_bytes })
}

pub async fn put_chunk(req: SyncPutChunkRequest) -> Result<SyncPutChunkResponse, SyncError> {
    use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};

    let root = canonical_root(&req.root).await?;
    let _root_guard = root_lock(&root).read().await;
    let _guard = path_lock(&root, &req.path).lock().await;
    let dest = safe_join(&root, &req.path).await?;
    // Ensure the staging dir exists (as a real dir) before confining the staging path through it.
    tokio::fs::create_dir_all(root.join(STAGING_DIR)).await?;
    let staging = safe_join(&root, &staging_rel(&req.path, &req.hash)).await?;

    let chunk_end = req
        .offset
        .checked_add(req.data.len() as u64)
        .ok_or(SyncError::ChunkRangeOverflow)?;

    // A concurrent identical transfer may have committed and renamed the shared staging file after
    // this caller observed the old manifest. Verify the destination hash before acknowledging it;
    // the host sees `committed` and stops sending redundant chunks.
    let staged = match tokio::fs::metadata(&staging).await {
        Ok(m) => Some(m.len()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(SyncError::Io(e)),
    };
    if staged.is_none() {
        if let Some(size) = matching_destination_size(&dest, &req.hash).await? {
            // This may be a retry after rename succeeded but a directory fsync failed. Re-run every
            // durability barrier before converting the earlier error into committed success.
            apply_mode(&dest, req.mode).await?;
            sync_file(&dest).await?;
            let dest_parent = dest.parent().ok_or(SyncError::PathEscape)?;
            let staging_parent = staging.parent().ok_or(SyncError::PathEscape)?;
            for dir in directory_chain_to_sync(&root, dest_parent, staging_parent)? {
                sync_directory(&dir).await?;
            }
            return Ok(SyncPutChunkResponse {
                next_offset: size,
                committed: true,
            });
        }
    }
    let staging_exists = staged.is_some();
    let staged = staged.unwrap_or(0);

    // Mux handlers run concurrently. Two pushes of the same (root,path,hash) therefore can submit
    // the same chunk. Under the stripe lock, an already-written byte range is an idempotent retry
    // only when its bytes match exactly. This lets identical transfers safely interleave while an
    // interrupted single transfer still resumes at its reported staged offset.
    if req.offset > staged {
        return Err(SyncError::OffsetMismatch {
            got: req.offset,
            expected: staged,
        });
    }

    let overlap = (staged - req.offset).min(req.data.len() as u64) as usize;
    let mut overlap_matches = true;
    if overlap > 0 {
        let mut file = tokio::fs::File::open(&staging).await?;
        file.seek(std::io::SeekFrom::Start(req.offset)).await?;
        let mut existing = vec![0; overlap];
        file.read_exact(&mut existing).await?;
        overlap_matches = existing == req.data[..overlap];
    }

    // A mismatched prefix means the stage is poisoned (a SHA-256 collision or external mutation).
    // Offset zero retains the original explicit-restart behavior; a resumed nonzero chunk cannot
    // reconstruct the missing prefix, so remove it and make the next push restart from zero.
    let restart = !overlap_matches && req.offset == 0;
    if !overlap_matches && !restart {
        let _ = tokio::fs::remove_file(&staging).await;
        return Err(SyncError::OffsetMismatch {
            got: req.offset,
            expected: 0,
        });
    }

    let duplicate = staging_exists && overlap_matches && overlap == req.data.len();
    if duplicate && !req.last {
        return Ok(SyncPutChunkResponse {
            next_offset: staged,
            committed: false,
        });
    }

    if !duplicate {
        let write_offset = if restart {
            0
        } else {
            req.offset + overlap as u64
        };
        let write_data = if restart {
            req.data.as_slice()
        } else {
            &req.data[overlap..]
        };
        let mut file = tokio::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(restart || (!staging_exists && req.offset == 0))
            .open(&staging)
            .await?;
        file.seek(std::io::SeekFrom::Start(write_offset)).await?;
        file.write_all(write_data).await?;
        // Do not acknowledge a staged offset until Tokio's blocking file operation is complete and
        // visible to a following RPC. Final sync_all + hash verification is the durability and
        // integrity boundary; forcing sync_data for every 256 KiB chunk would destroy throughput.
        file.flush().await?;
    } else if req.last && staged > chunk_end {
        // file_status cannot know the desired total length. If it reported an oversized stale stage,
        // the last request finally reveals that length; the byte-verified prefix is safe to trim.
        let file = tokio::fs::OpenOptions::new()
            .write(true)
            .open(&staging)
            .await?;
        file.set_len(chunk_end).await?;
    }
    let next_offset = chunk_end;

    if !req.last {
        return Ok(SyncPutChunkResponse {
            next_offset,
            committed: false,
        });
    }

    // Commit. Do the setup (parent dirs, mode) FIRST, then verify the full content hash and rename
    // immediately with no await in between — minimizing any window in which the staged file could be
    // mutated between the hash check and the atomic publish.
    let dest_parent = dest.parent().ok_or(SyncError::PathEscape)?;
    let mut new_dirs = missing_directory_chain(&root, dest_parent).await?;
    tokio::fs::create_dir_all(dest_parent).await?;
    apply_mode(&staging, req.mode).await?;
    // Persist both the data and chmod metadata on the same staged inode before publishing it.
    sync_file(&staging).await?;
    let (actual_hash, _) = hash_file(&staging).await?;
    if actual_hash.as_slice() != req.hash.as_slice() {
        let _ = tokio::fs::remove_file(&staging).await; // never leave poisoned staging around
        return Err(SyncError::HashMismatch);
    }
    // Retry once on ENOENT: a concurrent delete's prune_empty_parents can race the dest parent away.
    if let Err(e) = tokio::fs::rename(&staging, &dest).await {
        if e.kind() == std::io::ErrorKind::NotFound {
            new_dirs.extend(missing_directory_chain(&root, dest_parent).await?);
            tokio::fs::create_dir_all(dest_parent).await?;
            tokio::fs::rename(&staging, &dest).await?;
        } else {
            return Err(SyncError::Io(e));
        }
    }
    // rename durability requires both directory entries: the new destination name and removal of
    // the private staging name. If create_dir_all made a hierarchy, fsync each parent link up to the
    // canonical root as well. ACK only after all of these barriers succeed.
    let staging_parent = staging.parent().ok_or(SyncError::PathEscape)?;
    for dir in commit_directories_to_sync(&root, dest_parent, staging_parent, &new_dirs) {
        sync_directory(&dir).await?;
    }
    Ok(SyncPutChunkResponse {
        next_offset,
        committed: true,
    })
}

pub async fn delete(req: SyncDeleteRequest) -> Result<SyncDeleteResponse, SyncError> {
    let root = canonical_root(&req.root).await?;
    let _root_guard = root_lock(&root).write().await;
    let mut deleted = 0u32;
    let mut affected_parents = std::collections::HashSet::new();
    let mut mutation_error = None;
    for rel in &req.paths {
        let path = match safe_join(&root, rel).await {
            Ok(path) => path,
            Err(error) => {
                mutation_error = Some(error);
                break;
            }
        };
        if let Some(parent) = path.parent() {
            // Include NotFound paths too: this may be an RPC retry after the previous removal was
            // visible but its parent fsync failed.
            affected_parents.insert(parent.to_path_buf());
        }
        match tokio::fs::remove_file(&path).await {
            Ok(()) => {
                deleted += 1;
                if let Err(error) = prune_empty_parents(&root, &path).await {
                    mutation_error = Some(error);
                    break;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                mutation_error = Some(SyncError::Io(e));
                break;
            }
        }
    }
    // Persist every successful removal even if a later path failed. Otherwise a retry could see the
    // earlier files as absent, skip them, ACK, and still let them resurrect after a guest crash.
    sync_delete_directories(&root, &affected_parents).await?;
    if let Some(error) = mutation_error {
        return Err(error);
    }
    Ok(SyncDeleteResponse { deleted })
}

#[cfg(unix)]
async fn apply_mode(path: &Path, mode: u32) -> Result<(), SyncError> {
    if mode == 0 {
        return Ok(());
    }
    use std::os::unix::fs::PermissionsExt;
    let perms = std::fs::Permissions::from_mode(mode & 0o7777);
    tokio::fs::set_permissions(path, perms).await?;
    Ok(())
}

#[cfg(not(unix))]
async fn apply_mode(_path: &Path, _mode: u32) -> Result<(), SyncError> {
    Ok(())
}

/// Remove now-empty directories from `path`'s parent up toward (but not including) `root`.
async fn prune_empty_parents(root: &Path, path: &Path) -> Result<(), SyncError> {
    let mut dir = path.parent().map(Path::to_path_buf);
    while let Some(d) = dir {
        if d == root || !d.starts_with(root) {
            break;
        }
        // remove_dir only succeeds on an empty dir — exactly the prune condition.
        match tokio::fs::remove_dir(&d).await {
            Ok(()) => {}
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::DirectoryNotEmpty | std::io::ErrorKind::NotFound
                ) =>
            {
                break;
            }
            Err(e) => return Err(SyncError::Io(e)),
        }
        dir = d.parent().map(Path::to_path_buf);
    }
    Ok(())
}

async fn canonical_root(root: &str) -> Result<PathBuf, SyncError> {
    // Canonicalization makes textual aliases such as `/tmp/x` and `/private/tmp/x` select the same
    // lock stripe and staging path. The sync root must already exist: manifest() has to walk it
    // before a push can reach file_status/put_chunk.
    Ok(tokio::fs::canonicalize(PathBuf::from(root)).await?)
}

fn root_lock(root: &Path) -> &'static tokio::sync::RwLock<()> {
    static LOCKS: OnceLock<Box<[tokio::sync::RwLock<()>]>> = OnceLock::new();
    let locks = LOCKS.get_or_init(|| {
        (0..ROOT_LOCK_STRIPES)
            .map(|_| tokio::sync::RwLock::new(()))
            .collect::<Vec<_>>()
            .into_boxed_slice()
    });
    let digest = dory_sync::hash_bytes(root.to_string_lossy().as_bytes());
    let stripe = u64::from_le_bytes(digest[..8].try_into().expect("sha256 is 32 bytes")) as usize
        % locks.len();
    &locks[stripe]
}

fn path_lock(root: &Path, path: &str) -> &'static tokio::sync::Mutex<()> {
    static LOCKS: OnceLock<Box<[tokio::sync::Mutex<()>]>> = OnceLock::new();
    let locks = LOCKS.get_or_init(|| {
        (0..PATH_LOCK_STRIPES)
            .map(|_| tokio::sync::Mutex::new(()))
            .collect::<Vec<_>>()
            .into_boxed_slice()
    });

    let mut key = Vec::with_capacity(root.as_os_str().len() + path.len() + 1);
    key.extend_from_slice(root.to_string_lossy().as_bytes());
    key.push(0);
    key.extend_from_slice(path.as_bytes());
    let digest = dory_sync::hash_bytes(&key);
    let stripe = u64::from_le_bytes(digest[..8].try_into().expect("sha256 is 32 bytes")) as usize
        % locks.len();
    &locks[stripe]
}

async fn matching_destination_size(
    dest: &Path,
    expected_hash: &[u8],
) -> Result<Option<u64>, SyncError> {
    let meta = match tokio::fs::metadata(dest).await {
        Ok(meta) => meta,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(SyncError::Io(e)),
    };
    if !meta.is_file() {
        return Ok(None);
    }
    let (actual_hash, size) = hash_file(dest).await?;
    Ok((actual_hash.as_slice() == expected_hash).then_some(size))
}

async fn hash_file(path: &Path) -> Result<(dory_sync::Hash, u64), SyncError> {
    use sha2::{Digest, Sha256};
    use tokio::io::AsyncReadExt;

    let mut file = tokio::fs::File::open(path).await?;
    let mut hasher = Sha256::new();
    let mut size = 0u64;
    let mut buffer = vec![0u8; dory_sync::CHUNK_BYTES];
    loop {
        let read = file.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        size = size
            .checked_add(read as u64)
            .ok_or(SyncError::ChunkRangeOverflow)?;
    }
    Ok((hasher.finalize().into(), size))
}

async fn missing_directory_chain(root: &Path, parent: &Path) -> Result<Vec<PathBuf>, SyncError> {
    if !parent.starts_with(root) {
        return Err(SyncError::PathEscape);
    }
    let mut missing = Vec::new();
    let mut cursor = parent.to_path_buf();
    while cursor != root {
        match tokio::fs::symlink_metadata(&cursor).await {
            Ok(meta) if meta.file_type().is_symlink() => return Err(SyncError::PathEscape),
            Ok(meta) if meta.is_dir() => break,
            Ok(_) => {
                return Err(SyncError::Io(std::io::Error::from(
                    std::io::ErrorKind::NotADirectory,
                )))
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => missing.push(cursor.clone()),
            Err(e) => return Err(SyncError::Io(e)),
        }
        cursor = cursor.parent().ok_or(SyncError::PathEscape)?.to_path_buf();
    }
    Ok(missing)
}

fn commit_directories_to_sync(
    root: &Path,
    dest_parent: &Path,
    staging_parent: &Path,
    new_dirs: &[PathBuf],
) -> Vec<PathBuf> {
    // Leaf-to-root order: persist the destination entry, then every newly created directory entry
    // in its parent. The staging directory is included to persist removal of the old rename source.
    let mut dirs = vec![dest_parent.to_path_buf()];
    dirs.extend(
        new_dirs
            .iter()
            .filter_map(|dir| dir.parent().map(Path::to_path_buf)),
    );
    dirs.push(staging_parent.to_path_buf());
    dirs.retain(|dir| dir.starts_with(root));
    let mut unique = Vec::with_capacity(dirs.len());
    for dir in dirs {
        if !unique.contains(&dir) {
            unique.push(dir);
        }
    }
    unique
}

fn directory_chain_to_sync(
    root: &Path,
    dest_parent: &Path,
    staging_parent: &Path,
) -> Result<Vec<PathBuf>, SyncError> {
    if !dest_parent.starts_with(root) || !staging_parent.starts_with(root) {
        return Err(SyncError::PathEscape);
    }
    let mut dirs = Vec::new();
    let mut cursor = dest_parent.to_path_buf();
    loop {
        if !dirs.contains(&cursor) {
            dirs.push(cursor.clone());
        }
        if cursor == root {
            break;
        }
        cursor = cursor.parent().ok_or(SyncError::PathEscape)?.to_path_buf();
    }
    if !dirs.iter().any(|dir| dir == staging_parent) {
        dirs.push(staging_parent.to_path_buf());
    }
    Ok(dirs)
}

async fn sync_file(path: &Path) -> Result<(), SyncError> {
    tokio::fs::OpenOptions::new()
        .read(true)
        .open(path)
        .await?
        .sync_all()
        .await?;
    Ok(())
}

async fn sync_directory(path: &Path) -> Result<(), SyncError> {
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || std::fs::File::open(path)?.sync_all())
        .await
        .map_err(|e| SyncError::Io(std::io::Error::other(e)))??;
    Ok(())
}

async fn sync_delete_directories(
    root: &Path,
    affected: &std::collections::HashSet<PathBuf>,
) -> Result<(), SyncError> {
    let mut dirs = std::collections::HashSet::new();
    for original in affected {
        let dir = nearest_existing_directory(root, original).await?;
        dirs.insert(dir);
    }
    for dir in dirs {
        sync_directory(&dir).await?;
    }
    Ok(())
}

async fn nearest_existing_directory(root: &Path, start: &Path) -> Result<PathBuf, SyncError> {
    if !start.starts_with(root) {
        return Err(SyncError::PathEscape);
    }
    let mut cursor = start.to_path_buf();
    loop {
        match tokio::fs::symlink_metadata(&cursor).await {
            Ok(meta) if meta.file_type().is_symlink() => return Err(SyncError::PathEscape),
            Ok(meta) if meta.is_dir() => return Ok(cursor),
            Ok(_) => {
                return Err(SyncError::Io(std::io::Error::from(
                    std::io::ErrorKind::NotADirectory,
                )))
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound && cursor != root => {
                cursor = cursor.parent().ok_or(SyncError::PathEscape)?.to_path_buf();
            }
            Err(e) => return Err(SyncError::Io(e)),
        }
    }
}

/// Join `rel` (a forward-slash relpath) onto `root` and confine it there. Lexical checks reject
/// `..`/absolute/empty/`.`; then EACH existing component is `lstat`ed and a symlink is refused —
/// `rename`/`remove_file`/`create_dir_all` follow symlinks in non-final components, so a symlinked
/// directory would otherwise redirect a write or delete outside the root. (walk_manifest skips
/// symlinks, so a legitimately synced tree never contains one; a pre-planted symlink is an escape
/// primitive.) There is a benign TOCTOU against a local attacker who can mutate the tree concurrently
/// — out of scope, since such an attacker already has filesystem access on the remote.
async fn safe_join(root: &Path, rel: &str) -> Result<PathBuf, SyncError> {
    if rel.is_empty() || rel.starts_with('/') {
        return Err(SyncError::PathEscape);
    }
    let mut out = root.to_path_buf();
    for part in rel.split('/') {
        if part.is_empty() || part == "." || part == ".." {
            return Err(SyncError::PathEscape);
        }
        out.push(part);
        if let Ok(meta) = tokio::fs::symlink_metadata(&out).await {
            if meta.file_type().is_symlink() {
                return Err(SyncError::PathEscape);
            }
        }
    }
    Ok(out)
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// Staging rel-path for `(path, hash)`, under the staging dir. Keyed by BOTH so two destinations that
/// happen to share content (same hash) never collide in one staging file — otherwise a concurrent
/// push of one could truncate the other's staged bytes and publish a torn file. `file_status`
/// receives the same `(path, hash)`, so resume keys identically.
fn staging_rel(path: &str, hash: &[u8]) -> String {
    format!(
        "{STAGING_DIR}/{}.{}",
        hex(&dory_sync::hash_bytes(path.as_bytes())),
        hex(hash)
    )
}

/// The staging path as a plain join (no confinement I/O) — for tests asserting existence.
#[cfg(test)]
fn staging_path(root: &Path, path: &str, hash: &[u8]) -> PathBuf {
    root.join(staging_rel(path, hash))
}

#[cfg(test)]
mod tests {
    use super::*;
    use dory_sync::hash_bytes;
    use std::fs;

    struct TempRoot {
        path: PathBuf,
    }
    impl TempRoot {
        fn new(tag: &str) -> TempRoot {
            let path =
                std::env::temp_dir().join(format!("dory-apply-{}-{}", std::process::id(), tag));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).unwrap();
            TempRoot { path }
        }
        fn root(&self) -> String {
            self.path.to_string_lossy().into_owned()
        }
    }
    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    #[tokio::test]
    async fn single_chunk_commits_atomically_with_content() {
        let t = TempRoot::new("single");
        let data = b"hello sync".to_vec();
        let hash = hash_bytes(&data).to_vec();
        let resp = put_chunk(SyncPutChunkRequest {
            root: t.root(),
            path: "dir/file.txt".into(),
            hash: hash.clone(),
            offset: 0,
            data: data.clone(),
            last: true,
            mode: 0o600,
            mtime_ns: 0,
        })
        .await
        .unwrap();
        assert!(resp.committed);
        assert_eq!(resp.next_offset, data.len() as u64);
        assert_eq!(fs::read(t.path.join("dir/file.txt")).unwrap(), data);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(t.path.join("dir/file.txt"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        // Staging cleaned up after commit.
        assert!(!staging_path(&t.path, "dir/file.txt", &hash).exists());
    }

    #[test]
    fn durability_directory_plan_covers_both_rename_entries_and_new_parent_links() {
        let root = Path::new("/root");
        let dest_parent = Path::new("/root/a/b");
        let staging_parent = Path::new("/root/.dory-sync-tmp");
        let new_dirs = vec![PathBuf::from("/root/a/b"), PathBuf::from("/root/a")];
        assert_eq!(
            commit_directories_to_sync(root, dest_parent, staging_parent, &new_dirs),
            vec![
                PathBuf::from("/root/a/b"),
                PathBuf::from("/root/a"),
                PathBuf::from("/root"),
                PathBuf::from("/root/.dory-sync-tmp"),
            ]
        );
        assert_eq!(
            directory_chain_to_sync(root, dest_parent, staging_parent).unwrap(),
            vec![
                PathBuf::from("/root/a/b"),
                PathBuf::from("/root/a"),
                PathBuf::from("/root"),
                PathBuf::from("/root/.dory-sync-tmp"),
            ]
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn read_only_mode_is_synced_on_commit_and_matched_destination_retry() {
        use std::os::unix::fs::PermissionsExt;

        let t = TempRoot::new("read-only-durable");
        let data = b"immutable source".to_vec();
        let hash = hash_bytes(&data).to_vec();
        let request = |offset: u64, bytes: Vec<u8>, last: bool| SyncPutChunkRequest {
            root: t.root(),
            path: "readonly.txt".into(),
            hash: hash.clone(),
            offset,
            data: bytes,
            last,
            mode: 0o444,
            mtime_ns: 0,
        };

        let committed = put_chunk(request(0, data.clone(), true)).await.unwrap();
        assert!(committed.committed);
        assert_eq!(
            fs::metadata(t.path.join("readonly.txt"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o444
        );

        // Staging is gone, so this exercises the matched-destination durability retry path.
        let retry = put_chunk(request(1, data[1..2].to_vec(), false))
            .await
            .unwrap();
        assert!(retry.committed);
        assert_eq!(retry.next_offset, data.len() as u64);
    }

    #[tokio::test]
    async fn interrupted_transfer_resumes_from_reported_offset() {
        let t = TempRoot::new("resume");
        let data = b"0123456789abcdef".to_vec();
        let hash = hash_bytes(&data).to_vec();

        // First half, not last.
        let r1 = put_chunk(SyncPutChunkRequest {
            root: t.root(),
            path: "big.bin".into(),
            hash: hash.clone(),
            offset: 0,
            data: data[..8].to_vec(),
            last: false,
            mode: 0o644,
            mtime_ns: 0,
        })
        .await
        .unwrap();
        assert_eq!(r1.next_offset, 8);
        assert!(!r1.committed);
        assert!(
            !t.path.join("big.bin").exists(),
            "not committed mid-transfer"
        );

        // A reconnect: status reports the resume offset.
        let status = file_status(SyncFileStatusRequest {
            root: t.root(),
            path: "big.bin".into(),
            hash: hash.clone(),
        })
        .await
        .unwrap();
        assert_eq!(status.have_bytes, 8);

        // Second half from the reported offset, last.
        let r2 = put_chunk(SyncPutChunkRequest {
            root: t.root(),
            path: "big.bin".into(),
            hash: hash.clone(),
            offset: 8,
            data: data[8..].to_vec(),
            last: true,
            mode: 0o644,
            mtime_ns: 0,
        })
        .await
        .unwrap();
        assert!(r2.committed);
        assert_eq!(fs::read(t.path.join("big.bin")).unwrap(), data);
    }

    #[tokio::test]
    async fn delayed_duplicate_chunks_are_idempotent_and_do_not_rewind_staging() {
        let t = TempRoot::new("duplicate-chunks");
        let data = b"0123456789abcdefghijklmn".to_vec();
        let hash = hash_bytes(&data).to_vec();
        let chunk = |offset: u64, bytes: &[u8], last: bool| SyncPutChunkRequest {
            root: t.root(),
            path: "big.bin".into(),
            hash: hash.clone(),
            offset,
            data: bytes.to_vec(),
            last,
            mode: 0o644,
            mtime_ns: 0,
        };

        put_chunk(chunk(0, &data[..8], false)).await.unwrap();
        put_chunk(chunk(8, &data[8..16], false)).await.unwrap();

        // A slower identical push can deliver its first chunk after the winner is already ahead.
        // This must ACK the matching range, never O_TRUNC the 16 bytes already staged.
        let duplicate = put_chunk(chunk(0, &data[..8], false)).await.unwrap();
        assert_eq!(duplicate.next_offset, 16);
        assert!(!duplicate.committed);
        assert_eq!(
            tokio::fs::metadata(staging_path(&t.path, "big.bin", &hash))
                .await
                .unwrap()
                .len(),
            16
        );

        put_chunk(chunk(16, &data[16..], true)).await.unwrap();
        assert_eq!(fs::read(t.path.join("big.bin")).unwrap(), data);
    }

    #[tokio::test]
    async fn offset_zero_recovers_oversized_or_poisoned_staging() {
        for (tag, staged_contents) in [
            ("oversized", b"desired bytes plus stale tail".as_slice()),
            ("poisoned", b"WRONGED bytes".as_slice()),
        ] {
            let t = TempRoot::new(tag);
            let data = b"desired bytes".to_vec();
            let hash = hash_bytes(&data).to_vec();
            fs::create_dir_all(t.path.join(STAGING_DIR)).unwrap();
            fs::write(staging_path(&t.path, "f", &hash), staged_contents).unwrap();

            let response = put_chunk(SyncPutChunkRequest {
                root: t.root(),
                path: "f".into(),
                hash: hash.clone(),
                offset: 0,
                data: data.clone(),
                last: true,
                mode: 0o644,
                mtime_ns: 0,
            })
            .await
            .unwrap();
            assert!(response.committed, "{tag}");
            assert_eq!(fs::read(t.path.join("f")).unwrap(), data, "{tag}");
            assert!(!staging_path(&t.path, "f", &hash).exists(), "{tag}");
        }
    }

    #[tokio::test]
    async fn stale_chunk_after_an_identical_commit_is_acknowledged_without_recreating_staging() {
        let t = TempRoot::new("already-committed");
        let data = b"already complete".to_vec();
        let hash = hash_bytes(&data).to_vec();
        let request = |offset: u64, bytes: &[u8], last: bool| SyncPutChunkRequest {
            root: t.root(),
            path: "f".into(),
            hash: hash.clone(),
            offset,
            data: bytes.to_vec(),
            last,
            mode: 0o644,
            mtime_ns: 0,
        };

        put_chunk(request(0, &data, true)).await.unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(t.path.join("f"), std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        let stale = put_chunk(request(4, &data[4..8], false)).await.unwrap();
        assert!(stale.committed);
        assert_eq!(stale.next_offset, data.len() as u64);
        assert!(!staging_path(&t.path, "f", &hash).exists());
        assert_eq!(fs::read(t.path.join("f")).unwrap(), data);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(t.path.join("f")).unwrap().permissions().mode() & 0o777,
                0o644,
                "matched-destination ACK reapplies and persists requested metadata"
            );
        }
    }

    #[tokio::test]
    async fn file_status_surfaces_non_not_found_metadata_errors() {
        let t = TempRoot::new("status-io-error");
        // A regular file where the private staging directory must be makes metadata(<file>/<key>)
        // fail with ENOTDIR. It must not be misreported as an empty resumable stage.
        fs::write(t.path.join(STAGING_DIR), b"not a directory").unwrap();
        let err = file_status(SyncFileStatusRequest {
            root: t.root(),
            path: "f".into(),
            hash: hash_bytes(b"x").to_vec(),
        })
        .await
        .unwrap_err();
        assert!(matches!(err, SyncError::Io(_)), "got {err:?}");
    }

    #[tokio::test]
    async fn overflowing_chunk_range_is_rejected_without_a_panic() {
        let t = TempRoot::new("range-overflow");
        let err = put_chunk(SyncPutChunkRequest {
            root: t.root(),
            path: "f".into(),
            hash: hash_bytes(b"x").to_vec(),
            offset: u64::MAX,
            data: b"x".to_vec(),
            last: true,
            mode: 0o644,
            mtime_ns: 0,
        })
        .await
        .unwrap_err();
        assert!(matches!(err, SyncError::ChunkRangeOverflow));
    }

    #[tokio::test]
    async fn wrong_offset_is_rejected() {
        let t = TempRoot::new("offset");
        let hash = hash_bytes(b"x").to_vec();
        let err = put_chunk(SyncPutChunkRequest {
            root: t.root(),
            path: "f".into(),
            hash,
            offset: 99, // nothing staged yet, expected 0
            data: b"x".to_vec(),
            last: true,
            mode: 0o644,
            mtime_ns: 0,
        })
        .await
        .unwrap_err();
        assert!(matches!(
            err,
            SyncError::OffsetMismatch {
                got: 99,
                expected: 0
            }
        ));
    }

    #[tokio::test]
    async fn hash_mismatch_on_commit_does_not_publish_the_file() {
        let t = TempRoot::new("badhash");
        // Declare a hash that does not match the data.
        let declared = hash_bytes(b"the truth").to_vec();
        let err = put_chunk(SyncPutChunkRequest {
            root: t.root(),
            path: "f".into(),
            hash: declared.clone(),
            offset: 0,
            data: b"a lie".to_vec(),
            last: true,
            mode: 0o644,
            mtime_ns: 0,
        })
        .await
        .unwrap_err();
        assert!(matches!(err, SyncError::HashMismatch));
        assert!(
            !t.path.join("f").exists(),
            "a corrupt file must never be published"
        );
        assert!(
            !staging_path(&t.path, "f", &declared).exists(),
            "poisoned staging removed"
        );
    }

    #[tokio::test]
    async fn path_escape_is_rejected() {
        let t = TempRoot::new("escape");
        for bad in ["../evil", "/etc/passwd", "a/../../b", "", "a/./b"] {
            let err = put_chunk(SyncPutChunkRequest {
                root: t.root(),
                path: bad.into(),
                hash: hash_bytes(b"x").to_vec(),
                offset: 0,
                data: b"x".to_vec(),
                last: true,
                mode: 0o644,
                mtime_ns: 0,
            })
            .await;
            assert!(
                matches!(err, Err(SyncError::PathEscape)),
                "{bad:?} must be rejected"
            );
        }
    }

    /// A pre-existing symlinked directory component must NOT let a write escape the sync root.
    /// (walk_manifest skips symlinks, so a legit tree never contains one the host put there, but a
    /// pre-planted one is an escape primitive — the critical finding.)
    #[cfg(unix)]
    #[tokio::test]
    async fn symlinked_component_cannot_redirect_a_write_outside_root() {
        let t = TempRoot::new("symlink-write");
        let outside = TempRoot::new("symlink-write-outside");
        // <root>/link -> <outside>
        std::os::unix::fs::symlink(&outside.path, t.path.join("link")).unwrap();

        let data = b"pwned".to_vec();
        let err = put_chunk(SyncPutChunkRequest {
            root: t.root(),
            path: "link/evil.txt".into(),
            hash: hash_bytes(&data).to_vec(),
            offset: 0,
            data,
            last: true,
            mode: 0o600,
            mtime_ns: 0,
        })
        .await;
        assert!(
            matches!(err, Err(SyncError::PathEscape)),
            "write through a symlink must be rejected"
        );
        assert!(
            !outside.path.join("evil.txt").exists(),
            "nothing may be written outside the root"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn symlinked_component_cannot_redirect_a_delete_outside_root() {
        let t = TempRoot::new("symlink-del");
        let outside = TempRoot::new("symlink-del-outside");
        fs::write(outside.path.join("victim.txt"), "precious").unwrap();
        std::os::unix::fs::symlink(&outside.path, t.path.join("link")).unwrap();

        let err = delete(SyncDeleteRequest {
            root: t.root(),
            paths: vec!["link/victim.txt".into()],
        })
        .await;
        assert!(
            matches!(err, Err(SyncError::PathEscape)),
            "delete through a symlink must be rejected"
        );
        assert!(
            outside.path.join("victim.txt").exists(),
            "a file outside the root must survive"
        );
    }

    #[tokio::test]
    async fn delete_removes_files_and_prunes_empty_dirs() {
        let t = TempRoot::new("delete");
        fs::create_dir_all(t.path.join("a/b")).unwrap();
        fs::write(t.path.join("a/b/gone.txt"), "x").unwrap();
        fs::write(t.path.join("keep.txt"), "y").unwrap();

        let resp = delete(SyncDeleteRequest {
            root: t.root(),
            paths: vec!["a/b/gone.txt".into()],
        })
        .await
        .unwrap();
        assert_eq!(resp.deleted, 1);
        assert!(!t.path.join("a/b/gone.txt").exists());
        assert!(!t.path.join("a/b").exists(), "empty dir pruned");
        assert!(!t.path.join("a").exists(), "empty parent pruned");
        assert!(t.path.join("keep.txt").exists(), "untouched file kept");

        // A retry after the namespace mutation remains a durability operation: NotFound paths still
        // resolve and fsync their nearest surviving parent before success.
        let retry = delete(SyncDeleteRequest {
            root: t.root(),
            paths: vec!["a/b/gone.txt".into()],
        })
        .await
        .unwrap();
        assert_eq!(retry.deleted, 0);
    }

    /// Two different paths with identical content (same hash) must NOT share one staging file, or
    /// completing one destroys the other's resume state / can publish a torn file. Deterministic
    /// proxy for the concurrent same-hash corruption the adversarial review found.
    #[tokio::test]
    async fn same_hash_different_paths_have_isolated_staging() {
        let t = TempRoot::new("same-hash");
        let c = b"0123456789abcdef".to_vec();
        let h = hash_bytes(&c).to_vec();

        let half =
            |root: &str, path: &str, off: u64, data: Vec<u8>, last: bool| SyncPutChunkRequest {
                root: root.to_string(),
                path: path.into(),
                hash: h.clone(),
                offset: off,
                data,
                last,
                mode: 0o644,
                mtime_ns: 0,
            };

        // Stage both a and b halfway with the same content/hash.
        put_chunk(half(&t.root(), "a.txt", 0, c[..8].to_vec(), false))
            .await
            .unwrap();
        put_chunk(half(&t.root(), "b.txt", 0, c[..8].to_vec(), false))
            .await
            .unwrap();
        assert_eq!(
            file_status(SyncFileStatusRequest {
                root: t.root(),
                path: "a.txt".into(),
                hash: h.clone()
            })
            .await
            .unwrap()
            .have_bytes,
            8
        );
        assert_eq!(
            file_status(SyncFileStatusRequest {
                root: t.root(),
                path: "b.txt".into(),
                hash: h.clone()
            })
            .await
            .unwrap()
            .have_bytes,
            8
        );

        // Finish a (commits + cleans a's staging). b's staging must be untouched.
        put_chunk(half(&t.root(), "a.txt", 8, c[8..].to_vec(), true))
            .await
            .unwrap();
        assert_eq!(
            file_status(SyncFileStatusRequest {
                root: t.root(),
                path: "b.txt".into(),
                hash: h.clone()
            })
            .await
            .unwrap()
            .have_bytes,
            8,
            "finishing a.txt must not wipe b.txt's independent staging"
        );

        // Finish b — must still resume from 8 and commit.
        put_chunk(half(&t.root(), "b.txt", 8, c[8..].to_vec(), true))
            .await
            .unwrap();
        assert_eq!(fs::read(t.path.join("a.txt")).unwrap(), c);
        assert_eq!(fs::read(t.path.join("b.txt")).unwrap(), c);
    }

    #[tokio::test]
    async fn manifest_reflects_the_applied_tree() {
        let t = TempRoot::new("manifest");
        let data = b"content".to_vec();
        put_chunk(SyncPutChunkRequest {
            root: t.root(),
            path: "sub/f.txt".into(),
            hash: hash_bytes(&data).to_vec(),
            offset: 0,
            data: data.clone(),
            last: true,
            mode: 0o644,
            mtime_ns: 0,
        })
        .await
        .unwrap();

        let m = manifest(SyncManifestRequest { root: t.root() })
            .await
            .unwrap();
        let paths: Vec<&str> = m.entries.iter().map(|e| e.path.as_str()).collect();
        // The staging dir must NOT leak into the manifest.
        assert_eq!(paths, vec!["sub/f.txt"]);
        assert_eq!(m.entries[0].hash, hash_bytes(&data).to_vec());
    }
}
