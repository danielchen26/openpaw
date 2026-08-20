//! Codex CLI: `~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-*.jsonl` rollouts.

use anyhow::{Result, bail};
use openpaw_protocol::{
    AgentKind, AgentLifecycle, Body, ContextUpdated, DeltaKind, Event, FileChange, Risk, SessionId,
    ToolCompleted, ToolFailed, ToolStarted, TurnCompleted, TurnDelta, TurnRole, UsageUpdated,
    extract_tool_command, extract_tool_paths,
};
use serde_json::Value;
use time::OffsetDateTime;
use walkdir::WalkDir;

use crate::util::{
    Emitter, exit_code, from_seconds, non_empty, non_empty_verbatim, percent, summarize,
    timestamp_or, truncate,
};
use crate::{AgentAdapter, Cursor, DiscoveredSession, DiscoveryEnv, SessionSource, jsonl};

/// Lines of a rollout discovery reads to learn cwd, branch and title.
const SNIFF_LINES: usize = 64;
/// Cursor context keys: Codex spreads session facts over several lines, so the
/// current cwd/branch/turn must survive between incremental parses.
const CTX_CWD: &str = "codex:cwd";
const CTX_BRANCH: &str = "codex:branch";
const CTX_TURN: &str = "codex:turn";

/// Adapter for Codex CLI rollout transcripts.
#[derive(Debug, Default, Clone, Copy)]
pub struct CodexAdapter;

impl AgentAdapter for CodexAdapter {
    fn kind(&self) -> AgentKind {
        AgentKind::Codex
    }

    fn format_version(&self) -> &'static str {
        "codex/rollout-v1"
    }

    fn discover(&self, env: &DiscoveryEnv) -> Result<Vec<DiscoveredSession>> {
        let sessions_dir = env.home.join(".codex").join("sessions");
        let mut found = Vec::new();
        for entry in WalkDir::new(&sessions_dir)
            .min_depth(1)
            .max_depth(4)
            .sort_by_file_name()
        {
            let entry = match entry {
                Ok(entry) => entry,
                Err(error) => {
                    tracing::warn!(%error, "skipping unreadable codex sessions entry");
                    continue;
                }
            };
            if !entry.file_type().is_file() {
                continue;
            }
            let name = entry.file_name().to_string_lossy();
            if !name.starts_with("rollout-") || !name.ends_with(".jsonl") {
                continue;
            }
            let path = entry.path().to_path_buf();
            let metadata = entry.metadata()?;
            if metadata.len() == 0 {
                continue;
            }
            let updated_at = OffsetDateTime::from(metadata.modified()?);
            if !env.is_fresh(updated_at) {
                continue;
            }
            let sniffed = Sniffed::from_head(&jsonl::head_lines(&path, SNIFF_LINES)?);
            if !env.matches_cwd(sniffed.cwd.as_deref()) {
                continue;
            }
            let raw_id = sniffed
                .session_id
                .clone()
                .unwrap_or_else(|| rollout_id(&name).to_owned());
            found.push(DiscoveredSession {
                session: SessionId::new(AgentKind::Codex, &raw_id),
                agent: AgentKind::Codex,
                source: SessionSource::JsonLines(path),
                title: sniffed.title,
                cwd: sniffed.cwd,
                git_branch: sniffed.git_branch,
                updated_at,
            });
        }
        found.sort_by(|a, b| {
            b.updated_at
                .cmp(&a.updated_at)
                .then_with(|| a.session.as_ref().cmp(b.session.as_ref()))
        });
        Ok(found)
    }

    fn parse(&self, session: &DiscoveredSession, cursor: &mut Cursor) -> Result<Vec<Event>> {
        let SessionSource::JsonLines(path) = &session.source else {
            bail!("codex sessions are backed by a JSON Lines rollout");
        };
        let chunk = jsonl::read_lines_from(path, cursor.byte_offset, cursor.line_index)?;
        if chunk.restarted {
            cursor.flags.clear();
            cursor.consumed.clear();
            cursor.context.clear();
        }
        // A resumed cursor may start after the `session_meta` line that carries
        // the session's cwd and branch; re-sniff the head so context is intact.
        if cursor.ctx(CTX_CWD).is_none() {
            let sniffed = Sniffed::from_head(&jsonl::head_lines(path, SNIFF_LINES)?);
            cursor.set_ctx(CTX_CWD, sniffed.cwd.or_else(|| session.cwd.clone()));
            cursor.set_ctx(
                CTX_BRANCH,
                sniffed.git_branch.or_else(|| session.git_branch.clone()),
            );
        }

        let mut out = Emitter::new(&session.session, AgentKind::Codex);

        for (index, line) in &chunk.lines {
            let value: Value = match serde_json::from_str(line) {
                Ok(value) => value,
                Err(error) => {
                    tracing::warn!(
                        rollout = %path.display(),
                        line = index,
                        %error,
                        "skipping unparsable codex rollout line"
                    );
                    continue;
                }
            };
            let at = timestamp_or(value.get("timestamp"), session.updated_at);
            let payload = value.get("payload").cloned().unwrap_or(Value::Null);
            let record = value
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or_default();

            if record == "session_meta" {
                cursor.set_ctx(
                    CTX_CWD,
                    non_empty(payload.get("cwd").and_then(Value::as_str)),
                );
                cursor.set_ctx(
                    CTX_BRANCH,
                    non_empty(payload.pointer("/git/branch").and_then(Value::as_str)),
                );
            } else if record == "turn_context" {
                if let Some(cwd) = non_empty(payload.get("cwd").and_then(Value::as_str)) {
                    cursor.set_ctx(CTX_CWD, Some(cwd));
                }
                if let Some(turn) = non_empty(payload.get("turn_id").and_then(Value::as_str)) {
                    cursor.set_ctx(CTX_TURN, Some(turn));
                }
            }

            out.set_context(
                cursor.ctx(CTX_CWD).map(str::to_owned),
                cursor.ctx(CTX_BRANCH).map(str::to_owned),
            );

            match record {
                "session_meta" => out.push(
                    index.to_string(),
                    at,
                    Body::AgentStarted(AgentLifecycle {
                        reason: non_empty(payload.get("originator").and_then(Value::as_str)),
                        exit_code: None,
                        title: None,
                    }),
                ),
                "turn_context" => {}
                "event_msg" => event_msg(&mut out, &payload, *index, at, cursor),
                "response_item" => response_item(&mut out, &payload, *index, at, cursor),
                _ => {}
            }
        }

        cursor.byte_offset = chunk.next_offset;
        cursor.line_index = chunk.next_index;
        Ok(out.finish(cursor))
    }
}

fn event_msg(
    out: &mut Emitter<'_>,
    payload: &Value,
    index: u64,
    at: OffsetDateTime,
    cursor: &mut Cursor,
) {
    match payload
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default()
    {
        "task_started" => {
            if let Some(turn) = non_empty(payload.get("turn_id").and_then(Value::as_str)) {
                cursor.set_ctx(CTX_TURN, Some(turn));
            }
            out.push(
                index.to_string(),
                at,
                Body::AgentWorking(AgentLifecycle::default()),
            );
        }
        "user_message" => {
            if let Some(text) = non_empty(payload.get("message").and_then(Value::as_str)) {
                out.push(
                    index.to_string(),
                    at,
                    Body::TurnCompleted(TurnCompleted {
                        turn_id: turn_id(cursor, index),
                        role: TurnRole::User,
                        text,
                        thinking: None,
                    }),
                );
            }
        }
        "agent_message" => {
            if let Some(text) = non_empty(payload.get("message").and_then(Value::as_str)) {
                out.push(
                    index.to_string(),
                    at,
                    Body::TurnCompleted(TurnCompleted {
                        turn_id: turn_id(cursor, index),
                        role: TurnRole::Assistant,
                        text,
                        thinking: None,
                    }),
                );
            }
        }
        "patch_apply_end" => {
            let success = payload
                .get("success")
                .and_then(Value::as_bool)
                .unwrap_or(true);
            let call_id = non_empty(payload.get("call_id").and_then(Value::as_str))
                .unwrap_or_else(|| format!("patch-{index}"));
            let stdout = payload
                .get("stdout")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let stderr = payload
                .get("stderr")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if success {
                out.push(
                    index.to_string(),
                    at,
                    Body::ToolCompleted(ToolCompleted {
                        call_id,
                        exit_code: Some(0),
                        duration_ms: None,
                        summary: non_empty(Some(&summarize(stdout))),
                    }),
                );
            } else {
                out.push(
                    index.to_string(),
                    at,
                    Body::ToolFailed(ToolFailed {
                        call_id,
                        error: non_empty(Some(&summarize(stderr)))
                            .unwrap_or_else(|| "apply_patch failed".to_owned()),
                        exit_code: Some(1),
                    }),
                );
            }
            // `changes` is a JSON object keyed by path; iterate sorted so event
            // ids stay stable no matter how the map was serialized.
            if let Some(changes) = payload.get("changes").and_then(Value::as_object) {
                let mut paths: Vec<&String> = changes.keys().collect();
                paths.sort();
                for (nth, path) in paths.into_iter().enumerate() {
                    let change = &changes[path];
                    let file = FileChange {
                        path: path.clone(),
                        additions: None,
                        deletions: None,
                        bytes: None,
                        unified_diff: non_empty_verbatim(
                            change.get("unified_diff").and_then(Value::as_str),
                        ),
                    };
                    let body = match change.get("type").and_then(Value::as_str) {
                        Some("add") => Body::FileCreated(file),
                        Some("delete") => Body::FileDeleted(file),
                        _ => Body::FileModified(file),
                    };
                    out.push(format!("{index}:file:{nth}"), at, body);
                }
            }
        }
        "token_count" => {
            let info = payload.get("info").cloned().unwrap_or(Value::Null);
            let usage = info
                .get("total_token_usage")
                .cloned()
                .unwrap_or(Value::Null);
            let input_tokens = usage.get("input_tokens").and_then(Value::as_u64);
            let output_tokens = usage
                .get("output_tokens")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            if let Some(input_tokens) = input_tokens {
                out.push(
                    index.to_string(),
                    at,
                    Body::UsageUpdated(UsageUpdated {
                        input_tokens,
                        output_tokens,
                        cached_input_tokens: usage
                            .get("cached_input_tokens")
                            .and_then(Value::as_u64),
                        cost_usd: None,
                        rate_limit_percent: payload
                            .pointer("/rate_limits/primary/used_percent")
                            .and_then(Value::as_f64),
                        rate_limit_resets_at: payload
                            .pointer("/rate_limits/primary/resets_at")
                            .and_then(Value::as_i64)
                            .and_then(from_seconds),
                    }),
                );
            }
            if let Some(max_tokens) = info
                .get("model_context_window")
                .and_then(Value::as_u64)
                .filter(|window| *window > 0)
            {
                let used_tokens = usage
                    .get("total_tokens")
                    .and_then(Value::as_u64)
                    .unwrap_or_else(|| input_tokens.unwrap_or(0) + output_tokens);
                out.push(
                    format!("{index}:context"),
                    at,
                    Body::ContextUpdated(ContextUpdated {
                        used_tokens,
                        max_tokens,
                        percent_used: percent(used_tokens, max_tokens),
                    }),
                );
            }
        }
        "task_complete" => out.push(
            index.to_string(),
            at,
            Body::AgentCompleted(AgentLifecycle::default()),
        ),
        _ => {}
    }
}

fn response_item(
    out: &mut Emitter<'_>,
    payload: &Value,
    index: u64,
    at: OffsetDateTime,
    cursor: &Cursor,
) {
    match payload
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default()
    {
        "reasoning" => {
            // `encrypted_content` is opaque to us; only the plaintext summary is
            // ever shown on a device.
            let summary = payload
                .get("summary")
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| item.get("text").and_then(Value::as_str))
                        .collect::<Vec<&str>>()
                        .join("\n\n")
                })
                .unwrap_or_default();
            if let Some(delta) = non_empty(Some(&summary)) {
                out.push(
                    index.to_string(),
                    at,
                    Body::TurnDelta(TurnDelta {
                        turn_id: turn_id(cursor, index),
                        delta,
                        kind: DeltaKind::Thinking,
                    }),
                );
            }
        }
        "function_call" => {
            let tool = payload
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let call_id = non_empty(payload.get("call_id").and_then(Value::as_str))
                .unwrap_or_else(|| format!("call-{index}"));
            // `arguments` is a JSON document encoded as a string.
            let input: Value = payload
                .get("arguments")
                .and_then(Value::as_str)
                .and_then(|raw| serde_json::from_str(raw).ok())
                .unwrap_or(Value::Null);
            let command = extract_tool_command(tool, &input);
            out.push(
                index.to_string(),
                at,
                Body::ToolStarted(ToolStarted {
                    call_id,
                    tool: tool.to_owned(),
                    summary: command.as_deref().map(summarize),
                    command,
                    paths: extract_tool_paths(tool, &input),
                    risk: Risk::classify_tool(tool, &input),
                }),
            );
        }
        "custom_tool_call" => {
            let tool = payload
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let call_id = non_empty(payload.get("call_id").and_then(Value::as_str))
                .unwrap_or_else(|| format!("call-{index}"));
            let input = payload.get("input").cloned().unwrap_or(Value::Null);
            out.push(
                index.to_string(),
                at,
                Body::ToolStarted(ToolStarted {
                    call_id,
                    tool: tool.to_owned(),
                    summary: input.as_str().map(summarize),
                    command: extract_tool_command(tool, &input),
                    paths: extract_tool_paths(tool, &input),
                    risk: Risk::classify_tool(tool, &input),
                }),
            );
        }
        "function_call_output" | "custom_tool_call_output" => {
            let call_id = non_empty(payload.get("call_id").and_then(Value::as_str))
                .unwrap_or_else(|| format!("call-{index}"));
            let output = payload
                .get("output")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if is_failure(output) {
                out.push(
                    index.to_string(),
                    at,
                    Body::ToolFailed(ToolFailed {
                        call_id,
                        error: summarize(output),
                        exit_code: exit_code(payload.get("exit_code")),
                    }),
                );
            } else {
                out.push(
                    index.to_string(),
                    at,
                    Body::ToolCompleted(ToolCompleted {
                        call_id,
                        exit_code: exit_code(payload.get("exit_code")).or(Some(0)),
                        duration_ms: payload.get("duration_ms").and_then(Value::as_u64),
                        summary: non_empty(Some(&summarize(output))),
                    }),
                );
            }
        }
        _ => {}
    }
}

/// Codex reports shell failures in the output text rather than an exit status.
fn is_failure(output: &str) -> bool {
    let lowered = output.trim_start().to_lowercase();
    lowered.starts_with("failed")
        || lowered.contains("failed in sandbox")
        || output.contains("error[E")
}

fn turn_id(cursor: &Cursor, index: u64) -> String {
    cursor
        .ctx(CTX_TURN)
        .map(str::to_owned)
        .unwrap_or_else(|| format!("turn-{index}"))
}

/// `rollout-2026-08-20T15-00-00-<uuid>.jsonl` -> `<uuid>`.
fn rollout_id(file_name: &str) -> &str {
    let stem = file_name
        .strip_suffix(".jsonl")
        .unwrap_or(file_name)
        .strip_prefix("rollout-")
        .unwrap_or(file_name);
    // The timestamp prefix is a fixed-width `%Y-%m-%dT%H-%M-%S`.
    const TIMESTAMP_LEN: usize = "2026-08-20T15-00-00".len();
    match stem.get(TIMESTAMP_LEN..) {
        Some(rest) => rest.strip_prefix('-').unwrap_or(rest),
        None => stem,
    }
}

/// Session metadata sniffed from the head of a rollout.
#[derive(Debug, Default)]
struct Sniffed {
    session_id: Option<String>,
    cwd: Option<String>,
    git_branch: Option<String>,
    title: Option<String>,
}

impl Sniffed {
    fn from_head(lines: &[String]) -> Self {
        let mut sniffed = Self::default();
        for line in lines {
            let Ok(value) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            let record = value
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let payload = value.get("payload").cloned().unwrap_or(Value::Null);
            match record {
                "session_meta" => {
                    sniffed.session_id = non_empty(payload.get("id").and_then(Value::as_str));
                    sniffed.cwd = non_empty(payload.get("cwd").and_then(Value::as_str));
                    sniffed.git_branch =
                        non_empty(payload.pointer("/git/branch").and_then(Value::as_str));
                }
                "turn_context" => {
                    if let Some(cwd) = non_empty(payload.get("cwd").and_then(Value::as_str)) {
                        sniffed.cwd = Some(cwd);
                    }
                }
                "event_msg"
                    if sniffed.title.is_none()
                        && payload.get("type").and_then(Value::as_str) == Some("user_message") =>
                {
                    sniffed.title = non_empty(payload.get("message").and_then(Value::as_str))
                        .map(|text| truncate(&text, 80));
                }
                _ => {}
            }
            if sniffed.session_id.is_some() && sniffed.cwd.is_some() && sniffed.title.is_some() {
                break;
            }
        }
        sniffed
    }
}

#[cfg(test)]
mod tests {
    use super::{is_failure, rollout_id};

    #[test]
    fn rollout_id_strips_prefix_and_timestamp() {
        assert_eq!(
            rollout_id("rollout-2026-08-20T15-00-00-019ea614-3c6e-7b20-ac95-16f64ccbea58.jsonl"),
            "019ea614-3c6e-7b20-ac95-16f64ccbea58"
        );
    }

    #[test]
    fn failure_detection_matches_codex_wording() {
        assert!(is_failure("failed in sandbox: network access disabled"));
        assert!(is_failure("error[E0308]: mismatched types"));
        assert!(!is_failure("Success. Updated the following files:"));
    }
}
