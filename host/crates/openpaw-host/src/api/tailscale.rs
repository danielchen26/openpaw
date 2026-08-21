//! Read-only Tailscale device discovery.
//!
//! The only host command this module runs is the fixed argv equivalent of
//! `tailscale status --json`. Client request data is never accepted as command
//! input, and only sanitized candidate metadata is returned.

use std::future::Future;
use std::net::IpAddr;
use std::pin::Pin;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use axum::response::{IntoResponse, Response};
use axum::{Json, http::StatusCode};
use serde::Serialize;
use serde_json::Value;
use tokio::io::AsyncReadExt;
use tokio::process::Command;

use super::ApiError;

/// Maximum bytes accepted from `tailscale status --json`.
pub const MAX_STATUS_BYTES: usize = 1024 * 1024;
/// Maximum time spent waiting for the local Tailscale CLI.
pub const STATUS_TIMEOUT: Duration = Duration::from_secs(3);

/// Fixed command runner used by the route.
pub trait TailscaleStatusRunner: Send + Sync + 'static {
    /// Run fixed `tailscale status --json` and return stdout.
    fn status_json(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<u8>, TailscaleUnavailable>> + Send + '_>>;
}

/// Process-backed fixed argv runner.
#[derive(Debug, Default)]
pub struct ProcessTailscaleStatusRunner;

impl TailscaleStatusRunner for ProcessTailscaleStatusRunner {
    fn status_json(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<u8>, TailscaleUnavailable>> + Send + '_>> {
        Box::pin(async move { run_status_command(MAX_STATUS_BYTES, STATUS_TIMEOUT).await })
    }
}

/// Typed unavailable states exposed to clients.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "code", content = "message", rename_all = "snake_case")]
pub enum TailscaleUnavailable {
    /// The `tailscale` executable is not installed or not on PATH.
    MissingCli(String),
    /// The local node is not logged in to Tailscale.
    LoggedOut(String),
    /// The fixed command exceeded its timeout.
    Timeout(String),
    /// The fixed command produced more output than the bounded limit.
    OutputLimit(String),
}

/// Structured unavailable response body.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TailscaleUnavailableResponse {
    /// Typed safe error.
    pub error: TailscaleUnavailable,
}

/// Parser error for Tailscale status JSON.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TailscaleParseError {
    /// Status JSON reports Tailscale is unavailable.
    Unavailable(TailscaleUnavailable),
    /// Status JSON is malformed or has an unsupported shape.
    Malformed(String),
}

impl TailscaleUnavailable {
    fn missing_cli() -> Self {
        Self::MissingCli("Tailscale is not installed on the connected host.".to_owned())
    }
    fn logged_out() -> Self {
        Self::LoggedOut(
            "Tailscale is installed but not logged in on the connected host.".to_owned(),
        )
    }
    fn timeout() -> Self {
        Self::Timeout("Tailscale discovery timed out on the connected host.".to_owned())
    }
    fn output_limit() -> Self {
        Self::OutputLimit(
            "Tailscale discovery returned too much data on the connected host.".to_owned(),
        )
    }
}

/// Sanitized versioned response.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TailscaleDevicesResponse {
    /// Response model version.
    pub version: u32,
    /// Sanitized Tailscale candidates. Metadata only, not trust or SSH readiness.
    pub candidates: Vec<TailscaleDeviceCandidate>,
}

/// Sanitized metadata for a Tailscale peer candidate.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TailscaleDeviceCandidate {
    /// Stable Tailscale node id, when present, otherwise a stable DNS/name fallback.
    pub id: String,
    /// Human-readable host name.
    pub display_name: String,
    /// Optional MagicDNS/FQDN name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dns_name: Option<String>,
    /// Normalized Tailscale IP addresses.
    pub tailscale_ips: Vec<String>,
    /// Reported operating system.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub os: Option<String>,
    /// Tailscale online metadata only.
    pub online: bool,
    /// Optional last seen timestamp string from Tailscale.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_seen: Option<String>,
}

/// Route handler for `GET /v1/tailscale/devices`.
pub async fn devices(
    axum::extract::State(app): axum::extract::State<crate::AppState>,
) -> Result<Response, ApiError> {
    let bytes = app
        .tailscale
        .status_json()
        .await
        .map_err(unavailable_response)?;
    match parse_status_json(&bytes) {
        Ok(response) => Ok(Json(response).into_response()),
        Err(TailscaleParseError::Unavailable(err)) => Err(unavailable_response(err)),
        Err(TailscaleParseError::Malformed(err)) => Err(ApiError::internal(format!(
            "malformed tailscale status json: {err}"
        ))),
    }
}

fn unavailable_response(err: TailscaleUnavailable) -> ApiError {
    let status = match err {
        TailscaleUnavailable::MissingCli(_) | TailscaleUnavailable::LoggedOut(_) => {
            StatusCode::SERVICE_UNAVAILABLE
        }
        TailscaleUnavailable::Timeout(_) => StatusCode::GATEWAY_TIMEOUT,
        TailscaleUnavailable::OutputLimit(_) => StatusCode::BAD_GATEWAY,
    };
    ApiError::json(status, serde_json::json!({ "error": err }))
}

/// Parse `tailscale status --json` into sanitized candidates.
pub fn parse_status_json(bytes: &[u8]) -> Result<TailscaleDevicesResponse, TailscaleParseError> {
    let value: Value =
        serde_json::from_slice(bytes).map_err(|e| TailscaleParseError::Malformed(e.to_string()))?;
    if is_logged_out_status(&value) {
        return Err(TailscaleParseError::Unavailable(
            TailscaleUnavailable::logged_out(),
        ));
    }
    let peers = if let Some(peer) = value.get("Peer") {
        peer
    } else if value.is_array() {
        &value
    } else if let Some(peers) = value.get("peers") {
        peers
    } else {
        return Err(TailscaleParseError::Malformed(
            "unsupported tailscale status shape".to_owned(),
        ));
    };

    let values: Vec<&Value> = if let Some(map) = peers.as_object() {
        map.values().collect()
    } else if let Some(array) = peers.as_array() {
        array.iter().collect()
    } else {
        return Err(TailscaleParseError::Malformed(
            "unsupported tailscale peer shape".to_owned(),
        ));
    };

    let mut candidates = Vec::new();
    for peer in values {
        if let Some(candidate) = candidate_from_peer(peer) {
            candidates.push(candidate);
        }
    }
    candidates.sort_by(|a, b| a.display_name.cmp(&b.display_name).then(a.id.cmp(&b.id)));
    Ok(TailscaleDevicesResponse {
        version: 1,
        candidates,
    })
}

fn is_logged_out_status(value: &Value) -> bool {
    let backend_state = value
        .get("BackendState")
        .or_else(|| value.get("backend_state"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(
        backend_state.as_str(),
        "needslogin" | "needs_login" | "stopped" | "no_state"
    )
}

fn candidate_from_peer(peer: &Value) -> Option<TailscaleDeviceCandidate> {
    let id = string_at(peer, &["ID", "Id", "id", "NodeID", "StableID"])
        .or_else(|| string_at(peer, &["DNSName", "HostName", "Name"]))?;
    let display_name =
        string_at(peer, &["HostName", "Name", "DNSName"]).unwrap_or_else(|| id.clone());
    let dns_name = string_at(peer, &["DNSName"]);
    let os = string_at(peer, &["OS"]);
    let last_seen = string_at(peer, &["LastSeen"]);
    let online = peer.get("Online").and_then(Value::as_bool).unwrap_or(false);
    let tailscale_ips = ip_list(peer)?;
    Some(TailscaleDeviceCandidate {
        id,
        display_name,
        dns_name,
        tailscale_ips,
        os,
        online,
        last_seen,
    })
}

fn string_at(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        value
            .get(*key)?
            .as_str()
            .map(|s| s.trim().trim_end_matches('.').to_owned())
            .filter(|s| !s.is_empty())
    })
}

fn ip_list(peer: &Value) -> Option<Vec<String>> {
    let raw = peer
        .get("TailscaleIPs")
        .or_else(|| peer.get("TailscaleIP"))?;
    let mut ips = Vec::new();
    match raw {
        Value::Array(items) => {
            for item in items {
                if let Some(ip) = item.as_str().and_then(normalize_ip) {
                    ips.push(ip);
                }
            }
        }
        Value::String(s) => {
            if let Some(ip) = normalize_ip(s) {
                ips.push(ip);
            }
        }
        _ => {}
    }
    ips.sort();
    ips.dedup();
    (!ips.is_empty()).then_some(ips)
}

fn normalize_ip(value: &str) -> Option<String> {
    value.trim().parse::<IpAddr>().ok().map(|ip| ip.to_string())
}

async fn run_status_command(
    max_bytes: usize,
    timeout: Duration,
) -> Result<Vec<u8>, TailscaleUnavailable> {
    let mut child = Command::new("tailscale")
        .arg("status")
        .arg("--json")
        .kill_on_drop(true)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                TailscaleUnavailable::missing_cli()
            } else {
                TailscaleUnavailable::logged_out()
            }
        })?;

    let mut stdout = child.stdout.take().expect("stdout piped");
    let output = async move {
        let mut bytes = Vec::new();
        let mut limited = (&mut stdout).take((max_bytes + 1) as u64);
        limited
            .read_to_end(&mut bytes)
            .await
            .map_err(|_| TailscaleUnavailable::logged_out())?;
        let status = child
            .wait()
            .await
            .map_err(|_| TailscaleUnavailable::logged_out())?;
        if bytes.len() > max_bytes {
            return Err(TailscaleUnavailable::output_limit());
        }
        if !status.success() {
            return Err(TailscaleUnavailable::logged_out());
        }
        Ok(bytes)
    };
    tokio::time::timeout(timeout, output)
        .await
        .map_err(|_| TailscaleUnavailable::timeout())?
}

/// Shared default runner.
pub fn default_runner() -> Arc<dyn TailscaleStatusRunner> {
    Arc::new(ProcessTailscaleStatusRunner)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_real_peer_map_shape_and_sanitizes_fields() {
        let json = br#"{"Peer":{"nodekey:abc":{"ID":"n1","HostName":"macbook","DNSName":"macbook.tail.ts.net.","TailscaleIPs":["100.64.0.2","fd7a:115c:a1e0::2"],"OS":"macOS","Online":true,"LastSeen":"2026-08-21T07:00:00Z","UserID":1,"Key":"secret"}}}"#;
        let parsed = parse_status_json(json).unwrap();
        assert_eq!(parsed.version, 1);
        assert_eq!(
            parsed.candidates,
            vec![TailscaleDeviceCandidate {
                id: "n1".into(),
                display_name: "macbook".into(),
                dns_name: Some("macbook.tail.ts.net".into()),
                tailscale_ips: vec!["100.64.0.2".into(), "fd7a:115c:a1e0::2".into()],
                os: Some("macOS".into()),
                online: true,
                last_seen: Some("2026-08-21T07:00:00Z".into())
            }]
        );
        let serialized = serde_json::to_string(&parsed).unwrap();
        assert!(!serialized.contains("secret"));
        assert!(!serialized.contains("UserID"));
    }

    #[test]
    fn parses_supported_array_shape_optional_dns_and_offline() {
        let json = br#"[{"id":"n2","Name":"linux","TailscaleIP":"100.64.0.3","Online":false}]"#;
        let parsed = parse_status_json(json).unwrap();
        assert_eq!(parsed.candidates[0].dns_name, None);
        assert!(!parsed.candidates[0].online);
        assert_eq!(parsed.candidates[0].tailscale_ips, vec!["100.64.0.3"]);
    }

    #[test]
    fn rejects_malformed_and_unsupported_json() {
        assert!(parse_status_json(b"not json").is_err());
        assert!(parse_status_json(br#"{"Self":{}}"#).is_err());
    }

    #[test]
    fn backend_state_needs_login_is_typed_logged_out() {
        let err = parse_status_json(br#"{"BackendState":"NeedsLogin","Peer":{}}"#).unwrap_err();
        assert!(matches!(
            err,
            TailscaleParseError::Unavailable(TailscaleUnavailable::LoggedOut(_))
        ));
    }
}
