//! Request authentication, capability enforcement, and pairing.
//!
//! Every route except `/v1/health`, `/v1/pair` and the hook ingress requires
//! *both* factors from `protocol/capability-spec/capabilities.json`:
//!
//! * a bearer token, which says *which device* is calling, and
//! * an HMAC-SHA256 signature over `METHOD\nPATH\nTIMESTAMP\nNONCE\nSHA256(BODY)`,
//!   which binds the call to this exact request.
//!
//! A stolen bearer token alone cannot mutate anything, and a captured signed
//! request cannot be replayed: the timestamp must be within ±300 s and the nonce
//! is remembered for 600 s.

use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use axum::Json;
use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::{HeaderMap, HeaderName, HeaderValue, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use http_body_util::{BodyExt, LengthLimitError, Limited};
use openpaw_protocol::signing;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use time::OffsetDateTime;

use crate::AppState;

/// Header carrying the device id.
pub const DEVICE_HEADER: &str = "x-openpaw-device";
/// Header carrying the unix-second timestamp the signature covers.
pub const TIMESTAMP_HEADER: &str = "x-openpaw-timestamp";
/// Header carrying the per-request nonce.
pub const NONCE_HEADER: &str = "x-openpaw-nonce";
/// Header carrying the lowercase-hex HMAC signature.
pub const SIGNATURE_HEADER: &str = "x-openpaw-signature";
/// Header the local agent hooks and CLI authenticate with.
pub const HOOK_TOKEN_HEADER: &str = "x-openpaw-hook-token";
/// Header naming the capability a 403 was missing.
pub const REQUIRED_CAPABILITY_HEADER: &str = "x-openpaw-required-capability";

/// Accepted clock skew, per the capability spec.
pub const MAX_SKEW: i64 = 300;
/// How long a nonce is remembered, per the capability spec.
pub const NONCE_TTL: Duration = Duration::from_secs(600);
/// Hard cap for remembered replay nonces. Oldest entries are evicted first.
pub const MAX_NONCES: usize = 4096;
/// Pairing codes are short-lived on purpose: the code is read off a terminal and
/// typed into a phone, which takes seconds, not hours.
pub const PAIRING_TTL: Duration = Duration::from_secs(300);

/// Device id recorded in the audit log for hook-token (local) callers.
pub const LOCAL_CALLER: &str = "local-cli";

// ---------------------------------------------------------------------------
// primitives
// ---------------------------------------------------------------------------

/// Cryptographically secure random bytes.
///
/// `rand::random` on an array is the supported 0.10 surface for this and needs no
/// trait in scope.
fn random_bytes<const N: usize>() -> [u8; N] {
    rand::random()
}

/// Lowercase hex SHA-256.
pub fn sha256_hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

/// Length-independent equality for secrets.
///
/// Comparing lengths first leaks only the length, which is public for every
/// secret compared here (fixed-size hex digests and base64url tokens).
pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Mint a 32-byte secret as unpadded base64url (bearer tokens, hook token,
/// action tokens).
pub fn mint_secret() -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(random_bytes::<32>())
}

/// Mint a 32-byte HMAC key as standard base64, ready to hand to a device.
pub fn mint_hmac_key_b64() -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(random_bytes::<32>())
}

/// RFC 4648 base32 alphabet, uppercase: short and readable aloud.
const BASE32: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/// A pairing code: 6 groups of 4 uppercase base32 characters.
pub fn mint_pairing_code() -> String {
    // 24 characters, 5 bits of alphabet each. A uniform byte reduced mod 32 stays
    // uniform because 256 is a multiple of 32, so there is no modulo bias.
    let chars: Vec<char> = random_bytes::<24>()
        .iter()
        .map(|b| BASE32[(*b as usize) % BASE32.len()] as char)
        .collect();
    chars
        .chunks(4)
        .map(|chunk| chunk.iter().collect::<String>())
        .collect::<Vec<_>>()
        .join("-")
}

/// Strip formatting so `abcd efgh` and `ABCD-EFGH` are the same code.
pub fn normalize_pairing_code(code: &str) -> String {
    code.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_uppercase())
        .collect()
}

// ---------------------------------------------------------------------------
// capabilities
// ---------------------------------------------------------------------------

/// One capability from the capability spec.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Capability {
    /// List agent sessions.
    SessionsRead,
    /// Subscribe to the event stream.
    EventsRead,
    /// Read inbox items, including command detail.
    InboxRead,
    /// Resolve permission and question items.
    ApprovalsWrite,
    /// Read git status, diffs and trees.
    ReposRead,
    /// Read file contents.
    FilesRead,
    /// Proxy to allowlisted loopback ports.
    PreviewProxy,
    /// Read Tailscale device metadata.
    DevicesRead,
    /// Write attachments into the upload directory.
    UploadsWrite,
}

impl Capability {
    /// Every capability, in spec order.
    pub const ALL: [Capability; 9] = [
        Capability::SessionsRead,
        Capability::EventsRead,
        Capability::InboxRead,
        Capability::ApprovalsWrite,
        Capability::ReposRead,
        Capability::FilesRead,
        Capability::PreviewProxy,
        Capability::DevicesRead,
        Capability::UploadsWrite,
    ];

    /// Wire name.
    pub fn as_str(self) -> &'static str {
        match self {
            Capability::SessionsRead => "sessions.read",
            Capability::EventsRead => "events.read",
            Capability::InboxRead => "inbox.read",
            Capability::ApprovalsWrite => "approvals.write",
            Capability::ReposRead => "repos.read",
            Capability::FilesRead => "files.read",
            Capability::PreviewProxy => "preview.proxy",
            Capability::DevicesRead => "devices.read",
            Capability::UploadsWrite => "uploads.write",
        }
    }
}

/// A named bundle of capabilities, mirroring `profiles` in the capability spec.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Profile {
    /// Read-only: can watch, cannot decide.
    Observer,
    /// Full app surface, including approvals, uploads and preview.
    #[default]
    Operator,
}

impl Profile {
    /// Capabilities granted by this profile.
    pub fn capabilities(self) -> &'static [Capability] {
        match self {
            Profile::Observer => &[
                Capability::SessionsRead,
                Capability::EventsRead,
                Capability::InboxRead,
                Capability::ReposRead,
                Capability::FilesRead,
                Capability::DevicesRead,
            ],
            Profile::Operator => &Capability::ALL,
        }
    }

    /// Capability names for the pairing response.
    pub fn capability_names(self) -> Vec<String> {
        self.capabilities()
            .iter()
            .map(|c| c.as_str().to_owned())
            .collect()
    }
}

impl std::str::FromStr for Profile {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value.trim().to_ascii_lowercase().as_str() {
            "observer" => Ok(Profile::Observer),
            "operator" => Ok(Profile::Operator),
            other => Err(format!(
                "unknown profile {other:?}; expected observer|operator"
            )),
        }
    }
}

/// The authenticated caller, attached to the request for handlers and audit.
#[derive(Debug, Clone)]
pub struct AuthedDevice {
    /// Device id from `X-OpenPaw-Device`.
    pub device_id: String,
    /// Capability names granted at pairing.
    pub capabilities: Vec<String>,
}

impl AuthedDevice {
    /// True when this caller holds `capability`.
    pub fn has(&self, capability: Capability) -> bool {
        self.capabilities.iter().any(|c| c == capability.as_str())
    }
}

// ---------------------------------------------------------------------------
// nonce replay cache
// ---------------------------------------------------------------------------

/// Remembers recently used nonces so a captured request cannot be replayed.
#[derive(Debug)]
pub struct NonceCache {
    seen: Mutex<HashMap<String, Instant>>,
    order: Mutex<VecDeque<String>>,
    ttl: Duration,
    capacity: usize,
}

impl NonceCache {
    /// Cache with the spec's 600 s window.
    pub fn new() -> NonceCache {
        NonceCache::with_ttl(NONCE_TTL)
    }

    /// Cache with a custom window.
    pub fn with_ttl(ttl: Duration) -> NonceCache {
        NonceCache::with_ttl_and_capacity(ttl, MAX_NONCES)
    }

    /// Cache with a custom window and capacity.
    pub fn with_ttl_and_capacity(ttl: Duration, capacity: usize) -> NonceCache {
        NonceCache {
            seen: Mutex::new(HashMap::new()),
            order: Mutex::new(VecDeque::new()),
            ttl,
            capacity: capacity.max(1),
        }
    }

    /// Record `nonce` for `device_id`; `false` means it was already used.
    ///
    /// Pruning happens here rather than on a timer: the map only grows when
    /// requests arrive, so that is exactly when it needs trimming.
    pub fn check_and_insert(&self, device_id: &str, nonce: &str) -> bool {
        let key = format!("{device_id}:{nonce}");
        let now = Instant::now();
        let mut seen = self.lock_seen();
        let mut order = self.lock_order();
        prune_nonces(&mut seen, &mut order, now, self.ttl);
        if seen.contains_key(&key) {
            return false;
        }
        seen.insert(key.clone(), now);
        order.push_back(key);
        while seen.len() > self.capacity {
            if let Some(oldest) = order.pop_front() {
                seen.remove(&oldest);
            }
        }
        true
    }

    /// Number of remembered nonces. Diagnostics only.
    pub fn len(&self) -> usize {
        self.lock_seen().len()
    }

    /// True when nothing is remembered.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn lock_seen(&self) -> std::sync::MutexGuard<'_, HashMap<String, Instant>> {
        self.seen
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn lock_order(&self) -> std::sync::MutexGuard<'_, VecDeque<String>> {
        self.order
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

fn prune_nonces(
    seen: &mut HashMap<String, Instant>,
    order: &mut VecDeque<String>,
    now: Instant,
    ttl: Duration,
) {
    while let Some(key) = order.front() {
        let expired = seen
            .get(key)
            .is_none_or(|seen_at| now.duration_since(*seen_at) >= ttl);
        if expired {
            if let Some(key) = order.pop_front() {
                seen.remove(&key);
            }
        } else {
            break;
        }
    }
}

impl Default for NonceCache {
    fn default() -> Self {
        NonceCache::new()
    }
}

// ---------------------------------------------------------------------------
// pairing
// ---------------------------------------------------------------------------

/// A pairing code the daemon handed out that nobody has redeemed yet.
#[derive(Debug, Clone)]
pub struct PendingCode {
    /// The code. Grouped for display when returned by [`PairingCodes::issue`],
    /// normalized when returned by [`PairingCodes::consume`].
    pub code: String,
    /// Device name the operator pre-declared with `pair --name`, if any.
    pub device_name: Option<String>,
    /// Profile the redeemed device will receive.
    pub profile: Profile,
    /// Wall-clock expiry, for display.
    pub expires_at: OffsetDateTime,
    issued: Instant,
}

/// In-memory pairing codes. Deliberately never persisted: a code that survived a
/// restart would be a credential sitting on disk outliving its own expiry.
#[derive(Debug)]
pub struct PairingCodes {
    pending: Mutex<Vec<PendingCode>>,
    ttl: Duration,
}

impl PairingCodes {
    /// Store with the standard 5-minute lifetime.
    pub fn new() -> PairingCodes {
        PairingCodes::with_ttl(PAIRING_TTL)
    }

    /// Store with a custom lifetime.
    pub fn with_ttl(ttl: Duration) -> PairingCodes {
        PairingCodes {
            pending: Mutex::new(Vec::new()),
            ttl,
        }
    }

    /// Issue a fresh code. The returned `code` is the grouped form to display.
    pub fn issue(&self, device_name: Option<String>, profile: Profile) -> PendingCode {
        let formatted = mint_pairing_code();
        let entry = PendingCode {
            code: normalize_pairing_code(&formatted),
            device_name,
            profile,
            expires_at: OffsetDateTime::now_utc() + self.ttl,
            issued: Instant::now(),
        };
        {
            let mut guard = self.lock();
            guard.retain(|c| c.issued.elapsed() < self.ttl);
            guard.push(entry.clone());
        }
        PendingCode {
            code: formatted,
            ..entry
        }
    }

    /// Redeem a code. Single use: a successful redemption removes it.
    pub fn consume(&self, presented: &str) -> Option<PendingCode> {
        let presented = normalize_pairing_code(presented);
        let mut guard = self.lock();
        guard.retain(|c| c.issued.elapsed() < self.ttl);
        let index = guard
            .iter()
            .position(|c| constant_time_eq(c.code.as_bytes(), presented.as_bytes()))?;
        Some(guard.remove(index))
    }

    /// Number of live codes.
    pub fn len(&self) -> usize {
        let mut guard = self.lock();
        guard.retain(|c| c.issued.elapsed() < self.ttl);
        guard.len()
    }

    /// True when no code is outstanding.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<PendingCode>> {
        self.pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

impl Default for PairingCodes {
    fn default() -> Self {
        PairingCodes::new()
    }
}

// ---------------------------------------------------------------------------
// middleware
// ---------------------------------------------------------------------------

/// Build a 401. `WWW-Authenticate` tells a correct client what to do next; the
/// detail names which factor was absent or rejected, never any secret material.
fn unauthorized(detail: &'static str) -> Response {
    let mut response = (
        StatusCode::UNAUTHORIZED,
        Json(json!({ "error": "unauthorized", "detail": detail })),
    )
        .into_response();
    response.headers_mut().insert(
        axum::http::header::WWW_AUTHENTICATE,
        HeaderValue::from_static("Bearer realm=\"openpaw\""),
    );
    response
}

/// Build a 403 that names the missing capability in the body *and* in a header,
/// so a client can react without parsing prose.
fn forbidden(capability: Capability) -> Response {
    let mut response = (
        StatusCode::FORBIDDEN,
        Json(json!({
            "error": "missing_capability",
            "capability": capability.as_str(),
        })),
    )
        .into_response();
    if let Ok(value) = HeaderValue::from_str(capability.as_str()) {
        response
            .headers_mut()
            .insert(HeaderName::from_static(REQUIRED_CAPABILITY_HEADER), value);
    }
    response
}

fn header<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    headers.get(name)?.to_str().ok().map(str::trim)
}

/// Extract the bearer token from `Authorization`.
fn bearer(headers: &HeaderMap) -> Option<&str> {
    let value = header(headers, "authorization")?;
    let (scheme, token) = value.split_once(' ')?;
    if scheme.eq_ignore_ascii_case("bearer") && !token.trim().is_empty() {
        Some(token.trim())
    } else {
        None
    }
}

/// Bearer + HMAC + capability enforcement for one route.
///
/// The body is buffered because the signature covers `SHA256(BODY)`. The
/// alternative — streaming unauthenticated bytes to a handler and checking the
/// signature afterwards — would mean writing unverified data to disk. The read is
/// bounded by `max_upload_bytes`, so an oversized body is rejected while it
/// streams rather than after it all arrives, and memory stays inside the cap the
/// operator already configured.
pub async fn authorize(
    State((app, capability)): State<(AppState, Capability)>,
    request: Request,
    next: Next,
) -> Response {
    let (mut parts, body) = request.into_parts();

    let device_id = match header(&parts.headers, DEVICE_HEADER) {
        Some(id) if !id.is_empty() => id.to_owned(),
        _ => return unauthorized("missing device header"),
    };
    let token = match bearer(&parts.headers) {
        Some(token) => token.to_owned(),
        None => return unauthorized("missing bearer token"),
    };
    let device = match app.store.authenticate(&device_id, &token) {
        Some(device) => device,
        None => return unauthorized("unknown device or bad token"),
    };

    let timestamp = match header(&parts.headers, TIMESTAMP_HEADER)
        .and_then(|value| value.parse::<i64>().ok())
    {
        Some(timestamp) => timestamp,
        None => return unauthorized("missing or malformed timestamp"),
    };
    if (OffsetDateTime::now_utc().unix_timestamp() - timestamp).abs() > MAX_SKEW {
        return unauthorized("timestamp outside the allowed skew");
    }

    let nonce = match header(&parts.headers, NONCE_HEADER) {
        Some(nonce) if !nonce.is_empty() => nonce.to_owned(),
        _ => return unauthorized("missing nonce"),
    };
    let signature = match header(&parts.headers, SIGNATURE_HEADER) {
        Some(signature) if !signature.is_empty() => signature.to_owned(),
        _ => return unauthorized("missing signature"),
    };

    let limit = app.config.max_upload_bytes.max(1024 * 1024) as usize;
    let bytes = match Limited::new(body, limit).collect().await {
        Ok(collected) => collected.to_bytes(),
        Err(err) => {
            return if err.downcast_ref::<LengthLimitError>().is_some() {
                (
                    StatusCode::PAYLOAD_TOO_LARGE,
                    Json(json!({ "error": "body_too_large", "limit": limit })),
                )
                    .into_response()
            } else {
                (
                    StatusCode::BAD_REQUEST,
                    Json(json!({ "error": "unreadable_body" })),
                )
                    .into_response()
            };
        }
    };

    let path_and_query = parts
        .uri
        .path_and_query()
        .map(|pq| pq.as_str().to_owned())
        .unwrap_or_else(|| parts.uri.path().to_owned());
    let canonical = signing::canonical_string(
        parts.method.as_str(),
        &path_and_query,
        timestamp,
        &nonce,
        &bytes,
    );
    let key = match device.hmac_key() {
        Ok(key) => key,
        Err(err) => {
            tracing::error!(%err, device = %device_id, "stored hmac key is unusable");
            return unauthorized("device key is unusable");
        }
    };
    if !signing::verify(&key, &canonical, &signature) {
        return unauthorized("signature mismatch");
    }

    // Only a request that already proved its signature may consume a nonce,
    // otherwise an attacker could burn nonces by guessing them.
    if !app.nonces.check_and_insert(&device_id, &nonce) {
        return unauthorized("nonce already used");
    }

    if !device.has_capability(capability.as_str()) {
        return forbidden(capability);
    }

    app.store
        .touch_device(&device_id, OffsetDateTime::now_utc());
    parts.extensions.insert(AuthedDevice {
        device_id,
        capabilities: device.capabilities.clone(),
    });
    next.run(Request::from_parts(parts, Body::from(bytes)))
        .await
}

/// Hook-token authentication for the local ingress and the CLI's pairing-code
/// endpoint.
///
/// Agent hooks run as the same user on the same machine and cannot hold a device
/// key, so they present the file-backed hook token instead. This is exactly why
/// the daemon stays on loopback: the hook token is a local secret.
pub async fn authorize_hook(State(app): State<AppState>, request: Request, next: Next) -> Response {
    match header(request.headers(), HOOK_TOKEN_HEADER) {
        Some(presented) if app.store.verify_hook_token(presented) => next.run(request).await,
        _ => unauthorized("missing or bad hook token"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairing_codes_are_six_groups_of_four_base32_chars() {
        for _ in 0..32 {
            let code = mint_pairing_code();
            let groups: Vec<&str> = code.split('-').collect();
            assert_eq!(groups.len(), 6, "{code}");
            for group in groups {
                assert_eq!(group.len(), 4, "{code}");
                assert!(
                    group.bytes().all(|b| BASE32.contains(&b)),
                    "{code} has non-base32 characters"
                );
            }
            assert_eq!(normalize_pairing_code(&code).len(), 24);
        }
    }

    #[test]
    fn codes_are_case_and_separator_insensitive_and_single_use() {
        let codes = PairingCodes::new();
        let issued = codes.issue(Some("phone".into()), Profile::Observer);
        assert_eq!(codes.len(), 1);

        let messy = issued.code.to_ascii_lowercase().replace('-', " ");
        let consumed = codes.consume(&messy).expect("code should redeem");
        assert_eq!(consumed.device_name.as_deref(), Some("phone"));
        assert_eq!(consumed.profile, Profile::Observer);

        assert!(
            codes.consume(&issued.code).is_none(),
            "codes are single use"
        );
        assert!(codes.is_empty());
    }

    #[test]
    fn expired_codes_cannot_be_redeemed() {
        let codes = PairingCodes::with_ttl(Duration::from_millis(1));
        let issued = codes.issue(None, Profile::Operator);
        std::thread::sleep(Duration::from_millis(5));
        assert!(codes.consume(&issued.code).is_none());
    }

    #[test]
    fn unknown_codes_are_rejected() {
        let codes = PairingCodes::new();
        codes.issue(None, Profile::Operator);
        assert!(codes.consume("AAAA-BBBB-CCCC-DDDD-EEEE-FFFF").is_none());
        assert!(codes.consume("").is_none());
    }

    #[test]
    fn nonces_are_single_use_per_device_and_expire() {
        let cache = NonceCache::with_ttl(Duration::from_millis(20));
        assert!(cache.check_and_insert("dev_a", "n1"));
        assert!(!cache.check_and_insert("dev_a", "n1"), "replay rejected");
        // The same nonce from another device is a different key.
        assert!(cache.check_and_insert("dev_b", "n1"));

        std::thread::sleep(Duration::from_millis(30));
        // Pruning happens on insert, so this insert clears the expired rows.
        assert!(cache.check_and_insert("dev_a", "n2"));
        assert_eq!(cache.len(), 1, "expired nonces were pruned");
    }

    #[test]
    fn nonces_are_capacity_bounded_and_evict_oldest() {
        let cache = NonceCache::with_ttl_and_capacity(Duration::from_secs(60), 2);
        assert!(cache.check_and_insert("dev", "n1"));
        assert!(cache.check_and_insert("dev", "n2"));
        assert!(cache.check_and_insert("dev", "n3"));
        assert_eq!(cache.len(), 2);
        assert!(
            cache.check_and_insert("dev", "n1"),
            "oldest nonce was evicted"
        );
        assert!(
            !cache.check_and_insert("dev", "n3"),
            "recent nonce remains protected"
        );
    }

    #[test]
    fn profiles_match_the_capability_spec() {
        let observer = Profile::Observer.capability_names();
        assert_eq!(
            observer,
            vec![
                "sessions.read",
                "events.read",
                "inbox.read",
                "repos.read",
                "files.read",
                "devices.read"
            ]
        );
        assert!(!observer.contains(&"approvals.write".to_owned()));
        assert!(!observer.contains(&"uploads.write".to_owned()));

        let operator = Profile::Operator.capability_names();
        assert_eq!(operator.len(), 9);
        for capability in Capability::ALL {
            assert!(operator.contains(&capability.as_str().to_owned()));
        }
        assert_eq!("operator".parse::<Profile>().unwrap(), Profile::Operator);
        assert_eq!("Observer".parse::<Profile>().unwrap(), Profile::Observer);
        assert!("root".parse::<Profile>().is_err());
    }

    #[test]
    fn constant_time_eq_matches_semantic_equality() {
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"abc", b"abcd"));
        assert!(constant_time_eq(b"", b""));
    }

    #[test]
    fn sha256_hex_is_the_standard_digest() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn minted_secrets_are_unique_and_url_safe() {
        let a = mint_secret();
        let b = mint_secret();
        assert_ne!(a, b);
        assert!(
            a.chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        );
        assert!(a.len() >= 40);
    }

    #[test]
    fn bearer_parsing_accepts_only_the_bearer_scheme() {
        let mut headers = HeaderMap::new();
        headers.insert("authorization", HeaderValue::from_static("Bearer abc123"));
        assert_eq!(bearer(&headers), Some("abc123"));
        headers.insert("authorization", HeaderValue::from_static("bearer abc123"));
        assert_eq!(bearer(&headers), Some("abc123"));
        headers.insert("authorization", HeaderValue::from_static("Basic abc123"));
        assert_eq!(bearer(&headers), None);
        headers.insert("authorization", HeaderValue::from_static("Bearer   "));
        assert_eq!(bearer(&headers), None);
    }
}
