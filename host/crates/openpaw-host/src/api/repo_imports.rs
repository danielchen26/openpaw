//! Repository import API skeleton and progress manager.

use std::collections::VecDeque;
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use axum::Json;
use axum::extract::{Path as UrlPath, State};
use openpaw_git::{
    CancellationToken, CloneBytePolicy, CloneCredentialBridge, CloneCredentials, CloneRequest,
    HttpsRemoteUrl, LfsSmudgePolicy, TrustedCloneDestination, clone_repo,
};
use openpaw_protocol::{
    ProviderId, RepoImportProgress, RepoImportRequest, RepoImportState, RepoRegisterRequest,
};
use openpaw_providers::CloneSpec;
use serde::de::{self, IgnoredAny, SeqAccess, Visitor};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::AppState;
use crate::api::ApiError;

const MAX_PROGRESS: usize = 128;
const MAX_ID_LEN: usize = 128;
const MAX_MESSAGE_LEN: usize = 160;
const MAX_RECOVERY_BYTES: u64 = 1024 * 1024;
const RECOVERY_FILE: &str = "repo-imports-recovery.json";
const SECRET_MODE: u32 = 0o600;

/// Typed repository import manager failure.
#[derive(Debug, thiserror::Error)]
pub enum RepoImportError {
    /// A route id is not a server-issued repository import id.
    #[error("invalid repository import id")]
    InvalidId,
    /// Durable state could not be read or persisted.
    #[error(transparent)]
    Internal(#[from] anyhow::Error),
}

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
    #[serde(deserialize_with = "deserialize_recovery_records")]
    imports: Vec<RepoImportRecoveryRecord>,
}

fn deserialize_recovery_records<'de, D>(
    deserializer: D,
) -> std::result::Result<Vec<RepoImportRecoveryRecord>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    struct RecordsVisitor;

    impl<'de> Visitor<'de> for RecordsVisitor {
        type Value = Vec<RepoImportRecoveryRecord>;

        fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            formatter.write_str("a bounded repository import recovery array")
        }

        fn visit_seq<A>(self, mut sequence: A) -> std::result::Result<Self::Value, A::Error>
        where
            A: SeqAccess<'de>,
        {
            let mut records =
                Vec::with_capacity(sequence.size_hint().unwrap_or(0).min(MAX_PROGRESS));
            while records.len() < MAX_PROGRESS {
                match sequence.next_element()? {
                    Some(record) => records.push(record),
                    None => return Ok(records),
                }
            }
            if sequence.next_element::<IgnoredAny>()?.is_some() {
                return Err(de::Error::custom("too many recovery records"));
            }
            Ok(records)
        }
    }

    deserializer.deserialize_seq(RecordsVisitor)
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

    /// Start a new import and persist queued state before clone execution.
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
        let progress = progress_from_record(&record, Some("queued"));
        self.push(ImportEntry { record, progress })
    }

    /// Persist an import progress state transition without exposing provider credentials.
    pub fn update_state(
        &self,
        id: &str,
        state: RepoImportState,
        message: Option<&str>,
        percent: Option<u8>,
    ) -> Result<RepoImportProgress, RepoImportError> {
        validate_import_id(id)?;
        let mut imports = self.imports.lock().expect("repo imports poisoned");
        let Some(position) = imports.iter().position(|entry| entry.record.id == id) else {
            return Err(RepoImportError::InvalidId);
        };
        let mut next = imports.clone();
        next[position].record.state = state;
        next[position].record.updated_at = OffsetDateTime::now_utc();
        next[position].progress = progress_from_record(&next[position].record, message);
        next[position].progress.percent = percent;
        persist_recovery(
            &self.state_dir,
            next.iter().map(|entry| entry.record.clone()).collect(),
        )?;
        *imports = next;
        Ok(imports[position].progress.clone())
    }

    /// Return current progress for an import id.
    pub fn get(&self, id: &str) -> Result<Option<RepoImportProgress>, RepoImportError> {
        validate_import_id(id)?;
        Ok(self
            .imports
            .lock()
            .expect("repo imports poisoned")
            .iter()
            .find(|entry| entry.record.id == id)
            .map(|entry| entry.progress.clone()))
    }

    /// Cancel idempotently. Unknown ids return a stable cancelled tombstone.
    pub fn cancel(&self, id: &str) -> Result<RepoImportProgress, RepoImportError> {
        validate_import_id(id)?;
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
    let progress = app.repo_imports.start(request.clone())?;
    let clone_spec = app
        .provider_manager
        .clone_spec_for(request.provider, &request.repo_id)
        .await
        .map_err(|_| {
            ApiError::new(
                axum::http::StatusCode::SERVICE_UNAVAILABLE,
                "provider clone unavailable",
            )
        })?;
    execute_import_clone(&app, &request, &progress.id, clone_spec).await?;
    let completed = app
        .repo_imports
        .update_state(&progress.id, RepoImportState::Completed, None, Some(100))
        .map_err(|err| ApiError::internal(anyhow::Error::new(err)))?;
    Ok(Json(completed))
}

async fn execute_import_clone(
    app: &AppState,
    request: &RepoImportRequest,
    import_id: &str,
    clone_spec: CloneSpec,
) -> Result<(), ApiError> {
    let destination_name = request
        .requested_name
        .clone()
        .unwrap_or_else(|| sanitize_repo_name(&request.repo_id));
    let destination = app.store.state_dir().join("repos").join(&destination_name);
    let helper =
        std::env::current_exe().map_err(|err| ApiError::internal(anyhow::Error::new(err)))?;
    let remote = HttpsRemoteUrl::parse(&clone_spec.url)
        .map_err(|err| ApiError::bad_request(format!("invalid provider clone URL: {err}")))?;
    let credentials = CloneCredentials::new(
        clone_spec.username,
        clone_spec.password.expose_secret().to_owned(),
        CloneCredentialBridge::fixed(helper, "fd3"),
    )
    .map_err(|err| ApiError::internal(anyhow::Error::new(err)))?;
    let destination = TrustedCloneDestination::new(destination)
        .map_err(|err| ApiError::bad_request(format!("invalid clone destination: {err}")))?;
    app.repo_imports
        .update_state(
            import_id,
            RepoImportState::Cloning,
            Some("cloning"),
            Some(25),
        )
        .map_err(|err| ApiError::internal(anyhow::Error::new(err)))?;
    tokio::task::spawn_blocking(move || {
        clone_repo(CloneRequest {
            remote,
            destination,
            r#ref: None,
            timeout: std::time::Duration::from_secs(300),
            byte_policy: CloneBytePolicy::default(),
            cancellation: CancellationToken::new(),
            lfs_smudge: LfsSmudgePolicy::Disable,
            credentials: Some(credentials),
        })
    })
    .await
    .map_err(|err| ApiError::internal(anyhow::Error::new(err)))?
    .map_err(|err| ApiError::internal(anyhow::Error::new(err)))?;
    app.repo_imports
        .update_state(
            import_id,
            RepoImportState::Registering,
            Some("registering"),
            Some(90),
        )
        .map_err(|err| ApiError::internal(anyhow::Error::new(err)))?;
    app.workspaces
        .register_known(&destination_name, Some(&destination_name))
        .map_err(ApiError::internal)?;
    Ok(())
}

/// `GET /v1/repo-imports/{id}`.
pub async fn get_import(
    State(app): State<AppState>,
    UrlPath(id): UrlPath<String>,
) -> Result<Json<RepoImportProgress>, ApiError> {
    match app.repo_imports.get(&id) {
        Ok(Some(progress)) => Ok(Json(progress)),
        Ok(None) => Err(ApiError::not_found("repository import not found")),
        Err(RepoImportError::InvalidId) => {
            Err(ApiError::bad_request("invalid repository import id"))
        }
        Err(RepoImportError::Internal(err)) => Err(ApiError::internal(err)),
    }
}

/// `DELETE /v1/repo-imports/{id}`.
pub async fn cancel_import(
    State(app): State<AppState>,
    UrlPath(id): UrlPath<String>,
) -> Result<Json<RepoImportProgress>, ApiError> {
    match app.repo_imports.cancel(&id) {
        Ok(progress) => Ok(Json(progress)),
        Err(RepoImportError::InvalidId) => {
            Err(ApiError::bad_request("invalid repository import id"))
        }
        Err(RepoImportError::Internal(err)) => Err(ApiError::internal(err)),
    }
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
    validate_import_id(&record.id).map_err(anyhow::Error::new)?;
    validate_identifier(&record.repo_id)?;
    validate_identifier(&record.repo_name)?;
    validate_identifier(&record.destination_name)?;
    anyhow::ensure!(record.generation < u64::MAX, "invalid import generation");
    Ok(())
}

fn validate_import_id(value: &str) -> Result<(), RepoImportError> {
    if value.len() != "import-".len() + 32 {
        return Err(RepoImportError::InvalidId);
    }
    let Some(hex) = value.strip_prefix("import-") else {
        return Err(RepoImportError::InvalidId);
    };
    if !hex
        .bytes()
        .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        return Err(RepoImportError::InvalidId);
    }
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
    let Some(bytes) = bounded_read(&path, MAX_RECOVERY_BYTES)? else {
        return Ok(Vec::new());
    };
    let imports = serde_json::from_slice::<RecoveryFile>(&bytes)?.imports;
    anyhow::ensure!(imports.len() <= MAX_PROGRESS, "too many recovery records");
    Ok(imports)
}

fn bounded_read(path: &Path, max_bytes: u64) -> anyhow::Result<Option<Vec<u8>>> {
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err.into()),
    };
    Ok(Some(read_bounded(file, max_bytes)?))
}

fn read_bounded(reader: impl Read, max_bytes: u64) -> anyhow::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    reader
        .take(max_bytes.saturating_add(1))
        .read_to_end(&mut bytes)?;
    anyhow::ensure!(bytes.len() as u64 <= max_bytes, "state file is too large");
    Ok(bytes)
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
        assert!(
            manager
                .get("import-ABC00000000000000000000000000000")
                .is_err()
        );
        assert!(manager.cancel("../bad").is_err());
        assert!(!dir.path().join(RECOVERY_FILE).exists());
    }

    #[test]
    fn invalid_ids_and_persistence_failures_have_distinct_error_kinds() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        let manager = RepoImportManager::open(&state).unwrap();
        assert!(matches!(
            manager.get("not-an-import-id"),
            Err(RepoImportError::InvalidId)
        ));

        let progress = manager
            .start(RepoImportRequest {
                provider: ProviderId::Github,
                repo_id: "owner-name".to_owned(),
                requested_name: None,
            })
            .unwrap();
        let backup = dir.path().join("state-backup");
        std::fs::rename(&state, &backup).unwrap();
        std::fs::write(&state, b"not a directory").unwrap();

        assert!(matches!(
            manager.cancel(&progress.id),
            Err(RepoImportError::Internal(_))
        ));
    }

    #[test]
    fn oversized_recovery_file_is_rejected_on_restart() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join(RECOVERY_FILE),
            vec![b' '; (MAX_RECOVERY_BYTES + 1) as usize],
        )
        .unwrap();
        assert!(RepoImportManager::open(dir.path()).is_err());
    }

    #[test]
    fn recovery_record_limit_is_enforced_during_deserialization() {
        let record = |index| {
            format!(
                r#"{{"id":"import-{index:032x}","state":"queued","provider":"github","repo_id":"repo-{index}","repo_name":"repo-{index}","destination_name":"repo-{index}","generation":0,"updated_at":"2026-08-23T18:00:00Z"}}"#
            )
        };
        let mut records = (0..MAX_PROGRESS).map(record).collect::<Vec<_>>();
        records.push(r#"{"id":42}"#.to_owned());
        let json = format!(r#"{{"imports":[{}]}}"#, records.join(","));

        let error = serde_json::from_str::<RecoveryFile>(&json).unwrap_err();
        assert!(error.to_string().contains("too many recovery records"));
    }

    #[test]
    fn recovery_state_reader_rejects_streams_beyond_the_limit() {
        let error = read_bounded(std::io::Cursor::new(b"12345"), 4).unwrap_err();
        assert!(error.to_string().contains("state file is too large"));
    }
}
