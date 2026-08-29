//! Guest-to-host tree transfer. The guest supplies a point-in-time manifest and bounded chunks;
//! the host materializes them only inside a newly-created private staging root, verifies every
//! complete SHA-256, and removes the entire root on cancellation or failure. Callers publish the
//! verified staging tree separately, so partial guest bytes never become user-visible authority.

use std::collections::HashSet;
use std::path::Path;

use dory_pb::agent::{SyncGetChunkRequest, SyncReadTreeRequest};
use dory_sync::{DirectoryEntry, FileEntry, Hash, TreeSnapshot, CHUNK_BYTES, HASH_LEN};
use tokio::io::AsyncWriteExt;

use crate::{AgentClient, RemoteError};

const PRIVATE_TEMP_DIRECTORY: &str = ".dory-pull-tmp";
const MAX_PATH_BYTES: usize = 4 * 1024;
const MAX_TOTAL_PATH_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PullLimits {
    pub max_files: u64,
    pub max_directories: u64,
    pub max_bytes: u64,
}

impl Default for PullLimits {
    fn default() -> Self {
        Self {
            max_files: 100_000,
            max_directories: 100_000,
            max_bytes: 32 * 1024 * 1024 * 1024,
        }
    }
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct PullStats {
    pub files_received: u64,
    pub directories_received: u64,
    pub bytes_received: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PullPhase {
    Preparing,
    Transferring,
    Finalizing,
    Completed,
    Cancelled,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PullProgress {
    pub phase: PullPhase,
    pub files_total: u64,
    pub files_completed: u64,
    pub bytes_total: u64,
    pub bytes_completed: u64,
    pub current_path: Option<String>,
}

impl Default for PullProgress {
    fn default() -> Self {
        Self {
            phase: PullPhase::Preparing,
            files_total: 0,
            files_completed: 0,
            bytes_total: 0,
            bytes_completed: 0,
            current_path: None,
        }
    }
}

pub trait PullObserver: Send + Sync {
    fn update(&self, progress: &PullProgress);
    fn is_cancelled(&self) -> bool;
}

struct IgnorePullProgress;

impl PullObserver for IgnorePullProgress {
    fn update(&self, _progress: &PullProgress) {}
    fn is_cancelled(&self) -> bool {
        false
    }
}

pub trait SyncSource {
    fn read_tree(
        &self,
        root: &str,
        limits: PullLimits,
    ) -> impl std::future::Future<Output = Result<TreeSnapshot, RemoteError>> + Send;
    fn get_chunk(
        &self,
        root: &str,
        file: &FileEntry,
        offset: u64,
        max_bytes: u32,
    ) -> impl std::future::Future<Output = Result<SourceChunk, RemoteError>> + Send;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceChunk {
    pub data: Vec<u8>,
    pub next_offset: u64,
    pub eof: bool,
}

pub async fn pull<S: SyncSource>(
    remote_root: &str,
    local_root: &Path,
    source: &S,
    limits: PullLimits,
) -> Result<PullStats, RemoteError> {
    pull_observed(remote_root, local_root, source, limits, &IgnorePullProgress).await
}

pub async fn pull_observed<S: SyncSource, O: PullObserver>(
    remote_root: &str,
    local_root: &Path,
    source: &S,
    limits: PullLimits,
    observer: &O,
) -> Result<PullStats, RemoteError> {
    let mut progress = PullProgress::default();
    observer.update(&progress);
    let result = pull_inner(
        remote_root,
        local_root,
        source,
        limits,
        observer,
        &mut progress,
    )
    .await;
    if result.is_err() {
        if progress.phase != PullPhase::Cancelled {
            progress.phase = PullPhase::Failed;
        }
        progress.current_path = None;
        observer.update(&progress);
    }
    result
}

async fn pull_inner<S: SyncSource, O: PullObserver>(
    remote_root: &str,
    local_root: &Path,
    source: &S,
    limits: PullLimits,
    observer: &O,
    progress: &mut PullProgress,
) -> Result<PullStats, RemoteError> {
    require_not_cancelled(observer, progress)?;
    validate_new_local_root(local_root)?;
    let snapshot = source.read_tree(remote_root, limits).await?;
    let authority = validate_snapshot(snapshot, limits)?;
    progress.files_total = authority.files.len() as u64;
    progress.bytes_total = authority.bytes_total;
    observer.update(progress);
    require_not_cancelled(observer, progress)?;

    // A create-new failure never authorizes cleanup of whatever won the race. Once our private
    // directory exists, every subsequent failure removes only that directory before returning.
    create_private_root(local_root).await?;
    let result = async {
        sync_directory(local_root.parent().ok_or(RemoteError::Decode)?).await?;
        materialize(
            remote_root,
            local_root,
            source,
            &authority,
            observer,
            progress,
        )
        .await
    }
    .await;
    if result.is_err() {
        let _ = cleanup_private_root(local_root).await;
    }
    result
}

struct ValidatedSnapshot {
    files: Vec<FileEntry>,
    directories: Vec<DirectoryEntry>,
    bytes_total: u64,
}

fn validate_snapshot(
    snapshot: TreeSnapshot,
    limits: PullLimits,
) -> Result<ValidatedSnapshot, RemoteError> {
    let file_count =
        u64::try_from(snapshot.manifest.entries.len()).map_err(|_| RemoteError::Decode)?;
    let directory_count =
        u64::try_from(snapshot.directories.len()).map_err(|_| RemoteError::Decode)?;
    if file_count > limits.max_files || directory_count > limits.max_directories {
        return Err(RemoteError::Decode);
    }

    let mut previous_file: Option<&str> = None;
    let mut previous_directory: Option<&str> = None;
    let mut total_path_bytes = 0usize;
    let mut bytes_total = 0u64;
    let mut file_paths = HashSet::with_capacity(snapshot.manifest.entries.len());
    let mut directory_paths = HashSet::with_capacity(snapshot.directories.len());

    for directory in &snapshot.directories {
        validate_relative_path(&directory.path)?;
        if previous_directory.is_some_and(|previous| previous >= directory.path.as_str())
            || directory.path == PRIVATE_TEMP_DIRECTORY
            || directory
                .path
                .starts_with(&format!("{PRIVATE_TEMP_DIRECTORY}/"))
        {
            return Err(RemoteError::Decode);
        }
        previous_directory = Some(&directory.path);
        total_path_bytes = total_path_bytes
            .checked_add(directory.path.len())
            .ok_or(RemoteError::Decode)?;
        directory_paths.insert(directory.path.clone());
    }
    for file in &snapshot.manifest.entries {
        validate_relative_path(&file.path)?;
        if previous_file.is_some_and(|previous| previous >= file.path.as_str())
            || file.path == PRIVATE_TEMP_DIRECTORY
            || file.path.starts_with(&format!("{PRIVATE_TEMP_DIRECTORY}/"))
        {
            return Err(RemoteError::Decode);
        }
        previous_file = Some(&file.path);
        if file.mtime_ns < 0 {
            return Err(RemoteError::Decode);
        }
        total_path_bytes = total_path_bytes
            .checked_add(file.path.len())
            .ok_or(RemoteError::Decode)?;
        bytes_total = bytes_total
            .checked_add(file.size)
            .ok_or(RemoteError::Decode)?;
        file_paths.insert(file.path.clone());
    }
    if total_path_bytes > MAX_TOTAL_PATH_BYTES || bytes_total > limits.max_bytes {
        return Err(RemoteError::Decode);
    }
    if file_paths.iter().any(|path| directory_paths.contains(path)) {
        return Err(RemoteError::Decode);
    }

    for directory in &directory_paths {
        if let Some(parent) = parent_path(directory) {
            if !directory_paths.contains(parent) || file_paths.contains(parent) {
                return Err(RemoteError::Decode);
            }
        }
    }
    for file in &file_paths {
        if let Some(parent) = parent_path(file) {
            if !directory_paths.contains(parent) || file_paths.contains(parent) {
                return Err(RemoteError::Decode);
            }
        }
    }

    Ok(ValidatedSnapshot {
        files: snapshot.manifest.entries,
        directories: snapshot.directories,
        bytes_total,
    })
}

async fn materialize<S: SyncSource, O: PullObserver>(
    remote_root: &str,
    local_root: &Path,
    source: &S,
    snapshot: &ValidatedSnapshot,
    observer: &O,
    progress: &mut PullProgress,
) -> Result<PullStats, RemoteError> {
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    for directory in &snapshot.directories {
        let path = local_root.join(&directory.path);
        tokio::fs::create_dir(&path).await?;
        #[cfg(unix)]
        tokio::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).await?;
    }
    let temp_root = local_root.join(PRIVATE_TEMP_DIRECTORY);
    tokio::fs::create_dir(&temp_root).await?;
    #[cfg(unix)]
    tokio::fs::set_permissions(&temp_root, std::fs::Permissions::from_mode(0o700)).await?;

    progress.phase = PullPhase::Transferring;
    observer.update(progress);
    let mut stats = PullStats {
        directories_received: snapshot.directories.len() as u64,
        ..PullStats::default()
    };

    for (index, entry) in snapshot.files.iter().enumerate() {
        require_not_cancelled(observer, progress)?;
        progress.current_path = Some(entry.path.clone());
        observer.update(progress);
        let staged = temp_root.join(format!("{index:016x}"));
        let mut file = tokio::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&staged)
            .await?;
        let mut offset = 0u64;
        loop {
            require_not_cancelled(observer, progress)?;
            let chunk = source
                .get_chunk(
                    remote_root,
                    entry,
                    offset,
                    u32::try_from(CHUNK_BYTES).map_err(|_| RemoteError::Decode)?,
                )
                .await?;
            let expected_next = offset
                .checked_add(chunk.data.len() as u64)
                .ok_or(RemoteError::Decode)?;
            if chunk.data.len() > CHUNK_BYTES
                || chunk.next_offset != expected_next
                || chunk.next_offset > entry.size
                || chunk.eof != (chunk.next_offset == entry.size)
                || (chunk.data.is_empty() && !chunk.eof)
            {
                return Err(RemoteError::Decode);
            }
            file.write_all(&chunk.data).await?;
            offset = chunk.next_offset;
            progress.bytes_completed = stats
                .bytes_received
                .checked_add(offset)
                .ok_or(RemoteError::Decode)?;
            observer.update(progress);
            if chunk.eof {
                break;
            }
        }
        file.flush().await?;
        file.sync_all().await?;
        drop(file);
        let staged_for_hash = staged.clone();
        let hash = tokio::task::spawn_blocking(move || dory_sync::hash_file(&staged_for_hash))
            .await
            .map_err(|error| RemoteError::Io(std::io::Error::other(error)))??;
        if hash != entry.hash {
            return Err(RemoteError::SourceChanged);
        }
        apply_file_metadata_and_sync(&staged, entry.mode & 0o777, entry.mtime_ns).await?;
        let destination = local_root.join(&entry.path);
        tokio::fs::rename(&staged, &destination).await?;
        sync_directory(destination.parent().ok_or(RemoteError::Decode)?).await?;
        stats.files_received = stats
            .files_received
            .checked_add(1)
            .ok_or(RemoteError::Decode)?;
        stats.bytes_received = stats
            .bytes_received
            .checked_add(entry.size)
            .ok_or(RemoteError::Decode)?;
        progress.files_completed = stats.files_received;
        progress.bytes_completed = stats.bytes_received;
        observer.update(progress);
    }

    progress.phase = PullPhase::Finalizing;
    progress.current_path = None;
    observer.update(progress);
    tokio::fs::remove_dir(&temp_root).await?;
    for directory in snapshot.directories.iter().rev() {
        let path = local_root.join(&directory.path);
        apply_directory_mode_and_sync(&path, directory.mode & 0o777).await?;
    }
    sync_directory(local_root).await?;
    progress.phase = PullPhase::Completed;
    progress.current_path = None;
    progress.files_completed = progress.files_total;
    progress.bytes_completed = progress.bytes_total;
    observer.update(progress);
    Ok(stats)
}

fn validate_new_local_root(local_root: &Path) -> Result<(), RemoteError> {
    if !local_root.is_absolute() || local_root.file_name().is_none() {
        return Err(RemoteError::Decode);
    }
    let parent = local_root.parent().ok_or(RemoteError::Decode)?;
    let metadata = std::fs::symlink_metadata(parent)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(RemoteError::Decode);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o077 != 0 {
            return Err(RemoteError::Decode);
        }
    }
    match std::fs::symlink_metadata(local_root) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Ok(_) => Err(RemoteError::Decode),
        Err(error) => Err(RemoteError::Io(error)),
    }
}

async fn create_private_root(local_root: &Path) -> Result<(), RemoteError> {
    let path = local_root.to_path_buf();
    tokio::task::spawn_blocking(move || {
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            let mut builder = std::fs::DirBuilder::new();
            builder.mode(0o700).create(path)
        }
        #[cfg(not(unix))]
        {
            std::fs::create_dir(path)
        }
    })
    .await
    .map_err(|error| RemoteError::Io(std::io::Error::other(error)))??;
    Ok(())
}

async fn apply_file_metadata_and_sync(
    path: &Path,
    mode: u32,
    mtime_ns: i64,
) -> Result<(), RemoteError> {
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || {
        let modified = std::time::UNIX_EPOCH
            .checked_add(std::time::Duration::from_nanos(
                u64::try_from(mtime_ns)
                    .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidData))?,
            ))
            .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::InvalidData))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let file = std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(path)?;
            file.set_permissions(std::fs::Permissions::from_mode(mode))?;
            file.set_times(std::fs::FileTimes::new().set_modified(modified))?;
            file.sync_all()
        }
        #[cfg(not(unix))]
        {
            let file = std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(path)?;
            file.set_times(std::fs::FileTimes::new().set_modified(modified))?;
            file.sync_all()
        }
    })
    .await
    .map_err(|error| RemoteError::Io(std::io::Error::other(error)))??;
    Ok(())
}

async fn apply_directory_mode_and_sync(path: &Path, mode: u32) -> Result<(), RemoteError> {
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let directory = std::fs::File::open(path)?;
            directory.set_permissions(std::fs::Permissions::from_mode(mode))?;
            directory.sync_all()
        }
        #[cfg(not(unix))]
        {
            std::fs::File::open(path)?.sync_all()
        }
    })
    .await
    .map_err(|error| RemoteError::Io(std::io::Error::other(error)))??;
    Ok(())
}

async fn sync_directory(path: &Path) -> Result<(), RemoteError> {
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || std::fs::File::open(path)?.sync_all())
        .await
        .map_err(|error| RemoteError::Io(std::io::Error::other(error)))??;
    Ok(())
}

async fn cleanup_private_root(path: &Path) -> Result<(), RemoteError> {
    let path = path.to_path_buf();
    let parent = path.parent().map(Path::to_path_buf);
    tokio::task::spawn_blocking(move || {
        #[cfg(unix)]
        fn make_directories_private_and_writable(path: &Path) -> std::io::Result<()> {
            use std::os::unix::fs::PermissionsExt;
            let metadata = std::fs::symlink_metadata(path)?;
            if !metadata.is_dir() || metadata.file_type().is_symlink() {
                return Err(std::io::Error::from(std::io::ErrorKind::InvalidData));
            }
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
            for entry in std::fs::read_dir(path)? {
                let entry = entry?;
                let metadata = std::fs::symlink_metadata(entry.path())?;
                if metadata.is_dir() && !metadata.file_type().is_symlink() {
                    make_directories_private_and_writable(&entry.path())?;
                }
            }
            Ok(())
        }

        #[cfg(unix)]
        make_directories_private_and_writable(&path)?;
        std::fs::remove_dir_all(&path)?;
        if let Some(parent) = parent {
            std::fs::File::open(parent)?.sync_all()?;
        }
        Ok::<(), std::io::Error>(())
    })
    .await
    .map_err(|error| RemoteError::Io(std::io::Error::other(error)))??;
    Ok(())
}

fn validate_relative_path(path: &str) -> Result<(), RemoteError> {
    if path.is_empty()
        || path.len() > MAX_PATH_BYTES
        || path.starts_with('/')
        || path.contains('\0')
        || path
            .split('/')
            .any(|component| component.is_empty() || component == "." || component == "..")
    {
        return Err(RemoteError::Decode);
    }
    Ok(())
}

fn parent_path(path: &str) -> Option<&str> {
    path.rsplit_once('/').map(|(parent, _)| parent)
}

fn require_not_cancelled<O: PullObserver>(
    observer: &O,
    progress: &mut PullProgress,
) -> Result<(), RemoteError> {
    if !observer.is_cancelled() {
        return Ok(());
    }
    progress.phase = PullPhase::Cancelled;
    progress.current_path = None;
    observer.update(progress);
    Err(RemoteError::Cancelled)
}

impl SyncSource for AgentClient {
    async fn read_tree(&self, root: &str, limits: PullLimits) -> Result<TreeSnapshot, RemoteError> {
        let response = self
            .sync_read_tree(SyncReadTreeRequest {
                root: root.to_string(),
                max_files: limits.max_files,
                max_directories: limits.max_directories,
                max_bytes: limits.max_bytes,
            })
            .await?;
        let mut files = Vec::with_capacity(response.files.len());
        for entry in response.files {
            let hash: Hash = entry
                .hash
                .as_slice()
                .try_into()
                .map_err(|_| RemoteError::Decode)?;
            files.push(FileEntry {
                path: entry.path,
                size: entry.size,
                mtime_ns: entry.mtime_ns,
                mode: entry.mode,
                hash,
            });
        }
        let directories = response
            .directories
            .into_iter()
            .map(|entry| DirectoryEntry {
                path: entry.path,
                mtime_ns: 0,
                mode: entry.mode,
            })
            .collect();
        Ok(TreeSnapshot {
            manifest: dory_sync::Manifest { entries: files },
            directories,
        })
    }

    async fn get_chunk(
        &self,
        root: &str,
        file: &FileEntry,
        offset: u64,
        max_bytes: u32,
    ) -> Result<SourceChunk, RemoteError> {
        let response = self
            .sync_get_chunk(SyncGetChunkRequest {
                root: root.to_string(),
                path: file.path.clone(),
                offset,
                max_bytes,
                expected_size: file.size,
            })
            .await?;
        Ok(SourceChunk {
            data: response.data,
            next_offset: response.next_offset,
            eof: response.eof,
        })
    }
}

const _: () = assert!(HASH_LEN == 32);

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Mutex;

    struct TempParent {
        path: PathBuf,
    }

    impl TempParent {
        fn new(tag: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "dory-pull-{}-{}-{}",
                std::process::id(),
                tag,
                rand::random::<u64>()
            ));
            std::fs::create_dir(&path).unwrap();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
            }
            Self { path }
        }
    }

    impl Drop for TempParent {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    struct FakeSource {
        snapshot: TreeSnapshot,
        contents: HashMap<String, Vec<u8>>,
        corrupt_path: Option<String>,
        bogus_offsets: bool,
    }

    impl SyncSource for FakeSource {
        async fn read_tree(
            &self,
            _root: &str,
            _limits: PullLimits,
        ) -> Result<TreeSnapshot, RemoteError> {
            Ok(self.snapshot.clone())
        }

        async fn get_chunk(
            &self,
            _root: &str,
            file: &FileEntry,
            offset: u64,
            max_bytes: u32,
        ) -> Result<SourceChunk, RemoteError> {
            let contents = self.contents.get(&file.path).ok_or(RemoteError::Decode)?;
            let start = usize::try_from(offset).map_err(|_| RemoteError::Decode)?;
            let end = (start + max_bytes as usize).min(contents.len());
            let mut data = contents[start..end].to_vec();
            if self.corrupt_path.as_deref() == Some(&file.path) && !data.is_empty() {
                data[0] ^= 0xff;
            }
            Ok(SourceChunk {
                data,
                next_offset: if self.bogus_offsets {
                    end as u64 + 1
                } else {
                    end as u64
                },
                eof: end == contents.len(),
            })
        }
    }

    fn source(files: &[(&str, &[u8])], directories: &[&str]) -> FakeSource {
        let mut contents = HashMap::new();
        let entries = files
            .iter()
            .map(|(path, bytes)| {
                contents.insert((*path).to_string(), bytes.to_vec());
                FileEntry {
                    path: (*path).to_string(),
                    size: bytes.len() as u64,
                    mtime_ns: 0,
                    mode: 0o100640,
                    hash: dory_sync::hash_bytes(bytes),
                }
            })
            .collect();
        FakeSource {
            snapshot: TreeSnapshot {
                manifest: dory_sync::Manifest { entries },
                directories: directories
                    .iter()
                    .map(|path| DirectoryEntry {
                        path: (*path).to_string(),
                        mtime_ns: 0,
                        mode: 0o040750,
                    })
                    .collect(),
            },
            contents,
            corrupt_path: None,
            bogus_offsets: false,
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn pull_materializes_verified_files_and_empty_directories() {
        use std::os::unix::fs::PermissionsExt;

        let parent = TempParent::new("success");
        let destination = parent.path.join("verified");
        let source = source(
            &[("hello.txt", b"hello"), ("nested/report.txt", b"report")],
            &["empty", "nested"],
        );

        let stats = pull(
            "/home/dory/Downloads/export",
            &destination,
            &source,
            PullLimits::default(),
        )
        .await
        .unwrap();

        assert_eq!(stats.files_received, 2);
        assert_eq!(stats.directories_received, 2);
        assert_eq!(stats.bytes_received, 11);
        assert_eq!(
            std::fs::read(destination.join("hello.txt")).unwrap(),
            b"hello"
        );
        assert_eq!(
            std::fs::read(destination.join("nested/report.txt")).unwrap(),
            b"report"
        );
        assert!(destination.join("empty").is_dir());
        assert_eq!(
            std::fs::metadata(destination.join("hello.txt"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o640
        );
    }

    #[tokio::test]
    async fn digest_or_protocol_mismatch_removes_the_unpublished_root() {
        for bogus_offsets in [false, true] {
            let parent = TempParent::new("mismatch");
            let destination = parent.path.join("rejected");
            let mut source = source(&[("payload", b"payload")], &[]);
            source.corrupt_path = (!bogus_offsets).then(|| "payload".into());
            source.bogus_offsets = bogus_offsets;

            assert!(pull("/guest", &destination, &source, PullLimits::default())
                .await
                .is_err());
            assert!(!destination.exists());
        }
    }

    #[tokio::test]
    async fn malformed_or_over_limit_authority_writes_nothing() {
        let cases = [
            source(&[("../escape", b"x")], &[]),
            source(&[("missing/file", b"x")], &[]),
            source(&[(PRIVATE_TEMP_DIRECTORY, b"x")], &[]),
        ];
        for source in cases {
            let parent = TempParent::new("authority");
            let destination = parent.path.join("rejected");
            assert!(pull("/guest", &destination, &source, PullLimits::default())
                .await
                .is_err());
            assert!(!destination.exists());
        }

        let parent = TempParent::new("limit");
        let destination = parent.path.join("rejected");
        let source = source(&[("large", b"1234")], &[]);
        assert!(pull(
            "/guest",
            &destination,
            &source,
            PullLimits {
                max_bytes: 3,
                ..PullLimits::default()
            },
        )
        .await
        .is_err());
        assert!(!destination.exists());
    }

    struct CancellingObserver {
        cancel: AtomicBool,
        updates: Mutex<Vec<PullProgress>>,
    }

    impl PullObserver for CancellingObserver {
        fn update(&self, progress: &PullProgress) {
            self.updates.lock().unwrap().push(progress.clone());
            if progress.phase == PullPhase::Transferring {
                self.cancel.store(true, Ordering::Release);
            }
        }

        fn is_cancelled(&self) -> bool {
            self.cancel.load(Ordering::Acquire)
        }
    }

    #[tokio::test]
    async fn cancellation_is_terminal_and_cleans_partial_bytes() {
        let parent = TempParent::new("cancel");
        let destination = parent.path.join("cancelled");
        let source = source(&[("payload", b"payload")], &[]);
        let observer = CancellingObserver {
            cancel: AtomicBool::new(false),
            updates: Mutex::new(Vec::new()),
        };

        assert!(matches!(
            pull_observed(
                "/guest",
                &destination,
                &source,
                PullLimits::default(),
                &observer
            )
            .await,
            Err(RemoteError::Cancelled)
        ));
        assert!(!destination.exists());
        assert_eq!(
            observer.updates.lock().unwrap().last().unwrap().phase,
            PullPhase::Cancelled
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn destination_authority_is_private_create_new_and_cleanup_handles_mode_zero() {
        use std::os::unix::fs::PermissionsExt;

        let parent = TempParent::new("destination");
        let source = source(&[("payload", b"payload")], &[]);
        let existing = parent.path.join("existing");
        std::fs::create_dir(&existing).unwrap();
        std::fs::write(existing.join("keep"), b"owned elsewhere").unwrap();
        assert!(pull("/guest", &existing, &source, PullLimits::default())
            .await
            .is_err());
        assert_eq!(
            std::fs::read(existing.join("keep")).unwrap(),
            b"owned elsewhere"
        );

        let public_parent = TempParent::new("public-parent");
        std::fs::set_permissions(&public_parent.path, std::fs::Permissions::from_mode(0o755))
            .unwrap();
        let rejected = public_parent.path.join("rejected");
        assert!(pull("/guest", &rejected, &source, PullLimits::default())
            .await
            .is_err());
        assert!(!rejected.exists());

        let doomed = parent.path.join("doomed");
        std::fs::create_dir(&doomed).unwrap();
        std::fs::create_dir(doomed.join("closed")).unwrap();
        std::fs::write(doomed.join("closed/file"), b"partial").unwrap();
        std::fs::set_permissions(
            doomed.join("closed"),
            std::fs::Permissions::from_mode(0o000),
        )
        .unwrap();
        cleanup_private_root(&doomed).await.unwrap();
        assert!(!doomed.exists());
    }
}
