//! Golden-file tests: each checked-in fixture, parsed by its adapter, must
//! serialize byte-for-byte to `protocol/fixtures/normalized/<adapter>.events.json`.
//!
//! Regenerate with `OPENPAW_UPDATE_GOLDEN=1 cargo test -p openpaw-agents`.

mod support;

use std::collections::BTreeSet;
use std::fs;

use openpaw_agents::{AgentAdapter, Cursor, DiscoveredSession, adapter_for};
use openpaw_protocol::{AgentKind, Event};

#[test]
fn claude_code_transcript_matches_golden() {
    assert_golden(
        "claude-code",
        AgentKind::ClaudeCode,
        support::CLAUDE_SESSION,
    );
}

#[test]
fn codex_rollout_matches_golden() {
    assert_golden("codex", AgentKind::Codex, support::CODEX_SESSION);
}

#[test]
fn opencode_storage_matches_golden() {
    assert_golden("opencode", AgentKind::OpenCode, support::OPENCODE_SESSION);
}

#[test]
fn goldens_cover_every_supported_adapter() {
    for name in ["claude-code", "codex", "opencode"] {
        let path = support::normalized_dir().join(format!("{name}.events.json"));
        assert!(path.is_file(), "missing golden file {}", path.display());
    }
}

fn assert_golden(name: &str, kind: AgentKind, raw_id: &str) {
    let home = support::build_fake_home();
    let adapter = adapter_for(kind).expect("adapter");
    let session = fixture_session(adapter.as_ref(), &home, raw_id);

    let mut cursor = Cursor::new();
    let events = adapter.parse(&session, &mut cursor).expect("parse");
    assert!(!events.is_empty(), "{name} produced no events");

    // Contract invariants that the golden bytes alone would not pin down.
    let unique: BTreeSet<&str> = events.iter().map(|event| event.event_id.as_str()).collect();
    assert_eq!(unique.len(), events.len(), "{name} emitted duplicate ids");
    for (index, event) in events.iter().enumerate() {
        assert_eq!(event.seq, index as u64, "{name} seq is not dense");
        assert_eq!(event.version, openpaw_protocol::PROTOCOL_VERSION);
        assert_eq!(event.agent, kind);
        assert_eq!(event.session_id, session.session);
    }
    assert_eq!(cursor.next_seq(), events.len() as u64);
    assert!(
        adapter
            .parse(&session, &mut cursor)
            .expect("re-parse")
            .is_empty(),
        "{name} re-emitted events from a saved cursor"
    );

    let rendered = render(&events);
    let path = support::normalized_dir().join(format!("{name}.events.json"));
    if std::env::var("OPENPAW_UPDATE_GOLDEN").as_deref() == Ok("1") {
        fs::create_dir_all(support::normalized_dir()).expect("create normalized dir");
        fs::write(&path, rendered.as_bytes()).expect("write golden");
        return;
    }

    let expected = fs::read_to_string(&path).unwrap_or_else(|error| {
        panic!(
            "cannot read {}: {error}. Run with OPENPAW_UPDATE_GOLDEN=1 to generate it.",
            path.display()
        )
    });
    assert_eq!(
        rendered,
        expected,
        "{name} normalization drifted from {}. Re-run with OPENPAW_UPDATE_GOLDEN=1 if the change is intended.",
        path.display()
    );
}

/// Pretty printed with two spaces and a trailing newline: the golden format the
/// Swift tests read back.
fn render(events: &[Event]) -> String {
    let mut rendered = serde_json::to_string_pretty(events).expect("serialize events");
    rendered.push('\n');
    rendered
}

fn fixture_session(
    adapter: &dyn AgentAdapter,
    home: &support::FakeHome,
    raw_id: &str,
) -> DiscoveredSession {
    adapter
        .discover(&home.env())
        .expect("discover")
        .into_iter()
        .find(|session| session.raw_id() == raw_id)
        .unwrap_or_else(|| panic!("fixture session {raw_id} was not discovered"))
}
