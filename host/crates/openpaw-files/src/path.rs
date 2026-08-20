//! Relative-path sanitation and root containment.
//!
//! Every client-supplied path string in OpenPaw goes through [`sanitize_relative`]
//! before it is joined onto a root, and through [`resolve_in`] before it reaches the
//! filesystem. Nothing else is allowed to build a path from network input.

use std::path::{Path, PathBuf};

use percent_encoding::percent_decode_str;

use crate::{FileError, ResolvedRoot};

/// Decode and validate a client-supplied relative path.
///
/// The input is percent-decoded first, so `%2e%2e%2f` is rejected exactly like
/// `../`. Absolute paths, `..` components, NUL bytes and Windows drive/UNC
/// prefixes are refused with [`FileError::Escape`]. The result is a relative
/// path with `.` and empty components removed; it is *not* canonicalized and the
/// target need not exist, which is what makes it usable for git revisions where
/// the path only exists inside a tree object.
pub fn sanitize_relative(relative: &str) -> Result<PathBuf, FileError> {
    let decoded = percent_decode_str(relative)
        .decode_utf8()
        .map_err(|_| FileError::Escape)?;
    let raw: &str = decoded.as_ref();

    if raw.contains('\0') {
        return Err(FileError::Escape);
    }
    if raw.starts_with('/') || raw.starts_with('\\') {
        return Err(FileError::Escape);
    }
    if has_drive_prefix(raw) {
        return Err(FileError::Escape);
    }

    let mut out = PathBuf::new();
    for part in raw.split(['/', '\\']) {
        match part {
            "" | "." => continue,
            ".." => return Err(FileError::Escape),
            part => out.push(part),
        }
    }
    Ok(out)
}

/// `C:` / `c:\` style prefixes, plus the `\\?\` and `\\server` UNC forms.
fn has_drive_prefix(raw: &str) -> bool {
    let bytes = raw.as_bytes();
    if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        return true;
    }
    raw.starts_with("\\\\")
}

/// Sanitize `relative`, join it onto `root` and canonicalize the result,
/// verifying component-wise that the real path is still inside the root.
///
/// Because canonicalization resolves symlinks, a symlink whose target lives
/// outside the root fails containment and is reported as [`FileError::Escape`]:
/// the link can be *listed* but never read through.
pub fn resolve_in(root: &ResolvedRoot, relative: &str) -> Result<PathBuf, FileError> {
    let sanitized = sanitize_relative(relative)?;
    let joined = root.path.join(&sanitized);
    let canonical = std::fs::canonicalize(&joined).map_err(|err| match err.kind() {
        std::io::ErrorKind::NotFound => FileError::NotFound,
        _ => FileError::Io(err),
    })?;
    if !contains(&root.path, &canonical) {
        return Err(FileError::Escape);
    }
    Ok(canonical)
}

/// Component-wise containment. Never a string prefix test: `/tmp/rootx` must not
/// count as living inside `/tmp/root`.
pub(crate) fn contains(root: &Path, candidate: &Path) -> bool {
    candidate == root || candidate.starts_with(root)
}

/// Render `path` as a `/`-separated string relative to `root`.
///
/// Non-UTF-8 components are lossily converted; the value is display/transport
/// only and is never fed back into the filesystem.
pub(crate) fn relative_string(root: &Path, path: &Path) -> String {
    let tail = path.strip_prefix(root).unwrap_or(path);
    let mut out = String::new();
    for component in tail.components() {
        if !out.is_empty() {
            out.push('/');
        }
        out.push_str(&component.as_os_str().to_string_lossy());
    }
    out
}
