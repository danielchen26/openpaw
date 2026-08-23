//! Secret-safe provider abstraction for GitHub and Hugging Face.

use reqwest::header::{HeaderMap, LINK};
use serde::{Deserialize, Serialize};
use std::{fmt, path::PathBuf, sync::Arc, time::Duration as StdDuration};
use time::{Duration, OffsetDateTime};
use tokio::sync::Mutex;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SecretToken(String);
impl SecretToken {
    pub fn new(value: String) -> Self {
        Self(value)
    }
    pub fn expose_secret(&self) -> &str {
        &self.0
    }
}
impl fmt::Debug for SecretToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SecretToken(<redacted>)")
    }
}
impl fmt::Display for SecretToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("<redacted>")
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ProviderError {
    #[error("http status {status} from {url}")]
    HttpStatus {
        url: String,
        status: u16,
        rate_limit: Option<RateLimitState>,
    },
    #[error("transport error contacting {url}: {message}")]
    Transport { url: String, message: String },
    #[error("provider outage: {0}")]
    Outage(String),
    #[error("authorization denied")]
    Denied,
    #[error("authorization expired")]
    Expired,
    #[error("authorization cancelled")]
    Cancelled,
    #[error("token must be refreshed or user must reauthorize")]
    ReauthorizationRequired,
    #[error("remote revoke is unsupported for this public provider client; local disconnect only")]
    RemoteRevokeUnsupported,
    #[error("remote revoke requires confidential client configuration")]
    MissingConfidentialClient,
    #[error("io error: {0}")]
    Io(String),
    #[error("protocol error: {0}")]
    Protocol(String),
}
impl ProviderError {
    pub fn http_status(url: impl Into<String>, status: u16, _secret: Option<SecretToken>) -> Self {
        Self::HttpStatus {
            url: url.into(),
            status,
            rate_limit: None,
        }
    }
}
impl From<std::io::Error> for ProviderError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e.to_string())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RateLimitState {
    pub limit: Option<u64>,
    pub remaining: Option<u64>,
    pub retry_after_seconds: Option<u64>,
    pub reset_at: Option<OffsetDateTime>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProviderKind {
    GitHub,
    HuggingFace,
}
#[derive(Clone, Debug)]
pub struct PublicClientConfig {
    pub client_id: String,
    pub auth_base: String,
    pub api_base: String,
    pub token_endpoint: String,
    pub device_endpoint: String,
    pub confidential: Option<ConfidentialClientConfig>,
    pub kind: ProviderKind,
}
#[derive(Clone, Debug)]
pub struct ConfidentialClientConfig {
    pub client_secret: SecretToken,
    pub revoke_endpoint: String,
}
impl PublicClientConfig {
    pub fn github_app(
        client_id: impl Into<String>,
        auth_base: impl Into<String>,
        api_base: impl Into<String>,
    ) -> Self {
        let auth_base = auth_base.into();
        Self {
            client_id: client_id.into(),
            api_base: api_base.into(),
            device_endpoint: format!("{auth_base}/login/device/code"),
            token_endpoint: format!("{auth_base}/login/oauth/access_token"),
            auth_base,
            confidential: None,
            kind: ProviderKind::GitHub,
        }
    }
    pub fn hugging_face(
        client_id: impl Into<String>,
        auth_base: impl Into<String>,
        api_base: impl Into<String>,
    ) -> Self {
        let auth_base = auth_base.into();
        Self {
            client_id: client_id.into(),
            api_base: api_base.into(),
            device_endpoint: format!("{auth_base}/oauth/device"),
            token_endpoint: format!("{auth_base}/oauth/token"),
            auth_base,
            confidential: None,
            kind: ProviderKind::HuggingFace,
        }
    }
    pub fn with_confidential(
        mut self,
        client_secret: SecretToken,
        revoke_endpoint: impl Into<String>,
    ) -> Self {
        self.confidential = Some(ConfidentialClientConfig {
            client_secret,
            revoke_endpoint: revoke_endpoint.into(),
        });
        self
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DevicePollState {
    Pending { interval_seconds: u64 },
    SlowDown { interval_seconds: u64 },
    Authorized(TokenSet),
    Denied,
    Expired,
    Cancelled,
    Outage,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DeviceAuthorization {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub expires_in: u64,
    pub interval: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct TokenSet {
    pub access_token: SecretToken,
    pub refresh_token: Option<SecretToken>,
    pub expires_at: Option<OffsetDateTime>,
    pub scopes: Vec<String>,
}
impl TokenSet {
    pub fn short_lived(
        access_token: SecretToken,
        refresh_token: Option<SecretToken>,
        expires_in: u64,
        scopes: Vec<String>,
    ) -> Self {
        Self {
            access_token,
            refresh_token,
            expires_at: Some(
                OffsetDateTime::now_utc()
                    + Duration::seconds(expires_in.try_into().unwrap_or(i64::MAX)),
            ),
            scopes,
        }
    }
    pub fn is_expiring(&self) -> bool {
        self.expires_at
            .is_some_and(|t| t <= OffsetDateTime::now_utc() + Duration::minutes(2))
    }
    pub fn ensure_usable(&self) -> Result<(), ProviderError> {
        if self.is_expiring() && self.refresh_token.is_none() {
            Err(ProviderError::ReauthorizationRequired)
        } else {
            Ok(())
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SanitizedStatus {
    pub identity: Option<String>,
    pub scopes: Vec<String>,
    pub authorized: bool,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Repository {
    pub owner: String,
    pub name: String,
    pub https_url: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CloneSpec {
    pub url: String,
    pub username: String,
    pub password: SecretToken,
}

#[derive(Clone, Debug)]
pub struct GitHubProvider {
    cfg: PublicClientConfig,
    client: reqwest::Client,
}
#[derive(Clone, Debug)]
pub struct HuggingFaceProvider {
    cfg: PublicClientConfig,
    client: reqwest::Client,
}
fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(StdDuration::from_secs(20))
        .connect_timeout(StdDuration::from_secs(5))
        .build()
        .expect("reqwest client")
}
impl GitHubProvider {
    pub fn new(cfg: PublicClientConfig) -> Self {
        Self {
            cfg,
            client: client(),
        }
    }
    pub fn minimum_scopes(&self) -> &'static [&'static str] {
        &["read:user"]
    }
    pub fn required_repo_scopes(&self) -> &'static [&'static str] {
        &["repo"]
    }
    pub async fn begin_device_authorization(
        &self,
        scopes: &[&str],
    ) -> Result<DeviceAuthorization, ProviderError> {
        self.begin_device_authorization_with_cancel(scopes, None)
            .await
    }
    pub async fn begin_device_authorization_with_cancel(
        &self,
        scopes: &[&str],
        cancel: Option<&CancellationFlag>,
    ) -> Result<DeviceAuthorization, ProviderError> {
        post_form(
            &self.client,
            &self.cfg.device_endpoint,
            &[
                ("client_id", self.cfg.client_id.as_str()),
                ("scope", &scopes.join(" ")),
            ],
            cancel,
        )
        .await
    }
    pub async fn poll_device_authorization(
        &self,
        device_code: &str,
    ) -> Result<DevicePollState, ProviderError> {
        self.poll_device_authorization_with_interval(device_code, 5)
            .await
    }
    pub async fn poll_device_authorization_with_interval(
        &self,
        device_code: &str,
        interval: u64,
    ) -> Result<DevicePollState, ProviderError> {
        self.poll_device_authorization_with_interval_and_cancel(device_code, interval, None)
            .await
    }
    pub async fn poll_device_authorization_with_interval_and_cancel(
        &self,
        device_code: &str,
        interval: u64,
        cancel: Option<&CancellationFlag>,
    ) -> Result<DevicePollState, ProviderError> {
        poll_token(
            &self.client,
            &self.cfg.token_endpoint,
            &[
                ("client_id", self.cfg.client_id.as_str()),
                ("device_code", device_code),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ],
            interval,
            cancel,
        )
        .await
    }
    pub async fn refresh(&self, refresh_token: &SecretToken) -> Result<TokenSet, ProviderError> {
        self.refresh_with_cancel(refresh_token, None).await
    }
    pub async fn refresh_with_cancel(
        &self,
        refresh_token: &SecretToken,
        cancel: Option<&CancellationFlag>,
    ) -> Result<TokenSet, ProviderError> {
        token_response(
            &self.client,
            &self.cfg.token_endpoint,
            &[
                ("client_id", self.cfg.client_id.as_str()),
                ("refresh_token", refresh_token.expose_secret()),
                ("grant_type", "refresh_token"),
            ],
            cancel,
        )
        .await
    }
    pub async fn list_repositories(
        &self,
        token: &SecretToken,
    ) -> Result<Vec<Repository>, ProviderError> {
        self.list_repositories_with_cancel(token, None).await
    }
    pub async fn list_repositories_with_cancel(
        &self,
        token: &SecretToken,
        cancel: Option<&CancellationFlag>,
    ) -> Result<Vec<Repository>, ProviderError> {
        list_github_repos(&self.client, &self.cfg.api_base, token, cancel).await
    }
    pub fn validate_required_scopes(
        &self,
        token: &TokenSet,
        required: &[&str],
    ) -> Result<(), ProviderError> {
        validate_scopes(&token.scopes, required)
    }
    pub fn clone_spec(
        &self,
        repo: &Repository,
        token: SecretToken,
    ) -> Result<CloneSpec, ProviderError> {
        validate_repo(repo, ProviderKind::GitHub)?;
        Ok(CloneSpec {
            url: repo.https_url.clone(),
            username: "x-access-token".into(),
            password: token,
        })
    }
    pub fn status(&self, identity: Option<String>, token: Option<&TokenSet>) -> SanitizedStatus {
        SanitizedStatus {
            identity,
            scopes: token.map_or_else(Vec::new, |t| t.scopes.clone()),
            authorized: token.is_some(),
        }
    }
    pub async fn revoke_remote(&self, token: &SecretToken) -> Result<(), ProviderError> {
        self.revoke_remote_with_cancel(token, None).await
    }
    pub async fn revoke_remote_with_cancel(
        &self,
        token: &SecretToken,
        cancel: Option<&CancellationFlag>,
    ) -> Result<(), ProviderError> {
        revoke(&self.client, &self.cfg, token, cancel).await
    }
}
impl HuggingFaceProvider {
    pub fn new(cfg: PublicClientConfig) -> Self {
        Self {
            cfg,
            client: client(),
        }
    }
    pub fn minimum_scopes(&self) -> &'static [&'static str] {
        &["openid", "profile", "read-repos"]
    }
    pub async fn begin_device_authorization(
        &self,
        scopes: &[&str],
    ) -> Result<DeviceAuthorization, ProviderError> {
        self.begin_device_authorization_with_cancel(scopes, None)
            .await
    }
    pub async fn begin_device_authorization_with_cancel(
        &self,
        scopes: &[&str],
        cancel: Option<&CancellationFlag>,
    ) -> Result<DeviceAuthorization, ProviderError> {
        post_form(
            &self.client,
            &self.cfg.device_endpoint,
            &[
                ("client_id", self.cfg.client_id.as_str()),
                ("scope", &scopes.join(" ")),
            ],
            cancel,
        )
        .await
    }
    pub async fn poll_device_authorization(
        &self,
        device_code: &str,
    ) -> Result<DevicePollState, ProviderError> {
        self.poll_device_authorization_with_interval(device_code, 5)
            .await
    }
    pub async fn poll_device_authorization_with_interval(
        &self,
        device_code: &str,
        interval: u64,
    ) -> Result<DevicePollState, ProviderError> {
        self.poll_device_authorization_with_interval_and_cancel(device_code, interval, None)
            .await
    }
    pub async fn poll_device_authorization_with_interval_and_cancel(
        &self,
        device_code: &str,
        interval: u64,
        cancel: Option<&CancellationFlag>,
    ) -> Result<DevicePollState, ProviderError> {
        poll_token(
            &self.client,
            &self.cfg.token_endpoint,
            &[
                ("client_id", self.cfg.client_id.as_str()),
                ("device_code", device_code),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ],
            interval,
            cancel,
        )
        .await
    }
    pub async fn refresh(&self, refresh_token: &SecretToken) -> Result<TokenSet, ProviderError> {
        self.refresh_with_cancel(refresh_token, None).await
    }
    pub async fn refresh_with_cancel(
        &self,
        refresh_token: &SecretToken,
        cancel: Option<&CancellationFlag>,
    ) -> Result<TokenSet, ProviderError> {
        token_response(
            &self.client,
            &self.cfg.token_endpoint,
            &[
                ("client_id", self.cfg.client_id.as_str()),
                ("refresh_token", refresh_token.expose_secret()),
                ("grant_type", "refresh_token"),
            ],
            cancel,
        )
        .await
    }
    pub async fn list_repositories(
        &self,
        token: &SecretToken,
    ) -> Result<Vec<Repository>, ProviderError> {
        self.list_repositories_with_cancel(token, None).await
    }
    pub async fn list_repositories_with_cancel(
        &self,
        token: &SecretToken,
        cancel: Option<&CancellationFlag>,
    ) -> Result<Vec<Repository>, ProviderError> {
        list_hf_repos(&self.client, &self.cfg.api_base, token, cancel).await
    }
    pub fn clone_spec(
        &self,
        repo: &Repository,
        token: SecretToken,
    ) -> Result<CloneSpec, ProviderError> {
        validate_repo(repo, ProviderKind::HuggingFace)?;
        Ok(CloneSpec {
            url: repo.https_url.clone(),
            username: repo.owner.clone(),
            password: token,
        })
    }
    pub fn status(&self, identity: Option<String>, token: Option<&TokenSet>) -> SanitizedStatus {
        SanitizedStatus {
            identity,
            scopes: token.map_or_else(Vec::new, |t| t.scopes.clone()),
            authorized: token.is_some(),
        }
    }
    pub async fn revoke_remote(&self, token: &SecretToken) -> Result<(), ProviderError> {
        self.revoke_remote_with_cancel(token, None).await
    }
    pub async fn revoke_remote_with_cancel(
        &self,
        token: &SecretToken,
        cancel: Option<&CancellationFlag>,
    ) -> Result<(), ProviderError> {
        revoke(&self.client, &self.cfg, token, cancel).await
    }
}

async fn post_form<T: for<'de> Deserialize<'de>>(
    client: &reqwest::Client,
    url: &str,
    form: &[(&str, &str)],
    cancel: Option<&CancellationFlag>,
) -> Result<T, ProviderError> {
    check_cancelled(cancel)?;
    let body = form
        .iter()
        .map(|(k, v)| {
            format!(
                "{}={}",
                url::form_urlencoded::byte_serialize(k.as_bytes()).collect::<String>(),
                url::form_urlencoded::byte_serialize(v.as_bytes()).collect::<String>()
            )
        })
        .collect::<Vec<_>>()
        .join("&");
    let r = client
        .post(url)
        .header("Accept", "application/json")
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(body)
        .send()
        .await
        .map_err(|e| ProviderError::Transport {
            url: url.into(),
            message: e.to_string(),
        })?;
    check_cancelled(cancel)?;
    let status = r.status();
    let headers = r.headers().clone();
    let bytes = r.bytes().await.map_err(|e| ProviderError::Transport {
        url: url.into(),
        message: e.to_string(),
    })?;
    check_cancelled(cancel)?;
    if !status.is_success() {
        if let Ok(v) = serde_json::from_slice::<T>(&bytes) {
            return Ok(v);
        }
        return Err(http_err(url, status.as_u16(), &headers));
    }
    serde_json::from_slice(&bytes).map_err(|e| ProviderError::Protocol(e.to_string()))
}
async fn poll_token(
    client: &reqwest::Client,
    url: &str,
    form: &[(&str, &str)],
    interval: u64,
    cancel: Option<&CancellationFlag>,
) -> Result<DevicePollState, ProviderError> {
    let v: serde_json::Value = post_form(client, url, form, cancel).await?;
    if let Some(e) = v.get("error").and_then(|x| x.as_str()) {
        return Ok(match e {
            "authorization_pending" => DevicePollState::Pending {
                interval_seconds: interval,
            },
            "slow_down" => DevicePollState::SlowDown {
                interval_seconds: v
                    .get("interval")
                    .and_then(|x| x.as_u64())
                    .unwrap_or(interval + 5),
            },
            "access_denied" => DevicePollState::Denied,
            "expired_token" => DevicePollState::Expired,
            "cancelled" => DevicePollState::Cancelled,
            "temporarily_unavailable" | "server_error" => DevicePollState::Outage,
            _ => return Err(ProviderError::Protocol(format!("unknown device error {e}"))),
        });
    }
    Ok(DevicePollState::Authorized(parse_token(v)?))
}
async fn token_response(
    client: &reqwest::Client,
    url: &str,
    form: &[(&str, &str)],
    cancel: Option<&CancellationFlag>,
) -> Result<TokenSet, ProviderError> {
    let v: serde_json::Value = post_form(client, url, form, cancel).await?;
    parse_token(v)
}
fn parse_token(v: serde_json::Value) -> Result<TokenSet, ProviderError> {
    let access = v
        .get("access_token")
        .and_then(|x| x.as_str())
        .ok_or_else(|| ProviderError::Protocol("missing access_token".into()))?;
    let scopes = parse_scopes(v.get("scope").and_then(|x| x.as_str()).unwrap_or(""));
    Ok(TokenSet {
        access_token: SecretToken::new(access.into()),
        refresh_token: v
            .get("refresh_token")
            .and_then(|x| x.as_str())
            .map(|s| SecretToken::new(s.into())),
        expires_at: v.get("expires_in").and_then(|x| x.as_u64()).map(|e| {
            OffsetDateTime::now_utc() + Duration::seconds(e.try_into().unwrap_or(i64::MAX))
        }),
        scopes,
    })
}
fn parse_scopes(s: &str) -> Vec<String> {
    s.split(|c: char| c == ',' || c.is_whitespace())
        .filter(|p| !p.is_empty())
        .map(str::to_string)
        .collect()
}
fn validate_scopes(granted: &[String], required: &[&str]) -> Result<(), ProviderError> {
    let missing: Vec<_> = required
        .iter()
        .filter(|r| !granted.iter().any(|g| g == **r))
        .copied()
        .collect();
    if missing.is_empty() {
        Ok(())
    } else {
        Err(ProviderError::Protocol(format!(
            "missing required scopes: {}",
            missing.join(",")
        )))
    }
}

struct JsonWithHeaders<T> {
    value: T,
    headers: HeaderMap,
}
async fn get_json<T: for<'de> Deserialize<'de>>(
    client: &reqwest::Client,
    url: &str,
    token: &SecretToken,
    cancel: Option<&CancellationFlag>,
) -> Result<JsonWithHeaders<T>, ProviderError> {
    check_cancelled(cancel)?;
    let r = client
        .get(url)
        .bearer_auth(token.expose_secret())
        .send()
        .await
        .map_err(|e| ProviderError::Transport {
            url: url.into(),
            message: e.to_string(),
        })?;
    check_cancelled(cancel)?;
    let status = r.status();
    let headers = r.headers().clone();
    if !status.is_success() {
        return Err(http_err(url, status.as_u16(), &headers));
    }
    Ok(JsonWithHeaders {
        value: r
            .json()
            .await
            .map_err(|e| ProviderError::Protocol(e.to_string()))?,
        headers,
    })
}
fn http_err(url: &str, status: u16, headers: &HeaderMap) -> ProviderError {
    ProviderError::HttpStatus {
        url: url.into(),
        status,
        rate_limit: parse_rate_limit(headers),
    }
}
fn parse_rate_limit(headers: &HeaderMap) -> Option<RateLimitState> {
    let retry_after_seconds = headers
        .get("retry-after")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse().ok());
    let gh_reset = headers
        .get("x-ratelimit-reset")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse::<i64>().ok())
        .and_then(|ts| OffsetDateTime::from_unix_timestamp(ts).ok());
    let hf_ratelimit = headers
        .get("ratelimit")
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);
    let hf_reset = hf_ratelimit
        .as_deref()
        .and_then(|s| header_param(s, "t").or_else(|| header_param(s, "w")))
        .map(|s| OffsetDateTime::now_utc() + Duration::seconds(s.try_into().unwrap_or(i64::MAX)));
    let limit = headers
        .get("x-ratelimit-limit")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse().ok())
        .or_else(|| {
            headers
                .get("ratelimit-policy")
                .and_then(|v| v.to_str().ok())
                .and_then(|s| header_param(s, "q"))
        });
    let remaining = headers
        .get("x-ratelimit-remaining")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse().ok())
        .or_else(|| hf_ratelimit.as_deref().and_then(|s| header_param(s, "r")));
    if retry_after_seconds.is_some()
        || gh_reset.is_some()
        || hf_reset.is_some()
        || limit.is_some()
        || remaining.is_some()
    {
        Some(RateLimitState {
            limit,
            remaining,
            retry_after_seconds,
            reset_at: gh_reset.or(hf_reset),
        })
    } else {
        None
    }
}
fn header_param(s: &str, key: &str) -> Option<u64> {
    s.split(';')
        .find_map(|p| p.trim().strip_prefix(&format!("{key}="))?.parse().ok())
}
fn next_link(headers: &HeaderMap) -> Option<String> {
    headers
        .get(LINK)?
        .to_str()
        .ok()?
        .split(',')
        .find_map(|part| {
            let p = part.trim();
            if !p.contains("rel=\"next\"") && !p.contains("rel=next") {
                return None;
            }
            Some(p.split_once('<')?.1.split_once('>')?.0.to_string())
        })
}

async fn list_github_repos(
    client: &reqwest::Client,
    api: &str,
    token: &SecretToken,
    cancel: Option<&CancellationFlag>,
) -> Result<Vec<Repository>, ProviderError> {
    let mut url = format!("{api}/user/repos?per_page=100&page=1");
    let mut out = Vec::new();
    loop {
        let got: JsonWithHeaders<Vec<serde_json::Value>> =
            get_json(client, &url, token, cancel).await?;
        check_cancelled(cancel)?;
        for v in got.value {
            out.push(parse_github_repo(v)?);
        }
        if let Some(next) = next_link(&got.headers) {
            url = resolve_next_url(&url, &next)?;
        } else {
            break;
        }
    }
    Ok(out)
}
fn parse_github_repo(v: serde_json::Value) -> Result<Repository, ProviderError> {
    let owner = v
        .pointer("/owner/login")
        .and_then(|x| x.as_str())
        .ok_or_else(|| ProviderError::Protocol("malformed GitHub repo owner".into()))?;
    let name = v
        .get("name")
        .and_then(|x| x.as_str())
        .ok_or_else(|| ProviderError::Protocol("malformed GitHub repo name".into()))?;
    let url = v
        .get("clone_url")
        .and_then(|x| x.as_str())
        .ok_or_else(|| ProviderError::Protocol("malformed GitHub clone_url".into()))?;
    let repo = Repository {
        owner: owner.into(),
        name: name.into(),
        https_url: url.into(),
    };
    validate_repo(&repo, ProviderKind::GitHub)?;
    Ok(repo)
}
async fn list_hf_repos(
    client: &reqwest::Client,
    api: &str,
    token: &SecretToken,
    cancel: Option<&CancellationFlag>,
) -> Result<Vec<Repository>, ProviderError> {
    let who: JsonWithHeaders<serde_json::Value> =
        get_json(client, &format!("{api}/api/whoami-v2"), token, cancel).await?;
    let author = who
        .value
        .get("name")
        .or_else(|| who.value.get("user").and_then(|u| u.get("name")))
        .and_then(|x| x.as_str())
        .ok_or_else(|| ProviderError::Protocol("malformed Hugging Face identity".into()))?;
    let mut out = Vec::new();
    for kind in ["models", "datasets", "spaces"] {
        let author: String = url::form_urlencoded::byte_serialize(author.as_bytes()).collect();
        let mut url = format!("{api}/api/{kind}?limit=100&full=false&author={author}");
        loop {
            let got: JsonWithHeaders<serde_json::Value> =
                get_json(client, &url, token, cancel).await?;
            check_cancelled(cancel)?;
            let arr = got
                .value
                .as_array()
                .cloned()
                .or_else(|| got.value.get("items").and_then(|x| x.as_array()).cloned())
                .unwrap_or_default();
            for item in arr {
                out.push(parse_hf_repo(item, kind)?);
            }
            if let Some(next) = next_link(&got.headers) {
                url = resolve_next_url(&url, &next)?;
            } else {
                break;
            }
        }
    }
    Ok(out)
}
fn resolve_next_url(current_url: &str, next: &str) -> Result<String, ProviderError> {
    if next.starts_with("http://") || next.starts_with("https://") {
        return Ok(next.to_string());
    }
    let base = url::Url::parse(current_url)
        .map_err(|_| ProviderError::Protocol("invalid pagination URL".into()))?;
    base.join(next)
        .map(|u| u.to_string())
        .map_err(|_| ProviderError::Protocol("invalid pagination Link URL".into()))
}
fn parse_hf_repo(item: serde_json::Value, kind: &str) -> Result<Repository, ProviderError> {
    let id = item
        .get("id")
        .or_else(|| item.get("modelId"))
        .and_then(|x| x.as_str())
        .ok_or_else(|| ProviderError::Protocol("malformed Hugging Face repo id".into()))?;
    let (owner, name) = id.split_once('/').ok_or_else(|| {
        ProviderError::Protocol("Hugging Face repo id must be user-scoped".into())
    })?;
    let prefix = match kind {
        "datasets" => "datasets/",
        "spaces" => "spaces/",
        _ => "",
    };
    let repo = Repository {
        owner: owner.into(),
        name: name.into(),
        https_url: format!("https://huggingface.co/{prefix}{id}"),
    };
    validate_repo(&repo, ProviderKind::HuggingFace)?;
    Ok(repo)
}
fn validate_repo(repo: &Repository, kind: ProviderKind) -> Result<(), ProviderError> {
    if repo.owner.is_empty()
        || repo.name.is_empty()
        || repo.owner.contains('/')
        || repo.name.contains('/')
        || repo.owner.contains("..")
        || repo.name.contains("..")
    {
        return Err(ProviderError::Protocol(
            "invalid repository identity".into(),
        ));
    }
    let u = url::Url::parse(&repo.https_url)
        .map_err(|_| ProviderError::Protocol("invalid clone URL".into()))?;
    if u.scheme() != "https"
        || u.username() != ""
        || u.password().is_some()
        || u.host_str().is_none()
        || u.port().is_some()
        || u.query().is_some()
        || u.fragment().is_some()
    {
        return Err(ProviderError::Protocol("unsafe clone URL".into()));
    }
    let exact_prefix = match kind {
        ProviderKind::GitHub => "https://github.com/",
        ProviderKind::HuggingFace => "https://huggingface.co/",
    };
    if !repo.https_url.starts_with(exact_prefix) {
        return Err(ProviderError::Protocol(
            "unapproved clone URL authority".into(),
        ));
    }
    if kind == ProviderKind::GitHub && u.host_str() != Some("github.com") {
        return Err(ProviderError::Protocol(
            "unapproved GitHub clone host".into(),
        ));
    }
    if kind == ProviderKind::HuggingFace && u.host_str() != Some("huggingface.co") {
        return Err(ProviderError::Protocol(
            "unapproved Hugging Face clone host".into(),
        ));
    }
    if kind == ProviderKind::GitHub
        && !u
            .path()
            .ends_with(&format!("/{}/{}.git", repo.owner, repo.name))
    {
        return Err(ProviderError::Protocol(
            "clone URL does not match repository identity".into(),
        ));
    }
    if kind == ProviderKind::HuggingFace
        && !u
            .path()
            .ends_with(&format!("/{}/{}", repo.owner, repo.name))
    {
        return Err(ProviderError::Protocol(
            "clone URL does not match repository identity".into(),
        ));
    }
    Ok(())
}
async fn revoke(
    client: &reqwest::Client,
    cfg: &PublicClientConfig,
    token: &SecretToken,
    cancel: Option<&CancellationFlag>,
) -> Result<(), ProviderError> {
    check_cancelled(cancel)?;
    let Some(conf) = &cfg.confidential else {
        return Err(match cfg.kind {
            ProviderKind::GitHub => ProviderError::MissingConfidentialClient,
            ProviderKind::HuggingFace => ProviderError::RemoteRevokeUnsupported,
        });
    };
    let r = match cfg.kind {
        ProviderKind::GitHub => {
            client
                .delete(&conf.revoke_endpoint)
                .basic_auth(&cfg.client_id, Some(conf.client_secret.expose_secret()))
                .json(&serde_json::json!({"access_token": token.expose_secret()}))
                .send()
                .await
        }
        ProviderKind::HuggingFace => {
            client
                .post(&conf.revoke_endpoint)
                .basic_auth(&cfg.client_id, Some(conf.client_secret.expose_secret()))
                .header("Content-Type", "application/x-www-form-urlencoded")
                .body(format!(
                    "token={}",
                    url::form_urlencoded::byte_serialize(token.expose_secret().as_bytes())
                        .collect::<String>()
                ))
                .send()
                .await
        }
    }
    .map_err(|e| ProviderError::Transport {
        url: conf.revoke_endpoint.clone(),
        message: e.to_string(),
    })?;
    check_cancelled(cancel)?;
    if r.status().is_success() {
        Ok(())
    } else {
        Err(http_err(
            &conf.revoke_endpoint,
            r.status().as_u16(),
            r.headers(),
        ))
    }
}

fn check_cancelled(cancel: Option<&CancellationFlag>) -> Result<(), ProviderError> {
    if cancel.is_some_and(CancellationFlag::is_cancelled) {
        Err(ProviderError::Cancelled)
    } else {
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub struct TokenStore {
    path: PathBuf,
    lock: Arc<Mutex<()>>,
}
impl TokenStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            lock: Arc::new(Mutex::new(())),
        }
    }
    pub async fn save(&self, token: &TokenSet) -> Result<(), ProviderError> {
        let _g = self.lock.lock().await;
        if let Some(parent) = self.path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        let data = serde_json::to_vec(token).map_err(|e| ProviderError::Protocol(e.to_string()))?;
        let tmp = unique_tmp(&self.path);
        #[cfg(unix)]
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            let mut opts = std::fs::OpenOptions::new();
            opts.create_new(true).write(true).mode(0o600);
            let mut f = opts.open(&tmp)?;
            f.write_all(&data)?;
            f.sync_all()?;
        }
        #[cfg(not(unix))]
        {
            tokio::fs::write(&tmp, &data).await?;
        }
        std::fs::rename(&tmp, &self.path)?;
        sync_parent(&self.path)?;
        Ok(())
    }
    pub async fn load(&self) -> Result<Option<TokenSet>, ProviderError> {
        let _g = self.lock.lock().await;
        match tokio::fs::read(&self.path).await {
            Ok(b) => serde_json::from_slice(&b)
                .map(Some)
                .map_err(|e| ProviderError::Protocol(e.to_string())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }
    pub async fn delete_local(&self) -> Result<(), ProviderError> {
        let _g = self.lock.lock().await;
        match tokio::fs::remove_file(&self.path).await {
            Ok(()) => sync_parent(&self.path),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
}
fn unique_tmp(path: &std::path::Path) -> PathBuf {
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    path.with_extension(format!("tmp.{}.{}", std::process::id(), n))
}
fn sync_parent(path: &std::path::Path) -> Result<(), ProviderError> {
    #[cfg(unix)]
    if let Some(parent) = path.parent() {
        std::fs::File::open(parent)?.sync_all()?;
    }
    Ok(())
}
#[must_use]
pub fn canonical_https_clone_url(host: &str, owner: &str, name: &str) -> String {
    format!(
        "https://{}/{}/{}.git",
        host.trim_end_matches('/'),
        owner,
        name
    )
}
pub struct CancellationFlag(std::sync::atomic::AtomicBool);
impl CancellationFlag {
    pub fn new() -> Self {
        Self(std::sync::atomic::AtomicBool::new(false))
    }
    pub fn cancel(&self) {
        self.0.store(true, std::sync::atomic::Ordering::SeqCst);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(std::sync::atomic::Ordering::SeqCst)
    }
}
impl Default for CancellationFlag {
    fn default() -> Self {
        Self::new()
    }
}
