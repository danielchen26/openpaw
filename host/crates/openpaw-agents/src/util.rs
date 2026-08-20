//! Small helpers shared by the adapters: event collection, timestamp coercion,
//! directory listing and text trimming.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use openpaw_protocol::{AgentKind, Body, Event, SessionId};
use serde_json::Value;
use sha2::{Digest, Sha256};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use crate::Cursor;

/// Longest summary/detail string an adapter will put on an event. Transcripts
/// contain whole build logs; the phone only ever shows a headline, and the full
/// text stays available through the agent's own transcript.
pub(crate) const SUMMARY_LIMIT: usize = 400;

/// Accumulates events for one parse pass, keyed by `source_key` so the caller
/// can drop keys a previous pass already emitted.
pub(crate) struct Emitter<'a> {
    session: &'a SessionId,
    agent: AgentKind,
    cwd: Option<String>,
    git_branch: Option<String>,
    events: Vec<(String, Event)>,
}

impl<'a> Emitter<'a> {
    pub(crate) fn new(session: &'a SessionId, agent: AgentKind) -> Self {
        Self {
            session,
            agent,
            cwd: None,
            git_branch: None,
            events: Vec::new(),
        }
    }

    /// Context stamped onto every subsequent event.
    pub(crate) fn set_context(&mut self, cwd: Option<String>, git_branch: Option<String>) {
        self.cwd = cwd;
        self.git_branch = git_branch;
    }

    pub(crate) fn push(&mut self, source_key: impl Into<String>, at: OffsetDateTime, body: Body) {
        let source_key = source_key.into();
        let event = Event::new(self.session, self.agent, &source_key, at, body)
            .with_context(self.cwd.clone(), self.git_branch.clone());
        self.events.push((source_key, event));
    }

    /// Renumber and hand over the events, advancing `cursor.next_seq`.
    pub(crate) fn finish(self, cursor: &mut Cursor) -> Vec<Event> {
        let events: Vec<Event> = self.events.into_iter().map(|(_, event)| event).collect();
        Self::seal(events, cursor)
    }

    /// Like [`Emitter::finish`], but drops events whose `source_key` the cursor
    /// already recorded and remembers the ones that survive. Used where there is
    /// no byte offset to resume from.
    pub(crate) fn finish_deduped(self, cursor: &mut Cursor) -> Vec<Event> {
        let mut events = Vec::with_capacity(self.events.len());
        for (source_key, event) in self.events {
            if cursor.consumed.insert(source_key) {
                events.push(event);
            }
        }
        Self::seal(events, cursor)
    }

    fn seal(events: Vec<Event>, cursor: &mut Cursor) -> Vec<Event> {
        let events = crate::renumber(events, cursor.next_seq);
        cursor.next_seq += events.len() as u64;
        events
    }
}

/// Parse an RFC 3339 timestamp as written by the agents (`...Z`, optional
/// fractional seconds).
pub(crate) fn parse_rfc3339(raw: &str) -> Result<OffsetDateTime> {
    OffsetDateTime::parse(raw, &Rfc3339).with_context(|| format!("invalid timestamp {raw:?}"))
}

/// Timestamp from a JSON string field, falling back to `default`.
pub(crate) fn timestamp_or(value: Option<&Value>, default: OffsetDateTime) -> OffsetDateTime {
    value
        .and_then(Value::as_str)
        .and_then(|raw| parse_rfc3339(raw).ok())
        .unwrap_or(default)
}

/// Unix epoch milliseconds (OpenCode) to a timestamp.
pub(crate) fn from_millis(millis: i64) -> Result<OffsetDateTime> {
    OffsetDateTime::from_unix_timestamp_nanos(i128::from(millis) * 1_000_000)
        .with_context(|| format!("epoch millis {millis} out of range"))
}

/// Unix epoch seconds (Codex rate limit windows) to a timestamp.
pub(crate) fn from_seconds(seconds: i64) -> Option<OffsetDateTime> {
    OffsetDateTime::from_unix_timestamp(seconds).ok()
}

/// `sha256` hex digest, used for deterministic request ids.
pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

/// Trim to `SUMMARY_LIMIT` characters on a char boundary, marking elision.
pub(crate) fn summarize(text: &str) -> String {
    truncate(text, SUMMARY_LIMIT)
}

pub(crate) fn truncate(text: &str, limit: usize) -> String {
    let trimmed = text.trim();
    if trimmed.chars().count() <= limit {
        return trimmed.to_owned();
    }
    let mut out: String = trimmed.chars().take(limit).collect();
    out.push('…');
    out
}

/// Like [`non_empty`] but preserving surrounding whitespace, for payloads where
/// it is significant (a unified diff is newline terminated).
pub(crate) fn non_empty_verbatim(text: Option<&str>) -> Option<String> {
    text.filter(|text| !text.is_empty()).map(str::to_owned)
}

/// A non-empty trimmed string, or `None`.
pub(crate) fn non_empty(text: Option<&str>) -> Option<String> {
    text.map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

/// First present string field among `keys`.
pub(crate) fn first_str<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_str))
}

/// Flatten an Anthropic-style `content` field (string, or array of blocks with a
/// `text` field) into plain text.
pub(crate) fn content_text(content: &Value) -> String {
    match content {
        Value::String(text) => text.clone(),
        Value::Array(blocks) => {
            let parts: Vec<&str> = blocks
                .iter()
                .filter_map(|block| match block {
                    Value::String(text) => Some(text.as_str()),
                    other => other.get("text").and_then(Value::as_str),
                })
                .collect();
            parts.join("\n")
        }
        other => other.as_str().unwrap_or_default().to_owned(),
    }
}

/// Entries of `dir` sorted by file name, or an empty list when the directory
/// does not exist (an agent that was never installed is not an error).
pub(crate) fn read_dir_sorted(dir: &Path) -> Result<Vec<PathBuf>> {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error).with_context(|| format!("read dir {}", dir.display())),
    };
    let mut paths = Vec::new();
    for entry in entries {
        paths.push(
            entry
                .with_context(|| format!("read dir {}", dir.display()))?
                .path(),
        );
    }
    paths.sort();
    Ok(paths)
}

/// `i32` exit code from a JSON number, clamped into range.
pub(crate) fn exit_code(value: Option<&Value>) -> Option<i32> {
    value
        .and_then(Value::as_i64)
        .map(|code| code.clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32)
}

/// Percentage of `used` against `total`, rounded to two decimals so golden
/// output stays readable.
pub(crate) fn percent(used: u64, total: u64) -> f64 {
    if total == 0 {
        return 0.0;
    }
    let raw = (used as f64 / total as f64) * 100.0;
    (raw.min(100.0) * 100.0).round() / 100.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn content_text_flattens_string_and_blocks() {
        assert_eq!(content_text(&json!("hello")), "hello");
        assert_eq!(
            content_text(&json!([{"type": "text", "text": "a"}, {"type": "text", "text": "b"}])),
            "a\nb"
        );
    }

    #[test]
    fn truncate_marks_elision_on_char_boundary() {
        assert_eq!(truncate("ünïcodé", 3), "ünï…");
        assert_eq!(truncate("  short  ", 32), "short");
    }

    #[test]
    fn percent_rounds_and_clamps() {
        assert_eq!(percent(43_030, 272_000), 15.82);
        assert_eq!(percent(10, 0), 0.0);
        assert_eq!(percent(20, 10), 100.0);
    }
}
