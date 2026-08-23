use std::fmt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use crate::{GitError, validate_rev};

const MAX_GIT_OUTPUT_BYTES: usize = 64 * 1024;

#[derive(Clone, Default)]
pub struct CancellationToken(Arc<AtomicBool>);

impl CancellationToken {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct HttpsRemoteUrl(String);

impl HttpsRemoteUrl {
    pub fn parse(input: &str) -> Result<Self, GitError> {
        validate_https_url(input)?;
        Ok(Self(input.to_owned()))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for HttpsRemoteUrl {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("[redacted https git remote]")
    }
}

impl fmt::Debug for HttpsRemoteUrl {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("HttpsRemoteUrl([redacted])")
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloneRef(String);
impl CloneRef {
    pub fn parse(input: &str) -> Result<Self, GitError> {
        Ok(Self(validate_rev(input)?.to_owned()))
    }
    fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LfsSmudgePolicy {
    Allow,
    Disable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CloneBytePolicy {
    pub max_git_output_bytes: usize,
}
impl Default for CloneBytePolicy {
    fn default() -> Self {
        Self {
            max_git_output_bytes: MAX_GIT_OUTPUT_BYTES,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrustedCloneDestination {
    path: PathBuf,
    parent: PathBuf,
}
impl TrustedCloneDestination {
    pub fn new(path: impl Into<PathBuf>) -> Result<Self, GitError> {
        let path = path.into();
        if path.as_os_str().is_empty() {
            return Err(GitError::InvalidDestination("empty destination".into()));
        }
        if path.exists() {
            return Err(GitError::InvalidDestination(
                "destination already exists".into(),
            ));
        }
        let parent = path
            .parent()
            .ok_or_else(|| GitError::InvalidDestination("destination has no parent".into()))?;
        let parent = std::fs::canonicalize(parent).map_err(GitError::Io)?;
        if std::fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(GitError::InvalidDestination(
                "destination is a symlink".into(),
            ));
        }
        Ok(Self { path, parent })
    }
    pub fn path(&self) -> &Path {
        &self.path
    }
    fn assert_no_escape(&self) -> Result<(), GitError> {
        if self.path.exists() {
            let real = std::fs::canonicalize(&self.path).map_err(GitError::Io)?;
            if !real.starts_with(&self.parent) {
                return Err(GitError::InvalidDestination(
                    "destination escaped parent".into(),
                ));
            }
        }
        Ok(())
    }
}

pub struct CloneRequest {
    pub remote: HttpsRemoteUrl,
    pub destination: TrustedCloneDestination,
    pub r#ref: Option<CloneRef>,
    pub timeout: Duration,
    pub byte_policy: CloneBytePolicy,
    pub cancellation: CancellationToken,
    pub lfs_smudge: LfsSmudgePolicy,
}

pub fn clone_repo(req: CloneRequest) -> Result<(), GitError> {
    clone_with_git_program(req, "git")
}

fn clone_with_git_program(
    req: CloneRequest,
    git_program: impl AsRef<Path>,
) -> Result<(), GitError> {
    if req.cancellation.is_cancelled() {
        return Err(GitError::Cancelled);
    }
    let mut args = vec![
        "-c",
        "protocol.allow=never",
        "-c",
        "protocol.https.allow=always",
        "-c",
        "protocol.file.allow=never",
        "-c",
        "protocol.ext.allow=never",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.fsmonitor=false",
        "clone",
        "--no-local",
        "--template=",
        "--",
        req.remote.as_str(),
    ];
    let dest = req.destination.path.to_string_lossy().into_owned();
    args.push(&dest);
    if let Some(r) = &req.r#ref {
        args.splice(14..14, ["--branch", r.as_str()]);
    }

    let mut cmd = Command::new(git_program.as_ref());
    cmd.args(args)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_ASKPASS", "true")
        .env("GIT_PAGER", "cat")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .env("GIT_ALLOW_PROTOCOL", "https")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if matches!(req.lfs_smudge, LfsSmudgePolicy::Disable) {
        cmd.env("GIT_LFS_SKIP_SMUDGE", "1");
    }
    set_process_group(&mut cmd);
    let mut child = cmd.spawn().map_err(GitError::GitMissing)?;
    let pid = child.id();
    let start = Instant::now();
    loop {
        if req.cancellation.is_cancelled() {
            kill_group(pid);
            let _ = child.wait();
            return Err(GitError::Cancelled);
        }
        if start.elapsed() >= req.timeout {
            kill_group(pid);
            let _ = child.wait();
            return Err(GitError::Timeout);
        }
        if let Some(status) = child.try_wait().map_err(GitError::Io)? {
            let out = child.wait_with_output().map_err(GitError::Io)?;
            if out.stdout.len() + out.stderr.len() > req.byte_policy.max_git_output_bytes {
                return Err(GitError::OutputLimit);
            }
            req.destination.assert_no_escape()?;
            if status.success() {
                return Ok(());
            }
            return Err(GitError::Command {
                code: status.code(),
                stderr: sanitize_stderr(&out.stderr),
            });
        }
        thread::sleep(Duration::from_millis(10));
    }
}

fn validate_https_url(input: &str) -> Result<(), GitError> {
    if input.bytes().any(|b| b.is_ascii_control() || b == b'\\') {
        return Err(GitError::InvalidRemoteUrl);
    }
    let lower = input.to_ascii_lowercase();
    if lower.starts_with("file:")
        || lower.starts_with("ssh:")
        || lower.starts_with("ext:")
        || lower.starts_with("git:")
        || lower.contains("%3a")
        || lower.contains("%2f")
    {
        return Err(GitError::InvalidRemoteUrl);
    }
    let rest = input
        .strip_prefix("https://")
        .ok_or(GitError::InvalidRemoteUrl)?;
    let slash = rest.find('/').ok_or(GitError::InvalidRemoteUrl)?;
    let authority = &rest[..slash];
    let path = &rest[slash..];
    if authority.is_empty()
        || authority.contains('@')
        || authority.starts_with('.')
        || authority.ends_with('.')
    {
        return Err(GitError::InvalidRemoteUrl);
    }
    if !authority
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-' || b == b':')
    {
        return Err(GitError::InvalidRemoteUrl);
    }
    if path.len() < 2 || path.contains("//") {
        return Err(GitError::InvalidRemoteUrl);
    }
    Ok(())
}

fn sanitize_stderr(stderr: &[u8]) -> String {
    String::from_utf8_lossy(stderr)
        .chars()
        .take(4096)
        .collect::<String>()
        .replace("https://", "https://[redacted]@")
}

#[cfg(unix)]
fn set_process_group(cmd: &mut Command) {
    use std::os::unix::process::CommandExt;
    cmd.process_group(0);
}
#[cfg(not(unix))]
fn set_process_group(_cmd: &mut Command) {}
#[cfg(unix)]
fn kill_group(pid: u32) {
    let group = format!("-{}", pid);
    let _ = Command::new("/bin/kill").args(["-TERM", &group]).status();
    let _ = Command::new("/bin/kill")
        .args(["-TERM", &pid.to_string()])
        .status();
}
#[cfg(not(unix))]
fn kill_group(_pid: u32) {}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_unsafe_urls_and_refs() {
        assert!(HttpsRemoteUrl::parse("https://github.com/o/r.git").is_ok());
        for bad in [
            "file:///x",
            "ssh://host/x",
            "git@github.com:o/r",
            "ext::sh -c x",
            "/tmp/repo",
            "https:%2f%2fgithub.com/x",
            "https://user:pw@github.com/o/r",
        ] {
            assert!(HttpsRemoteUrl::parse(bad).is_err(), "{bad}");
        }
        for bad in ["--upload-pack=x", "HEAD:foo", "main branch", "a\nb"] {
            assert!(CloneRef::parse(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn destination_rejects_symlink_escape() {
        let td = tempfile::tempdir().unwrap();
        let link = td.path().join("link");
        #[cfg(unix)]
        std::os::unix::fs::symlink("/tmp", &link).unwrap();
        #[cfg(unix)]
        assert!(TrustedCloneDestination::new(&link).is_err());
        assert!(TrustedCloneDestination::new(td.path().join("repo")).is_ok());
    }

    #[test]
    #[cfg(unix)]
    fn clone_uses_fixed_safe_args_env_and_redacts_debug() {
        let td = tempfile::tempdir().unwrap();
        let log = td.path().join("git.log");
        let git = td.path().join("git");
        std::fs::write(
            &git,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\nprintenv | grep '^GIT_' >> '{}'\nfor last do :; done\nmkdir -p \"$last\"\n",
                log.display(),
                log.display()
            ),
        )
        .unwrap();
        let _ = std::process::Command::new("chmod")
            .args(["+x", git.to_str().unwrap()])
            .status();
        let dest = TrustedCloneDestination::new(td.path().join("repo")).unwrap();
        let remote = HttpsRemoteUrl::parse("https://example.com/org/repo.git").unwrap();
        assert!(!format!("{remote:?}").contains("example.com"));
        clone_with_git_program(
            CloneRequest {
                remote,
                destination: dest,
                r#ref: None,
                timeout: Duration::from_secs(5),
                byte_policy: CloneBytePolicy::default(),
                cancellation: CancellationToken::new(),
                lfs_smudge: LfsSmudgePolicy::Disable,
            },
            &git,
        )
        .unwrap();
        let log = std::fs::read_to_string(log).unwrap();
        for required in [
            "protocol.allow=never",
            "protocol.https.allow=always",
            "protocol.file.allow=never",
            "protocol.ext.allow=never",
            "core.hooksPath=/dev/null",
            "core.fsmonitor=false",
            "clone",
            "--no-local",
            "--template=",
            "--",
            "GIT_CONFIG_NOSYSTEM=1",
            "GIT_TERMINAL_PROMPT=0",
            "GIT_ALLOW_PROTOCOL=https",
            "GIT_LFS_SKIP_SMUDGE=1",
        ] {
            assert!(log.contains(required), "missing {required} in {log}");
        }
    }
}
