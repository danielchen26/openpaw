# Agent adapters

An adapter turns one agent's private, unstable, on-disk bookkeeping into the normalized event stream. It never
screen-scrapes a TUI, because a redraw, a resize or a `clear` would silently corrupt the result.

## Capability matrix

| Adapter | `format_version()` | Source | Turns | Tools | Plans | Usage | Files | Permissions |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `claude-code` | `claude-code/transcript-v1` | `~/.claude/projects/<slug>/<uuid>.jsonl` + hooks | yes | yes | yes (`TodoWrite`) | yes | yes | yes, via `PreToolUse` |
| `codex` | `codex/rollout-v1` | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | yes | yes | no | yes (+ rate limits) | yes (`patch_apply_end`) | no hook surface yet |
| `opencode` | `opencode/storage-v1` | `~/.local/share/opencode/storage/{session,message,part}` | yes | yes | no | yes (+ cost) | yes (`patch` parts) | no hook surface yet |
| `generic` | `generic/markers-v1` | OSC 9 / OSC 777 / `OSC 1337;OpenPaw=` | markers only | markers only | no | no | no | no |

An agent that is not in this table still runs perfectly well as a terminal program. What it loses is the
structured Inbox, Chat View, notifications and diff linkage — not functionality.

## Why versioned adapters, not "support"

These formats are internal to their tools and change without notice. Every adapter therefore has:

- a **fixture** in `protocol/fixtures/<agent>/`, captured from a real run;
- a **golden** in `protocol/fixtures/normalized/<agent>.events.json`, byte-compared in CI;
- a **format version** reported at runtime and shown in the app's diagnostics;
- **incremental-parse tests** proving a resumed cursor never re-emits an `event_id`.

When a format shifts, the golden test fails in CI before a user sees a wrong approval prompt. That is the entire
design goal.

## Discovery

Sessions are found by scanning the agent's own directories and filtering by modification time
(`session_max_age_days`, default 7). Tailing is by **offset + mtime + size polling**, every 750 ms, deliberately
not inotify/FSEvents: transcripts commonly live on network filesystems, in WSL, or on a volume where watches are
unreliable, and a missed watch is a silently stale Inbox.

Claude Code sidechain lines (`isSidechain: true`) are skipped so a subagent's tool calls do not appear as the main
session's approvals.

## The permission path

Only Claude Code currently exposes a pre-execution hook, so it is the only adapter that can *hold* an action
pending your approval:

```json
{
  "hooks": {
    "PreToolUse":   [{ "hooks": [{ "type": "command", "command": "openpaw-host hook claude-code" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "openpaw-host hook claude-code" }] }],
    "Stop":         [{ "hooks": [{ "type": "command", "command": "openpaw-host hook claude-code" }] }]
  }
}
```

`openpaw-host install-hooks --agent claude-code` writes this into `~/.claude/settings.json`, merging rather than
replacing. The hook posts to the loopback daemon with the hook token, and by default returns immediately
(`hook_wait_ms = 0`) so a user without a phone is never blocked. Set `hook_wait_ms` to hold the CLI while you
decide on the phone.

Codex and OpenCode are read-only today: their events populate the Inbox as notifications, and you approve in the
terminal or Chat View. When they expose a pre-execution hook, the adapter's `parse_hook` is where it lands.

## Adding an adapter

See `CONTRIBUTING.md`. In short: fixture, golden, format version, matrix row, incremental test. An adapter without
a fixture is a guess, and guesses about someone else's private format do not belong in an approval path.
