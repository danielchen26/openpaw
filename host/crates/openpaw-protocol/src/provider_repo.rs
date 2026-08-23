use serde::de::{self, Deserializer};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::wire_enum::wire_enum;

wire_enum! { pub enum ProviderId { Github = "github", HuggingFace = "huggingface", } }
wire_enum! { pub enum ProviderConnectionState { Disconnected = "disconnected", Authorizing = "authorizing", Connected = "connected", ReauthorizationRequired = "reauthorization_required", Outage = "outage", Error = "error", } }
wire_enum! { pub enum ProviderAuthorizationState { Pending = "pending", SlowDown = "slow_down", Authorized = "authorized", Denied = "denied", Expired = "expired", Cancelled = "cancelled", ReauthorizationRequired = "reauthorization_required", Outage = "outage", } }
wire_enum! { pub enum RepoImportState { Queued = "queued", Authorizing = "authorizing", Cloning = "cloning", Validating = "validating", Registering = "registering", Completed = "completed", Failed = "failed", Cancelled = "cancelled", RecoveryRequired = "recovery_required", } }

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderStatus {
    pub id: ProviderId,
    pub display_name: String,
    pub state: ProviderConnectionState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account_label: Option<String>,
    #[serde(default)]
    pub scopes: Vec<String>,
    pub repo_listing_supported: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderAuthorizationStart {
    #[serde(deserialize_with = "deserialize_wire_identifier")]
    pub authorization_id: String,
    pub verification_url: String,
    pub user_code: String,
    #[serde(with = "time::serde::rfc3339")]
    pub expires_at: OffsetDateTime,
    pub interval_seconds: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderAuthorizationStatus {
    #[serde(deserialize_with = "deserialize_wire_identifier")]
    pub authorization_id: String,
    pub state: ProviderAuthorizationState,
    pub provider: ProviderId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account_label: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderRepo {
    #[serde(deserialize_with = "deserialize_wire_identifier")]
    pub id: String,
    pub provider: ProviderId,
    pub owner: String,
    pub name: String,
    pub display_name: String,
    pub is_private: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_url_redacted: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderRepoPage {
    pub repos: Vec<ProviderRepo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RepoImportRequest {
    pub provider: ProviderId,
    #[serde(deserialize_with = "deserialize_wire_identifier")]
    pub repo_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(deserialize_with = "deserialize_optional_requested_name")]
    pub requested_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RepoRegisterRequest {
    #[serde(deserialize_with = "deserialize_wire_identifier")]
    pub root_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(deserialize_with = "deserialize_optional_requested_name")]
    pub requested_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RepoImportProgress {
    #[serde(deserialize_with = "deserialize_wire_identifier")]
    pub id: String,
    pub state: RepoImportState,
    pub repo_name: String,
    pub destination_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(deserialize_with = "deserialize_optional_percent")]
    pub percent: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(deserialize_with = "deserialize_optional_message")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_url_redacted: Option<String>,
}

fn deserialize_wire_identifier<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    let value = String::deserialize(deserializer)?;
    validate_wire_identifier(&value).map_err(de::Error::custom)?;
    Ok(value)
}

fn deserialize_optional_requested_name<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<String>::deserialize(deserializer)?;
    if let Some(name) = value.as_deref() {
        validate_wire_identifier(name).map_err(de::Error::custom)?;
    }
    Ok(value)
}

fn deserialize_optional_percent<'de, D>(deserializer: D) -> Result<Option<u8>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<u16>::deserialize(deserializer)?;
    match value {
        Some(percent) if percent <= 100 => Ok(Some(percent as u8)),
        Some(_) => Err(de::Error::custom("percent must be between 0 and 100")),
        None => Ok(None),
    }
}

fn deserialize_optional_message<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<String>::deserialize(deserializer)?;
    if let Some(message) = value.as_deref()
        && message.chars().count() > 500
    {
        return Err(de::Error::custom("message must be at most 500 characters"));
    }
    Ok(value)
}

fn validate_wire_identifier(value: &str) -> Result<(), &'static str> {
    if value.is_empty() || value.len() > 128 {
        return Err("identifier must be 1..=128 bytes");
    }
    if value.starts_with('-') || value.contains("..") {
        return Err("identifier cannot traverse or start with dash");
    }
    let lower = value.to_ascii_lowercase();
    if lower.contains("%2f") || lower.contains("%5c") {
        return Err("identifier cannot contain encoded separators");
    }
    if value
        .chars()
        .any(|ch| ch.is_control() || ch == '/' || ch == '\\')
    {
        return Err("identifier cannot contain controls or separators");
    }
    if !value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | '.'))
    {
        return Err("identifier must match [A-Za-z0-9_.-]+");
    }
    Ok(())
}

pub fn redact_url_credentials(input: &str) -> String {
    if let Some(scheme_end) = input.find("://") {
        let auth_start = scheme_end + 3;
        if let Some(at_rel) = input[auth_start..].find('@') {
            let at = auth_start + at_rel;
            let slash = input[auth_start..]
                .find('/')
                .map(|i| auth_start + i)
                .unwrap_or(input.len());
            if at < slash {
                return format!("{}<redacted>@{}", &input[..auth_start], &input[at + 1..]);
            }
        }
    }
    input.to_owned()
}
