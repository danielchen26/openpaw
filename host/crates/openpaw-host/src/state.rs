//! Persistent daemon state: paired devices, adapter cursors, and the hook token.
//!
//! Everything lives in `<state_dir>` with restrictive permissions. Two rules
//! drive the design:
//!
//! * the raw bearer token is never written to disk — only its SHA-256 — so a
//!   leaked `state.json` cannot be replayed against the daemon;
//! * permissions are verified *and repaired* on every boot, because a state
//!   directory that became world-readable after a careless `chmod -R` is a
//!   silent credential leak.
//!
//! State writes are synchronous `std::fs` calls. The file is a few kilobytes and
//! is written only on pairing and on polls that produced events, so the cost is
//! irrelevant next to the complexity of an async write path.

use std::collections::BTreeMap;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::{Context, Result};
use openpaw_agents::Cursor;
use openpaw_protocol::{InboxId, SessionId};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::auth::{constant_time_eq, sha256_hex};

/// Directory mode: owner-only. Nothing else needs to traverse it.
const DIR_MODE: u32 = 0o700;
/// File mode for anything holding secret material.
const SECRET_MODE: u32 = 0o600;

/// A paired device. One row per phone.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Device {
    /// Opaque identifier sent in `X-OpenPaw-Device`.
    pub device_id: String,
    /// Human label chosen at pairing time.
    pub name: String,
    /// Reported platform, e.g. `ios`.
    pub platform: String,
    /// Base64 HMAC key; the device holds the same bytes.
    pub hmac_key_b64: String,
    /// SHA-256 (lowercase hex) of the bearer token. The token itself is shown
    /// exactly once, at pairing.
    pub token_sha256: String,
    /// Granted capability names.
    pub capabilities: Vec<String>,
    /// When pairing completed.
    #[serde(with = "time::serde::rfc3339")]
    pub paired_at: OffsetDateTime,
    /// Last authenticated request.
    #[serde(default, with = "time::serde::rfc3339::option")]
    pub last_seen: Option<OffsetDateTime>,
}

impl Device {
    /// True when this device holds `capability`.
    pub fn has_capability(&self, capability: &str) -> bool {
        self.capabilities.iter().any(|c| c == capability)
    }

    /// Decode the device's HMAC key.
    pub fn hmac_key(&self) -> Result<Vec<u8>> {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD
            .decode(self.hmac_key_b64.as_bytes())
            .context("device hmac key is not valid base64")
    }
}

/// On-disk shape of `state.json`.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(default)]
struct StateFile {
    devices: Vec<Device>,
    /// One cursor per session id, so a restart resumes parsing instead of
    /// replaying every transcript from byte zero.
    cursors: BTreeMap<String, Cursor>,
    /// Inbox ids the operator dismissed locally.
    dismissed_inbox: BTreeMap<String, DismissedInboxItem>,
}

/// Durable local dismissal tombstone for informational inbox items.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DismissedInboxItem {
    /// Inbox item id.
    pub inbox_id: String,
    /// Device that dismissed it.
    pub device_id: String,
    /// Dismissal time.
    #[serde(with = "time::serde::rfc3339")]
    pub dismissed_at: OffsetDateTime,
}

/// Owner of the state directory.
#[derive(Debug)]
pub struct Store {
    state_dir: PathBuf,
    path: PathBuf,
    hook_token: String,
    inner: Mutex<StateFile>,
}

impl Store {
    /// Open (or create) the state directory and load `state.json`.
    ///
    /// Creates `state.json`, `hook-token`, `uploads/` and `decisions/` with
    /// owner-only permissions, and repairs the modes of anything that already
    /// exists.
    pub fn open(state_dir: &Path) -> Result<Store> {
        ensure_private_dir(state_dir)?;
        for sub in ["uploads", "decisions"] {
            ensure_private_dir(&state_dir.join(sub))?;
        }

        let path = state_dir.join("state.json");
        let inner = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice::<StateFile>(&bytes)
                .with_context(|| format!("parsing {}", path.display()))?,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => StateFile::default(),
            Err(err) => return Err(err).with_context(|| format!("reading {}", path.display())),
        };
        if path.exists() {
            ensure_private_file(&path)?;
        }

        let hook_token = load_or_create_hook_token(&state_dir.join("hook-token"))?;

        Ok(Store {
            state_dir: state_dir.to_path_buf(),
            path,
            hook_token,
            inner: Mutex::new(inner),
        })
    }

    /// The state directory root.
    pub fn state_dir(&self) -> &Path {
        &self.state_dir
    }

    /// Directory the resolve endpoint writes decision files into.
    pub fn decisions_dir(&self) -> PathBuf {
        self.state_dir.join("decisions")
    }

    /// Directory uploads land in.
    pub fn uploads_dir(&self) -> PathBuf {
        self.state_dir.join("uploads")
    }

    /// The shared secret that local agent hooks and the CLI use.
    pub fn hook_token(&self) -> &str {
        &self.hook_token
    }

    /// Constant-time check of a presented hook token.
    pub fn verify_hook_token(&self, presented: &str) -> bool {
        constant_time_eq(self.hook_token.as_bytes(), presented.as_bytes())
    }

    /// Look up a device by id.
    pub fn device(&self, device_id: &str) -> Option<Device> {
        let guard = self.lock();
        guard
            .devices
            .iter()
            .find(|d| d.device_id == device_id)
            .cloned()
    }

    /// Authenticate a bearer token against a device id.
    ///
    /// Returns `None` on an unknown device *or* a bad token; the caller must not
    /// distinguish the two in its response.
    pub fn authenticate(&self, device_id: &str, bearer: &str) -> Option<Device> {
        let device = self.device(device_id)?;
        let presented = sha256_hex(bearer.as_bytes());
        if constant_time_eq(device.token_sha256.as_bytes(), presented.as_bytes()) {
            Some(device)
        } else {
            None
        }
    }

    /// Record a newly paired device.
    pub fn insert_device(&self, device: Device) -> Result<()> {
        {
            let mut guard = self.lock();
            guard.devices.retain(|d| d.device_id != device.device_id);
            guard.devices.push(device);
        }
        self.persist()
    }

    /// Stamp `last_seen`. Best effort: a failed stamp must never fail a request.
    pub fn touch_device(&self, device_id: &str, now: OffsetDateTime) {
        {
            let mut guard = self.lock();
            match guard.devices.iter_mut().find(|d| d.device_id == device_id) {
                Some(device) => device.last_seen = Some(now),
                None => return,
            }
        }
        if let Err(err) = self.persist() {
            tracing::warn!(%err, "could not persist device last_seen");
        }
    }

    /// Every paired device.
    pub fn devices(&self) -> Vec<Device> {
        self.lock().devices.clone()
    }

    /// Load the persisted cursor for a session, or a fresh one.
    pub fn cursor(&self, session: &SessionId) -> Cursor {
        self.lock()
            .cursors
            .get(session.as_ref())
            .cloned()
            .unwrap_or_default()
    }

    /// Store cursors advanced by a poll pass and flush to disk.
    pub fn save_cursors(&self, updated: Vec<(SessionId, Cursor)>) -> Result<()> {
        if updated.is_empty() {
            return Ok(());
        }
        {
            let mut guard = self.lock();
            for (session, cursor) in updated {
                guard.cursors.insert(session.as_ref().to_owned(), cursor);
            }
        }
        self.persist()
    }

    /// Persist an informational inbox dismissal tombstone before in-memory mutation.
    pub fn insert_dismissed_inbox(
        &self,
        id: &InboxId,
        device_id: &str,
        at: OffsetDateTime,
    ) -> Result<bool> {
        let mut inserted = false;
        {
            let mut guard = self.lock();
            if !guard.dismissed_inbox.contains_key(id.as_ref()) {
                guard.dismissed_inbox.insert(
                    id.as_ref().to_owned(),
                    DismissedInboxItem {
                        inbox_id: id.as_ref().to_owned(),
                        device_id: device_id.to_owned(),
                        dismissed_at: at,
                    },
                );
                inserted = true;
            }
        }
        if inserted {
            self.persist()?;
        }
        Ok(inserted)
    }

    /// True when an inbox item id has a durable local dismissal tombstone.
    pub fn is_inbox_dismissed(&self, id: &InboxId) -> bool {
        self.lock().dismissed_inbox.contains_key(id.as_ref())
    }

    /// All durable local dismissal ids.
    pub fn dismissed_inbox_ids(&self) -> Vec<InboxId> {
        self.lock()
            .dismissed_inbox
            .keys()
            .filter_map(|id| id.parse().ok())
            .collect()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, StateFile> {
        // A poisoned lock means a previous holder panicked mid-mutation. The
        // state is a plain document with no cross-field invariant, so recovering
        // is strictly better than taking the whole daemon down.
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Serialize and replace `state.json` atomically at mode 0600.
    fn persist(&self) -> Result<()> {
        let snapshot = self.lock().clone();
        let bytes = serde_json::to_vec_pretty(&snapshot)?;
        write_private_atomic(&self.path, &bytes)
    }
}

/// Create `path` if needed and force owner-only permissions.
pub fn ensure_private_dir(path: &Path) -> Result<()> {
    if !path.exists() {
        std::fs::create_dir_all(path).with_context(|| format!("creating {}", path.display()))?;
    }
    let mut perms = std::fs::metadata(path)
        .with_context(|| format!("stat {}", path.display()))?
        .permissions();
    if perms.mode() & 0o777 != DIR_MODE {
        perms.set_mode(DIR_MODE);
        std::fs::set_permissions(path, perms)
            .with_context(|| format!("tightening permissions on {}", path.display()))?;
        tracing::warn!(path = %path.display(), "repaired directory permissions to 0700");
    }
    Ok(())
}

/// Force mode 0600 on an existing file.
pub fn ensure_private_file(path: &Path) -> Result<()> {
    let mut perms = std::fs::metadata(path)
        .with_context(|| format!("stat {}", path.display()))?
        .permissions();
    if perms.mode() & 0o777 != SECRET_MODE {
        perms.set_mode(SECRET_MODE);
        std::fs::set_permissions(path, perms)
            .with_context(|| format!("tightening permissions on {}", path.display()))?;
        tracing::warn!(path = %path.display(), "repaired file permissions to 0600");
    }
    Ok(())
}

/// Write `bytes` to `path` via a same-directory temporary file, so a crash can
/// never leave a half-written state file, and never at a mode wider than 0600.
pub fn write_private_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let dir = path
        .parent()
        .context("state file must have a parent directory")?;
    let tmp = dir.join(format!(
        ".{}.tmp-{}",
        path.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("openpaw"),
        std::process::id()
    ));
    {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(SECRET_MODE)
            .open(&tmp)
            .with_context(|| format!("creating {}", tmp.display()))?;
        file.write_all(bytes)
            .with_context(|| format!("writing {}", tmp.display()))?;
        file.sync_all()
            .with_context(|| format!("fsync {}", tmp.display()))?;
    }
    std::fs::rename(&tmp, path).with_context(|| format!("replacing {}", path.display()))?;
    ensure_private_file(path)
}

/// Read `hook-token`, minting one at mode 0600 if it does not exist.
fn load_or_create_hook_token(path: &Path) -> Result<String> {
    match std::fs::read_to_string(path) {
        Ok(text) => {
            let token = text.trim().to_owned();
            if token.is_empty() {
                anyhow::bail!("{} is empty; delete it and restart", path.display());
            }
            ensure_private_file(path)?;
            Ok(token)
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            let token = crate::auth::mint_secret();
            write_private_atomic(path, format!("{token}\n").as_bytes())?;
            tracing::info!(path = %path.display(), "minted a new hook token");
            Ok(token)
        }
        Err(err) => Err(err).with_context(|| format!("reading {}", path.display())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device(id: &str, token: &str) -> Device {
        Device {
            device_id: id.to_owned(),
            name: "phone".into(),
            platform: "ios".into(),
            hmac_key_b64: "AAAA".into(),
            token_sha256: sha256_hex(token.as_bytes()),
            capabilities: vec!["sessions.read".into()],
            paired_at: OffsetDateTime::UNIX_EPOCH,
            last_seen: None,
        }
    }

    #[test]
    fn dismissed_inbox_tombstones_persist_across_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("state");
        let id: InboxId = "inb_0123456789abcdef01234567".parse().unwrap();
        let store = Store::open(&root).unwrap();
        assert!(
            store
                .insert_dismissed_inbox(&id, "dev_a", OffsetDateTime::UNIX_EPOCH)
                .unwrap()
        );
        assert!(
            !store
                .insert_dismissed_inbox(&id, "dev_a", OffsetDateTime::UNIX_EPOCH)
                .unwrap()
        );
        drop(store);

        let reopened = Store::open(&root).unwrap();
        assert!(reopened.is_inbox_dismissed(&id));
        assert_eq!(reopened.dismissed_inbox_ids(), vec![id]);
    }

    #[test]
    fn state_dir_and_hook_token_are_owner_only() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("state");
        let store = Store::open(&root).unwrap();
        assert!(!store.hook_token().is_empty());

        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&root), 0o700);
        assert_eq!(mode(&root.join("hook-token")), 0o600);
        assert_eq!(mode(&root.join("uploads")), 0o700);
        assert_eq!(mode(&root.join("decisions")), 0o700);
    }

    #[test]
    fn loose_permissions_are_repaired_on_boot() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("state");
        let token = {
            let store = Store::open(&root).unwrap();
            store.hook_token().to_owned()
        };

        let hook = root.join("hook-token");
        std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o644)).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();

        let store = Store::open(&root).unwrap();
        assert_eq!(store.hook_token(), token, "an existing token is reused");
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&hook), 0o600);
        assert_eq!(mode(&root), 0o700);
    }

    #[test]
    fn raw_bearer_tokens_never_reach_the_state_file() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("state");
        let store = Store::open(&root).unwrap();
        store
            .insert_device(device("dev_a", "super-secret-token"))
            .unwrap();

        let text = std::fs::read_to_string(root.join("state.json")).unwrap();
        assert!(!text.contains("super-secret-token"));
        assert!(text.contains(&sha256_hex(b"super-secret-token")));
        assert_eq!(
            std::fs::metadata(root.join("state.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn authentication_requires_the_exact_token() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(&dir.path().join("state")).unwrap();
        store.insert_device(device("dev_a", "right")).unwrap();

        assert!(store.authenticate("dev_a", "right").is_some());
        assert!(store.authenticate("dev_a", "wrong").is_none());
        assert!(store.authenticate("dev_missing", "right").is_none());
    }

    #[test]
    fn devices_and_cursors_survive_a_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("state");
        let session: SessionId = "sess_cc-alpha".parse().unwrap();
        {
            let store = Store::open(&root).unwrap();
            store.insert_device(device("dev_a", "right")).unwrap();
            assert!(store.cursor(&session).is_empty());
            let cursor = Cursor::default();
            store.save_cursors(vec![(session.clone(), cursor)]).unwrap();
        }
        let store = Store::open(&root).unwrap();
        assert_eq!(store.devices().len(), 1);
        assert!(
            store
                .device("dev_a")
                .unwrap()
                .has_capability("sessions.read")
        );
        assert!(
            !store
                .device("dev_a")
                .unwrap()
                .has_capability("approvals.write")
        );
    }
}
