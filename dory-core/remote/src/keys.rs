//! Parse SSH keys from their OpenSSH string forms, so callers (the FFI, doryd) can pass keys as
//! strings loaded from Keychain / config without depending on russh's key types.

use russh::keys::{PrivateKey, PublicKey};

use crate::error::RemoteError;

/// Decode an OpenSSH private key (the `-----BEGIN OPENSSH PRIVATE KEY-----` PEM). Unencrypted only.
pub fn private_key_from_openssh(pem: &str) -> Result<PrivateKey, RemoteError> {
    russh::keys::decode_secret_key(pem, None)
        .map_err(|e| RemoteError::Ssh(format!("private key: {e}")))
}

/// Parse an OpenSSH public key line (`ssh-ed25519 AAAA... comment`), as found in `authorized_keys`
/// or a `.pub` file — used to pin a server host key.
pub fn public_key_from_openssh(line: &str) -> Result<PublicKey, RemoteError> {
    PublicKey::from_openssh(line.trim()).map_err(|e| RemoteError::Ssh(format!("public key: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use russh::keys::ssh_key::{Algorithm, PrivateKey as Sk};

    #[test]
    fn round_trips_a_generated_keypair_through_openssh_strings() {
        let key = Sk::random(&mut rand::rng(), Algorithm::Ed25519).unwrap();
        let pem = key
            .to_openssh(russh::keys::ssh_key::LineEnding::LF)
            .unwrap();
        let pub_line = key.public_key().to_openssh().unwrap();

        let parsed_priv = private_key_from_openssh(&pem).unwrap();
        let parsed_pub = public_key_from_openssh(&pub_line).unwrap();
        // The parsed private key's public half must equal the separately-parsed public line.
        assert_eq!(parsed_priv.public_key().key_data(), parsed_pub.key_data());
    }

    #[test]
    fn rejects_garbage() {
        assert!(private_key_from_openssh("not a key").is_err());
        assert!(public_key_from_openssh("not a key").is_err());
    }
}
