//! Concurrency-safe workspace root registry.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};

use anyhow::{Context, Result};
use openpaw_files::Roots;
use serde::{Deserialize, Serialize};

const REGISTRY_FILE: &str = "workspace-registry.json";
const SECRET_MODE: u32 = 0o600;
const MAX_RECORDS: usize = 512;

/// Durable dynamic workspace record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkspaceRecord {
    /// Host-owned stable root id under `<state_dir>/repos`.
    pub root_id: String,
    /// Preferred client-visible repository name.
    pub name: String,
    /// Legacy field. Ignored on load because stored absolute paths are not trusted.
    #[serde(default)]
    pub path: PathBuf,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(default)]
struct RegistryFile {
    workspaces: Vec<WorkspaceRecord>,
}

/// Immutable-snapshot repository registry.
#[derive(Debug)]
pub struct WorkspaceRegistry {
    state_dir: PathBuf,
    config_roots: Vec<PathBuf>,
    records: RwLock<Vec<WorkspaceRecord>>,
    snapshot: RwLock<Arc<Roots>>,
}

impl WorkspaceRegistry {
    /// Load dynamic records and build the first roots snapshot.
    pub fn open(state_dir: &Path, config_roots: Vec<PathBuf>) -> Result<Self> {
        let records = load_records(state_dir)?;
        let snapshot = Arc::new(build_roots(state_dir, &config_roots, &records)?);
        Ok(Self {
            state_dir: state_dir.to_path_buf(),
            config_roots,
            records: RwLock::new(records),
            snapshot: RwLock::new(snapshot),
        })
    }

    /// Current immutable roots snapshot.
    pub fn snapshot(&self) -> Arc<Roots> {
        self.snapshot
            .read()
            .expect("workspace snapshot poisoned")
            .clone()
    }

    /// Register an already host-known root id. The client never supplies a path.
    pub fn register_known(
        &self,
        root_id: &str,
        requested_name: Option<&str>,
    ) -> Result<Arc<Roots>> {
        validate_identifier(root_id)?;
        let name = requested_name.unwrap_or(root_id).to_owned();
        validate_identifier(&name)?;
        let record = validated_record(&self.state_dir, root_id, &name)?;

        let records = self
            .records
            .read()
            .expect("workspace records poisoned")
            .clone();
        let mut next_records = records.clone();
        if let Some(existing) = next_records
            .iter_mut()
            .find(|existing| existing.root_id == root_id)
        {
            existing.name = record.name.clone();
        } else {
            next_records.push(record);
        }
        let next_snapshot = Arc::new(build_roots(
            &self.state_dir,
            &self.config_roots,
            &next_records,
        )?);
        persist_records(&self.state_dir, &next_records)?;

        *self.records.write().expect("workspace records poisoned") = next_records;
        *self.snapshot.write().expect("workspace snapshot poisoned") = next_snapshot.clone();
        Ok(next_snapshot)
    }

    /// Find the published client-visible name for a root id.
    pub fn visible_name(&self, root_id: &str) -> Option<String> {
        let records = self.records.read().expect("workspace records poisoned");
        let record = records.iter().find(|record| record.root_id == root_id)?;
        let path = record_path(&self.state_dir, &record.root_id).ok()?;
        self.snapshot()
            .all()
            .iter()
            .find(|root| root.path == path)
            .map(|root| root.name.clone())
    }
}

fn build_roots(
    state_dir: &Path,
    config_roots: &[PathBuf],
    records: &[WorkspaceRecord],
) -> Result<Roots> {
    let config = config_roots.iter().cloned().map(|path| (None, path));
    let mut roots = Vec::with_capacity(config_roots.len() + records.len());
    roots.extend(config);
    for record in records {
        roots.push((
            Some(record.name.clone()),
            record_path(state_dir, &record.root_id)?,
        ));
    }
    Roots::with_names(roots).map_err(|err| anyhow::anyhow!(err))
}

fn load_records(state_dir: &Path) -> Result<Vec<WorkspaceRecord>> {
    let path = state_dir.join(REGISTRY_FILE);
    let records = match fs::read(&path) {
        Ok(bytes) => {
            serde_json::from_slice::<RegistryFile>(&bytes)
                .with_context(|| format!("parsing {}", path.display()))?
                .workspaces
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(err) => return Err(err).with_context(|| format!("reading {}", path.display())),
    };
    anyhow::ensure!(records.len() <= MAX_RECORDS, "too many workspace records");
    let mut validated = Vec::with_capacity(records.len());
    for record in records {
        validate_identifier(&record.root_id)?;
        validate_identifier(&record.name)?;
        validated.push(validated_record(state_dir, &record.root_id, &record.name)?);
    }
    Ok(validated)
}

fn validated_record(state_dir: &Path, root_id: &str, name: &str) -> Result<WorkspaceRecord> {
    let path = record_path(state_dir, root_id)?;
    ensure_working_git_repo(state_dir, root_id, &path)?;
    Ok(WorkspaceRecord {
        root_id: root_id.to_owned(),
        name: name.to_owned(),
        path,
    })
}

fn record_path(state_dir: &Path, root_id: &str) -> Result<PathBuf> {
    validate_identifier(root_id)?;
    let repos_dir = state_dir.join("repos");
    fs::create_dir_all(&repos_dir).context("creating repository state directory")?;
    let candidate = repos_dir.join(root_id);
    let metadata =
        fs::symlink_metadata(&candidate).context("registered repository is not available")?;
    anyhow::ensure!(
        !metadata.file_type().is_symlink(),
        "registered repository is a symlink"
    );
    let canonical = fs::canonicalize(&candidate).context("canonicalizing registered repository")?;
    let repos_canon =
        fs::canonicalize(&repos_dir).context("canonicalizing repository state directory")?;
    anyhow::ensure!(
        canonical.starts_with(&repos_canon),
        "registered repository is outside host storage"
    );
    Ok(canonical)
}

fn ensure_working_git_repo(state_dir: &Path, root_id: &str, canonical: &Path) -> Result<()> {
    anyhow::ensure!(
        canonical.is_dir(),
        "registered repository is not a directory"
    );
    let git = canonical.join(".git");
    let git_meta =
        fs::symlink_metadata(&git).context("registered repository is not a git repository")?;
    anyhow::ensure!(
        !git_meta.file_type().is_symlink(),
        "git metadata is a symlink"
    );
    anyhow::ensure!(
        git_meta.is_dir() || git_meta.is_file(),
        "registered repository is not a git repository"
    );
    let repos = fs::canonicalize(state_dir.join("repos"))?;
    let git_canon = fs::canonicalize(git)?;
    anyhow::ensure!(
        git_canon.starts_with(&repos),
        "git metadata escapes host storage"
    );
    validate_identifier(root_id)?;
    Ok(())
}

fn persist_records(state_dir: &Path, records: &[WorkspaceRecord]) -> Result<()> {
    fs::create_dir_all(state_dir).context("creating state directory")?;
    let path = state_dir.join(REGISTRY_FILE);
    let tmp = state_dir.join(format!(".{REGISTRY_FILE}.{}.tmp", uuid::Uuid::new_v4()));
    let bytes = serde_json::to_vec_pretty(&RegistryFile {
        workspaces: records.to_vec(),
    })?;
    let result = (|| -> Result<()> {
        {
            let mut file = OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(SECRET_MODE)
                .open(&tmp)
                .with_context(|| format!("creating {}", tmp.display()))?;
            file.write_all(&bytes)?;
            file.sync_all()?;
        }
        fs::rename(&tmp, &path)?;
        let dir = OpenOptions::new().read(true).open(state_dir)?;
        dir.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

fn validate_identifier(value: &str) -> Result<()> {
    anyhow::ensure!(!value.is_empty(), "identifier is required");
    anyhow::ensure!(value.len() <= 128, "identifier is too long");
    anyhow::ensure!(
        value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-')),
        "identifier is invalid"
    );
    anyhow::ensure!(value != "." && value != "..", "identifier is invalid");
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::thread;

    use super::*;

    fn git_init(path: &Path) {
        fs::create_dir_all(path).unwrap();
        let status = std::process::Command::new("git")
            .arg("init")
            .arg(path)
            .status()
            .unwrap();
        assert!(status.success());
    }

    #[test]
    fn register_known_rejects_arbitrary_path_and_persists_reload() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        git_init(&state.join("repos/server-root"));
        git_init(&dir.path().join("outside"));
        let registry = WorkspaceRegistry::open(&state, Vec::new()).unwrap();

        assert!(registry.register_known("../../outside", None).is_err());
        let snapshot = registry
            .register_known("server-root", Some("visible-root"))
            .unwrap();
        assert!(snapshot.names().contains(&"visible-root".to_owned()));

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(state.join(REGISTRY_FILE))
                .unwrap()
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(mode, 0o600);
        }

        let reloaded = WorkspaceRegistry::open(&state, Vec::new()).unwrap();
        assert!(
            reloaded
                .snapshot()
                .names()
                .contains(&"visible-root".to_owned())
        );
    }

    #[test]
    fn old_snapshots_are_immutable_while_new_snapshots_publish_atomically() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        git_init(&state.join("repos/one"));
        git_init(&state.join("repos/two"));
        let registry = Arc::new(WorkspaceRegistry::open(&state, Vec::new()).unwrap());
        registry.register_known("one", None).unwrap();
        let old = registry.snapshot();
        let readers: Vec<_> = (0..8)
            .map(|_| {
                let old = old.clone();
                thread::spawn(move || {
                    for _ in 0..100 {
                        assert_eq!(old.names(), vec!["one".to_owned()]);
                    }
                })
            })
            .collect();
        registry.register_known("two", None).unwrap();
        for reader in readers {
            reader.join().unwrap();
        }
        let names = registry.snapshot().names();
        assert!(names.contains(&"one".to_owned()));
        assert!(names.contains(&"two".to_owned()));
        assert_eq!(old.names(), vec!["one".to_owned()]);
    }

    #[test]
    fn boot_rejects_malicious_persisted_records_and_non_git_dirs() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        fs::create_dir_all(state.join("repos/plain")).unwrap();
        fs::create_dir_all(&state).unwrap();
        fs::write(
            state.join(REGISTRY_FILE),
            r#"{"workspaces":[{"root_id":"plain","name":"plain","path":"/tmp/evil"}]}"#,
        )
        .unwrap();
        assert!(WorkspaceRegistry::open(&state, Vec::new()).is_err());
    }

    #[test]
    fn requested_names_are_visible_and_collide_deterministically() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        git_init(&state.join("repos/one"));
        git_init(&state.join("repos/two"));
        let registry = WorkspaceRegistry::open(&state, Vec::new()).unwrap();
        registry.register_known("one", Some("repo")).unwrap();
        registry.register_known("two", Some("repo")).unwrap();
        assert_eq!(registry.snapshot().names(), vec!["repo", "repo-2"]);
    }
}
