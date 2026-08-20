//! The inbox: reading actionable items and resolving them.
//!
//! Resolving is the single most consequential thing this daemon does, so the path
//! is deliberately paranoid. Four gates stand between a tap on a phone and an
//! agent proceeding:
//!
//! 1. the two-factor request check (bearer + HMAC) in [`crate::auth`];
//! 2. the `approvals.write` capability, which an `observer` device does not hold;
//! 3. a single-use action token with a 10-minute lifetime, so a stale push
//!    notification can never authorize anything;
//! 4. for anything the risk classifier flagged as needing expansion, an explicit
//!    `detail_acknowledged` — the operator must have actually looked at the
//!    `rm -rf` target, not just hit the green button in a notification.
//!
//! Only then is the decision written where the agent's own hook can read it.

use std::path::{Path, PathBuf};

use axum::extract::{Path as UrlPath, State};
use axum::{Extension, Json};
use openpaw_protocol::{
    ActionId, Body, DecidedBy, Event, InboxCategory, InboxId, InboxItem, InboxStatus,
    PermissionResolved, QuestionAnswered,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use time::OffsetDateTime;

use crate::AppState;
use crate::api::ApiError;
use crate::audit::AuditEntry;
use crate::auth::AuthedDevice;
use crate::bus::ClaimError;

/// Schema version of a decision file.
pub const DECISION_VERSION: &str = "1";

/// Query parameters for `GET /v1/inbox`.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct InboxQuery {
    /// `pending`, `resolved`, `dismissed` or `expired`.
    pub status: Option<String>,
}

/// Body of `POST /v1/inbox/{id}/resolve`.
///
/// Not `deny_unknown_fields`: clients across three platforms evolve at different
/// speeds, and rejecting a request because it carried one extra key would break
/// approvals for a version mismatch that does not matter.
#[derive(Debug, Clone, Deserialize)]
pub struct ResolveRequest {
    /// The decision.
    pub action: ActionId,
    /// The item's one-time token.
    pub action_token: String,
    /// Free-text answer, for question items.
    #[serde(default)]
    pub answer: Option<String>,
    /// Set when the operator expanded and read the full command detail.
    #[serde(default)]
    pub detail_acknowledged: bool,
}

/// Response of `POST /v1/inbox/{id}/resolve`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResolveResponse {
    /// `resolved` when the agent was told, `dismissed` for informational items.
    pub status: String,
    /// Id of the event published as a result. `null` for a dismissal, which
    /// produces no agent-visible fact.
    pub event_id: Option<String>,
}

/// What gets written to `<state_dir>/decisions/<request_id>.json`.
///
/// This file *is* the handoff protocol. An agent hook re-runs, finds the file
/// matching its `request_id`, and turns it into whatever its own CLI expects. It
/// is a file rather than a socket because hooks are short-lived processes that may
/// start after the decision was made, and a file is the only channel that is
/// already durable when that happens.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Decision {
    /// Schema version.
    pub version: String,
    /// The agent-side request this answers, verbatim.
    pub request_id: String,
    /// Inbox item that carried the decision.
    pub inbox_id: String,
    /// Session the request came from.
    pub session_id: String,
    /// Agent wire name.
    pub agent: String,
    /// The decision.
    pub action: ActionId,
    /// Free-text answer for question items.
    pub answer: Option<String>,
    /// Always `device` here; the enum exists because policy and timeout
    /// resolutions are also part of the protocol.
    pub decided_by: DecidedBy,
    /// Device that decided.
    pub device_id: String,
    /// Whether the operator expanded the detail before deciding.
    pub detail_acknowledged: bool,
    /// When the decision was made.
    #[serde(with = "time::serde::rfc3339")]
    pub decided_at: OffsetDateTime,
    /// Event the inbox item was projected from.
    pub source_event_id: String,
}

impl Decision {
    /// True when the agent should be told to proceed.
    ///
    /// Delegates to the protocol rather than re-matching the variants: which
    /// actions count as approvals is load-bearing security logic (it decides what
    /// the detail-expansion gate applies to), and it is defined once, in
    /// `openpaw-protocol`, for both the host and the app.
    pub fn approves(&self) -> bool {
        self.action.is_approval()
    }

    /// True when the agent should be told not to proceed.
    pub fn denies(&self) -> bool {
        self.action.is_denial()
    }

    /// True when the agent should stop what it is doing.
    ///
    /// Wider than [`Decision::denies`]: `stop` is not a denial of a specific
    /// request, but a hook that must translate a decision into approve-or-block
    /// has to treat it as a block. This mapping belongs to the hook protocol, not
    /// to the security predicate, which is why it is a separate method.
    pub fn halts(&self) -> bool {
        self.action.is_denial() || matches!(self.action, ActionId::Stop)
    }
}

/// Filename a decision for `request_id` lives under.
///
/// A request id comes from an agent's own transcript, so it is not trusted to be
/// a safe filename: every character outside `[A-Za-z0-9._-]` is folded to `_`.
/// Hooks must apply the same rule, which is why this is public.
pub fn decision_filename(request_id: &str) -> String {
    let mut safe: String = request_id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '_'
            }
        })
        .take(180)
        .collect();
    if safe.trim_matches('_').is_empty() {
        safe = format!("unknown-{}", crate::auth::sha256_hex(request_id.as_bytes()));
        safe.truncate(180);
    }
    format!("{safe}.json")
}

/// Write a decision atomically at mode 0600 and return its path.
pub async fn write_decision(dir: &Path, decision: &Decision) -> anyhow::Result<PathBuf> {
    let path = dir.join(decision_filename(&decision.request_id));
    let bytes = serde_json::to_vec_pretty(decision)?;
    let target = path.clone();
    tokio::task::spawn_blocking(move || crate::state::write_private_atomic(&target, &bytes))
        .await??;
    Ok(path)
}

/// Read a decision for `request_id`, if one has been written.
///
/// A malformed file is treated as absent: an agent hook must never be blocked or
/// crashed by a decision file someone hand-edited.
pub async fn read_decision(dir: &Path, request_id: &str) -> Option<Decision> {
    let path = dir.join(decision_filename(request_id));
    let bytes = tokio::fs::read(&path).await.ok()?;
    match serde_json::from_slice::<Decision>(&bytes) {
        Ok(decision) if decision.request_id == request_id => Some(decision),
        Ok(decision) => {
            // Two request ids that sanitize to the same filename. Refuse rather
            // than apply a decision meant for a different request.
            tracing::warn!(
                path = %path.display(),
                stored = %decision.request_id,
                wanted = %request_id,
                "decision file request id mismatch; ignoring"
            );
            None
        }
        Err(err) => {
            tracing::warn!(path = %path.display(), %err, "unreadable decision file; ignoring");
            None
        }
    }
}

/// `GET /v1/inbox`.
pub async fn list(
    State(app): State<AppState>,
    axum::extract::Query(query): axum::extract::Query<InboxQuery>,
) -> Result<Json<Vec<InboxItem>>, ApiError> {
    let status = match query
        .status
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        Some(raw) => Some(
            serde_json::from_value::<InboxStatus>(Value::String(raw.to_owned())).map_err(|_| {
                ApiError::bad_request("status must be one of pending, resolved, dismissed, expired")
            })?,
        ),
        None => None,
    };
    Ok(Json(app.bus.inbox(status)))
}

/// `POST /v1/inbox/{id}/resolve`.
pub async fn resolve(
    State(app): State<AppState>,
    Extension(device): Extension<AuthedDevice>,
    UrlPath(id): UrlPath<String>,
    Json(request): Json<ResolveRequest>,
) -> Result<Json<ResolveResponse>, ApiError> {
    let id: InboxId = id
        .parse()
        .map_err(|err| ApiError::bad_request(format!("invalid inbox id: {err}")))?;
    let action = action_name(request.action);

    let pending = app
        .bus
        .peek(&id)
        .ok_or_else(|| ApiError::not_found("unknown inbox item"))?;

    // Gate 4, checked before the token is spent so a refused request leaves the
    // item usable: the operator can expand the detail and try again.
    //
    // The gate applies to *approvals only*. The asymmetry is the whole point: a
    // denial the host rejects costs nothing, because the agent stays blocked and
    // the operator retries. A denial the host *blocks* costs everything, because
    // the operator's "no" never lands and the agent proceeds on its own. So `deny`
    // is always accepted, however dangerous the command is.
    let gated = request.action.is_approval()
        && pending
            .item
            .risk
            .as_ref()
            .is_some_and(|risk| risk.requires_detail_expansion);
    if gated && !request.detail_acknowledged {
        let reasons = pending
            .item
            .risk
            .as_ref()
            .map(|risk| risk.reasons.join("; "))
            .unwrap_or_default();
        let _ = app
            .audit
            .append(&AuditEntry::now(
                &device.device_id,
                "inbox.resolve",
                id.as_ref(),
                format!("rejected: detail not acknowledged ({reasons})"),
            ))
            .await;
        return Err(ApiError::bad_request(format!(
            "this action requires detail_acknowledged=true: {reasons}"
        )));
    }

    let claimed = app
        .bus
        .claim(&id, &request.action_token, &action)
        .map_err(|err| {
            tracing::warn!(inbox = %id, device = %device.device_id, %err, "action token refused");
            match err {
                ClaimError::Unknown => ApiError::not_found("unknown inbox item"),
                ClaimError::BadToken | ClaimError::Expired => ApiError::forbidden(err.to_string()),
                ClaimError::AlreadyResolved => ApiError::conflict(err.to_string()),
            }
        })?;

    let request_id = claimed.request_id().map(str::to_owned);
    let Some(request_id) = request_id else {
        // Informational item (a completion, a context warning): there is nothing
        // to tell the agent, so acknowledging it is a local dismissal.
        app.audit
            .append(&AuditEntry::now(
                &device.device_id,
                "inbox.dismiss",
                id.as_ref(),
                &action,
            ))
            .await
            .map_err(ApiError::internal)?;
        return Ok(Json(ResolveResponse {
            status: "dismissed".to_owned(),
            event_id: None,
        }));
    };

    let decision = Decision {
        version: DECISION_VERSION.to_owned(),
        request_id: request_id.clone(),
        inbox_id: id.as_ref().to_owned(),
        session_id: claimed.item.session_id.as_ref().to_owned(),
        agent: crate::supervisor::agent_name(claimed.item.agent),
        action: request.action,
        answer: request.answer.clone(),
        decided_by: DecidedBy::Device,
        device_id: device.device_id.clone(),
        detail_acknowledged: request.detail_acknowledged,
        decided_at: OffsetDateTime::now_utc(),
        source_event_id: claimed.item.source_event_id.as_ref().to_owned(),
    };

    // The decision file is the agent-visible effect, so it is written before the
    // item is reported resolved. If it fails, the claim is rolled back: the phone
    // must not show "approved" while the terminal still waits.
    let path = match write_decision(&app.store.decisions_dir(), &decision).await {
        Ok(path) => path,
        Err(err) => {
            app.bus.restore(claimed);
            let _ = app
                .audit
                .append(&AuditEntry::now(
                    &device.device_id,
                    "inbox.resolve",
                    id.as_ref(),
                    format!("failed: could not write the decision file ({err:#})"),
                ))
                .await;
            return Err(ApiError::internal(err));
        }
    };

    let body = resolution_body(&claimed.item, &request, &request_id, &device.device_id);
    let event = Event::new(
        &claimed.item.session_id,
        claimed.item.agent,
        &format!("decision:{request_id}:{action}"),
        decision.decided_at,
        body,
    )
    .with_context(
        claimed.source.cwd.clone(),
        claimed.source.git_branch.clone(),
    );
    let (published, _item) = app.publish(event);

    app.audit
        .append(&AuditEntry::now(
            &device.device_id,
            "inbox.resolve",
            id.as_ref(),
            if request.detail_acknowledged {
                format!("{action} (detail acknowledged)")
            } else {
                action.clone()
            },
        ))
        .await
        .map_err(ApiError::internal)?;

    tracing::info!(
        inbox = %id,
        request = %request_id,
        %action,
        decision_file = %path.display(),
        "decision recorded"
    );
    Ok(Json(ResolveResponse {
        status: "resolved".to_owned(),
        event_id: Some(published.event_id.as_ref().to_owned()),
    }))
}

/// Pick the event body that describes this resolution.
fn resolution_body(
    item: &InboxItem,
    request: &ResolveRequest,
    request_id: &str,
    device_id: &str,
) -> Body {
    match item.category {
        InboxCategory::Question => Body::QuestionAnswered(QuestionAnswered {
            request_id: request_id.to_owned(),
            // A question item can also be answered by picking an action (for
            // example `stop`); the action name is then the answer.
            answer: request
                .answer
                .clone()
                .unwrap_or_else(|| action_name(request.action)),
        }),
        _ => Body::PermissionResolved(PermissionResolved {
            request_id: request_id.to_owned(),
            decision: request.action,
            decided_by: DecidedBy::Device,
            device_id: Some(device_id.to_owned()),
        }),
    }
}

/// Wire name of an action, e.g. `approve_once`.
fn action_name(action: ActionId) -> String {
    serde_json::to_value(action)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_else(|| format!("{action:?}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decision(request_id: &str, action: ActionId) -> Decision {
        Decision {
            version: DECISION_VERSION.to_owned(),
            request_id: request_id.to_owned(),
            inbox_id: "inb_1".to_owned(),
            session_id: "sess_cc-alpha".to_owned(),
            agent: "claude-code".to_owned(),
            action,
            answer: None,
            decided_by: DecidedBy::Device,
            device_id: "dev_a".to_owned(),
            detail_acknowledged: true,
            decided_at: OffsetDateTime::UNIX_EPOCH,
            source_event_id: "evt_1".to_owned(),
        }
    }

    #[test]
    fn action_names_use_the_protocol_spelling() {
        assert_eq!(action_name(ActionId::ApproveOnce), "approve_once");
        assert_eq!(action_name(ActionId::DenyAlways), "deny_always");
        assert_eq!(action_name(ActionId::Acknowledge), "acknowledge");
    }

    #[test]
    fn hostile_request_ids_cannot_escape_the_decisions_directory() {
        // Dots survive, because session ids legitimately contain them. What must
        // never survive is a separator, and the invariant that actually protects
        // the directory is that the result is always exactly one path component —
        // so `dir.join(name)` cannot climb out no matter what the agent wrote.
        let single_component = |request_id: &str| {
            let filename = decision_filename(request_id);
            assert!(!filename.contains('/'), "{filename}");
            assert!(!filename.contains('\\'), "{filename}");
            let path = Path::new(&filename);
            assert_eq!(path.components().count(), 1, "{filename}");
            assert_eq!(
                path.file_name().and_then(|n| n.to_str()),
                Some(filename.as_str()),
                "{filename}"
            );
            // The joined path stays directly inside the decisions directory.
            let joined = Path::new("/state/decisions").join(&filename);
            assert_eq!(
                joined.parent(),
                Some(Path::new("/state/decisions")),
                "{filename}"
            );
            filename
        };

        assert_eq!(single_component("req-1"), "req-1.json");
        assert_eq!(single_component("a/b"), "a_b.json");
        assert_eq!(
            single_component("../../etc/passwd"),
            ".._.._etc_passwd.json"
        );
        assert_eq!(single_component("..%2f..%2fx"), ".._2f.._2fx.json");
        single_component("sess_cc-alpha:tool.Bash");

        // A name made only of separators still yields a usable filename.
        let filename = single_component("///");
        assert!(filename.starts_with("unknown-"), "{filename}");

        // `..` on its own can never become the parent directory, because the
        // extension is always appended.
        assert_eq!(single_component(".."), "...json");
        assert_eq!(single_component("."), "..json");
    }

    #[test]
    fn decision_intent_maps_to_approve_deny_or_halt() {
        assert!(decision("r", ActionId::ApproveOnce).approves());
        assert!(decision("r", ActionId::ApproveAlways).approves());
        assert!(!decision("r", ActionId::ApproveOnce).denies());
        assert!(!decision("r", ActionId::ApproveOnce).halts());

        assert!(decision("r", ActionId::Deny).denies());
        assert!(decision("r", ActionId::DenyAlways).denies());
        assert!(decision("r", ActionId::Deny).halts());

        // `stop` halts the agent without being a denial of this one request, which
        // is why the two predicates are separate.
        assert!(decision("r", ActionId::Stop).halts());
        assert!(!decision("r", ActionId::Stop).denies());
        assert!(!decision("r", ActionId::Stop).approves());

        // Answering or acknowledging is none of the three.
        for action in [ActionId::Answer, ActionId::Acknowledge] {
            let neutral = decision("r", action);
            assert!(!neutral.approves(), "{action:?}");
            assert!(!neutral.denies(), "{action:?}");
            assert!(!neutral.halts(), "{action:?}");
        }
    }

    #[tokio::test]
    async fn decisions_round_trip_through_the_filesystem() {
        let dir = tempfile::tempdir().unwrap();
        let written = decision("req-1", ActionId::ApproveOnce);
        let path = write_decision(dir.path(), &written).await.unwrap();
        assert!(path.ends_with("req-1.json"));

        let read = read_decision(dir.path(), "req-1").await.unwrap();
        assert_eq!(read, written);
        assert!(read_decision(dir.path(), "req-2").await.is_none());
    }

    #[tokio::test]
    async fn a_mismatched_or_corrupt_decision_file_reads_as_absent() {
        let dir = tempfile::tempdir().unwrap();
        // A file whose stored request id is not the one being asked about.
        write_decision(dir.path(), &decision("other", ActionId::ApproveOnce))
            .await
            .unwrap();
        std::fs::rename(
            dir.path().join("other.json"),
            dir.path().join(decision_filename("req-1")),
        )
        .unwrap();
        assert!(read_decision(dir.path(), "req-1").await.is_none());

        std::fs::write(dir.path().join(decision_filename("req-2")), b"{ not json").unwrap();
        assert!(read_decision(dir.path(), "req-2").await.is_none());
    }

    #[test]
    fn resolve_requests_tolerate_unknown_fields_and_default_the_flags() {
        let request: ResolveRequest = serde_json::from_str(
            r#"{"action":"approve_once","action_token":"t","future_field":42}"#,
        )
        .unwrap();
        assert_eq!(request.action, ActionId::ApproveOnce);
        assert!(!request.detail_acknowledged);
        assert!(request.answer.is_none());

        let request: ResolveRequest = serde_json::from_str(
            r#"{"action":"answer","action_token":"t","answer":"blue","detail_acknowledged":true}"#,
        )
        .unwrap();
        assert_eq!(request.answer.as_deref(), Some("blue"));
        assert!(request.detail_acknowledged);
    }
}
