//! Filesystem access boundary for the OpenPaw host.
//!
//! Nothing in OpenPaw touches the filesystem on behalf of a phone without going
//! through this crate. [`Roots`] is an ordered allowlist of canonicalized
//! directories; [`Roots::resolve`] is the only supported way to turn a client
//! string into a [`std::path::PathBuf`], and it refuses traversal, absolute
//! paths, NUL bytes, Windows drive prefixes and symlinks that leave the root.

mod blob;
mod list;
mod path;
mod search;

use std::collections::HashSet;
use std::path::PathBuf;

pub use blob::{
    BINARY_PROBE_BYTES, Blob, BlobContent, DEFAULT_MAX_BLOB_BYTES, ReadOptions, blob_from_bytes,
    looks_binary, read_blob,
};
pub use list::{DEFAULT_MAX_ENTRIES, EntryKind, ListOptions, TreeEntry, list_dir};
pub use path::sanitize_relative;
pub use search::{ContentMatch, MAX_SEARCH_FILE_BYTES, PRUNED_DIRS, search_content, search_names};

/// Everything that can go wrong behind the filesystem boundary.
#[derive(Debug, thiserror::Error)]
pub enum FileError {
    /// No allowlisted root carries the requested name.
    #[error("unknown root")]
    UnknownRoot,
    /// The request tried to leave its root: traversal, absolute path, NUL byte,
    /// drive prefix, or a symlink pointing outside.
    #[error("path escapes its allowlisted root")]
    Escape,
    /// The resolved path does not exist.
    #[error("path not found")]
    NotFound,
    /// A file was required but the path is a directory or a special file.
    #[error("path is not a regular file")]
    NotAFile,
    /// A directory was required but the path is not one.
    #[error("path is not a directory")]
    NotADirectory,
    /// The object is larger than the caller's byte budget and cannot be
    /// summarized as text.
    #[error("{bytes} bytes exceeds the {limit} byte limit")]
    TooLarge {
        /// Real size of the object.
        bytes: u64,
        /// Budget the caller supplied.
        limit: u64,
    },
    /// Underlying filesystem failure.
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

/// One canonicalized directory the host is allowed to read.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct ResolvedRoot {
    /// Stable, client-visible name: the final path component, de-duplicated.
    pub name: String,
    /// Absolute canonical path.
    pub path: PathBuf,
}

/// Ordered allowlist of readable roots.
#[derive(Debug, Clone, Default)]
pub struct Roots {
    roots: Vec<ResolvedRoot>,
}

impl Roots {
    /// Canonicalize each configured path and assign it a unique name.
    ///
    /// Paths that are not directories are rejected; a path that does not exist
    /// yields [`FileError::NotFound`]. Names collide when two roots share a final
    /// component, in which case the later one gains a `-2`, `-3`, ... suffix so
    /// that a client name always maps to exactly one directory.
    pub fn new(paths: impl IntoIterator<Item = PathBuf>) -> Result<Roots, FileError> {
        Self::with_names(paths.into_iter().map(|path| (None, path)))
    }

    /// Canonicalize paths and assign unique names, using an optional preferred
    /// client-visible base name before falling back to the final path component.
    pub fn with_names(
        paths: impl IntoIterator<Item = (Option<String>, PathBuf)>,
    ) -> Result<Roots, FileError> {
        let mut roots: Vec<ResolvedRoot> = Vec::new();
        let mut taken: HashSet<String> = HashSet::new();

        for (preferred, raw) in paths {
            let canonical = std::fs::canonicalize(&raw).map_err(|err| match err.kind() {
                std::io::ErrorKind::NotFound => FileError::NotFound,
                _ => FileError::Io(err),
            })?;
            if !canonical.is_dir() {
                return Err(FileError::NotADirectory);
            }
            if roots.iter().any(|root| root.path == canonical) {
                continue;
            }
            let base = preferred
                .filter(|name| !name.is_empty())
                .or_else(|| {
                    canonical
                        .file_name()
                        .map(|name| name.to_string_lossy().into_owned())
                        .filter(|name| !name.is_empty())
                })
                .unwrap_or_else(|| "root".to_owned());
            let mut name = base.clone();
            let mut suffix = 2usize;
            while !taken.insert(name.clone()) {
                name = format!("{base}-{suffix}");
                suffix += 1;
            }
            roots.push(ResolvedRoot {
                name,
                path: canonical,
            });
        }

        Ok(Roots { roots })
    }

    /// Look up a root by client-visible name.
    pub fn root(&self, name: &str) -> Option<&ResolvedRoot> {
        self.roots.iter().find(|root| root.name == name)
    }

    /// Client-visible names, in configuration order.
    pub fn names(&self) -> Vec<String> {
        self.roots.iter().map(|root| root.name.clone()).collect()
    }

    /// All roots, in configuration order.
    pub fn all(&self) -> &[ResolvedRoot] {
        &self.roots
    }

    /// Turn a `(root name, relative path)` pair from a client into a real path.
    ///
    /// This is the only sanctioned entry point: it sanitizes, joins,
    /// canonicalizes and re-checks containment.
    pub fn resolve(&self, root_name: &str, relative: &str) -> Result<PathBuf, FileError> {
        let root = self.root(root_name).ok_or(FileError::UnknownRoot)?;
        path::resolve_in(root, relative)
    }
}
