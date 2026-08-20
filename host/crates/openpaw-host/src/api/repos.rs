//! Repository routes: status, diffs, trees, blobs and search.
//!
//! Everything here is a thin adapter over `openpaw-git` and `openpaw-files`. Two
//! properties are enforced by those crates rather than restated here, on purpose:
//! a path can never escape an allowlisted root, and a ref must look like a ref.
//! Duplicating either check in the HTTP layer would create a second place for it
//! to drift.
//!
//! All of it is blocking work — `git` subprocesses and directory walks — so every
//! call goes through `spawn_blocking`.

use axum::Json;
use axum::extract::{Path as UrlPath, Query, State};
use openpaw_files::{Blob, ListOptions, ReadOptions, ResolvedRoot, TreeEntry};
use openpaw_git::{Diff, DiffMode, DiffRequest, RepoSummary, Status};
use serde::Deserialize;

use crate::AppState;
use crate::api::{ApiError, file_error, git_error};

/// Default cap on search results. Enough to be useful on a phone screen, small
/// enough that a one-character query cannot stream a whole monorepo.
const DEFAULT_SEARCH_LIMIT: usize = 200;
/// Hard cap, whatever the client asks for.
const MAX_SEARCH_LIMIT: usize = 1000;

/// `?ref=&path=` for tree and blob reads.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct RefQuery {
    /// Git ref. Empty or absent means `HEAD` for a blob, and the working tree for
    /// a directory listing.
    #[serde(rename = "ref")]
    pub reference: Option<String>,
    /// Path relative to the repository root.
    pub path: Option<String>,
}

/// `?path=&staged=&commit=&base=&head=` for diffs.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct DiffQuery {
    /// Restrict the diff to one path.
    pub path: Option<String>,
    /// Diff the index instead of the working tree.
    pub staged: Option<bool>,
    /// Diff a single commit against its parent.
    pub commit: Option<String>,
    /// Range start.
    pub base: Option<String>,
    /// Range end.
    pub head: Option<String>,
}

impl DiffQuery {
    /// Resolve the query into exactly one diff mode.
    ///
    /// Checked most-specific first so a client that sends both `commit` and
    /// `staged` gets a defined answer rather than an arbitrary one.
    fn mode(&self) -> DiffMode {
        if let Some(commit) = non_empty(&self.commit) {
            return DiffMode::Commit(commit.to_owned());
        }
        match (non_empty(&self.base), non_empty(&self.head)) {
            (Some(base), Some(head)) => DiffMode::Range {
                base: base.to_owned(),
                head: head.to_owned(),
            },
            _ if self.staged.unwrap_or(false) => DiffMode::Staged,
            _ => DiffMode::WorkingTree,
        }
    }
}

/// `?q=&path=&limit=` for search.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct SearchQuery {
    /// Literal, case-insensitive needle.
    pub q: Option<String>,
    /// Subdirectory to search under.
    pub path: Option<String>,
    /// Maximum matches to return.
    pub limit: Option<usize>,
}

fn non_empty(value: &Option<String>) -> Option<&str> {
    value.as_deref().map(str::trim).filter(|s| !s.is_empty())
}

/// `GET /v1/repos`.
pub async fn list(State(app): State<AppState>) -> Result<Json<Vec<RepoSummary>>, ApiError> {
    let roots = app.roots.clone();
    let summaries = tokio::task::spawn_blocking(move || openpaw_git::summaries(&roots)).await?;
    Ok(Json(summaries))
}

/// `GET /v1/repos/{repo}/status`.
pub async fn status(
    State(app): State<AppState>,
    UrlPath(repo): UrlPath<String>,
) -> Result<Json<Status>, ApiError> {
    let roots = app.roots.clone();
    let status = tokio::task::spawn_blocking(move || {
        openpaw_git::open_named(&roots, &repo).and_then(|repo| repo.status())
    })
    .await?
    .map_err(git_error)?;
    Ok(Json(status))
}

/// `GET /v1/repos/{repo}/diff`.
pub async fn diff(
    State(app): State<AppState>,
    UrlPath(repo): UrlPath<String>,
    Query(query): Query<DiffQuery>,
) -> Result<Json<Diff>, ApiError> {
    let roots = app.roots.clone();
    let request = DiffRequest {
        mode: query.mode(),
        path: non_empty(&query.path).map(str::to_owned),
    };
    let diff = tokio::task::spawn_blocking(move || {
        openpaw_git::open_named(&roots, &repo).and_then(|repo| repo.diff(&request))
    })
    .await?
    .map_err(git_error)?;
    Ok(Json(diff))
}

/// `GET /v1/repos/{repo}/tree`.
pub async fn tree(
    State(app): State<AppState>,
    UrlPath(repo): UrlPath<String>,
    Query(query): Query<RefQuery>,
) -> Result<Json<Vec<TreeEntry>>, ApiError> {
    let roots = app.roots.clone();
    let relative = non_empty(&query.path).unwrap_or_default().to_owned();

    match non_empty(&query.reference) {
        // A ref means "read it out of git history", which git itself resolves.
        Some(reference) => {
            let reference = reference.to_owned();
            let entries = tokio::task::spawn_blocking(move || {
                openpaw_git::open_named(&roots, &repo)
                    .and_then(|repo| repo.tree(&reference, &relative))
            })
            .await?
            .map_err(git_error)?;
            Ok(Json(entries))
        }
        // No ref means the working tree, including files git does not track yet —
        // which is usually exactly what you want to look at from a phone.
        None => {
            let entries = tokio::task::spawn_blocking(move || {
                let root = roots
                    .root(&repo)
                    .cloned()
                    .ok_or_else(|| unknown_root(&repo))?;
                openpaw_files::list_dir(&root, &relative, &ListOptions::default())
            })
            .await?
            .map_err(file_error)?;
            Ok(Json(entries))
        }
    }
}

/// `GET /v1/repos/{repo}/blob`.
pub async fn blob(
    State(app): State<AppState>,
    UrlPath(repo): UrlPath<String>,
    Query(query): Query<RefQuery>,
) -> Result<Json<Blob>, ApiError> {
    let roots = app.roots.clone();
    let max_bytes = app.config.max_blob_bytes;
    let relative = non_empty(&query.path)
        .ok_or_else(|| ApiError::bad_request("path is required"))?
        .to_owned();

    match non_empty(&query.reference) {
        Some(reference) => {
            let reference = reference.to_owned();
            let blob = tokio::task::spawn_blocking(move || {
                openpaw_git::open_named(&roots, &repo)
                    .and_then(|repo| repo.blob(&reference, &relative, max_bytes))
            })
            .await?
            .map_err(git_error)?;
            Ok(Json(blob))
        }
        None => {
            let blob = tokio::task::spawn_blocking(move || {
                let root = roots
                    .root(&repo)
                    .cloned()
                    .ok_or_else(|| unknown_root(&repo))?;
                openpaw_files::read_blob(&root, &relative, &ReadOptions { max_bytes })
            })
            .await?
            .map_err(file_error)?;
            Ok(Json(blob))
        }
    }
}

/// `GET /v1/repos/{repo}/search`.
///
/// Content search lives in `openpaw-files` rather than `git grep` so it also sees
/// files that are not committed yet — the ones you are most likely to be looking
/// for mid-session.
pub async fn search(
    State(app): State<AppState>,
    UrlPath(repo): UrlPath<String>,
    Query(query): Query<SearchQuery>,
) -> Result<Json<Vec<openpaw_files::ContentMatch>>, ApiError> {
    let needle = non_empty(&query.q)
        .ok_or_else(|| ApiError::bad_request("q is required"))?
        .to_owned();
    let limit = query
        .limit
        .unwrap_or(DEFAULT_SEARCH_LIMIT)
        .clamp(1, MAX_SEARCH_LIMIT);
    let relative = non_empty(&query.path).unwrap_or_default().to_owned();
    let roots = app.roots.clone();

    let hits = tokio::task::spawn_blocking(move || {
        let root = roots
            .root(&repo)
            .cloned()
            .ok_or_else(|| unknown_root(&repo))?;
        // Scope the walk to a subdirectory by resolving it as a root of its own.
        // `resolve` is what rejects an escape attempt, so the narrowed root is
        // guaranteed to still be inside the allowlisted one.
        let scope = if relative.is_empty() {
            root
        } else {
            ResolvedRoot {
                name: root.name.clone(),
                path: roots.resolve(&root.name, &relative)?,
            }
        };
        openpaw_files::search_content(&scope, &needle, limit)
    })
    .await?
    .map_err(file_error)?;
    Ok(Json(hits))
}

/// The error for a repository name that is not allowlisted.
///
/// `FileError::UnknownRoot` carries no name, which is the right shape: telling an
/// unauthorized-for-this-root caller *which* name they got wrong would confirm
/// what does exist. The name goes in the log line, not the response.
fn unknown_root(name: &str) -> openpaw_files::FileError {
    tracing::debug!(
        repo = name,
        "request for a repository root that is not allowlisted"
    );
    openpaw_files::FileError::UnknownRoot
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a query the way the extractor would hand it to us. Constructed
    /// directly rather than parsed from a string: the parsing belongs to axum, and
    /// the logic worth testing is [`DiffQuery::mode`].
    fn query(
        staged: Option<bool>,
        commit: Option<&str>,
        base: Option<&str>,
        head: Option<&str>,
    ) -> DiffQuery {
        DiffQuery {
            path: None,
            staged,
            commit: commit.map(str::to_owned),
            base: base.map(str::to_owned),
            head: head.map(str::to_owned),
        }
    }

    #[test]
    fn diff_modes_are_resolved_most_specific_first() {
        assert_eq!(query(None, None, None, None).mode(), DiffMode::WorkingTree);
        assert_eq!(query(Some(true), None, None, None).mode(), DiffMode::Staged);
        assert_eq!(
            query(Some(false), None, None, None).mode(),
            DiffMode::WorkingTree
        );
        assert_eq!(
            query(None, Some("abc123"), None, None).mode(),
            DiffMode::Commit("abc123".to_owned())
        );
        assert_eq!(
            query(None, None, Some("main"), Some("feature")).mode(),
            DiffMode::Range {
                base: "main".to_owned(),
                head: "feature".to_owned()
            }
        );

        // A commit wins over a range, and a range wins over `staged`.
        assert_eq!(
            query(Some(true), Some("abc"), Some("main"), Some("dev")).mode(),
            DiffMode::Commit("abc".to_owned())
        );
        assert_eq!(
            query(Some(true), None, Some("main"), Some("dev")).mode(),
            DiffMode::Range {
                base: "main".to_owned(),
                head: "dev".to_owned()
            }
        );

        // A half-specified range is not a range.
        assert_eq!(
            query(None, None, Some("main"), None).mode(),
            DiffMode::WorkingTree
        );
        assert_eq!(
            query(None, None, None, Some("dev")).mode(),
            DiffMode::WorkingTree
        );
    }

    #[test]
    fn blank_query_values_are_treated_as_absent() {
        // A client that sends `?commit=` or `?commit=%20` means "no commit".
        assert_eq!(
            query(None, Some(""), None, None).mode(),
            DiffMode::WorkingTree
        );
        assert_eq!(
            query(None, Some("  "), None, None).mode(),
            DiffMode::WorkingTree
        );
        assert_eq!(
            query(None, None, Some("main"), Some(" ")).mode(),
            DiffMode::WorkingTree,
            "a blank head does not make a range"
        );

        assert!(non_empty(&Some("  ".to_owned())).is_none());
        assert_eq!(non_empty(&Some(" x ".to_owned())), Some("x"));
        assert!(non_empty(&None).is_none());
    }
}
