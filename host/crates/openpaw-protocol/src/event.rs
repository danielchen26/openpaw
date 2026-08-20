use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::PROTOCOL_VERSION;
use crate::agent::AgentKind;
use crate::ids::{EventId, SessionId};
use crate::payload::{
    AgentLifecycle, ContextUpdated, FileChange, PermissionRequested, PermissionResolved, Plan,
    QuestionAnswered, QuestionRequested, ToolCompleted, ToolFailed, ToolOutput, ToolStarted,
    TurnCompleted, TurnDelta, TurnStarted, UsageUpdated,
};
use crate::wire_enum::wire_enum;

wire_enum! {
    /// Discriminant of [`Body`], mirroring `event.schema.json#/$defs/eventType`.
    pub enum EventType {
        /// A session was discovered or launched.
        AgentStarted = "agent.started",
        /// The agent began or resumed producing output.
        AgentWorking = "agent.working",
        /// The agent finished its turn and is idle.
        AgentCompleted = "agent.completed",
        /// The agent stopped because of an error.
        AgentFailed = "agent.failed",
        /// A conversation turn started.
        TurnStarted = "turn.started",
        /// A fragment of a streaming turn.
        TurnDelta = "turn.delta",
        /// A conversation turn finished.
        TurnCompleted = "turn.completed",
        /// A tool call started.
        ToolStarted = "tool.started",
        /// A chunk of tool output.
        ToolOutput = "tool.output",
        /// A tool call succeeded.
        ToolCompleted = "tool.completed",
        /// A tool call failed.
        ToolFailed = "tool.failed",
        /// The agent is blocked on an approval decision.
        PermissionRequested = "permission.requested",
        /// An approval decision was recorded.
        PermissionResolved = "permission.resolved",
        /// The agent is blocked on a question.
        QuestionRequested = "question.requested",
        /// A question was answered.
        QuestionAnswered = "question.answered",
        /// A plan was published.
        PlanCreated = "plan.created",
        /// A published plan changed.
        PlanUpdated = "plan.updated",
        /// A file was read.
        FileRead = "file.read",
        /// A file was created.
        FileCreated = "file.created",
        /// A file was modified.
        FileModified = "file.modified",
        /// A file was deleted.
        FileDeleted = "file.deleted",
        /// Token and cost counters changed.
        UsageUpdated = "usage.updated",
        /// Context window occupancy changed.
        ContextUpdated = "context.updated",
    }
}

/// Discriminated payload of an [`Event`].
///
/// Serialized adjacently as `{"type": ..., "payload": {...}}` and flattened
/// into the envelope, which is exactly the shape the JSON schema requires.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload")]
pub enum Body {
    /// See [`EventType::AgentStarted`].
    #[serde(rename = "agent.started")]
    AgentStarted(AgentLifecycle),
    /// See [`EventType::AgentWorking`].
    #[serde(rename = "agent.working")]
    AgentWorking(AgentLifecycle),
    /// See [`EventType::AgentCompleted`].
    #[serde(rename = "agent.completed")]
    AgentCompleted(AgentLifecycle),
    /// See [`EventType::AgentFailed`].
    #[serde(rename = "agent.failed")]
    AgentFailed(AgentLifecycle),
    /// See [`EventType::TurnStarted`].
    #[serde(rename = "turn.started")]
    TurnStarted(TurnStarted),
    /// See [`EventType::TurnDelta`].
    #[serde(rename = "turn.delta")]
    TurnDelta(TurnDelta),
    /// See [`EventType::TurnCompleted`].
    #[serde(rename = "turn.completed")]
    TurnCompleted(TurnCompleted),
    /// See [`EventType::ToolStarted`].
    #[serde(rename = "tool.started")]
    ToolStarted(ToolStarted),
    /// See [`EventType::ToolOutput`].
    #[serde(rename = "tool.output")]
    ToolOutput(ToolOutput),
    /// See [`EventType::ToolCompleted`].
    #[serde(rename = "tool.completed")]
    ToolCompleted(ToolCompleted),
    /// See [`EventType::ToolFailed`].
    #[serde(rename = "tool.failed")]
    ToolFailed(ToolFailed),
    /// See [`EventType::PermissionRequested`].
    #[serde(rename = "permission.requested")]
    PermissionRequested(PermissionRequested),
    /// See [`EventType::PermissionResolved`].
    #[serde(rename = "permission.resolved")]
    PermissionResolved(PermissionResolved),
    /// See [`EventType::QuestionRequested`].
    #[serde(rename = "question.requested")]
    QuestionRequested(QuestionRequested),
    /// See [`EventType::QuestionAnswered`].
    #[serde(rename = "question.answered")]
    QuestionAnswered(QuestionAnswered),
    /// See [`EventType::PlanCreated`].
    #[serde(rename = "plan.created")]
    PlanCreated(Plan),
    /// See [`EventType::PlanUpdated`].
    #[serde(rename = "plan.updated")]
    PlanUpdated(Plan),
    /// See [`EventType::FileRead`].
    #[serde(rename = "file.read")]
    FileRead(FileChange),
    /// See [`EventType::FileCreated`].
    #[serde(rename = "file.created")]
    FileCreated(FileChange),
    /// See [`EventType::FileModified`].
    #[serde(rename = "file.modified")]
    FileModified(FileChange),
    /// See [`EventType::FileDeleted`].
    #[serde(rename = "file.deleted")]
    FileDeleted(FileChange),
    /// See [`EventType::UsageUpdated`].
    #[serde(rename = "usage.updated")]
    UsageUpdated(UsageUpdated),
    /// See [`EventType::ContextUpdated`].
    #[serde(rename = "context.updated")]
    ContextUpdated(ContextUpdated),
}

impl Body {
    /// The discriminant of this payload.
    pub const fn kind(&self) -> EventType {
        match self {
            Body::AgentStarted(_) => EventType::AgentStarted,
            Body::AgentWorking(_) => EventType::AgentWorking,
            Body::AgentCompleted(_) => EventType::AgentCompleted,
            Body::AgentFailed(_) => EventType::AgentFailed,
            Body::TurnStarted(_) => EventType::TurnStarted,
            Body::TurnDelta(_) => EventType::TurnDelta,
            Body::TurnCompleted(_) => EventType::TurnCompleted,
            Body::ToolStarted(_) => EventType::ToolStarted,
            Body::ToolOutput(_) => EventType::ToolOutput,
            Body::ToolCompleted(_) => EventType::ToolCompleted,
            Body::ToolFailed(_) => EventType::ToolFailed,
            Body::PermissionRequested(_) => EventType::PermissionRequested,
            Body::PermissionResolved(_) => EventType::PermissionResolved,
            Body::QuestionRequested(_) => EventType::QuestionRequested,
            Body::QuestionAnswered(_) => EventType::QuestionAnswered,
            Body::PlanCreated(_) => EventType::PlanCreated,
            Body::PlanUpdated(_) => EventType::PlanUpdated,
            Body::FileRead(_) => EventType::FileRead,
            Body::FileCreated(_) => EventType::FileCreated,
            Body::FileModified(_) => EventType::FileModified,
            Body::FileDeleted(_) => EventType::FileDeleted,
            Body::UsageUpdated(_) => EventType::UsageUpdated,
            Body::ContextUpdated(_) => EventType::ContextUpdated,
        }
    }
}

/// One normalized observation about an agent session.
///
/// Field order matters: it is the on-the-wire key order both protocol
/// implementations emit.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Event {
    /// Always [`PROTOCOL_VERSION`].
    pub version: String,
    /// Content addressed identifier, stable across re-reads of the source.
    pub event_id: EventId,
    /// Session this event belongs to.
    pub session_id: SessionId,
    /// Agent that produced the source data.
    pub agent: AgentKind,
    /// Monotonic per session, assigned in source order.
    pub seq: u64,
    /// When the source recorded the observation.
    #[serde(with = "time::serde::rfc3339")]
    pub timestamp: OffsetDateTime,
    /// Working directory of the session, when known.
    #[serde(default)]
    pub cwd: Option<String>,
    /// Git branch checked out in `cwd`, when known.
    #[serde(default)]
    pub git_branch: Option<String>,
    /// Multiplexer target the session lives in, e.g. a tmux `work:2.0`.
    #[serde(default)]
    pub multiplexer_target: Option<String>,
    /// Type discriminant and payload.
    #[serde(flatten)]
    pub body: Body,
}

impl Event {
    /// Builds an event with `seq` 0 and no context.
    ///
    /// `source_key` must uniquely name the origin of this event inside the
    /// session so that [`EventId::derive`] makes re-ingestion idempotent.
    pub fn new(
        session: &SessionId,
        agent: AgentKind,
        source_key: &str,
        timestamp: OffsetDateTime,
        body: Body,
    ) -> Event {
        Event {
            version: PROTOCOL_VERSION.to_owned(),
            event_id: EventId::derive(session, source_key),
            session_id: session.clone(),
            agent,
            seq: 0,
            timestamp,
            cwd: None,
            git_branch: None,
            multiplexer_target: None,
            body,
        }
    }

    /// The type discriminant of this event.
    pub const fn kind(&self) -> EventType {
        self.body.kind()
    }

    /// Assigns the per-session sequence number.
    pub fn with_seq(mut self, seq: u64) -> Event {
        self.seq = seq;
        self
    }

    /// Attaches the working directory and git branch.
    pub fn with_context(mut self, cwd: Option<String>, git_branch: Option<String>) -> Event {
        self.cwd = cwd;
        self.git_branch = git_branch;
        self
    }

    /// Attaches the multiplexer target the session was discovered in.
    pub fn with_multiplexer_target(mut self, target: Option<String>) -> Event {
        self.multiplexer_target = target;
        self
    }
}
