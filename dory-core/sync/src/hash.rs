use sha2::{Digest, Sha256};

pub const HASH_LEN: usize = 32;

/// A content hash (sha256). Used to decide whether a remote file matches the host's — content, not
/// mtime, is authoritative, so a touched-but-unchanged file is not re-sent.
pub type Hash = [u8; HASH_LEN];

pub fn hash_bytes(bytes: &[u8]) -> Hash {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher.finalize().into()
}
