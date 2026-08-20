# Protocol reference

Wire format: `protocol/json-schema/event.schema.json` and `protocol/json-schema/inbox-item.schema.json`.
Capabilities and request signing: `protocol/capability-spec/capabilities.json`. Two independent implementations
(`host/crates/openpaw-protocol` in Rust, `packages/swift-agent-protocol` in Swift) are pinned to the same golden
files in `protocol/fixtures/normalized/`.

## Envelope

```json
{
  "version": "1",
  "event_id": "evt_9f2c1ab34d5e6f708192a3b4",
  "session_id": "sess_cc-57ae0add-f501-42d6-a04d-618fc9d3bfae",
  "agent": "claude-code",
  "seq": 12,
  "timestamp": "2026-08-20T14:30:02Z",
  "cwd": "/Users/dev/src/openpaw",
  "git_branch": "main",
  "multiplexer_target": "work:2.0",
  "type": "tool.started",
  "payload": { "call_id": "toolu_01", "tool": "Bash", "command": "pytest tests/unit -q",
               "summary": "Run test suite", "paths": [],
               "risk": { "class": "read_only", "requires_detail_expansion": false, "reasons": [] } }
}
```

`event_id` is **content addressed**: `"evt_" + sha256(session_id || 0x1F || source_key)[..24]`. Re-reading a
transcript therefore produces identical ids, which is what makes ingestion idempotent and lets a client dedupe
without server state. Never derive it from a wall clock.

`seq` is dense and monotonic per session, so `GET /v1/events?after_seq=` is an exact resume point rather than a
best-effort one.

`cwd`, `git_branch` and `multiplexer_target` are always present, `null` when unknown.

## Event catalogue

| Type | Payload | Notes |
| --- | --- | --- |
| `agent.started` / `.working` / `.completed` / `.failed` | `AgentLifecycle` | lifecycle of one agent session |
| `turn.started` / `.delta` / `.completed` | `TurnStarted` / `TurnDelta` / `TurnCompleted` | `delta.kind` separates `text` from `thinking` |
| `tool.started` / `.output` / `.completed` / `.failed` | `ToolStarted` / `ToolOutput` / `ToolCompleted` / `ToolFailed` | `tool.started` always carries a `Risk` |
| `permission.requested` / `.resolved` | `PermissionRequested` / `PermissionResolved` | the approval workflow |
| `question.requested` / `.answered` | `QuestionRequested` / `QuestionAnswered` | clarifying questions |
| `plan.created` / `.updated` | `Plan` | todo/plan lists |
| `file.read` / `.created` / `.modified` / `.deleted` | `FileChange` | `unified_diff` when the agent supplies one |
| `usage.updated` | `UsageUpdated` | tokens, cost, rate-limit percentage |
| `context.updated` | `ContextUpdated` | context-window pressure |

Unknown `type` values MUST NOT be a hard error. The Swift decoder keeps them as `.unsupported(type:payload:)` and
round-trips them unchanged, so an older app talking to a newer host degrades instead of breaking.

## Risk classification

Eight classes: `read_only`, `local_write`, `git_operation`, `network_access`, `package_installation`,
`destructive_shell`, `credential_access`, `unknown`. A command line is split on `&&`, `||`, `;`, `|` and newlines;
every segment is classified; the highest severity wins in that order, with `sudo`/`env` prefixes seen through.

`requires_detail_expansion` is a separate axis from the class. It is true whenever the decision deserves reading
the actual text: `rm`, `sudo`/`doas`, credential paths, `git push --force`/`--force-with-lease`, production deploy
markers, database mutations, secret modification. Clients MUST refuse to send an approval for such an item unless
they have displayed the full detail and set `"detail_acknowledged": true`; the host enforces this with a 400.

## Inbox projection

Events become actionable items: `permission.requested` → `permission`, `question.requested` → `question`,
`plan.*` → `plan`, `tool.failed` / `agent.failed` → `tool_failure`, `agent.completed` → `completion`,
`context.updated` at ≥ 85 % → `context_warning`, `usage.updated` at ≥ 90 % rate limit → `rate_limit`. Everything
else projects to nothing and stays in the stream.

`action_token` is minted by the host, never by an adapter, is single-use with a 10-minute TTL, and is delivered
only over the authenticated tunnel.

## Versioning rules

Add event types; never repurpose one. Add payload fields as optional; never change a field's type. Bump
`version` only for a breaking envelope change, and then support both for one release. Adapters carry their own
`format_version()` describing the *agent* format they parse, which is independent of the protocol version.
