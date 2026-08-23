use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::wire_enum::wire_enum;

wire_enum! { pub enum ProviderId { Github = "github", HuggingFace = "huggingface", } }
wire_enum! { pub enum ProviderConnectionState { Disconnected = "disconnected", Authorizing = "authorizing", Connected = "connected", Error = "error", } }
wire_enum! { pub enum ProviderAuthorizationState { Pending = "pending", SlowDown = "slow_down", Authorized = "authorized", Denied = "denied", Expired = "expired", Cancelled = "cancelled", } }
wire_enum! { pub enum RepoImportState { Queued = "queued", Cloning = "cloning", Indexing = "indexing", Completed = "completed", Failed = "failed", Cancelled = "cancelled", } }

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
    pub authorization_id: String,
    pub state: ProviderAuthorizationState,
    pub provider: ProviderId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account_label: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderRepo {
    pub id: String,
    pub provider: ProviderId,
    pub owner: String,
    pub name: String,
    pub display_name: String,
    pub is_private: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clone_url_redacted: Option<String>,
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
    pub repo_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requested_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RepoRegisterRequest {
    pub root_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requested_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RepoImportProgress {
    pub id: String,
    pub state: RepoImportState,
    pub repo_name: String,
    pub destination_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub percent: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_url_redacted: Option<String>,
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
