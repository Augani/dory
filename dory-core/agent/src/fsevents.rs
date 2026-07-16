//! Bounded host-edit batches used to synthesize Linux fsnotify after virtio-fs invalidation.
//!
//! The host is the only producer. It sends absolute guest paths derived from configured shares;
//! this module validates the wire data again and performs a same-mode `fchmod` on the path (or its
//! nearest existing parent). The metadata operation is intentionally content-neutral while still
//! traversing Linux VFS, which makes inotify-backed tools observe the edit.

use std::collections::HashMap;
use std::ffi::CString;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path, PathBuf};
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};

pub const PROTOCOL_VERSION: u32 = 2;
/// Maximum encoded batch body. With its four-byte prefix, the complete frame is at most 128 KiB.
pub const MAX_FRAME_BYTES: usize = 128 * 1024 - std::mem::size_of::<u32>();
pub const MAX_PATHS: usize = 512;
/// `PATH_MAX` includes the terminating NUL required by `open(2)`.
pub const MAX_PATH_BYTES: usize = libc::PATH_MAX as usize - 1;
pub const DEFAULT_DEDUPE_CAPACITY: usize = 4096;
pub const DEFAULT_DEDUPE_TTL: Duration = Duration::from_secs(120);
const NUDGE_STALE_RETRIES: usize = 64;
const NUDGE_STALE_RETRY_DELAY: Duration = Duration::from_millis(1);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodedBatch {
    pub operation_id: u64,
    pub paths: Vec<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BatchOutcome {
    pub path_count: u32,
    pub failed_indices: Vec<u32>,
}

impl BatchOutcome {
    pub fn touched(&self) -> u32 {
        self.path_count - self.failed()
    }

    pub fn failed(&self) -> u32 {
        self.failed_indices.len() as u32
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecodeError {
    ShortFrame,
    FrameTooLarge,
    UnsupportedVersion,
    TooManyPaths,
    InvalidOperationId,
    InvalidPath,
    TrailingData,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DedupeError {
    ConflictingOperationId,
    CapacityExhausted,
    ExecutionFailed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum ResponseStatus {
    Success = 0,
    ConflictingOperationId = 1,
    CapacityExhausted = 2,
    ExecutionFailed = 3,
}

/// A bounded, expiring exactly-once window for host-originated operations. An entry is installed
/// before its filesystem work begins, so concurrent deliveries of the same operation wait for and
/// reuse one result. Unexpired entries are never evicted: when the bounded window is full, new IDs
/// fail safely instead of making an earlier uncertain delivery executable a second time.
pub struct FSEventDedupeStore {
    capacity: usize,
    ttl: Duration,
    state: Mutex<DedupeState>,
    changed: Condvar,
}

#[derive(Default)]
struct DedupeState {
    entries: HashMap<u64, DedupeEntry>,
}

struct DedupeEntry {
    fingerprint: [u8; 32],
    expires_at: Instant,
    state: DedupeEntryState,
}

enum DedupeEntryState {
    InFlight,
    Complete(BatchOutcome),
    Failed,
}

impl FSEventDedupeStore {
    pub fn new(capacity: usize, ttl: Duration) -> Self {
        assert!(capacity > 0, "fsevent dedupe capacity must be non-zero");
        Self {
            capacity,
            ttl,
            state: Mutex::new(DedupeState::default()),
            changed: Condvar::new(),
        }
    }

    pub fn execute<F>(&self, batch: &DecodedBatch, work: F) -> Result<BatchOutcome, DedupeError>
    where
        F: FnOnce(&[PathBuf]) -> BatchOutcome,
    {
        let fingerprint = batch_fingerprint(&batch.paths);
        let mut work = Some(work);
        loop {
            let now = Instant::now();
            let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
            state.entries.retain(|_, entry| {
                matches!(entry.state, DedupeEntryState::InFlight) || entry.expires_at > now
            });

            if let Some(entry) = state.entries.get_mut(&batch.operation_id) {
                if entry.fingerprint != fingerprint {
                    return Err(DedupeError::ConflictingOperationId);
                }
                match &entry.state {
                    DedupeEntryState::Complete(outcome) => {
                        let outcome = outcome.clone();
                        entry.expires_at = now + self.ttl;
                        return Ok(outcome);
                    }
                    DedupeEntryState::Failed => return Err(DedupeError::ExecutionFailed),
                    DedupeEntryState::InFlight => {
                        drop(
                            self.changed
                                .wait(state)
                                .unwrap_or_else(|error| error.into_inner()),
                        );
                        continue;
                    }
                }
            }

            if state.entries.len() >= self.capacity {
                return Err(DedupeError::CapacityExhausted);
            }
            state.entries.insert(
                batch.operation_id,
                DedupeEntry {
                    fingerprint,
                    expires_at: now + self.ttl,
                    state: DedupeEntryState::InFlight,
                },
            );
            drop(state);

            let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                work.take().expect("fsevent work executes once")(&batch.paths)
            }));
            let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
            match outcome {
                Ok(outcome) => {
                    if let Some(entry) = state.entries.get_mut(&batch.operation_id) {
                        entry.expires_at = Instant::now() + self.ttl;
                        entry.state = DedupeEntryState::Complete(outcome.clone());
                    }
                    self.changed.notify_all();
                    return Ok(outcome);
                }
                Err(payload) => {
                    if let Some(entry) = state.entries.get_mut(&batch.operation_id) {
                        entry.expires_at = Instant::now() + self.ttl;
                        entry.state = DedupeEntryState::Failed;
                    }
                    self.changed.notify_all();
                    drop(state);
                    drop(payload);
                    return Err(DedupeError::ExecutionFailed);
                }
            }
        }
    }
}

impl Default for FSEventDedupeStore {
    fn default() -> Self {
        Self::new(DEFAULT_DEDUPE_CAPACITY, DEFAULT_DEDUPE_TTL)
    }
}

pub fn decode_batch_body(body: &[u8]) -> Result<DecodedBatch, DecodeError> {
    if body.len() > MAX_FRAME_BYTES {
        return Err(DecodeError::FrameTooLarge);
    }

    let mut cursor = 0;
    let version = take_u32(body, &mut cursor)?;
    if version != PROTOCOL_VERSION {
        return Err(DecodeError::UnsupportedVersion);
    }
    let operation_id = take_u64(body, &mut cursor)?;
    let count = take_u32(body, &mut cursor)? as usize;
    if count > MAX_PATHS {
        return Err(DecodeError::TooManyPaths);
    }
    if operation_id == 0 && count != 0 {
        return Err(DecodeError::InvalidOperationId);
    }

    let mut paths = Vec::with_capacity(count);
    for _ in 0..count {
        let length = take_u32(body, &mut cursor)? as usize;
        let end = cursor
            .checked_add(length)
            .filter(|end| *end <= body.len())
            .ok_or(DecodeError::InvalidPath)?;
        if length == 0 || length > MAX_PATH_BYTES {
            return Err(DecodeError::InvalidPath);
        }
        let value =
            std::str::from_utf8(&body[cursor..end]).map_err(|_| DecodeError::InvalidPath)?;
        cursor = end;
        if value.contains('\0') {
            return Err(DecodeError::InvalidPath);
        }
        let path = PathBuf::from(value);
        if !path.is_absolute()
            || path
                .components()
                .any(|component| matches!(component, Component::ParentDir))
        {
            return Err(DecodeError::InvalidPath);
        }
        paths.push(path);
    }
    if cursor != body.len() {
        return Err(DecodeError::TrailingData);
    }
    Ok(DecodedBatch {
        operation_id,
        paths,
    })
}

pub fn encode_batch_frame(operation_id: u64, paths: &[PathBuf]) -> Result<Vec<u8>, DecodeError> {
    if paths.len() > MAX_PATHS {
        return Err(DecodeError::TooManyPaths);
    }
    if operation_id == 0 && !paths.is_empty() {
        return Err(DecodeError::InvalidOperationId);
    }
    let mut body = Vec::new();
    body.extend_from_slice(&PROTOCOL_VERSION.to_le_bytes());
    body.extend_from_slice(&operation_id.to_le_bytes());
    body.extend_from_slice(&(paths.len() as u32).to_le_bytes());
    for path in paths {
        let bytes = path.as_os_str().as_bytes();
        if bytes.is_empty()
            || bytes.len() > MAX_PATH_BYTES
            || bytes.contains(&0)
            || !path.is_absolute()
            || path
                .components()
                .any(|component| matches!(component, Component::ParentDir))
        {
            return Err(DecodeError::InvalidPath);
        }
        let encoded_len = 4_usize
            .checked_add(bytes.len())
            .and_then(|length| body.len().checked_add(length))
            .ok_or(DecodeError::FrameTooLarge)?;
        if encoded_len > MAX_FRAME_BYTES {
            return Err(DecodeError::FrameTooLarge);
        }
        body.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
        body.extend_from_slice(bytes);
    }
    let mut frame = Vec::with_capacity(4 + body.len());
    frame.extend_from_slice(&(body.len() as u32).to_le_bytes());
    frame.extend_from_slice(&body);
    Ok(frame)
}

pub fn encode_response_frame(operation_id: u64, outcome: &BatchOutcome) -> Vec<u8> {
    debug_assert!(outcome.failed_indices.len() <= outcome.path_count as usize);
    debug_assert!(outcome
        .failed_indices
        .windows(2)
        .all(|indices| indices[0] < indices[1]));
    debug_assert!(outcome
        .failed_indices
        .iter()
        .all(|index| *index < outcome.path_count));
    encode_response(
        operation_id,
        outcome.path_count,
        ResponseStatus::Success,
        &outcome.failed_indices,
    )
}

pub fn encode_error_response_frame(
    operation_id: u64,
    path_count: u32,
    status: ResponseStatus,
) -> Vec<u8> {
    debug_assert_ne!(status, ResponseStatus::Success);
    encode_response(operation_id, path_count, status, &[])
}

fn encode_response(
    operation_id: u64,
    path_count: u32,
    status: ResponseStatus,
    failed_indices: &[u32],
) -> Vec<u8> {
    let body_len = 24_u32 + failed_indices.len() as u32 * 4;
    let mut frame = Vec::with_capacity(4 + body_len as usize);
    frame.extend_from_slice(&body_len.to_le_bytes());
    frame.extend_from_slice(&PROTOCOL_VERSION.to_le_bytes());
    frame.extend_from_slice(&operation_id.to_le_bytes());
    frame.extend_from_slice(&path_count.to_le_bytes());
    frame.extend_from_slice(&(status as u32).to_le_bytes());
    frame.extend_from_slice(&(failed_indices.len() as u32).to_le_bytes());
    for index in failed_indices {
        frame.extend_from_slice(&index.to_le_bytes());
    }
    frame
}

pub fn nudge_paths(paths: &[PathBuf]) -> BatchOutcome {
    let mut failed_indices = Vec::new();
    for (index, path) in paths.iter().enumerate() {
        if nudge_path_or_parent(path).is_err() {
            failed_indices.push(index as u32);
        }
    }
    BatchOutcome {
        path_count: paths.len() as u32,
        failed_indices,
    }
}

fn take_u32(body: &[u8], cursor: &mut usize) -> Result<u32, DecodeError> {
    let end = cursor.saturating_add(4);
    let bytes: [u8; 4] = body
        .get(*cursor..end)
        .ok_or(DecodeError::ShortFrame)?
        .try_into()
        .map_err(|_| DecodeError::ShortFrame)?;
    *cursor = end;
    Ok(u32::from_le_bytes(bytes))
}

fn take_u64(body: &[u8], cursor: &mut usize) -> Result<u64, DecodeError> {
    let end = cursor.saturating_add(8);
    let bytes: [u8; 8] = body
        .get(*cursor..end)
        .ok_or(DecodeError::ShortFrame)?
        .try_into()
        .map_err(|_| DecodeError::ShortFrame)?;
    *cursor = end;
    Ok(u64::from_le_bytes(bytes))
}

fn batch_fingerprint(paths: &[PathBuf]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update((paths.len() as u32).to_le_bytes());
    for path in paths {
        let bytes = path.as_os_str().as_bytes();
        hasher.update((bytes.len() as u32).to_le_bytes());
        hasher.update(bytes);
    }
    hasher.finalize().into()
}

fn nudge_path_or_parent(path: &Path) -> io::Result<()> {
    let mut candidate = Some(path);
    while let Some(current) = candidate {
        // Never turn an invalid/deleted event into a metadata update of the guest filesystem root.
        if current.parent().is_none() {
            break;
        }
        let mut stale_retries = 0;
        loop {
            match nudge_exact(current) {
                Ok(()) => return Ok(()),
                Err(error)
                    if error.raw_os_error() == Some(libc::ESTALE)
                        && stale_retries < NUDGE_STALE_RETRIES =>
                {
                    stale_retries += 1;
                    std::thread::sleep(NUDGE_STALE_RETRY_DELAY);
                }
                Err(error) if error.raw_os_error() == Some(libc::ESTALE) => {
                    // A deleted cached dentry can keep reopening its pinned unlinked inode until
                    // metadata validity expires. After the bounded exact-path chase, nudge the
                    // nearest live parent just like ENOENT instead of degrading coherence.
                    candidate = current.parent();
                    break;
                }
                Err(error)
                    if matches!(
                        error.raw_os_error(),
                        Some(libc::ENOENT) | Some(libc::ENOTDIR) | Some(libc::ELOOP)
                    ) =>
                {
                    candidate = current.parent();
                    break;
                }
                Err(error)
                    if matches!(error.raw_os_error(), Some(libc::EACCES) | Some(libc::EPERM)) =>
                {
                    // The host file may intentionally be write-only or mode 000. The macOS
                    // virtio-fs server runs as the owning desktop user, so Linux root cannot make
                    // an O_RDONLY open bypass those host permission bits. A write-only regular
                    // file is retried with O_WRONLY inside nudge_exact; if neither access mode is
                    // available, wake the nearest live directory watcher instead of retrying the
                    // same permanently failing file until coherence restarts the VM.
                    candidate = current.parent();
                    break;
                }
                Err(error) => return Err(error),
            }
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "event path and its safe parents do not exist",
    ))
}

fn nudge_exact(path: &Path) -> io::Result<()> {
    let c_path = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path contains NUL"))?;
    let metadata = std::fs::symlink_metadata(path)?;
    let access_modes = nudge_access_modes(metadata.permissions().mode());
    let mut fd = -1;
    let mut last_error = None;
    for access_mode in access_modes {
        fd = unsafe {
            libc::open(
                c_path.as_ptr(),
                access_mode | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
            )
        };
        if fd >= 0 {
            break;
        }
        let error = io::Error::last_os_error();
        let permission_error =
            matches!(error.raw_os_error(), Some(libc::EACCES) | Some(libc::EPERM));
        last_error = Some(error);
        if !permission_error {
            break;
        }
    }
    if fd < 0 {
        return Err(last_error.unwrap_or_else(io::Error::last_os_error));
    }

    let result = (|| {
        let mut info: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstat(fd, &mut info) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let kind = info.st_mode & libc::S_IFMT;
        if kind != libc::S_IFREG && kind != libc::S_IFDIR {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "only regular files and directories can be nudged",
            ));
        }
        // An atomic replacement can complete after LOOKUP but before OPEN, leaving this fd on the
        // unlinked old inode. fchmod there would not wake watches on the replacement pathname;
        // report a transient stale result so the bounded caller retries the exact path.
        if info.st_nlink == 0 {
            return Err(io::Error::from_raw_os_error(libc::ESTALE));
        }
        if unsafe { libc::fchmod(fd, info.st_mode & 0o7777) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    })();
    unsafe { libc::close(fd) };
    result
}

#[allow(clippy::unnecessary_cast)]
fn mode_bits(mode: libc::mode_t) -> u32 {
    // Darwin uses a narrower mode_t than Linux, while the sync protocol carries mode bits as u32.
    mode as u32
}

fn nudge_access_modes(mode: u32) -> [libc::c_int; 2] {
    let kind = mode & mode_bits(libc::S_IFMT);
    // A write-only host file cannot be reopened O_RDONLY by the unprivileged macOS VMM even when
    // Linux's caller is root. O_WRONLY without O_TRUNC is sufficient for same-mode fchmod. Keep
    // directories and ordinarily readable files on the read path first.
    if kind == mode_bits(libc::S_IFREG) && mode & 0o444 == 0 && mode & 0o222 != 0 {
        [libc::O_WRONLY, libc::O_RDONLY]
    } else {
        [libc::O_RDONLY, libc::O_WRONLY]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Barrier};

    fn unique_temp_dir() -> PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "dory-fsevents-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        directory
    }

    #[test]
    fn batch_codec_round_trips_absolute_utf8_paths() {
        let paths = vec![
            PathBuf::from("/work/src/a.ts"),
            PathBuf::from("/work/space b.ts"),
        ];
        let frame = encode_batch_frame(0x1020_3040_5060_7080, &paths).unwrap();
        let body_len = u32::from_le_bytes(frame[0..4].try_into().unwrap()) as usize;
        assert_eq!(body_len, frame.len() - 4);
        assert_eq!(
            decode_batch_body(&frame[4..]).unwrap(),
            DecodedBatch {
                operation_id: 0x1020_3040_5060_7080,
                paths
            }
        );
    }

    #[test]
    fn decoder_rejects_traversal_unknown_versions_and_trailing_data() {
        let traversal = encode_raw_body(PROTOCOL_VERSION, &["/work/../secret"]);
        assert_eq!(decode_batch_body(&traversal), Err(DecodeError::InvalidPath));

        let unknown = encode_raw_body(99, &["/work/a"]);
        assert_eq!(
            decode_batch_body(&unknown),
            Err(DecodeError::UnsupportedVersion)
        );

        let mut trailing = encode_raw_body(PROTOCOL_VERSION, &["/work/a"]);
        trailing.push(0);
        assert_eq!(decode_batch_body(&trailing), Err(DecodeError::TrailingData));
    }

    #[test]
    fn codec_enforces_batch_count_frame_and_path_limits() {
        assert_eq!(
            encode_batch_frame(0, &[PathBuf::from("/work/a")]),
            Err(DecodeError::InvalidOperationId)
        );
        assert!(encode_batch_frame(0, &[]).is_ok());

        let too_many_count = (MAX_PATHS as u32 + 1).to_le_bytes();
        let mut too_many = Vec::from(PROTOCOL_VERSION.to_le_bytes());
        too_many.extend_from_slice(&17_u64.to_le_bytes());
        too_many.extend_from_slice(&too_many_count);
        assert_eq!(decode_batch_body(&too_many), Err(DecodeError::TooManyPaths));

        let mut oversized_body = vec![0_u8; MAX_FRAME_BYTES + 1];
        oversized_body[0..4].copy_from_slice(&PROTOCOL_VERSION.to_le_bytes());
        assert_eq!(
            decode_batch_body(&oversized_body),
            Err(DecodeError::FrameTooLarge)
        );

        let oversized_path = PathBuf::from(format!("/{}", "a".repeat(MAX_PATH_BYTES)));
        assert_eq!(
            encode_batch_frame(1, &[oversized_path]),
            Err(DecodeError::InvalidPath)
        );

        let maximum_path = PathBuf::from(format!("/{}", "a".repeat(MAX_PATH_BYTES - 1)));
        assert!(encode_batch_frame(1, &[maximum_path]).is_ok());

        let wide_batch = vec![PathBuf::from(format!("/{}", "a".repeat(300))); MAX_PATHS];
        assert_eq!(
            encode_batch_frame(1, &wide_batch),
            Err(DecodeError::FrameTooLarge)
        );
    }

    #[test]
    fn nudge_preserves_mode_and_missing_child_uses_parent() {
        let directory = unique_temp_dir();
        let file = directory.join("watched.txt");
        std::fs::write(&file, b"unchanged").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o640)).unwrap();

        let outcome = nudge_paths(&[file.clone(), directory.join("deleted.txt")]);

        assert_eq!(
            outcome,
            BatchOutcome {
                path_count: 2,
                failed_indices: vec![]
            }
        );
        assert_eq!(outcome.touched(), 2);
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o7777,
            0o640
        );
        assert_eq!(std::fs::read(&file).unwrap(), b"unchanged");
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn nudge_write_only_file_uses_nontruncating_write_access_and_mode_zero_falls_back() {
        let directory = unique_temp_dir();
        let write_only = directory.join("write-only");
        let inaccessible = directory.join("inaccessible");
        std::fs::write(&write_only, b"preserved").unwrap();
        std::fs::write(&inaccessible, b"also-preserved").unwrap();
        std::fs::set_permissions(&write_only, std::fs::Permissions::from_mode(0o200)).unwrap();
        std::fs::set_permissions(&inaccessible, std::fs::Permissions::from_mode(0o000)).unwrap();

        assert_eq!(
            nudge_access_modes(mode_bits(libc::S_IFREG) | 0o200),
            [libc::O_WRONLY, libc::O_RDONLY]
        );
        let outcome = nudge_paths(&[write_only.clone(), inaccessible.clone()]);
        assert_eq!(outcome.failed_indices, Vec::<u32>::new());
        assert_eq!(
            std::fs::metadata(&write_only).unwrap().permissions().mode() & 0o7777,
            0o200
        );
        assert_eq!(
            std::fs::metadata(&inaccessible)
                .unwrap()
                .permissions()
                .mode()
                & 0o7777,
            0o000
        );

        std::fs::set_permissions(&write_only, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::set_permissions(&inaccessible, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(std::fs::read(&write_only).unwrap(), b"preserved");
        assert_eq!(std::fs::read(&inaccessible).unwrap(), b"also-preserved");
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn response_frame_carries_operation_path_count_and_failed_indices() {
        let frame = encode_response_frame(
            0x0102_0304_0506_0708,
            &BatchOutcome {
                path_count: 7,
                failed_indices: vec![1, 5],
            },
        );
        assert_eq!(frame.len(), 36);
        assert_eq!(u32::from_le_bytes(frame[0..4].try_into().unwrap()), 32);
        assert_eq!(
            u32::from_le_bytes(frame[4..8].try_into().unwrap()),
            PROTOCOL_VERSION
        );
        assert_eq!(
            u64::from_le_bytes(frame[8..16].try_into().unwrap()),
            0x0102_0304_0506_0708
        );
        assert_eq!(u32::from_le_bytes(frame[16..20].try_into().unwrap()), 7);
        assert_eq!(u32::from_le_bytes(frame[20..24].try_into().unwrap()), 0);
        assert_eq!(u32::from_le_bytes(frame[24..28].try_into().unwrap()), 2);
        assert_eq!(u32::from_le_bytes(frame[28..32].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(frame[32..36].try_into().unwrap()), 5);

        let rejected = encode_error_response_frame(
            0x0102_0304_0506_0708,
            7,
            ResponseStatus::ConflictingOperationId,
        );
        assert_eq!(rejected.len(), 28);
        assert_eq!(u32::from_le_bytes(rejected[0..4].try_into().unwrap()), 24);
        assert_eq!(u32::from_le_bytes(rejected[20..24].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(rejected[24..28].try_into().unwrap()), 0);
    }

    #[test]
    fn dedupe_reuses_completed_response_without_reexecuting_work() {
        let store = FSEventDedupeStore::new(4, Duration::from_secs(1));
        let batch = DecodedBatch {
            operation_id: 41,
            paths: vec![PathBuf::from("/work/a"), PathBuf::from("/work/b")],
        };
        let executions = AtomicUsize::new(0);
        let expected = BatchOutcome {
            path_count: 2,
            failed_indices: vec![1],
        };

        let first = store
            .execute(&batch, |_| {
                executions.fetch_add(1, Ordering::SeqCst);
                expected.clone()
            })
            .unwrap();
        let repeated = store
            .execute(&batch, |_| {
                executions.fetch_add(1, Ordering::SeqCst);
                BatchOutcome {
                    path_count: 2,
                    failed_indices: vec![],
                }
            })
            .unwrap();

        assert_eq!(first, expected);
        assert_eq!(repeated, expected);
        assert_eq!(executions.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn concurrent_duplicate_waits_for_and_reuses_inflight_result() {
        let store = Arc::new(FSEventDedupeStore::new(4, Duration::from_secs(1)));
        let batch = DecodedBatch {
            operation_id: 99,
            paths: vec![PathBuf::from("/work/a")],
        };
        let executions = Arc::new(AtomicUsize::new(0));
        let start = Arc::new(Barrier::new(3));
        let mut workers = Vec::new();
        for _ in 0..2 {
            let store = Arc::clone(&store);
            let batch = batch.clone();
            let executions = Arc::clone(&executions);
            let start = Arc::clone(&start);
            workers.push(std::thread::spawn(move || {
                start.wait();
                store
                    .execute(&batch, |_| {
                        executions.fetch_add(1, Ordering::SeqCst);
                        std::thread::sleep(Duration::from_millis(25));
                        BatchOutcome {
                            path_count: 1,
                            failed_indices: vec![],
                        }
                    })
                    .unwrap()
            }));
        }
        start.wait();
        let outcomes: Vec<_> = workers
            .into_iter()
            .map(|worker| worker.join().unwrap())
            .collect();

        assert_eq!(outcomes[0], outcomes[1]);
        assert_eq!(executions.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn dedupe_rejects_id_reuse_for_another_batch_and_expires_bounded_entries() {
        let store = FSEventDedupeStore::new(1, Duration::from_millis(10));
        let first = DecodedBatch {
            operation_id: 5,
            paths: vec![PathBuf::from("/work/a")],
        };
        let conflict = DecodedBatch {
            operation_id: 5,
            paths: vec![PathBuf::from("/work/b")],
        };
        let next = DecodedBatch {
            operation_id: 6,
            paths: vec![PathBuf::from("/work/b")],
        };
        let outcome = BatchOutcome {
            path_count: 1,
            failed_indices: vec![],
        };
        store.execute(&first, |_| outcome.clone()).unwrap();
        assert_eq!(
            store.execute(&conflict, |_| outcome.clone()),
            Err(DedupeError::ConflictingOperationId)
        );
        assert_eq!(
            store.execute(&next, |_| outcome.clone()),
            Err(DedupeError::CapacityExhausted)
        );

        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(store.execute(&next, |_| outcome.clone()).unwrap(), outcome);
    }

    fn encode_raw_body(version: u32, paths: &[&str]) -> Vec<u8> {
        let mut body = Vec::new();
        body.extend_from_slice(&version.to_le_bytes());
        body.extend_from_slice(&42_u64.to_le_bytes());
        body.extend_from_slice(&(paths.len() as u32).to_le_bytes());
        for path in paths {
            body.extend_from_slice(&(path.len() as u32).to_le_bytes());
            body.extend_from_slice(path.as_bytes());
        }
        body
    }
}
