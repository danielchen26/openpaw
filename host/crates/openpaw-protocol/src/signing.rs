//! Request signing shared by the host daemon and every paired device.
//!
//! The device token authenticates the caller; the HMAC signature binds the
//! request to a method, path, timestamp, nonce and body so a captured token
//! cannot be replayed against a different request.
//!
//! Canonical string (see `protocol/capability-spec/capabilities.json`):
//!
//! ```text
//! METHOD\nPATH_WITH_QUERY\nTIMESTAMP\nNONCE\nSHA256_HEX(BODY)
//! ```

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

use crate::util::{hex_decode_fixed, hex_encode};

type HmacSha256 = Hmac<Sha256>;

/// Length of a SHA-256 digest in bytes.
const DIGEST_LEN: usize = 32;

/// Builds the canonical string that gets signed.
///
/// `method` is upper-cased so that a client sending `get` and one sending `GET`
/// produce the same signature; every other component is used verbatim.
/// `path_and_query` must be the request target exactly as it appears on the
/// wire, including the leading slash and any query string.
pub fn canonical_string(
    method: &str,
    path_and_query: &str,
    timestamp: i64,
    nonce: &str,
    body: &[u8],
) -> String {
    let body_digest = hex_encode(&Sha256::digest(body));
    let mut out = String::with_capacity(
        method.len() + path_and_query.len() + nonce.len() + body_digest.len() + 32,
    );
    out.push_str(&method.to_ascii_uppercase());
    out.push('\n');
    out.push_str(path_and_query);
    out.push('\n');
    out.push_str(&timestamp.to_string());
    out.push('\n');
    out.push_str(nonce);
    out.push('\n');
    out.push_str(&body_digest);
    out
}

/// Signs a canonical string, returning lowercase hex.
pub fn sign(hmac_key: &[u8], canonical: &str) -> String {
    hex_encode(&mac(hmac_key, canonical))
}

/// Verifies a lowercase-or-uppercase hex signature in constant time.
///
/// Malformed hex and wrong-length signatures are rejected without comparing.
pub fn verify(hmac_key: &[u8], canonical: &str, signature: &str) -> bool {
    let Some(provided) = hex_decode_fixed::<DIGEST_LEN>(signature) else {
        return false;
    };
    let expected = mac(hmac_key, canonical);
    // `ct_eq` on two fixed-size digests: no early exit, no length leak.
    ct_eq(&expected, &provided)
}

fn mac(hmac_key: &[u8], canonical: &str) -> [u8; DIGEST_LEN] {
    let mut mac = <HmacSha256 as Mac>::new_from_slice(hmac_key)
        .expect("HMAC accepts keys of any length, so this cannot fail");
    mac.update(canonical.as_bytes());
    mac.finalize().into_bytes().into()
}

fn ct_eq(left: &[u8; DIGEST_LEN], right: &[u8; DIGEST_LEN]) -> bool {
    let mut diff = 0u8;
    for index in 0..DIGEST_LEN {
        diff |= left[index] ^ right[index];
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &[u8] = b"0123456789abcdef0123456789abcdef";

    #[test]
    fn canonical_string_has_the_documented_layout() {
        let canonical =
            canonical_string("get", "/v1/inbox?status=pending", 1787245200, "n0nce", b"");
        let lines: Vec<&str> = canonical.split('\n').collect();
        assert_eq!(lines.len(), 5);
        assert_eq!(lines[0], "GET");
        assert_eq!(lines[1], "/v1/inbox?status=pending");
        assert_eq!(lines[2], "1787245200");
        assert_eq!(lines[3], "n0nce");
        // sha256 of the empty string.
        assert_eq!(
            lines[4],
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn body_changes_the_canonical_string() {
        let a = canonical_string("POST", "/v1/uploads", 1, "n", b"one");
        let b = canonical_string("POST", "/v1/uploads", 1, "n", b"two");
        assert_ne!(a, b);
    }

    #[test]
    fn sign_then_verify_round_trips() {
        let canonical = canonical_string("POST", "/v1/inbox/inb_x/resolve", 42, "abc", b"{}");
        let signature = sign(KEY, &canonical);
        assert_eq!(signature.len(), DIGEST_LEN * 2);
        assert!(signature.bytes().all(|b| b.is_ascii_hexdigit()));
        assert!(verify(KEY, &canonical, &signature));
    }

    #[test]
    fn verify_rejects_wrong_key_tampered_canonical_and_bad_hex() {
        let canonical = canonical_string("POST", "/v1/inbox/inb_x/resolve", 42, "abc", b"{}");
        let signature = sign(KEY, &canonical);

        assert!(!verify(b"another key entirely", &canonical, &signature));

        let tampered = canonical_string("POST", "/v1/inbox/inb_y/resolve", 42, "abc", b"{}");
        assert!(!verify(KEY, &tampered, &signature));

        assert!(!verify(KEY, &canonical, ""));
        assert!(!verify(KEY, &canonical, &signature[..62]));
        assert!(!verify(KEY, &canonical, &format!("{}zz", &signature[..62])));
    }

    #[test]
    fn verify_accepts_uppercase_hex() {
        let canonical = canonical_string("GET", "/v1/sessions", 7, "n", b"");
        let signature = sign(KEY, &canonical).to_uppercase();
        assert!(verify(KEY, &canonical, &signature));
    }
}
