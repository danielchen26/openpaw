//! Hook ingress: Claude Code hook payloads become permission and question
//! events with the right risk classification.

mod support;

use std::fs;

use openpaw_agents::adapter_for;
use openpaw_protocol::{ActionId, AgentKind, Body, EventType, RiskClass};
use serde_json::Value;
use time::OffsetDateTime;

fn hook(name: &str) -> Value {
    let path = support::fixtures().join(format!("claude-code/{name}"));
    serde_json::from_slice(&fs::read(&path).expect("read hook fixture"))
        .expect("parse hook fixture")
}

fn now() -> OffsetDateTime {
    OffsetDateTime::from_unix_timestamp(1_787_245_200).expect("timestamp")
}

fn parse(name: &str) -> openpaw_protocol::Event {
    adapter_for(AgentKind::ClaudeCode)
        .expect("adapter")
        .parse_hook(&hook(name), now())
        .expect("parse hook")
        .unwrap_or_else(|| panic!("{name} produced no event"))
}

#[test]
fn destructive_pretooluse_demands_detail_expansion() {
    let event = parse("hook-pretooluse-destructive.json");
    assert_eq!(event.kind(), EventType::PermissionRequested);
    assert_eq!(event.cwd.as_deref(), Some("/Users/dev/src/openpaw"));
    let Body::PermissionRequested(payload) = &event.body else {
        panic!("expected permission.requested, got {:?}", event.kind());
    };
    assert_eq!(payload.tool, "Bash");
    assert_eq!(
        payload.command.as_deref(),
        Some("sudo rm -rf /Users/dev/src/openpaw/build")
    );
    assert_eq!(payload.risk.class, RiskClass::DestructiveShell);
    assert!(
        payload.risk.requires_detail_expansion,
        "rm/sudo must force detail expansion"
    );
    assert!(
        !payload.risk.reasons.is_empty(),
        "risk must name its triggers"
    );
    assert_eq!(
        payload.actions,
        vec![
            ActionId::ApproveOnce,
            ActionId::ApproveAlways,
            ActionId::Deny
        ]
    );
    assert!(payload.request_id.starts_with(support::CLAUDE_SESSION));
}

#[test]
fn readonly_pretooluse_is_plain_read_only() {
    let event = parse("hook-pretooluse-readonly.json");
    let Body::PermissionRequested(payload) = &event.body else {
        panic!("expected permission.requested, got {:?}", event.kind());
    };
    assert_eq!(payload.tool, "Read");
    assert_eq!(payload.risk.class, RiskClass::ReadOnly);
    assert!(!payload.risk.requires_detail_expansion);
    assert_eq!(payload.paths, vec!["/Users/dev/src/openpaw/README.md"]);
}

#[test]
fn notification_asking_for_input_becomes_a_question() {
    let event = parse("hook-notification-question.json");
    assert_eq!(event.kind(), EventType::QuestionRequested);
    let Body::QuestionRequested(payload) = &event.body else {
        panic!("expected question.requested, got {:?}", event.kind());
    };
    assert!(payload.question.contains("should the migration run"));
    assert!(payload.allows_free_text);
    assert!(payload.choices.is_empty());
}

#[test]
fn hook_events_are_idempotent_and_agent_scoped() {
    let first = parse("hook-pretooluse-destructive.json");
    let again = parse("hook-pretooluse-destructive.json");
    assert_eq!(first.event_id, again.event_id);
    assert_eq!(first.agent, AgentKind::ClaudeCode);
    assert_eq!(first.seq, 0, "hook events are sequenced by the host");
}

#[test]
fn notifications_that_ask_nothing_are_not_inbox_items() {
    let payload = serde_json::json!({
        "session_id": support::CLAUDE_SESSION,
        "hook_event_name": "Notification",
        "message": "Claude finished the refactor",
    });
    let event = adapter_for(AgentKind::ClaudeCode)
        .expect("adapter")
        .parse_hook(&payload, now())
        .expect("parse hook");
    assert!(
        event.is_none(),
        "a plain notification must not ask anything"
    );
}

#[test]
fn stop_and_subagent_hooks_report_lifecycle() {
    let adapter = adapter_for(AgentKind::ClaudeCode).expect("adapter");
    for (hook_name, expected) in [
        ("Stop", EventType::AgentCompleted),
        ("SessionEnd", EventType::AgentCompleted),
        ("SubagentStop", EventType::AgentWorking),
    ] {
        let payload = serde_json::json!({
            "session_id": support::CLAUDE_SESSION,
            "hook_event_name": hook_name,
        });
        let event = adapter
            .parse_hook(&payload, now())
            .expect("parse hook")
            .unwrap_or_else(|| panic!("{hook_name} produced no event"));
        assert_eq!(event.kind(), expected, "{hook_name}");
    }
}

#[test]
fn malformed_hooks_are_errors_not_silence() {
    let adapter = adapter_for(AgentKind::ClaudeCode).expect("adapter");
    assert!(
        adapter
            .parse_hook(&serde_json::json!({"session_id": "x"}), now())
            .is_err(),
        "a payload without hook_event_name is malformed"
    );
    assert!(
        adapter
            .parse_hook(
                &serde_json::json!({"hook_event_name": "PreToolUse", "session_id": "x"}),
                now()
            )
            .is_err(),
        "PreToolUse without tool_name is malformed"
    );
    assert!(
        adapter
            .parse_hook(
                &serde_json::json!({"hook_event_name": "PreCompact", "session_id": "x"}),
                now()
            )
            .expect("unknown hooks are not errors")
            .is_none(),
        "unknown hook names are simply uninteresting"
    );
}

#[test]
fn agents_without_hooks_stay_silent() {
    for kind in [AgentKind::Codex, AgentKind::OpenCode, AgentKind::Generic] {
        let event = adapter_for(kind)
            .expect("adapter")
            .parse_hook(&hook("hook-pretooluse-destructive.json"), now())
            .expect("parse hook");
        assert!(event.is_none(), "{kind} has no hook ingress");
    }
}
