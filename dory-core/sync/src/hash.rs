use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::Path;

pub const HASH_LEN: usize = 32;

/// A content hash (sha256). Used to decide whether a remote file matches the host's — content, not
/// mtime, is authoritative, so a touched-but-unchanged file is not re-sent.
pub type Hash = [u8; HASH_LEN];

pub fn hash_bytes(bytes: &[u8]) -> Hash {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher.finalize().into()
}

/// Hash a file without loading it into memory. Callers that need a stable snapshot must compare
/// the surrounding file metadata or re-hash at their transaction boundary; this function only
/// guarantees bounded-memory SHA-256 calculation for the bytes observed by this open file.
pub fn hash_file(path: &Path) -> std::io::Result<Hash> {
    let file = std::fs::File::open(path)?;
    let mut reader = std::io::BufReader::with_capacity(crate::CHUNK_BYTES, file);
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; crate::CHUNK_BYTES];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher.finalize().into())
}
