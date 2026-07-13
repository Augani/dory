use crate::{hex_decode, TransferHelperError};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

pub const VOLUME_MANIFEST_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ManifestLimits {
    pub maximum_entries: usize,
    pub maximum_manifest_bytes: usize,
    pub maximum_path_bytes: usize,
    pub maximum_xattrs_per_entry: usize,
    pub maximum_xattr_name_bytes: usize,
    pub maximum_xattr_value_bytes: usize,
}

impl Default for ManifestLimits {
    fn default() -> Self {
        Self {
            maximum_entries: 1_000_000,
            maximum_manifest_bytes: 256 * 1024 * 1024,
            maximum_path_bytes: 4_096,
            maximum_xattrs_per_entry: 1_024,
            maximum_xattr_name_bytes: 255,
            maximum_xattr_value_bytes: 65_536,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VolumeManifest {
    pub schema_version: u32,
    pub root: ManifestEntry,
    pub entries: Vec<ManifestEntry>,
}

impl VolumeManifest {
    pub fn new(root: ManifestEntry, mut entries: Vec<ManifestEntry>) -> Self {
        entries.sort_by(|left, right| left.path_hex.cmp(&right.path_hex));
        Self {
            schema_version: VOLUME_MANIFEST_SCHEMA_VERSION,
            root,
            entries,
        }
    }

    pub fn validate(&self, limits: ManifestLimits) -> Result<(), TransferHelperError> {
        if self.schema_version != VOLUME_MANIFEST_SCHEMA_VERSION {
            return invalid("unsupported schema version");
        }
        if self.entries.len() > limits.maximum_entries {
            return Err(TransferHelperError::Limit(format!(
                "{} entries exceeds {}",
                self.entries.len(),
                limits.maximum_entries
            )));
        }
        if !self.root.path_hex.is_empty() || self.root.kind != ManifestEntryKind::Directory {
            return invalid("root must be the empty-path directory entry");
        }
        validate_entry(&self.root, true, limits)?;

        let mut previous_path: Option<Vec<u8>> = None;
        let mut by_path = BTreeMap::<Vec<u8>, &ManifestEntry>::new();
        for entry in &self.entries {
            validate_entry(entry, false, limits)?;
            let path = hex_decode(&entry.path_hex)?;
            if previous_path
                .as_ref()
                .is_some_and(|previous| previous >= &path)
            {
                return invalid("entries are not strictly sorted by raw path bytes");
            }
            previous_path = Some(path.clone());
            if let Some(separator) = path.iter().rposition(|byte| *byte == b'/') {
                let parent = &path[..separator];
                if by_path.get(parent).map(|entry| entry.kind) != Some(ManifestEntryKind::Directory)
                {
                    return invalid("entry parent must be a prior directory");
                }
            }
            if by_path.insert(path.clone(), entry).is_some() {
                return invalid("manifest contains duplicate paths");
            }
            if entry.kind == ManifestEntryKind::HardLink {
                let target = hex_decode(entry.hard_link_target_hex.as_deref().unwrap_or_default())?;
                if target >= path {
                    return invalid("hard-link target must precede its canonical link");
                }
                let target_entry = by_path
                    .get(&target)
                    .filter(|target_entry| target_entry.kind == ManifestEntryKind::RegularFile)
                    .ok_or_else(|| {
                        invalid_error("hard-link target must name a prior regular file")
                    })?;
                validate_hard_link_metadata(entry, target_entry)?;
            }
        }
        Ok(())
    }

    pub fn canonical_json(&self, limits: ManifestLimits) -> Result<Vec<u8>, TransferHelperError> {
        self.validate(limits)?;
        let encoded = serde_json::to_vec(self)?;
        if encoded.len() > limits.maximum_manifest_bytes {
            return Err(TransferHelperError::Limit(format!(
                "manifest is {} bytes; maximum is {}",
                encoded.len(),
                limits.maximum_manifest_bytes
            )));
        }
        Ok(encoded)
    }

    pub fn canonical_sha256(&self, limits: ManifestLimits) -> Result<String, TransferHelperError> {
        let json = self.canonical_json(limits)?;
        let digest = Sha256::digest(json);
        Ok(crate::hex_encode(&digest))
    }

    pub fn socket_paths(&self) -> Vec<String> {
        self.entries
            .iter()
            .filter(|entry| entry.kind == ManifestEntryKind::Socket)
            .map(|entry| entry.path_hex.clone())
            .collect()
    }

    pub fn contains_device_nodes(&self) -> bool {
        self.entries.iter().any(|entry| {
            matches!(
                entry.kind,
                ManifestEntryKind::BlockDevice | ManifestEntryKind::CharacterDevice
            )
        })
    }

    pub fn normalized_target(&self) -> Self {
        let entries = self
            .entries
            .iter()
            .filter(|entry| entry.kind != ManifestEntryKind::Socket)
            .cloned()
            .collect();
        Self::new(self.root.clone(), entries)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ManifestEntryKind {
    RegularFile,
    Directory,
    SymbolicLink,
    HardLink,
    Fifo,
    Socket,
    BlockDevice,
    CharacterDevice,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManifestEntry {
    pub path_hex: String,
    pub kind: ManifestEntryKind,
    pub mode: u32,
    pub uid: u32,
    pub gid: u32,
    pub size: u64,
    pub mtime_seconds: i64,
    pub mtime_nanoseconds: u32,
    pub content_sha256: Option<String>,
    pub link_target_hex: Option<String>,
    pub hard_link_target_hex: Option<String>,
    pub sparse_data_extents: Option<Vec<DataExtent>>,
    pub device_major: Option<u64>,
    pub device_minor: Option<u64>,
    pub xattrs: Vec<XattrEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DataExtent {
    pub offset: u64,
    pub length: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct XattrEntry {
    pub name_hex: String,
    pub value_hex: String,
}

fn validate_entry(
    entry: &ManifestEntry,
    is_root: bool,
    limits: ManifestLimits,
) -> Result<(), TransferHelperError> {
    let path = hex_decode(&entry.path_hex)?;
    if is_root {
        if !path.is_empty() {
            return invalid("root path must be empty");
        }
    } else {
        validate_relative_path(&path, limits.maximum_path_bytes)?;
    }
    if entry.mode > 0o7777 {
        return invalid("mode contains file-type or unsupported bits");
    }
    if entry.mtime_nanoseconds >= 1_000_000_000 {
        return invalid("mtime nanoseconds are out of range");
    }
    validate_xattrs(&entry.xattrs, limits)?;

    match entry.kind {
        ManifestEntryKind::RegularFile => {
            require_hash(entry.content_sha256.as_deref())?;
            require_none(entry.link_target_hex.as_ref(), "regular file link target")?;
            require_none(
                entry.hard_link_target_hex.as_ref(),
                "regular file hard-link target",
            )?;
            validate_extents(entry.sparse_data_extents.as_deref(), entry.size)?;
            require_no_device(entry)?;
        }
        ManifestEntryKind::Directory => {
            require_zero_size(entry)?;
            require_no_content_fields(entry)?;
            require_no_device(entry)?;
        }
        ManifestEntryKind::SymbolicLink => {
            let target = hex_decode(
                entry
                    .link_target_hex
                    .as_deref()
                    .ok_or_else(|| invalid_error("symbolic link is missing its target"))?,
            )?;
            if target.contains(&0) || target.len() as u64 != entry.size {
                return invalid("symbolic-link target is invalid or has the wrong size");
            }
            require_none(entry.content_sha256.as_ref(), "symbolic-link content hash")?;
            require_none(
                entry.hard_link_target_hex.as_ref(),
                "symbolic-link hard-link target",
            )?;
            require_none(
                entry.sparse_data_extents.as_ref(),
                "symbolic-link sparse extents",
            )?;
            require_no_device(entry)?;
        }
        ManifestEntryKind::HardLink => {
            if entry.hard_link_target_hex.is_none() {
                return invalid("hard link is missing its target");
            }
            require_none(entry.content_sha256.as_ref(), "hard-link content hash")?;
            require_none(entry.link_target_hex.as_ref(), "hard-link symbolic target")?;
            require_none(
                entry.sparse_data_extents.as_ref(),
                "hard-link sparse extents",
            )?;
            require_no_device(entry)?;
        }
        ManifestEntryKind::Fifo | ManifestEntryKind::Socket => {
            require_zero_size(entry)?;
            require_no_content_fields(entry)?;
            require_no_device(entry)?;
        }
        ManifestEntryKind::BlockDevice | ManifestEntryKind::CharacterDevice => {
            require_zero_size(entry)?;
            require_no_content_fields(entry)?;
            if entry.device_major.is_none() || entry.device_minor.is_none() {
                return invalid("device entry is missing major/minor identity");
            }
        }
    }
    Ok(())
}

fn validate_hard_link_metadata(
    link: &ManifestEntry,
    target: &ManifestEntry,
) -> Result<(), TransferHelperError> {
    if link.mode != target.mode
        || link.uid != target.uid
        || link.gid != target.gid
        || link.size != target.size
        || link.mtime_seconds != target.mtime_seconds
        || link.mtime_nanoseconds != target.mtime_nanoseconds
        || link.xattrs != target.xattrs
    {
        return invalid("hard-link metadata differs from its canonical regular file");
    }
    Ok(())
}

fn validate_relative_path(path: &[u8], maximum: usize) -> Result<(), TransferHelperError> {
    if path.is_empty() || path.len() > maximum || path[0] == b'/' || path.contains(&0) {
        return invalid("path is empty, absolute, contains NUL, or exceeds its limit");
    }
    for component in path.split(|byte| *byte == b'/') {
        if component.is_empty() || component == b"." || component == b".." {
            return invalid("path contains an empty, dot, or dot-dot component");
        }
    }
    Ok(())
}

fn validate_xattrs(
    xattrs: &[XattrEntry],
    limits: ManifestLimits,
) -> Result<(), TransferHelperError> {
    if xattrs.len() > limits.maximum_xattrs_per_entry {
        return Err(TransferHelperError::Limit(
            "too many xattrs on one entry".into(),
        ));
    }
    let mut previous: Option<Vec<u8>> = None;
    let mut names = BTreeSet::new();
    for xattr in xattrs {
        let name = hex_decode(&xattr.name_hex)?;
        let value = hex_decode(&xattr.value_hex)?;
        if name.is_empty()
            || name.len() > limits.maximum_xattr_name_bytes
            || name.contains(&0)
            || value.len() > limits.maximum_xattr_value_bytes
        {
            return invalid("xattr name/value is invalid or exceeds its limit");
        }
        if previous.as_ref().is_some_and(|prior| prior >= &name) || !names.insert(name.clone()) {
            return invalid("xattrs are not strictly sorted and unique");
        }
        previous = Some(name);
    }
    Ok(())
}

fn validate_extents(extents: Option<&[DataExtent]>, size: u64) -> Result<(), TransferHelperError> {
    let extents = extents.ok_or_else(|| invalid_error("regular file has unknown sparse layout"))?;
    let mut previous_end = 0_u64;
    for extent in extents {
        if extent.length == 0 || extent.offset < previous_end {
            return invalid(
                "sparse data extents overlap, are unsorted, or contain an empty extent",
            );
        }
        let end = extent
            .offset
            .checked_add(extent.length)
            .ok_or_else(|| invalid_error("sparse extent overflows"))?;
        if end > size {
            return invalid("sparse extent exceeds the file's logical size");
        }
        previous_end = end;
    }
    Ok(())
}

fn require_hash(value: Option<&str>) -> Result<(), TransferHelperError> {
    let value = value.ok_or_else(|| invalid_error("regular file is missing its content hash"))?;
    if value.len() != 64 || hex_decode(value)?.len() != 32 {
        return invalid("content hash is not SHA-256 canonical hex");
    }
    Ok(())
}

fn require_zero_size(entry: &ManifestEntry) -> Result<(), TransferHelperError> {
    if entry.size != 0 {
        return invalid("non-content entry has a nonzero size");
    }
    Ok(())
}

fn require_no_content_fields(entry: &ManifestEntry) -> Result<(), TransferHelperError> {
    require_none(entry.content_sha256.as_ref(), "content hash")?;
    require_none(entry.link_target_hex.as_ref(), "symbolic-link target")?;
    require_none(entry.hard_link_target_hex.as_ref(), "hard-link target")?;
    require_none(entry.sparse_data_extents.as_ref(), "sparse extents")
}

fn require_no_device(entry: &ManifestEntry) -> Result<(), TransferHelperError> {
    require_none(entry.device_major.as_ref(), "device major")?;
    require_none(entry.device_minor.as_ref(), "device minor")
}

fn require_none<T>(value: Option<&T>, field: &str) -> Result<(), TransferHelperError> {
    if value.is_some() {
        return invalid(&format!("unexpected {field}"));
    }
    Ok(())
}

fn invalid<T>(message: &str) -> Result<T, TransferHelperError> {
    Err(invalid_error(message))
}

fn invalid_error(message: &str) -> TransferHelperError {
    TransferHelperError::InvalidManifest(message.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(path_hex: &str, kind: ManifestEntryKind) -> ManifestEntry {
        ManifestEntry {
            path_hex: path_hex.into(),
            kind,
            mode: 0o644,
            uid: 1000,
            gid: 1000,
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

    fn root() -> ManifestEntry {
        let mut value = entry("", ManifestEntryKind::Directory);
        value.mode = 0o755;
        value
    }

    fn regular(path: &str, contents: &[u8]) -> ManifestEntry {
        regular_hex(&crate::hex_encode(path.as_bytes()), contents)
    }

    fn regular_hex(path_hex: &str, contents: &[u8]) -> ManifestEntry {
        let mut value = entry(path_hex, ManifestEntryKind::RegularFile);
        value.size = contents.len() as u64;
        value.content_sha256 = Some(crate::hex_encode(&Sha256::digest(contents)));
        value.sparse_data_extents = if contents.is_empty() {
            Some(vec![])
        } else {
            Some(vec![DataExtent {
                offset: 0,
                length: contents.len() as u64,
            }])
        };
        value
    }

    #[test]
    fn canonical_manifest_is_byte_stable_and_byte_path_safe() {
        let mut binary_name = b"binary-".to_vec();
        binary_name.push(0xff);
        let manifest = VolumeManifest::new(
            root(),
            vec![
                regular("z-last", b"z"),
                regular("alpha", b"a"),
                regular_hex(&crate::hex_encode(&binary_name), b"binary"),
            ],
        );
        manifest.validate(ManifestLimits::default()).unwrap();
        let first = manifest.canonical_json(ManifestLimits::default()).unwrap();
        let second = manifest.canonical_json(ManifestLimits::default()).unwrap();
        assert_eq!(first, second);
        assert_eq!(
            manifest
                .canonical_sha256(ManifestLimits::default())
                .unwrap()
                .len(),
            64
        );
        assert!(String::from_utf8(first)
            .unwrap()
            .contains("62696e6172792dff"));
    }

    #[test]
    fn hardlinks_must_target_a_prior_canonical_regular_file() {
        let original = regular("data", b"same inode");
        let mut link = entry("6c696e6b", ManifestEntryKind::HardLink);
        link.hard_link_target_hex = Some(original.path_hex.clone());
        link.mode = original.mode;
        link.uid = original.uid;
        link.gid = original.gid;
        link.size = original.size;
        link.mtime_seconds = original.mtime_seconds;
        link.mtime_nanoseconds = original.mtime_nanoseconds;
        link.xattrs = original.xattrs.clone();
        let valid = VolumeManifest::new(root(), vec![original.clone(), link.clone()]);
        valid.validate(ManifestLimits::default()).unwrap();

        link.hard_link_target_hex = Some(crate::hex_encode(b"missing"));
        let invalid = VolumeManifest::new(root(), vec![original, link]);
        assert!(invalid.validate(ManifestLimits::default()).is_err());
    }

    #[test]
    fn paths_xattrs_and_sparse_extents_fail_closed() {
        let bad_paths = ["2f616273", "612f2e2e2f62", "612f2f62", "4A"];
        for path in bad_paths {
            let manifest = VolumeManifest::new(root(), vec![regular_hex(path, b"x")]);
            assert!(
                manifest.validate(ManifestLimits::default()).is_err(),
                "{path}"
            );
        }

        let mut bad_xattr = regular("file", b"x");
        bad_xattr.xattrs = vec![
            XattrEntry {
                name_hex: crate::hex_encode(b"user.z"),
                value_hex: "00".into(),
            },
            XattrEntry {
                name_hex: crate::hex_encode(b"user.a"),
                value_hex: "01".into(),
            },
        ];
        assert!(VolumeManifest::new(root(), vec![bad_xattr])
            .validate(ManifestLimits::default())
            .is_err());

        let mut bad_sparse = regular("file", b"0123456789");
        bad_sparse.sparse_data_extents = Some(vec![
            DataExtent {
                offset: 4,
                length: 5,
            },
            DataExtent {
                offset: 8,
                length: 2,
            },
        ]);
        assert!(VolumeManifest::new(root(), vec![bad_sparse])
            .validate(ManifestLimits::default())
            .is_err());
    }

    #[test]
    fn sockets_are_explicitly_excluded_from_the_target_contract() {
        let socket_path = crate::hex_encode(b"run/service.sock");
        let socket = entry(&socket_path, ManifestEntryKind::Socket);
        let directory = entry(&crate::hex_encode(b"run"), ManifestEntryKind::Directory);
        let file = regular("data", b"payload");
        let manifest = VolumeManifest::new(root(), vec![socket, directory, file]);
        manifest.validate(ManifestLimits::default()).unwrap();

        assert_eq!(manifest.socket_paths(), vec![socket_path]);
        assert_eq!(manifest.normalized_target().entries.len(), 2);
    }

    #[test]
    fn device_nodes_remain_an_explicit_policy_gate() {
        let mut device = entry("646576696365", ManifestEntryKind::CharacterDevice);
        device.device_major = Some(1);
        device.device_minor = Some(3);
        let manifest = VolumeManifest::new(root(), vec![device]);
        manifest.validate(ManifestLimits::default()).unwrap();
        assert!(manifest.contains_device_nodes());
    }

    #[test]
    fn parent_hardlink_and_total_byte_invariants_fail_closed() {
        let orphan = VolumeManifest::new(root(), vec![regular("missing/file", b"x")]);
        assert!(orphan.validate(ManifestLimits::default()).is_err());

        let original = regular("original", b"same inode");
        let mut link = entry(&crate::hex_encode(b"second"), ManifestEntryKind::HardLink);
        link.hard_link_target_hex = Some(original.path_hex.clone());
        link.size = original.size;
        link.mode = original.mode ^ 0o100;
        let inconsistent = VolumeManifest::new(root(), vec![original, link]);
        assert!(inconsistent.validate(ManifestLimits::default()).is_err());

        let manifest = VolumeManifest::new(root(), vec![regular("file", b"content")]);
        let limits = ManifestLimits {
            maximum_manifest_bytes: 1,
            ..ManifestLimits::default()
        };
        assert!(matches!(
            manifest.canonical_json(limits),
            Err(TransferHelperError::Limit(_))
        ));
    }
}
