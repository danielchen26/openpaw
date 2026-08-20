//! Agents with no structured log on disk: Gemini CLI, Cursor CLI, Kimi CLI, Qwen
//! Code and anything else a user runs inside a terminal.
//!
//! This adapter is deliberately **signal driven** rather than file driven. The
//! agents it serves keep no transcript OpenPaw can read — their state exists only
//! as bytes on a pseudo terminal. Polling a file would therefore be polling
//! nothing, so [`GenericAdapter::discover`] and [`GenericAdapter::parse`] have no
//! work to do; the real entry point is
//! [`GenericAdapter::ingest_terminal_marker`], which the terminal bridge calls
//! for every output line it scans.
//!
//! Two families of marker are understood:
//!
//! * **Desktop notification escapes** — `OSC 9` (`ESC ] 9 ; text BEL`) and
//!   `OSC 777` (`ESC ] 777 ; notify ; title ; body BEL`). Every mainstream CLI
//!   agent emits one of these when a turn ends or when it wants attention, which
//!   is exactly the moment a phone needs to light up.
//! * **A first-class OpenPaw escape** — `ESC ] 1337 ; OpenPaw=<json> BEL`, whose
//!   JSON is a normalized event body (`{"type": ..., "payload": ...}`). Agents
//!   and wrapper scripts that want full fidelity can opt in without OpenPaw
//!   having to reverse-engineer their log format.

use anyhow::Result;
use openpaw_protocol::{AgentKind, AgentLifecycle, Body, Event, QuestionRequested, SessionId};
use serde_json::Value;
use time::OffsetDateTime;

use crate::util::{non_empty, sha256_hex, summarize, timestamp_or};
use crate::{AgentAdapter, Cursor, DiscoveredSession, DiscoveryEnv};

/// Marker prefixes, all terminated by BEL (`\u{7}`) or ST (`\u{1b}\\`).
const OSC_9: &str = "\u{1b}]9;";
const OSC_777: &str = "\u{1b}]777;";
const OSC_OPENPAW: &str = "\u{1b}]1337;OpenPaw=";

/// Adapter for terminal-only agents.
#[derive(Debug, Default, Clone, Copy)]
pub struct GenericAdapter;

impl GenericAdapter {
    /// Turn one line of terminal output into an event, if it carries a marker.
    ///
    /// `None` means the line held no recognizable marker (the overwhelmingly
    /// common case) or the OpenPaw escape carried JSON that is not a valid event
    /// body. The returned event has `seq == 0`; callers hand it to
    /// [`crate::renumber`] or to a host-side sequencer.
    pub fn ingest_terminal_marker(
        &self,
        session: &SessionId,
        line: &str,
        now: OffsetDateTime,
    ) -> Option<Event> {
        if let Some(payload) = marker_body(line, OSC_OPENPAW) {
            return self.openpaw_event(session, &payload, now);
        }
        let text = marker_body(line, OSC_9)
            .or_else(|| marker_body(line, OSC_777).map(|body| notify_text(&body)))?;
        let text = non_empty(Some(&text))?;

        let body = if is_input_request(&text) {
            Body::QuestionRequested(QuestionRequested {
                request_id: format!("notify:{}", &sha256_hex(text.as_bytes())[..16]),
                question: summarize(&text),
                choices: Vec::new(),
                allows_free_text: true,
            })
        } else if is_failure(&text) {
            Body::AgentFailed(AgentLifecycle {
                reason: Some(summarize(&text)),
                exit_code: None,
                title: None,
            })
        } else {
            // A bare notification from a terminal agent means "your turn":
            // the agent stopped doing work and is handing control back.
            Body::AgentCompleted(AgentLifecycle {
                reason: Some(summarize(&text)),
                exit_code: None,
                title: None,
            })
        };

        let source_key = format!("osc:{}", sha256_hex(text.as_bytes()));
        Some(Event::new(
            session,
            AgentKind::Generic,
            &source_key,
            now,
            body,
        ))
    }

    fn openpaw_event(
        &self,
        session: &SessionId,
        payload: &str,
        now: OffsetDateTime,
    ) -> Option<Event> {
        let value: Value = serde_json::from_str(payload).ok()?;
        let body: Body = serde_json::from_value(value.clone()).ok()?;
        let at = timestamp_or(value.get("timestamp"), now);
        let source_key = non_empty(value.get("source_key").and_then(Value::as_str))
            .unwrap_or_else(|| format!("openpaw:{}", sha256_hex(payload.as_bytes())));
        Some(
            Event::new(session, AgentKind::Generic, &source_key, at, body).with_context(
                non_empty(value.get("cwd").and_then(Value::as_str)),
                non_empty(value.get("git_branch").and_then(Value::as_str)),
            ),
        )
    }
}

impl AgentAdapter for GenericAdapter {
    fn kind(&self) -> AgentKind {
        AgentKind::Generic
    }

    fn format_version(&self) -> &'static str {
        "generic/terminal-markers-v1"
    }

    /// Terminal-only agents leave nothing on disk to discover; sessions arrive
    /// from the terminal bridge instead.
    fn discover(&self, _env: &DiscoveryEnv) -> Result<Vec<DiscoveredSession>> {
        Ok(Vec::new())
    }

    /// There is no transcript to read incrementally; see
    /// [`GenericAdapter::ingest_terminal_marker`].
    fn parse(&self, _session: &DiscoveredSession, _cursor: &mut Cursor) -> Result<Vec<Event>> {
        Ok(Vec::new())
    }
}

/// Body of the first `prefix`-introduced OSC sequence in `line`, without its
/// terminator.
fn marker_body(line: &str, prefix: &str) -> Option<String> {
    let start = line.find(prefix)? + prefix.len();
    let rest = &line[start..];
    let end = rest
        .find('\u{7}')
        .or_else(|| rest.find("\u{1b}\\"))
        .unwrap_or(rest.len());
    Some(rest[..end].to_owned())
}

/// `notify ; title ; body` (or `title ; body`) collapsed to one line of text.
fn notify_text(body: &str) -> String {
    let fields: Vec<&str> = body.split(';').collect();
    let fields = match fields.split_first() {
        Some((first, rest)) if first.eq_ignore_ascii_case("notify") => rest,
        _ => fields.as_slice(),
    };
    fields
        .iter()
        .map(|field| field.trim())
        .filter(|field| !field.is_empty())
        .collect::<Vec<&str>>()
        .join(": ")
}

fn is_input_request(text: &str) -> bool {
    let lowered = text.to_lowercase();
    lowered.contains("needs your input")
        || lowered.contains("waiting for")
        || lowered.contains("permission")
        || lowered.contains("approve")
}

fn is_failure(text: &str) -> bool {
    let lowered = text.to_lowercase();
    lowered.contains("failed") || lowered.contains("error")
}

#[cfg(test)]
mod tests {
    use super::*;
    use openpaw_protocol::EventType;

    fn session() -> SessionId {
        SessionId::new(AgentKind::Generic, "tmux:work:2.0")
    }

    fn now() -> OffsetDateTime {
        OffsetDateTime::from_unix_timestamp(1_787_245_200).expect("timestamp")
    }

    #[test]
    fn osc9_completion_becomes_agent_completed() {
        let event = GenericAdapter
            .ingest_terminal_marker(
                &session(),
                "\u{1b}]9;Gemini finished the refactor\u{7}",
                now(),
            )
            .expect("event");
        assert_eq!(event.kind(), EventType::AgentCompleted);
        assert_eq!(event.seq, 0);
    }

    #[test]
    fn osc777_input_request_becomes_question() {
        let event = GenericAdapter
            .ingest_terminal_marker(
                &session(),
                "\u{1b}]777;notify;Kimi CLI;Kimi needs your input to continue\u{1b}\\",
                now(),
            )
            .expect("event");
        assert_eq!(event.kind(), EventType::QuestionRequested);
    }

    #[test]
    fn osc9_failure_becomes_agent_failed() {
        let event = GenericAdapter
            .ingest_terminal_marker(&session(), "\u{1b}]9;build failed: 2 errors\u{7}", now())
            .expect("event");
        assert_eq!(event.kind(), EventType::AgentFailed);
    }

    #[test]
    fn openpaw_escape_carries_a_full_event_body() {
        let line = "\u{1b}]1337;OpenPaw={\"type\":\"context.updated\",\"payload\":{\"used_tokens\":100,\"max_tokens\":1000,\"percent_used\":10.0},\"source_key\":\"ctx-1\",\"cwd\":\"/repo\"}\u{7}";
        let event = GenericAdapter
            .ingest_terminal_marker(&session(), line, now())
            .expect("event");
        assert_eq!(event.kind(), EventType::ContextUpdated);
        assert_eq!(event.cwd.as_deref(), Some("/repo"));
        // Same marker, same id: replays are idempotent.
        let again = GenericAdapter
            .ingest_terminal_marker(&session(), line, now())
            .expect("event");
        assert_eq!(event.event_id, again.event_id);
    }

    #[test]
    fn plain_output_and_malformed_json_yield_nothing() {
        assert!(
            GenericAdapter
                .ingest_terminal_marker(&session(), "cargo test --workspace", now())
                .is_none()
        );
        assert!(
            GenericAdapter
                .ingest_terminal_marker(&session(), "\u{1b}]1337;OpenPaw={oops}\u{7}", now())
                .is_none()
        );
    }
}
