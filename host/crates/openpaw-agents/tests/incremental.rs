//! Incremental parsing: a resumed cursor must yield only the new events, with
//! contiguous `seq` and no repeated `event_id`.

mod support;

use std::collections::{BTreeMap, BTreeSet};
use std::fs;

use openpaw_agents::{AgentAdapter, Cursor, DiscoveredSession, DiscoveryEnv, adapter_for};
use openpaw_protocol::{AgentKind, Body, Event, EventType, PlanStepStatus};
use tempfile::TempDir;

#[test]
fn claude_transcript_resumes_mid_line() {
    let dir = TempDir::new().expect("tempdir");
    let project = dir.path().join(".claude/projects/-Users-dev-src-openpaw");
    fs::create_dir_all(&project).expect("project dir");
    let transcript = project.join(format!("{}.jsonl", support::CLAUDE_SESSION));
    let full = fs::read(
        support::fixtures().join(format!("claude-code/{}.jsonl", support::CLAUDE_SESSION)),
    )
    .expect("read transcript");

    // Cut inside the fifth line: the writer is mid-append.
    let cut = mid_line_offset(&full, 4);
    fs::write(&transcript, &full[..cut]).expect("write truncated transcript");

    let adapter = adapter_for(AgentKind::ClaudeCode).expect("adapter");
    let env = DiscoveryEnv::from_home(dir.path());
    let session = only_session(adapter.as_ref(), &env);
    let mut cursor = Cursor::new();
    let first = adapter.parse(&session, &mut cursor).expect("first pass");
    assert!(!first.is_empty(), "first pass produced no events");
    assert!(
        cursor.byte_offset() <= cut as u64,
        "consumed a partially written line"
    );
    assert!(
        adapter
            .parse(&session, &mut cursor)
            .expect("idle pass")
            .is_empty(),
        "re-parsing unchanged bytes produced events"
    );

    fs::write(&transcript, &full).expect("restore transcript");
    let session = only_session(adapter.as_ref(), &env);
    let second = adapter.parse(&session, &mut cursor).expect("second pass");
    assert!(!second.is_empty(), "second pass produced no events");

    assert_resumed(&first, &second);
    assert_matches_single_pass(adapter.as_ref(), &session, &first, &second, true);
}

#[test]
fn codex_rollout_resumes_at_line_boundary() {
    let dir = TempDir::new().expect("tempdir");
    let day = dir.path().join(".codex/sessions/2026/08/20");
    fs::create_dir_all(&day).expect("codex dir");
    let rollout = day.join(support::CODEX_ROLLOUT);
    let full = fs::read(support::fixtures().join(format!("codex/{}", support::CODEX_ROLLOUT)))
        .expect("read rollout");
    let cut = line_boundary_offset(&full, 6);
    fs::write(&rollout, &full[..cut]).expect("write truncated rollout");

    let adapter = adapter_for(AgentKind::Codex).expect("adapter");
    let env = DiscoveryEnv::from_home(dir.path());
    let session = only_session(adapter.as_ref(), &env);
    let mut cursor = Cursor::new();
    let first = adapter.parse(&session, &mut cursor).expect("first pass");
    assert!(!first.is_empty(), "first pass produced no events");

    fs::write(&rollout, &full).expect("restore rollout");
    let session = only_session(adapter.as_ref(), &env);
    let second = adapter.parse(&session, &mut cursor).expect("second pass");
    assert!(!second.is_empty(), "second pass produced no events");

    assert_resumed(&first, &second);
    assert_matches_single_pass(adapter.as_ref(), &session, &first, &second, true);
    // Codex states its cwd only on the first line, which the second pass never
    // re-reads: the cursor must have carried it.
    assert!(
        second
            .iter()
            .all(|event| event.cwd.as_deref() == Some("/Users/dev/src/openpaw")),
        "cwd was lost across the resume"
    );
}

#[test]
fn opencode_storage_resumes_when_parts_arrive() {
    let dir = TempDir::new().expect("tempdir");
    let storage = dir.path().join(".local/share/opencode/storage");
    support::copy_tree(&support::fixtures().join("opencode/storage"), &storage)
        .expect("copy storage");
    let assistant_parts = storage.join("part/msg_c4b2186d8001ILwDoNkyZur5tU");
    let deferred: Vec<(std::path::PathBuf, Vec<u8>)> =
        ["prt_a5.json", "prt_a6.json", "prt_a7.json"]
            .iter()
            .map(|name| {
                let path = assistant_parts.join(name);
                let bytes = fs::read(&path).expect("read part");
                fs::remove_file(&path).expect("remove part");
                (path, bytes)
            })
            .collect();

    let adapter = adapter_for(AgentKind::OpenCode).expect("adapter");
    let env = DiscoveryEnv::from_home(dir.path());
    let session = only_session(adapter.as_ref(), &env);
    let mut cursor = Cursor::new();
    let first = adapter.parse(&session, &mut cursor).expect("first pass");
    assert!(!first.is_empty(), "first pass produced no events");
    assert!(
        adapter
            .parse(&session, &mut cursor)
            .expect("idle pass")
            .is_empty(),
        "unchanged storage produced events"
    );

    for (path, bytes) in deferred {
        fs::write(path, bytes).expect("restore part");
    }
    let second = adapter.parse(&session, &mut cursor).expect("second pass");
    assert!(!second.is_empty(), "new parts produced no events");
    assert_resumed(&first, &second);
    assert_matches_single_pass(adapter.as_ref(), &session, &first, &second, false);
}

/// The first todo write of a session creates a plan, later ones update it — and
/// that distinction has to survive a resumed parse, because the cursor is the
/// only place that remembers it.
#[test]
fn a_later_todo_write_updates_the_plan_across_a_resume() {
    let dir = TempDir::new().expect("tempdir");
    let project = dir.path().join(".claude/projects/-Users-dev-src-openpaw");
    fs::create_dir_all(&project).expect("project dir");
    let transcript = project.join(format!("{}.jsonl", support::CLAUDE_SESSION));
    fs::copy(
        support::fixtures().join(format!("claude-code/{}.jsonl", support::CLAUDE_SESSION)),
        &transcript,
    )
    .expect("copy transcript");

    let adapter = adapter_for(AgentKind::ClaudeCode).expect("adapter");
    let env = DiscoveryEnv::from_home(dir.path());
    let session = only_session(adapter.as_ref(), &env);
    let mut cursor = Cursor::new();
    let first = adapter.parse(&session, &mut cursor).expect("first pass");
    let created: Vec<&Event> = first
        .iter()
        .filter(|event| event.kind() == EventType::PlanCreated)
        .collect();
    assert_eq!(created.len(), 1, "the first todo write creates the plan");

    let appended = serde_json::json!({
        "sessionId": support::CLAUDE_SESSION,
        "cwd": "/Users/dev/src/openpaw",
        "gitBranch": "main",
        "type": "assistant",
        "uuid": "a5",
        "timestamp": "2026-08-20T14:31:00.000Z",
        "message": {
            "id": "msg_05",
            "role": "assistant",
            "content": [{
                "type": "tool_use",
                "id": "toolu_05",
                "name": "TodoWrite",
                "input": {"todos": [
                    {"content": "Fix failing parser test", "status": "completed"},
                    {"content": "Clean build directory", "status": "in_progress"},
                ]},
            }],
        },
    });
    let mut file = fs::OpenOptions::new()
        .append(true)
        .open(&transcript)
        .expect("append to transcript");
    use std::io::Write as _;
    writeln!(file, "{appended}").expect("write appended line");
    drop(file);

    let session = only_session(adapter.as_ref(), &env);
    let second = adapter.parse(&session, &mut cursor).expect("second pass");
    let updated: Vec<&Event> = second
        .iter()
        .filter(|event| event.kind() == EventType::PlanUpdated)
        .collect();
    assert_eq!(updated.len(), 1, "the second todo write updates the plan");
    assert!(
        !second
            .iter()
            .any(|event| event.kind() == EventType::PlanCreated),
        "a session must not create two plans"
    );

    let (Body::PlanCreated(before), Body::PlanUpdated(after)) =
        (&created[0].body, &updated[0].body)
    else {
        panic!("expected plan bodies");
    };
    assert_eq!(before.plan_id, after.plan_id, "the plan identity is stable");
    assert_eq!(after.steps.len(), 2);
    assert_eq!(after.steps[0].status, PlanStepStatus::Completed);
    assert_eq!(after.steps[1].status, PlanStepStatus::InProgress);
    assert_eq!(after.steps[1].id, "1");
}

fn only_session(adapter: &dyn AgentAdapter, env: &DiscoveryEnv) -> DiscoveredSession {
    let mut sessions = adapter.discover(env).expect("discover");
    assert_eq!(sessions.len(), 1, "expected exactly one staged session");
    sessions.remove(0)
}

/// Byte offset halfway into line `index` (0 based).
fn mid_line_offset(bytes: &[u8], index: usize) -> usize {
    let start = line_boundary_offset(bytes, index);
    let end = line_boundary_offset(bytes, index + 1);
    start + (end - start) / 2
}

/// Byte offset at which line `index` starts.
fn line_boundary_offset(bytes: &[u8], index: usize) -> usize {
    if index == 0 {
        return 0;
    }
    let mut seen = 0;
    for (offset, byte) in bytes.iter().enumerate() {
        if *byte == b'\n' {
            seen += 1;
            if seen == index {
                return offset + 1;
            }
        }
    }
    bytes.len()
}

fn assert_resumed(first: &[Event], second: &[Event]) {
    let seen: BTreeSet<&str> = first.iter().map(|event| event.event_id.as_str()).collect();
    for event in second {
        assert!(
            !seen.contains(event.event_id.as_str()),
            "second pass re-emitted {}",
            event.event_id
        );
    }
    let unique: BTreeSet<&str> = second.iter().map(|event| event.event_id.as_str()).collect();
    assert_eq!(unique.len(), second.len(), "second pass had duplicate ids");
    for (index, event) in first.iter().chain(second).enumerate() {
        assert_eq!(
            event.seq, index as u64,
            "seq is not contiguous across passes"
        );
    }
}

/// Two resumed passes must observe exactly the same events as one pass over the
/// finished input.
///
/// `ordered` is true for append-only transcripts, where resuming cannot change
/// the order. It is false for OpenCode: a message-level event (its `finish`) is
/// emitted as soon as the message record says so, which is before the parts that
/// arrive later, so the resumed sequence interleaves differently while carrying
/// an identical set of events.
fn assert_matches_single_pass(
    adapter: &dyn AgentAdapter,
    session: &DiscoveredSession,
    first: &[Event],
    second: &[Event],
    ordered: bool,
) {
    let mut fresh = Cursor::new();
    let single = adapter.parse(session, &mut fresh).expect("single pass");
    let incremental: Vec<&Event> = first.iter().chain(second).collect();
    assert_eq!(single.len(), incremental.len(), "event count diverged");

    let whole: BTreeMap<&str, &Event> = single
        .iter()
        .map(|event| (event.event_id.as_str(), event))
        .collect();
    for part in &incremental {
        let counterpart = whole
            .get(part.event_id.as_str())
            .unwrap_or_else(|| panic!("{} is missing from the single pass", part.event_id));
        assert_eq!(counterpart.body, part.body, "{}", part.event_id);
        assert_eq!(counterpart.cwd, part.cwd, "{}", part.event_id);
        assert_eq!(counterpart.timestamp, part.timestamp, "{}", part.event_id);
    }

    if ordered {
        for (whole, part) in single.iter().zip(incremental) {
            assert_eq!(whole.event_id, part.event_id, "order diverged");
            assert_eq!(whole.seq, part.seq);
        }
    }
}

#[test]
fn line_offset_helpers_land_on_boundaries() {
    let bytes = b"a\nbb\nccc\n";
    assert_eq!(line_boundary_offset(bytes, 0), 0);
    assert_eq!(line_boundary_offset(bytes, 1), 2);
    assert_eq!(line_boundary_offset(bytes, 2), 5);
    assert_eq!(mid_line_offset(bytes, 1), 3);
}
