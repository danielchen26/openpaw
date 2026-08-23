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

use axum::Json;
use axum::extract::State;
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::AppState;
use crate::api::ApiError;
use crate::audit::AuditEntry;
use crate::auth::{self, Profile};
use crate::state::Device;

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
#[derive(Debug, Clone, Serialize, Deserialize)]
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

/// Body of `POST /v1/pair`.
#[derive(Debug, Clone, Deserialize)]
pub struct PairRequest {
    /// The code from the workstation.
    pub pairing_code: String,
    /// Human label for this device.
    pub device_name: String,
    /// Reported platform, e.g. `ios`.
    pub platform: String,
}

/// Response of `POST /v1/pair`. The `token` is shown exactly once.
#[derive(Debug, Clone, Serialize, Deserialize)]
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
    Json(request): Json<PairRequest>,
) -> Result<Json<PairResponse>, ApiError> {
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

    tracing::info!(device = %device_id, name = %name, profile = ?pending.profile, "device paired");
    Ok(Json(response))
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
}
