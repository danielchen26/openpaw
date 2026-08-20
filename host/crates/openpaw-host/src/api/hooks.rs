//! `POST /v1/hooks/{agent}` — ingress for the agents' own hook mechanisms.
//!
//! A transcript file tells us what an agent *did*; a hook tells us what it is
//! *about to do*, in time to stop it. That is the difference between a read-only
//! observer and a control plane, so this route exists even though the polling
//! supervisor would eventually see the same activity.
//!
//! The reply is where the two directions meet. Claude Code's `PreToolUse` hook
//! reads `{"decision": "approve"|"block"}` off stdout, so if a decision for this
//! request is already on disk we answer with it and the CLI proceeds without
//! prompting. If there is no decision, we answer `{}` and the CLI falls back to
//! its own terminal prompt.
//!
//! By default the daemon does not wait for a decision at all (`hook_wait_ms = 0`).
//! That is the only defensible default: an operator whose phone is in another room
//! must never find their terminal wedged because OpenPaw was installed.

use std::time::{Duration, Instant};

use axum::extract::{Path as UrlPath, State};
use axum::{Json, http::StatusCode};
use bytes::Bytes;
use openpaw_protocol::{AgentKind, Body};
use serde_json::{Value, json};
use time::OffsetDateTime;

use crate::AppState;
use crate::api::ApiError;
use crate::api::inbox::{Decision, read_decision};
use crate::audit::AuditEntry;
use crate::auth::LOCAL_CALLER;

/// How often the decisions directory is checked while a hook is waiting.
const DECISION_POLL: Duration = Duration::from_millis(50);

/// `POST /v1/hooks/{agent}`.
pub async fn ingest(
    State(app): State<AppState>,
    UrlPath(agent): UrlPath<String>,
    body: Bytes,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let kind = serde_json::from_value::<AgentKind>(Value::String(agent.clone()))
        .map_err(|_| ApiError::not_found(format!("unknown agent {agent:?}")))?;
    if !app.config.agents.enabled(kind) {
        return Err(ApiError::forbidden(format!(
            "the {agent} adapter is disabled in config.toml"
        )));
    }
    let adapter = openpaw_agents::adapter_for(kind)
        .ok_or_else(|| ApiError::not_found(format!("no adapter for {agent}")))?;

    // An empty body is a legitimate ping from a hook that has nothing to report.
    let payload: Value = if body.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&body)
            .map_err(|err| ApiError::bad_request(format!("hook body is not JSON: {err}")))?
    };

    let event = adapter
        .parse_hook(&payload, OffsetDateTime::now_utc())
        .map_err(|err| ApiError::bad_request(format!("{err:#}")))?;

    let Some(event) = event else {
        // The hook shape carried nothing normalizable. Accepting it keeps the
        // agent's hook exit code clean.
        return Ok((StatusCode::OK, Json(json!({}))));
    };

    let request_id = request_id_of(&event.body).map(str::to_owned);
    let (stored, item) = app.publish(event);
    app.sessions.observe_event(&stored);
    if let Some(item) = &item {
        tracing::info!(
            inbox = %item.id,
            session = %stored.session_id,
            kind = stored.kind().as_str(),
            "hook produced an actionable item"
        );
    }

    let Some(request_id) = request_id else {
        return Ok((StatusCode::OK, Json(json!({}))));
    };

    let decision = await_decision(&app, &request_id).await;
    let Some(decision) = decision else {
        return Ok((StatusCode::OK, Json(json!({}))));
    };

    // Applying a decision to a live tool call is the security-relevant moment, so
    // it gets an audit line. The hook traffic that carries no decision does not:
    // a line per `PreToolUse` would bury the entries that matter.
    app.audit
        .append(&AuditEntry::now(
            LOCAL_CALLER,
            "hook.decision_delivered",
            &request_id,
            format!(
                "{} to {}",
                if decision.approves() {
                    "approve"
                } else if decision.halts() {
                    "block"
                } else {
                    "pass through"
                },
                agent
            ),
        ))
        .await
        .map_err(ApiError::internal)?;

    Ok((StatusCode::OK, Json(hook_reply(kind, &decision))))
}

/// Poll for a decision for at most `hook_wait_ms`.
///
/// Checked once before any waiting, because the common case is a decision the
/// operator already made: the hook re-runs after being blocked and the answer is
/// sitting there.
async fn await_decision(app: &AppState, request_id: &str) -> Option<Decision> {
    let dir = app.store.decisions_dir();
    if let Some(decision) = read_decision(&dir, request_id).await {
        return Some(decision);
    }
    let budget = app.config.hook_wait();
    if budget.is_zero() {
        return None;
    }

    let started = Instant::now();
    while started.elapsed() < budget {
        let remaining = budget.saturating_sub(started.elapsed());
        tokio::time::sleep(DECISION_POLL.min(remaining)).await;
        if let Some(decision) = read_decision(&dir, request_id).await {
            return Some(decision);
        }
    }
    tracing::debug!(
        request_id,
        ?budget,
        "no decision arrived within the hook budget"
    );
    None
}

/// Render a decision in the shape the agent's hook protocol expects.
fn hook_reply(kind: AgentKind, decision: &Decision) -> Value {
    match kind {
        AgentKind::ClaudeCode => {
            if decision.approves() {
                json!({
                    "decision": "approve",
                    "reason": reason(decision, "Approved from an OpenPaw device"),
                })
            } else if decision.halts() {
                json!({
                    "decision": "block",
                    "reason": reason(decision, "Denied from an OpenPaw device"),
                })
            } else {
                // `answer`/`acknowledge` are not approve/deny verdicts; leaving
                // the reply empty keeps Claude Code's own prompt in charge.
                json!({})
            }
        }
        // No other supported agent defines a decision-carrying hook reply. An
        // empty object is the neutral answer everywhere.
        _ => json!({}),
    }
}

/// Prefer the operator's own words when they supplied any.
fn reason(decision: &Decision, fallback: &str) -> String {
    match decision
        .answer
        .as_deref()
        .map(str::trim)
        .filter(|answer| !answer.is_empty())
    {
        Some(answer) => answer.to_owned(),
        None => fallback.to_owned(),
    }
}

/// The agent-side request id a body is asking about, if any.
fn request_id_of(body: &Body) -> Option<&str> {
    match body {
        Body::PermissionRequested(payload) => Some(payload.request_id.as_str()),
        Body::QuestionRequested(payload) => Some(payload.request_id.as_str()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openpaw_protocol::{ActionId, DecidedBy};

    fn decision(action: ActionId, answer: Option<&str>) -> Decision {
        Decision {
            version: crate::api::inbox::DECISION_VERSION.to_owned(),
            request_id: "req-1".to_owned(),
            inbox_id: "inb_1".to_owned(),
            session_id: "sess_cc-alpha".to_owned(),
            agent: "claude-code".to_owned(),
            action,
            answer: answer.map(str::to_owned),
            decided_by: DecidedBy::Device,
            device_id: "dev_a".to_owned(),
            detail_acknowledged: true,
            decided_at: OffsetDateTime::UNIX_EPOCH,
            source_event_id: "evt_1".to_owned(),
        }
    }

    #[test]
    fn claude_code_gets_approve_and_block_verdicts() {
        let reply = hook_reply(
            AgentKind::ClaudeCode,
            &decision(ActionId::ApproveOnce, None),
        );
        assert_eq!(reply["decision"], "approve");
        assert_eq!(reply["reason"], "Approved from an OpenPaw device");

        let reply = hook_reply(AgentKind::ClaudeCode, &decision(ActionId::DenyAlways, None));
        assert_eq!(reply["decision"], "block");

        let reply = hook_reply(AgentKind::ClaudeCode, &decision(ActionId::Stop, None));
        assert_eq!(reply["decision"], "block");
    }

    #[test]
    fn the_operators_own_words_become_the_reason() {
        let reply = hook_reply(
            AgentKind::ClaudeCode,
            &decision(ActionId::Deny, Some("wrong directory")),
        );
        assert_eq!(reply["reason"], "wrong directory");

        // Whitespace is not an explanation.
        let reply = hook_reply(
            AgentKind::ClaudeCode,
            &decision(ActionId::Deny, Some("   ")),
        );
        assert_eq!(reply["reason"], "Denied from an OpenPaw device");
    }

    #[test]
    fn non_verdict_actions_and_other_agents_get_an_empty_reply() {
        assert_eq!(
            hook_reply(
                AgentKind::ClaudeCode,
                &decision(ActionId::Answer, Some("x"))
            ),
            json!({})
        );
        assert_eq!(
            hook_reply(
                AgentKind::ClaudeCode,
                &decision(ActionId::Acknowledge, None)
            ),
            json!({})
        );
        assert_eq!(
            hook_reply(AgentKind::Codex, &decision(ActionId::ApproveOnce, None)),
            json!({})
        );
        assert_eq!(
            hook_reply(AgentKind::OpenCode, &decision(ActionId::Deny, None)),
            json!({})
        );
    }
}
