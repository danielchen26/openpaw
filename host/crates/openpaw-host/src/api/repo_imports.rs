//! Repository import API skeleton and progress manager.

use std::collections::VecDeque;
use std::fs::OpenOptions;
use std::io::Write;
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
const MAX_ID_LEN: usize = 128;
const MAX_MESSAGE_LEN: usize = 160;
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

#[derive(Debug, Clone)]
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
        let mut changed = false;
        let mut entries = VecDeque::new();
        for mut record in load_recovery(state_dir)? {
            validate_record(&record)?;
            if !is_terminal(record.state) {
                record.state = RepoImportState::RecoveryRequired;
                record.updated_at = OffsetDateTime::now_utc();
                changed = true;
            }
            entries.push_back(ImportEntry {
                progress: progress_from_record(&record, None),
                record,
            });
        }
        while entries.len() > MAX_PROGRESS {
            entries.pop_front();
            changed = true;
        }
        if changed {
            persist_recovery(
                state_dir,
                entries.iter().map(|entry| entry.record.clone()).collect(),
            )?;
        }
        Ok(Self {
            state_dir: state_dir.to_path_buf(),
            imports: Mutex::new(entries),
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
        validate_record(&record)?;
        let progress = progress_from_record(&record, Some("clone execution is not yet supported"));
        self.push(ImportEntry { record, progress })
    }

    /// Return current progress for an import id.
    pub fn get(&self, id: &str) -> anyhow::Result<Option<RepoImportProgress>> {
        validate_identifier(id)?;
        Ok(self
            .imports
            .lock()
            .expect("repo imports poisoned")
            .iter()
            .find(|entry| entry.record.id == id)
            .map(|entry| entry.progress.clone()))
    }

    /// Cancel idempotently. Unknown ids return a stable cancelled tombstone.
    pub fn cancel(&self, id: &str) -> anyhow::Result<RepoImportProgress> {
        validate_identifier(id)?;
        let mut imports = self.imports.lock().expect("repo imports poisoned");
        let Some(position) = imports.iter().position(|entry| entry.record.id == id) else {
            return Ok(cancelled_tombstone(id));
        };
        if is_terminal(imports[position].record.state) {
            return Ok(imports[position].progress.clone());
        }

        let mut next = imports.clone();
        next[position].record.generation = next[position].record.generation.saturating_add(1);
        next[position].record.state = RepoImportState::Cancelled;
        next[position].record.updated_at = OffsetDateTime::now_utc();
        next[position].progress = progress_from_record(&next[position].record, Some("cancelled"));
        persist_recovery(
            &self.state_dir,
            next.iter().map(|entry| entry.record.clone()).collect(),
        )?;
        *imports = next;
        Ok(imports[position].progress.clone())
    }

    fn push(&self, entry: ImportEntry) -> anyhow::Result<RepoImportProgress> {
        let mut imports = self.imports.lock().expect("repo imports poisoned");
        let mut next = imports.clone();
        next.push_back(entry);
        while next.len() > MAX_PROGRESS {
            next.pop_front();
        }
        persist_recovery(
            &self.state_dir,
            next.iter().map(|entry| entry.record.clone()).collect(),
        )?;
        *imports = next;
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
        .map_err(|_| ApiError::bad_request("invalid repository import id"))?
        .map(Json)
        .ok_or_else(|| ApiError::not_found("repository import not found"))
}

/// `DELETE /v1/repo-imports/{id}`.
pub async fn cancel_import(
    State(app): State<AppState>,
    UrlPath(id): UrlPath<String>,
) -> Result<Json<RepoImportProgress>, ApiError> {
    Ok(Json(app.repo_imports.cancel(&id).map_err(|_| {
        ApiError::bad_request("invalid repository import id")
    })?))
}

/// `POST /v1/repos/register`.
pub async fn register_repo(
    State(app): State<AppState>,
    Json(request): Json<RepoRegisterRequest>,
) -> Result<Json<RepoImportProgress>, ApiError> {
    app.workspaces
        .register_known(&request.root_id, request.requested_name.as_deref())?;
    let destination_name = app
        .workspaces
        .visible_name(&request.root_id)
        .unwrap_or_else(|| {
            request
                .requested_name
                .clone()
                .unwrap_or_else(|| request.root_id.clone())
        });
    Ok(Json(RepoImportProgress {
        id: format!("register-{}", uuid::Uuid::new_v4().simple()),
        state: RepoImportState::Completed,
        repo_name: destination_name.clone(),
        destination_name,
        percent: Some(100),
        message: None,
        source_url_redacted: None,
    }))
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
        message: message.map(bound_message),
        source_url_redacted: None,
    }
}

fn cancelled_tombstone(id: &str) -> RepoImportProgress {
    RepoImportProgress {
        id: id.to_owned(),
        state: RepoImportState::Cancelled,
        repo_name: "unknown".to_owned(),
        destination_name: "unknown".to_owned(),
        percent: None,
        message: Some("cancelled".to_owned()),
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
        .take(MAX_ID_LEN)
        .collect::<String>()
        .trim_matches('.')
        .to_owned()
        .if_empty("repository")
}

fn validate_record(record: &RepoImportRecoveryRecord) -> anyhow::Result<()> {
    validate_identifier(&record.id)?;
    validate_identifier(&record.repo_id)?;
    validate_identifier(&record.repo_name)?;
    validate_identifier(&record.destination_name)?;
    anyhow::ensure!(record.generation < u64::MAX, "invalid import generation");
    Ok(())
}

fn validate_identifier(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(!value.is_empty(), "identifier is required");
    anyhow::ensure!(value.len() <= MAX_ID_LEN, "identifier is too long");
    anyhow::ensure!(
        value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-')),
        "identifier is invalid"
    );
    anyhow::ensure!(value != "." && value != "..", "identifier is invalid");
    Ok(())
}

fn bound_message(message: &str) -> String {
    message.chars().take(MAX_MESSAGE_LEN).collect()
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
    let result = (|| -> anyhow::Result<()> {
        {
            let mut file = OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(SECRET_MODE)
                .open(&tmp)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
        }
        std::fs::rename(&tmp, path)?;
        let dir = OpenOptions::new().read(true).open(state_dir)?;
        dir.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
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
                repo_id: "owner-name".to_owned(),
                requested_name: Some("safe-name".to_owned()),
            })
            .unwrap();
        assert!(progress.id.starts_with("import-"));
        assert_eq!(progress.state, RepoImportState::Queued);
        assert_eq!(progress.repo_name, "owner-name");
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
                repo_id: "owner-name".to_owned(),
                requested_name: None,
            })
            .unwrap();
        let restarted = RepoImportManager::open(dir.path()).unwrap();
        assert_eq!(
            restarted.get(&progress.id).unwrap().unwrap().state,
            RepoImportState::RecoveryRequired
        );
        let persisted = std::fs::read_to_string(dir.path().join(RECOVERY_FILE)).unwrap();
        assert!(persisted.contains("recovery_required"));
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
                    repo_id: format!("owner-repo-{i}"),
                    requested_name: None,
                })
                .unwrap();
            if i == 0 {
                first = progress.id.clone();
            }
            last = progress.id;
        }
        assert!(manager.get(&first).unwrap().is_none());
        assert!(manager.get(&last).unwrap().is_some());
    }

    #[test]
    fn invalid_ids_fail_before_state_mutation() {
        let dir = tempfile::tempdir().unwrap();
        let manager = RepoImportManager::open(dir.path()).unwrap();
        assert!(manager.get("../bad").is_err());
        assert!(manager.cancel("../bad").is_err());
        assert!(!dir.path().join(RECOVERY_FILE).exists());
    }
}
