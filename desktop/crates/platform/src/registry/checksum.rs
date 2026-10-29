//! 安装产物 checksum（story 5.3/5.4）：SHA-256 十六进制比对，算法固定不做协商。

use sha2::{Digest, Sha256};

pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

pub fn verify_sha256(bytes: &[u8], expected_hex: &str) -> bool {
    sha256_hex(bytes).eq_ignore_ascii_case(expected_hex.trim())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verifies_known_sha256() {
        let digest = sha256_hex(b"abc");
        assert_eq!(
            digest,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert!(verify_sha256(b"abc", &digest));
        assert!(verify_sha256(b"abc", &digest.to_uppercase()));
        assert!(!verify_sha256(b"abd", &digest));
    }
}
