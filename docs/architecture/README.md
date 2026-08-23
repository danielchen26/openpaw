# Architecture

## The one-sentence version

The remote host keeps running everything; OpenPaw adds a *structured* channel next to the PTY so a phone can
understand what an agent is doing and answer it safely.

## Layers

```
apps/ios/OpenPawApp          SwiftUI shell, SwiftTerm surface, dictation, image capture
  packages/swift-openpaw-ui  every screen, platform-agnostic, snapshot-rendered in CI
  packages/swift-ssh-transport  SSHTransport, PortForwarder, KeychainStore
  packages/swift-terminal-core  RemoteTransport seam, multiplexers, scrollback, keymaps, host store
  packages/swift-agent-protocol OpenPawProtocol: events, risk, inbox, HostClient (REST + SSE)
                       |
             one SSH connection
                       |
host/crates/openpaw-host      axum on 127.0.0.1: auth, capabilities, SSE bus, audit
  openpaw-agents              adapters: claude-code, codex, opencode, generic
  openpaw-git                 status, diff, tree, blob, log — read-only, allowlisted
  openpaw-files               the filesystem security boundary
  openpaw-preview             loopback reverse proxy for dev servers
  openpaw-protocol            the normalized event, risk classifier, inbox projection, request signing
```

Nothing above depends on anything below it except through those seams. `openpaw-protocol` and
`OpenPawProtocol` are deliberate duplicates: one wire format, two independent implementations, both pinned to the
same golden files, so a drift in either is a test failure rather than a field bug.

## Product and distribution boundaries

The architecture is intentionally broader than the set of features that may ship today. These decision records are
release constraints, not aspirational notes:

- [ADR 0001](../decisions/0001-mosh-distribution-gate.md) keeps native Mosh unlinked and unavailable until Gate M0
  resolves licensing, distribution, interoperability, and physical-device lifecycle.
- [ADR 0002](../decisions/0002-et-provenance-distribution-gate.md) keeps Eternal Terminal protocol-only and
  unavailable until the independent Gate E0 resolves provenance, distribution, real-server interoperability, and
  lifecycle behavior.
- [ADR 0003](../decisions/0003-tailscale-discovery-boundary.md) defines Tailscale-assisted discovery without
  claiming access to the installed iOS application's account or peer list.
- [ADR 0004](../decisions/0004-provider-token-boundary.md) keeps repository-provider credentials on the selected
  host and preserves the no-arbitrary-execution boundary for imports.

Until M0 and E0 are approved, SSH is the only production terminal transport and unavailable transports are omitted
from product UI rather than shown as disabled promises.

## Why two sources of truth, and which one wins

| Question | Authority |
| --- | --- |
| What is actually executing right now? | the PTY / terminal |
| What was said in the conversation? | the agent's own transcript |
| What does the phone display? | a projection of the two |

This is why Chat View never reconstructs a conversation by scraping ANSI output. Screen-scraping a TUI is fragile
in exactly the cases that matter — a redrawn spinner, a resized window, a `clear`. The adapters read the agent's
structured logs instead, and the terminal remains available and authoritative for execution.

Corollary: closing Chat View, the Inbox or the whole app stops nothing. The agent, the shell, the multiplexer
session and the working directory are all owned by the host.

## Durable sessions

Mosh would solve *network* mobility: a UDP session can survive a Wi-Fi-to-cellular handoff. It does not solve
*process* lifetime — when the remote shell exits, it is gone. tmux (or Zellij, screen, Herdr) solves process
lifetime. The production transport today is SSH, paired with a host-side multiplexer for durable processes:

```
app  --SSH today; Mosh/ET future-->  host  --attach-->  tmux  --runs-->  agent
```

`TransportSelector` does not ship automatic Mosh or Eternal Terminal selection. The default planning path uses
`ExperimentalTransportFeatures.disabled`, so ET is excluded and SSH remains the only production transport. Native
Mosh is not implemented and is gated on licensing plus iOS UDP/background feasibility. An isolated Eternal Terminal
foundation exists, but it is disabled by default and is not app-integrated or validated against real `etserver` or
physical devices. The seam (`RemoteTransport`) exists so future transports can be additions rather than rewrites.

## Event flow for an approval

```mermaid
sequenceDiagram
  participant CC as Claude Code
  participant H as openpaw-host
  participant A as OpenPaw app
  CC->>H: PreToolUse hook (tool + input)
  H->>H: classify risk, project InboxItem, mint one-time action token
  H-->>A: SSE permission.requested
  A->>A: gate UI on risk.requires_detail_expansion
  A->>H: POST /v1/inbox/{id}/resolve {action, action_token, detail_acknowledged}
  H->>H: verify token (single use, 10 min), write audit line
  H->>CC: decision file / hook response
  H-->>A: SSE permission.resolved
```

The push notification, when one exists, carries an opaque session id and a one-line preview and nothing else. The
command text, the diff and the transcript are fetched over the tunnel. A notification is never a capability.

## Extending the terminal beyond SSH

`TerminalScreen` renders bytes; it has no idea what produced them. That is what makes a local shell, `kubectl
exec`, `docker exec`, a serial console or a WebSocket PTY additions rather than forks. The only requirement is a
`RemoteTransport`.
