//! Read-only Tailscale device discovery.
//!
//! The only host command this module runs is the fixed argv equivalent of
//! `tailscale status --json`. Client request data is never accepted as command
//! input, and only sanitized candidate metadata is returned.

use std::future::Future;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use axum::response::{IntoResponse, Response};
use axum::{Json, http::StatusCode};
use serde::Serialize;
use serde_json::Value;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::sync::Semaphore;
use tokio::time::{Instant, timeout_at};

use super::ApiError;

/// Maximum bytes accepted from `tailscale status --json`.
pub const MAX_STATUS_BYTES: usize = 1024 * 1024;
/// Maximum time spent waiting for the local Tailscale CLI.
pub const STATUS_TIMEOUT: Duration = Duration::from_secs(3);
/// Bounded time to wait for parent reaping after an explicit kill.
pub const POST_KILL_REAP_GRACE: Duration = Duration::from_millis(500);
const MAX_TEXT_FIELD_LEN: usize = 255;

/// Fixed command runner used by the route.
pub trait TailscaleStatusRunner: Send + Sync + 'static {
    /// Run fixed `tailscale status --json` and return stdout.
    fn status_json(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<u8>, TailscaleUnavailable>> + Send + '_>>;
}

/// Process-backed fixed argv runner.
#[derive(Debug)]
pub struct ProcessTailscaleStatusRunner {
    executable: PathBuf,
    semaphore: Arc<Semaphore>,
}

impl Default for ProcessTailscaleStatusRunner {
    fn default() -> Self {
        Self::new("tailscale")
    }
}

impl ProcessTailscaleStatusRunner {
    /// Create a process runner for an executable path or name.
    pub fn new(executable: impl Into<PathBuf>) -> Self {
        Self {
            executable: executable.into(),
            semaphore: Arc::new(Semaphore::new(1)),
        }
    }
}

impl TailscaleStatusRunner for ProcessTailscaleStatusRunner {
    fn status_json(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<u8>, TailscaleUnavailable>> + Send + '_>> {
        Box::pin(async move {
            let permit = self
                .semaphore
                .clone()
                .try_acquire_owned()
                .map_err(|_| TailscaleUnavailable::busy())?;
            let result =
                run_status_command(&self.executable, MAX_STATUS_BYTES, STATUS_TIMEOUT).await;
            drop(permit);
            result
        })
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
    /// Another process-backed discovery is already running.
    Busy(String),
    /// The local Tailscale daemon did not report a known running backend state.
    UnavailableState(String),
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BackendState {
    Running,
    LoggedOut,
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
    fn busy() -> Self {
        Self::Busy("Tailscale discovery is already running on the connected host.".to_owned())
    }
    fn unavailable_state(reason: &str) -> Self {
        Self::UnavailableState(format!(
            "Tailscale is not in a supported running state on the connected host: {reason}."
        ))
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
        TailscaleUnavailable::MissingCli(_)
        | TailscaleUnavailable::LoggedOut(_)
        | TailscaleUnavailable::UnavailableState(_) => StatusCode::SERVICE_UNAVAILABLE,
        TailscaleUnavailable::Timeout(_) => StatusCode::GATEWAY_TIMEOUT,
        TailscaleUnavailable::OutputLimit(_) | TailscaleUnavailable::Busy(_) => {
            StatusCode::BAD_GATEWAY
        }
    };
    ApiError::json(status, serde_json::json!({ "error": err }))
}

/// Parse `tailscale status --json` into sanitized candidates.
pub fn parse_status_json(bytes: &[u8]) -> Result<TailscaleDevicesResponse, TailscaleParseError> {
    let value: Value =
        serde_json::from_slice(bytes).map_err(|e| TailscaleParseError::Malformed(e.to_string()))?;
    let backend_state = backend_state(&value)?;
    if backend_state == BackendState::LoggedOut
        && value
            .get("Peer")
            .or_else(|| value.get("peers"))
            .is_none_or(peers_empty)
    {
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

    match backend_state {
        BackendState::Running => {}
        BackendState::LoggedOut if values.is_empty() => {
            return Err(TailscaleParseError::Unavailable(
                TailscaleUnavailable::logged_out(),
            ));
        }
        BackendState::LoggedOut => {
            return Err(TailscaleParseError::Malformed(
                "tailscale BackendState contradicts peer data".to_owned(),
            ));
        }
    }

    let mut candidates = Vec::new();
    for peer in values {
        candidates.push(candidate_from_peer(peer)?);
    }
    candidates.sort_by(|a, b| a.display_name.cmp(&b.display_name).then(a.id.cmp(&b.id)));
    Ok(TailscaleDevicesResponse {
        version: 1,
        candidates,
    })
}

fn backend_state(value: &Value) -> Result<BackendState, TailscaleParseError> {
    let Some(raw) = value
        .get("BackendState")
        .or_else(|| value.get("backend_state"))
    else {
        return Err(TailscaleParseError::Unavailable(
            TailscaleUnavailable::unavailable_state("missing BackendState"),
        ));
    };
    let Some(state) = raw.as_str() else {
        return Err(TailscaleParseError::Unavailable(
            TailscaleUnavailable::unavailable_state("BackendState is not a string"),
        ));
    };
    match state.to_ascii_lowercase().as_str() {
        "running" => Ok(BackendState::Running),
        "needslogin" | "needs_login" | "stopped" | "no_state" => Ok(BackendState::LoggedOut),
        _ => Err(TailscaleParseError::Unavailable(
            TailscaleUnavailable::unavailable_state("unsupported BackendState"),
        )),
    }
}

fn candidate_from_peer(peer: &Value) -> Result<TailscaleDeviceCandidate, TailscaleParseError> {
    if !peer.is_object() {
        return Err(TailscaleParseError::Malformed(
            "tailscale peer entry is not an object".to_owned(),
        ));
    }
    let id = match optional_string_at(peer, &["ID", "Id", "id", "NodeID", "StableID"])? {
        Some(id) => id,
        None => optional_string_at(peer, &["DNSName", "HostName", "Name"])?.ok_or_else(|| {
            TailscaleParseError::Malformed("tailscale peer is missing id".to_owned())
        })?,
    };
    let display_name =
        optional_string_at(peer, &["HostName", "Name", "DNSName"])?.unwrap_or_else(|| id.clone());
    let dns_name = optional_string_at(peer, &["DNSName"])?;
    let os = optional_string_at(peer, &["OS"])?;
    let last_seen = optional_last_seen(peer)?;
    let online = optional_bool_at(peer, "Online")?.unwrap_or(false);
    let tailscale_ips = ip_list(peer)?;
    Ok(TailscaleDeviceCandidate {
        id,
        display_name,
        dns_name,
        tailscale_ips,
        os,
        online,
        last_seen,
    })
}

fn peers_empty(value: &Value) -> bool {
    value.as_object().is_some_and(serde_json::Map::is_empty)
        || value.as_array().is_some_and(Vec::is_empty)
}

fn optional_string_at(value: &Value, keys: &[&str]) -> Result<Option<String>, TailscaleParseError> {
    for key in keys {
        let Some(raw) = value.get(*key) else {
            continue;
        };
        let Some(raw) = raw.as_str() else {
            return Err(TailscaleParseError::Malformed(format!(
                "tailscale peer field {key} is not a string"
            )));
        };
        let normalized = raw.trim().trim_end_matches('.');
        if normalized.is_empty() {
            return Err(TailscaleParseError::Malformed(format!(
                "tailscale peer field {key} is empty"
            )));
        }
        if normalized.len() > MAX_TEXT_FIELD_LEN || normalized.chars().any(char::is_control) {
            return Err(TailscaleParseError::Malformed(format!(
                "tailscale peer field {key} is invalid"
            )));
        }
        return Ok(Some(normalized.to_owned()));
    }
    Ok(None)
}

fn optional_bool_at(value: &Value, key: &str) -> Result<Option<bool>, TailscaleParseError> {
    value
        .get(key)
        .map(|raw| {
            raw.as_bool().ok_or_else(|| {
                TailscaleParseError::Malformed(format!(
                    "tailscale peer field {key} is not a boolean"
                ))
            })
        })
        .transpose()
}

fn optional_last_seen(value: &Value) -> Result<Option<String>, TailscaleParseError> {
    let Some(last_seen) = optional_string_at(value, &["LastSeen"])? else {
        return Ok(None);
    };
    OffsetDateTime::parse(&last_seen, &Rfc3339).map_err(|_| {
        TailscaleParseError::Malformed("tailscale peer LastSeen is not RFC3339".to_owned())
    })?;
    Ok(Some(last_seen))
}

fn ip_list(peer: &Value) -> Result<Vec<String>, TailscaleParseError> {
    let raw = peer
        .get("TailscaleIPs")
        .or_else(|| peer.get("TailscaleIP"))
        .ok_or_else(|| {
            TailscaleParseError::Malformed("tailscale peer is missing tailscale IPs".to_owned())
        })?;
    let mut ips = Vec::new();
    match raw {
        Value::Array(items) => {
            for item in items {
                let ip = item.as_str().and_then(normalize_ip).ok_or_else(|| {
                    TailscaleParseError::Malformed(
                        "tailscale peer contains invalid tailscale IP".to_owned(),
                    )
                })?;
                ips.push(ip);
            }
        }
        Value::String(s) => {
            let ip = normalize_ip(s).ok_or_else(|| {
                TailscaleParseError::Malformed(
                    "tailscale peer contains invalid tailscale IP".to_owned(),
                )
            })?;
            ips.push(ip);
        }
        _ => {
            return Err(TailscaleParseError::Malformed(
                "tailscale peer has unsupported tailscale IP shape".to_owned(),
            ));
        }
    }
    ips.sort();
    ips.dedup();
    if ips.is_empty() {
        Err(TailscaleParseError::Malformed(
            "tailscale peer has no valid tailscale IPs".to_owned(),
        ))
    } else {
        Ok(ips)
    }
}

fn normalize_ip(value: &str) -> Option<String> {
    let ip = value.trim().parse::<IpAddr>().ok()?;
    if is_tailscale_ip(&ip) {
        Some(ip.to_string())
    } else {
        None
    }
}

fn is_tailscale_ip(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ipv4_in_100_64_10(*ip),
        IpAddr::V6(ip) => ipv6_in_tailscale_ula(*ip),
    }
}

fn ipv4_in_100_64_10(ip: Ipv4Addr) -> bool {
    let octets = ip.octets();
    octets[0] == 100 && (64..=127).contains(&octets[1])
}

fn ipv6_in_tailscale_ula(ip: Ipv6Addr) -> bool {
    let segments = ip.segments();
    segments[0] == 0xfd7a && segments[1] == 0x115c && segments[2] == 0xa1e0
}

async fn run_status_command(
    executable: &Path,
    max_bytes: usize,
    timeout: Duration,
) -> Result<Vec<u8>, TailscaleUnavailable> {
    let deadline = Instant::now() + timeout;
    let mut command = Command::new(executable);
    command
        .arg("status")
        .arg("--json")
        .kill_on_drop(true)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(unix)]
    make_process_group(&mut command);
    let mut child = command.spawn().map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            TailscaleUnavailable::missing_cli()
        } else {
            TailscaleUnavailable::logged_out()
        }
    })?;

    let mut stdout = child.stdout.take().expect("stdout piped");
    let mut bytes = Vec::new();
    let mut limited = (&mut stdout).take((max_bytes + 1) as u64);
    match timeout_at(deadline, limited.read_to_end(&mut bytes)).await {
        Ok(result) => {
            result.map_err(|_| TailscaleUnavailable::logged_out())?;
        }
        Err(_) => {
            // `kill_on_drop` is a backstop. Explicit kill/reap prevents an orphan
            // or zombie when the timeout wins while the child is still running.
            cleanup_child(&mut child).await;
            return Err(TailscaleUnavailable::timeout());
        }
    }

    if bytes.len() > max_bytes {
        cleanup_child(&mut child).await;
        return Err(TailscaleUnavailable::output_limit());
    }

    let status = match timeout_at(deadline, child.wait()).await {
        Ok(result) => result.map_err(|_| TailscaleUnavailable::logged_out())?,
        Err(_) => {
            cleanup_child(&mut child).await;
            return Err(TailscaleUnavailable::timeout());
        }
    };
    if !status.success() {
        cleanup_child(&mut child).await;
        return Err(TailscaleUnavailable::logged_out());
    }
    Ok(bytes)
}

#[cfg(unix)]
fn make_process_group(command: &mut Command) {
    command.process_group(0);
}

async fn cleanup_child(child: &mut tokio::process::Child) {
    #[cfg(unix)]
    if let Some(pid) = child.id() {
        let _ = tokio::process::Command::new("/bin/kill")
            .arg("-KILL")
            .arg(format!("-{}", pid))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await;
    }
    #[cfg(not(unix))]
    let _ = child.kill().await;

    let reap_deadline = Instant::now() + POST_KILL_REAP_GRACE;
    let _ = timeout_at(reap_deadline, child.wait()).await;
}

/// Shared default runner.
pub fn default_runner() -> Arc<dyn TailscaleStatusRunner> {
    Arc::new(ProcessTailscaleStatusRunner::default())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::time::Instant;

    #[test]
    fn parses_real_peer_map_shape_and_sanitizes_fields() {
        let json = br#"{"BackendState":"Running","Peer":{"nodekey:abc":{"ID":"n1","HostName":"macbook","DNSName":"macbook.tail.ts.net.","TailscaleIPs":["100.64.0.2","fd7a:115c:a1e0::2"],"OS":"macOS","Online":true,"LastSeen":"2026-08-21T07:00:00Z","UserID":1,"Key":"secret"}}}"#;
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
        let json = br#"{"BackendState":"Running","Peer":[{"id":"n2","Name":"linux","TailscaleIP":"100.64.0.3","Online":false}]}"#;
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
    fn rejects_mixed_valid_and_invalid_peer_entries() {
        let err = parse_status_json(
            br#"{"BackendState":"Running","Peer":{"good":{"ID":"n1","HostName":"ok","TailscaleIP":"100.64.0.2"},"bad":{"ID":"n2","HostName":"bad"}}}"#,
        )
        .unwrap_err();
        assert!(matches!(err, TailscaleParseError::Malformed(_)));
    }

    #[test]
    fn backend_state_needs_login_is_typed_logged_out() {
        let err = parse_status_json(br#"{"BackendState":"NeedsLogin","Peer":{}}"#).unwrap_err();
        assert!(matches!(
            err,
            TailscaleParseError::Unavailable(TailscaleUnavailable::LoggedOut(_))
        ));

        let err = parse_status_json(
            br#"{"BackendState":"NeedsLogin","AuthURL":"https://login.tailscale.com/a/abc"}"#,
        )
        .unwrap_err();
        assert!(matches!(
            err,
            TailscaleParseError::Unavailable(TailscaleUnavailable::LoggedOut(_))
        ));
    }

    #[test]
    fn rejects_wrong_type_invalid_text_and_non_tailscale_candidate_fields() {
        for json in [
            br#"{"BackendState":"Running","Peer":{"n":{"ID":7,"HostName":"ok","TailscaleIP":"100.64.0.2"}}}"#.as_slice(),
            br#"{"BackendState":"Running","Peer":{"n":{"ID":"n1","HostName":"bad\u0007name","TailscaleIP":"100.64.0.2"}}}"#.as_slice(),
            br#"{"BackendState":"Running","Peer":{"n":{"ID":"n1","HostName":"ok","DNSName":false,"TailscaleIP":"100.64.0.2"}}}"#.as_slice(),
            br#"{"BackendState":"Running","Peer":{"n":{"ID":"n1","HostName":"ok","Online":"yes","TailscaleIP":"100.64.0.2"}}}"#.as_slice(),
            br#"{"BackendState":"Running","Peer":{"n":{"ID":"n1","HostName":"ok","TailscaleIP":"192.168.1.2"}}}"#.as_slice(),
            br#"{"BackendState":"Running","Peer":{"n":{"ID":"n1","HostName":"ok","TailscaleIPs":["100.64.0.2","fd00::1"]}}}"#.as_slice(),
        ] {
            assert!(matches!(
                parse_status_json(json).unwrap_err(),
                TailscaleParseError::Malformed(_)
            ));
        }
    }

    #[test]
    fn validates_last_seen_as_rfc3339_when_present() {
        let parsed = parse_status_json(
            br#"{"BackendState":"Running","Peer":[{"id":"n1","Name":"online","TailscaleIP":"100.64.0.2","Online":true,"LastSeen":"2026-08-21T07:00:00Z"},{"id":"n2","Name":"offline","TailscaleIP":"100.64.0.3","Online":false,"LastSeen":"2026-08-21T07:00:00+00:00"}]}"#,
        )
        .unwrap();
        let online = parsed
            .candidates
            .iter()
            .find(|candidate| candidate.display_name == "online")
            .unwrap();
        let offline = parsed
            .candidates
            .iter()
            .find(|candidate| candidate.display_name == "offline")
            .unwrap();
        assert!(online.online);
        assert_eq!(online.last_seen.as_deref(), Some("2026-08-21T07:00:00Z"));
        assert!(!offline.online);
        assert_eq!(
            offline.last_seen.as_deref(),
            Some("2026-08-21T07:00:00+00:00")
        );

        for json in [
            br#"{"BackendState":"Running","Peer":{"n":{"ID":"n1","HostName":"ok","TailscaleIP":"100.64.0.2","LastSeen":"not a timestamp"}}}"#.as_slice(),
            br#"{"BackendState":"Running","Peer":{"n":{"ID":"n1","HostName":"ok","TailscaleIP":"100.64.0.2","LastSeen":"2026-99-99T99:99:99Z"}}}"#.as_slice(),
        ] {
            assert!(matches!(
                parse_status_json(json).unwrap_err(),
                TailscaleParseError::Malformed(_)
            ));
        }
    }

    #[test]
    fn backend_state_is_fail_closed_for_absent_unknown_non_string_and_contradictory_states() {
        for json in [
            br#"{"Peer":{}}"#.as_slice(),
            br#"{"BackendState":"Mystery","Peer":{}}"#.as_slice(),
            br#"{"BackendState":true,"Peer":{}}"#.as_slice(),
        ] {
            assert!(matches!(
                parse_status_json(json).unwrap_err(),
                TailscaleParseError::Unavailable(TailscaleUnavailable::UnavailableState(_))
            ));
        }

        let err = parse_status_json(
            br#"{"BackendState":"NeedsLogin","Peer":{"n1":{"ID":"n1","HostName":"bad","TailscaleIP":"100.64.0.2"}}}"#,
        )
        .unwrap_err();
        assert!(matches!(err, TailscaleParseError::Malformed(_)));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn process_runner_reports_missing_executable() {
        let temp = tempfile::tempdir().unwrap();
        let missing = temp.path().join("missing-tailscale");
        let err = run_status_command(&missing, MAX_STATUS_BYTES, STATUS_TIMEOUT)
            .await
            .unwrap_err();
        assert!(matches!(err, TailscaleUnavailable::MissingCli(_)));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn process_runner_maps_nonzero_to_logged_out_without_stderr_leak() {
        let (_temp, script) = executable_script("nonzero", "echo secret-stderr >&2\nexit 1\n");
        let err = run_status_command(&script, MAX_STATUS_BYTES, STATUS_TIMEOUT)
            .await
            .unwrap_err();
        assert!(
            matches!(err, TailscaleUnavailable::LoggedOut(message) if !message.contains("secret-stderr"))
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn process_runner_discards_stderr_flood() {
        let (_temp, script) = executable_script(
            "stderr-flood",
            "i=0\nwhile [ $i -lt 20000 ]; do echo stderr-flood >&2; i=$((i+1)); done\nprintf '%s' '[{\"id\":\"n1\",\"Name\":\"ok\",\"TailscaleIP\":\"100.64.0.2\"}]'\n",
        );
        let out = run_status_command(&script, MAX_STATUS_BYTES, Duration::from_secs(2))
            .await
            .unwrap();
        assert!(String::from_utf8(out).unwrap().contains("100.64.0.2"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn process_runner_kills_and_reaps_on_stdout_overflow_promptly() {
        let (_temp, script) = executable_script(
            "overflow",
            "i=0\nwhile [ $i -lt 10000 ]; do printf x; i=$((i+1)); done\nsleep 5\n",
        );
        let started = Instant::now();
        let err = run_status_command(&script, 16, Duration::from_secs(2))
            .await
            .unwrap_err();
        assert!(matches!(err, TailscaleUnavailable::OutputLimit(_)));
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn process_runner_rejects_concurrent_process_discovery_as_busy() {
        let (_temp, script) = executable_script(
            "slow-ok",
            "sleep 1\nprintf '%s' '[{\"id\":\"n1\",\"Name\":\"ok\",\"TailscaleIP\":\"100.64.0.2\"}]'\n",
        );
        let runner = Arc::new(ProcessTailscaleStatusRunner::new(script));
        let first = {
            let runner = Arc::clone(&runner);
            tokio::spawn(async move { runner.status_json().await })
        };
        tokio::time::sleep(Duration::from_millis(50)).await;

        let err = runner.status_json().await.unwrap_err();
        assert!(
            matches!(err, TailscaleUnavailable::Busy(message) if !message.contains("100.64.0.2"))
        );
        first.await.unwrap().unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn process_runner_kills_and_reaps_on_timeout() {
        let temp = tempfile::tempdir().unwrap();
        let pid_file = temp.path().join("pid");
        let script = temp.path().join("timeout");
        let child_pid_file = temp.path().join("child_pid");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\necho $$ > {}\nsleep 10 &\necho $! > {}\nwait\n",
                pid_file.display(),
                child_pid_file.display()
            ),
        )
        .unwrap();
        make_executable(&script);

        let err = run_status_command(&script, MAX_STATUS_BYTES, Duration::from_millis(50))
            .await
            .unwrap_err();
        assert!(matches!(err, TailscaleUnavailable::Timeout(_)));
        let pid: i32 = std::fs::read_to_string(&pid_file)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        let still_alive = std::process::Command::new("kill")
            .arg("-0")
            .arg(pid.to_string())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success();
        assert!(!still_alive, "timed out child should be killed and reaped");
        let child_pid: i32 = std::fs::read_to_string(&child_pid_file)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        assert!(
            !pid_is_alive(child_pid),
            "process group child should be killed"
        );
    }

    #[cfg(unix)]
    fn executable_script(name: &str, body: &str) -> (tempfile::TempDir, PathBuf) {
        let temp = tempfile::tempdir().unwrap();
        let script = temp.path().join(name);
        std::fs::write(&script, format!("#!/bin/sh\n{body}")).unwrap();
        make_executable(&script);
        (temp, script)
    }

    #[cfg(unix)]
    fn make_executable(path: &Path) {
        let mut permissions = std::fs::metadata(path).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(path, permissions).unwrap();
    }

    #[cfg(unix)]
    fn pid_is_alive(pid: i32) -> bool {
        std::process::Command::new("kill")
            .arg("-0")
            .arg(pid.to_string())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success()
    }
}
