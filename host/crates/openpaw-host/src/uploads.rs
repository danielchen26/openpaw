//! Attachment uploads.
//!
//! The phone needs to hand a screenshot or a log to the agent, and this is the
//! only write path into the filesystem the daemon offers. It is deliberately
//! narrow: a caller chooses neither the directory nor the stem of the file, only
//! an extension out of a fixed allowlist. There is no way to phrase a request
//! that lands bytes outside `<state_dir>/uploads/`.

use std::path::{Path, PathBuf};

use axum::extract::State;
use axum::http::HeaderMap;
use axum::{Extension, Json};
use bytes::Bytes;
use serde::{Deserialize, Serialize};

use crate::AppState;
use crate::api::ApiError;
use crate::audit::AuditEntry;
use crate::auth::{AuthedDevice, sha256_hex};

/// Header carrying the client's original filename.
pub const FILENAME_HEADER: &str = "x-openpaw-filename";

/// Extensions the daemon will store.
///
/// An allowlist rather than a denylist, and no archive or executable formats: a
/// `.zip` or `.sh` in a directory the agent can see is an invitation to unpack or
/// run something the operator never reviewed.
pub const ALLOWED_EXTENSIONS: &[&str] = &[
    "png", "jpg", "jpeg", "gif", "heic", "webp", "pdf", "txt", "log", "json",
];

/// What a stored upload looks like on the wire.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UploadResponse {
    /// Absolute path of the stored file, ready to paste into a prompt.
    pub path: String,
    /// Size in bytes.
    pub bytes: u64,
    /// Lowercase hex SHA-256 of the contents.
    pub sha256: String,
}

/// Why an upload was refused.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum UploadError {
    /// `X-OpenPaw-Filename` was absent or empty.
    #[error("missing {FILENAME_HEADER} header")]
    MissingFilename,
    /// The filename was a path, not a bare basename.
    #[error("filename must be a bare basename with no path separators")]
    NotABasename,
    /// The extension is absent or not allowlisted.
    #[error("unsupported file extension; allowed: {}", ALLOWED_EXTENSIONS.join(", "))]
    UnsupportedExtension,
    /// The body was empty.
    #[error("upload body is empty")]
    Empty,
    /// The body exceeded `max_upload_bytes`.
    #[error("upload is {bytes} bytes, over the {limit} byte limit")]
    TooLarge {
        /// Size received.
        bytes: usize,
        /// Configured cap.
        limit: u64,
    },
    /// The bytes could not be written.
    #[error("could not store the upload: {0}")]
    Write(String),
}

/// Validate a client filename and return its allowlisted extension.
///
/// The returned extension is lowercase; the client's stem is discarded entirely,
/// so a hostile name cannot influence the stored path at all.
pub fn extension_for(raw: &str) -> Result<String, UploadError> {
    let name = raw.trim();
    if name.is_empty() {
        return Err(UploadError::MissingFilename);
    }
    // Reject anything that is not exactly its own basename. One check catches
    // `../evil.png`, `/etc/evil.png`, `a/b.png`, `.` and `..`, including the
    // Windows-style separator a client might send.
    if name.contains('/')
        || name.contains('\\')
        || name.chars().any(|c| c.is_control())
        || Path::new(name).file_name().and_then(|n| n.to_str()) != Some(name)
    {
        return Err(UploadError::NotABasename);
    }

    let extension = Path::new(name)
        .extension()
        .and_then(|ext| ext.to_str())
        .map(str::to_ascii_lowercase)
        .ok_or(UploadError::UnsupportedExtension)?;
    if !ALLOWED_EXTENSIONS.contains(&extension.as_str()) {
        return Err(UploadError::UnsupportedExtension);
    }
    Ok(extension)
}

/// Store `body` under a fresh random stem inside `uploads_dir`.
///
/// Written through a temporary file and fsynced before the rename, so a reader
/// never observes a partial attachment, at mode 0600 like the rest of the state
/// directory.
pub async fn store(
    uploads_dir: &Path,
    filename: &str,
    body: &[u8],
    limit: u64,
) -> Result<UploadResponse, UploadError> {
    let extension = extension_for(filename)?;
    if body.is_empty() {
        return Err(UploadError::Empty);
    }
    if body.len() as u64 > limit {
        return Err(UploadError::TooLarge {
            bytes: body.len(),
            limit,
        });
    }

    let target: PathBuf = uploads_dir.join(format!("{}.{extension}", uuid::Uuid::new_v4()));
    let digest = sha256_hex(body);

    let bytes = body.to_vec();
    let path = target.clone();
    // The write plus fsync goes to a blocking thread so a slow disk cannot stall
    // the runtime while a request handler waits on it.
    tokio::task::spawn_blocking(move || crate::state::write_private_atomic(&path, &bytes))
        .await
        .map_err(|err| UploadError::Write(err.to_string()))?
        .map_err(|err| UploadError::Write(format!("{err:#}")))?;

    Ok(UploadResponse {
        path: target.to_string_lossy().into_owned(),
        bytes: body.len() as u64,
        sha256: digest,
    })
}

impl From<UploadError> for ApiError {
    fn from(err: UploadError) -> ApiError {
        match err {
            UploadError::TooLarge { .. } => ApiError::too_large(err.to_string()),
            UploadError::Write(message) => ApiError::internal(message),
            other => ApiError::bad_request(other.to_string()),
        }
    }
}

/// `POST /v1/uploads` — raw bytes in, stored path out.
pub async fn upload(
    State(app): State<AppState>,
    Extension(device): Extension<AuthedDevice>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<UploadResponse>, ApiError> {
    let filename = headers
        .get(FILENAME_HEADER)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_owned();

    match store(
        &app.store.uploads_dir(),
        &filename,
        &body,
        app.config.max_upload_bytes,
    )
    .await
    {
        Ok(response) => {
            app.audit
                .append(&AuditEntry::now(
                    &device.device_id,
                    "uploads.write",
                    &response.path,
                    format!("stored {} bytes", response.bytes),
                ))
                .await
                .map_err(ApiError::internal)?;
            Ok(Json(response))
        }
        Err(err) => {
            // A rejected upload is still an authenticated write attempt, and a
            // stream of them is exactly what an audit log should surface.
            let _ = app
                .audit
                .append(&AuditEntry::now(
                    &device.device_id,
                    "uploads.write",
                    &filename,
                    format!("rejected: {err}"),
                ))
                .await;
            Err(err.into())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn path_traversal_and_absolute_names_are_rejected() {
        for name in [
            "../evil.png",
            "../../etc/evil.png",
            "/etc/evil.png",
            "dir/shot.png",
            "dir\\shot.png",
            ".",
            "..",
        ] {
            assert_eq!(
                extension_for(name),
                Err(UploadError::NotABasename),
                "{name} must be refused"
            );
        }
    }

    #[test]
    fn only_allowlisted_extensions_pass() {
        assert_eq!(extension_for("shot.png").unwrap(), "png");
        assert_eq!(extension_for("SHOT.PNG").unwrap(), "png");
        assert_eq!(extension_for("trace.log").unwrap(), "log");
        for name in ["evil.sh", "archive.zip", "lib.dylib", "noext", ".env"] {
            assert_eq!(
                extension_for(name),
                Err(UploadError::UnsupportedExtension),
                "{name} must be refused"
            );
        }
    }

    #[test]
    fn empty_and_control_character_filenames_are_rejected() {
        assert_eq!(extension_for(""), Err(UploadError::MissingFilename));
        assert_eq!(extension_for("   "), Err(UploadError::MissingFilename));
        assert_eq!(extension_for("a\0b.png"), Err(UploadError::NotABasename));
        assert_eq!(extension_for("a\nb.png"), Err(UploadError::NotABasename));
    }

    #[tokio::test]
    async fn stored_uploads_get_a_random_stem_and_owner_only_mode() {
        let dir = tempfile::tempdir().unwrap();
        let first = store(dir.path(), "shot.png", b"pixels", 1024)
            .await
            .unwrap();
        let second = store(dir.path(), "shot.png", b"pixels", 1024)
            .await
            .unwrap();

        assert_ne!(first.path, second.path, "the client stem is never reused");
        assert!(first.path.ends_with(".png"));
        assert!(!first.path.contains("shot"));
        assert_eq!(first.bytes, 6);
        assert_eq!(first.sha256, sha256_hex(b"pixels"));
        assert_eq!(first.sha256, second.sha256);

        assert_eq!(std::fs::read(&first.path).unwrap(), b"pixels");
        assert_eq!(
            std::fs::metadata(&first.path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[tokio::test]
    async fn the_size_limit_is_enforced_and_empty_bodies_refused() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            store(dir.path(), "shot.png", &[0u8; 10], 4).await,
            Err(UploadError::TooLarge {
                bytes: 10,
                limit: 4
            })
        );
        assert_eq!(
            store(dir.path(), "shot.png", b"", 1024).await,
            Err(UploadError::Empty)
        );
        // Nothing was written for either rejection.
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
    }
}
