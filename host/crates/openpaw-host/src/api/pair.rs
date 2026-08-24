//! Pairing: minting a code on the workstation, redeeming it from the phone.
//!
//! The flow has two halves so no secret is ever typed by hand:
//!
//! 1. The operator runs `openpaw-host pair --name phone`. That CLI call reaches
//!    the *running daemon* over loopback with the hook token, and the daemon
//!    mints a code it holds in memory for five minutes.
//! 2. The phone posts the code to `POST /v1/pair`, which consumes it and returns
//!    the device's bearer token and HMAC key.
//!
//! The daemon owns the code because the CLI is a short-lived process: a code
//! minted in the CLI's memory would be gone before the phone could redeem it, and
//! a code written to disk would be a credential outliving its own expiry.

use std::collections::VecDeque;
use std::fmt;
use std::time::{Duration, Instant};

use axum::Json;
use axum::extract::State;
use axum::http::HeaderMap;
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use time::OffsetDateTime;
use tokio::sync::Mutex;

use crate::AppState;
use crate::api::ApiError;
use crate::audit::AuditEntry;
use crate::auth::{self, Profile};
use crate::state::Device;

/// Optional recovery key for `POST /v1/pair`.
pub const IDEMPOTENCY_HEADER: &str = "x-openpaw-idempotency-key";
const IDEMPOTENCY_KEY_BYTES: usize = 32;
const RECOVERY_TTL: Duration = Duration::from_secs(60);
const RECOVERY_CAPACITY: usize = 64;

/// Short-lived, process-local recovery for successful pairing responses.
///
/// The inner entries intentionally implement no `Debug`: they hold the one-time
/// bearer token and HMAC key. The outer implementation reports policy only.
pub struct PairRecovery {
    inner: Mutex<PairRecoveryState>,
    ttl: Duration,
    capacity: usize,
}

#[derive(Default)]
struct PairRecoveryState {
    entries: VecDeque<PairRecoveryEntry>,
}

struct PairRecoveryEntry {
    key: String,
    fingerprint: [u8; 32],
    response: PairResponse,
    inserted_at: Instant,
}

impl PairRecovery {
    /// Create the standard 60-second, 64-entry in-memory recovery cache.
    pub fn new() -> PairRecovery {
        PairRecovery {
            inner: Mutex::new(PairRecoveryState::default()),
            ttl: RECOVERY_TTL,
            capacity: RECOVERY_CAPACITY,
        }
    }
}

impl Default for PairRecovery {
    fn default() -> Self {
        PairRecovery::new()
    }
}

impl fmt::Debug for PairRecovery {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PairRecovery")
            .field("ttl", &self.ttl)
            .field("capacity", &self.capacity)
            .finish_non_exhaustive()
    }
}

impl PairRecoveryState {
    fn remove_expired(&mut self, ttl: Duration) {
        self.entries
            .retain(|entry| entry.inserted_at.elapsed() < ttl);
    }

    fn find(&self, key: &str) -> Option<&PairRecoveryEntry> {
        self.entries.iter().find(|entry| entry.key == key)
    }

    fn insert(
        &mut self,
        key: String,
        fingerprint: [u8; 32],
        response: PairResponse,
        capacity: usize,
    ) {
        while self.entries.len() >= capacity {
            self.entries.pop_front();
        }
        self.entries.push_back(PairRecoveryEntry {
            key,
            fingerprint,
            response,
            inserted_at: Instant::now(),
        });
    }
}

/// Body of `POST /v1/pairing-code`.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct IssueRequest {
    /// Name to pre-assign to whichever device redeems the code.
    pub device_name: Option<String>,
    /// Capability profile to grant. Defaults to `operator`.
    pub profile: Profile,
}

/// Response of `POST /v1/pairing-code`.
#[derive(Clone, Serialize, Deserialize)]
pub struct IssueResponse {
    /// The code to read out, e.g. `K3F2-9QAM-...`.
    pub code: String,
    /// When it stops working.
    #[serde(with = "time::serde::rfc3339")]
    pub expires_at: OffsetDateTime,
    /// Profile the redeemed device will receive.
    pub profile: Profile,
    /// Seconds the operator has to type it in.
    pub expires_in_seconds: u64,
}

impl fmt::Debug for IssueResponse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("IssueResponse")
            .field("code", &"<redacted>")
            .field("expires_at", &self.expires_at)
            .field("profile", &self.profile)
            .field("expires_in_seconds", &self.expires_in_seconds)
            .finish()
    }
}

/// Body of `POST /v1/pair`.
#[derive(Clone, Deserialize)]
pub struct PairRequest {
    /// The code from the workstation.
    pub pairing_code: String,
    /// Human label for this device.
    pub device_name: String,
    /// Reported platform, e.g. `ios`.
    pub platform: String,
}

impl fmt::Debug for PairRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PairRequest")
            .field("pairing_code", &"<redacted>")
            .field("device_name", &self.device_name)
            .field("platform", &self.platform)
            .finish()
    }
}

/// Response of `POST /v1/pair`. A keyed retry may replay the exact credentials
/// from memory for 60 seconds.
#[derive(Clone, Serialize, Deserialize)]
pub struct PairResponse {
    /// Identifier to send in `X-OpenPaw-Device`.
    pub device_id: String,
    /// Bearer token. Only the SHA-256 is stored by the daemon.
    pub token: String,
    /// Base64 HMAC key for request signing.
    pub hmac_key_b64: String,
    /// Capability names granted.
    pub capabilities: Vec<String>,
}

impl fmt::Debug for PairResponse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PairResponse")
            .field("device_id", &self.device_id)
            .field("token", &"<redacted>")
            .field("hmac_key_b64", &"<redacted>")
            .field("capabilities", &self.capabilities)
            .finish()
    }
}

/// `POST /v1/pairing-code` — hook-token authenticated, used by the CLI.
pub async fn issue_code(
    State(app): State<AppState>,
    body: Option<Json<IssueRequest>>,
) -> Result<Json<IssueResponse>, ApiError> {
    let request = body.map(|Json(request)| request).unwrap_or_default();
    let pending = app
        .pairing
        .issue(request.device_name.clone(), request.profile);

    app.audit
        .append(&AuditEntry::now(
            auth::LOCAL_CALLER,
            "pairing.code_issued",
            request.device_name.as_deref().unwrap_or("(unnamed)"),
            format!(
                "{:?} profile, expires {}",
                request.profile, pending.expires_at
            ),
        ))
        .await
        .map_err(ApiError::internal)?;

    Ok(Json(IssueResponse {
        code: pending.code,
        expires_at: pending.expires_at,
        profile: pending.profile,
        expires_in_seconds: auth::PAIRING_TTL.as_secs(),
    }))
}

/// `POST /v1/pair` — unauthenticated, guarded by the one-time code.
pub async fn pair(
    State(app): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<PairRequest>,
) -> Result<Json<PairResponse>, ApiError> {
    let idempotency_key = parse_idempotency_key(&headers)?;
    let fingerprint = idempotency_key
        .as_ref()
        .map(|_| pairing_fingerprint(&request));

    // Pairing is globally low-frequency. Holding one transaction lock through
    // code consumption, durable writes and recovery publication makes concurrent
    // retries observe either the completed result or the in-flight transaction.
    let mut recovery = app.pair_recovery.inner.lock().await;
    recovery.remove_expired(app.pair_recovery.ttl);
    if let (Some(key), Some(fingerprint)) = (&idempotency_key, fingerprint) {
        if let Some(entry) = recovery.find(key) {
            if entry.fingerprint == fingerprint {
                return Ok(Json(entry.response.clone()));
            }
            return Err(ApiError::conflict(
                "idempotency key was already used for another pairing request",
            ));
        }
    }

    let pending = match app.pairing.consume(&request.pairing_code) {
        Some(pending) => pending,
        None => {
            // Worth auditing: repeated failures here are someone guessing codes.
            let _ = app
                .audit
                .append(&AuditEntry::now(
                    "unpaired",
                    "device.pair",
                    &request.device_name,
                    "rejected: unknown or expired pairing code",
                ))
                .await;
            return Err(ApiError::forbidden(
                "unknown or expired pairing code; run `openpaw-host pair` again",
            ));
        }
    };

    let name = pick_name(&request.device_name, pending.device_name.as_deref());
    let token = auth::mint_secret();
    let device = Device {
        device_id: format!("dev_{}", uuid::Uuid::new_v4().simple()),
        name: name.clone(),
        platform: sanitize_label(&request.platform, "unknown"),
        hmac_key_b64: auth::mint_hmac_key_b64(),
        token_sha256: auth::sha256_hex(token.as_bytes()),
        capabilities: pending.profile.capability_names(),
        profile: Some(pending.profile),
        paired_at: OffsetDateTime::now_utc(),
        last_seen: None,
    };

    let response = PairResponse {
        device_id: device.device_id.clone(),
        token,
        hmac_key_b64: device.hmac_key_b64.clone(),
        capabilities: device.capabilities.clone(),
    };
    let device_id = device.device_id.clone();
    app.store.insert_device(device)?;

    app.audit
        .append(&AuditEntry::now(
            &device_id,
            "device.pair",
            &name,
            format!("paired with the {:?} profile", pending.profile),
        ))
        .await
        .map_err(ApiError::internal)?;

    // Ordering is deliberate: persistent device insert, durable audit, then the
    // process-local recovery entry, and only then the HTTP response.
    if let (Some(key), Some(fingerprint)) = (idempotency_key, fingerprint) {
        recovery.insert(
            key,
            fingerprint,
            response.clone(),
            app.pair_recovery.capacity,
        );
    }

    tracing::info!(device = %device_id, name = %name, profile = ?pending.profile, "device paired");
    Ok(Json(response))
}

fn parse_idempotency_key(headers: &HeaderMap) -> Result<Option<String>, ApiError> {
    let mut values = headers.get_all(IDEMPOTENCY_HEADER).iter();
    let Some(value) = values.next() else {
        return Ok(None);
    };
    if values.next().is_some() {
        return Err(ApiError::bad_request(
            "x-openpaw-idempotency-key must appear exactly once",
        ));
    }
    let value = value
        .to_str()
        .map_err(|_| ApiError::bad_request("x-openpaw-idempotency-key must be ASCII base64url"))?;
    let decoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| {
            ApiError::bad_request(
                "x-openpaw-idempotency-key must be unpadded base64url for 32 bytes",
            )
        })?;
    if decoded.len() != IDEMPOTENCY_KEY_BYTES
        || base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(&decoded) != value
    {
        return Err(ApiError::bad_request(
            "x-openpaw-idempotency-key must be canonical unpadded base64url for 32 bytes",
        ));
    }
    Ok(Some(value.to_owned()))
}

fn pairing_fingerprint(request: &PairRequest) -> [u8; 32] {
    let fields = [
        auth::normalize_pairing_code(&request.pairing_code),
        sanitize_label(&request.device_name, "device"),
        sanitize_label(&request.platform, "unknown"),
    ];
    let mut digest = Sha256::new();
    for field in fields {
        digest.update((field.len() as u64).to_be_bytes());
        digest.update(field.as_bytes());
    }
    digest.finalize().into()
}

/// Prefer the name the device reports; fall back to the one the operator
/// pre-declared, then to a placeholder. A device that reports nothing usable must
/// still be identifiable in the audit log.
fn pick_name(reported: &str, declared: Option<&str>) -> String {
    let reported = reported.trim();
    if !reported.is_empty() {
        return sanitize_label(reported, "device");
    }
    match declared.map(str::trim).filter(|name| !name.is_empty()) {
        Some(declared) => sanitize_label(declared, "device"),
        None => "device".to_owned(),
    }
}

/// Keep labels printable and bounded: they end up in log lines and in the audit
/// file, where a control character or a megabyte of text is a nuisance at best.
fn sanitize_label(raw: &str, fallback: &str) -> String {
    let cleaned: String = raw
        .trim()
        .chars()
        .filter(|c| !c.is_control())
        .take(64)
        .collect();
    if cleaned.trim().is_empty() {
        fallback.to_owned()
    } else {
        cleaned
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reported_names_win_over_declared_ones() {
        assert_eq!(pick_name("Pixel", Some("phone")), "Pixel");
        assert_eq!(pick_name("   ", Some("phone")), "phone");
        assert_eq!(pick_name("", None), "device");
        assert_eq!(pick_name("  ", Some("   ")), "device");
    }

    #[test]
    fn labels_are_stripped_of_control_characters_and_bounded() {
        assert_eq!(sanitize_label("ok\u{7}name", "fallback"), "okname");
        assert_eq!(sanitize_label("\n\t", "fallback"), "fallback");
        assert_eq!(sanitize_label(&"x".repeat(200), "fallback").len(), 64);
    }

    #[test]
    fn issue_request_defaults_to_the_operator_profile() {
        let request: IssueRequest = serde_json::from_str("{}").unwrap();
        assert_eq!(request.profile, Profile::Operator);
        assert!(request.device_name.is_none());

        let request: IssueRequest =
            serde_json::from_str(r#"{"profile":"observer","device_name":"ipad"}"#).unwrap();
        assert_eq!(request.profile, Profile::Observer);
        assert_eq!(request.device_name.as_deref(), Some("ipad"));
    }

    #[test]
    fn pairing_debug_output_redacts_codes_and_credentials() {
        let issued = IssueResponse {
            code: "SECRET-PAIRING-CODE".to_owned(),
            expires_at: OffsetDateTime::UNIX_EPOCH,
            profile: Profile::Operator,
            expires_in_seconds: 300,
        };
        let request = PairRequest {
            pairing_code: "SECRET-PAIRING-CODE".to_owned(),
            device_name: "iPad".to_owned(),
            platform: "ios".to_owned(),
        };
        let response = PairResponse {
            device_id: "dev_test".to_owned(),
            token: "SECRET-BEARER-TOKEN".to_owned(),
            hmac_key_b64: "SECRET-HMAC-KEY".to_owned(),
            capabilities: Vec::new(),
        };

        let debug = format!("{issued:?} {request:?} {response:?}");
        assert!(!debug.contains("SECRET-PAIRING-CODE"), "{debug}");
        assert!(!debug.contains("SECRET-BEARER-TOKEN"), "{debug}");
        assert!(!debug.contains("SECRET-HMAC-KEY"), "{debug}");
        assert!(debug.contains("<redacted>"), "{debug}");
    }

    #[test]
    fn expired_pairing_recovery_entries_are_removed_without_sleeping() {
        let mut state = PairRecoveryState::default();
        let key = "test-key".to_owned();
        state.insert(
            key.clone(),
            [7; 32],
            PairResponse {
                device_id: "dev_expired".to_owned(),
                token: "expired-token".to_owned(),
                hmac_key_b64: "expired-hmac".to_owned(),
                capabilities: Vec::new(),
            },
            RECOVERY_CAPACITY,
        );
        state.entries[0].inserted_at = Instant::now() - RECOVERY_TTL;

        state.remove_expired(RECOVERY_TTL);

        assert!(state.find(&key).is_none());
    }

    #[tokio::test]
    async fn pairing_recovery_debug_never_exposes_cached_credentials() {
        let recovery = PairRecovery::new();
        recovery.inner.lock().await.insert(
            "secret-idempotency-key".to_owned(),
            [9; 32],
            PairResponse {
                device_id: "dev_cached".to_owned(),
                token: "SECRET-CACHED-TOKEN".to_owned(),
                hmac_key_b64: "SECRET-CACHED-HMAC".to_owned(),
                capabilities: Vec::new(),
            },
            RECOVERY_CAPACITY,
        );

        let debug = format!("{recovery:?}");
        assert!(!debug.contains("secret-idempotency-key"), "{debug}");
        assert!(!debug.contains("SECRET-CACHED-TOKEN"), "{debug}");
        assert!(!debug.contains("SECRET-CACHED-HMAC"), "{debug}");
    }
}
