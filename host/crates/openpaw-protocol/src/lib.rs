//! Normalized event protocol shared by every OpenPaw host component.
//!
//! This crate is the Rust half of a byte-compatible pair; `OpenPawProtocol`
//! (Swift) mirrors it. The wire format is defined by
//! `protocol/json-schema/event.schema.json` and
//! `protocol/json-schema/inbox-item.schema.json`.
//!
//! Wire rules that both halves must honour:
//!
//! * The envelope always emits `cwd`, `git_branch` and `multiplexer_target`,
//!   serialized as `null` when absent.
//! * Payload `Option` fields are omitted entirely when `None`.
//! * Timestamps are RFC 3339.
//! * Envelope key order is `version, event_id, session_id, agent, seq,
//!   timestamp, cwd, git_branch, multiplexer_target, type, payload`.

mod agent;
mod error;
mod event;
mod ids;
mod inbox;
mod payload;
mod provider_repo;
mod risk;
pub mod signing;
mod util;
mod wire_enum;

pub use agent::AgentKind;
pub use error::{ParseEnumError, ParseIdError};
pub use event::{Body, Event, EventType};
pub use ids::{EventId, InboxId, SessionId};
pub use inbox::{InboxCategory, InboxItem, InboxStatus};
pub use payload::{
    ActionId, AgentLifecycle, ContextUpdated, DecidedBy, DeltaKind, FileChange,
    PermissionRequested, PermissionResolved, Plan, PlanStep, PlanStepStatus, QuestionAnswered,
    QuestionRequested, StdStream, ToolCompleted, ToolFailed, ToolOutput, ToolStarted,
    TurnCompleted, TurnDelta, TurnRole, TurnStarted, UsageUpdated,
};
pub use provider_repo::{
    ProviderAuthorizationStart, ProviderAuthorizationState, ProviderAuthorizationStatus,
    ProviderConnectionState, ProviderId, ProviderRemoteRevokeResult, ProviderRepo,
    ProviderRepoPage, ProviderStatus, RepoImportProgress, RepoImportRequest, RepoImportState,
    RepoRegisterRequest, redact_url_credentials,
};
pub use risk::{Risk, RiskClass, extract_tool_command, extract_tool_paths};

/// Wire protocol version carried in every [`Event`].
pub const PROTOCOL_VERSION: &str = "1";
