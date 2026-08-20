#![allow(dead_code)]

//! Shared fixtures for the integration tests.

use std::path::PathBuf;

use openpaw_protocol::{
    ActionId, AgentKind, AgentLifecycle, Body, ContextUpdated, DecidedBy, DeltaKind, Event,
    EventType, FileChange, InboxItem, PermissionRequested, PermissionResolved, Plan, PlanStep,
    PlanStepStatus, QuestionAnswered, QuestionRequested, Risk, SessionId, StdStream, ToolCompleted,
    ToolFailed, ToolOutput, ToolStarted, TurnCompleted, TurnDelta, TurnRole, TurnStarted,
    UsageUpdated,
};
use time::OffsetDateTime;
use time::macros::datetime;

/// Native session id taken from the Claude Code fixture transcript.
pub const SESSION_RAW: &str = "57ae0add-f501-42d6-a04d-618fc9d3bfae";

pub fn session() -> SessionId {
    SessionId::new(AgentKind::ClaudeCode, SESSION_RAW)
}

pub fn timestamp() -> OffsetDateTime {
    datetime!(2026-08-20 14:30:00 UTC)
}

pub fn expiry() -> OffsetDateTime {
    datetime!(2026-08-20 14:35:00 UTC)
}

/// A representative payload for every event type.
pub fn sample_body(kind: EventType) -> Body {
    let lifecycle = |reason: &str, title: &str| AgentLifecycle {
        reason: Some(reason.to_owned()),
        exit_code: None,
        title: Some(title.to_owned()),
    };
    let risk = Risk::classify_command("rm -rf /Users/dev/src/openpaw/build");

    match kind {
        EventType::AgentStarted => {
            Body::AgentStarted(lifecycle("discovered in tmux", "openpaw host"))
        }
        EventType::AgentWorking => Body::AgentWorking(AgentLifecycle::default()),
        EventType::AgentCompleted => {
            Body::AgentCompleted(lifecycle("end_turn", "Wire up the preview proxy"))
        }
        EventType::AgentFailed => Body::AgentFailed(AgentLifecycle {
            reason: Some("provider returned 529".to_owned()),
            exit_code: Some(1),
            title: None,
        }),
        EventType::TurnStarted => Body::TurnStarted(TurnStarted {
            turn_id: "turn_1".to_owned(),
            role: TurnRole::User,
            text: Some("Wire up the preview proxy.".to_owned()),
        }),
        EventType::TurnDelta => Body::TurnDelta(TurnDelta {
            turn_id: "turn_1".to_owned(),
            delta: "Adding a websocket upgrade branch".to_owned(),
            kind: DeltaKind::Text,
        }),
        EventType::TurnCompleted => Body::TurnCompleted(TurnCompleted {
            turn_id: "turn_1".to_owned(),
            role: TurnRole::Assistant,
            text: "Done; the proxy now upgrades websockets.".to_owned(),
            thinking: Some("Hop-by-hop headers must be stripped.".to_owned()),
        }),
        EventType::ToolStarted => Body::ToolStarted(ToolStarted {
            call_id: "call_ab12".to_owned(),
            tool: "Bash".to_owned(),
            summary: Some("Clean build directory".to_owned()),
            command: Some("rm -rf /Users/dev/src/openpaw/build".to_owned()),
            paths: vec!["/Users/dev/src/openpaw/build".to_owned()],
            risk: risk.clone(),
        }),
        EventType::ToolOutput => Body::ToolOutput(ToolOutput {
            call_id: "call_ab12".to_owned(),
            chunk: "error[E0308]: mismatched types\n".to_owned(),
            stream: StdStream::Stderr,
            truncated: false,
        }),
        EventType::ToolCompleted => Body::ToolCompleted(ToolCompleted {
            call_id: "call_ab12".to_owned(),
            exit_code: Some(0),
            duration_ms: Some(26_000),
            summary: Some("workspace builds cleanly".to_owned()),
        }),
        EventType::ToolFailed => Body::ToolFailed(ToolFailed {
            call_id: "call_9f2a1d".to_owned(),
            error: "file not found".to_owned(),
            exit_code: Some(1),
        }),
        EventType::PermissionRequested => Body::PermissionRequested(PermissionRequested {
            request_id: "req_1".to_owned(),
            tool: "Bash".to_owned(),
            summary: "Clean build directory".to_owned(),
            command: Some("rm -rf /Users/dev/src/openpaw/build".to_owned()),
            paths: vec!["/Users/dev/src/openpaw/build".to_owned()],
            risk,
            actions: vec![
                ActionId::ApproveOnce,
                ActionId::ApproveAlways,
                ActionId::Deny,
            ],
            expires_at: Some(expiry()),
        }),
        EventType::PermissionResolved => Body::PermissionResolved(PermissionResolved {
            request_id: "req_1".to_owned(),
            decision: ActionId::Deny,
            decided_by: DecidedBy::Device,
            device_id: Some("dev_phone".to_owned()),
        }),
        EventType::QuestionRequested => Body::QuestionRequested(QuestionRequested {
            request_id: "req_2".to_owned(),
            question: "Should the migration run against production?".to_owned(),
            choices: vec!["yes".to_owned(), "no".to_owned()],
            allows_free_text: true,
        }),
        EventType::QuestionAnswered => Body::QuestionAnswered(QuestionAnswered {
            request_id: "req_2".to_owned(),
            answer: "no".to_owned(),
        }),
        EventType::PlanCreated => Body::PlanCreated(sample_plan()),
        EventType::PlanUpdated => Body::PlanUpdated(sample_plan()),
        EventType::FileRead => Body::FileRead(FileChange::new("/Users/dev/src/openpaw/README.md")),
        EventType::FileCreated => Body::FileCreated(FileChange {
            path: "/Users/dev/src/openpaw/host/crates/openpaw-preview/src/ws.rs".to_owned(),
            additions: Some(120),
            deletions: Some(0),
            bytes: Some(4_096),
            unified_diff: None,
        }),
        EventType::FileModified => Body::FileModified(FileChange {
            path: "/Users/dev/src/openpaw/host/crates/openpaw-git/src/diff.rs".to_owned(),
            additions: Some(1),
            deletions: Some(1),
            bytes: Some(2_048),
            unified_diff: Some("@@\n-    Ok(out)\n+    Ok(out.into())\n".to_owned()),
        }),
        EventType::FileDeleted => {
            Body::FileDeleted(FileChange::new("/Users/dev/src/openpaw/build/stale.o"))
        }
        EventType::UsageUpdated => Body::UsageUpdated(UsageUpdated {
            input_tokens: 41_200,
            output_tokens: 1_830,
            cached_input_tokens: Some(38_000),
            cost_usd: Some(0.184),
            rate_limit_percent: Some(12.5),
            rate_limit_resets_at: Some(datetime!(2026-08-20 19:30:00 UTC)),
        }),
        EventType::ContextUpdated => Body::ContextUpdated(ContextUpdated::new(43_030, 272_000)),
    }
}

pub fn sample_plan() -> Plan {
    Plan {
        plan_id: "plan_1".to_owned(),
        title: Some("Preview proxy".to_owned()),
        steps: vec![
            PlanStep {
                id: "s1".to_owned(),
                title: "Strip hop-by-hop headers".to_owned(),
                status: PlanStepStatus::Completed,
            },
            PlanStep {
                id: "s2".to_owned(),
                title: "Add the websocket upgrade branch".to_owned(),
                status: PlanStepStatus::InProgress,
            },
            PlanStep {
                id: "s3".to_owned(),
                title: "Cover SSE".to_owned(),
                status: PlanStepStatus::Pending,
            },
            PlanStep {
                id: "s4".to_owned(),
                title: "Drop the polling fallback".to_owned(),
                status: PlanStepStatus::Cancelled,
            },
        ],
    }
}

/// A fully populated event of the given type.
pub fn sample_event(kind: EventType) -> Event {
    Event::new(
        &session(),
        AgentKind::ClaudeCode,
        &format!("sample:{}", kind.as_str()),
        timestamp(),
        sample_body(kind),
    )
    .with_seq(7)
    .with_context(
        Some("/Users/dev/src/openpaw".to_owned()),
        Some("main".to_owned()),
    )
    .with_multiplexer_target(Some("work:2.0".to_owned()))
}

/// The permission inbox item, which is the richest projection.
pub fn sample_inbox_item() -> InboxItem {
    InboxItem::from_event(&sample_event(EventType::PermissionRequested))
        .expect("permission.requested always projects")
}

/// Walks up from this crate to the repository root.
pub fn repo_root() -> PathBuf {
    let mut dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    loop {
        if dir.join("protocol/json-schema/event.schema.json").is_file() {
            return dir;
        }
        assert!(
            dir.pop(),
            "walked past the filesystem root without finding protocol/json-schema"
        );
    }
}
