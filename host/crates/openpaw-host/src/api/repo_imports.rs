//! Repository import API skeleton and progress manager.

use std::collections::VecDeque;
use std::fs::OpenOptions;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use axum::Json;
use axum::extract::{Path as UrlPath, State};
use openpaw_protocol::{
    ProviderId, RepoImportProgress, RepoImportRequest, RepoImportState, RepoRegisterRequest,
};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::AppState;
use crate::api::ApiError;

const MAX_PROGRESS: usize = 128;
const RECOVERY_FILE: &str = "repo-imports-recovery.json";
const SECRET_MODE: u32 = 0o600;

/// Durable restart recovery record for an import operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepoImportRecoveryRecord {
    /// Server-generated import id.
    pub id: String,
    /// Last observed non-secret state.
    pub state: RepoImportState,
    /// Provider selected by the client.
    pub provider: ProviderId,
    /// Provider-scoped repository id.
    pub repo_id: String,
    /// Sanitized display name.
    pub repo_name: String,
    /// Sanitized destination name.
    pub destination_name: String,
    /// Cancellation generation.
    pub generation: u64,
    /// Last update time.
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(default)]
struct RecoveryFile {
    imports: Vec<RepoImportRecoveryRecord>,
}

#[derive(Debug)]
struct ImportEntry {
    record: RepoImportRecoveryRecord,
    progress: RepoImportProgress,
}

/// Bounded in-memory import manager with durable recovery metadata.
#[derive(Debug)]
pub struct RepoImportManager {
    state_dir: PathBuf,
    imports: Mutex<VecDeque<ImportEntry>>,
}

impl RepoImportManager {
    /// Load persisted recovery records, converting nonterminal states to recovery_required.
    pub fn open(state_dir: &Path) -> anyhow::Result<Self> {
        let records = load_recovery(state_dir)?
            .into_iter()
            .map(|mut record| {
                if !is_terminal(record.state) {
                    record.state = RepoImportState::RecoveryRequired;
                }
                ImportEntry {
                    progress: progress_from_record(&record, None),
                    record,
                }
            })
            .collect();
        Ok(Self {
            state_dir: state_dir.to_path_buf(),
            imports: Mutex::new(records),
        })
    }

    /// Start a new skeleton import. Clone execution is intentionally not wired in this slice.
    pub fn start(&self, request: RepoImportRequest) -> anyhow::Result<RepoImportProgress> {
        let id = format!("import-{}", uuid::Uuid::new_v4().simple());
        let repo_name = sanitize_repo_name(&request.repo_id);
        let destination_name = request
            .requested_name
            .clone()
            .unwrap_or_else(|| repo_name.clone());
        let record = RepoImportRecoveryRecord {
            id: id.clone(),
            state: RepoImportState::Queued,
            provider: request.provider,
            repo_id: request.repo_id,
            repo_name,
            destination_name,
            generation: 0,
            updated_at: OffsetDateTime::now_utc(),
        };
        let progress = progress_from_record(&record, Some("clone execution is not yet supported"));
        self.push(ImportEntry { record, progress })
    }

    /// Return current progress for an import id.
    pub fn get(&self, id: &str) -> Option<RepoImportProgress> {
        self.imports
            .lock()
            .expect("repo imports poisoned")
            .iter()
            .find(|e| e.record.id == id)
            .map(|e| e.progress.clone())
    }

    /// Cancel idempotently. Unknown ids return a stable cancelled tombstone.
    pub fn cancel(&self, id: &str) -> anyhow::Result<RepoImportProgress> {
        let mut imports = self.imports.lock().expect("repo imports poisoned");
        if let Some(position) = imports.iter().position(|e| e.record.id == id) {
            if !is_terminal(imports[position].record.state) {
                imports[position].record.generation =
                    imports[position].record.generation.saturating_add(1);
                imports[position].record.state = RepoImportState::Cancelled;
                imports[position].record.updated_at = OffsetDateTime::now_utc();
                imports[position].progress =
                    progress_from_record(&imports[position].record, Some("cancelled"));
                persist_recovery(
                    &self.state_dir,
                    imports.iter().map(|e| e.record.clone()).collect(),
                )?;
            }
            return Ok(imports[position].progress.clone());
        }
        Ok(RepoImportProgress {
            id: id.to_owned(),
            state: RepoImportState::Cancelled,
            repo_name: "unknown".to_owned(),
            destination_name: "unknown".to_owned(),
            percent: None,
            message: Some("cancelled".to_owned()),
            source_url_redacted: None,
        })
    }

    fn push(&self, entry: ImportEntry) -> anyhow::Result<RepoImportProgress> {
        let mut imports = self.imports.lock().expect("repo imports poisoned");
        imports.push_back(entry);
        while imports.len() > MAX_PROGRESS {
            imports.pop_front();
        }
        persist_recovery(
            &self.state_dir,
            imports.iter().map(|e| e.record.clone()).collect(),
        )?;
        Ok(imports.back().expect("just pushed").progress.clone())
    }
}

/// `POST /v1/repo-imports`.
pub async fn start_import(
    State(app): State<AppState>,
    Json(request): Json<RepoImportRequest>,
) -> Result<Json<RepoImportProgress>, ApiError> {
    Ok(Json(app.repo_imports.start(request)?))
}

/// `GET /v1/repo-imports/{id}`.
pub async fn get_import(
    State(app): State<AppState>,
    UrlPath(id): UrlPath<String>,
) -> Result<Json<RepoImportProgress>, ApiError> {
    app.repo_imports
        .get(&id)
        .map(Json)
        .ok_or_else(|| ApiError::not_found("repository import not found"))
}

/// `DELETE /v1/repo-imports/{id}`.
pub async fn cancel_import(
    State(app): State<AppState>,
    UrlPath(id): UrlPath<String>,
) -> Result<Json<RepoImportProgress>, ApiError> {
    Ok(Json(app.repo_imports.cancel(&id)?))
}

/// `POST /v1/repos/register`.
pub async fn register_repo(
    State(app): State<AppState>,
    Json(request): Json<RepoRegisterRequest>,
) -> Result<Json<Vec<openpaw_git::RepoSummary>>, ApiError> {
    app.workspaces
        .register_known(&request.root_id, request.requested_name.as_deref())?;
    let roots = app.roots();
    let summaries = tokio::task::spawn_blocking(move || openpaw_git::summaries(&roots)).await?;
    Ok(Json(summaries))
}

fn progress_from_record(
    record: &RepoImportRecoveryRecord,
    message: Option<&str>,
) -> RepoImportProgress {
    RepoImportProgress {
        id: record.id.clone(),
        state: record.state,
        repo_name: record.repo_name.clone(),
        destination_name: record.destination_name.clone(),
        percent: None,
        message: message.map(str::to_owned),
        source_url_redacted: None,
    }
}

fn is_terminal(state: RepoImportState) -> bool {
    matches!(
        state,
        RepoImportState::Completed
            | RepoImportState::Failed
            | RepoImportState::Cancelled
            | RepoImportState::RecoveryRequired
    )
}

fn sanitize_repo_name(repo_id: &str) -> String {
    repo_id
        .rsplit('/')
        .next()
        .unwrap_or(repo_id)
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        .take(128)
        .collect::<String>()
        .trim_matches('.')
        .to_owned()
        .if_empty("repository")
}

trait IfEmpty {
    fn if_empty(self, fallback: &str) -> String;
}
impl IfEmpty for String {
    fn if_empty(self, fallback: &str) -> String {
        if self.is_empty() {
            fallback.to_owned()
        } else {
            self
        }
    }
}

fn load_recovery(state_dir: &Path) -> anyhow::Result<Vec<RepoImportRecoveryRecord>> {
    let path = state_dir.join(RECOVERY_FILE);
    match std::fs::read(&path) {
        Ok(bytes) => Ok(serde_json::from_slice::<RecoveryFile>(&bytes)?.imports),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(err) => Err(err.into()),
    }
}

fn persist_recovery(
    state_dir: &Path,
    imports: Vec<RepoImportRecoveryRecord>,
) -> anyhow::Result<()> {
    std::fs::create_dir_all(state_dir)?;
    let path = state_dir.join(RECOVERY_FILE);
    let tmp = state_dir.join(format!(".{RECOVERY_FILE}.{}.tmp", uuid::Uuid::new_v4()));
    let bytes = serde_json::to_vec_pretty(&RecoveryFile { imports })?;
    std::io::Write::write_all(
        &mut OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(SECRET_MODE)
            .open(&tmp)?,
        &bytes,
    )?;
    std::fs::rename(tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn start_uses_server_id_and_sanitized_progress() {
        let dir = tempfile::tempdir().unwrap();
        let manager = RepoImportManager::open(dir.path()).unwrap();
        let progress = manager
            .start(RepoImportRequest {
                provider: ProviderId::Github,
                repo_id: "owner/secret-token-repo".to_owned(),
                requested_name: Some("safe-name".to_owned()),
            })
            .unwrap();
        assert!(progress.id.starts_with("import-"));
        assert_eq!(progress.state, RepoImportState::Queued);
        assert_eq!(progress.repo_name, "secret-token-repo");
        assert_eq!(progress.destination_name, "safe-name");
        let json = serde_json::to_string(&progress).unwrap();
        assert!(!json.contains("https://"));
        assert!(!json.contains(dir.path().to_str().unwrap()));
    }

    #[test]
    fn cancel_is_idempotent_and_persisted_nonterminal_recovers() {
        let dir = tempfile::tempdir().unwrap();
        let manager = RepoImportManager::open(dir.path()).unwrap();
        let progress = manager
            .start(RepoImportRequest {
                provider: ProviderId::Github,
                repo_id: "owner/name".to_owned(),
                requested_name: None,
            })
            .unwrap();
        let restarted = RepoImportManager::open(dir.path()).unwrap();
        assert_eq!(
            restarted.get(&progress.id).unwrap().state,
            RepoImportState::RecoveryRequired
        );
        let first = manager.cancel(&progress.id).unwrap();
        let second = manager.cancel(&progress.id).unwrap();
        assert_eq!(first.state, RepoImportState::Cancelled);
        assert_eq!(second.state, RepoImportState::Cancelled);
    }

    #[test]
    fn progress_is_bounded_to_latest_entries() {
        let dir = tempfile::tempdir().unwrap();
        let manager = RepoImportManager::open(dir.path()).unwrap();
        let mut first = String::new();
        let mut last = String::new();
        for i in 0..(MAX_PROGRESS + 2) {
            let progress = manager
                .start(RepoImportRequest {
                    provider: ProviderId::Github,
                    repo_id: format!("owner/repo-{i}"),
                    requested_name: None,
                })
                .unwrap();
            if i == 0 {
                first = progress.id.clone();
            }
            last = progress.id;
        }
        assert!(manager.get(&first).is_none());
        assert!(manager.get(&last).is_some());
    }
}
