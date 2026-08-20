//! Directory listing.

use std::fs::Metadata;
use std::path::Path;

use crate::path::{contains, relative_string, resolve_in};
use crate::{FileError, ResolvedRoot};

/// Default cap on entries returned for one directory.
pub const DEFAULT_MAX_ENTRIES: usize = 2000;

/// What a tree entry is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryKind {
    /// Regular file.
    File,
    /// Directory.
    Directory,
    /// Symlink that is broken or points outside the root, and therefore cannot
    /// be classified any further.
    Symlink,
    /// Submodule, socket, device, fifo: present but not readable as content.
    Other,
}

/// One entry in a directory or git tree listing.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct TreeEntry {
    /// Final path component.
    pub name: String,
    /// Path relative to the root, `/`-separated.
    pub path: String,
    /// Classification, following symlinks only while they stay inside the root.
    pub kind: EntryKind,
    /// Size in bytes for regular files.
    pub size: Option<u64>,
    /// True when the entry itself is a symlink, regardless of `kind`.
    pub is_symlink: bool,
}

/// Listing limits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ListOptions {
    /// Cap on returned entries; the listing is sorted before it is cut, so the
    /// prefix is stable.
    pub max_entries: usize,
    /// Include dot-files.
    pub include_hidden: bool,
}

impl Default for ListOptions {
    fn default() -> Self {
        ListOptions {
            max_entries: DEFAULT_MAX_ENTRIES,
            include_hidden: false,
        }
    }
}

/// List one directory inside `root`.
///
/// Entries are sorted directories-first then by name, so `max_entries` yields a
/// deterministic prefix. Symlinks are reported but never resolved past the root
/// boundary.
pub fn list_dir(
    root: &ResolvedRoot,
    relative: &str,
    opts: &ListOptions,
) -> Result<Vec<TreeEntry>, FileError> {
    let resolved = resolve_in(root, relative)?;
    if !std::fs::metadata(&resolved)?.is_dir() {
        return Err(FileError::NotADirectory);
    }

    let mut entries: Vec<TreeEntry> = Vec::new();
    for entry in std::fs::read_dir(&resolved)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if !opts.include_hidden && name.starts_with('.') {
            continue;
        }
        let path = entry.path();
        let link_meta = std::fs::symlink_metadata(&path)?;
        let is_symlink = link_meta.file_type().is_symlink();
        let (kind, size) = if is_symlink {
            classify_symlink(&root.path, &path)
        } else {
            classify(&link_meta)
        };
        entries.push(TreeEntry {
            name,
            path: relative_string(&root.path, &path),
            kind,
            size,
            is_symlink,
        });
    }

    entries.sort_by(|left, right| {
        let by_kind =
            (left.kind != EntryKind::Directory).cmp(&(right.kind != EntryKind::Directory));
        by_kind.then_with(|| left.name.cmp(&right.name))
    });
    entries.truncate(opts.max_entries);
    Ok(entries)
}

/// Classify a symlink by its target, but only when the target stays inside the
/// root. Anything else stays [`EntryKind::Symlink`] with no size, which is how an
/// escaping link is surfaced without ever being followed.
fn classify_symlink(root: &Path, path: &Path) -> (EntryKind, Option<u64>) {
    match std::fs::canonicalize(path) {
        Ok(target) if contains(root, &target) => match std::fs::metadata(path) {
            Ok(meta) => classify(&meta),
            Err(_) => (EntryKind::Symlink, None),
        },
        _ => (EntryKind::Symlink, None),
    }
}

fn classify(meta: &Metadata) -> (EntryKind, Option<u64>) {
    if meta.is_dir() {
        (EntryKind::Directory, None)
    } else if meta.is_file() {
        (EntryKind::File, Some(meta.len()))
    } else {
        (EntryKind::Other, None)
    }
}
