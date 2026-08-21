# Host API

`openpaw-host` speaks HTTP on loopback only. The phone reaches it by forwarding the port over its own SSH
connection (`direct-tcpip`), so there is no listening socket on any network interface and no cloud hop. Binding
elsewhere requires `--i-understand-the-risk` and logs a warning on every start.

Base path is `/v1`. All bodies are JSON unless stated. All timestamps are RFC 3339.

## Authentication

Two routes are public: `GET /v1/health` and `POST /v1/pair`. One route is authenticated by a local file token:
`POST /v1/hooks/{agent}`. Everything else requires a paired device to send **both** a bearer token and a
signature:

```
Authorization:         Bearer <device token>
X-OpenPaw-Device:      dev_…
X-OpenPaw-Timestamp:   1787245200            # unix seconds, ±300 s
X-OpenPaw-Nonce:       9f2c1ab34d5e6f70      # unique within 600 s
X-OpenPaw-Signature:   <lowercase hex HMAC-SHA256>
```

The signature covers a canonical string, so a captured signature cannot be replayed onto another route or another
body:

```
METHOD \n PATH_WITH_QUERY \n TIMESTAMP \n NONCE \n SHA256_HEX(BODY)
```

The host stores only `sha256(token)` and compares in constant time. The HMAC key is per device. Losing a phone
means revoking one device, not rotating everything. Authenticated requests consume a nonce only after the HMAC
signature verifies. If replay-protection capacity is full while remembered nonces are still within the 600-second
TTL, the host fails closed with `429 {"error":"nonce_cache_full"}` instead of evicting an unexpired nonce.

Each route additionally requires a capability from `protocol/capability-spec/capabilities.json`. The `observer`
profile holds only read capabilities, so an observer device physically cannot approve, upload or proxy — it gets
`403` with the missing capability named.

### Pairing

```sh
openpaw-host pairing-code          # ABCD-EFGH-IJKL-MNOP-QRST-UVWX, valid 5 minutes, single use
```

```http
POST /v1/pair
{"pairing_code": "ABCD-…", "device_name": "Daniel's iPhone", "platform": "ios"}

200 {"device_id": "dev_…", "token": "…", "hmac_key_b64": "…", "capabilities": ["…"]}
```

The code is consumed on first use. The token and key are returned exactly once and belong in the Keychain.

## Routes

### `GET /v1/health` — public

```json
{
  "version": "0.1.0",
  "protocol": "1",
  "agents": ["claude-code", "codex", "opencode"],
  "capabilities": ["sessions.read", "events.read", "…"],
  "preview_ports": [3000, 5173],
  "adapter_versions": {"claude-code": "claude-code/transcript-v1", "codex": "codex/rollout-v1"}
}
```

`adapter_versions` is the first thing to check in a bug report: these agent formats move, and it names which
parser is running. `preview_ports` is typed rather than encoded in a capability string so the preview picker can
offer exactly the ports that will work.

### `GET /v1/sessions` — `sessions.read`

```json
[{"session_id": "sess_cc-57ae0add-…", "agent": "claude-code", "title": "Fix the failing parser test",
  "cwd": "/Users/dev/src/openpaw", "git_branch": "main", "multiplexer_target": "work:2.0",
  "state": "working", "last_event_at": "2026-08-20T14:30:40Z", "last_seq": 41, "pending_inbox": 1}]
```

`state` is one of `idle`, `working`, `waiting`, `failed`, `exited`. `waiting` means a human is the blocker.

### `GET /v1/events?session=&after_seq=` — `events.read`

`text/event-stream`. The backlog from `after_seq` is replayed from an in-memory ring (2000 events per session by
default), then the stream follows live. A `:` keep-alive comment every 15 seconds keeps intermediaries honest.

```
data: {"version":"1","event_id":"evt_…","seq":42,"type":"tool.started","payload":{…}}

```

Resume is exact rather than best-effort: `seq` is dense per session, and `event_id` is content addressed, so a
reconnect that overlaps cannot duplicate a row. See `docs/protocol/README.md`.

### `GET /v1/inbox?status=` — `inbox.read`

Array of inbox items (`protocol/json-schema/inbox-item.schema.json`). Each pending item carries a single-use
`action_token` with a 10-minute TTL. Tokens exist only here, over the tunnel — never in a push payload.

### `POST /v1/inbox/{id}/resolve` — `approvals.write`

```json
{"action": "approve_once", "action_token": "…", "answer": null, "detail_acknowledged": true}
```

- `400` when the item's `risk.requires_detail_expansion` is true and `detail_acknowledged` is not. The host
  enforces the gate; the app does too. Neither trusts the other.
- `401` when the action token is missing, expired, or already used.
- `403` when the device lacks `approvals.write`.
- `200` `{"status": "resolved", "event_id": "evt_…"}`, plus an audit line, a `permission.resolved` event on the
  stream, and a decision file at `<state_dir>/decisions/<request_id>.json` that the agent's hook reads back.

### Repository inspection — `repos.read`, blobs need `files.read`

```
GET /v1/repos
GET /v1/repos/{repo}/status
GET /v1/repos/{repo}/diff?path=&staged=&commit=&base=&head=
GET /v1/repos/{repo}/tree?ref=&path=
GET /v1/repos/{repo}/blob?ref=&path=
GET /v1/repos/{repo}/search?q=&path=
```

All read-only. `{repo}` names an allowlisted root; paths are resolved through the same canonicalizing boundary
that rejects `..`, absolute paths, NUL bytes and symlinks that escape the root. Revs are validated against a
conservative character set and can never be read as a `git` flag. Diffs are parsed into hunks and lines with
correct old/new numbering, including renames, binary files and missing trailing newlines.

### `GET /v1/tailscale/devices` — `devices.read`

Runs exactly the fixed host-side argv `tailscale status --json` with no shell, no request-controlled path, and no request-controlled arguments. The command is read-only and bounded by timeout and output-size limits.

Response data is sanitized candidate metadata only:

```json
{
  "version": 1,
  "candidates": [{
    "id": "n123",
    "display_name": "macbook",
    "dns_name": "macbook.tailnet.ts.net",
    "tailscale_ips": ["100.64.0.2", "fd7a:115c:a1e0::2"],
    "os": "macOS",
    "online": true,
    "last_seen": "2026-08-21T07:00:00Z"
  }]
}
```

The response never includes raw `tailscale status` JSON, users, keys, route advertisements, credentials, or command output. Candidates are metadata only. They are not SSH-ready, trusted, or verified, and clients must not label them that way. Candidate strings are bounded and control-character-free, optional fields with wrong types are rejected, `last_seen` must be valid RFC3339 when present, and reported addresses must be in Tailscale ranges (`100.64.0.0/10` or `fd7a:115c:a1e0::/48`).

Typed unavailable states include missing Tailscale CLI, logged-out Tailscale from parsed `BackendState`, generic process/CLI unavailable failures, timeout, output limit, busy when
another process-backed discovery is already running, and `unavailable_state` when `BackendState` is absent,
non-string, unknown, or otherwise not a known running state. Malformed or unsupported CLI JSON after a supported
running state is a hard server error with safe user text.

### `POST /v1/uploads` — `uploads.write`

Raw bytes with `X-OpenPaw-Filename: shot.png`. The filename must be a bare basename with an allowlisted
extension. Writes to `<state_dir>/uploads/<uuid>.<ext>` and returns `{"path", "bytes", "sha256"}`. The remote path
is what gets handed to the agent, which keeps image attachments entirely inside the machines you own — no relay,
no short-lived public URL.

### `ANY /v1/preview/{port}/{*rest}` — `preview.proxy`

Reverse-proxies an allowlisted loopback port. Streams bodies without buffering so Server-Sent Events and Vite HMR
work, upgrades WebSockets, strips hop-by-hop headers, and rewrites `Location`, `Content-Location` and `Set-Cookie`
so redirects and cookies stay inside the mount prefix. A port outside the allowlist is refused before any
connection is attempted.

### `GET /v1/audit?limit=` — `inbox.read`

Append-only log of every authenticated mutating request and every pairing: `{"at", "device_id", "action",
"target", "result"}`.

### `POST /v1/hooks/{agent}` — hook token

Agent hooks post their native payload here with `X-OpenPaw-Hook-Token` matching `<state_dir>/hook-token` (mode
0600). The adapter normalizes it, the host publishes it, and the response is whatever the agent's hook protocol
expects — for Claude Code, `{"decision": "approve"|"block", "reason": "…"}` when a decision already exists,
otherwise `{}` so the CLI keeps its own prompt. `hook_wait_ms` (default `0`) bounds how long the hook will block
waiting for a phone, so a user without one is never stuck.

## The route that does not exist

There is no `POST /v1/exec`, no `/v1/run`, and no endpoint that takes a command. The app already owns an
authenticated PTY channel; a second, weaker path to the same power would only widen the blast radius. This is a
permanent design decision, and `scripts/smoke.py` asserts the absence.

## Errors

| Status | Meaning |
| --- | --- |
| `400` | The request was understood and refused — most often the detail-expansion gate |
| `401` | Not paired, bad signature, stale timestamp, replayed nonce, spent action token |
| `403` | Paired but missing the capability, which is named in the body |
| `404` | Unknown repo, item, or route |
| `413` | Body over `max_upload_bytes` |
| `502` | The proxied dev server is not answering |

## State directory

`$OPENPAW_STATE_DIR`, else `~/.openpaw`:

```
config.toml            bind, port, repos, preview_ports, limits, agent toggles
state.json      0600   devices: id, name, platform, hmac key, sha256(token), capabilities, timestamps
hook-token      0600   local hook authentication
audit.jsonl            append only
decisions/             one file per resolved request, read back by agent hooks
uploads/               attachment sink
```
