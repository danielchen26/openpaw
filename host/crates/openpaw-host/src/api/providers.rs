//! Provider authorization, token storage, and repository listing API.
//!
//! This module is deliberately secret-tight: HTTP responses are assembled from
//! protocol DTOs only, provider device codes and tokens remain manager-internal,
//! and errors are mapped to typed, sanitized states.

use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use axum::extract::{Path as AxumPath, Query, State};
use axum::http::StatusCode;
use axum::{Extension, Json};
use openpaw_protocol::{
    ProviderAuthorizationStart, ProviderAuthorizationState, ProviderAuthorizationStatus,
    ProviderConnectionState, ProviderId, ProviderRemoteRevokeResult, ProviderRepo,
    ProviderRepoPage, ProviderStatus,
};
use openpaw_providers::{
    CloneSpec, DeviceAuthorization, DevicePollState, GitHubProvider, HuggingFaceProvider,
    ProviderError, PublicClientConfig, Repository, SecretToken, TokenSet,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use time::{Duration, OffsetDateTime};
use tokio::sync::{Mutex, RwLock};

use crate::AppState;
use crate::api::ApiError;
use crate::auth::AuthedDevice;

const TOKEN_MODE: u32 = 0o600;
const PAGE_LIMIT: usize = 50;
const MAX_AUTHORIZATION_SESSIONS: usize = 128;

/// Public OAuth client configuration for built-in providers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderClientConfig {
    /// Public OAuth client id.
    pub client_id: String,
    /// OAuth authorization host base URL.
    pub auth_base: String,
    /// Provider API base URL.
    pub api_base: String,
}

/// Public provider client configuration block.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ProviderClientsConfig {
    /// GitHub public OAuth settings. Missing means unavailable.
    pub github: Option<ProviderClientConfig>,
    /// Hugging Face public OAuth settings. Missing means unavailable.
    pub huggingface: Option<ProviderClientConfig>,
}

#[derive(Clone)]
enum ProviderClient {
    Github(GitHubProvider),
    HuggingFace(HuggingFaceProvider),
}

impl ProviderClient {
    fn display_name(&self) -> &'static str {
        match self {
            ProviderClient::Github(_) => "GitHub",
            ProviderClient::HuggingFace(_) => "Hugging Face",
        }
    }

    fn scopes(&self) -> &'static [&'static str] {
        match self {
            ProviderClient::Github(provider) => provider.required_repo_scopes(),
            ProviderClient::HuggingFace(provider) => provider.minimum_scopes(),
        }
    }

    async fn begin(&self) -> Result<DeviceAuthorization, ProviderError> {
        match self {
            ProviderClient::Github(provider) => {
                provider.begin_device_authorization(self.scopes()).await
            }
            ProviderClient::HuggingFace(provider) => {
                provider.begin_device_authorization(self.scopes()).await
            }
        }
    }

    async fn poll(
        &self,
        device_code: &str,
        interval: u64,
    ) -> Result<DevicePollState, ProviderError> {
        match self {
            ProviderClient::Github(provider) => {
                provider
                    .poll_device_authorization_with_interval(device_code, interval)
                    .await
            }
            ProviderClient::HuggingFace(provider) => {
                provider
                    .poll_device_authorization_with_interval(device_code, interval)
                    .await
            }
        }
    }

    async fn refresh(&self, refresh_token: &SecretToken) -> Result<TokenSet, ProviderError> {
        match self {
            ProviderClient::Github(provider) => provider.refresh(refresh_token).await,
            ProviderClient::HuggingFace(provider) => provider.refresh(refresh_token).await,
        }
    }

    async fn list(&self, access_token: &SecretToken) -> Result<Vec<Repository>, ProviderError> {
        match self {
            ProviderClient::Github(provider) => provider.list_repositories(access_token).await,
            ProviderClient::HuggingFace(provider) => provider.list_repositories(access_token).await,
        }
    }

    fn clone_spec(
        &self,
        repo: &Repository,
        token: SecretToken,
    ) -> Result<CloneSpec, ProviderError> {
        match self {
            ProviderClient::Github(provider) => provider.clone_spec(repo, token),
            ProviderClient::HuggingFace(provider) => provider.clone_spec(repo, token),
        }
    }

    async fn revoke(&self, access_token: &SecretToken) -> Result<(), ProviderError> {
        match self {
            ProviderClient::Github(provider) => provider.revoke_remote(access_token).await,
            ProviderClient::HuggingFace(provider) => provider.revoke_remote(access_token).await,
        }
    }
}

/// Host provider manager.
pub struct ProviderManager {
    token_store: TokenStore,
    clients: HashMap<ProviderId, ProviderClient>,
    sessions: RwLock<HashMap<String, Arc<AuthorizationSession>>>,
}

impl ProviderManager {
    /// Build a manager for the daemon state directory.
    pub fn new(state_dir: &Path, config: ProviderClientsConfig) -> Self {
        let mut clients = HashMap::new();
        if let Some(github_config) = config.github {
            let github = PublicClientConfig::github_app(
                github_config.client_id,
                github_config.auth_base,
                github_config.api_base,
            );
            clients.insert(
                ProviderId::Github,
                ProviderClient::Github(GitHubProvider::new(github)),
            );
        }
        if let Some(hf_config) = config.huggingface {
            let hf = PublicClientConfig::hugging_face(
                hf_config.client_id,
                hf_config.auth_base,
                hf_config.api_base,
            );
            clients.insert(
                ProviderId::HuggingFace,
                ProviderClient::HuggingFace(HuggingFaceProvider::new(hf)),
            );
        }
        Self {
            token_store: TokenStore::new(state_dir),
            clients,
            sessions: RwLock::new(HashMap::new()),
        }
    }

    /// Start a device authorization flow. Only public fields are returned.
    pub async fn start_authorization(
        &self,
        provider: ProviderId,
    ) -> Result<ProviderAuthorizationStart, ProviderError> {
        self.purge_sessions().await;
        let client = self.client(provider)?;
        let device = client.begin().await?;
        let id = uuid::Uuid::new_v4().to_string();
        let now = OffsetDateTime::now_utc();
        let expires_at = now + Duration::seconds(device.expires_in.try_into().unwrap_or(i64::MAX));
        let status = ProviderAuthorizationStatus {
            authorization_id: id.clone(),
            state: ProviderAuthorizationState::Pending,
            provider,
            account_label: None,
        };
        let session = AuthorizationSession {
            provider,
            device_code: device.device_code,
            generation: AtomicU64::new(0),
            created_at: now,
            expires_at,
            next_poll_at: Mutex::new(now),
            interval: Mutex::new(device.interval.max(1)),
            status: Mutex::new(status),
            poll_lock: Mutex::new(()),
        };
        let mut sessions = self.sessions.write().await;
        if sessions.len() >= MAX_AUTHORIZATION_SESSIONS
            && let Some(oldest) = sessions
                .iter()
                .min_by_key(|(_, session)| session.created_at)
                .map(|(id, _)| id.clone())
        {
            sessions.remove(&oldest);
        }
        sessions.insert(id.clone(), Arc::new(session));
        Ok(ProviderAuthorizationStart {
            authorization_id: id,
            verification_url: device.verification_uri,
            user_code: device.user_code,
            expires_at,
            interval_seconds: device.interval.min(u32::MAX as u64) as u32,
        })
    }

    /// Poll only when the route provider owns the authorization id.
    pub async fn authorization_status_for(
        &self,
        provider: ProviderId,
        id: &str,
    ) -> Result<ProviderAuthorizationStatus, ProviderError> {
        let session = self.session(id).await?;
        if session.provider != provider {
            return Err(ProviderError::Protocol(
                "authorization not found".to_owned(),
            ));
        }
        self.authorization_status(id).await
    }

    /// Poll an existing flow. Concurrent callers observe cached state while one owner polls.
    pub async fn authorization_status(
        &self,
        id: &str,
    ) -> Result<ProviderAuthorizationStatus, ProviderError> {
        let session = self.session(id).await?;
        if let Ok(_owner) = session.poll_lock.try_lock() {
            let current = session.status.lock().await.clone();
            if matches!(
                current.state,
                ProviderAuthorizationState::Authorized
                    | ProviderAuthorizationState::Denied
                    | ProviderAuthorizationState::Expired
                    | ProviderAuthorizationState::Cancelled
            ) {
                return Ok(current);
            }
            if OffsetDateTime::now_utc() >= session.expires_at {
                let mut status = session.status.lock().await;
                status.state = ProviderAuthorizationState::Expired;
                return Ok(status.clone());
            }
            if OffsetDateTime::now_utc() < *session.next_poll_at.lock().await {
                return Ok(session.status.lock().await.clone());
            }
            let generation = session.generation.load(Ordering::SeqCst);
            let interval = *session.interval.lock().await;
            let client = self.client(session.provider)?;
            let poll_result = client.poll(&session.device_code, interval).await;
            if session.generation.load(Ordering::SeqCst) != generation {
                return Ok(session.status.lock().await.clone());
            }
            if OffsetDateTime::now_utc() >= session.expires_at {
                let mut status = session.status.lock().await;
                status.state = ProviderAuthorizationState::Expired;
                return Ok(status.clone());
            }
            let next = match poll_result {
                Ok(DevicePollState::Pending { interval_seconds }) => {
                    *session.interval.lock().await = interval_seconds.max(1);
                    *session.next_poll_at.lock().await = OffsetDateTime::now_utc()
                        + Duration::seconds(interval_seconds.max(1).try_into().unwrap_or(i64::MAX));
                    ProviderAuthorizationState::Pending
                }
                Ok(DevicePollState::SlowDown { interval_seconds }) => {
                    *session.interval.lock().await = interval_seconds.max(1);
                    *session.next_poll_at.lock().await = OffsetDateTime::now_utc()
                        + Duration::seconds(interval_seconds.max(1).try_into().unwrap_or(i64::MAX));
                    ProviderAuthorizationState::SlowDown
                }
                Ok(DevicePollState::Authorized(token)) => {
                    self.token_store.save(session.provider, &token)?;
                    ProviderAuthorizationState::Authorized
                }
                Ok(DevicePollState::Denied) => ProviderAuthorizationState::Denied,
                Ok(DevicePollState::Expired) => ProviderAuthorizationState::Expired,
                Ok(DevicePollState::Cancelled) => ProviderAuthorizationState::Cancelled,
                Ok(DevicePollState::Outage) => ProviderAuthorizationState::Outage,
                Err(ProviderError::ReauthorizationRequired) => {
                    ProviderAuthorizationState::ReauthorizationRequired
                }
                Err(ProviderError::Denied) => ProviderAuthorizationState::Denied,
                Err(ProviderError::Expired) => ProviderAuthorizationState::Expired,
                Err(ProviderError::Cancelled) => ProviderAuthorizationState::Cancelled,
                Err(err) => return Err(err),
            };
            let mut status = session.status.lock().await;
            status.state = next;
            Ok(status.clone())
        } else {
            Ok(session.status.lock().await.clone())
        }
    }

    /// Cancel only when the route provider owns the authorization id.
    pub async fn cancel_authorization_for(
        &self,
        provider: ProviderId,
        id: &str,
    ) -> Result<ProviderAuthorizationStatus, ProviderError> {
        let session = self.session(id).await?;
        if session.provider != provider {
            return Err(ProviderError::Protocol(
                "authorization not found".to_owned(),
            ));
        }
        self.cancel_authorization(id).await
    }

    /// Cancel is idempotent and session-id owned.
    pub async fn cancel_authorization(
        &self,
        id: &str,
    ) -> Result<ProviderAuthorizationStatus, ProviderError> {
        let session = self.session(id).await?;
        session.generation.fetch_add(1, Ordering::SeqCst);
        let mut status = session.status.lock().await;
        if !matches!(status.state, ProviderAuthorizationState::Authorized) {
            status.state = ProviderAuthorizationState::Cancelled;
        }
        Ok(status.clone())
    }

    /// List configured provider statuses.
    pub async fn statuses(&self) -> Vec<ProviderStatus> {
        let mut out = Vec::new();
        for (id, client) in &self.clients {
            let token = self.token_store.load(*id).ok().flatten();
            out.push(ProviderStatus {
                id: *id,
                display_name: client.display_name().to_owned(),
                state: if token.is_some() {
                    ProviderConnectionState::Connected
                } else {
                    ProviderConnectionState::Disconnected
                },
                account_label: None,
                scopes: token.map_or_else(Vec::new, |t| t.scopes),
                repo_listing_supported: true,
                remote_revoke_result: None,
            });
        }
        out.sort_by_key(|status| status.id.as_str().to_owned());
        out
    }

    /// Disconnect locally and attempt remote revoke when provider supports it.
    pub async fn disconnect(&self, provider: ProviderId) -> Result<ProviderStatus, ProviderError> {
        let client = self.client(provider)?;
        let token = self.token_store.load(provider)?;
        self.token_store.delete(provider)?;
        let remote_revoke_result = if let Some(token) = token.as_ref() {
            match client.revoke(&token.access_token).await {
                Ok(()) => Some(ProviderRemoteRevokeResult::Revoked),
                Err(
                    ProviderError::RemoteRevokeUnsupported
                    | ProviderError::MissingConfidentialClient,
                ) => Some(ProviderRemoteRevokeResult::Unsupported),
                Err(_) => Some(ProviderRemoteRevokeResult::Failed),
            }
        } else {
            None
        };
        Ok(ProviderStatus {
            id: provider,
            display_name: client.display_name().to_owned(),
            state: ProviderConnectionState::Disconnected,
            account_label: None,
            scopes: Vec::new(),
            repo_listing_supported: true,
            remote_revoke_result,
        })
    }

    /// List repositories with bounded pages and opaque cursor preservation.
    pub async fn list_repos(
        &self,
        provider: ProviderId,
        cursor: Option<String>,
    ) -> Result<ProviderRepoPage, ProviderError> {
        let client = self.client(provider)?;
        let mut token = self.usable_token(provider).await?;
        if token.is_expiring() {
            let refresh = token
                .refresh_token
                .as_ref()
                .ok_or(ProviderError::ReauthorizationRequired)?;
            token = client.refresh(refresh).await?;
            self.token_store.save(provider, &token)?;
        }
        if cursor.is_some() {
            return Err(ProviderError::Protocol(
                "provider cursor not supported by provider core".to_owned(),
            ));
        }
        let repos = client.list(&token.access_token).await?;
        let page = repos
            .iter()
            .take(PAGE_LIMIT)
            .map(|repo| wire_repo(provider, repo))
            .collect();
        Ok(ProviderRepoPage {
            repos: page,
            next_cursor: None,
        })
    }

    /// Internal seam for the later workspace import slice. Not exposed over HTTP.
    pub async fn clone_spec_for(
        &self,
        provider: ProviderId,
        repo_id: &str,
    ) -> Result<CloneSpec, ProviderError> {
        let client = self.client(provider)?;
        let token = self.usable_token(provider).await?;
        let repos = client.list(&token.access_token).await?;
        let repo = repos
            .into_iter()
            .find(|repo| repo.provider_repo_id == repo_id)
            .ok_or_else(|| ProviderError::Protocol("repository not found".to_owned()))?;
        client.clone_spec(&repo, token.access_token)
    }

    async fn purge_sessions(&self) {
        let now = OffsetDateTime::now_utc();
        self.sessions.write().await.retain(|_, session| {
            if now >= session.expires_at + Duration::minutes(5) {
                return false;
            }
            match session.status.try_lock() {
                Ok(status) => !matches!(
                    status.state,
                    ProviderAuthorizationState::Authorized
                        | ProviderAuthorizationState::Denied
                        | ProviderAuthorizationState::Expired
                        | ProviderAuthorizationState::Cancelled
                ),
                Err(_) => true,
            }
        });
    }

    async fn usable_token(&self, provider: ProviderId) -> Result<TokenSet, ProviderError> {
        let token = self
            .token_store
            .load(provider)?
            .ok_or(ProviderError::ReauthorizationRequired)?;
        token.ensure_usable()?;
        Ok(token)
    }

    async fn session(&self, id: &str) -> Result<Arc<AuthorizationSession>, ProviderError> {
        self.sessions
            .read()
            .await
            .get(id)
            .cloned()
            .ok_or_else(|| ProviderError::Protocol("authorization not found".to_owned()))
    }

    fn client(&self, provider: ProviderId) -> Result<&ProviderClient, ProviderError> {
        self.clients
            .get(&provider)
            .ok_or_else(|| ProviderError::Protocol("provider not configured".to_owned()))
    }
}

struct AuthorizationSession {
    provider: ProviderId,
    device_code: String,
    generation: AtomicU64,
    created_at: OffsetDateTime,
    expires_at: OffsetDateTime,
    next_poll_at: Mutex<OffsetDateTime>,
    interval: Mutex<u64>,
    status: Mutex<ProviderAuthorizationStatus>,
    poll_lock: Mutex<()>,
}

#[derive(Clone)]
struct TokenStore {
    state_dir: PathBuf,
    dir: PathBuf,
}

impl TokenStore {
    fn new(state_dir: &Path) -> Self {
        Self {
            state_dir: state_dir.to_path_buf(),
            dir: state_dir.join("providers"),
        }
    }

    fn path(&self, provider: ProviderId) -> PathBuf {
        self.dir.join(format!("{}.json", provider.as_str()))
    }

    fn save(&self, provider: ProviderId, token: &TokenSet) -> Result<(), ProviderError> {
        self.ensure_dir()?;
        let path = self.path(provider);
        let temp = self.dir.join(format!(
            ".{}.{}.tmp",
            provider.as_str(),
            uuid::Uuid::new_v4()
        ));
        let bytes =
            serde_json::to_vec(token).map_err(|err| ProviderError::Protocol(err.to_string()))?;
        {
            let mut file = OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(TOKEN_MODE)
                .open(&temp)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
        }
        std::fs::rename(&temp, &path)?;
        fsync_dir(&self.dir)?;
        Ok(())
    }

    fn load(&self, provider: ProviderId) -> Result<Option<TokenSet>, ProviderError> {
        let path = self.path(provider);
        match std::fs::read(&path) {
            Ok(bytes) => {
                #[cfg(unix)]
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(TOKEN_MODE))?;
                serde_json::from_slice(&bytes)
                    .map(Some)
                    .map_err(|err| ProviderError::Protocol(err.to_string()))
            }
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(err) => Err(err.into()),
        }
    }

    fn delete(&self, provider: ProviderId) -> Result<(), ProviderError> {
        self.ensure_dir()?;
        let path = self.path(provider);
        match std::fs::remove_file(&path) {
            Ok(()) => fsync_dir(&self.dir).map_err(Into::into),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(err) => Err(err.into()),
        }
    }
    fn ensure_dir(&self) -> Result<(), ProviderError> {
        let existed = self.dir.exists();
        std::fs::create_dir_all(&self.dir)?;
        #[cfg(unix)]
        std::fs::set_permissions(&self.dir, std::fs::Permissions::from_mode(0o700))?;
        if !existed {
            fsync_dir(&self.state_dir)?;
        }
        Ok(())
    }
}

fn fsync_dir(path: &Path) -> std::io::Result<()> {
    let dir = OpenOptions::new().read(true).open(path)?;
    dir.sync_all()
}

fn wire_repo(provider: ProviderId, repo: &Repository) -> ProviderRepo {
    ProviderRepo {
        id: repo.provider_repo_id.clone(),
        provider,
        owner: repo.owner.clone(),
        name: repo.name.clone(),
        display_name: format!("{}/{}", repo.owner, repo.name),
        is_private: repo.is_private,
        source_url_redacted: Some(openpaw_protocol::redact_url_credentials(&repo.https_url)),
    }
}

/// Query parameters for provider repository listing.
#[derive(Deserialize)]
pub struct RepoQuery {
    /// Server-issued opaque cursor from a prior page.
    cursor: Option<String>,
}

/// GET /v1/providers.
pub async fn list(State(app): State<AppState>) -> Result<Json<Vec<ProviderStatus>>, ApiError> {
    Ok(Json(app.provider_manager.statuses().await))
}

/// POST /v1/providers/{provider}/authorizations.
pub async fn start_authorization(
    State(app): State<AppState>,
    Extension(caller): Extension<AuthedDevice>,
    AxumPath(provider): AxumPath<ProviderId>,
) -> Result<Json<ProviderAuthorizationStart>, ApiError> {
    let result = app.provider_manager.start_authorization(provider).await;
    audit_provider(
        &app,
        "provider.authorize",
        &caller.device_id,
        provider,
        &result,
    )
    .await;
    result.map(Json).map_err(api_error)
}

/// GET /v1/providers/{provider}/authorizations/{id}.
pub async fn authorization_status(
    State(app): State<AppState>,
    AxumPath((provider, id)): AxumPath<(ProviderId, String)>,
) -> Result<Json<ProviderAuthorizationStatus>, ApiError> {
    let status = app
        .provider_manager
        .authorization_status_for(provider, &id)
        .await
        .map_err(api_error)?;
    if status.provider != provider {
        return Err(ApiError::not_found("authorization not found"));
    }
    Ok(Json(status))
}

/// DELETE /v1/providers/{provider}/authorizations/{id}.
pub async fn cancel_authorization(
    State(app): State<AppState>,
    Extension(caller): Extension<AuthedDevice>,
    AxumPath((provider, id)): AxumPath<(ProviderId, String)>,
) -> Result<Json<ProviderAuthorizationStatus>, ApiError> {
    let result = app
        .provider_manager
        .cancel_authorization_for(provider, &id)
        .await;
    audit_provider(
        &app,
        "provider.cancel_authorization",
        &caller.device_id,
        provider,
        &result,
    )
    .await;
    let status = result.map_err(api_error)?;
    if status.provider != provider {
        return Err(ApiError::not_found("authorization not found"));
    }
    Ok(Json(status))
}

/// DELETE /v1/providers/{provider}.
pub async fn disconnect(
    State(app): State<AppState>,
    Extension(caller): Extension<AuthedDevice>,
    AxumPath(provider): AxumPath<ProviderId>,
) -> Result<Json<ProviderStatus>, ApiError> {
    let result = app.provider_manager.disconnect(provider).await;
    audit_provider(
        &app,
        "provider.disconnect",
        &caller.device_id,
        provider,
        &result,
    )
    .await;
    result.map(Json).map_err(api_error)
}

/// GET /v1/providers/{provider}/repos.
pub async fn repos(
    State(app): State<AppState>,
    AxumPath(provider): AxumPath<ProviderId>,
    Query(query): Query<RepoQuery>,
) -> Result<Json<ProviderRepoPage>, ApiError> {
    app.provider_manager
        .list_repos(provider, query.cursor)
        .await
        .map(Json)
        .map_err(api_error)
}

fn api_error(err: ProviderError) -> ApiError {
    match err {
        ProviderError::Denied => {
            ApiError::json(StatusCode::FORBIDDEN, json!({ "error": "denied" }))
        }
        ProviderError::Expired => ApiError::json(StatusCode::GONE, json!({ "error": "expired" })),
        ProviderError::Cancelled => {
            ApiError::json(StatusCode::CONFLICT, json!({ "error": "cancelled" }))
        }
        ProviderError::ReauthorizationRequired => ApiError::json(
            StatusCode::UNAUTHORIZED,
            json!({ "error": "reauthorization_required" }),
        ),
        ProviderError::HttpStatus {
            status: 429,
            rate_limit,
            ..
        } => ApiError::json(
            StatusCode::TOO_MANY_REQUESTS,
            json!({ "error": "rate_limited", "retry_after_seconds": rate_limit.and_then(|r| r.retry_after_seconds) }),
        ),
        ProviderError::Outage(_) | ProviderError::Transport { .. } => {
            ApiError::json(StatusCode::BAD_GATEWAY, json!({ "error": "outage" }))
        }
        ProviderError::Protocol(message)
            if message == "provider cursor not supported by provider core" =>
        {
            ApiError::bad_request("invalid_cursor")
        }
        ProviderError::Protocol(message) if message == "provider not configured" => ApiError::json(
            StatusCode::SERVICE_UNAVAILABLE,
            json!({ "error": "not_configured" }),
        ),
        ProviderError::Protocol(message)
            if message == "authorization not found" || message == "repository not found" =>
        {
            ApiError::not_found(message)
        }
        ProviderError::RemoteRevokeUnsupported | ProviderError::MissingConfidentialClient => {
            ApiError::json(
                StatusCode::OK,
                json!({ "error": "remote_revoke_unsupported" }),
            )
        }
        ProviderError::Io(_) | ProviderError::Protocol(_) | ProviderError::HttpStatus { .. } => {
            ApiError::bad_gateway("provider request failed")
        }
    }
}

async fn audit_provider<T>(
    app: &AppState,
    action: &'static str,
    device_id: &str,
    provider: ProviderId,
    result: &Result<T, ProviderError>,
) {
    let outcome = if result.is_ok() { "ok" } else { "error" };
    let _ = app
        .audit
        .append(&crate::audit::AuditEntry::now(
            device_id,
            action,
            provider.as_str(),
            outcome,
        ))
        .await;
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    fn token() -> TokenSet {
        TokenSet {
            access_token: SecretToken::new("access-secret".to_owned()),
            refresh_token: Some(SecretToken::new("refresh-secret".to_owned())),
            expires_at: None,
            scopes: vec!["repo".to_owned()],
        }
    }

    #[test]
    fn token_store_is_owner_only_and_repairs_file_mode_on_load() {
        let dir = tempfile::tempdir().unwrap();
        let store = TokenStore::new(dir.path());
        store.save(ProviderId::Github, &token()).unwrap();
        let provider_dir = dir.path().join("providers");
        let token_path = provider_dir.join("github.json");
        #[cfg(unix)]
        {
            assert_eq!(
                std::fs::metadata(&provider_dir)
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o700
            );
            assert_eq!(
                std::fs::metadata(&token_path).unwrap().permissions().mode() & 0o777,
                0o600
            );
            std::fs::set_permissions(&token_path, std::fs::Permissions::from_mode(0o644)).unwrap();
        }
        let loaded = store.load(ProviderId::Github).unwrap().unwrap();
        assert_eq!(loaded.scopes, vec!["repo".to_owned()]);
        #[cfg(unix)]
        assert_eq!(
            std::fs::metadata(&token_path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn token_store_delete_is_idempotent_and_removes_local_token() {
        let dir = tempfile::tempdir().unwrap();
        let store = TokenStore::new(dir.path());
        store.save(ProviderId::Github, &token()).unwrap();
        store.delete(ProviderId::Github).unwrap();
        store.delete(ProviderId::Github).unwrap();
        assert!(store.load(ProviderId::Github).unwrap().is_none());
    }
}
