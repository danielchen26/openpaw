//! Name and content search inside a single root.

use walkdir::{DirEntry, WalkDir};

use crate::blob::{BINARY_PROBE_BYTES, looks_binary};
use crate::list::{EntryKind, TreeEntry};
use crate::path::relative_string;
use crate::{FileError, ResolvedRoot};

/// Directories that are never walked: build output and dependency caches drown
/// out real hits and cost seconds.
pub const PRUNED_DIRS: &[&str] = &[
    ".git",
    "node_modules",
    "target",
    ".build",
    "DerivedData",
    ".venv",
    "dist",
];

/// Files larger than this are skipped by content search.
pub const MAX_SEARCH_FILE_BYTES: u64 = 1024 * 1024;

/// Longest snippet returned for a single match.
const MAX_MATCH_TEXT: usize = 400;

/// One line that contains the query.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ContentMatch {
    /// Path relative to the searched root, `/`-separated.
    pub path: String,
    /// 1-based line number.
    pub line: u32,
    /// The matching line, trimmed of trailing whitespace and capped in length.
    pub text: String,
}

/// Find entries whose file name contains `query`, case-insensitively.
pub fn search_names(
    root: &ResolvedRoot,
    query: &str,
    limit: usize,
) -> Result<Vec<TreeEntry>, FileError> {
    let needle = query.to_lowercase();
    if needle.is_empty() || limit == 0 {
        return Ok(Vec::new());
    }
    if !root.path.is_dir() {
        return Err(FileError::NotADirectory);
    }

    let mut hits: Vec<TreeEntry> = Vec::new();
    for entry in walk(root) {
        if entry.depth() == 0 {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.to_lowercase().contains(&needle) {
            continue;
        }
        let file_type = entry.file_type();
        let is_symlink = file_type.is_symlink();
        let meta = entry.metadata().ok();
        let kind = if is_symlink {
            EntryKind::Symlink
        } else if file_type.is_dir() {
            EntryKind::Directory
        } else if file_type.is_file() {
            EntryKind::File
        } else {
            EntryKind::Other
        };
        let size = if kind == EntryKind::File {
            meta.as_ref().map(std::fs::Metadata::len)
        } else {
            None
        };
        hits.push(TreeEntry {
            name,
            path: relative_string(&root.path, entry.path()),
            kind,
            size,
            is_symlink,
        });
        if hits.len() >= limit {
            break;
        }
    }
    Ok(hits)
}

/// Literal, case-insensitive substring search over file contents.
///
/// No regular expressions: the query is matched verbatim, so user input can
/// never turn into a pathological pattern. Binary files, files above
/// [`MAX_SEARCH_FILE_BYTES`] and [`PRUNED_DIRS`] are skipped.
pub fn search_content(
    root: &ResolvedRoot,
    query: &str,
    limit: usize,
) -> Result<Vec<ContentMatch>, FileError> {
    let needle = query.to_lowercase();
    if needle.is_empty() || limit == 0 {
        return Ok(Vec::new());
    }
    if !root.path.is_dir() {
        return Err(FileError::NotADirectory);
    }

    let mut hits: Vec<ContentMatch> = Vec::new();
    'files: for entry in walk(root) {
        if entry.depth() == 0 || !entry.file_type().is_file() {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        if meta.len() > MAX_SEARCH_FILE_BYTES {
            continue;
        }
        let Ok(bytes) = std::fs::read(entry.path()) else {
            continue;
        };
        if looks_binary(&bytes[..bytes.len().min(BINARY_PROBE_BYTES)]) {
            continue;
        }
        let Ok(text) = String::from_utf8(bytes) else {
            continue;
        };
        let lowered = text.to_lowercase();
        let path = relative_string(&root.path, entry.path());
        for (index, (raw, lower)) in text.lines().zip(lowered.lines()).enumerate() {
            if !lower.contains(&needle) {
                continue;
            }
            hits.push(ContentMatch {
                path: path.clone(),
                line: u32::try_from(index + 1).unwrap_or(u32::MAX),
                text: snippet(raw),
            });
            if hits.len() >= limit {
                break 'files;
            }
        }
    }
    Ok(hits)
}

/// Deterministic, symlink-free walk that prunes noise directories.
fn walk(root: &ResolvedRoot) -> impl Iterator<Item = DirEntry> {
    WalkDir::new(&root.path)
        .follow_links(false)
        .sort_by_file_name()
        .into_iter()
        .filter_entry(keep)
        .filter_map(Result::ok)
}

fn keep(entry: &DirEntry) -> bool {
    if entry.depth() == 0 || !entry.file_type().is_dir() {
        return true;
    }
    let name = entry.file_name().to_string_lossy();
    !PRUNED_DIRS.contains(&name.as_ref())
}

/// Trim and cap a matching line without splitting a character.
fn snippet(line: &str) -> String {
    let trimmed = line.trim_end();
    match trimmed.char_indices().nth(MAX_MATCH_TEXT) {
        Some((at, _)) => trimmed[..at].to_owned(),
        None => trimmed.to_owned(),
    }
}
