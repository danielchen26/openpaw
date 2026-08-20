//! Shared fixtures for the adapter integration tests.
//!
//! Every test works against a synthetic `$HOME` built in a tempdir, with the
//! checked-in fixtures copied to the exact relative paths the real agents use.

#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration as StdDuration, SystemTime};

use openpaw_agents::DiscoveryEnv;
use tempfile::TempDir;
use time::OffsetDateTime;

/// Native session ids of the checked-in fixtures.
pub const CLAUDE_SESSION: &str = "57ae0add-f501-42d6-a04d-618fc9d3bfae";
pub const CODEX_SESSION: &str = "019ea614-3c6e-7b20-ac95-16f64ccbea58";
pub const OPENCODE_SESSION: &str = "ses_2f64fc11cffegKaJScI4Md0FTX";
pub const OPENCODE_PROJECT: &str = "18126aafbcfc02bc4295dffd449e7e72f8590b0c";
pub const CODEX_ROLLOUT: &str =
    "rollout-2026-08-20T15-00-00-019ea614-3c6e-7b20-ac95-16f64ccbea58.jsonl";

/// Repository root, found by walking up from this test file.
pub fn repo_root() -> PathBuf {
    let mut dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    while !dir.join("protocol/json-schema/event.schema.json").exists() {
        assert!(dir.pop(), "repository root not found above the crate");
    }
    dir
}

pub fn fixtures() -> PathBuf {
    repo_root().join("protocol/fixtures")
}

pub fn normalized_dir() -> PathBuf {
    fixtures().join("normalized")
}

/// A synthetic home directory holding one live session per agent, one stale
/// session per agent, and unrelated files that discovery must ignore.
pub struct FakeHome {
    dir: TempDir,
}

impl FakeHome {
    pub fn path(&self) -> &Path {
        self.dir.path()
    }

    /// Discovery rooted at this home, as of now, with the default max age.
    pub fn env(&self) -> DiscoveryEnv {
        DiscoveryEnv::from_home(self.dir.path())
    }
}

/// 30 days ago: comfortably outside the 7 day default `max_age`.
pub fn stale_time() -> SystemTime {
    SystemTime::now() - StdDuration::from_secs(30 * 24 * 60 * 60)
}

pub fn stale_millis() -> i64 {
    (OffsetDateTime::now_utc() - time::Duration::days(30)).unix_timestamp() * 1000
}

pub fn build_fake_home() -> FakeHome {
    let dir = TempDir::new().expect("tempdir");
    let home = dir.path();
    let fixtures = fixtures();

    // --- Claude Code -------------------------------------------------------
    let claude_project = home.join(".claude/projects/-Users-dev-src-openpaw");
    fs::create_dir_all(&claude_project).expect("claude project dir");
    let claude_fixture = fixtures.join(format!("claude-code/{CLAUDE_SESSION}.jsonl"));
    fs::copy(
        &claude_fixture,
        claude_project.join(format!("{CLAUDE_SESSION}.jsonl")),
    )
    .expect("copy claude transcript");
    // A file that is not a transcript at all.
    fs::write(claude_project.join("notes.txt"), b"not a transcript\n").expect("claude noise");
    // A session last touched a month ago, in another project.
    let stale_project = home.join(".claude/projects/-Users-dev-src-stale");
    fs::create_dir_all(&stale_project).expect("stale project dir");
    let stale_claude = stale_project.join("11111111-1111-4111-8111-111111111111.jsonl");
    let claude_text = fs::read_to_string(&claude_fixture).expect("read claude transcript");
    fs::write(
        &stale_claude,
        claude_text
            .replace(CLAUDE_SESSION, "11111111-1111-4111-8111-111111111111")
            .replace("/Users/dev/src/openpaw", "/Users/dev/src/stale"),
    )
    .expect("write stale claude transcript");
    set_stale(&stale_claude);

    // --- Codex -------------------------------------------------------------
    let codex_day = home.join(".codex/sessions/2026/08/20");
    fs::create_dir_all(&codex_day).expect("codex day dir");
    let codex_fixture = fixtures.join(format!("codex/{CODEX_ROLLOUT}"));
    fs::copy(&codex_fixture, codex_day.join(CODEX_ROLLOUT)).expect("copy codex rollout");
    // Codex also writes non-rollout files next to rollouts.
    fs::write(codex_day.join("history.jsonl"), b"{\"type\":\"other\"}\n").expect("codex noise");
    let stale_day = home.join(".codex/sessions/2026/07/01");
    fs::create_dir_all(&stale_day).expect("stale codex dir");
    let stale_codex =
        stale_day.join("rollout-2026-07-01T09-00-00-22222222-2222-4222-8222-222222222222.jsonl");
    let codex_text = fs::read_to_string(&codex_fixture).expect("read codex rollout");
    fs::write(
        &stale_codex,
        codex_text
            .replace(CODEX_SESSION, "22222222-2222-4222-8222-222222222222")
            .replace("/Users/dev/src/openpaw", "/Users/dev/src/stale"),
    )
    .expect("write stale codex rollout");
    set_stale(&stale_codex);

    // --- OpenCode ----------------------------------------------------------
    let storage = home.join(".local/share/opencode/storage");
    copy_tree(&fixtures.join("opencode/storage"), &storage).expect("copy opencode storage");
    // A record that is not a session.
    fs::write(
        storage.join(format!("session/{OPENCODE_PROJECT}/index.json")),
        b"{\"id\":\"not-a-session\"}",
    )
    .expect("opencode noise");
    let stale_session = storage.join(format!(
        "session/{OPENCODE_PROJECT}/ses_STALE0000000000000000000.json"
    ));
    fs::write(
        &stale_session,
        format!(
            "{{\"id\":\"ses_STALE0000000000000000000\",\"directory\":\"/Users/dev/src/stale\",\
             \"title\":\"Stale session\",\"time\":{{\"created\":{stale},\"updated\":{stale}}}}}",
            stale = stale_millis()
        ),
    )
    .expect("write stale opencode session");
    set_stale(&stale_session);

    FakeHome { dir }
}

/// Backdate a file's mtime so `max_age` filters it out.
pub fn set_stale(path: &Path) {
    let file = fs::File::options()
        .write(true)
        .open(path)
        .expect("open for mtime");
    file.set_modified(stale_time()).expect("set mtime");
}

pub fn copy_tree(from: &Path, to: &Path) -> std::io::Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_tree(&entry.path(), &target)?;
        } else {
            fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}
