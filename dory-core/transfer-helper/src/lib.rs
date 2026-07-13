//! Hermetic metadata verifier for Docker named-volume transfer.
//!
//! Linux paths are byte strings, not necessarily UTF-8. The manifest therefore uses lowercase
//! hex for every path, link target, xattr name, and xattr value. The model and validation are kept
//! transport-free so the app can treat the canonical JSON digest as operation evidence.

mod model;

#[cfg(target_os = "linux")]
mod scan_linux;

#[cfg(target_os = "linux")]
mod repair_linux;

pub use model::{
    DataExtent, ManifestEntry, ManifestEntryKind, ManifestLimits, VolumeManifest, XattrEntry,
};

use std::path::Path;

#[derive(Debug, thiserror::Error)]
pub enum TransferHelperError {
    #[error("invalid volume manifest: {0}")]
    InvalidManifest(String),
    #[error("volume manifest exceeds its limit: {0}")]
    Limit(String),
    #[error("filesystem operation failed for {path}: {source}")]
    Filesystem {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("volume changed while it was being scanned: {0}")]
    SourceDrift(String),
    #[error("volume verification failed: {0}")]
    Verification(String),
    #[error("unsupported volume semantics: {0}")]
    Unsupported(String),
    #[error("this operation requires Linux")]
    LinuxRequired,
    #[error("manifest encoding failed: {0}")]
    Encoding(#[from] serde_json::Error),
}

pub fn scan_volume(
    root: &Path,
    limits: ManifestLimits,
) -> Result<VolumeManifest, TransferHelperError> {
    #[cfg(target_os = "linux")]
    {
        scan_linux::scan_volume(root, limits)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (root, limits);
        Err(TransferHelperError::LinuxRequired)
    }
}

pub fn repair_volume(
    root: &Path,
    source: &VolumeManifest,
    limits: ManifestLimits,
) -> Result<VolumeManifest, TransferHelperError> {
    #[cfg(target_os = "linux")]
    {
        repair_linux::repair_volume(root, source, limits)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (root, source, limits);
        Err(TransferHelperError::LinuxRequired)
    }
}

pub fn hex_encode(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut result = String::with_capacity(bytes.len().saturating_mul(2));
    for byte in bytes {
        result.push(DIGITS[(byte >> 4) as usize] as char);
        result.push(DIGITS[(byte & 0x0f) as usize] as char);
    }
    result
}

pub fn hex_decode(value: &str) -> Result<Vec<u8>, TransferHelperError> {
    if !value.len().is_multiple_of(2) {
        return Err(TransferHelperError::InvalidManifest(
            "hex field has an odd number of digits".to_string(),
        ));
    }
    let bytes = value.as_bytes();
    let mut result = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks_exact(2) {
        let high = hex_nibble(pair[0]).ok_or_else(|| {
            TransferHelperError::InvalidManifest("hex field is not lowercase canonical hex".into())
        })?;
        let low = hex_nibble(pair[1]).ok_or_else(|| {
            TransferHelperError::InvalidManifest("hex field is not lowercase canonical hex".into())
        })?;
        result.push((high << 4) | low);
    }
    Ok(result)
}

fn hex_nibble(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        _ => None,
    }
}
