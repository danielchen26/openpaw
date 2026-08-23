use std::ffi::OsString;
use std::fmt;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::{GitError, validate_rev};

const MAX_GIT_OUTPUT_BYTES: usize = 64 * 1024;
const DEFAULT_MAX_REPOSITORY_BYTES: u64 = 512 * 1024 * 1024;
const KILL_GRACE: Duration = Duration::from_millis(500);
const REAP_GRACE: Duration = Duration::from_millis(500);

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
    pub max_repository_bytes: u64,
}
impl Default for CloneBytePolicy {
    fn default() -> Self {
        Self {
            max_git_output_bytes: MAX_GIT_OUTPUT_BYTES,
            max_repository_bytes: DEFAULT_MAX_REPOSITORY_BYTES,
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
    fn cleanup(&self) {
        if self.assert_no_escape().is_ok() && self.path.exists() {
            let _ = std::fs::remove_dir_all(&self.path);
        }
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
    let result = clone_inner(&req, git_program.as_ref());
    if result.is_err() {
        req.destination.cleanup();
    }
    result
}

fn clone_inner(req: &CloneRequest, git_program: &Path) -> Result<(), GitError> {
    if req.cancellation.is_cancelled() {
        return Err(GitError::Cancelled);
    }
    let mut args: Vec<OsString> = [
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
        "-c",
        "credential.helper=",
        "-c",
        "http.followRedirects=false",
        "clone",
        "--no-local",
        "--template=",
    ]
    .into_iter()
    .map(OsString::from)
    .collect();
    if let Some(r) = &req.r#ref {
        args.push("--branch".into());
        args.push(r.as_str().into());
    }
    args.push("--".into());
    args.push(req.remote.as_str().into());
    args.push(req.destination.path.as_os_str().to_owned());

    let mut cmd = Command::new(git_program);
    cmd.args(&args)
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
    let stdout = drain(
        child.stdout.take().unwrap(),
        req.byte_policy.max_git_output_bytes,
    );
    let stderr = drain(
        child.stderr.take().unwrap(),
        req.byte_policy.max_git_output_bytes,
    );
    let start = Instant::now();
    loop {
        if req.cancellation.is_cancelled() {
            terminate_and_reap(&mut child, pid);
            join_drains(stdout, stderr);
            return Err(GitError::Cancelled);
        }
        if start.elapsed() >= req.timeout {
            terminate_and_reap(&mut child, pid);
            join_drains(stdout, stderr);
            return Err(GitError::Timeout);
        }
        if pipe_bytes(&stdout) + pipe_bytes(&stderr) > req.byte_policy.max_git_output_bytes {
            terminate_and_reap(&mut child, pid);
            join_drains(stdout, stderr);
            return Err(GitError::OutputLimit);
        }
        req.destination.assert_no_escape()?;
        if dir_size(req.destination.path())? > req.byte_policy.max_repository_bytes {
            terminate_and_reap(&mut child, pid);
            join_drains(stdout, stderr);
            return Err(GitError::RepositorySizeLimit);
        }
        if let Some(status) = child.try_wait().map_err(GitError::Io)? {
            let (_out, err) = join_drains(stdout, stderr);
            if pipe_len(&err) + pipe_len(&_out) > req.byte_policy.max_git_output_bytes {
                return Err(GitError::OutputLimit);
            }
            req.destination.assert_no_escape()?;
            if dir_size(req.destination.path())? > req.byte_policy.max_repository_bytes {
                return Err(GitError::RepositorySizeLimit);
            }
            return finish_status(status, &err);
        }
        thread::sleep(Duration::from_millis(10));
    }
}

fn finish_status(status: ExitStatus, stderr: &[u8]) -> Result<(), GitError> {
    if status.success() {
        Ok(())
    } else {
        Err(GitError::Command {
            code: status.code(),
            stderr: sanitize_stderr(stderr),
        })
    }
}

struct Drain {
    bytes: Arc<AtomicUsize>,
    handle: JoinHandle<Vec<u8>>,
}

fn drain(mut reader: impl Read + Send + 'static, limit: usize) -> Drain {
    let bytes = Arc::new(AtomicUsize::new(0));
    let thread_bytes = Arc::clone(&bytes);
    let handle = thread::spawn(move || {
        let mut out = Vec::new();
        let mut buf = [0_u8; 8192];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => return out,
                Ok(n) => {
                    thread_bytes.fetch_add(n, Ordering::SeqCst);
                    let remaining = limit.saturating_add(1).saturating_sub(out.len());
                    out.extend_from_slice(&buf[..n.min(remaining)]);
                }
            }
        }
    });
    Drain { bytes, handle }
}

fn pipe_bytes(drain: &Drain) -> usize {
    drain.bytes.load(Ordering::SeqCst)
}

fn join_drains(a: Drain, b: Drain) -> (Vec<u8>, Vec<u8>) {
    (
        a.handle.join().unwrap_or_default(),
        b.handle.join().unwrap_or_default(),
    )
}
fn pipe_len(v: &[u8]) -> usize {
    v.len()
}

fn dir_size(path: &Path) -> Result<u64, GitError> {
    fn walk(path: &Path, total: &mut u64) -> std::io::Result<()> {
        let meta = match std::fs::symlink_metadata(path) {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(e) => return Err(e),
        };
        if meta.file_type().is_symlink() {
            return Ok(());
        }
        if meta.is_file() {
            *total = total.saturating_add(meta.len());
        } else if meta.is_dir() {
            for entry in std::fs::read_dir(path)? {
                walk(&entry?.path(), total)?;
            }
        }
        Ok(())
    }
    let mut total = 0;
    walk(path, &mut total).map_err(GitError::Io)?;
    Ok(total)
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
    let s: String = String::from_utf8_lossy(stderr).chars().take(4096).collect();
    s.split_whitespace()
        .map(|tok| {
            if tok.starts_with("http://") || tok.starts_with("https://") || tok.contains('@') {
                "[redacted]"
            } else {
                tok
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(unix)]
fn set_process_group(cmd: &mut Command) {
    use std::os::unix::process::CommandExt;
    cmd.process_group(0);
}
#[cfg(not(unix))]
fn set_process_group(_cmd: &mut Command) {}

fn terminate_and_reap(child: &mut Child, pid: u32) {
    term_group(pid);
    if wait_bounded(child, KILL_GRACE).is_none() {
        kill_group(pid);
        let _ = wait_bounded(child, REAP_GRACE);
    }
}

fn wait_bounded(child: &mut Child, timeout: Duration) -> Option<ExitStatus> {
    let start = Instant::now();
    loop {
        if let Ok(Some(status)) = child.try_wait() {
            return Some(status);
        }
        if start.elapsed() >= timeout {
            return None;
        }
        thread::sleep(Duration::from_millis(10));
    }
}

#[cfg(unix)]
fn term_group(pid: u32) {
    signal_group(pid, "-TERM");
}
#[cfg(unix)]
fn kill_group(pid: u32) {
    signal_group(pid, "-KILL");
}
#[cfg(unix)]
fn signal_group(pid: u32, sig: &str) {
    let group = format!("-{pid}");
    let _ = Command::new("/bin/kill")
        .args([sig, &group])
        .stderr(Stdio::null())
        .status();
    let _ = Command::new("/bin/kill")
        .args([sig, &pid.to_string()])
        .stderr(Stdio::null())
        .status();
}
#[cfg(not(unix))]
fn term_group(_pid: u32) {}
#[cfg(not(unix))]
fn kill_group(_pid: u32) {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn chmod_x(path: &Path) {
        let _ = Command::new("chmod")
            .args(["+x", path.to_str().unwrap()])
            .status();
    }

    fn req(
        td: &tempfile::TempDir,
        policy: CloneBytePolicy,
        cancellation: CancellationToken,
    ) -> CloneRequest {
        CloneRequest {
            remote: HttpsRemoteUrl::parse("https://example.com/org/repo.git").unwrap(),
            destination: TrustedCloneDestination::new(td.path().join("repo")).unwrap(),
            r#ref: None,
            timeout: Duration::from_secs(2),
            byte_policy: policy,
            cancellation,
            lfs_smudge: LfsSmudgePolicy::Disable,
        }
    }

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
        fs::write(&git, format!("#!/bin/sh\nprintf '%s\n' \"$@\" > '{}'\nprintenv | grep '^GIT_' >> '{}'\nfor last do :; done\nmkdir -p \"$last\"\n", log.display(), log.display())).unwrap();
        chmod_x(&git);
        clone_with_git_program(
            req(&td, CloneBytePolicy::default(), CancellationToken::new()),
            &git,
        )
        .unwrap();
        let log = fs::read_to_string(log).unwrap();
        for required in [
            "protocol.allow=never",
            "credential.helper=",
            "http.followRedirects=false",
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
        let sanitized = sanitize_stderr(
            b"fatal https://user:secret@example.com/org/repo.git user@example.com\n",
        );
        assert!(!sanitized.contains("secret"));
        assert!(!sanitized.contains("example.com"));
    }

    #[test]
    #[cfg(unix)]
    fn cleans_destination_on_output_limit_after_success() {
        let td = tempfile::tempdir().unwrap();
        let git = td.path().join("git");
        fs::write(&git, "#!/bin/sh\nfor last do :; done\nmkdir -p \"$last\"\npython3 - <<'PY'\nprint('x' * 20000)\nPY\nexit 0\n").unwrap();
        chmod_x(&git);
        let err = clone_with_git_program(
            req(
                &td,
                CloneBytePolicy {
                    max_git_output_bytes: 100,
                    ..Default::default()
                },
                CancellationToken::new(),
            ),
            &git,
        )
        .unwrap_err();
        assert!(matches!(err, GitError::OutputLimit));
        assert!(!td.path().join("repo").exists());
    }

    #[test]
    #[cfg(unix)]
    fn enforces_repository_size_limit_while_child_runs() {
        let td = tempfile::tempdir().unwrap();
        let git = td.path().join("git");
        fs::write(&git, "#!/bin/sh\nfor last do :; done\nmkdir -p \"$last\"\ndd if=/dev/zero of=\"$last/blob\" bs=1024 count=64 2>/dev/null\nsleep 5\n").unwrap();
        chmod_x(&git);
        let err = clone_with_git_program(
            req(
                &td,
                CloneBytePolicy {
                    max_repository_bytes: 1024,
                    ..Default::default()
                },
                CancellationToken::new(),
            ),
            &git,
        )
        .unwrap_err();
        assert!(matches!(err, GitError::RepositorySizeLimit));
        assert!(!td.path().join("repo").exists());
    }

    #[test]
    #[cfg(unix)]
    fn timeout_escalates_term_ignoring_child_and_cleans() {
        let td = tempfile::tempdir().unwrap();
        let git = td.path().join("git");
        fs::write(
            &git,
            "#!/bin/sh\ntrap '' TERM\nfor last do :; done\nmkdir -p \"$last\"\nsleep 10\n",
        )
        .unwrap();
        chmod_x(&git);
        let mut r = req(&td, CloneBytePolicy::default(), CancellationToken::new());
        r.timeout = Duration::from_millis(50);
        let start = Instant::now();
        let err = clone_with_git_program(r, &git).unwrap_err();
        assert!(matches!(err, GitError::Timeout));
        assert!(start.elapsed() < Duration::from_secs(3));
        assert!(!td.path().join("repo").exists());
    }

    #[test]
    #[cfg(unix)]
    fn cancel_terminates_and_cleans() {
        let td = tempfile::tempdir().unwrap();
        let git = td.path().join("git");
        fs::write(
            &git,
            "#!/bin/sh\nfor last do :; done\nmkdir -p \"$last\"\nsleep 10\n",
        )
        .unwrap();
        chmod_x(&git);
        let token = CancellationToken::new();
        let token2 = token.clone();
        thread::spawn(move || {
            thread::sleep(Duration::from_millis(50));
            token2.cancel();
        });
        let err =
            clone_with_git_program(req(&td, CloneBytePolicy::default(), token), &git).unwrap_err();
        assert!(matches!(err, GitError::Cancelled));
        assert!(!td.path().join("repo").exists());
    }

    #[test]
    fn concurrent_same_destination_attempt_is_rejected() {
        let td = tempfile::tempdir().unwrap();
        let dest = td.path().join("repo");
        let first = TrustedCloneDestination::new(&dest).unwrap();
        fs::create_dir(&dest).unwrap();
        assert!(TrustedCloneDestination::new(&dest).is_err());
        drop(first);
    }
}
