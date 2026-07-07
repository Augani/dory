//! Agent-side apply for host-authoritative sync. The host is the source of truth; these handlers
//! stage incoming chunks under `<root>/.dory-sync-tmp/<hash>` and atomically rename into place on the
//! last chunk (so a reader never sees a half-written file), verifying the full content hash before
//! commit. Staging by hash makes an interrupted push resumable: `file_status` reports how many bytes
//! are already staged, and the host resumes from there. Paths are confined to `root` — a `..` or
//! absolute path is rejected, never followed.

use std::path::{Path, PathBuf};

use dory_pb::agent::{
    SyncDeleteRequest, SyncDeleteResponse, SyncFileEntry, SyncFileStatusRequest,
    SyncFileStatusResponse, SyncManifestRequest, SyncManifestResponse, SyncPutChunkRequest,
    SyncPutChunkResponse,
};

const STAGING_DIR: &str = ".dory-sync-tmp";

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("path escapes the sync root")]
    PathEscape,
    #[error("chunk offset {got} does not match staged size {expected}")]
    OffsetMismatch { got: u64, expected: u64 },
    #[error("content hash mismatch on commit")]
    HashMismatch,
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
            SyncError::Io(_) => 500,
        }
    }
}

pub async fn manifest(req: SyncManifestRequest) -> Result<SyncManifestResponse, SyncError> {
    let root = PathBuf::from(req.root);
    let manifest = tokio::task::spawn_blocking(move || dory_sync::walk_manifest(&root))
        .await
        .map_err(|e| SyncError::Io(std::io::Error::other(e)))??;
    let entries = manifest
        .entries
        .into_iter()
        // The staging dir is an implementation detail — never report it to the host.
        .filter(|e| !e.path.starts_with(&format!("{STAGING_DIR}/")))
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
    let root = PathBuf::from(&req.root);
    // Reject a bad path even on status so the host gets a consistent error surface.
    safe_join(&root, &req.path)?;
    let staging = staging_path(&root, &req.hash);
    let have_bytes = match tokio::fs::metadata(&staging).await {
        Ok(m) => m.len(),
        Err(_) => 0,
    };
    Ok(SyncFileStatusResponse { have_bytes })
}

pub async fn put_chunk(req: SyncPutChunkRequest) -> Result<SyncPutChunkResponse, SyncError> {
    use tokio::io::{AsyncSeekExt, AsyncWriteExt};

    let root = PathBuf::from(&req.root);
    let dest = safe_join(&root, &req.path)?;
    let staging = staging_path(&root, &req.hash);
    if let Some(parent) = staging.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }

    // Strict append: the chunk offset must match what is already staged. offset 0 (re)starts the
    // file; a resumed chunk must land exactly at the current staged size.
    let staged = tokio::fs::metadata(&staging).await.map(|m| m.len()).unwrap_or(0);
    if req.offset == 0 {
        // fresh (or restart): truncate any stale staging
    } else if req.offset != staged {
        return Err(SyncError::OffsetMismatch {
            got: req.offset,
            expected: staged,
        });
    }

    let mut file = tokio::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(req.offset == 0)
        .open(&staging)
        .await?;
    file.seek(std::io::SeekFrom::Start(req.offset)).await?;
    file.write_all(&req.data).await?;
    let next_offset = req.offset + req.data.len() as u64;

    if !req.last {
        return Ok(SyncPutChunkResponse {
            next_offset,
            committed: false,
        });
    }

    // Commit: verify the FULL content hash before the file becomes visible.
    file.sync_all().await?;
    drop(file);
    let contents = tokio::fs::read(&staging).await?;
    if dory_sync::hash_bytes(&contents).as_slice() != req.hash.as_slice() {
        let _ = tokio::fs::remove_file(&staging).await; // never leave poisoned staging around
        return Err(SyncError::HashMismatch);
    }
    if let Some(parent) = dest.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    apply_mode(&staging, req.mode).await?;
    tokio::fs::rename(&staging, &dest).await?; // atomic publish
    Ok(SyncPutChunkResponse {
        next_offset,
        committed: true,
    })
}

pub async fn delete(req: SyncDeleteRequest) -> Result<SyncDeleteResponse, SyncError> {
    let root = PathBuf::from(&req.root);
    let mut deleted = 0u32;
    for rel in &req.paths {
        let path = safe_join(&root, rel)?;
        match tokio::fs::remove_file(&path).await {
            Ok(()) => {
                deleted += 1;
                prune_empty_parents(&root, &path).await;
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(SyncError::Io(e)),
        }
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
async fn prune_empty_parents(root: &Path, path: &Path) {
    let mut dir = path.parent().map(Path::to_path_buf);
    while let Some(d) = dir {
        if d == root || !d.starts_with(root) {
            break;
        }
        // remove_dir only succeeds on an empty dir — exactly the prune condition.
        if tokio::fs::remove_dir(&d).await.is_err() {
            break;
        }
        dir = d.parent().map(Path::to_path_buf);
    }
}

/// Join `rel` (a forward-slash relpath) onto `root`, rejecting anything that would escape it.
fn safe_join(root: &Path, rel: &str) -> Result<PathBuf, SyncError> {
    if rel.is_empty() || rel.starts_with('/') {
        return Err(SyncError::PathEscape);
    }
    let mut out = root.to_path_buf();
    for part in rel.split('/') {
        if part.is_empty() || part == "." || part == ".." {
            return Err(SyncError::PathEscape);
        }
        out.push(part);
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

fn staging_path(root: &Path, hash: &[u8]) -> PathBuf {
    root.join(STAGING_DIR).join(hex(hash))
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
            let path = std::env::temp_dir().join(format!("dory-apply-{}-{}", std::process::id(), tag));
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
            mode: 0o644,
            mtime_ns: 0,
        })
        .await
        .unwrap();
        assert!(resp.committed);
        assert_eq!(resp.next_offset, data.len() as u64);
        assert_eq!(fs::read(t.path.join("dir/file.txt")).unwrap(), data);
        // Staging cleaned up after commit.
        assert!(!t.path.join(STAGING_DIR).join(hex(&hash)).exists());
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
        assert!(!t.path.join("big.bin").exists(), "not committed mid-transfer");

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
        assert!(matches!(err, SyncError::OffsetMismatch { got: 99, expected: 0 }));
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
        assert!(!t.path.join("f").exists(), "a corrupt file must never be published");
        assert!(!t.path.join(STAGING_DIR).join(hex(&declared)).exists(), "poisoned staging removed");
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
            assert!(matches!(err, Err(SyncError::PathEscape)), "{bad:?} must be rejected");
        }
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

        let m = manifest(SyncManifestRequest { root: t.root() }).await.unwrap();
        let paths: Vec<&str> = m.entries.iter().map(|e| e.path.as_str()).collect();
        // The staging dir must NOT leak into the manifest.
        assert_eq!(paths, vec!["sub/f.txt"]);
        assert_eq!(m.entries[0].hash, hash_bytes(&data).to_vec());
    }
}
