//! `InboxItem::from_event` projection: every actionable category, every
//! threshold boundary, and the events that must not raise an item.

mod common;

use common::{expiry, sample_event, sample_plan, session, timestamp};
use openpaw_protocol::{
    ActionId, AgentKind, AgentLifecycle, Body, ContextUpdated, Event, EventType, InboxCategory,
    InboxId, InboxItem, InboxStatus, Plan, RiskClass, UsageUpdated,
};

fn project(kind: EventType) -> InboxItem {
    InboxItem::from_event(&sample_event(kind))
        .unwrap_or_else(|| panic!("{kind} should project to an inbox item"))
}

fn event_with(body: Body) -> Event {
    Event::new(
        &session(),
        AgentKind::ClaudeCode,
        "projection",
        timestamp(),
        body,
    )
}

#[test]
fn permission_requests_carry_command_risk_actions_and_expiry() {
    let source = sample_event(EventType::PermissionRequested);
    let item = InboxItem::from_event(&source).unwrap();

    assert_eq!(item.category, InboxCategory::Permission);
    assert_eq!(item.title, "Clean build directory");
    assert_eq!(
        item.detail.as_deref(),
        Some("rm -rf /Users/dev/src/openpaw/build")
    );
    assert_eq!(
        item.command.as_deref(),
        Some("rm -rf /Users/dev/src/openpaw/build")
    );
    let risk = item.risk.as_ref().expect("permission items carry a risk");
    assert_eq!(risk.class, RiskClass::DestructiveShell);
    assert!(risk.requires_detail_expansion);
    assert_eq!(
        item.actions,
        vec![
            ActionId::ApproveOnce,
            ActionId::ApproveAlways,
            ActionId::Deny
        ]
    );
    assert_eq!(item.expires_at, Some(expiry()));
    assert_eq!(item.request_id.as_deref(), Some("req_1"));

    // Identity and provenance.
    assert_eq!(item.id, InboxId::derive(&source.event_id));
    assert_eq!(item.source_event_id, source.event_id);
    assert_eq!(item.session_id, source.session_id);
    assert_eq!(item.agent, source.agent);
    assert_eq!(item.created_at, source.timestamp);

    // The host mints the token, never the projection.
    assert_eq!(item.action_token, None);
    assert_eq!(item.status, InboxStatus::Pending);
    assert_eq!(item.resolution, None);
}

#[test]
fn permission_detail_falls_back_to_the_summary_without_a_command() {
    let mut source = sample_event(EventType::PermissionRequested);
    if let Body::PermissionRequested(payload) = &mut source.body {
        payload.command = None;
    }
    let item = InboxItem::from_event(&source).unwrap();
    assert_eq!(item.detail.as_deref(), Some("Clean build directory"));
    assert_eq!(item.command, None);
}

#[test]
fn questions_offer_the_answer_action_and_list_their_choices() {
    let item = project(EventType::QuestionRequested);
    assert_eq!(item.category, InboxCategory::Question);
    assert_eq!(item.title, "Should the migration run against production?");
    assert_eq!(item.detail.as_deref(), Some("yes, no"));
    assert_eq!(item.actions, vec![ActionId::Answer]);
    assert_eq!(item.request_id.as_deref(), Some("req_2"));
    assert_eq!(item.risk, None);
}

#[test]
fn open_ended_questions_have_no_detail() {
    let mut source = sample_event(EventType::QuestionRequested);
    if let Body::QuestionRequested(payload) = &mut source.body {
        payload.choices.clear();
    }
    assert_eq!(InboxItem::from_event(&source).unwrap().detail, None);
}

#[test]
fn plans_summarise_step_counts_and_render_step_lines() {
    for kind in [EventType::PlanCreated, EventType::PlanUpdated] {
        let item = project(kind);
        assert_eq!(item.category, InboxCategory::Plan);
        assert_eq!(item.title, "Preview proxy (1/4 steps complete)");
        assert_eq!(
            item.detail.as_deref(),
            Some(
                "[x] Strip hop-by-hop headers\n\
                 [~] Add the websocket upgrade branch\n\
                 [ ] Cover SSE\n\
                 [-] Drop the polling fallback"
            )
        );
        assert_eq!(item.actions, vec![ActionId::Acknowledge]);
        assert_eq!(item.request_id, None);
    }
}

#[test]
fn untitled_and_empty_plans_still_project() {
    let mut plan = sample_plan();
    plan.title = None;
    let titled = InboxItem::from_event(&event_with(Body::PlanCreated(plan))).unwrap();
    assert_eq!(titled.title, "Plan (1/4 steps complete)");

    let empty = InboxItem::from_event(&event_with(Body::PlanUpdated(Plan {
        plan_id: "plan_2".to_owned(),
        title: Some("Empty".to_owned()),
        steps: Vec::new(),
    })))
    .unwrap();
    assert_eq!(empty.title, "Empty (0/0 steps complete)");
    assert_eq!(empty.detail, None);
}

#[test]
fn tool_failures_and_agent_failures_share_the_tool_failure_category() {
    let tool = project(EventType::ToolFailed);
    assert_eq!(tool.category, InboxCategory::ToolFailure);
    assert_eq!(tool.title, "Tool call call_9f2a1d failed");
    assert_eq!(tool.detail.as_deref(), Some("file not found"));
    assert_eq!(tool.actions, vec![ActionId::Acknowledge]);

    let agent = project(EventType::AgentFailed);
    assert_eq!(agent.category, InboxCategory::ToolFailure);
    assert_eq!(agent.title, "Agent failed");
    assert_eq!(agent.detail.as_deref(), Some("provider returned 529"));
}

#[test]
fn completions_use_the_session_title_when_present() {
    let item = project(EventType::AgentCompleted);
    assert_eq!(item.category, InboxCategory::Completion);
    assert_eq!(item.title, "Wire up the preview proxy");
    assert_eq!(item.detail.as_deref(), Some("end_turn"));

    let untitled =
        InboxItem::from_event(&event_with(Body::AgentCompleted(AgentLifecycle::default())))
            .unwrap();
    assert_eq!(untitled.title, "Agent completed");
    assert_eq!(untitled.detail, None);
}

#[test]
fn context_warnings_fire_only_at_or_above_eighty_five_percent() {
    let quiet = ContextUpdated {
        used_tokens: 84_000,
        max_tokens: 100_000,
        percent_used: 84.0,
    };
    assert!(InboxItem::from_event(&event_with(Body::ContextUpdated(quiet))).is_none());

    let boundary = ContextUpdated {
        used_tokens: 85_000,
        max_tokens: 100_000,
        percent_used: 85.0,
    };
    let item = InboxItem::from_event(&event_with(Body::ContextUpdated(boundary))).unwrap();
    assert_eq!(item.category, InboxCategory::ContextWarning);
    assert_eq!(item.title, "Context window 85% used");
    assert_eq!(item.detail.as_deref(), Some("85000 of 100000 tokens used"));
    assert_eq!(item.actions, vec![ActionId::Acknowledge]);

    // The sample event sits well below the threshold.
    assert!(InboxItem::from_event(&sample_event(EventType::ContextUpdated)).is_none());
}

#[test]
fn rate_limit_warnings_fire_only_at_or_above_ninety_percent() {
    let mut usage = UsageUpdated::new(1_000, 100);
    usage.rate_limit_percent = Some(89.9);
    assert!(InboxItem::from_event(&event_with(Body::UsageUpdated(usage.clone()))).is_none());

    usage.rate_limit_percent = Some(90.0);
    usage.rate_limit_resets_at = Some(expiry());
    let item = InboxItem::from_event(&event_with(Body::UsageUpdated(usage.clone()))).unwrap();
    assert_eq!(item.category, InboxCategory::RateLimit);
    assert_eq!(item.title, "Rate limit 90% consumed");
    assert_eq!(
        item.detail.as_deref(),
        Some("resets at 2026-08-20T14:35:00Z")
    );

    usage.rate_limit_resets_at = None;
    assert_eq!(
        InboxItem::from_event(&event_with(Body::UsageUpdated(usage)))
            .unwrap()
            .detail,
        None
    );

    // Missing rate limit information never raises an item.
    let bare = UsageUpdated::new(10, 5);
    assert!(InboxItem::from_event(&event_with(Body::UsageUpdated(bare))).is_none());

    // The sample event reports 12.5%.
    assert!(InboxItem::from_event(&sample_event(EventType::UsageUpdated)).is_none());
}

#[test]
fn non_actionable_events_do_not_project() {
    let actionable = [
        EventType::PermissionRequested,
        EventType::QuestionRequested,
        EventType::PlanCreated,
        EventType::PlanUpdated,
        EventType::ToolFailed,
        EventType::AgentCompleted,
        EventType::AgentFailed,
    ];
    for kind in EventType::ALL {
        let projected = InboxItem::from_event(&sample_event(*kind)).is_some();
        let expected = actionable.contains(kind);
        assert_eq!(
            projected, expected,
            "{kind} projection expectation mismatch (the usage/context samples are below their thresholds)"
        );
    }
}

#[test]
fn inbox_items_round_trip_and_omit_absent_options() {
    let item = project(EventType::PermissionRequested);
    let value = serde_json::to_value(&item).unwrap();
    assert_eq!(value["id"], item.id.as_str());
    assert_eq!(value["category"], "permission");
    assert_eq!(value["status"], "pending");
    assert_eq!(value["created_at"], "2026-08-20T14:30:00Z");
    assert_eq!(value["expires_at"], "2026-08-20T14:35:00Z");
    assert!(value.get("action_token").is_none(), "None must be omitted");
    assert!(value.get("resolution").is_none(), "None must be omitted");
    assert!(value["actions"].is_array());

    let decoded: InboxItem = serde_json::from_value(value).unwrap();
    assert_eq!(decoded, item);

    // A minimal item omits every optional key except the ones it populates.
    let plan = project(EventType::PlanCreated);
    let plan_value = serde_json::to_value(&plan).unwrap();
    assert!(plan_value.get("command").is_none());
    assert!(plan_value.get("risk").is_none());
    assert!(plan_value.get("request_id").is_none());
    assert!(plan_value.get("expires_at").is_none());
}

/// The detail-expansion gate applies to approvals only. A denial blocked by the
/// client is strictly worse than a denial the host rejects, so this predicate is
/// single-sourced here for both the device and the host to use.
#[test]
fn only_approvals_are_gated_by_detail_expansion() {
    assert!(ActionId::ApproveOnce.is_approval());
    assert!(ActionId::ApproveAlways.is_approval());
    for action in [
        ActionId::Deny,
        ActionId::DenyAlways,
        ActionId::Answer,
        ActionId::Stop,
        ActionId::Acknowledge,
    ] {
        assert!(!action.is_approval(), "{action} must not be an approval");
    }

    assert!(ActionId::Deny.is_denial());
    assert!(ActionId::DenyAlways.is_denial());
    for action in [
        ActionId::ApproveOnce,
        ActionId::ApproveAlways,
        ActionId::Answer,
        ActionId::Stop,
        ActionId::Acknowledge,
    ] {
        assert!(!action.is_denial(), "{action} must not be a denial");
    }

    // Every action is classified at most one way, and the two sets are disjoint.
    for action in ActionId::ALL {
        assert!(!(action.is_approval() && action.is_denial()), "{action}");
    }

    // The gate is only ever consulted for items that actually carry a risk.
    let item = project(EventType::PermissionRequested);
    let risk = item.risk.as_ref().unwrap();
    assert!(risk.requires_detail_expansion);
    assert!(
        item.actions.iter().any(ActionId::is_approval),
        "a destructive permission still offers approvals, gated client side"
    );
    assert!(
        item.actions.iter().any(ActionId::is_denial),
        "and must always offer an ungated denial"
    );
}

#[test]
fn inbox_ids_are_derived_from_the_event_and_are_stable() {
    let source = sample_event(EventType::ToolFailed);
    let first = InboxItem::from_event(&source).unwrap();
    let second = InboxItem::from_event(&source).unwrap();
    assert_eq!(first.id, second.id);
    assert_eq!(first.id.as_str().len(), "inb_".len() + 24);
    assert!(first.id.as_str().starts_with("inb_"));

    let other = InboxItem::from_event(&sample_event(EventType::AgentFailed)).unwrap();
    assert_ne!(first.id, other.id);
}
