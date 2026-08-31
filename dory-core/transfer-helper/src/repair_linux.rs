use crate::{
    hex_decode, ManifestEntry, ManifestEntryKind, ManifestLimits, TransferHelperError,
    VolumeManifest, XattrEntry,
};
use std::collections::BTreeMap;
use std::ffi::{CString, OsStr};
use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

pub fn repair_volume(
    root: &Path,
    source: &VolumeManifest,
    limits: ManifestLimits,
) -> Result<VolumeManifest, TransferHelperError> {
    source.validate(limits)?;
    if source.contains_device_nodes() {
        return Err(TransferHelperError::Unsupported(
            "device-node transfer is not enabled by the Apple Silicon launch policy".into(),
        ));
    }

    let expected = source.normalized_target();
    let before = crate::scan_linux::scan_volume(root, limits)?;
    verify_transport_content(&expected, &before)?;

    apply_ownership(root, &expected)?;
    restore_sparse_layout(root, &expected)?;
    apply_modes(root, &expected)?;
    apply_xattrs(root, &expected, limits)?;
    apply_timestamps(root, &expected)?;
    sync_volume(root)?;

    let after = crate::scan_linux::scan_volume(root, limits)?;
    if after != expected {
        return Err(TransferHelperError::Verification(first_exact_mismatch(
            &expected, &after,
        )));
    }
    Ok(after)
}

fn verify_transport_content(
    expected: &VolumeManifest,
    actual: &VolumeManifest,
) -> Result<(), TransferHelperError> {
    if expected.entries.len() != actual.entries.len() {
        return verification(format!(
            "archive path set differs: expected {} entries, found {}",
            expected.entries.len(),
            actual.entries.len()
        ));
    }

    for (expected_entry, actual_entry) in expected.entries.iter().zip(&actual.entries) {
        if expected_entry.path_hex != actual_entry.path_hex {
            return verification(format!(
                "archive path set differs at expected hex:{} and actual hex:{}",
                expected_entry.path_hex, actual_entry.path_hex
            ));
        }
        if expected_entry.kind != actual_entry.kind {
            return verification(format!(
                "hex:{} changed type from {:?} to {:?}",
                expected_entry.path_hex, expected_entry.kind, actual_entry.kind
            ));
        }
        let matches = match expected_entry.kind {
            ManifestEntryKind::RegularFile => {
                expected_entry.size == actual_entry.size
                    && expected_entry.content_sha256 == actual_entry.content_sha256
            }
            ManifestEntryKind::SymbolicLink => {
                expected_entry.size == actual_entry.size
                    && expected_entry.link_target_hex == actual_entry.link_target_hex
            }
            ManifestEntryKind::HardLink => {
                expected_entry.size == actual_entry.size
                    && expected_entry.hard_link_target_hex == actual_entry.hard_link_target_hex
            }
            ManifestEntryKind::BlockDevice | ManifestEntryKind::CharacterDevice => {
                expected_entry.device_major == actual_entry.device_major
                    && expected_entry.device_minor == actual_entry.device_minor
            }
            ManifestEntryKind::Directory | ManifestEntryKind::Fifo | ManifestEntryKind::Socket => {
                true
            }
        };
        if !matches {
            return verification(format!(
                "archive content differs at hex:{}",
                expected_entry.path_hex
            ));
        }
    }
    Ok(())
}

fn apply_ownership(root: &Path, manifest: &VolumeManifest) -> Result<(), TransferHelperError> {
    for entry in all_entries(manifest) {
        let path = manifest_path(root, entry)?;
        let c_path = path_c_string(&path)?;
        let result = unsafe { libc::lchown(c_path.as_ptr(), entry.uid, entry.gid) };
        if result != 0 {
            return Err(filesystem_error(&path, std::io::Error::last_os_error()));
        }
    }
    Ok(())
}

fn restore_sparse_layout(
    root: &Path,
    manifest: &VolumeManifest,
) -> Result<(), TransferHelperError> {
    for entry in &manifest.entries {
        if entry.kind != ManifestEntryKind::RegularFile {
            continue;
        }
        let path = manifest_path(root, entry)?;
        let file = OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&path)
            .map_err(|source| filesystem_error(&path, source))?;
        let extents = entry.sparse_data_extents.as_deref().ok_or_else(|| {
            TransferHelperError::InvalidManifest(format!(
                "hex:{} has no sparse extent proof",
                entry.path_hex
            ))
        })?;
        let mut cursor = 0_u64;
        for extent in extents {
            if cursor < extent.offset {
                punch_hole(&file, cursor, extent.offset - cursor, &path)?;
            }
            cursor = extent.offset + extent.length;
        }
        if cursor < entry.size {
            punch_hole(&file, cursor, entry.size - cursor, &path)?;
        }
        file.sync_all()
            .map_err(|source| filesystem_error(&path, source))?;
    }
    Ok(())
}

fn punch_hole(
    file: &File,
    offset: u64,
    length: u64,
    path: &Path,
) -> Result<(), TransferHelperError> {
    if length == 0 {
        return Ok(());
    }
    let offset = libc::off_t::try_from(offset).map_err(|_| {
        TransferHelperError::Unsupported(format!(
            "{} has a sparse offset outside off_t",
            path.display()
        ))
    })?;
    let length = libc::off_t::try_from(length).map_err(|_| {
        TransferHelperError::Unsupported(format!(
            "{} has a sparse length outside off_t",
            path.display()
        ))
    })?;
    let result = unsafe {
        libc::fallocate(
            file.as_raw_fd(),
            libc::FALLOC_FL_PUNCH_HOLE | libc::FALLOC_FL_KEEP_SIZE,
            offset,
            length,
        )
    };
    if result != 0 {
        let error = std::io::Error::last_os_error();
        return match error.raw_os_error() {
            Some(libc::EOPNOTSUPP) | Some(libc::ENOSYS) | Some(libc::EINVAL) => {
                Err(TransferHelperError::Unsupported(format!(
                    "{} cannot restore sparse holes: {error}",
                    path.display()
                )))
            }
            _ => Err(filesystem_error(path, error)),
        };
    }
    Ok(())
}

fn apply_modes(root: &Path, manifest: &VolumeManifest) -> Result<(), TransferHelperError> {
    for entry in all_entries(manifest) {
        if entry.kind == ManifestEntryKind::SymbolicLink {
            continue;
        }
        let path = manifest_path(root, entry)?;
        let c_path = path_c_string(&path)?;
        let result = unsafe { libc::chmod(c_path.as_ptr(), entry.mode) };
        if result != 0 {
            return Err(filesystem_error(&path, std::io::Error::last_os_error()));
        }
    }
    Ok(())
}

fn apply_xattrs(
    root: &Path,
    manifest: &VolumeManifest,
    limits: ManifestLimits,
) -> Result<(), TransferHelperError> {
    for entry in all_entries(manifest) {
        let path = manifest_path(root, entry)?;
        let c_path = path_c_string(&path)?;
        let expected = entry
            .xattrs
            .iter()
            .map(|xattr| Ok((hex_decode(&xattr.name_hex)?, xattr)))
            .collect::<Result<BTreeMap<Vec<u8>, &XattrEntry>, TransferHelperError>>()?;
        let actual = list_xattrs(&c_path, &path, limits)?;

        for name in actual {
            if expected.contains_key(&name) {
                continue;
            }
            let c_name = CString::new(name).map_err(|_| {
                TransferHelperError::InvalidManifest(format!(
                    "{} returned a NUL-containing xattr name",
                    path.display()
                ))
            })?;
            let result = unsafe { libc::lremovexattr(c_path.as_ptr(), c_name.as_ptr()) };
            if result != 0 {
                return Err(filesystem_error(&path, std::io::Error::last_os_error()));
            }
        }

        for (name, xattr) in expected {
            let value = hex_decode(&xattr.value_hex)?;
            let c_name = CString::new(name).map_err(|_| {
                TransferHelperError::InvalidManifest(format!(
                    "{} contains a NUL-containing xattr name",
                    path.display()
                ))
            })?;
            let result = unsafe {
                libc::lsetxattr(
                    c_path.as_ptr(),
                    c_name.as_ptr(),
                    value.as_ptr().cast::<libc::c_void>(),
                    value.len(),
                    0,
                )
            };
            if result != 0 {
                return Err(filesystem_error(&path, std::io::Error::last_os_error()));
            }
        }
    }
    Ok(())
}

fn apply_timestamps(root: &Path, manifest: &VolumeManifest) -> Result<(), TransferHelperError> {
    let mut entries = manifest
        .entries
        .iter()
        .map(|entry| {
            let depth = hex_decode(&entry.path_hex)?
                .iter()
                .filter(|byte| **byte == b'/')
                .count();
            Ok((entry, depth))
        })
        .collect::<Result<Vec<_>, TransferHelperError>>()?;
    entries.sort_by(|(left, left_depth), (right, right_depth)| {
        let left_directory = left.kind == ManifestEntryKind::Directory;
        let right_directory = right.kind == ManifestEntryKind::Directory;
        left_directory
            .cmp(&right_directory)
            .then_with(|| right_depth.cmp(left_depth))
            .then_with(|| left.path_hex.cmp(&right.path_hex))
    });
    for entry in entries
        .into_iter()
        .map(|(entry, _)| entry)
        .chain(std::iter::once(&manifest.root))
    {
        let path = manifest_path(root, entry)?;
        let c_path = path_c_string(&path)?;
        let times = [
            libc::timespec {
                tv_sec: entry.mtime_seconds,
                tv_nsec: entry.mtime_nanoseconds.into(),
            },
            libc::timespec {
                tv_sec: entry.mtime_seconds,
                tv_nsec: entry.mtime_nanoseconds.into(),
            },
        ];
        let result = unsafe {
            libc::utimensat(
                libc::AT_FDCWD,
                c_path.as_ptr(),
                times.as_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        };
        if result != 0 {
            return Err(filesystem_error(&path, std::io::Error::last_os_error()));
        }
    }
    Ok(())
}

fn sync_volume(root: &Path) -> Result<(), TransferHelperError> {
    let directory = File::open(root).map_err(|source| filesystem_error(root, source))?;
    directory
        .sync_all()
        .map_err(|source| filesystem_error(root, source))?;
    let result = unsafe { libc::syncfs(directory.as_raw_fd()) };
    if result != 0 {
        return Err(filesystem_error(root, std::io::Error::last_os_error()));
    }
    Ok(())
}

fn all_entries(manifest: &VolumeManifest) -> impl Iterator<Item = &ManifestEntry> {
    std::iter::once(&manifest.root).chain(manifest.entries.iter())
}

fn manifest_path(root: &Path, entry: &ManifestEntry) -> Result<PathBuf, TransferHelperError> {
    if entry.path_hex.is_empty() {
        return Ok(root.to_path_buf());
    }
    let raw = hex_decode(&entry.path_hex)?;
    let mut result = root.to_path_buf();
    for component in raw.split(|byte| *byte == b'/') {
        result.push(OsStr::from_bytes(component));
    }
    Ok(result)
}

fn list_xattrs(
    c_path: &CString,
    path: &Path,
    limits: ManifestLimits,
) -> Result<Vec<Vec<u8>>, TransferHelperError> {
    for _ in 0..3 {
        let needed = unsafe { libc::llistxattr(c_path.as_ptr(), std::ptr::null_mut(), 0) };
        if needed < 0 {
            return Err(filesystem_error(path, std::io::Error::last_os_error()));
        }
        if needed == 0 {
            return Ok(vec![]);
        }
        let mut buffer = vec![0_u8; needed as usize];
        let count = unsafe {
            libc::llistxattr(
                c_path.as_ptr(),
                buffer.as_mut_ptr().cast::<libc::c_char>(),
                buffer.len(),
            )
        };
        if count < 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ERANGE) {
                continue;
            }
            return Err(filesystem_error(path, error));
        }
        buffer.truncate(count as usize);
        if buffer.last() != Some(&0) {
            return Err(TransferHelperError::Verification(format!(
                "{} returned a malformed xattr list",
                path.display()
            )));
        }
        let mut names = buffer[..buffer.len() - 1]
            .split(|byte| *byte == 0)
            .map(<[u8]>::to_vec)
            .collect::<Vec<_>>();
        names.sort();
        if names.len() > limits.maximum_xattrs_per_entry {
            return Err(TransferHelperError::Limit(format!(
                "{} has more than {} target xattrs",
                path.display(),
                limits.maximum_xattrs_per_entry
            )));
        }
        if names.windows(2).any(|pair| pair[0] == pair[1]) {
            return Err(TransferHelperError::Verification(format!(
                "{} returned duplicate xattr names",
                path.display()
            )));
        }
        return Ok(names);
    }
    Err(TransferHelperError::SourceDrift(format!(
        "{} target xattr list changed repeatedly",
        path.display()
    )))
}

fn first_exact_mismatch(expected: &VolumeManifest, actual: &VolumeManifest) -> String {
    if expected.root != actual.root {
        return "target root metadata does not match the source manifest".into();
    }
    for (left, right) in expected.entries.iter().zip(&actual.entries) {
        if left != right {
            return format!("target differs at hex:{}", left.path_hex);
        }
    }
    format!(
        "target entry count differs: expected {}, found {}",
        expected.entries.len(),
        actual.entries.len()
    )
}

fn path_c_string(path: &Path) -> Result<CString, TransferHelperError> {
    CString::new(path.as_os_str().as_bytes()).map_err(|_| {
        TransferHelperError::InvalidManifest(format!("{} contains an embedded NUL", path.display()))
    })
}

fn verification<T>(message: String) -> Result<T, TransferHelperError> {
    Err(TransferHelperError::Verification(message))
}

fn filesystem_error(path: &Path, source: std::io::Error) -> TransferHelperError {
    TransferHelperError::Filesystem {
        path: format!("hex:{}", crate::hex_encode(path.as_os_str().as_bytes())),
        source,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{make_fifo, permissions, try_set_xattr, write_file, TempRoot};
    use crate::{hex_encode, DataExtent};
    use sha2::{Digest, Sha256};
    use std::fs;

    fn limits() -> ManifestLimits {
        ManifestLimits::default()
    }

    /// The archive transport reproduces names and bytes; modes, ownership, xattrs, and timestamps
    /// are what `repair_volume` has to converge. `decorate` therefore only varies metadata.
    fn build_volume(volume: &TempRoot, decorate: bool) {
        fs::create_dir(volume.join("dir")).unwrap();
        write_file(&volume.join("dir/file"), b"payload");
        fs::hard_link(volume.join("dir/file"), volume.join("dir/link")).unwrap();
        std::os::unix::fs::symlink("dir/file", volume.join("symlink")).unwrap();
        make_fifo(&volume.join("pipe"));
        if decorate {
            fs::set_permissions(volume.join("dir"), permissions(0o750)).unwrap();
            fs::set_permissions(volume.join("dir/file"), permissions(0o640)).unwrap();
            fs::set_permissions(volume.join("pipe"), permissions(0o600)).unwrap();
            let _ = try_set_xattr(&volume.join("dir/file"), "user.source", b"kept");
        } else {
            fs::set_permissions(volume.join("dir"), permissions(0o700)).unwrap();
            fs::set_permissions(volume.join("dir/file"), permissions(0o600)).unwrap();
            let _ = try_set_xattr(&volume.join("dir/file"), "user.stale", b"removed");
        }
    }

    fn entry(path: &str, kind: ManifestEntryKind) -> ManifestEntry {
        ManifestEntry {
            path_hex: hex_encode(path.as_bytes()),
            kind,
            mode: 0o644,
            uid: unsafe { libc::getuid() },
            gid: unsafe { libc::getgid() },
            size: 0,
            mtime_seconds: 1,
            mtime_nanoseconds: 2,
            content_sha256: None,
            link_target_hex: None,
            hard_link_target_hex: None,
            sparse_data_extents: None,
            device_major: None,
            device_minor: None,
            xattrs: vec![],
        }
    }

    fn root_entry() -> ManifestEntry {
        let mut value = entry("", ManifestEntryKind::Directory);
        value.mode = 0o755;
        value
    }

    #[test]
    fn repair_converges_the_target_onto_the_source_manifest() {
        let source = TempRoot::new();
        build_volume(&source, true);
        let expected = crate::scan_volume(source.path(), limits()).unwrap();

        let target = TempRoot::new();
        build_volume(&target, false);
        fs::set_permissions(target.path(), permissions(0o700)).unwrap();

        let repaired = repair_volume(target.path(), &expected, limits()).unwrap();
        assert_eq!(repaired, expected.normalized_target());
        assert_eq!(
            crate::scan_volume(target.path(), limits()).unwrap(),
            expected
        );
        assert_eq!(
            repaired.canonical_sha256(limits()).unwrap(),
            expected.canonical_sha256(limits()).unwrap()
        );
    }

    #[test]
    fn repair_restores_sparse_holes_for_regular_files() {
        let target = TempRoot::new();
        let path = target.join("sparse");
        write_file(&path, &vec![0_u8; 512 * 1024]);

        let mut file = entry("sparse", ManifestEntryKind::RegularFile);
        file.size = 512 * 1024;
        file.content_sha256 = Some(hex_encode(&Sha256::digest(vec![0_u8; 512 * 1024])));
        file.sparse_data_extents = Some(vec![]);
        let manifest = VolumeManifest::new(root_entry(), vec![file]);

        let repaired = repair_volume(target.path(), &manifest, limits()).unwrap();
        let entry = &repaired.entries[0];
        assert_eq!(entry.size, 512 * 1024);
        assert_eq!(entry.sparse_data_extents.as_deref(), Some(&[][..]));
        assert_eq!(fs::read(&path).unwrap(), vec![0_u8; 512 * 1024]);
    }

    #[test]
    fn sockets_in_the_source_are_excluded_from_the_repaired_target() {
        let source = TempRoot::new();
        write_file(&source.join("file"), b"payload");
        let listener = std::os::unix::net::UnixListener::bind(source.join("service.sock")).unwrap();
        let manifest = crate::scan_volume(source.path(), limits()).unwrap();
        drop(listener);
        assert_eq!(manifest.socket_paths().len(), 1);

        let target = TempRoot::new();
        write_file(&target.join("file"), b"payload");

        let repaired = repair_volume(target.path(), &manifest, limits()).unwrap();
        assert_eq!(repaired.entries.len(), 1);
        assert!(repaired.socket_paths().is_empty());
    }

    #[test]
    fn device_nodes_are_refused_by_the_launch_policy() {
        let target = TempRoot::new();
        let mut device = entry("device", ManifestEntryKind::CharacterDevice);
        device.device_major = Some(1);
        device.device_minor = Some(3);
        let manifest = VolumeManifest::new(root_entry(), vec![device]);

        assert!(matches!(
            repair_volume(target.path(), &manifest, limits()),
            Err(TransferHelperError::Unsupported(_))
        ));
    }

    #[test]
    fn an_invalid_source_manifest_never_touches_the_target() {
        let target = TempRoot::new();
        let mut broken = root_entry();
        broken.mtime_nanoseconds = 1_000_000_000;
        let manifest = VolumeManifest::new(broken, vec![]);
        assert!(matches!(
            repair_volume(target.path(), &manifest, limits()),
            Err(TransferHelperError::InvalidManifest(_))
        ));
    }

    #[test]
    fn transport_verification_rejects_missing_extra_and_altered_paths() {
        let target = TempRoot::new();
        write_file(&target.join("file"), b"payload");

        let mut file = entry("file", ManifestEntryKind::RegularFile);
        file.size = 7;
        file.content_sha256 = Some(hex_encode(&Sha256::digest(b"payload")));
        file.sparse_data_extents = Some(vec![DataExtent {
            offset: 0,
            length: 7,
        }]);

        let mut extra = entry("absent", ManifestEntryKind::Directory);
        extra.mode = 0o755;
        let too_many = VolumeManifest::new(root_entry(), vec![file.clone(), extra]);
        assert!(matches!(
            repair_volume(target.path(), &too_many, limits()),
            Err(TransferHelperError::Verification(_))
        ));

        let mut renamed = file.clone();
        renamed.path_hex = hex_encode(b"other");
        let wrong_path = VolumeManifest::new(root_entry(), vec![renamed]);
        assert!(matches!(
            repair_volume(target.path(), &wrong_path, limits()),
            Err(TransferHelperError::Verification(_))
        ));

        let mut wrong_kind = file.clone();
        wrong_kind.kind = ManifestEntryKind::Fifo;
        wrong_kind.size = 0;
        wrong_kind.content_sha256 = None;
        wrong_kind.sparse_data_extents = None;
        let wrong_kind = VolumeManifest::new(root_entry(), vec![wrong_kind]);
        assert!(matches!(
            repair_volume(target.path(), &wrong_kind, limits()),
            Err(TransferHelperError::Verification(_))
        ));

        let mut wrong_content = file;
        wrong_content.content_sha256 = Some(hex_encode(&Sha256::digest(b"different")));
        let wrong_content = VolumeManifest::new(root_entry(), vec![wrong_content]);
        assert!(matches!(
            repair_volume(target.path(), &wrong_content, limits()),
            Err(TransferHelperError::Verification(_))
        ));
    }

    #[test]
    fn symbolic_and_hard_link_targets_are_verified_against_the_target() {
        let target = TempRoot::new();
        write_file(&target.join("file"), b"payload");
        std::os::unix::fs::symlink("file", target.join("symlink")).unwrap();
        fs::hard_link(target.join("file"), target.join("linked")).unwrap();

        let observed = crate::scan_volume(target.path(), limits()).unwrap();
        let mut drifted = observed.clone();
        for entry in &mut drifted.entries {
            match entry.kind {
                ManifestEntryKind::SymbolicLink => {
                    entry.link_target_hex = Some(hex_encode(b"other"));
                    entry.size = 5;
                }
                ManifestEntryKind::HardLink => {
                    entry.hard_link_target_hex = Some(hex_encode(b"absent"));
                }
                _ => {}
            }
        }
        assert!(matches!(
            verify_transport_content(&drifted, &observed),
            Err(TransferHelperError::Verification(_))
        ));
        verify_transport_content(&observed, &observed).unwrap();
    }

    #[test]
    fn manifest_paths_decode_byte_components_under_the_root() {
        let root = Path::new("/volume");
        assert_eq!(
            manifest_path(root, &root_entry()).unwrap(),
            Path::new("/volume")
        );
        let nested = entry("dir/file", ManifestEntryKind::Directory);
        assert_eq!(
            manifest_path(root, &nested).unwrap(),
            Path::new("/volume/dir/file")
        );
        let mut invalid = nested;
        invalid.path_hex = "abc".into();
        assert!(matches!(
            manifest_path(root, &invalid),
            Err(TransferHelperError::InvalidManifest(_))
        ));
    }

    #[test]
    fn exact_mismatch_reports_the_first_differing_entry() {
        let file = {
            let mut value = entry("file", ManifestEntryKind::RegularFile);
            value.size = 7;
            value.content_sha256 = Some(hex_encode(&Sha256::digest(b"payload")));
            value.sparse_data_extents = Some(vec![DataExtent {
                offset: 0,
                length: 7,
            }]);
            value
        };
        let expected = VolumeManifest::new(root_entry(), vec![file.clone()]);

        let mut different_root = expected.clone();
        different_root.root.mode = 0o700;
        assert_eq!(
            first_exact_mismatch(&expected, &different_root),
            "target root metadata does not match the source manifest"
        );

        let mut different_entry = expected.clone();
        different_entry.entries[0].mode = 0o600;
        assert_eq!(
            first_exact_mismatch(&expected, &different_entry),
            format!("target differs at hex:{}", file.path_hex)
        );

        let empty = VolumeManifest::new(root_entry(), vec![]);
        assert_eq!(
            first_exact_mismatch(&expected, &empty),
            "target entry count differs: expected 1, found 0"
        );
    }

    #[test]
    fn punching_a_zero_length_hole_is_a_no_op() {
        let target = TempRoot::new();
        let path = target.join("file");
        write_file(&path, b"payload");
        let file = fs::OpenOptions::new().write(true).open(&path).unwrap();
        punch_hole(&file, 0, 0, &path).unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"payload");
    }
}
