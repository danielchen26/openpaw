//! Discovery: against a synthetic `$HOME` holding all three agents, every
//! adapter must find exactly its own session, honour `max_age`, ignore unrelated
//! files and respect the cwd filter.

mod support;

use openpaw_agents::{DiscoveryEnv, SessionSource, adapter_for, adapters};
use openpaw_protocol::AgentKind;
use time::Duration;

fn discover(kind: AgentKind, env: &DiscoveryEnv) -> Vec<openpaw_agents::DiscoveredSession> {
    adapter_for(kind)
        .expect("adapter")
        .discover(env)
        .expect("discover")
}

#[test]
fn claude_finds_only_its_fresh_transcript() {
    let home = support::build_fake_home();
    let sessions = discover(AgentKind::ClaudeCode, &home.env());
    assert_eq!(sessions.len(), 1, "{sessions:#?}");
    let session = &sessions[0];
    assert_eq!(session.agent, AgentKind::ClaudeCode);
    assert_eq!(session.raw_id(), support::CLAUDE_SESSION);
    assert_eq!(
        session.session.as_str(),
        format!("sess_cc-{}", support::CLAUDE_SESSION)
    );
    assert_eq!(session.cwd.as_deref(), Some("/Users/dev/src/openpaw"));
    assert_eq!(session.git_branch.as_deref(), Some("main"));
    assert_eq!(
        session.title.as_deref(),
        Some("Run the unit tests, then clean the build directory.")
    );
    assert!(matches!(session.source, SessionSource::JsonLines(_)));
    assert_eq!(session.watch_path(), session.source.path());
}

#[test]
fn codex_finds_only_its_fresh_rollout() {
    let home = support::build_fake_home();
    let sessions = discover(AgentKind::Codex, &home.env());
    assert_eq!(sessions.len(), 1, "{sessions:#?}");
    let session = &sessions[0];
    assert_eq!(session.raw_id(), support::CODEX_SESSION);
    assert_eq!(session.cwd.as_deref(), Some("/Users/dev/src/openpaw"));
    assert_eq!(session.git_branch.as_deref(), Some("main"));
    assert_eq!(
        session.title.as_deref(),
        Some("Build the host daemon and fix any compile errors.")
    );
    assert_eq!(
        session.source.path().file_name().and_then(|n| n.to_str()),
        Some(support::CODEX_ROLLOUT)
    );
}

#[test]
fn opencode_finds_only_its_fresh_session() {
    let home = support::build_fake_home();
    let sessions = discover(AgentKind::OpenCode, &home.env());
    assert_eq!(sessions.len(), 1, "{sessions:#?}");
    let session = &sessions[0];
    assert_eq!(session.raw_id(), support::OPENCODE_SESSION);
    assert_eq!(session.title.as_deref(), Some("Wire the preview proxy"));
    assert_eq!(session.cwd.as_deref(), Some("/Users/dev/src/openpaw"));
    assert_eq!(session.git_branch, None, "opencode records no branch");
    let SessionSource::OpenCodeStorage { root, session_dir } = &session.source else {
        panic!("expected an opencode storage source");
    };
    assert!(root.ends_with("opencode/storage"));
    assert!(session_dir.ends_with(support::OPENCODE_PROJECT));
    assert_eq!(
        session.watch_path(),
        session_dir.join(format!("{}.json", support::OPENCODE_SESSION))
    );
}

#[test]
fn a_wide_max_age_also_finds_the_stale_sessions() {
    let home = support::build_fake_home();
    let mut env = home.env();
    env.max_age = Duration::days(365);
    for (kind, expected) in [
        (AgentKind::ClaudeCode, 2),
        (AgentKind::Codex, 2),
        (AgentKind::OpenCode, 2),
    ] {
        let sessions = discover(kind, &env);
        assert_eq!(sessions.len(), expected, "{kind}: {sessions:#?}");
    }
}

#[test]
fn newest_session_is_listed_first() {
    let home = support::build_fake_home();
    let mut env = home.env();
    env.max_age = Duration::days(365);
    for kind in [AgentKind::ClaudeCode, AgentKind::Codex, AgentKind::OpenCode] {
        let sessions = discover(kind, &env);
        assert!(
            sessions[0].updated_at >= sessions[1].updated_at,
            "{kind} is not sorted newest first"
        );
    }
}

#[test]
fn cwd_filter_excludes_other_checkouts() {
    let home = support::build_fake_home();
    let mut env = home.env();
    env.max_age = Duration::days(365);
    env.cwd_filter = Some("/Users/dev/src/openpaw".into());
    for (kind, raw_id) in [
        (AgentKind::ClaudeCode, support::CLAUDE_SESSION),
        (AgentKind::Codex, support::CODEX_SESSION),
        (AgentKind::OpenCode, support::OPENCODE_SESSION),
    ] {
        let sessions = discover(kind, &env);
        assert_eq!(sessions.len(), 1, "{kind}: {sessions:#?}");
        assert_eq!(sessions[0].raw_id(), raw_id);
    }

    env.cwd_filter = Some("/Users/dev/src/elsewhere".into());
    for kind in [AgentKind::ClaudeCode, AgentKind::Codex, AgentKind::OpenCode] {
        assert!(discover(kind, &env).is_empty(), "{kind} ignored cwd_filter");
    }
}

#[test]
fn an_empty_home_discovers_nothing_and_is_not_an_error() {
    let dir = tempfile::TempDir::new().expect("tempdir");
    let env = DiscoveryEnv::from_home(dir.path());
    for adapter in adapters() {
        assert!(
            adapter.discover(&env).expect("discover").is_empty(),
            "{} found something in an empty home",
            adapter.kind()
        );
    }
}

#[test]
fn the_generic_adapter_never_discovers_files() {
    let home = support::build_fake_home();
    let adapter = adapter_for(AgentKind::Generic).expect("adapter");
    assert!(adapter.discover(&home.env()).expect("discover").is_empty());
    assert_eq!(adapter.format_version(), "generic/terminal-markers-v1");
}

#[test]
fn every_adapter_reports_a_distinct_kind_and_format() {
    let mut kinds = Vec::new();
    let mut versions = Vec::new();
    for adapter in adapters() {
        kinds.push(adapter.kind());
        versions.push(adapter.format_version());
        assert_eq!(
            adapter_for(adapter.kind()).expect("round trip").kind(),
            adapter.kind()
        );
    }
    kinds.sort_by_key(|kind| kind.as_str());
    let unique = kinds.len();
    kinds.dedup();
    assert_eq!(kinds.len(), unique, "duplicate adapter kinds");
    versions.sort_unstable();
    let unique = versions.len();
    versions.dedup();
    assert_eq!(versions.len(), unique, "duplicate format versions");
    for kind in [
        AgentKind::GeminiCli,
        AgentKind::CursorCli,
        AgentKind::KimiCli,
        AgentKind::QwenCode,
    ] {
        assert!(
            adapter_for(kind).is_none(),
            "{kind} has no structured adapter yet"
        );
    }
}
