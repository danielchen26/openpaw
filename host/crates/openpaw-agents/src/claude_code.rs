//! Claude Code: `~/.claude/projects/<slug>/<session>.jsonl` transcripts plus the
//! hook payloads Claude Code POSTs to `openpaw-host`.

use anyhow::{Result, bail};
use openpaw_protocol::{
    ActionId, AgentKind, AgentLifecycle, Body, DeltaKind, Event, FileChange, PermissionRequested,
    Plan, PlanStep, PlanStepStatus, QuestionRequested, Risk, SessionId, ToolCompleted, ToolFailed,
    ToolStarted, TurnCompleted, TurnDelta, TurnRole, UsageUpdated, extract_tool_command,
    extract_tool_paths,
};
use serde_json::Value;
use time::OffsetDateTime;

use crate::util::{
    Emitter, content_text, exit_code, first_str, non_empty, read_dir_sorted, sha256_hex, summarize,
    timestamp_or, truncate,
};
use crate::{AgentAdapter, Cursor, DiscoveredSession, DiscoveryEnv, SessionSource, jsonl};

/// Lines of a transcript discovery reads to learn cwd, branch and title.
const SNIFF_LINES: usize = 64;

/// Adapter for Claude Code transcripts and hooks.
#[derive(Debug, Default, Clone, Copy)]
pub struct ClaudeCodeAdapter;

impl ClaudeCodeAdapter {
    /// Latched in the cursor once a `TodoWrite` produced a `plan.created`, so
    /// later todo writes in the same session become `plan.updated`.
    const PLAN_FLAG: &'static str = "plan";
}

impl AgentAdapter for ClaudeCodeAdapter {
    fn kind(&self) -> AgentKind {
        AgentKind::ClaudeCode
    }

    fn format_version(&self) -> &'static str {
        "claude-code/transcript-v1"
    }

    fn discover(&self, env: &DiscoveryEnv) -> Result<Vec<DiscoveredSession>> {
        let projects = env.home.join(".claude").join("projects");
        let mut found = Vec::new();
        for project in read_dir_sorted(&projects)? {
            if !project.is_dir() {
                continue;
            }
            for path in read_dir_sorted(&project)? {
                if path.extension().and_then(|ext| ext.to_str()) != Some("jsonl") {
                    continue;
                }
                let metadata = std::fs::metadata(&path)?;
                if !metadata.is_file() || metadata.len() == 0 {
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
                let raw_id = sniffed.session_id.clone().unwrap_or_else(|| {
                    path.file_stem()
                        .and_then(|stem| stem.to_str())
                        .unwrap_or("unknown")
                        .to_owned()
                });
                found.push(DiscoveredSession {
                    session: SessionId::new(AgentKind::ClaudeCode, &raw_id),
                    agent: AgentKind::ClaudeCode,
                    source: SessionSource::JsonLines(path),
                    title: sniffed.title,
                    cwd: sniffed.cwd,
                    git_branch: sniffed.git_branch,
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
        let SessionSource::JsonLines(path) = &session.source else {
            bail!("claude-code sessions are backed by a JSON Lines transcript");
        };
        let chunk = jsonl::read_lines_from(path, cursor.byte_offset, cursor.line_index)?;
        if chunk.restarted {
            cursor.flags.clear();
            cursor.consumed.clear();
        }

        let mut out = Emitter::new(&session.session, AgentKind::ClaudeCode);
        let plan_id = format!("{}:todos", session.raw_id());

        for (index, line) in &chunk.lines {
            let value: Value = match serde_json::from_str(line) {
                Ok(value) => value,
                Err(error) => {
                    tracing::warn!(
                        transcript = %path.display(),
                        line = index,
                        %error,
                        "skipping unparsable claude-code transcript line"
                    );
                    continue;
                }
            };
            if value.get("isSidechain").and_then(Value::as_bool) == Some(true) {
                continue;
            }

            out.set_context(
                non_empty(value.get("cwd").and_then(Value::as_str)).or_else(|| session.cwd.clone()),
                non_empty(value.get("gitBranch").and_then(Value::as_str))
                    .or_else(|| session.git_branch.clone()),
            );

            let uuid = value
                .get("uuid")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .unwrap_or_else(|| format!("line-{index}"));
            let at = timestamp_or(value.get("timestamp"), session.updated_at);

            match value.get("type").and_then(Value::as_str) {
                Some("user") => user_line(&mut out, &value, &uuid, at),
                Some("assistant") => {
                    assistant_line(&mut out, &value, &uuid, at, &plan_id, cursor);
                }
                _ => {}
            }
        }

        cursor.byte_offset = chunk.next_offset;
        cursor.line_index = chunk.next_index;
        Ok(out.finish(cursor))
    }

    fn parse_hook(&self, raw: &Value, now: OffsetDateTime) -> Result<Option<Event>> {
        let Some(hook) = raw.get("hook_event_name").and_then(Value::as_str) else {
            bail!("claude-code hook payload has no hook_event_name");
        };
        let Some(raw_session) = raw.get("session_id").and_then(Value::as_str) else {
            bail!("claude-code {hook} hook payload has no session_id");
        };
        let session = SessionId::new(AgentKind::ClaudeCode, raw_session);
        let cwd = non_empty(raw.get("cwd").and_then(Value::as_str));

        let (source_key, body) = match hook {
            "PreToolUse" => {
                let Some(tool) = raw.get("tool_name").and_then(Value::as_str) else {
                    bail!("claude-code PreToolUse hook payload has no tool_name");
                };
                let input = raw.get("tool_input").cloned().unwrap_or(Value::Null);
                let digest = sha256_hex(serde_json::to_string(&input)?.as_bytes());
                let request_id = format!("{raw_session}:{tool}:{}", &digest[..16]);
                let paths = extract_tool_paths(tool, &input);
                let command = extract_tool_command(tool, &input);
                let summary = non_empty(first_str(&input, &["description", "summary"]))
                    .or_else(|| command.as_deref().map(summarize))
                    .or_else(|| (!paths.is_empty()).then(|| format!("{tool} {}", paths.join(" "))))
                    .unwrap_or_else(|| tool.to_owned());
                let body = Body::PermissionRequested(PermissionRequested {
                    request_id: request_id.clone(),
                    tool: tool.to_owned(),
                    summary,
                    command,
                    paths,
                    risk: Risk::classify_tool(tool, &input),
                    actions: vec![
                        ActionId::ApproveOnce,
                        ActionId::ApproveAlways,
                        ActionId::Deny,
                    ],
                    expires_at: None,
                });
                (format!("hook:PreToolUse:{request_id}"), body)
            }
            "Notification" => {
                let message = raw
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .trim();
                if !is_input_request(message) {
                    return Ok(None);
                }
                let digest = sha256_hex(message.as_bytes());
                let request_id = format!("{raw_session}:notify:{}", &digest[..16]);
                let body = Body::QuestionRequested(QuestionRequested {
                    request_id: request_id.clone(),
                    question: message.to_owned(),
                    choices: Vec::new(),
                    allows_free_text: true,
                });
                (format!("hook:Notification:{request_id}"), body)
            }
            "Stop" | "SessionEnd" => (
                // Stop hooks carry no identifier of their own; second resolution
                // is enough to collapse a redelivered POST while keeping
                // successive stops distinct.
                format!("hook:{hook}:{}", now.unix_timestamp()),
                Body::AgentCompleted(AgentLifecycle {
                    reason: non_empty(raw.get("reason").and_then(Value::as_str))
                        .or_else(|| Some(hook.to_lowercase())),
                    exit_code: None,
                    title: None,
                }),
            ),
            "SubagentStop" => (
                format!("hook:SubagentStop:{}", now.unix_timestamp()),
                Body::AgentWorking(AgentLifecycle {
                    reason: Some("subagent stopped".to_owned()),
                    exit_code: None,
                    title: None,
                }),
            ),
            _ => return Ok(None),
        };

        Ok(Some(
            Event::new(&session, AgentKind::ClaudeCode, &source_key, now, body)
                .with_context(cwd, None),
        ))
    }
}

/// Claude Code notifications only become questions when they actually ask for
/// something; "task finished" style notifications are not inbox items.
fn is_input_request(message: &str) -> bool {
    let lowered = message.to_lowercase();
    lowered.contains("needs your input") || lowered.contains("waiting for")
}

fn user_line(out: &mut Emitter<'_>, value: &Value, uuid: &str, at: OffsetDateTime) {
    match value.pointer("/message/content") {
        Some(Value::String(text)) => {
            if let Some(text) = non_empty(Some(text)) {
                out.push(
                    format!("{uuid}#0"),
                    at,
                    Body::TurnCompleted(TurnCompleted {
                        turn_id: uuid.to_owned(),
                        role: TurnRole::User,
                        text,
                        thinking: None,
                    }),
                );
            }
        }
        Some(Value::Array(blocks)) => {
            for (index, block) in blocks.iter().enumerate() {
                match block.get("type").and_then(Value::as_str) {
                    Some("text") => {
                        if let Some(text) = non_empty(block.get("text").and_then(Value::as_str)) {
                            out.push(
                                format!("{uuid}#{index}"),
                                at,
                                Body::TurnCompleted(TurnCompleted {
                                    turn_id: uuid.to_owned(),
                                    role: TurnRole::User,
                                    text,
                                    thinking: None,
                                }),
                            );
                        }
                    }
                    Some("tool_result") => {
                        out.push(
                            format!("{uuid}#{index}"),
                            at,
                            tool_result_body(value, block, uuid),
                        );
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
}

fn tool_result_body(line: &Value, block: &Value, uuid: &str) -> Body {
    let call_id = non_empty(block.get("tool_use_id").and_then(Value::as_str))
        .unwrap_or_else(|| uuid.to_owned());
    let text = summarize(&content_text(block.get("content").unwrap_or(&Value::Null)));
    let exit = exit_code(line.pointer("/toolUseResult/exitCode"));
    if block.get("is_error").and_then(Value::as_bool) == Some(true) {
        Body::ToolFailed(ToolFailed {
            call_id,
            error: if text.is_empty() {
                "tool reported an error".to_owned()
            } else {
                text
            },
            exit_code: exit,
        })
    } else {
        Body::ToolCompleted(ToolCompleted {
            call_id,
            exit_code: exit,
            duration_ms: None,
            summary: non_empty(Some(&text)),
        })
    }
}

fn assistant_line(
    out: &mut Emitter<'_>,
    value: &Value,
    uuid: &str,
    at: OffsetDateTime,
    plan_id: &str,
    cursor: &mut Cursor,
) {
    let message = value.get("message");
    let turn_id = message
        .and_then(|message| message.get("id"))
        .and_then(Value::as_str)
        .unwrap_or(uuid)
        .to_owned();

    if let Some(Value::Array(blocks)) = message.and_then(|message| message.get("content")) {
        for (index, block) in blocks.iter().enumerate() {
            match block.get("type").and_then(Value::as_str) {
                Some("thinking") => {
                    if let Some(delta) = non_empty(block.get("thinking").and_then(Value::as_str)) {
                        out.push(
                            format!("{uuid}#{index}"),
                            at,
                            Body::TurnDelta(TurnDelta {
                                turn_id: turn_id.clone(),
                                delta,
                                kind: DeltaKind::Thinking,
                            }),
                        );
                    }
                }
                Some("text") => {
                    if let Some(text) = non_empty(block.get("text").and_then(Value::as_str)) {
                        out.push(
                            format!("{uuid}#{index}"),
                            at,
                            Body::TurnCompleted(TurnCompleted {
                                turn_id: turn_id.clone(),
                                role: TurnRole::Assistant,
                                text,
                                thinking: None,
                            }),
                        );
                    }
                }
                Some("tool_use") => {
                    let tool = block
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown");
                    let call_id = non_empty(block.get("id").and_then(Value::as_str))
                        .unwrap_or_else(|| format!("{uuid}-{index}"));
                    let input = block.get("input").unwrap_or(&Value::Null);
                    out.push(
                        format!("{uuid}#{index}"),
                        at,
                        Body::ToolStarted(ToolStarted {
                            call_id,
                            tool: tool.to_owned(),
                            summary: non_empty(first_str(input, &["description", "summary"])),
                            command: extract_tool_command(tool, input),
                            paths: extract_tool_paths(tool, input),
                            risk: Risk::classify_tool(tool, input),
                        }),
                    );
                    if tool == "TodoWrite"
                        && let Some(body) = plan_body(input, plan_id, cursor)
                    {
                        out.push(format!("{uuid}#{index}:plan"), at, body);
                    }
                    if let Some(body) = file_body(tool, input) {
                        out.push(format!("{uuid}#{index}:file"), at, body);
                    }
                }
                _ => {}
            }
        }
    }

    if let Some(usage) = message.and_then(|message| message.get("usage"))
        && let Some(body) = usage_body(usage)
    {
        out.push(format!("{uuid}#usage"), at, body);
    }
}

fn plan_body(input: &Value, plan_id: &str, cursor: &mut Cursor) -> Option<Body> {
    let todos = input.get("todos")?.as_array()?;
    let steps = todos
        .iter()
        .enumerate()
        .map(|(index, todo)| PlanStep {
            id: index.to_string(),
            title: first_str(todo, &["content", "title", "activeForm"])
                .map(|title| truncate(title, 200))
                .unwrap_or_default(),
            status: plan_status(todo.get("status").and_then(Value::as_str)),
        })
        .collect();
    let plan = Plan {
        plan_id: plan_id.to_owned(),
        title: None,
        steps,
    };
    Some(if cursor.flag(ClaudeCodeAdapter::PLAN_FLAG) {
        Body::PlanUpdated(plan)
    } else {
        Body::PlanCreated(plan)
    })
}

fn plan_status(status: Option<&str>) -> PlanStepStatus {
    match status {
        Some("in_progress") => PlanStepStatus::InProgress,
        Some("completed") => PlanStepStatus::Completed,
        Some("cancelled") => PlanStepStatus::Cancelled,
        _ => PlanStepStatus::Pending,
    }
}

fn file_body(tool: &str, input: &Value) -> Option<Body> {
    let path = first_str(input, &["file_path", "notebook_path"])?.to_owned();
    let change = FileChange {
        path,
        additions: None,
        deletions: None,
        bytes: input
            .get("content")
            .and_then(Value::as_str)
            .map(|content| content.len() as u64),
        unified_diff: None,
    };
    match tool {
        "Write" => Some(Body::FileCreated(change)),
        "Edit" | "MultiEdit" | "NotebookEdit" => Some(Body::FileModified(change)),
        _ => None,
    }
}

fn usage_body(usage: &Value) -> Option<Body> {
    let input_tokens = usage.get("input_tokens").and_then(Value::as_u64)?;
    Some(Body::UsageUpdated(UsageUpdated {
        input_tokens,
        output_tokens: usage
            .get("output_tokens")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        cached_input_tokens: usage.get("cache_read_input_tokens").and_then(Value::as_u64),
        cost_usd: None,
        rate_limit_percent: None,
        rate_limit_resets_at: None,
    }))
}

/// Session metadata sniffed from the head of a transcript.
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
            if value.get("isSidechain").and_then(Value::as_bool) == Some(true) {
                continue;
            }
            if sniffed.session_id.is_none() {
                sniffed.session_id = non_empty(value.get("sessionId").and_then(Value::as_str));
            }
            if sniffed.cwd.is_none() {
                sniffed.cwd = non_empty(value.get("cwd").and_then(Value::as_str));
            }
            if sniffed.git_branch.is_none() {
                sniffed.git_branch = non_empty(value.get("gitBranch").and_then(Value::as_str));
            }
            if sniffed.title.is_none()
                && value.get("type").and_then(Value::as_str) == Some("user")
                && let Some(Value::String(text)) = value.pointer("/message/content")
            {
                sniffed.title = non_empty(Some(text)).map(|text| truncate(&text, 80));
            }
            if sniffed.session_id.is_some()
                && sniffed.cwd.is_some()
                && sniffed.git_branch.is_some()
                && sniffed.title.is_some()
            {
                break;
            }
        }
        sniffed
    }
}
