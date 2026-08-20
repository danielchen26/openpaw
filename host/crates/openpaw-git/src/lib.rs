//! Read-only git inspection for the OpenPaw host.
//!
//! Every call shells out to the `git` binary — no libgit2, no in-process object
//! database. Invocations are pinned to an allowlisted work tree with `-C`, run
//! with `--no-optional-locks` so a phone poll can never fight a local `git`
//! process for the index lock, and never inherit a terminal: `GIT_TERMINAL_PROMPT=0`
//! makes a credential prompt fail instead of hang.
//!
//! Two rules keep client input out of git's argument parser: revisions must match
//! `^[A-Za-z0-9._/@^~{}-]{1,200}$` and may not start with `-`, and paths go
//! through [`openpaw_files::sanitize_relative`] and are always passed after `--`.
//!
//! Nothing here writes: there is no commit, no checkout, no fetch. The phone can
//! look at a repository, never move it.

mod patch;
mod repo;
mod status;
mod tree;

use openpaw_files::{FileError, Roots};
use time::OffsetDateTime;

pub use openpaw_files::{Blob, BlobContent, EntryKind, TreeEntry};
pub use patch::{ChangeKind, Diff, DiffLine, FileDiff, Hunk, LineKind};
pub use repo::Repo;
pub use status::{Status, StatusEntry};

/// Maximum accepted revision length.
pub const MAX_REV_LEN: usize = 200;

/// Field separator used inside `--format` output.
pub(crate) const UNIT_SEPARATOR: char = '\u{1f}';

/// Everything that can go wrong while inspecting a repository.
#[derive(Debug, thiserror::Error)]
pub enum GitError {
    /// The root is not the top level of a git work tree.
    #[error("not a git work tree")]
    NotARepository,
    /// A revision failed validation and never reached git.
    #[error("invalid git revision: {0:?}")]
    InvalidRef(String),
    /// A path was rejected by the filesystem boundary, or a blob exceeded its
    /// byte budget.
    #[error("{0}")]
    Path(#[from] FileError),
    /// The requested object, path or revision does not exist.
    #[error("object not found")]
    NotFound,
    /// The object exists but is not a blob.
    #[error("object is not a file")]
    NotAFile,
    /// git ran and failed.
    #[error("git failed ({code:?}): {stderr}")]
    Command {
        /// Process exit code, absent when killed by a signal.
        code: Option<i32>,
        /// Trimmed stderr.
        stderr: String,
    },
    /// git could not be started at all.
    #[error("could not run git: {0}")]
    GitMissing(std::io::Error),
    /// Failure while reading git's output.
    #[error("io error: {0}")]
    Io(std::io::Error),
    /// git produced output this crate could not parse.
    #[error("could not parse git output: {0}")]
    Parse(String),
}

/// Compact repository state for a list view.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct RepoSummary {
    /// Client-visible repository name.
    pub name: String,
    /// Absolute path of the work tree.
    pub path: String,
    /// Current branch, `None` when HEAD is detached.
    pub branch: Option<String>,
    /// True when there is uncommitted or untracked work.
    pub dirty: bool,
    /// Commits ahead of upstream.
    pub ahead: u32,
    /// Commits behind upstream.
    pub behind: u32,
}

/// One commit from `git log`.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Commit {
    /// Full object id.
    pub oid: String,
    /// Abbreviated object id.
    pub short_oid: String,
    /// Author name.
    pub author_name: String,
    /// Author email.
    pub author_email: String,
    /// Author timestamp.
    #[serde(with = "time::serde::rfc3339")]
    pub authored_at: OffsetDateTime,
    /// First line of the commit message.
    pub subject: String,
}

/// Which two sides to diff.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiffMode {
    /// Unstaged changes: work tree against the index.
    WorkingTree,
    /// Staged changes: index against HEAD.
    Staged,
    /// The change one commit introduced, against its first parent.
    Commit(String),
    /// Two endpoints.
    Range {
        /// Old side.
        base: String,
        /// New side.
        head: String,
    },
}

/// A diff request, optionally narrowed to one path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffRequest {
    /// Which sides to compare.
    pub mode: DiffMode,
    /// Repository-relative path filter; raw client input, sanitized on the way in.
    pub path: Option<String>,
}

/// Summaries for every allowlisted root that is a git work tree.
///
/// Roots that are not repositories, or that point inside a repository rather than
/// at its top level, are skipped rather than reported as errors: the allowlist
/// legitimately contains plain directories too.
pub fn summaries(roots: &Roots) -> Vec<RepoSummary> {
    roots
        .all()
        .iter()
        .filter_map(|root| Repo::open(root.clone()).ok()?.summary().ok())
        .collect()
}

/// Open the repository registered under `name`.
pub fn open_named(roots: &Roots, name: &str) -> Result<Repo, GitError> {
    let root = roots.root(name).ok_or(FileError::UnknownRoot)?;
    Repo::open(root.clone())
}

/// Validate a client-supplied revision.
///
/// The character set excludes `:` and whitespace, so a revision can never be
/// spliced into a `rev:path` object spec, and a leading `-` is refused so a
/// revision can never be read as an option such as `--upload-pack=evil`.
pub fn validate_rev(rev: &str) -> Result<&str, GitError> {
    let invalid = rev.is_empty()
        || rev.len() > MAX_REV_LEN
        || rev.starts_with('-')
        || !rev.bytes().all(is_rev_byte);
    if invalid {
        return Err(GitError::InvalidRef(rev.to_owned()));
    }
    Ok(rev)
}

fn is_rev_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || b"._/@^~{}-".contains(&byte)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn revisions_are_validated_before_they_reach_git() {
        for good in [
            "HEAD",
            "main",
            "refs/heads/feature/x",
            "v1.2.3",
            "HEAD~2",
            "HEAD^",
            "HEAD@{1}",
            "0123456789abcdef",
        ] {
            assert!(validate_rev(good).is_ok(), "{good} should be accepted");
        }
        for bad in [
            "",
            "--upload-pack=evil",
            "-f",
            "HEAD:../../etc/passwd",
            "main; rm -rf /",
            "main branch",
            "$(whoami)",
            "head\nmain",
            "a\0b",
            "HEAD:file",
            "--output=/tmp/pwned",
        ] {
            assert!(
                matches!(validate_rev(bad), Err(GitError::InvalidRef(_))),
                "{bad:?} should be rejected"
            );
        }
        let long = "a".repeat(MAX_REV_LEN + 1);
        assert!(matches!(validate_rev(&long), Err(GitError::InvalidRef(_))));
        assert!(validate_rev(&"a".repeat(MAX_REV_LEN)).is_ok());
    }

    #[test]
    fn empty_ref_means_head() {
        assert_eq!(repo::rev_or_head("").expect("head"), "HEAD");
        assert_eq!(repo::rev_or_head("main").expect("main"), "main");
        assert!(repo::rev_or_head("-f").is_err());
    }
}
