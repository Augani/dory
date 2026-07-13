use crate::{
    hex_encode, DataExtent, ManifestEntry, ManifestEntryKind, ManifestLimits, TransferHelperError,
    VolumeManifest, XattrEntry,
};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::ffi::{CString, OsStr};
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt};
use std::path::Path;

type InodeIdentity = (u64, u64);

pub fn scan_volume(
    root: &Path,
    limits: ManifestLimits,
) -> Result<VolumeManifest, TransferHelperError> {
    let root_metadata =
        fs::symlink_metadata(root).map_err(|source| filesystem_error(root, source))?;
    if !root_metadata.file_type().is_dir() {
        return Err(TransferHelperError::InvalidManifest(
            "scan root is not a directory".into(),
        ));
    }

    let mut seen_regular_inodes = HashMap::<InodeIdentity, String>::new();
    let root_entry = entry_for(root, &[], &root_metadata, &mut seen_regular_inodes, limits)?;
    let mut entries = Vec::new();
    walk_directory(root, &[], &mut seen_regular_inodes, &mut entries, limits)?;
    let manifest = VolumeManifest::new(root_entry, entries);
    manifest.validate(limits)?;
    Ok(manifest)
}

fn walk_directory(
    directory: &Path,
    relative: &[u8],
    seen_regular_inodes: &mut HashMap<InodeIdentity, String>,
    output: &mut Vec<ManifestEntry>,
    limits: ManifestLimits,
) -> Result<(), TransferHelperError> {
    let mut children = fs::read_dir(directory)
        .map_err(|source| filesystem_error(directory, source))?
        .map(|result| result.map_err(|source| filesystem_error(directory, source)))
        .collect::<Result<Vec<_>, _>>()?;
    children.sort_by(|left, right| {
        left.file_name()
            .as_bytes()
            .cmp(right.file_name().as_bytes())
    });

    for child in children {
        let name = child.file_name();
        let name_bytes = name.as_bytes();
        if name_bytes.is_empty() || name_bytes.contains(&b'/') || name_bytes.contains(&0) {
            return Err(TransferHelperError::InvalidManifest(
                "filesystem returned an invalid directory entry name".into(),
            ));
        }
        let child_relative = join_relative(relative, name_bytes, limits.maximum_path_bytes)?;
        if output.len() >= limits.maximum_entries {
            return Err(TransferHelperError::Limit(format!(
                "entry count exceeds {}",
                limits.maximum_entries
            )));
        }
        let path = child.path();
        let metadata =
            fs::symlink_metadata(&path).map_err(|source| filesystem_error(&path, source))?;
        output.push(entry_for(
            &path,
            &child_relative,
            &metadata,
            seen_regular_inodes,
            limits,
        )?);
        if metadata.file_type().is_dir() {
            walk_directory(&path, &child_relative, seen_regular_inodes, output, limits)?;
        }
    }
    Ok(())
}

fn entry_for(
    path: &Path,
    relative: &[u8],
    metadata: &Metadata,
    seen_regular_inodes: &mut HashMap<InodeIdentity, String>,
    limits: ManifestLimits,
) -> Result<ManifestEntry, TransferHelperError> {
    let path_hex = hex_encode(relative);
    let file_type = metadata.file_type();
    let mut entry = ManifestEntry {
        path_hex: path_hex.clone(),
        kind: ManifestEntryKind::RegularFile,
        mode: metadata.mode() & 0o7777,
        uid: metadata.uid(),
        gid: metadata.gid(),
        size: 0,
        mtime_seconds: metadata.mtime(),
        mtime_nanoseconds: u32::try_from(metadata.mtime_nsec()).map_err(|_| {
            TransferHelperError::InvalidManifest(format!(
                "{} has invalid mtime nanoseconds",
                display_path(relative)
            ))
        })?,
        content_sha256: None,
        link_target_hex: None,
        hard_link_target_hex: None,
        sparse_data_extents: None,
        device_major: None,
        device_minor: None,
        xattrs: read_xattrs(path, limits)?,
    };

    if file_type.is_dir() {
        entry.kind = ManifestEntryKind::Directory;
    } else if file_type.is_file() {
        entry.size = metadata.size();
        let identity = (metadata.dev(), metadata.ino());
        if metadata.nlink() > 1 {
            if let Some(target) = seen_regular_inodes.get(&identity) {
                entry.kind = ManifestEntryKind::HardLink;
                entry.hard_link_target_hex = Some(target.clone());
                return Ok(entry);
            }
            seen_regular_inodes.insert(identity, path_hex);
        }
        let (digest, extents) = hash_and_extents(path, metadata, relative)?;
        entry.content_sha256 = Some(digest);
        entry.sparse_data_extents = Some(extents);
    } else if file_type.is_symlink() {
        entry.kind = ManifestEntryKind::SymbolicLink;
        let target = fs::read_link(path).map_err(|source| filesystem_error(path, source))?;
        let target_bytes = target.as_os_str().as_bytes();
        if target_bytes.contains(&0) {
            return Err(TransferHelperError::InvalidManifest(format!(
                "{} has a NUL-containing symbolic-link target",
                display_path(relative)
            )));
        }
        entry.size = target_bytes.len() as u64;
        entry.link_target_hex = Some(hex_encode(target_bytes));
    } else if file_type.is_fifo() {
        entry.kind = ManifestEntryKind::Fifo;
    } else if file_type.is_socket() {
        entry.kind = ManifestEntryKind::Socket;
    } else if file_type.is_block_device() {
        entry.kind = ManifestEntryKind::BlockDevice;
        entry.device_major = Some(libc::major(metadata.rdev()) as u64);
        entry.device_minor = Some(libc::minor(metadata.rdev()) as u64);
    } else if file_type.is_char_device() {
        entry.kind = ManifestEntryKind::CharacterDevice;
        entry.device_major = Some(libc::major(metadata.rdev()) as u64);
        entry.device_minor = Some(libc::minor(metadata.rdev()) as u64);
    } else {
        return Err(TransferHelperError::InvalidManifest(format!(
            "{} has an unsupported filesystem type",
            display_path(relative)
        )));
    }
    Ok(entry)
}

fn hash_and_extents(
    path: &Path,
    expected: &Metadata,
    relative: &[u8],
) -> Result<(String, Vec<DataExtent>), TransferHelperError> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
        .map_err(|source| filesystem_error(path, source))?;
    let before = file
        .metadata()
        .map_err(|source| filesystem_error(path, source))?;
    ensure_same_file(expected, &before, relative)?;

    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        let count = file
            .read(&mut buffer)
            .map_err(|source| filesystem_error(path, source))?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    let after = file
        .metadata()
        .map_err(|source| filesystem_error(path, source))?;
    ensure_same_file(&before, &after, relative)?;
    let extents = sparse_data_extents(&mut file, before.size(), path)?;
    file.seek(SeekFrom::Start(0))
        .map_err(|source| filesystem_error(path, source))?;
    Ok((hex_encode(&hasher.finalize()), extents))
}

fn ensure_same_file(
    expected: &Metadata,
    actual: &Metadata,
    relative: &[u8],
) -> Result<(), TransferHelperError> {
    let unchanged = expected.dev() == actual.dev()
        && expected.ino() == actual.ino()
        && expected.mode() == actual.mode()
        && expected.uid() == actual.uid()
        && expected.gid() == actual.gid()
        && expected.size() == actual.size()
        && expected.mtime() == actual.mtime()
        && expected.mtime_nsec() == actual.mtime_nsec();
    if unchanged {
        Ok(())
    } else {
        Err(TransferHelperError::SourceDrift(display_path(relative)))
    }
}

fn sparse_data_extents(
    file: &mut File,
    size: u64,
    path: &Path,
) -> Result<Vec<DataExtent>, TransferHelperError> {
    if size == 0 {
        return Ok(vec![]);
    }
    let size_offset = libc::off_t::try_from(size).map_err(|_| {
        TransferHelperError::InvalidManifest(format!(
            "{} is too large for SEEK_DATA/SEEK_HOLE",
            path.display()
        ))
    })?;
    let mut cursor: libc::off_t = 0;
    let mut result = Vec::new();
    while cursor < size_offset {
        let data = unsafe { libc::lseek(file.as_raw_fd(), cursor, libc::SEEK_DATA) };
        if data < 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ENXIO) {
                break;
            }
            return Err(filesystem_error(path, sparse_error(error)));
        }
        let hole = unsafe { libc::lseek(file.as_raw_fd(), data, libc::SEEK_HOLE) };
        if hole < 0 {
            return Err(filesystem_error(
                path,
                sparse_error(std::io::Error::last_os_error()),
            ));
        }
        if hole <= data || hole > size_offset {
            return Err(TransferHelperError::InvalidManifest(format!(
                "{} returned an invalid sparse extent",
                path.display()
            )));
        }
        result.push(DataExtent {
            offset: data as u64,
            length: (hole - data) as u64,
        });
        cursor = hole;
    }
    Ok(result)
}

fn sparse_error(error: std::io::Error) -> std::io::Error {
    match error.raw_os_error() {
        Some(libc::EINVAL) | Some(libc::ENOTSUP) => std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "filesystem cannot prove sparse data/hole extents",
        ),
        _ => error,
    }
}

fn read_xattrs(
    path: &Path,
    limits: ManifestLimits,
) -> Result<Vec<XattrEntry>, TransferHelperError> {
    let c_path = path_c_string(path)?;
    let mut names = xattr_list(&c_path, path)?;
    names.sort();
    if names.windows(2).any(|pair| pair[0] == pair[1]) {
        return Err(TransferHelperError::InvalidManifest(format!(
            "{} returned duplicate xattr names",
            path.display()
        )));
    }
    if names.len() > limits.maximum_xattrs_per_entry {
        return Err(TransferHelperError::Limit(format!(
            "{} has more than {} xattrs",
            path.display(),
            limits.maximum_xattrs_per_entry
        )));
    }
    let mut result = Vec::with_capacity(names.len());
    for name in names {
        if name.is_empty() || name.len() > limits.maximum_xattr_name_bytes || name.contains(&0) {
            return Err(TransferHelperError::InvalidManifest(format!(
                "{} has an invalid xattr name",
                path.display()
            )));
        }
        let c_name = CString::new(name.clone()).map_err(|_| {
            TransferHelperError::InvalidManifest(format!(
                "{} has a NUL-containing xattr name",
                path.display()
            ))
        })?;
        let value = xattr_value(&c_path, &c_name, path)?;
        if value.len() > limits.maximum_xattr_value_bytes {
            return Err(TransferHelperError::Limit(format!(
                "{} has an xattr value larger than {} bytes",
                path.display(),
                limits.maximum_xattr_value_bytes
            )));
        }
        result.push(XattrEntry {
            name_hex: hex_encode(&name),
            value_hex: hex_encode(&value),
        });
    }
    Ok(result)
}

fn xattr_list(c_path: &CString, path: &Path) -> Result<Vec<Vec<u8>>, TransferHelperError> {
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
            return Err(TransferHelperError::InvalidManifest(format!(
                "{} returned a malformed xattr name list",
                path.display()
            )));
        }
        let names = buffer[..buffer.len() - 1]
            .split(|byte| *byte == 0)
            .map(<[u8]>::to_vec)
            .collect();
        return Ok(names);
    }
    Err(TransferHelperError::SourceDrift(format!(
        "{} xattr list changed repeatedly",
        path.display()
    )))
}

fn xattr_value(
    c_path: &CString,
    c_name: &CString,
    path: &Path,
) -> Result<Vec<u8>, TransferHelperError> {
    for _ in 0..3 {
        let needed =
            unsafe { libc::lgetxattr(c_path.as_ptr(), c_name.as_ptr(), std::ptr::null_mut(), 0) };
        if needed < 0 {
            return Err(filesystem_error(path, std::io::Error::last_os_error()));
        }
        let mut buffer = vec![0_u8; needed as usize];
        let count = unsafe {
            libc::lgetxattr(
                c_path.as_ptr(),
                c_name.as_ptr(),
                buffer.as_mut_ptr().cast::<libc::c_void>(),
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
        return Ok(buffer);
    }
    Err(TransferHelperError::SourceDrift(format!(
        "{} xattr value changed repeatedly",
        path.display()
    )))
}

fn path_c_string(path: &Path) -> Result<CString, TransferHelperError> {
    CString::new(path.as_os_str().as_bytes()).map_err(|_| {
        TransferHelperError::InvalidManifest(format!("{} contains an embedded NUL", path.display()))
    })
}

fn join_relative(
    parent: &[u8],
    child: &[u8],
    maximum: usize,
) -> Result<Vec<u8>, TransferHelperError> {
    let required = parent
        .len()
        .checked_add(usize::from(!parent.is_empty()))
        .and_then(|length| length.checked_add(child.len()))
        .ok_or_else(|| TransferHelperError::Limit("path length overflow".into()))?;
    if required > maximum {
        return Err(TransferHelperError::Limit(format!(
            "path exceeds {maximum} bytes"
        )));
    }
    let mut result = Vec::with_capacity(required);
    result.extend_from_slice(parent);
    if !parent.is_empty() {
        result.push(b'/');
    }
    result.extend_from_slice(child);
    Ok(result)
}

fn display_path(relative: &[u8]) -> String {
    if relative.is_empty() {
        ".".into()
    } else {
        format!("hex:{}", hex_encode(relative))
    }
}

fn filesystem_error(path: &Path, source: std::io::Error) -> TransferHelperError {
    TransferHelperError::Filesystem {
        path: path_display_lossless(path),
        source,
    }
}

fn path_display_lossless(path: &Path) -> String {
    format!("hex:{}", hex_encode(path.as_os_str().as_bytes()))
}

#[allow(dead_code)]
fn _os_name_bytes(value: &OsStr) -> &[u8] {
    value.as_bytes()
}
