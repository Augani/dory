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
    SyncFileStatusResponse, SyncGetChunkRequest, SyncGetChunkResponse, SyncManifestRequest,
    SyncManifestResponse, SyncPutChunkRequest, SyncPutChunkResponse, SyncReadTreeRequest,
    SyncReadTreeResponse, SyncTreeRequest, SyncTreeResponse,
};

const STAGING_DIR: &str = ".dory-sync-tmp";
// Every sync RPC for one canonical root shares a stripe, so a manifest is a stable snapshot with
// respect to agent puts/deletes. Fixed stripes avoid an attacker growing a lock map without bound.
const ROOT_LOCK_STRIPES: usize = 64;
// A fixed stripe table bounds memory while serializing operations for the same destination path.
// The hash is deliberately NOT part of this key: conflicting-content commits must linearize around
// destination hash checks, chmod, and rename. Stripe collisions only reduce concurrency.
const PATH_LOCK_STRIPES: usize = 64;
const MAX_TREE_ENTRIES: usize = 100_000;
const MAX_TREE_PATH_BYTES: usize = 8 * 1024 * 1024;

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
    #[error("invalid sync tree authority")]
    InvalidTree,
    #[error("invalid sync read authority")]
    InvalidRead,
    #[error("source file changed during sync read")]
    SourceChanged,
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
            SyncError::InvalidTree => 400,
            SyncError::InvalidRead => 400,
            SyncError::SourceChanged => 409,
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

/// Capture the complete regular-file and directory topology for a guest-to-host transfer. This is
/// read-only and excludes the agent's private push staging subtree. The returned hashes are the
/// authority the host must verify after assembling every bounded chunk.
pub async fn read_tree(req: SyncReadTreeRequest) -> Result<SyncReadTreeResponse, SyncError> {
    let root = validated_read_root_path(&req.root)?;
    let _root_guard = root_lock(&root).write().await;
    let limits = dory_sync::TreeLimits {
        max_files: req.max_files,
        max_directories: req.max_directories,
        max_bytes: req.max_bytes,
    };
    let snapshot = tokio::task::spawn_blocking(move || {
        let directory = open_absolute_directory_nofollow(&root)?;
        #[cfg(target_os = "linux")]
        let descriptor_root = {
            use std::os::fd::AsRawFd;
            PathBuf::from(format!("/proc/self/fd/{}", directory.as_raw_fd()))
        };
        #[cfg(not(target_os = "linux"))]
        let descriptor_root = root;
        #[cfg(not(target_os = "linux"))]
        let _ = &directory;
        let snapshot =
            dory_sync::walk_tree_excluding_bounded(&descriptor_root, &[STAGING_DIR], limits)?;
        Ok::<_, SyncError>(snapshot)
    })
    .await
    .map_err(|error| SyncError::Io(std::io::Error::other(error)))??;
    let files = snapshot
        .manifest
        .entries
        .into_iter()
        .map(|entry| SyncFileEntry {
            path: entry.path,
            size: entry.size,
            mtime_ns: entry.mtime_ns,
            mode: entry.mode,
            hash: entry.hash.to_vec(),
        })
        .collect();
    let directories = snapshot
        .directories
        .into_iter()
        .map(|entry| dory_pb::agent::SyncDirectoryEntry {
            path: entry.path,
            mode: entry.mode,
        })
        .collect();
    Ok(SyncReadTreeResponse { files, directories })
}

/// Return one bounded range from a regular source file. Path confinement rejects absolute,
/// traversal, and symlink components. Size is checked on every request; the host verifies the
/// manifest digest after the last response to detect same-size concurrent mutation.
pub async fn get_chunk(req: SyncGetChunkRequest) -> Result<SyncGetChunkResponse, SyncError> {
    use tokio::io::{AsyncReadExt, AsyncSeekExt};

    if req.max_bytes == 0 || req.max_bytes as usize > dory_sync::CHUNK_BYTES {
        return Err(SyncError::InvalidRead);
    }
    let root = validated_read_root_path(&req.root)?;
    let _root_guard = root_lock(&root).read().await;
    let _path_guard = path_lock(&root, &req.path).lock().await;
    // The agent may run with more privilege than the guest desktop user. Open every component
    // relative to directory descriptors with O_NOFOLLOW instead of validating a pathname and then
    // reopening it; otherwise a guest-side rename could turn a checked path into an escape.
    let root_for_open = root.clone();
    let path_for_open = req.path.clone();
    let source =
        tokio::task::spawn_blocking(move || open_regular_beneath(&root_for_open, &path_for_open))
            .await
            .map_err(|error| SyncError::Io(std::io::Error::other(error)))??;
    let metadata = source.metadata()?;
    if !metadata.is_file() || metadata.len() != req.expected_size || req.offset > req.expected_size
    {
        return Err(SyncError::SourceChanged);
    }

    let remaining = req.expected_size - req.offset;
    let count = remaining.min(req.max_bytes as u64) as usize;
    let mut file = tokio::fs::File::from_std(source);
    file.seek(std::io::SeekFrom::Start(req.offset)).await?;
    let mut data = vec![0; count];
    file.read_exact(&mut data).await?;
    let next_offset = req
        .offset
        .checked_add(data.len() as u64)
        .ok_or(SyncError::ChunkRangeOverflow)?;
    let after = file.metadata().await?;
    if !after.is_file() || after.len() != req.expected_size {
        return Err(SyncError::SourceChanged);
    }
    Ok(SyncGetChunkResponse {
        data,
        next_offset,
        eof: next_offset == req.expected_size,
    })
}

#[cfg(unix)]
fn open_regular_beneath(root: &Path, rel: &str) -> Result<std::fs::File, SyncError> {
    use std::ffi::CString;
    use std::os::fd::{AsRawFd, FromRawFd};

    if !root.is_absolute() || rel.is_empty() || rel.starts_with('/') {
        return Err(SyncError::PathEscape);
    }

    fn open_at(
        parent: &std::fs::File,
        name: &[u8],
        directory: bool,
    ) -> Result<std::fs::File, SyncError> {
        let name = CString::new(name).map_err(|_| SyncError::PathEscape)?;
        let mut flags = libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW;
        if directory {
            flags |= libc::O_DIRECTORY;
        }
        let descriptor = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), flags) };
        if descriptor < 0 {
            let error = std::io::Error::last_os_error();
            return if matches!(
                error.raw_os_error(),
                Some(libc::ELOOP) | Some(libc::ENOTDIR)
            ) {
                Err(SyncError::PathEscape)
            } else {
                Err(SyncError::Io(error))
            };
        }
        Ok(unsafe { std::fs::File::from_raw_fd(descriptor) })
    }

    let mut directory = open_absolute_directory_nofollow(root)?;

    let components = rel.split('/').collect::<Vec<_>>();
    if components
        .iter()
        .any(|part| part.is_empty() || *part == "." || *part == "..")
    {
        return Err(SyncError::PathEscape);
    }
    for component in &components[..components.len() - 1] {
        directory = open_at(&directory, component.as_bytes(), true)?;
    }
    let file = open_at(
        &directory,
        components
            .last()
            .expect("non-empty relative path")
            .as_bytes(),
        false,
    )?;
    if !file.metadata()?.is_file() {
        return Err(SyncError::SourceChanged);
    }
    Ok(file)
}

fn validated_read_root_path(root: &str) -> Result<PathBuf, SyncError> {
    use std::path::Component;

    if root.is_empty() || root.as_bytes().contains(&0) {
        return Err(SyncError::PathEscape);
    }
    let path = PathBuf::from(root);
    if !path.is_absolute()
        || path
            .components()
            .any(|component| !matches!(component, Component::RootDir | Component::Normal(_)))
    {
        return Err(SyncError::PathEscape);
    }
    #[cfg(target_os = "linux")]
    return Ok(path);

    #[cfg(not(target_os = "linux"))]
    {
        let metadata = std::fs::symlink_metadata(&path)?;
        if metadata.file_type().is_symlink() {
            return Err(SyncError::PathEscape);
        }
        Ok(std::fs::canonicalize(path)?)
    }
}

#[cfg(unix)]
fn open_absolute_directory_nofollow(root: &Path) -> Result<std::fs::File, SyncError> {
    use std::ffi::CString;
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::os::unix::ffi::OsStrExt;
    use std::path::Component;

    fn open_directory_at(parent: &std::fs::File, name: &[u8]) -> Result<std::fs::File, SyncError> {
        let name = CString::new(name).map_err(|_| SyncError::PathEscape)?;
        let descriptor = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_DIRECTORY,
            )
        };
        if descriptor < 0 {
            let error = std::io::Error::last_os_error();
            return if matches!(
                error.raw_os_error(),
                Some(libc::ELOOP) | Some(libc::ENOTDIR)
            ) {
                Err(SyncError::PathEscape)
            } else {
                Err(SyncError::Io(error))
            };
        }
        Ok(unsafe { std::fs::File::from_raw_fd(descriptor) })
    }

    let root = validated_read_root_path(&root.to_string_lossy())?;
    let slash = CString::new("/").expect("static path has no NUL");
    let descriptor = unsafe {
        libc::open(
            slash.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_DIRECTORY | libc::O_NOFOLLOW,
        )
    };
    if descriptor < 0 {
        return Err(SyncError::Io(std::io::Error::last_os_error()));
    }
    let mut directory = unsafe { std::fs::File::from_raw_fd(descriptor) };
    for component in root.components() {
        match component {
            Component::RootDir => {}
            Component::Normal(name) => {
                directory = open_directory_at(&directory, name.as_bytes())?;
            }
            _ => return Err(SyncError::PathEscape),
        }
    }
    Ok(directory)
}

#[cfg(not(unix))]
fn open_absolute_directory_nofollow(_root: &Path) -> Result<std::fs::File, SyncError> {
    Err(SyncError::InvalidRead)
}

#[cfg(not(unix))]
fn open_regular_beneath(_root: &Path, _rel: &str) -> Result<std::fs::File, SyncError> {
    Err(SyncError::InvalidRead)
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

/// Reconcile the complete namespace around streamed file puts. Running this under the root write
/// lock makes file/directory type changes deterministic and preserves empty directories without a
/// user-visible sentinel. The final pass also proves that every desired regular file exists.
pub async fn tree(req: SyncTreeRequest) -> Result<SyncTreeResponse, SyncError> {
    let root = canonical_root(&req.root).await?;
    let _root_guard = root_lock(&root).write().await;
    let desired = validate_tree_request(&root, &req).await?;
    let scan_root = root.clone();
    let current = tokio::task::spawn_blocking(move || scan_topology(&scan_root))
        .await
        .map_err(|error| SyncError::Io(std::io::Error::other(error)))??;

    let mut paths_deleted = 0u32;
    for leaf in current.leaves {
        if !leaf.regular || !desired.files.contains(&leaf.path) {
            tokio::fs::remove_file(root.join(&leaf.path)).await?;
            paths_deleted = paths_deleted.checked_add(1).ok_or(SyncError::InvalidTree)?;
        }
    }

    let mut current_directories = current.directories;
    current_directories.sort_by(|lhs, rhs| {
        path_depth(rhs)
            .cmp(&path_depth(lhs))
            .then_with(|| rhs.cmp(lhs))
    });
    for path in current_directories {
        if !desired.directories.contains_key(&path) {
            tokio::fs::remove_dir(root.join(&path)).await?;
            paths_deleted = paths_deleted.checked_add(1).ok_or(SyncError::InvalidTree)?;
        }
    }

    let mut directory_paths = desired.directories.keys().cloned().collect::<Vec<_>>();
    directory_paths.sort_by(|lhs, rhs| {
        path_depth(lhs)
            .cmp(&path_depth(rhs))
            .then_with(|| lhs.cmp(rhs))
    });
    let mut directories_created = 0u32;
    for path in &directory_paths {
        let destination = root.join(path);
        match tokio::fs::symlink_metadata(&destination).await {
            Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {
                if !req.finalize {
                    // A previously finalized source directory may be read-only. The preparation
                    // phase temporarily grants only its owner access so following file puts can
                    // reconcile children; the final pass restores the exact source mode.
                    apply_mode(&destination, 0o700).await?;
                }
            }
            Ok(_) => return Err(SyncError::InvalidTree),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                tokio::fs::create_dir(&destination).await?;
                apply_mode(&destination, 0o700).await?;
                directories_created = directories_created
                    .checked_add(1)
                    .ok_or(SyncError::InvalidTree)?;
            }
            Err(error) => return Err(SyncError::Io(error)),
        }
    }

    if req.finalize {
        for path in &desired.files {
            let metadata = tokio::fs::symlink_metadata(root.join(path)).await?;
            if !metadata.is_file() || metadata.file_type().is_symlink() {
                return Err(SyncError::InvalidTree);
            }
        }
    }

    // Persist every surviving namespace link. Desired directories include every non-root parent;
    // syncing them plus the root covers creations and removals at every depth.
    for path in directory_paths.iter().rev() {
        sync_directory(&root.join(path)).await?;
    }
    sync_directory(&root).await?;
    if req.finalize {
        for path in directory_paths.iter().rev() {
            apply_directory_mode_and_sync(
                &root.join(path),
                *desired
                    .directories
                    .get(path)
                    .ok_or(SyncError::InvalidTree)?,
            )
            .await?;
        }
    }
    Ok(SyncTreeResponse {
        paths_deleted,
        directories_created,
    })
}

struct DesiredTree {
    files: std::collections::HashSet<String>,
    directories: std::collections::HashMap<String, u32>,
}

async fn validate_tree_request(
    root: &Path,
    req: &SyncTreeRequest,
) -> Result<DesiredTree, SyncError> {
    let count = req
        .files
        .len()
        .checked_add(req.directories.len())
        .ok_or(SyncError::InvalidTree)?;
    if count > MAX_TREE_ENTRIES {
        return Err(SyncError::InvalidTree);
    }
    let mut path_bytes = 0usize;
    let mut files = std::collections::HashSet::with_capacity(req.files.len());
    let mut directories = std::collections::HashMap::with_capacity(req.directories.len());
    for path in &req.files {
        path_bytes = path_bytes
            .checked_add(path.len())
            .ok_or(SyncError::InvalidTree)?;
        validate_tree_path(root, path).await?;
        if !files.insert(path.clone()) {
            return Err(SyncError::InvalidTree);
        }
    }
    for entry in &req.directories {
        path_bytes = path_bytes
            .checked_add(entry.path.len())
            .ok_or(SyncError::InvalidTree)?;
        validate_tree_path(root, &entry.path).await?;
        if directories.insert(entry.path.clone(), entry.mode).is_some()
            || files.contains(&entry.path)
        {
            return Err(SyncError::InvalidTree);
        }
    }
    if path_bytes > MAX_TREE_PATH_BYTES {
        return Err(SyncError::InvalidTree);
    }
    for path in files.iter().chain(directories.keys()) {
        let mut parent = Path::new(path).parent();
        while let Some(value) = parent {
            if value.as_os_str().is_empty() {
                break;
            }
            let parent_text = value.to_string_lossy();
            if files.contains(parent_text.as_ref())
                || !directories.contains_key(parent_text.as_ref())
            {
                return Err(SyncError::InvalidTree);
            }
            parent = value.parent();
        }
    }
    Ok(DesiredTree { files, directories })
}

async fn validate_tree_path(root: &Path, path: &str) -> Result<(), SyncError> {
    if path == STAGING_DIR || path.starts_with(&format!("{STAGING_DIR}/")) {
        return Err(SyncError::InvalidTree);
    }
    safe_join(root, path).await.map(|_| ())
}

#[derive(Default)]
struct CurrentTopology {
    leaves: Vec<TopologyLeaf>,
    directories: Vec<String>,
}

struct TopologyLeaf {
    path: String,
    regular: bool,
}

fn scan_topology(root: &Path) -> Result<CurrentTopology, SyncError> {
    fn walk(
        root: &Path,
        directory: &Path,
        topology: &mut CurrentTopology,
    ) -> Result<(), SyncError> {
        for entry in std::fs::read_dir(directory)? {
            let entry = entry?;
            if directory == root && entry.file_name() == STAGING_DIR {
                continue;
            }
            let path = entry.path();
            let metadata = std::fs::symlink_metadata(&path)?;
            let relative = path
                .strip_prefix(root)
                .map_err(|_| SyncError::PathEscape)?
                .components()
                .map(|component| component.as_os_str().to_string_lossy())
                .collect::<Vec<_>>()
                .join("/");
            if metadata.is_dir() && !metadata.file_type().is_symlink() {
                topology.directories.push(relative);
                walk(root, &path, topology)?;
            } else {
                topology.leaves.push(TopologyLeaf {
                    path: relative,
                    regular: metadata.is_file() && !metadata.file_type().is_symlink(),
                });
            }
        }
        Ok(())
    }

    let mut topology = CurrentTopology::default();
    walk(root, root, &mut topology)?;
    Ok(topology)
}

fn path_depth(path: &str) -> usize {
    path.bytes().filter(|byte| *byte == b'/').count() + 1
}

async fn apply_directory_mode_and_sync(path: &Path, mode: u32) -> Result<(), SyncError> {
    // Open before chmod so even a source mode such as 0000 cannot prevent the durability sync.
    let directory = tokio::fs::File::open(path).await?;
    apply_mode(path, mode).await?;
    directory.sync_all().await?;
    Ok(())
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
    use dory_pb::agent::SyncDirectoryEntry;
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
    async fn read_tree_and_chunks_preserve_topology_and_bound_reads() {
        let root = TempRoot::new("read-tree");
        fs::create_dir_all(root.path.join("empty/nested")).unwrap();
        fs::create_dir_all(root.path.join(STAGING_DIR)).unwrap();
        fs::write(root.path.join(STAGING_DIR).join("private"), b"hidden").unwrap();
        fs::write(root.path.join("hello.txt"), b"hello").unwrap();

        let snapshot = read_tree(SyncReadTreeRequest {
            root: root.root(),
            max_files: 10,
            max_directories: 10,
            max_bytes: 1024,
        })
        .await
        .unwrap();
        assert_eq!(
            snapshot
                .files
                .iter()
                .map(|entry| entry.path.as_str())
                .collect::<Vec<_>>(),
            vec!["hello.txt"]
        );
        assert_eq!(
            snapshot
                .directories
                .iter()
                .map(|entry| entry.path.as_str())
                .collect::<Vec<_>>(),
            vec!["empty", "empty/nested"]
        );

        let first = get_chunk(SyncGetChunkRequest {
            root: root.root(),
            path: "hello.txt".into(),
            offset: 0,
            max_bytes: 2,
            expected_size: 5,
        })
        .await
        .unwrap();
        assert_eq!(first.data, b"he");
        assert_eq!(first.next_offset, 2);
        assert!(!first.eof);

        let last = get_chunk(SyncGetChunkRequest {
            root: root.root(),
            path: "hello.txt".into(),
            offset: first.next_offset,
            max_bytes: dory_sync::CHUNK_BYTES as u32,
            expected_size: 5,
        })
        .await
        .unwrap();
        assert_eq!(last.data, b"llo");
        assert_eq!(last.next_offset, 5);
        assert!(last.eof);

        fs::write(root.path.join("hello.txt"), b"changed").unwrap();
        assert!(matches!(
            get_chunk(SyncGetChunkRequest {
                root: root.root(),
                path: "hello.txt".into(),
                offset: 0,
                max_bytes: 1,
                expected_size: 5,
            })
            .await,
            Err(SyncError::SourceChanged)
        ));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn read_tree_rejects_symlink_roots_and_enforces_limits_before_reply() {
        use std::os::unix::fs::symlink;

        let root = TempRoot::new("read-root-authority");
        fs::write(root.path.join("one"), b"12345").unwrap();
        fs::write(root.path.join("two"), b"67890").unwrap();

        let over_files = read_tree(SyncReadTreeRequest {
            root: root.root(),
            max_files: 1,
            max_directories: 10,
            max_bytes: 100,
        })
        .await;
        assert!(over_files.is_err());

        let over_bytes = read_tree(SyncReadTreeRequest {
            root: root.root(),
            max_files: 10,
            max_directories: 10,
            max_bytes: 9,
        })
        .await;
        assert!(over_bytes.is_err());

        let link = root.path.with_extension("symlink");
        symlink(&root.path, &link).unwrap();
        let symlink_result = read_tree(SyncReadTreeRequest {
            root: link.to_string_lossy().into_owned(),
            max_files: 10,
            max_directories: 10,
            max_bytes: 100,
        })
        .await;
        let _ = fs::remove_file(&link);
        assert!(matches!(symlink_result, Err(SyncError::PathEscape)));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn read_chunks_reject_escape_symlinks_and_unbounded_requests() {
        use std::os::unix::fs::symlink;

        let root = TempRoot::new("read-reject");
        fs::write(root.path.join("real"), b"content").unwrap();
        symlink("real", root.path.join("alias")).unwrap();

        for path in ["../outside", "/etc/passwd", "alias"] {
            assert!(get_chunk(SyncGetChunkRequest {
                root: root.root(),
                path: path.into(),
                offset: 0,
                max_bytes: 1,
                expected_size: 7,
            })
            .await
            .is_err());
        }
        assert!(matches!(
            get_chunk(SyncGetChunkRequest {
                root: root.root(),
                path: "real".into(),
                offset: 0,
                max_bytes: dory_sync::CHUNK_BYTES as u32 + 1,
                expected_size: 7,
            })
            .await,
            Err(SyncError::InvalidRead)
        ));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn tree_reconciles_type_conflicts_extras_and_empty_directories() {
        use std::os::unix::fs::PermissionsExt;

        let t = TempRoot::new("tree-topology");
        fs::write(t.path.join("extra.txt"), b"remove").unwrap();
        fs::write(t.path.join("folder"), b"file-to-directory").unwrap();
        fs::create_dir_all(t.path.join("replace.txt")).unwrap();
        fs::write(t.path.join("replace.txt/old"), b"directory-to-file").unwrap();
        fs::create_dir(t.path.join("old-empty")).unwrap();
        let request = |finalize| SyncTreeRequest {
            root: t.root(),
            files: vec!["folder/a.txt".into(), "replace.txt".into()],
            directories: vec![
                SyncDirectoryEntry {
                    path: "empty".into(),
                    mode: 0o711,
                },
                SyncDirectoryEntry {
                    path: "folder".into(),
                    mode: 0o700,
                },
            ],
            finalize,
        };

        let prepared = tree(request(false)).await.unwrap();
        assert_eq!(prepared.paths_deleted, 5);
        assert_eq!(prepared.directories_created, 2);
        assert!(t.path.join("empty").is_dir());
        assert!(t.path.join("folder").is_dir());
        assert!(!t.path.join("extra.txt").exists());
        assert!(!t.path.join("replace.txt").exists());

        fs::write(t.path.join("folder/a.txt"), b"a").unwrap();
        fs::write(t.path.join("replace.txt"), b"replacement").unwrap();
        let finalized = tree(request(true)).await.unwrap();
        assert_eq!(finalized.paths_deleted, 0);
        assert_eq!(finalized.directories_created, 0);
        assert_eq!(
            fs::metadata(t.path.join("empty"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o711
        );
        assert_eq!(
            fs::metadata(t.path.join("folder"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
    }

    #[tokio::test]
    async fn tree_rejects_incomplete_duplicate_reserved_and_missing_final_authority() {
        let t = TempRoot::new("tree-invalid");
        let cases = [
            SyncTreeRequest {
                root: t.root(),
                files: vec!["missing-parent/file".into()],
                directories: vec![],
                finalize: false,
            },
            SyncTreeRequest {
                root: t.root(),
                files: vec!["same".into(), "same".into()],
                directories: vec![],
                finalize: false,
            },
            SyncTreeRequest {
                root: t.root(),
                files: vec![format!("{STAGING_DIR}/poison")],
                directories: vec![],
                finalize: false,
            },
        ];
        for request in cases {
            assert!(matches!(tree(request).await, Err(SyncError::InvalidTree)));
        }

        let missing = tree(SyncTreeRequest {
            root: t.root(),
            files: vec!["not-sent".into()],
            directories: vec![],
            finalize: true,
        })
        .await;
        assert!(matches!(missing, Err(SyncError::Io(_))));
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
