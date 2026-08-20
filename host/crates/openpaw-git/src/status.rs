//! `git status --porcelain=v2 --branch -z` parsing.
//!
//! The serialized shape is the `GET /v1/repos/{repo}/status` body: `branch`,
//! `ahead`, `behind`, `staged`, `unstaged`, `untracked`, each entry
//! `{path, old_path, change}`.

use crate::{ChangeKind, GitError};

/// One changed path.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct StatusEntry {
    /// Path relative to the repository root.
    pub path: String,
    /// Source path for renames and copies.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub old_path: Option<String>,
    /// What happened to the file.
    pub change: ChangeKind,
}

impl StatusEntry {
    fn new(path: String, change: ChangeKind, old_path: Option<String>) -> StatusEntry {
        StatusEntry {
            path,
            old_path,
            change,
        }
    }
}

/// Working tree and branch state.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Status {
    /// Client-visible repository name.
    pub name: String,
    /// Absolute path of the work tree.
    pub path: String,
    /// Branch name, or the abbreviated commit when HEAD is detached. Never
    /// empty and never null, so clients can render it unconditionally.
    pub branch: String,
    /// Upstream tracking ref, when configured.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub upstream: Option<String>,
    /// Commits on HEAD that the upstream lacks.
    pub ahead: u32,
    /// Commits on the upstream that HEAD lacks.
    pub behind: u32,
    /// True when `branch` holds a commit rather than a branch name.
    pub detached: bool,
    /// Staged changes.
    pub staged: Vec<StatusEntry>,
    /// Unstaged working-tree changes.
    pub unstaged: Vec<StatusEntry>,
    /// Untracked paths, reported as [`ChangeKind::Added`].
    pub untracked: Vec<StatusEntry>,
    /// Paths with merge conflicts. Conflicts have no single-sided change kind, so
    /// they are listed as plain paths.
    pub conflicted: Vec<String>,
}

impl Status {
    /// True when the work tree differs from HEAD in any way a user would call
    /// uncommitted work. Ignored files never count.
    pub fn is_dirty(&self) -> bool {
        !self.staged.is_empty()
            || !self.unstaged.is_empty()
            || !self.untracked.is_empty()
            || !self.conflicted.is_empty()
    }

    /// Parse the NUL-delimited porcelain v2 payload.
    pub fn parse(name: &str, path: &str, data: &[u8]) -> Result<Status, GitError> {
        let mut status = Status {
            name: name.to_owned(),
            path: path.to_owned(),
            branch: String::new(),
            upstream: None,
            ahead: 0,
            behind: 0,
            detached: false,
            staged: Vec::new(),
            unstaged: Vec::new(),
            untracked: Vec::new(),
            conflicted: Vec::new(),
        };
        let mut oid: Option<String> = None;

        let records: Vec<String> = data
            .split(|byte| *byte == 0)
            .filter(|record| !record.is_empty())
            .map(|record| String::from_utf8_lossy(record).into_owned())
            .collect();

        let mut at = 0usize;
        while at < records.len() {
            let record = records[at].as_str();
            at += 1;
            if let Some(rest) = record.strip_prefix("# branch.oid ") {
                if rest != "(initial)" {
                    oid = Some(rest.to_owned());
                }
            } else if let Some(rest) = record.strip_prefix("# branch.head ") {
                if rest == "(detached)" {
                    status.detached = true;
                } else {
                    status.branch = rest.to_owned();
                }
            } else if let Some(rest) = record.strip_prefix("# branch.upstream ") {
                status.upstream = Some(rest.to_owned());
            } else if let Some(rest) = record.strip_prefix("# branch.ab ") {
                let (ahead, behind) = parse_ahead_behind(rest)?;
                status.ahead = ahead;
                status.behind = behind;
            } else if record.starts_with("# ") {
                continue;
            } else if let Some(rest) = record.strip_prefix("1 ") {
                let (index, worktree, path) = parse_ordinary(rest)?;
                push_entry(&mut status, index, worktree, path, None)?;
            } else if let Some(rest) = record.strip_prefix("2 ") {
                let (index, worktree, path) = parse_renamed(rest)?;
                // With -z the original path is a separate NUL-delimited record.
                let original = records
                    .get(at)
                    .ok_or_else(|| GitError::Parse("rename entry without source path".to_owned()))?
                    .clone();
                at += 1;
                push_entry(&mut status, index, worktree, path, Some(original))?;
            } else if let Some(rest) = record.strip_prefix("u ") {
                status.conflicted.push(field(rest, 10)?);
            } else if let Some(rest) = record.strip_prefix("? ") {
                status
                    .untracked
                    .push(StatusEntry::new(rest.to_owned(), ChangeKind::Added, None));
            } else if record.starts_with("! ") {
                continue;
            } else {
                return Err(GitError::Parse(format!(
                    "unrecognized status record {record:?}"
                )));
            }
        }

        if status.detached || status.branch.is_empty() {
            status.detached = true;
            status.branch = match &oid {
                Some(oid) if oid.len() >= 7 => oid[..7].to_owned(),
                Some(oid) => oid.clone(),
                None => "(no commits)".to_owned(),
            };
        }

        Ok(status)
    }
}

/// Map a porcelain v2 status letter. `U` never appears here: unmerged paths are
/// their own record type.
fn change_from_code(code: char) -> Result<ChangeKind, GitError> {
    match code {
        'A' => Ok(ChangeKind::Added),
        'M' => Ok(ChangeKind::Modified),
        'D' => Ok(ChangeKind::Deleted),
        'R' => Ok(ChangeKind::Renamed),
        'C' => Ok(ChangeKind::Copied),
        'T' => Ok(ChangeKind::TypeChanged),
        other => Err(GitError::Parse(format!("unknown status code {other:?}"))),
    }
}

fn push_entry(
    status: &mut Status,
    index: char,
    worktree: char,
    path: String,
    original: Option<String>,
) -> Result<(), GitError> {
    if index != '.' {
        status.staged.push(StatusEntry::new(
            path.clone(),
            change_from_code(index)?,
            original.clone(),
        ));
    }
    if worktree != '.' {
        status.unstaged.push(StatusEntry::new(
            path,
            change_from_code(worktree)?,
            original,
        ));
    }
    Ok(())
}

/// `+2 -3` -> `(2, 3)`.
fn parse_ahead_behind(raw: &str) -> Result<(u32, u32), GitError> {
    let mut parts = raw.split(' ');
    let ahead = parts
        .next()
        .and_then(|value| value.strip_prefix('+'))
        .and_then(|value| value.parse().ok());
    let behind = parts
        .next()
        .and_then(|value| value.strip_prefix('-'))
        .and_then(|value| value.parse().ok());
    match (ahead, behind) {
        (Some(ahead), Some(behind)) => Ok((ahead, behind)),
        _ => Err(GitError::Parse(format!("bad branch.ab value {raw:?}"))),
    }
}

/// `<XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
fn parse_ordinary(rest: &str) -> Result<(char, char, String), GitError> {
    let (index, worktree) = status_pair(rest)?;
    Ok((index, worktree, field(rest, 8)?))
}

/// `<XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>`
fn parse_renamed(rest: &str) -> Result<(char, char, String), GitError> {
    let (index, worktree) = status_pair(rest)?;
    Ok((index, worktree, field(rest, 9)?))
}

fn status_pair(rest: &str) -> Result<(char, char), GitError> {
    let mut chars = rest.chars();
    match (chars.next(), chars.next()) {
        (Some(index), Some(worktree)) => Ok((index, worktree)),
        _ => Err(GitError::Parse(format!("bad status record {rest:?}"))),
    }
}

/// Return everything from the `count`-th space-separated field onwards, so paths
/// containing spaces survive intact.
fn field(rest: &str, count: usize) -> Result<String, GitError> {
    let mut remainder = rest;
    for _ in 1..count {
        match remainder.split_once(' ') {
            Some((_, tail)) => remainder = tail,
            None => return Err(GitError::Parse(format!("truncated status record {rest:?}"))),
        }
    }
    if remainder.is_empty() {
        return Err(GitError::Parse(format!("empty path in record {rest:?}")));
    }
    Ok(remainder.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn payload(records: &[&str]) -> Vec<u8> {
        let mut out = Vec::new();
        for record in records {
            out.extend_from_slice(record.as_bytes());
            out.push(0);
        }
        out
    }

    #[test]
    fn parses_branch_header_and_tracking() {
        let data = payload(&[
            "# branch.oid 1111111111111111111111111111111111111111",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -3",
        ]);
        let status = Status::parse("repo", "/tmp/repo", &data).expect("parse");
        assert_eq!(status.branch, "main");
        assert_eq!(status.upstream.as_deref(), Some("origin/main"));
        assert_eq!((status.ahead, status.behind), (2, 3));
        assert!(!status.detached);
        assert!(!status.is_dirty());
    }

    #[test]
    fn detached_head_reports_the_short_commit() {
        let data = payload(&[
            "# branch.oid abcdef1234567890abcdef1234567890abcdef12",
            "# branch.head (detached)",
        ]);
        let status = Status::parse("repo", "/tmp/repo", &data).expect("parse");
        assert!(status.detached);
        assert_eq!(status.branch, "abcdef1");
    }

    #[test]
    fn empty_repository_still_has_a_branch_string() {
        let data = payload(&["# branch.oid (initial)", "# branch.head main"]);
        let status = Status::parse("repo", "/tmp/repo", &data).expect("parse");
        assert_eq!(status.branch, "main");
        assert!(!status.detached);
    }

    #[test]
    fn paths_with_spaces_survive() {
        let data = payload(&[
            "# branch.head main",
            "1 M. N... 100644 100644 100644 aaaa bbbb my notes.txt",
            "? un tracked.txt",
        ]);
        let status = Status::parse("repo", "/tmp/repo", &data).expect("parse");
        assert_eq!(status.staged[0].path, "my notes.txt");
        assert_eq!(status.untracked[0].path, "un tracked.txt");
        assert_eq!(status.untracked[0].change, ChangeKind::Added);
    }

    #[test]
    fn rename_pulls_the_source_from_the_next_record() {
        let data = payload(&[
            "# branch.head main",
            "2 R. N... 100644 100644 100644 aaaa bbbb R100 new/name.txt",
            "old/name.txt",
            "1 .M N... 100644 100644 100644 cccc dddd other.txt",
        ]);
        let status = Status::parse("repo", "/tmp/repo", &data).expect("parse");
        assert_eq!(status.staged.len(), 1);
        assert_eq!(status.staged[0].change, ChangeKind::Renamed);
        assert_eq!(status.staged[0].path, "new/name.txt");
        assert_eq!(status.staged[0].old_path.as_deref(), Some("old/name.txt"));
        assert_eq!(status.unstaged.len(), 1);
        assert_eq!(status.unstaged[0].path, "other.txt");
        assert_eq!(status.unstaged[0].change, ChangeKind::Modified);
    }

    #[test]
    fn unmerged_records_are_conflicts() {
        let data = payload(&[
            "# branch.head main",
            "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc both.txt",
        ]);
        let status = Status::parse("repo", "/tmp/repo", &data).expect("parse");
        assert_eq!(status.conflicted, vec!["both.txt"]);
        assert!(status.is_dirty());
    }

    #[test]
    fn ignored_records_do_not_make_a_repo_dirty() {
        let data = payload(&["# branch.head main", "! build/output.o"]);
        let status = Status::parse("repo", "/tmp/repo", &data).expect("parse");
        assert!(!status.is_dirty());
    }

    #[test]
    fn garbage_is_reported_not_swallowed() {
        let data = payload(&["9 what is this"]);
        let err = Status::parse("repo", "/tmp/repo", &data).expect_err("must fail");
        assert!(matches!(err, GitError::Parse(_)), "got {err:?}");
    }

    #[test]
    fn json_matches_the_status_route_shape() {
        let data = payload(&[
            "# branch.oid 1111111111111111111111111111111111111111",
            "# branch.head main",
            "# branch.ab +1 -0",
            "2 R. N... 100644 100644 100644 aaaa bbbb R100 new.txt",
            "old.txt",
            "? fresh.txt",
        ]);
        let status = Status::parse("repo", "/tmp/repo", &data).expect("parse");
        let json = serde_json::to_value(&status).expect("json");
        assert_eq!(json["branch"], "main");
        assert_eq!(json["ahead"], 1);
        assert_eq!(json["behind"], 0);
        assert_eq!(json["staged"][0]["path"], "new.txt");
        assert_eq!(json["staged"][0]["old_path"], "old.txt");
        assert_eq!(json["staged"][0]["change"], "renamed");
        assert_eq!(json["untracked"][0]["path"], "fresh.txt");
        assert_eq!(json["untracked"][0]["change"], "added");
        assert!(
            json["untracked"][0].get("old_path").is_none(),
            "absent old_path must be omitted, not null"
        );
    }
}
