//! OpenCode: the exploded `~/.local/share/opencode/storage` tree of
//! `session/`, `message/` and `part/` JSON records.

use std::path::Path;

use anyhow::{Context, Result, bail};
use openpaw_protocol::{
    AgentKind, AgentLifecycle, Body, DeltaKind, Event, FileChange, Risk, SessionId, ToolCompleted,
    ToolFailed, ToolStarted, TurnCompleted, TurnDelta, TurnRole, UsageUpdated,
    extract_tool_command, extract_tool_paths,
};
use serde_json::Value;
use time::OffsetDateTime;

use crate::util::{Emitter, from_millis, non_empty, read_dir_sorted, summarize};
use crate::{AgentAdapter, Cursor, DiscoveredSession, DiscoveryEnv, SessionSource};

/// Adapter for OpenCode's storage tree.
#[derive(Debug, Default, Clone, Copy)]
pub struct OpenCodeAdapter;

impl OpenCodeAdapter {
    /// `storage` directory under a home directory.
    fn storage_root(home: &Path) -> std::path::PathBuf {
        home.join(".local")
            .join("share")
            .join("opencode")
            .join("storage")
    }
}

impl AgentAdapter for OpenCodeAdapter {
    fn kind(&self) -> AgentKind {
        AgentKind::OpenCode
    }

    fn format_version(&self) -> &'static str {
        "opencode/storage-v1"
    }

    fn discover(&self, env: &DiscoveryEnv) -> Result<Vec<DiscoveredSession>> {
        let root = Self::storage_root(&env.home);
        let mut found = Vec::new();
        for project_dir in read_dir_sorted(&root.join("session"))? {
            if !project_dir.is_dir() {
                continue;
            }
            for path in read_dir_sorted(&project_dir)? {
                let name = path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or_default();
                if !name.starts_with("ses_") || !name.ends_with(".json") {
                    continue;
                }
                let record = match read_json(&path) {
                    Ok(record) => record,
                    Err(error) => {
                        tracing::warn!(session = %path.display(), %error, "skipping unreadable opencode session");
                        continue;
                    }
                };
                let Some(raw_id) = non_empty(record.get("id").and_then(Value::as_str)) else {
                    continue;
                };
                let updated_at = match session_updated_at(&record, &path) {
                    Ok(updated_at) => updated_at,
                    Err(error) => {
                        tracing::warn!(session = %path.display(), %error, "skipping opencode session with unusable timestamps");
                        continue;
                    }
                };
                if !env.is_fresh(updated_at) {
                    continue;
                }
                let cwd = non_empty(record.get("directory").and_then(Value::as_str));
                if !env.matches_cwd(cwd.as_deref()) {
                    continue;
                }
                found.push(DiscoveredSession {
                    session: SessionId::new(AgentKind::OpenCode, &raw_id),
                    agent: AgentKind::OpenCode,
                    source: SessionSource::OpenCodeStorage {
                        root: root.clone(),
                        session_dir: project_dir.clone(),
                    },
                    title: non_empty(record.get("title").and_then(Value::as_str)),
                    cwd,
                    git_branch: None,
                    updated_at,
                });
            }
        }
        found.sort_by(|a, b| {
            b.updated_at
                .cmp(&a.updated_at)
                .then_with(|| a.session.as_ref().cmp(b.session.as_ref()))
        });
        Ok(found)
    }

    fn parse(&self, session: &DiscoveredSession, cursor: &mut Cursor) -> Result<Vec<Event>> {
        let SessionSource::OpenCodeStorage { root, session_dir } = &session.source else {
            bail!("opencode sessions are backed by a storage tree");
        };
        let raw_id = session.raw_id().to_owned();
        let record = read_json(&session_dir.join(format!("{raw_id}.json")))?;
        let session_cwd = non_empty(record.get("directory").and_then(Value::as_str))
            .or_else(|| session.cwd.clone());
        let session_created = record
            .pointer("/time/created")
            .and_then(Value::as_i64)
            .and_then(|millis| from_millis(millis).ok())
            .unwrap_or(session.updated_at);

        let mut messages = Vec::new();
        for path in read_dir_sorted(&root.join("message").join(&raw_id))? {
            if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
                continue;
            }
            let message = match read_json(&path) {
                Ok(message) => message,
                Err(error) => {
                    tracing::warn!(message = %path.display(), %error, "skipping unreadable opencode message");
                    continue;
                }
            };
            let Some(id) = non_empty(message.get("id").and_then(Value::as_str)) else {
                continue;
            };
            let created = message
                .pointer("/time/created")
                .and_then(Value::as_i64)
                .unwrap_or_default();
            messages.push((created, id, message));
        }
        messages.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));

        let mut out = Emitter::new(&session.session, AgentKind::OpenCode);
        for (created, message_id, message) in &messages {
            let created_at = from_millis(*created).unwrap_or(session_created);
            let completed_at = message
                .pointer("/time/completed")
                .and_then(Value::as_i64)
                .and_then(|millis| from_millis(millis).ok())
                .unwrap_or(created_at);
            let role = message
                .get("role")
                .and_then(Value::as_str)
                .unwrap_or("assistant");
            out.set_context(
                non_empty(message.pointer("/path/cwd").and_then(Value::as_str))
                    .or_else(|| session_cwd.clone()),
                None,
            );

            for path in read_dir_sorted(&root.join("part").join(message_id))? {
                if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
                    continue;
                }
                let part = match read_json(&path) {
                    Ok(part) => part,
                    Err(error) => {
                        tracing::warn!(part = %path.display(), %error, "skipping unreadable opencode part");
                        continue;
                    }
                };
                let Some(part_id) = non_empty(part.get("id").and_then(Value::as_str)) else {
                    continue;
                };
                let at = part
                    .pointer("/time/start")
                    .and_then(Value::as_i64)
                    .and_then(|millis| from_millis(millis).ok())
                    .unwrap_or(created_at);
                part_events(
                    &mut out,
                    &part,
                    &part_id,
                    message_id,
                    role,
                    at,
                    completed_at,
                );
            }

            if let Some(reason) = non_empty(message.get("finish").and_then(Value::as_str)) {
                out.push(
                    format!("{message_id}:finish"),
                    completed_at,
                    Body::AgentCompleted(AgentLifecycle {
                        reason: Some(reason),
                        exit_code: None,
                        title: None,
                    }),
                );
            }
        }

        Ok(out.finish_deduped(cursor))
    }
}

#[allow(clippy::too_many_arguments)]
fn part_events(
    out: &mut Emitter<'_>,
    part: &Value,
    part_id: &str,
    message_id: &str,
    role: &str,
    at: OffsetDateTime,
    message_completed_at: OffsetDateTime,
) {
    match part.get("type").and_then(Value::as_str).unwrap_or_default() {
        "text" => {
            let Some(text) = non_empty(part.get("text").and_then(Value::as_str)) else {
                return;
            };
            out.push(
                part_id.to_owned(),
                at,
                Body::TurnCompleted(TurnCompleted {
                    turn_id: message_id.to_owned(),
                    role: if role == "user" {
                        TurnRole::User
                    } else {
                        TurnRole::Assistant
                    },
                    text,
                    thinking: None,
                }),
            );
        }
        "reasoning" => {
            if let Some(delta) = non_empty(part.get("text").and_then(Value::as_str)) {
                out.push(
                    part_id.to_owned(),
                    at,
                    Body::TurnDelta(TurnDelta {
                        turn_id: message_id.to_owned(),
                        delta,
                        kind: DeltaKind::Thinking,
                    }),
                );
            }
        }
        "tool" => {
            let tool = part
                .get("tool")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let call_id = non_empty(part.get("callID").and_then(Value::as_str))
                .unwrap_or_else(|| part_id.to_owned());
            let state = part.get("state").cloned().unwrap_or(Value::Null);
            let input = state.get("input").cloned().unwrap_or(Value::Null);
            // Tool parts time themselves inside `state`, not at part level.
            let started_at = state
                .pointer("/time/start")
                .and_then(Value::as_i64)
                .and_then(|millis| from_millis(millis).ok())
                .unwrap_or(at);
            out.push(
                part_id.to_owned(),
                started_at,
                Body::ToolStarted(ToolStarted {
                    call_id: call_id.clone(),
                    tool: tool.to_owned(),
                    summary: non_empty(state.get("title").and_then(Value::as_str)),
                    command: extract_tool_command(tool, &input),
                    paths: extract_tool_paths(tool, &input),
                    risk: Risk::classify_tool(tool, &input),
                }),
            );
            let ended_at = state
                .pointer("/time/end")
                .and_then(Value::as_i64)
                .and_then(|millis| from_millis(millis).ok())
                .unwrap_or(started_at);
            let duration_ms = state
                .pointer("/time/start")
                .and_then(Value::as_i64)
                .zip(state.pointer("/time/end").and_then(Value::as_i64))
                .map(|(start, end)| end.saturating_sub(start).max(0) as u64);
            match state.get("status").and_then(Value::as_str) {
                Some("completed") => out.push(
                    format!("{part_id}:done"),
                    ended_at,
                    Body::ToolCompleted(ToolCompleted {
                        call_id,
                        exit_code: Some(0),
                        duration_ms,
                        summary: non_empty(state.get("output").and_then(Value::as_str))
                            .map(|output| summarize(&output)),
                    }),
                ),
                Some("error") => out.push(
                    format!("{part_id}:done"),
                    ended_at,
                    Body::ToolFailed(ToolFailed {
                        call_id,
                        error: non_empty(state.get("error").and_then(Value::as_str))
                            .unwrap_or_else(|| "tool reported an error".to_owned()),
                        exit_code: None,
                    }),
                ),
                _ => {}
            }
        }
        "patch" => {
            if let Some(files) = part.get("files").and_then(Value::as_array) {
                for (nth, file) in files.iter().enumerate() {
                    let Some(path) = non_empty(file.as_str()) else {
                        continue;
                    };
                    out.push(
                        format!("{part_id}:file:{nth}"),
                        at,
                        Body::FileModified(FileChange {
                            path,
                            additions: None,
                            deletions: None,
                            bytes: None,
                            unified_diff: None,
                        }),
                    );
                }
            }
        }
        "step-finish" => {
            let tokens = part.get("tokens").cloned().unwrap_or(Value::Null);
            let Some(input_tokens) = tokens.get("input").and_then(Value::as_u64) else {
                return;
            };
            out.push(
                part_id.to_owned(),
                message_completed_at,
                Body::UsageUpdated(UsageUpdated {
                    input_tokens,
                    output_tokens: tokens.get("output").and_then(Value::as_u64).unwrap_or(0),
                    cached_input_tokens: tokens.pointer("/cache/read").and_then(Value::as_u64),
                    cost_usd: part.get("cost").and_then(Value::as_f64),
                    rate_limit_percent: None,
                    rate_limit_resets_at: None,
                }),
            );
        }
        _ => {}
    }
}

/// OpenCode rewrites `time.updated` whenever a session advances; fall back to
/// the record's mtime for older layouts that omit it.
fn session_updated_at(record: &Value, path: &Path) -> Result<OffsetDateTime> {
    if let Some(millis) = record
        .pointer("/time/updated")
        .or_else(|| record.pointer("/time/created"))
        .and_then(Value::as_i64)
    {
        return from_millis(millis);
    }
    Ok(OffsetDateTime::from(
        std::fs::metadata(path)
            .with_context(|| format!("stat {}", path.display()))?
            .modified()?,
    ))
}

fn read_json(path: &Path) -> Result<Value> {
    let bytes = std::fs::read(path).with_context(|| format!("read {}", path.display()))?;
    serde_json::from_slice(&bytes).with_context(|| format!("parse {}", path.display()))
}
