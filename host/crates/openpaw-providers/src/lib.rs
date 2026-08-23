//! Secret-safe provider abstraction for GitHub and Hugging Face.

use serde::{Deserialize, Serialize};
use std::{fmt, path::PathBuf};
use time::{Duration, OffsetDateTime};

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
    HttpStatus { url: String, status: u16 },
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
        }
    }
}
impl From<std::io::Error> for ProviderError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e.to_string())
    }
}

#[derive(Clone, Debug)]
pub struct PublicClientConfig {
    pub client_id: String,
    pub auth_base: String,
    pub api_base: String,
    pub token_endpoint: String,
    pub device_endpoint: String,
    pub confidential: Option<ConfidentialClientConfig>,
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
            device_endpoint: format!("{auth_base}/oauth/device/code"),
            token_endpoint: format!("{auth_base}/oauth/token"),
            auth_base,
            confidential: None,
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
    Pending,
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

impl GitHubProvider {
    pub fn new(cfg: PublicClientConfig) -> Self {
        Self {
            cfg,
            client: reqwest::Client::new(),
        }
    }
    pub fn minimum_scopes(&self) -> &'static [&'static str] {
        &["read:user"]
    }
    pub async fn begin_device_authorization(
        &self,
        scopes: &[&str],
    ) -> Result<DeviceAuthorization, ProviderError> {
        post_form(
            &self.client,
            &self.cfg.device_endpoint,
            &[
                ("client_id", self.cfg.client_id.as_str()),
                ("scope", &scopes.join(" ")),
            ],
        )
        .await
    }
    pub async fn poll_device_authorization(
        &self,
        device_code: &str,
    ) -> Result<DevicePollState, ProviderError> {
        poll_token(
            &self.client,
            &self.cfg.token_endpoint,
            &[
                ("client_id", self.cfg.client_id.as_str()),
                ("device_code", device_code),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ],
        )
        .await
    }
    pub async fn list_repositories(
        &self,
        token: &SecretToken,
    ) -> Result<Vec<Repository>, ProviderError> {
        list_github_repos(&self.client, &self.cfg.api_base, token).await
    }
    pub fn clone_spec(&self, repo: &Repository, token: SecretToken) -> CloneSpec {
        CloneSpec {
            url: repo.https_url.clone(),
            username: "x-access-token".into(),
            password: token,
        }
    }
    pub fn status(&self, identity: Option<String>, token: Option<&TokenSet>) -> SanitizedStatus {
        SanitizedStatus {
            identity,
            scopes: token.map_or_else(Vec::new, |t| t.scopes.clone()),
            authorized: token.is_some(),
        }
    }
    pub async fn revoke_remote(&self, token: &SecretToken) -> Result<(), ProviderError> {
        revoke(&self.client, &self.cfg, token).await
    }
}

impl HuggingFaceProvider {
    pub fn new(cfg: PublicClientConfig) -> Self {
        Self {
            cfg,
            client: reqwest::Client::new(),
        }
    }
    pub fn minimum_scopes(&self) -> &'static [&'static str] {
        &["read-repos"]
    }
    pub async fn begin_device_authorization(
        &self,
        scopes: &[&str],
    ) -> Result<DeviceAuthorization, ProviderError> {
        post_form(
            &self.client,
            &self.cfg.device_endpoint,
            &[
                ("client_id", self.cfg.client_id.as_str()),
                ("scope", &scopes.join(" ")),
            ],
        )
        .await
    }
    pub async fn poll_device_authorization(
        &self,
        device_code: &str,
    ) -> Result<DevicePollState, ProviderError> {
        poll_token(
            &self.client,
            &self.cfg.token_endpoint,
            &[
                ("client_id", self.cfg.client_id.as_str()),
                ("device_code", device_code),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ],
        )
        .await
    }
    pub async fn refresh(&self, refresh_token: &SecretToken) -> Result<TokenSet, ProviderError> {
        token_response(
            &self.client,
            &self.cfg.token_endpoint,
            &[
                ("client_id", self.cfg.client_id.as_str()),
                ("refresh_token", refresh_token.expose_secret()),
                ("grant_type", "refresh_token"),
            ],
        )
        .await
    }
    pub async fn list_repositories(
        &self,
        token: &SecretToken,
    ) -> Result<Vec<Repository>, ProviderError> {
        list_hf_repos(&self.client, &self.cfg.api_base, token).await
    }
    pub fn clone_spec(&self, repo: &Repository, token: SecretToken) -> CloneSpec {
        CloneSpec {
            url: repo.https_url.clone(),
            username: "oauth2".into(),
            password: token,
        }
    }
    pub fn status(&self, identity: Option<String>, token: Option<&TokenSet>) -> SanitizedStatus {
        SanitizedStatus {
            identity,
            scopes: token.map_or_else(Vec::new, |t| t.scopes.clone()),
            authorized: token.is_some(),
        }
    }
    pub async fn revoke_remote(&self, token: &SecretToken) -> Result<(), ProviderError> {
        revoke(&self.client, &self.cfg, token).await
    }
}

async fn post_form<T: for<'de> Deserialize<'de>>(
    client: &reqwest::Client,
    url: &str,
    form: &[(&str, &str)],
) -> Result<T, ProviderError> {
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
    if !r.status().is_success() {
        return Err(ProviderError::http_status(url, r.status().as_u16(), None));
    }
    r.json()
        .await
        .map_err(|e| ProviderError::Protocol(e.to_string()))
}
async fn poll_token(
    client: &reqwest::Client,
    url: &str,
    form: &[(&str, &str)],
) -> Result<DevicePollState, ProviderError> {
    let v: serde_json::Value = post_form(client, url, form).await?;
    if let Some(e) = v.get("error").and_then(|x| x.as_str()) {
        return Ok(match e {
            "authorization_pending" => DevicePollState::Pending,
            "slow_down" => DevicePollState::SlowDown {
                interval_seconds: 10,
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
) -> Result<TokenSet, ProviderError> {
    let v: serde_json::Value = post_form(client, url, form).await?;
    parse_token(v)
}
fn parse_token(v: serde_json::Value) -> Result<TokenSet, ProviderError> {
    let access = v
        .get("access_token")
        .and_then(|x| x.as_str())
        .ok_or_else(|| ProviderError::Protocol("missing access_token".into()))?;
    let refresh = v
        .get("refresh_token")
        .and_then(|x| x.as_str())
        .map(|s| SecretToken::new(s.into()));
    let expires = v.get("expires_in").and_then(|x| x.as_u64());
    let scopes = v
        .get("scope")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .split_whitespace()
        .map(str::to_string)
        .collect();
    Ok(TokenSet {
        access_token: SecretToken::new(access.into()),
        refresh_token: refresh,
        expires_at: expires.map(|e| {
            OffsetDateTime::now_utc() + Duration::seconds(e.try_into().unwrap_or(i64::MAX))
        }),
        scopes,
    })
}

async fn list_github_repos(
    client: &reqwest::Client,
    api: &str,
    token: &SecretToken,
) -> Result<Vec<Repository>, ProviderError> {
    let mut page = 1;
    let mut out = Vec::new();
    loop {
        let url = format!("{api}/user/repos?per_page=100&page={page}");
        let vals: Vec<serde_json::Value> = get_json(client, &url, token).await?;
        let n = vals.len();
        out.extend(vals.into_iter().map(|v| Repository {
            owner: v["owner"]["login"].as_str().unwrap_or_default().into(),
            name: v["name"].as_str().unwrap_or_default().into(),
            https_url: v["clone_url"].as_str().unwrap_or_default().into(),
        }));
        if n < 100 {
            break;
        }
        page += 1;
    }
    Ok(out)
}
async fn list_hf_repos(
    client: &reqwest::Client,
    api: &str,
    token: &SecretToken,
) -> Result<Vec<Repository>, ProviderError> {
    let mut cursor: Option<String> = None;
    let mut out = Vec::new();
    loop {
        let url = if let Some(c) = &cursor {
            format!("{api}/api/models?limit=100&cursor={c}")
        } else {
            format!("{api}/api/models?limit=100")
        };
        let v: serde_json::Value = get_json(client, &url, token).await?;
        let arr = v
            .as_array()
            .cloned()
            .or_else(|| v.get("items").and_then(|x| x.as_array()).cloned())
            .unwrap_or_default();
        for item in arr {
            let id = item.get("id").and_then(|x| x.as_str()).unwrap_or_default();
            let (owner, name) = id.split_once('/').unwrap_or(("", id));
            out.push(Repository {
                owner: owner.into(),
                name: name.into(),
                https_url: format!("https://huggingface.co/{id}"),
            });
        }
        cursor = v.get("next").and_then(|x| x.as_str()).map(str::to_string);
        if cursor.is_none() {
            break;
        }
    }
    Ok(out)
}
async fn get_json<T: for<'de> Deserialize<'de>>(
    client: &reqwest::Client,
    url: &str,
    token: &SecretToken,
) -> Result<T, ProviderError> {
    let r = client
        .get(url)
        .bearer_auth(token.expose_secret())
        .send()
        .await
        .map_err(|e| ProviderError::Transport {
            url: url.into(),
            message: e.to_string(),
        })?;
    if !r.status().is_success() {
        return Err(ProviderError::http_status(
            url,
            r.status().as_u16(),
            Some(token.clone()),
        ));
    }
    r.json()
        .await
        .map_err(|e| ProviderError::Protocol(e.to_string()))
}
async fn revoke(
    client: &reqwest::Client,
    cfg: &PublicClientConfig,
    token: &SecretToken,
) -> Result<(), ProviderError> {
    let Some(conf) = &cfg.confidential else {
        return Err(ProviderError::MissingConfidentialClient);
    };
    let body = format!(
        "token={}",
        url::form_urlencoded::byte_serialize(token.expose_secret().as_bytes()).collect::<String>()
    );
    let r = client
        .post(&conf.revoke_endpoint)
        .basic_auth(&cfg.client_id, Some(conf.client_secret.expose_secret()))
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(body)
        .send()
        .await
        .map_err(|e| ProviderError::Transport {
            url: conf.revoke_endpoint.clone(),
            message: e.to_string(),
        })?;
    if r.status().is_success() {
        Ok(())
    } else {
        Err(ProviderError::http_status(
            &conf.revoke_endpoint,
            r.status().as_u16(),
            Some(token.clone()),
        ))
    }
}

#[derive(Clone, Debug)]
pub struct TokenStore {
    path: PathBuf,
}
impl TokenStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }
    pub async fn save(&self, token: &TokenSet) -> Result<(), ProviderError> {
        if let Some(parent) = self.path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        let tmp = self.path.with_extension("tmp");
        let data = serde_json::to_vec(token).map_err(|e| ProviderError::Protocol(e.to_string()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            let mut opts = std::fs::OpenOptions::new();
            opts.create(true).write(true).truncate(true).mode(0o600);
            let mut f = opts.open(&tmp)?;
            use std::io::Write;
            f.write_all(&data)?;
            f.sync_all()?;
        }
        #[cfg(not(unix))]
        {
            tokio::fs::write(&tmp, &data).await?;
        }
        std::fs::rename(&tmp, &self.path)?;
        #[cfg(unix)]
        if let Some(parent) = self.path.parent() {
            let dir = std::fs::File::open(parent)?;
            dir.sync_all()?;
        }
        Ok(())
    }
    pub async fn load(&self) -> Result<Option<TokenSet>, ProviderError> {
        match tokio::fs::read(&self.path).await {
            Ok(b) => serde_json::from_slice(&b)
                .map(Some)
                .map_err(|e| ProviderError::Protocol(e.to_string())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }
    pub async fn delete_local(&self) -> Result<(), ProviderError> {
        match tokio::fs::remove_file(&self.path).await {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
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
