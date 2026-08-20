use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::risk::Risk;
use crate::wire_enum::wire_enum;

wire_enum! {
    /// Decision a device can take on an inbox item.
    pub enum ActionId {
        /// Allow this single invocation.
        ApproveOnce = "approve_once",
        /// Allow this invocation and remember the decision for the session.
        ApproveAlways = "approve_always",
        /// Refuse this single invocation.
        Deny = "deny",
        /// Refuse and remember the refusal for the session.
        DenyAlways = "deny_always",
        /// Reply to a question with text or a choice.
        Answer = "answer",
        /// Interrupt the agent.
        Stop = "stop",
        /// Dismiss a purely informational item.
        Acknowledge = "acknowledge",
    }
}

impl ActionId {
    /// True for the two decisions that let a pending operation proceed.
    ///
    /// This is the predicate that gates
    /// [`Risk::requires_detail_expansion`](crate::Risk::requires_detail_expansion):
    /// a client must refuse to send an approval until the full detail has been
    /// shown, but must never block a denial on the same condition. A denial the
    /// host rejects costs nothing; a denial the UI blocks costs everything.
    /// Both the device and the host enforce it, so the classification lives here
    /// rather than being restated at each call site.
    pub const fn is_approval(&self) -> bool {
        matches!(self, ActionId::ApproveOnce | ActionId::ApproveAlways)
    }

    /// True for the two decisions that refuse a pending operation.
    pub const fn is_denial(&self) -> bool {
        matches!(self, ActionId::Deny | ActionId::DenyAlways)
    }
}

wire_enum! {
    /// Author of a conversation turn.
    pub enum TurnRole {
        /// The human operator.
        User = "user",
        /// The agent.
        Assistant = "assistant",
    }
}

wire_enum! {
    /// Which stream a streamed turn fragment belongs to.
    pub enum DeltaKind {
        /// Visible assistant text.
        Text = "text",
        /// Reasoning summary text.
        Thinking = "thinking",
    }
}

wire_enum! {
    /// Standard stream a tool output chunk came from.
    pub enum StdStream {
        /// Standard output.
        Stdout = "stdout",
        /// Standard error.
        Stderr = "stderr",
    }
}

wire_enum! {
    /// Who resolved a permission request.
    pub enum DecidedBy {
        /// A paired device answered.
        Device = "device",
        /// The operator answered in the terminal.
        Terminal = "terminal",
        /// A stored policy answered automatically.
        Policy = "policy",
        /// The request expired without an answer.
        Timeout = "timeout",
    }
}

wire_enum! {
    /// Lifecycle state of one plan step.
    pub enum PlanStepStatus {
        /// Not started.
        Pending = "pending",
        /// Being worked on.
        InProgress = "in_progress",
        /// Finished.
        Completed = "completed",
        /// Abandoned.
        Cancelled = "cancelled",
    }
}

/// Payload of `agent.started`, `agent.working`, `agent.completed` and
/// `agent.failed`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct AgentLifecycle {
    /// Free-form explanation, e.g. the stop reason or the failure message.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// Process exit code when the agent terminated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    /// Short human readable session title.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

/// Payload of `turn.started`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TurnStarted {
    /// Identifier of the turn inside the session.
    pub turn_id: String,
    /// Who is speaking.
    pub role: TurnRole,
    /// Opening text when it is already known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

/// Payload of `turn.delta`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TurnDelta {
    /// Turn this fragment belongs to.
    pub turn_id: String,
    /// The fragment itself.
    pub delta: String,
    /// Whether the fragment is visible text or reasoning.
    pub kind: DeltaKind,
}

/// Payload of `turn.completed`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TurnCompleted {
    /// Turn that finished.
    pub turn_id: String,
    /// Who spoke.
    pub role: TurnRole,
    /// Full text of the turn.
    pub text: String,
    /// Full reasoning summary when the agent exposed one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thinking: Option<String>,
}

/// Payload of `tool.started`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolStarted {
    /// Agent-assigned call identifier, used to correlate output and completion.
    pub call_id: String,
    /// Tool name as the agent reported it.
    pub tool: String,
    /// One line summary suitable for a notification.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// Full command line for shell-like tools.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    /// Filesystem paths the call touches.
    #[serde(default)]
    pub paths: Vec<String>,
    /// Classification driving the approval UI.
    pub risk: Risk,
}

/// Payload of `tool.output`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolOutput {
    /// Call this chunk belongs to.
    pub call_id: String,
    /// The output fragment.
    pub chunk: String,
    /// Which stream produced it.
    pub stream: StdStream,
    /// True when the host dropped bytes to stay inside its output budget.
    pub truncated: bool,
}

/// Payload of `tool.completed`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolCompleted {
    /// Call that finished.
    pub call_id: String,
    /// Exit code for process-backed tools.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    /// Wall clock duration in milliseconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    /// One line result summary.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
}

/// Payload of `tool.failed`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolFailed {
    /// Call that failed.
    pub call_id: String,
    /// Error text reported by the agent or the process.
    pub error: String,
    /// Exit code when the failure came from a process.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
}

/// Payload of `permission.requested`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PermissionRequested {
    /// Identifier the agent expects back with the decision.
    pub request_id: String,
    /// Tool awaiting approval.
    pub tool: String,
    /// One line summary suitable for a notification.
    pub summary: String,
    /// Full command line when the tool is shell-like.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    /// Filesystem paths the call would touch.
    #[serde(default)]
    pub paths: Vec<String>,
    /// Classification driving the approval UI.
    pub risk: Risk,
    /// Decisions the agent will accept.
    pub actions: Vec<ActionId>,
    /// Point after which the request is no longer answerable.
    #[serde(
        default,
        with = "time::serde::rfc3339::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub expires_at: Option<OffsetDateTime>,
}

/// Payload of `permission.resolved`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PermissionResolved {
    /// Request that was resolved.
    pub request_id: String,
    /// The decision taken.
    pub decision: ActionId,
    /// Where the decision came from.
    pub decided_by: DecidedBy,
    /// Device that decided, when `decided_by` is `device`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
}

/// Payload of `question.requested`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuestionRequested {
    /// Identifier the agent expects back with the answer.
    pub request_id: String,
    /// The question text.
    pub question: String,
    /// Offered choices, empty when the question is open ended.
    #[serde(default)]
    pub choices: Vec<String>,
    /// True when an answer outside `choices` is acceptable.
    pub allows_free_text: bool,
}

/// Payload of `question.answered`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuestionAnswered {
    /// Request that was answered.
    pub request_id: String,
    /// The answer text.
    pub answer: String,
}

/// One step of a plan.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanStep {
    /// Stable step identifier inside the plan.
    pub id: String,
    /// Step description.
    pub title: String,
    /// Current state.
    pub status: PlanStepStatus,
}

/// Payload of `plan.created` and `plan.updated`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Plan {
    /// Stable plan identifier inside the session.
    pub plan_id: String,
    /// Plan title when the agent supplied one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Ordered steps.
    #[serde(default)]
    pub steps: Vec<PlanStep>,
}

/// Payload of `file.read`, `file.created`, `file.modified` and `file.deleted`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FileChange {
    /// Absolute path of the file.
    pub path: String,
    /// Lines added.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub additions: Option<u32>,
    /// Lines removed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deletions: Option<u32>,
    /// Resulting file size in bytes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bytes: Option<u64>,
    /// Unified diff of the change, when the host captured one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unified_diff: Option<String>,
}

impl FileChange {
    /// A change that only records the path.
    pub fn new(path: impl Into<String>) -> FileChange {
        FileChange {
            path: path.into(),
            additions: None,
            deletions: None,
            bytes: None,
            unified_diff: None,
        }
    }
}

/// Payload of `usage.updated`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UsageUpdated {
    /// Cumulative prompt tokens.
    pub input_tokens: u64,
    /// Cumulative completion tokens.
    pub output_tokens: u64,
    /// Cumulative prompt tokens served from cache.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cached_input_tokens: Option<u64>,
    /// Cumulative cost in US dollars.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
    /// Percentage of the provider rate limit window already consumed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rate_limit_percent: Option<f64>,
    /// When the rate limit window resets.
    #[serde(
        default,
        with = "time::serde::rfc3339::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub rate_limit_resets_at: Option<OffsetDateTime>,
}

impl UsageUpdated {
    /// Usage with only the two mandatory counters populated.
    pub fn new(input_tokens: u64, output_tokens: u64) -> UsageUpdated {
        UsageUpdated {
            input_tokens,
            output_tokens,
            cached_input_tokens: None,
            cost_usd: None,
            rate_limit_percent: None,
            rate_limit_resets_at: None,
        }
    }
}

/// Payload of `context.updated`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ContextUpdated {
    /// Tokens currently occupying the context window.
    pub used_tokens: u64,
    /// Size of the context window.
    pub max_tokens: u64,
    /// `used_tokens / max_tokens` as a percentage.
    pub percent_used: f64,
}

impl ContextUpdated {
    /// Computes `percent_used` from the two counters.
    ///
    /// A `max_tokens` of zero cannot occur on the wire (the schema requires a
    /// minimum of 1) and is reported as fully consumed rather than dividing by
    /// zero. The result is clamped to the schema's 0..=100 range.
    pub fn new(used_tokens: u64, max_tokens: u64) -> ContextUpdated {
        let percent_used = if max_tokens == 0 {
            100.0
        } else {
            ((used_tokens as f64 / max_tokens as f64) * 100.0).min(100.0)
        };
        ContextUpdated {
            used_tokens,
            max_tokens,
            percent_used,
        }
    }
}
