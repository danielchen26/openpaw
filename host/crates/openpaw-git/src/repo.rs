//! The `git` invocation layer: one hardened `Command` builder and the read-only
//! operations built on it.

use std::io::Read;
use std::process::{Command, Output, Stdio};

use openpaw_files::{
    BINARY_PROBE_BYTES, Blob, FileError, ReadOptions, ResolvedRoot, TreeEntry, blob_from_bytes,
    looks_binary,
};
use time::OffsetDateTime;

use crate::patch::Diff;
use crate::status::Status;
use crate::tree::parse_ls_tree;
use crate::{Commit, DiffMode, DiffRequest, GitError, RepoSummary, UNIT_SEPARATOR, validate_rev};

/// An open, read-only handle on one work tree.
#[derive(Debug, Clone)]
pub struct Repo {
    root: ResolvedRoot,
}

impl Repo {
    /// Open `root` as a repository.
    ///
    /// The root must be the *top level* of the work tree, so that every path git
    /// reports back is also a valid path inside the allowlisted root.
    pub fn open(root: ResolvedRoot) -> Result<Repo, GitError> {
        let repo = Repo { root };
        let toplevel = match repo.run(&["rev-parse", "--show-toplevel"]) {
            Ok(stdout) => String::from_utf8_lossy(&stdout).trim().to_owned(),
            Err(GitError::Command { .. } | GitError::NotFound) => {
                return Err(GitError::NotARepository);
            }
            Err(other) => return Err(other),
        };
        if toplevel.is_empty() {
            return Err(GitError::NotARepository);
        }
        let canonical = std::fs::canonicalize(&toplevel).map_err(GitError::Io)?;
        if canonical != repo.root.path {
            return Err(GitError::NotARepository);
        }
        Ok(repo)
    }

    /// The allowlisted root this repository was opened from.
    pub fn root(&self) -> &ResolvedRoot {
        &self.root
    }

    /// Branch, tracking distance and dirtiness in one `git status` call.
    pub fn summary(&self) -> Result<RepoSummary, GitError> {
        let status = self.status()?;
        Ok(RepoSummary {
            name: status.name.clone(),
            path: status.path.clone(),
            branch: if status.detached {
                None
            } else {
                Some(status.branch.clone())
            },
            dirty: status.is_dirty(),
            ahead: status.ahead,
            behind: status.behind,
        })
    }

    /// Full working tree status.
    pub fn status(&self) -> Result<Status, GitError> {
        let stdout = self.run(&[
            "status",
            "--porcelain=v2",
            "--branch",
            "-z",
            "--untracked-files=normal",
        ])?;
        Status::parse(&self.root.name, &self.root.path.to_string_lossy(), &stdout)
    }

    /// Diff two sides of the repository.
    pub fn diff(&self, req: &DiffRequest) -> Result<Diff, GitError> {
        let mut args: Vec<String> = Vec::new();
        match &req.mode {
            DiffMode::WorkingTree => args.push("diff".to_owned()),
            DiffMode::Staged => {
                args.push("diff".to_owned());
                args.push("--cached".to_owned());
            }
            DiffMode::Commit(rev) => {
                let rev = validate_rev(rev)?;
                args.push("show".to_owned());
                args.push("--format=".to_owned());
                args.push("--first-parent".to_owned());
                args.push(rev.to_owned());
            }
            DiffMode::Range { base, head } => {
                let base = validate_rev(base)?;
                let head = validate_rev(head)?;
                args.push("diff".to_owned());
                args.push(base.to_owned());
                args.push(head.to_owned());
            }
        }
        args.extend(
            [
                "--patch",
                "--no-color",
                "--no-ext-diff",
                "--no-textconv",
                "--find-renames",
                "--find-copies",
                "--unified=3",
            ]
            .into_iter()
            .map(str::to_owned),
        );

        // The path filter always lands after `--`, and only after the same
        // sanitation an HTTP file read would get.
        args.push("--".to_owned());
        if let Some(path) = &req.path {
            let spec = relative_spec(path)?;
            if !spec.is_empty() {
                args.push(spec);
            }
        }

        let borrowed: Vec<&str> = args.iter().map(String::as_str).collect();
        let stdout = self.run(&borrowed)?;
        Ok(Diff::parse(&String::from_utf8_lossy(&stdout)))
    }

    /// List one directory of a tree-ish, non-recursively.
    pub fn tree(&self, r#ref: &str, relative: &str) -> Result<Vec<TreeEntry>, GitError> {
        let rev = rev_or_head(r#ref)?;
        let spec = relative_spec(relative)?;
        let entries = if spec.is_empty() {
            parse_ls_tree(&self.run(&["ls-tree", "-l", "-z", rev])?)?
        } else {
            // A trailing slash makes ls-tree list the directory's children
            // rather than the directory entry itself.
            let dir = format!("{spec}/");
            parse_ls_tree(&self.run(&["ls-tree", "-l", "-z", rev, "--", &dir])?)?
        };

        if entries.is_empty() && !spec.is_empty() {
            // ls-tree is silent for "no such path", "that is a file" and "empty
            // directory" alike; ask what the object actually is.
            return match self.object_type(rev, &spec)? {
                ObjectType::Tree => Ok(entries),
                ObjectType::Blob => Err(GitError::Path(FileError::NotADirectory)),
                ObjectType::Other => Err(GitError::NotFound),
            };
        }
        Ok(entries)
    }

    /// Read one blob out of a tree-ish.
    ///
    /// Oversized *text* is cut and flagged; oversized binary is refused, exactly
    /// like [`openpaw_files::read_blob`].
    pub fn blob(&self, r#ref: &str, relative: &str, max_bytes: u64) -> Result<Blob, GitError> {
        let rev = rev_or_head(r#ref)?;
        let spec = relative_spec(relative)?;
        if spec.is_empty() {
            return Err(GitError::NotAFile);
        }
        if self.object_type(rev, &spec)? != ObjectType::Blob {
            return Err(GitError::NotAFile);
        }

        let object = format!("{rev}:{spec}");
        let size: u64 = String::from_utf8_lossy(&self.run(&["cat-file", "-s", &object])?)
            .trim()
            .parse()
            .map_err(|_| GitError::Parse("cat-file -s did not return a size".to_owned()))?;
        let opts = ReadOptions { max_bytes };

        if size <= max_bytes {
            let data = self.cat_blob(&object, None)?;
            let total = data.len() as u64;
            return Ok(blob_from_bytes(&spec, &data, total, &opts)?);
        }

        // Oversized: read only enough to classify, then either cut the text or
        // refuse the binary. The whole object is never held in memory.
        let cap = usize::try_from(max_bytes.max(BINARY_PROBE_BYTES as u64)).unwrap_or(usize::MAX);
        let prefix = self.cat_blob(&object, Some(cap))?;
        if looks_binary(&prefix[..prefix.len().min(BINARY_PROBE_BYTES)]) {
            return Err(GitError::Path(FileError::TooLarge {
                bytes: size,
                limit: max_bytes,
            }));
        }
        let keep = usize::try_from(max_bytes)
            .unwrap_or(usize::MAX)
            .min(prefix.len());
        Ok(blob_from_bytes(&spec, &prefix[..keep], size, &opts)?)
    }

    /// Most recent commits on HEAD, newest first. An empty repository yields an
    /// empty list rather than an error.
    pub fn log(&self, limit: usize) -> Result<Vec<Commit>, GitError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let count = format!("--max-count={limit}");
        let format = format!(
            "--format=%H{sep}%h{sep}%an{sep}%ae{sep}%aI{sep}%s",
            sep = UNIT_SEPARATOR
        );
        let out = self.output(&["log", "-z", &count, &format])?;
        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr);
            if stderr.contains("does not have any commits yet") {
                return Ok(Vec::new());
            }
            return Err(classify(&out));
        }

        let mut commits: Vec<Commit> = Vec::new();
        for record in out.stdout.split(|byte| *byte == 0) {
            if record.is_empty() {
                continue;
            }
            let record = String::from_utf8_lossy(record);
            let fields: Vec<&str> = record.split(UNIT_SEPARATOR).collect();
            let [
                oid,
                short_oid,
                author_name,
                author_email,
                authored_at,
                subject,
            ] = fields[..]
            else {
                return Err(GitError::Parse(format!("bad log record {record:?}")));
            };
            let authored_at =
                OffsetDateTime::parse(authored_at, &time::format_description::well_known::Rfc3339)
                    .map_err(|err| GitError::Parse(format!("bad commit timestamp: {err}")))?;
            commits.push(Commit {
                oid: oid.to_owned(),
                short_oid: short_oid.to_owned(),
                author_name: author_name.to_owned(),
                author_email: author_email.to_owned(),
                authored_at,
                subject: subject.to_owned(),
            });
        }
        Ok(commits)
    }

    fn object_type(&self, rev: &str, spec: &str) -> Result<ObjectType, GitError> {
        let object = format!("{rev}:{spec}");
        let out = self.output(&["cat-file", "-t", &object])?;
        if !out.status.success() {
            return Err(classify(&out));
        }
        Ok(match String::from_utf8_lossy(&out.stdout).trim() {
            "blob" => ObjectType::Blob,
            "tree" => ObjectType::Tree,
            _ => ObjectType::Other,
        })
    }

    /// Stream a blob's bytes, optionally stopping after `cap` bytes.
    fn cat_blob(&self, object: &str, cap: Option<usize>) -> Result<Vec<u8>, GitError> {
        let mut child = self
            .command(&["cat-file", "blob", object])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(GitError::GitMissing)?;
        let mut data: Vec<u8> = Vec::new();
        {
            let stdout = child
                .stdout
                .as_mut()
                .ok_or_else(|| GitError::Parse("cat-file produced no stdout".to_owned()))?;
            match cap {
                Some(cap) => {
                    let mut limited = stdout.take(cap as u64);
                    limited.read_to_end(&mut data).map_err(GitError::Io)?;
                }
                None => {
                    stdout.read_to_end(&mut data).map_err(GitError::Io)?;
                }
            }
        }
        let stopped_early = cap.is_some_and(|cap| data.len() >= cap);
        if stopped_early {
            // We will not drain the rest; do not let git block on a full pipe.
            let _ = child.kill();
        }
        let out = child.wait_with_output().map_err(GitError::Io)?;
        if !out.status.success() && !stopped_early {
            return Err(classify(&Output {
                status: out.status,
                stdout: Vec::new(),
                stderr: out.stderr,
            }));
        }
        Ok(data)
    }

    /// Build a hardened `git` invocation pinned to this work tree.
    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new("git");
        command
            .arg("-C")
            .arg(&self.root.path)
            .arg("--no-optional-locks")
            .args([
                // Paths must come back verbatim, prefixes must stay `a/` + `b/`,
                // and no user config may inject an external diff driver.
                "-c",
                "core.quotepath=false",
                "-c",
                "diff.noprefix=false",
                "-c",
                "diff.mnemonicprefix=false",
                "-c",
                "diff.relative=false",
                "-c",
                "diff.external=",
                "-c",
                "core.pager=cat",
            ])
            .args(args)
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_PAGER", "cat")
            .stdin(Stdio::null());
        command
    }

    fn output(&self, args: &[&str]) -> Result<Output, GitError> {
        self.command(args).output().map_err(GitError::GitMissing)
    }

    fn run(&self, args: &[&str]) -> Result<Vec<u8>, GitError> {
        let out = self.output(args)?;
        if !out.status.success() {
            return Err(classify(&out));
        }
        Ok(out.stdout)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ObjectType {
    Blob,
    Tree,
    Other,
}

/// Sanitize a client path into a repository-relative spec string.
fn relative_spec(relative: &str) -> Result<String, GitError> {
    let sanitized = openpaw_files::sanitize_relative(relative)?;
    Ok(sanitized.to_string_lossy().into_owned())
}

/// An empty `ref` means HEAD; anything else must survive validation.
pub(crate) fn rev_or_head(r#ref: &str) -> Result<&str, GitError> {
    if r#ref.is_empty() {
        return Ok("HEAD");
    }
    validate_rev(r#ref)
}

/// Turn a failed invocation into the most specific error we can justify.
fn classify(out: &Output) -> GitError {
    let stderr = String::from_utf8_lossy(&out.stderr).trim().to_owned();
    const MISSING: &[&str] = &[
        "Not a valid object name",
        "not a valid object name",
        "unknown revision",
        "bad revision",
        "does not exist",
        "exists on disk, but not in",
        "no such path",
        "ambiguous argument",
        "does not have any commits yet",
    ];
    if MISSING.iter().any(|marker| stderr.contains(marker)) {
        return GitError::NotFound;
    }
    GitError::Command {
        code: out.status.code(),
        stderr,
    }
}
