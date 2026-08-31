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

#[cfg(all(test, target_os = "linux"))]
mod test_support;

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trips_every_byte_value() {
        let bytes: Vec<u8> = (0..=255_u8).collect();
        let encoded = hex_encode(&bytes);
        assert_eq!(encoded.len(), 512);
        assert!(encoded
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)));
        assert_eq!(hex_decode(&encoded).unwrap(), bytes);
        assert_eq!(hex_encode(&[]), "");
        assert_eq!(hex_decode("").unwrap(), Vec::<u8>::new());
    }

    #[test]
    fn hex_decode_rejects_odd_length_and_non_canonical_digits() {
        for value in ["a", "abc", "4A", "ff0G", "ff 0"] {
            assert!(
                matches!(
                    hex_decode(value),
                    Err(TransferHelperError::InvalidManifest(_))
                ),
                "{value}"
            );
        }
    }

    #[test]
    fn errors_report_their_path_and_source() {
        let error = TransferHelperError::Filesystem {
            path: "hex:2f".into(),
            source: std::io::Error::from(std::io::ErrorKind::NotFound),
        };
        let message = error.to_string();
        assert!(message.contains("hex:2f"), "{message}");
        assert!(std::error::Error::source(&error).is_some());
        assert!(TransferHelperError::LinuxRequired
            .to_string()
            .contains("Linux"));
    }
}
