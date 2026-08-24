//! Quick Connect pairing-link construction and terminal QR rendering.
//!
//! The link carries only local connection metadata plus the daemon-issued
//! five-minute single-use pairing code. It never includes hook tokens, SSH
//! credentials, private keys, passwords, commands, or provider tokens.

use std::collections::HashSet;
use std::net::IpAddr;
use std::path::Path;

use base64::Engine;
use serde::Serialize;
use sha2::{Digest, Sha256};
use thiserror::Error;
use time::{Duration, OffsetDateTime};

use crate::api::tailscale;

const MAX_HOSTNAME_BYTES: usize = 255;
const MAX_COMMAND_OUTPUT_BYTES: usize = 1024 * 1024;
const DEFAULT_SSH_PORT: u16 = 22;

/// Options controlling pairing-link metadata discovery.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PairingLinkOptions {
    /// Explicit SSH target host. Wins over Tailscale and hostname discovery.
    pub ssh_host: Option<String>,
    /// Explicit SSH username. Wins over local-account discovery.
    pub ssh_user: Option<String>,
    /// SSH port for every target.
    pub ssh_port: Option<u16>,
    /// Optional SSH public host-key file to fingerprint.
    pub host_key_public_file: Option<std::path::PathBuf>,
}

/// A complete renderable pairing-link result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingLink {
    /// URL using the Swift `openpaw://pair#v1.<payload>` format.
    pub url: String,
    /// Envelope encoded by the URL.
    pub envelope: PairingEnvelopeV1,
}

/// Versioned envelope matching Swift `QuickConnectEnvelopeV1` coding keys.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PairingEnvelopeV1 {
    /// Envelope version.
    #[serde(rename = "v")]
    pub version: u8,
    /// RFC3339 issuance timestamp.
    #[serde(rename = "issued_at", with = "time::serde::rfc3339")]
    pub issued_at: OffsetDateTime,
    /// RFC3339 expiration timestamp.
    #[serde(rename = "expires_at", with = "time::serde::rfc3339")]
    pub expires_at: OffsetDateTime,
    /// Existing daemon-issued single-use code.
    #[serde(rename = "pairing_code")]
    pub pairing_code: String,
    /// Human-readable host nickname.
    pub nickname: String,
    /// SSH username to propose for explicit confirmation.
    pub username: String,
    /// Ordered candidate targets.
    pub targets: Vec<PairingTarget>,
    /// Optional host-key fingerprints.
    #[serde(rename = "host_keys")]
    pub host_keys: Vec<PairingHostKey>,
}

/// Candidate SSH target.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PairingTarget {
    /// Hostname or IP address.
    pub hostname: String,
    /// SSH port.
    pub port: u16,
    /// Metadata source, matching Swift enum raw values.
    pub source: PairingTargetSource,
}

/// Source of a candidate SSH target.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PairingTargetSource {
    /// Tailscale MagicDNS name.
    #[serde(rename = "magic_dns")]
    MagicDns,
    /// Tailscale IP address.
    Tailnet,
    /// Explicit or local hostname fallback.
    Explicit,
}

/// SSH host-key fingerprint.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PairingHostKey {
    /// SSH public-key algorithm.
    pub algorithm: String,
    /// `SHA256:<base64-without-padding>` fingerprint.
    pub fingerprint: String,
}

/// Sanitized metadata discovered for the local host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalTargetMetadata {
    /// Preferred nickname.
    pub nickname: String,
    /// Ordered discovered targets.
    pub targets: Vec<PairingTarget>,
}

/// Pairing-link construction error. Values are safe to print.
#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum PairingLinkError {
    /// Host is empty or contains unsupported/control/user-info syntax.
    #[error("invalid SSH host")]
    InvalidHost,
    /// SSH username is empty or unsafe.
    #[error("invalid SSH username")]
    InvalidUsername,
    /// SSH port is invalid.
    #[error("invalid SSH port")]
    InvalidPort,
    /// Discovery output was too large.
    #[error("local discovery output exceeded its bounded limit")]
    OutputLimit,
    /// Tailscale status JSON was invalid for local-node discovery.
    #[error("invalid local Tailscale status")]
    InvalidTailscaleStatus,
    /// No target could be discovered.
    #[error("could not discover a local SSH target")]
    MissingTarget,
    /// SSH public key file could not be parsed.
    #[error("invalid SSH host public key")]
    InvalidHostKey,
    /// JSON/link encoding failed.
    #[error("failed to encode pairing link")]
    Encoding,
}

/// Build a pairing link from an existing daemon-issued code.
pub fn build_pairing_link(
    code: &str,
    opts: &PairingLinkOptions,
    tailscale_status_json: Option<&[u8]>,
    hostname_output: Option<&[u8]>,
    local_username: Option<&str>,
    now: OffsetDateTime,
) -> Result<PairingLink, PairingLinkError> {
    let port = opts.ssh_port.unwrap_or(DEFAULT_SSH_PORT);
    validate_port(port)?;
    let username = discover_username(opts.ssh_user.as_deref(), local_username)?;
    let metadata = discover_local_targets(opts, tailscale_status_json, hostname_output, port)?;
    let host_keys = if let Some(path) = &opts.host_key_public_file {
        vec![fingerprint_public_key_file(path)?]
    } else {
        Vec::new()
    };
    let envelope = PairingEnvelopeV1 {
        version: 1,
        issued_at: now,
        expires_at: now + Duration::minutes(5),
        pairing_code: code.trim().to_ascii_uppercase(),
        nickname: metadata.nickname,
        username,
        targets: metadata.targets,
        host_keys,
    };
    let url = encode_envelope_url(&envelope)?;
    Ok(PairingLink { url, envelope })
}

/// Discover local SSH targets from explicit options, local Tailscale status, or hostname fallback.
pub fn discover_local_targets(
    opts: &PairingLinkOptions,
    tailscale_status_json: Option<&[u8]>,
    hostname_output: Option<&[u8]>,
    port: u16,
) -> Result<LocalTargetMetadata, PairingLinkError> {
    validate_port(port)?;
    if let Some(host) = &opts.ssh_host {
        let hostname = validate_host(host)?;
        return Ok(LocalTargetMetadata {
            nickname: nickname_from_host(&hostname),
            targets: vec![PairingTarget {
                hostname,
                port,
                source: PairingTargetSource::Explicit,
            }],
        });
    }
    if let Some(bytes) = tailscale_status_json {
        if bytes.len() > MAX_COMMAND_OUTPUT_BYTES {
            return Err(PairingLinkError::OutputLimit);
        }
        if let Ok(local) = tailscale::parse_self_node(bytes) {
            let mut targets = Vec::new();
            if let Some(dns) = local.dns_name {
                targets.push(PairingTarget {
                    hostname: validate_host(&dns)?,
                    port,
                    source: PairingTargetSource::MagicDns,
                });
            }
            for ip in local.tailscale_ips {
                targets.push(PairingTarget {
                    hostname: validate_host(&ip)?,
                    port,
                    source: PairingTargetSource::Tailnet,
                });
            }
            dedupe_targets(&mut targets);
            if !targets.is_empty() {
                return Ok(LocalTargetMetadata {
                    nickname: local.display_name,
                    targets,
                });
            }
        }
    }
    if let Some(bytes) = hostname_output {
        if bytes.len() > MAX_COMMAND_OUTPUT_BYTES {
            return Err(PairingLinkError::OutputLimit);
        }
        let raw = std::str::from_utf8(bytes).map_err(|_| PairingLinkError::InvalidHost)?;
        let hostname = validate_host(raw.trim())?;
        return Ok(LocalTargetMetadata {
            nickname: nickname_from_host(&hostname),
            targets: vec![PairingTarget {
                hostname,
                port,
                source: PairingTargetSource::Explicit,
            }],
        });
    }
    Err(PairingLinkError::MissingTarget)
}

/// Validate/discover username.
pub fn discover_username(
    explicit: Option<&str>,
    local: Option<&str>,
) -> Result<String, PairingLinkError> {
    if let Some(user) = explicit {
        return validate_username(user);
    }
    validate_username(local.ok_or(PairingLinkError::InvalidUsername)?)
}

/// Encode an envelope as `openpaw://pair#v1.<base64url-json>`.
pub fn encode_envelope_url(envelope: &PairingEnvelopeV1) -> Result<String, PairingLinkError> {
    let json = serde_json::to_vec(envelope).map_err(|_| PairingLinkError::Encoding)?;
    let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(json);
    Ok(format!("openpaw://pair#v1.{payload}"))
}

/// Render a terminal QR for the exact pairing-link URL.
pub fn render_terminal_qr(url: &str) -> String {
    match qrcode::QrCode::new(url.as_bytes()) {
        Ok(code) => code
            .render::<qrcode::render::unicode::Dense1x2>()
            .quiet_zone(true)
            .build(),
        Err(_) => String::new(),
    }
}

/// Parse an OpenSSH public key and return a safe SHA256 fingerprint record.
pub fn fingerprint_public_key_bytes(input: &[u8]) -> Result<PairingHostKey, PairingLinkError> {
    let text = std::str::from_utf8(input).map_err(|_| PairingLinkError::InvalidHostKey)?;
    let mut parts = text.split_whitespace();
    let algorithm = parts.next().ok_or(PairingLinkError::InvalidHostKey)?;
    let key_b64 = parts.next().ok_or(PairingLinkError::InvalidHostKey)?;
    if !matches!(
        algorithm,
        "ssh-ed25519" | "ecdsa-sha2-nistp256" | "rsa-sha2-512" | "rsa-sha2-256" | "ssh-rsa"
    ) {
        return Err(PairingLinkError::InvalidHostKey);
    }
    let key = base64::engine::general_purpose::STANDARD
        .decode(key_b64)
        .map_err(|_| PairingLinkError::InvalidHostKey)?;
    let digest = Sha256::digest(&key);
    let fingerprint = format!(
        "SHA256:{}",
        base64::engine::general_purpose::STANDARD_NO_PAD.encode(digest)
    );
    Ok(PairingHostKey {
        algorithm: algorithm.to_owned(),
        fingerprint,
    })
}

fn fingerprint_public_key_file(path: &Path) -> Result<PairingHostKey, PairingLinkError> {
    let bytes = std::fs::read(path).map_err(|_| PairingLinkError::InvalidHostKey)?;
    fingerprint_public_key_bytes(&bytes)
}

fn validate_port(port: u16) -> Result<(), PairingLinkError> {
    if port == 0 {
        Err(PairingLinkError::InvalidPort)
    } else {
        Ok(())
    }
}

fn validate_username(value: &str) -> Result<String, PairingLinkError> {
    let value = value.trim();
    if value.is_empty()
        || value.len() > 64
        || value.chars().any(char::is_control)
        || value.contains(char::is_whitespace)
        || value.contains(['/', ':', '@'])
    {
        return Err(PairingLinkError::InvalidUsername);
    }
    Ok(value.to_owned())
}

fn validate_host(value: &str) -> Result<String, PairingLinkError> {
    let value = value.trim().trim_end_matches('.');
    if value.is_empty()
        || value.len() > MAX_HOSTNAME_BYTES
        || value.chars().any(char::is_control)
        || value.chars().any(char::is_whitespace)
        || value.contains('@')
        || value.contains("://")
    {
        return Err(PairingLinkError::InvalidHost);
    }
    if value.parse::<IpAddr>().is_ok()
        || value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '.'))
    {
        Ok(value.to_ascii_lowercase())
    } else {
        Err(PairingLinkError::InvalidHost)
    }
}

fn dedupe_targets(targets: &mut Vec<PairingTarget>) {
    let mut seen = HashSet::new();
    targets.retain(|target| seen.insert((target.hostname.clone(), target.port)));
}

fn nickname_from_host(host: &str) -> String {
    host.split('.')
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or(host)
        .to_owned()
}

/// Current local username from the environment.
pub fn current_username() -> Option<String> {
    std::env::var("USER")
        .ok()
        .or_else(|| std::env::var("LOGNAME").ok())
}

/// Best-effort local hostname probe. Bounded and non-interactive.
pub async fn probe_hostname() -> Result<Vec<u8>, PairingLinkError> {
    #[cfg(unix)]
    {
        use tokio::io::AsyncReadExt;
        use tokio::process::Command;
        let mut child = Command::new("hostname")
            .arg("-f")
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|_| PairingLinkError::MissingTarget)?;
        let mut stdout = child.stdout.take().ok_or(PairingLinkError::MissingTarget)?;
        let mut bytes = Vec::new();
        let read = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            stdout.read_to_end(&mut bytes),
        )
        .await;
        let _ = child.kill().await;
        let _ = child.wait().await;
        read.map_err(|_| PairingLinkError::MissingTarget)?
            .map_err(|_| PairingLinkError::MissingTarget)?;
        if bytes.len() > MAX_COMMAND_OUTPUT_BYTES {
            return Err(PairingLinkError::OutputLimit);
        }
        Ok(bytes)
    }
    #[cfg(not(unix))]
    {
        Err(PairingLinkError::MissingTarget)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn now() -> OffsetDateTime {
        OffsetDateTime::from_unix_timestamp(1_700_000_000).unwrap()
    }
    fn status() -> Vec<u8> {
        br#"{"BackendState":"Running","Self":{"ID":"n1","HostName":"my-mac","DNSName":"my-mac.tail.ts.net.","TailscaleIPs":["100.64.1.2","fd7a:115c:a1e0::1"],"Online":true}}"#.to_vec()
    }

    #[test]
    fn explicit_overrides_win() {
        let opts = PairingLinkOptions {
            ssh_host: Some("EXAMPLE.local".into()),
            ssh_user: Some("alice".into()),
            ssh_port: Some(2222),
            host_key_public_file: None,
        };
        let link = build_pairing_link(
            "AbCd",
            &opts,
            Some(&status()),
            Some(b"fallback\n"),
            Some("bob"),
            now(),
        )
        .unwrap();
        assert_eq!(link.envelope.username, "alice");
        assert_eq!(
            link.envelope.targets,
            vec![PairingTarget {
                hostname: "example.local".into(),
                port: 2222,
                source: PairingTargetSource::Explicit
            }]
        );
    }

    #[test]
    fn tailscale_self_dns_then_ips_without_overrides() {
        let targets = discover_local_targets(
            &PairingLinkOptions::default(),
            Some(&status()),
            Some(b"fallback\n"),
            22,
        )
        .unwrap()
        .targets;
        assert_eq!(targets[0].source, PairingTargetSource::MagicDns);
        assert_eq!(targets[0].hostname, "my-mac.tail.ts.net");
        assert_eq!(targets[1].source, PairingTargetSource::Tailnet);
        assert_eq!(targets[2].source, PairingTargetSource::Tailnet);
    }

    #[test]
    fn fallback_hostname_is_used_without_tailscale() {
        let meta = discover_local_targets(
            &PairingLinkOptions::default(),
            None,
            Some(b"HostOne.local\n"),
            22,
        )
        .unwrap();
        assert_eq!(meta.targets[0].hostname, "hostone.local");
        assert_eq!(meta.targets[0].source, PairingTargetSource::Explicit);
    }

    #[test]
    fn username_precedence_and_validation() {
        assert_eq!(
            discover_username(Some("daniel"), Some("local")).unwrap(),
            "daniel"
        );
        assert_eq!(discover_username(None, Some("local")).unwrap(), "local");
        assert_eq!(
            discover_username(Some("bad user"), Some("local")),
            Err(PairingLinkError::InvalidUsername)
        );
    }

    #[test]
    fn rejects_invalid_hosts_and_unbounded_output() {
        assert_eq!(
            discover_local_targets(
                &PairingLinkOptions {
                    ssh_host: Some("u@example.com".into()),
                    ..Default::default()
                },
                None,
                None,
                22
            ),
            Err(PairingLinkError::InvalidHost)
        );
        assert_eq!(
            discover_local_targets(
                &PairingLinkOptions::default(),
                None,
                Some(b"bad host\n"),
                22
            ),
            Err(PairingLinkError::InvalidHost)
        );
        let huge = vec![b'a'; MAX_COMMAND_OUTPUT_BYTES + 1];
        assert_eq!(
            discover_local_targets(&PairingLinkOptions::default(), None, Some(&huge), 22),
            Err(PairingLinkError::OutputLimit)
        );
    }

    #[test]
    fn public_key_fingerprint_uses_sha256_without_key_bytes() {
        let key = b"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICvP7z4QMa0kZVNuclUMViZFSEWPBX9l7H9w4ff6Bk3H host\n";
        let fp = fingerprint_public_key_bytes(key).unwrap();
        assert_eq!(fp.algorithm, "ssh-ed25519");
        assert!(fp.fingerprint.starts_with("SHA256:"));
        let encoded = serde_json::to_string(&fp).unwrap();
        assert!(!encoded.contains("AAAAC3"));
    }

    #[test]
    fn envelope_contains_code_but_not_hook_token() {
        let link = build_pairing_link(
            "pair-123",
            &PairingLinkOptions::default(),
            Some(&status()),
            None,
            Some("alice"),
            now(),
        )
        .unwrap();
        let decoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(link.url.split("v1.").nth(1).unwrap())
            .unwrap();
        let json = String::from_utf8(decoded).unwrap();
        assert!(json.contains("PAIR-123"));
        assert!(!json.contains("hook-token"));
        assert!(!json.contains("secret"));
    }

    #[test]
    fn qr_and_link_render_the_same_exact_envelope() {
        let link = build_pairing_link(
            "PAIR",
            &PairingLinkOptions::default(),
            Some(&status()),
            None,
            Some("alice"),
            now(),
        )
        .unwrap();
        let qr = render_terminal_qr(&link.url);
        assert!(!qr.is_empty());
        let encoded = encode_envelope_url(&link.envelope).unwrap();
        assert_eq!(encoded, link.url);
    }

    #[test]
    fn code_only_output_helper_remains_compatible() {
        assert_eq!(code_stdout("AbC123"), "AbC123\n");
    }

    #[test]
    fn swift_field_names_and_fragment_shape_match() {
        let link = build_pairing_link(
            "PAIR",
            &PairingLinkOptions::default(),
            Some(&status()),
            None,
            Some("alice"),
            now(),
        )
        .unwrap();
        assert!(link.url.starts_with("openpaw://pair#v1."));
        let decoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(link.url.split("v1.").nth(1).unwrap())
            .unwrap();
        let value: Value = serde_json::from_slice(&decoded).unwrap();
        assert!(value.get("v").is_some());
        assert!(value.get("issued_at").is_some());
        assert!(value.get("expires_at").is_some());
        assert!(value.get("pairing_code").is_some());
        assert!(value.get("host_keys").is_some());
    }
}

/// Existing code-only stdout rendering: intentionally just code plus newline.
pub fn code_stdout(code: &str) -> String {
    format!("{code}\n")
}
