//! Append-only audit log.
//!
//! One JSONL line per authenticated mutating request and per pairing, fsynced
//! before the response goes out. The point is that the log survives a crash that
//! happens right after a decision was applied — an approval that reached the
//! agent but left no trace would be the worst possible failure mode for a tool
//! that approves `rm -rf` from a phone.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use tokio::io::AsyncWriteExt;
use tokio::sync::Mutex;

/// One audit record.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AuditEntry {
    /// When the request was served.
    #[serde(with = "time::serde::rfc3339")]
    pub at: OffsetDateTime,
    /// Device that made the request, or `local-cli` for hook-token callers.
    pub device_id: String,
    /// What was attempted, e.g. `inbox.resolve` or `device.pair`.
    pub action: String,
    /// What it was attempted against, e.g. an inbox id or an upload path.
    pub target: String,
    /// Outcome in human terms, e.g. `approve_once (detail acknowledged)`.
    pub result: String,
}

impl AuditEntry {
    /// Build an entry stamped with the current time.
    pub fn now(
        device_id: impl Into<String>,
        action: impl Into<String>,
        target: impl Into<String>,
        result: impl Into<String>,
    ) -> AuditEntry {
        AuditEntry {
            at: OffsetDateTime::now_utc(),
            device_id: device_id.into(),
            action: action.into(),
            target: target.into(),
            result: result.into(),
        }
    }
}

/// Serialized writer for `<state_dir>/audit.jsonl`.
#[derive(Debug)]
pub struct Audit {
    path: PathBuf,
    /// Serializes appends so two concurrent decisions cannot interleave bytes.
    write_lock: Mutex<()>,
}

impl Audit {
    /// Point the log at `<state_dir>/audit.jsonl`.
    pub fn new(state_dir: &Path) -> Audit {
        Audit {
            path: state_dir.join("audit.jsonl"),
            write_lock: Mutex::new(()),
        }
    }

    /// The log path.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Append one line and fsync it.
    pub async fn append(&self, entry: &AuditEntry) -> std::io::Result<()> {
        let mut line = serde_json::to_vec(entry).map_err(std::io::Error::other)?;
        line.push(b'\n');

        let _guard = self.write_lock.lock().await;
        let mut file = tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(&self.path)
            .await?;
        file.write_all(&line).await?;
        file.flush().await?;
        // `sync_data` is enough: we only need the appended bytes durable, not
        // the directory entry, which already exists after the first append.
        file.sync_data().await
    }

    /// Most recent `limit` entries, newest first.
    ///
    /// Unparseable lines are skipped rather than failing the request: a
    /// truncated tail from a power loss must not make the whole log unreadable.
    pub async fn tail(&self, limit: usize) -> std::io::Result<Vec<AuditEntry>> {
        let text = match tokio::fs::read_to_string(&self.path).await {
            Ok(text) => text,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(err) => return Err(err),
        };
        let mut out: Vec<AuditEntry> = text
            .lines()
            .rev()
            .filter(|line| !line.trim().is_empty())
            .filter_map(|line| serde_json::from_str::<AuditEntry>(line).ok())
            .take(limit)
            .collect();
        out.shrink_to_fit();
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[tokio::test]
    async fn appends_are_newline_delimited_and_owner_only() {
        let dir = tempfile::tempdir().unwrap();
        let audit = Audit::new(dir.path());
        assert!(audit.tail(10).await.unwrap().is_empty());

        audit
            .append(&AuditEntry::now("dev_a", "device.pair", "phone", "paired"))
            .await
            .unwrap();
        audit
            .append(&AuditEntry::now(
                "dev_a",
                "inbox.resolve",
                "inb_1",
                "approve_once (detail acknowledged)",
            ))
            .await
            .unwrap();

        let raw = std::fs::read_to_string(audit.path()).unwrap();
        assert_eq!(raw.lines().count(), 2);
        assert_eq!(
            std::fs::metadata(audit.path())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );

        let entries = audit.tail(10).await.unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].action, "inbox.resolve", "newest first");
        assert_eq!(entries[0].result, "approve_once (detail acknowledged)");
        assert_eq!(entries[1].action, "device.pair");
    }

    #[tokio::test]
    async fn tail_honours_the_limit_and_skips_a_torn_line() {
        let dir = tempfile::tempdir().unwrap();
        let audit = Audit::new(dir.path());
        for i in 0..5 {
            audit
                .append(&AuditEntry::now(
                    "dev_a",
                    "inbox.resolve",
                    format!("inb_{i}"),
                    "deny",
                ))
                .await
                .unwrap();
        }
        // Simulate a power loss mid-append.
        tokio::fs::write(
            audit.path(),
            format!(
                "{}{{\"at\":\"2026",
                tokio::fs::read_to_string(audit.path()).await.unwrap()
            ),
        )
        .await
        .unwrap();

        let entries = audit.tail(3).await.unwrap();
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].target, "inb_4");
        assert_eq!(entries[2].target, "inb_2");
    }
}
