//! Shared scaffolding for the Linux scan and repair tests: a self-cleaning temporary volume plus
//! the raw filesystem primitives the manifest contract has to describe.

use std::ffi::CString;
use std::fs;
use std::io::{Seek, SeekFrom, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

static COUNTER: AtomicU32 = AtomicU32::new(0);

/// Temporary volumes live in `TMPDIR` when that filesystem can hold user xattrs, and under the
/// build directory otherwise: tmpfs rejects `user.*` xattrs on older kernels, and the manifest
/// contract covers xattrs.
fn base_directory() -> PathBuf {
    let candidate = std::env::temp_dir();
    #[allow(clippy::disallowed_names)]
    let probe = candidate.join(format!("dory-xattr-probe-{}", std::process::id()));
    let supported = fs::File::create(&probe)
        .map(|_| try_set_xattr(&probe, "user.dory-probe", b"1"))
        .unwrap_or(false);
    let _ = fs::remove_file(&probe);
    if supported {
        candidate
    } else {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../target/dory-transfer-tests")
    }
}

pub struct TempRoot {
    path: PathBuf,
}

impl Default for TempRoot {
    fn default() -> Self {
        Self::new()
    }
}

impl TempRoot {
    /// The name stays short because tests bind Unix sockets inside the volume, and `sockaddr_un`
    /// paths are limited to 108 bytes.
    pub fn new() -> Self {
        let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
        let base = base_directory();
        fs::create_dir_all(&base).expect("create temporary volume base");
        let path = base.join(format!("v{}-{unique}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).expect("create temporary volume");
        fs::set_permissions(&path, permissions(0o755)).expect("set root mode");
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn join(&self, relative: &str) -> PathBuf {
        self.path.join(relative)
    }
}

impl Drop for TempRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

pub fn permissions(mode: u32) -> fs::Permissions {
    use std::os::unix::fs::PermissionsExt;
    fs::Permissions::from_mode(mode)
}

pub fn write_file(path: &Path, contents: &[u8]) {
    fs::write(path, contents).expect("write file");
}

pub fn write_sparse_file(path: &Path, hole_bytes: u64, tail: &[u8]) {
    let mut file = fs::File::create(path).expect("create sparse file");
    file.seek(SeekFrom::Start(hole_bytes)).expect("seek hole");
    file.write_all(tail).expect("write sparse tail");
    file.sync_all().expect("sync sparse file");
}

pub fn make_fifo(path: &Path) {
    let raw = CString::new(path.as_os_str().as_bytes()).expect("fifo path has no nul");
    let result = unsafe { libc::mkfifo(raw.as_ptr(), 0o644) };
    assert_eq!(
        result,
        0,
        "mkfifo failed: {}",
        std::io::Error::last_os_error()
    );
}

/// Returns false when the filesystem backing the temporary volume rejects user xattrs, which
/// happens on older tmpfs kernels. Callers skip their xattr assertions in that case.
pub fn try_set_xattr(path: &Path, name: &str, value: &[u8]) -> bool {
    let raw_path = CString::new(path.as_os_str().as_bytes()).expect("xattr path has no nul");
    let raw_name = CString::new(name).expect("xattr name has no nul");
    let result = unsafe {
        libc::lsetxattr(
            raw_path.as_ptr(),
            raw_name.as_ptr(),
            value.as_ptr().cast::<libc::c_void>(),
            value.len(),
            0,
        )
    };
    result == 0
}
