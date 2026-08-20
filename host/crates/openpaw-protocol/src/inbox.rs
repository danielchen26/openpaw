use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::agent::AgentKind;
use crate::event::{Body, Event};
use crate::ids::{EventId, InboxId, SessionId};
use crate::payload::{ActionId, Plan, PlanStepStatus};
use crate::risk::Risk;
use crate::wire_enum::wire_enum;

wire_enum! {
    /// Why an inbox item exists.
    pub enum InboxCategory {
        /// The agent is blocked waiting for approval.
        Permission = "permission",
        /// The agent is blocked waiting for an answer.
        Question = "question",
        /// A plan was published or changed.
        Plan = "plan",
        /// A tool call or the agent itself failed.
        ToolFailure = "tool_failure",
        /// The agent finished its turn.
        Completion = "completion",
        /// The context window is nearly full.
        ContextWarning = "context_warning",
        /// The provider rate limit window is nearly exhausted.
        RateLimit = "rate_limit",
        /// A long running background job changed state.
        BackgroundJob = "background_job",
    }
}

wire_enum! {
    /// Lifecycle of an inbox item.
    pub enum InboxStatus {
        /// Awaiting a decision.
        Pending = "pending",
        /// A decision was recorded.
        Resolved = "resolved",
        /// Dismissed without a decision.
        Dismissed = "dismissed",
        /// The window for deciding closed.
        Expired = "expired",
    }
}

/// Context occupancy at or above this percentage raises a warning item.
const CONTEXT_WARNING_PERCENT: f64 = 85.0;

/// Rate limit consumption at or above this percentage raises a warning item.
const RATE_LIMIT_WARNING_PERCENT: f64 = 90.0;

/// An actionable projection of one event.
///
/// Actions carry a one-time token minted by the host; a push notification alone
/// is never sufficient to authorize a decision, which is why `action_token` is
/// always `None` here.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InboxItem {
    /// Content addressed identifier, derived from `source_event_id`.
    pub id: InboxId,
    /// Session the item belongs to.
    pub session_id: SessionId,
    /// Agent that raised it.
    pub agent: AgentKind,
    /// Why the item exists.
    pub category: InboxCategory,
    /// One line notification-ready summary.
    pub title: String,
    /// Full detail the client must reveal before allowing a risky approval.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// Raw command line when the underlying event carried one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    /// Classification of the underlying operation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub risk: Option<Risk>,
    /// Decisions a device may take.
    #[serde(default)]
    pub actions: Vec<ActionId>,
    /// One-time bearer for `POST /v1/inbox/{id}/resolve`, minted by the host.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action_token: Option<String>,
    /// Underlying permission or question request id, so a later
    /// `permission.resolved` can be correlated back to this item.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    /// Timestamp of the source event.
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
    /// Point after which the item can no longer be resolved.
    #[serde(
        default,
        with = "time::serde::rfc3339::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub expires_at: Option<OffsetDateTime>,
    /// Lifecycle state.
    pub status: InboxStatus,
    /// Human readable outcome once resolved.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
    /// Event this item was projected from.
    pub source_event_id: EventId,
}

/// The category-specific part of a projection.
struct Projection {
    category: InboxCategory,
    title: String,
    detail: Option<String>,
    command: Option<String>,
    risk: Option<Risk>,
    actions: Vec<ActionId>,
    request_id: Option<String>,
    expires_at: Option<OffsetDateTime>,
}

impl Projection {
    /// A purely informational projection: acknowledge and move on.
    fn informational(category: InboxCategory, title: String, detail: Option<String>) -> Projection {
        Projection {
            category,
            title,
            detail,
            command: None,
            risk: None,
            actions: vec![ActionId::Acknowledge],
            request_id: None,
            expires_at: None,
        }
    }
}

impl InboxItem {
    /// Projects an event into an inbox item, or `None` when the event needs no
    /// human decision and no notification.
    pub fn from_event(event: &Event) -> Option<InboxItem> {
        let projection = project(event)?;
        Some(InboxItem {
            id: InboxId::derive(&event.event_id),
            session_id: event.session_id.clone(),
            agent: event.agent,
            category: projection.category,
            title: projection.title,
            detail: projection.detail,
            command: projection.command,
            risk: projection.risk,
            actions: projection.actions,
            action_token: None,
            request_id: projection.request_id,
            created_at: event.timestamp,
            expires_at: projection.expires_at,
            status: InboxStatus::Pending,
            resolution: None,
            source_event_id: event.event_id.clone(),
        })
    }
}

fn project(event: &Event) -> Option<Projection> {
    match &event.body {
        Body::PermissionRequested(payload) => Some(Projection {
            category: InboxCategory::Permission,
            title: payload.summary.clone(),
            detail: Some(
                payload
                    .command
                    .clone()
                    .unwrap_or_else(|| payload.summary.clone()),
            ),
            command: payload.command.clone(),
            risk: Some(payload.risk.clone()),
            actions: payload.actions.clone(),
            request_id: Some(payload.request_id.clone()),
            expires_at: payload.expires_at,
        }),
        Body::QuestionRequested(payload) => Some(Projection {
            category: InboxCategory::Question,
            title: payload.question.clone(),
            detail: if payload.choices.is_empty() {
                None
            } else {
                Some(payload.choices.join(", "))
            },
            command: None,
            risk: None,
            actions: vec![ActionId::Answer],
            request_id: Some(payload.request_id.clone()),
            expires_at: None,
        }),
        Body::PlanCreated(plan) | Body::PlanUpdated(plan) => Some(Projection::informational(
            InboxCategory::Plan,
            plan_title(plan),
            plan_detail(plan),
        )),
        Body::ToolFailed(payload) => Some(Projection::informational(
            InboxCategory::ToolFailure,
            format!("Tool call {} failed", payload.call_id),
            Some(payload.error.clone()),
        )),
        Body::AgentCompleted(payload) => Some(Projection::informational(
            InboxCategory::Completion,
            payload
                .title
                .clone()
                .unwrap_or_else(|| "Agent completed".to_owned()),
            payload.reason.clone(),
        )),
        Body::AgentFailed(payload) => Some(Projection::informational(
            InboxCategory::ToolFailure,
            payload
                .title
                .clone()
                .unwrap_or_else(|| "Agent failed".to_owned()),
            payload.reason.clone(),
        )),
        Body::ContextUpdated(payload) if payload.percent_used >= CONTEXT_WARNING_PERCENT => {
            Some(Projection::informational(
                InboxCategory::ContextWarning,
                format!(
                    "Context window {}% used",
                    payload.percent_used.round() as i64
                ),
                Some(format!(
                    "{} of {} tokens used",
                    payload.used_tokens, payload.max_tokens
                )),
            ))
        }
        Body::UsageUpdated(payload)
            if payload
                .rate_limit_percent
                .is_some_and(|percent| percent >= RATE_LIMIT_WARNING_PERCENT) =>
        {
            let percent = payload.rate_limit_percent.unwrap_or_default();
            Some(Projection::informational(
                InboxCategory::RateLimit,
                format!("Rate limit {}% consumed", percent.round() as i64),
                payload.rate_limit_resets_at.map(|at| {
                    format!(
                        "resets at {}",
                        at.format(&time::format_description::well_known::Rfc3339)
                            .unwrap_or_else(|_| at.to_string())
                    )
                }),
            ))
        }
        _ => None,
    }
}

fn plan_title(plan: &Plan) -> String {
    let total = plan.steps.len();
    let completed = plan
        .steps
        .iter()
        .filter(|step| step.status == PlanStepStatus::Completed)
        .count();
    let base = plan.title.as_deref().unwrap_or("Plan");
    format!("{base} ({completed}/{total} steps complete)")
}

fn plan_detail(plan: &Plan) -> Option<String> {
    if plan.steps.is_empty() {
        return None;
    }
    Some(
        plan.steps
            .iter()
            .map(|step| {
                let marker = match step.status {
                    PlanStepStatus::Pending => "[ ]",
                    PlanStepStatus::InProgress => "[~]",
                    PlanStepStatus::Completed => "[x]",
                    PlanStepStatus::Cancelled => "[-]",
                };
                format!("{marker} {}", step.title)
            })
            .collect::<Vec<String>>()
            .join("\n"),
    )
}
