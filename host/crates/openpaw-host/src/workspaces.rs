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

/// Durable dynamic workspace record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkspaceRecord {
    /// Host-owned stable root id.
    pub root_id: String,
    /// Client-visible repository name.
    pub name: String,
    /// Canonical host path.
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
        let snapshot = Arc::new(build_roots(&config_roots, &records)?);
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
        let repos_dir = self.state_dir.join("repos");
        fs::create_dir_all(&repos_dir).context("creating repository state directory")?;
        let candidate = repos_dir.join(root_id);
        let canonical =
            fs::canonicalize(&candidate).context("registered repository is not available")?;
        let repos_canon =
            fs::canonicalize(&repos_dir).context("canonicalizing repository state directory")?;
        anyhow::ensure!(
            canonical.starts_with(&repos_canon),
            "registered repository is outside host storage"
        );
        anyhow::ensure!(
            canonical.is_dir(),
            "registered repository is not a directory"
        );

        let name = requested_name.unwrap_or(root_id).to_owned();
        validate_identifier(&name)?;
        let record = WorkspaceRecord {
            root_id: root_id.to_owned(),
            name,
            path: canonical,
        };

        let mut records = self.records.write().expect("workspace records poisoned");
        if !records
            .iter()
            .any(|existing| existing.root_id == record.root_id)
        {
            records.push(record);
            persist_records(&self.state_dir, &records)?;
        }
        let next = Arc::new(build_roots(&self.config_roots, &records)?);
        *self.snapshot.write().expect("workspace snapshot poisoned") = next.clone();
        Ok(next)
    }
}

fn build_roots(config_roots: &[PathBuf], records: &[WorkspaceRecord]) -> Result<Roots> {
    let paths = config_roots
        .iter()
        .cloned()
        .chain(records.iter().map(|r| r.path.clone()));
    Roots::new(paths).map_err(|err| anyhow::anyhow!(err))
}

fn load_records(state_dir: &Path) -> Result<Vec<WorkspaceRecord>> {
    let path = state_dir.join(REGISTRY_FILE);
    match fs::read(&path) {
        Ok(bytes) => Ok(serde_json::from_slice::<RegistryFile>(&bytes)
            .with_context(|| format!("parsing {}", path.display()))?
            .workspaces),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(err) => Err(err).with_context(|| format!("reading {}", path.display())),
    }
}

fn persist_records(state_dir: &Path, records: &[WorkspaceRecord]) -> Result<()> {
    fs::create_dir_all(state_dir).context("creating state directory")?;
    let path = state_dir.join(REGISTRY_FILE);
    let tmp = state_dir.join(format!(".{REGISTRY_FILE}.{}.tmp", uuid::Uuid::new_v4()));
    let bytes = serde_json::to_vec_pretty(&RegistryFile {
        workspaces: records.to_vec(),
    })?;
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
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::thread;

    use super::*;

    #[test]
    fn register_known_rejects_arbitrary_path_and_persists_reload() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        fs::create_dir_all(state.join("repos/server-root/.git")).unwrap();
        fs::create_dir_all(dir.path().join("outside/.git")).unwrap();
        let registry = WorkspaceRegistry::open(&state, Vec::new()).unwrap();

        assert!(registry.register_known("../../outside", None).is_err());
        let snapshot = registry
            .register_known("server-root", Some("visible-root"))
            .unwrap();
        assert!(snapshot.names().contains(&"server-root".to_owned()));

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
                .contains(&"server-root".to_owned())
        );
    }

    #[test]
    fn old_snapshots_are_immutable_while_new_snapshots_publish_atomically() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        fs::create_dir_all(state.join("repos/one/.git")).unwrap();
        fs::create_dir_all(state.join("repos/two/.git")).unwrap();
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
}
