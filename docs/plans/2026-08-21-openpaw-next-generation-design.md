# OpenPaw Next-Generation Product Design

**Date:** 2026-08-21
**Status:** Approved direction
**Product thesis:** OpenPaw is the local-first mobile control plane for coding agents. It should combine a real terminal, agent-native context, safe approvals, durable sessions, and repository inspection in a mobile interface that feels calmer and more capable than Moshi.

## Goals

1. Deliver a distinctive modern iOS experience without reducing terminal density or safety.
2. Make first-run setup and reconnection understandable to people who do not think in SSH internals.
3. Present Tailscale-reachable machines as workspaces, not as a flat server inventory.
4. Preserve and improve Herdr, tmux, Zellij, and screen workflows.
5. Make voice a first-class, local-first input for both terminal and agent conversation.
6. Add resilient Mosh and Eternal Terminal transports behind the existing `RemoteTransport` seam.
7. Match Moshi's valuable Apple-platform integrations while differentiating through open protocol, stronger risk gates, and richer workspace context.

## Product principles

### The workspace is the unit of navigation

A person wants to return to “OpenPaw on the Mac mini,” not manually reconstruct a hostname, repository, multiplexer, window, and agent session. OpenPaw therefore presents this hierarchy:

`Device → Workspace → Session → Surface`

A workspace combines a host, recent directory or repository, active agent sessions, multiplexer sessions, pending approvals, Git state, and preview ports. Terminal, Chat, Inbox, Repo, and Preview are projections of the same workspace.

### Progressive disclosure

The first screen shows what can be acted on now: devices, active work, approvals, and a primary resume action. SSH ports, key references, jump hosts, transport policy, and terminal geometry remain available in advanced configuration but do not dominate first-run use.

### Local-first safety

Tailscale and SSH discovery produce candidates only. A person must confirm a device before it enters the allowlist. Host keys stay pinned, changed keys remain a hard block, and no discovery path silently expands access. Voice never sends a command before the transcript is reviewable. Risky commands require explicit confirmation.

## Visual system: “signal in the dark”

The signature element is a quiet connection signal that runs through the product: a small orbital indicator whose motion and color communicate discovery, dialing, online, degraded, sleeping, and blocked states. This is not decorative glow. It is the shared visual language for devices, transports, agents, and voice capture.

### Palette

- `Void` `#080B10`: primary canvas
- `Graphite` `#111722`: raised machine surface
- `Ember` `#1B1817`: warm human/prose surface
- `Signal` `#7C9CFF`: navigation and healthy connection focus
- `Pulse` `#60D5B2`: active transport and completed work
- `Caution` `#F4BE5B`: waiting, degraded, or attention required
- Existing semantic risk ramp remains authoritative for approvals

The existing machine/human register is preserved because it is specific to OpenPaw and useful. The redesign adds spatial hierarchy and a connection signature rather than replacing the established information model with generic glass cards.

### Type

- Machine facts, commands, metrics, and controls continue to use the system monospaced design.
- Human prompts and explanations continue to use the serif register.
- Navigation titles use a restrained rounded system face to improve scanability at mobile sizes.
- Dynamic Type remains mandatory. No fixed-size semantic text.

### Surfaces

Glass-like material is reserved for transient chrome: the workspace switcher, floating voice composer, and connection overlays. Terminal, diffs, files, logs, and approval details use opaque high-contrast surfaces. Motion respects Reduce Motion and stops when the app is inactive.

## Information architecture

### Home

The compact root gains a `Home` destination and becomes the default first-run destination. Home contains:

- Tailnet/SSH reachability summary
- Device cards with online state, transport recommendation, latency band, multiplexer, active agents, pending approvals, and recent workspace
- Active work timeline
- Pending approval summary
- Primary actions: Resume, Connect, Add device, Voice command

When there are no hosts, Home becomes guided onboarding. It must never attempt a backend refresh or show “The tunnel is down.”

### Device discovery

Milestone 1 models discovery candidates without taking a dependency on a Tailscale account or cloud API. Sources are explicit and local:

- Manual hostname or MagicDNS name
- Imported OpenPaw host configuration
- Optional future Tailscale LocalAPI provider

Candidates display their source and remain untrusted until confirmed. A hostname ending in `.ts.net`, a `tailscale` tag, or an explicit source can be presented with Tailscale vocabulary, but heuristics never grant access.

### Workspace

Selecting a device opens a workspace overview before the terminal. It shows:

- Resume last session
- Herdr/tmux/Zellij/screen spaces
- Active coding agents and context usage
- Repository status and changed-file count
- Pending approvals
- Discovered local preview ports
- Recent directories

Power users can set “connect straight to terminal” per device.

## Voice design

A unified composer supports Terminal and Agent destinations. It shows live waveform, partial transcript, engine, language, and privacy state. The transcript is always editable before sending. Apple Speech remains the baseline. WhisperKit or `whisper.cpp` model management follows in a separate milestone, with downloads, deletion, storage accounting, and offline status. Code-aware corrections are suggestions, not silent rewrites.

## Sessions and transports

Herdr, tmux, Zellij, and screen are presented as session spaces through the existing multiplexer abstraction. SSH, Mosh, and Eternal Terminal conform to `RemoteTransport`. Transport selection considers explicit preference, last success, network capability, and fallback behavior. Reconnection restores the previous multiplexer session instead of creating an unrelated shell.

## Apple ecosystem

After the core mobile workflow is stable:

- Live Activities and Dynamic Island show agent state, approvals, and connection health.
- Apple Watch is deliberately limited to status, approve, deny, stop, and open iPhone.
- Push notifications are hints only. Approval authority remains a single-use action token delivered over an authenticated channel.

## Error and empty-state language

Errors name the failed layer and the next action:

- “No device added” → “Add a Tailscale or SSH device”
- “Device is asleep” → “Wake it or connect when it returns online”
- “Tailscale is disconnected” → “Open Tailscale, then try again”
- “SSH is disabled” → “Enable Remote Login on this Mac”
- “Host key changed” → hard block with fingerprint comparison

Generic “tunnel down” language is reserved for a previously established forwarded tunnel that actually failed.

## Delivery order

1. Design tokens and reusable components
2. First-run onboarding and Home
3. Device/workspace presentation and discovery candidates
4. Unified voice composer
5. Herdr and multiplexer session polish
6. Native Mosh and Eternal Terminal
7. Live Activities, Dynamic Island, and Watch
8. Physical-device and live-host release validation

## Success measures

- A new user reaches an understandable Add Device screen without an error alert.
- A returning user resumes an active workspace in two taps or fewer.
- Every connection failure provides a specific recovery action.
- Terminal, Chat, Voice, Inbox, and Repo retain one shared workspace context.
- All automated checks, UI snapshots, simulator flows, and documented physical-device acceptance scenarios pass.
