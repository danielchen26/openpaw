# OpenPaw Proactive Radial Launcher Design

**Date:** 2026-08-26  
**Status:** Approved  
**Scope:** Authenticated iPhone workspace, with reusable compact-width behavior for iPad and macOS

## Problem

OpenPaw currently uses a paged `ControlDeck` strip to preserve terminal shortcuts, root navigation, dictation, search, copy and font controls without stacking multiple bars. It is materially better than the older three-bar layout, but it still reserves a horizontal control surface and makes the user search for the correct page before acting.

The desired interaction is a one-handed, context-aware launcher inspired by the supplied radial control reference. A user presses the bottom-right control and pushes upward. The launcher unfolds the real remote-work hierarchy one level at a time, shows a detailed proactive proposal in the upper-middle of the screen, and freezes that proposal on release. Nothing executes on the first release. A second explicit confirmation navigates, sends or runs the action.

The launcher must understand the current SSH host, Herdr workspace, tab, pane or agent, repository, tool and current page workflow. It must work across Home, Terminal, Sessions, Inbox, Repo and Settings without recreating separate menus per screen.

## Product decisions

The approved decisions are:

- Replace the existing compact `ControlDeck` handle and permanent strip with one 56-point Paw Orb at the bottom-right safe-area corner.
- Treat the connected SSH host as the implicit root. Keep `Switch Host` as a first-level edge branch.
- Follow the contextual hierarchy rather than a fixed category menu.
- Use a hybrid proposal source. Local deterministic rules appear immediately. Agent-derived suggestions arrive in the background.
- Show three ranked proposals plus `More`. Freeze item positions for the duration of a gesture.
- Update a proposal card in the upper-middle of the screen while the finger moves.
- On first release, freeze the preview. Require a second upward gesture or an explicit button before ordinary actions execute.
- Never execute destructive commands from a gesture. Navigate and prefill them, then require a clearly labelled red confirmation in Terminal.
- Cover every authenticated destination, not Terminal alone.
- Keep full-screen hold-to-talk on Terminal. Only a touch that begins inside the Paw Orb belongs to the radial launcher.

## Truthful Herdr hierarchy

The existing adapter flattens Herdr panes into `RemoteSession` values, even though the real Herdr topology is workspace, tab and pane. The new context graph must preserve that topology instead of building a visual hierarchy from lossy presentation data.

The user-facing path is:

```text
SSH Host
└── Herdr Workspace (presented as Session)
    └── Tab
        └── Pane / Agent
            ├── Repository
            ├── Tools
            └── Top 3 Proposals + More
```

For tmux, Zellij and GNU Screen, the same graph maps a multiplexer session to the Session level and a window to the Tab level. A leaf without discoverable windows gets one synthetic tab so the interaction remains consistent. Repository association is derived from the pane or session working directory and the allowlisted repositories returned by `OpenPawModel.repos`.

## Architecture

Use a context graph with independent rendering and execution layers.

### `WorkspaceContextGraph`

`WorkspaceContextGraph` is a pure, sendable snapshot. Every node has a stable ID, kind, title, subtitle, status, children and optional action. It contains no SwiftUI view values. The builder receives:

- selected host and connection generation;
- root destination and repo pane;
- structured Agent sessions and their normalized events;
- multiplexer workspaces, tabs and panes;
- selected Session and repository;
- Inbox state and repository summaries/status;
- available terminal and workspace tools.

The graph is rebuilt when source state changes. An open gesture retains one immutable snapshot so asynchronous refreshes cannot move a target under the user's finger.

### `ProposalEngine`

The engine merges two sources:

1. **Local rules** produce immediate actions such as continue the active plan step, review a dirty repository, inspect a failed tool, answer a pending question, resolve an Inbox request, retry a disconnected host or open the active terminal.
2. **Agent-derived suggestions** inspect the latest normalized `plan.created`, `plan.updated`, turn, tool and context events already emitted by the active Agent. The latest in-progress or pending plan step becomes a specific next-step suggestion without injecting a hidden prompt into the user's Agent session.

This first implementation intentionally does not start a second model turn merely to populate a menu. Hidden prompts would consume tokens, mutate session history and potentially race the user's work. A future host capability may provide advisory generation, but it must return read-only proposal data and must not write into the active session.

Ranking uses current page relevance, active Session/Tab, event freshness, plan status, pending Inbox work, repository association and failure state. Stable IDs and deterministic tie-breaking keep the Top 3 ordering predictable.

### `RadialLauncher`

`RadialLauncher` owns visual geometry, gesture tracking, haptics, selection and preview presentation. It does not perform navigation or remote work. Horizontal angle selects siblings. Distance from the Paw Orb selects depth. Pulling inward moves up one level. Returning to the origin cancels.

The Paw Orb doubles as a compact status light:

- neutral: ready;
- blue: connected context available;
- teal pulse: newer proposal available;
- amber: partial or stale context;
- red: disconnected or failed execution.

Local nodes must appear within 100 ms. Dragging must remain independent of Agent refresh and target 60 fps on supported phones.

### `ProposalExecutionCoordinator`

Execution is a separate `@MainActor` coordinator. It owns a monotonic generation and a unique operation ID. It checks the host ID, connection generation, graph snapshot ID, target Session/Tab and selected proposal again after every suspension.

The coordinator supports typed actions:

- navigate to a destination, Session, Tab, Repo or tool;
- attach or focus a multiplexer or Herdr pane;
- send a natural-language instruction to the selected Agent pane;
- prefill or send Terminal text;
- run a non-interactive tool action;
- switch hosts.

It routes first, waits for acknowledgement, verifies ownership, then dispatches once. A stale or disconnected target fails closed. Duplicate taps with the same operation ID cannot dispatch twice.

## Gesture and preview state machine

```text
idle
  → tracking
  → drilling
  → frozenPreview
  → confirming
  → routing
  → executing
  → completed | failed
```

`tracking` and `drilling` cannot execute actions. The first release always enters `frozenPreview`. Page changes, host changes, backgrounding and cancellation return to `idle` unless an already confirmed operation owns the current generation.

The proposal card shows:

- breadcrumb path from Host through target leaf;
- action source, either Local or Agent-derived;
- complete natural-language text or command;
- destination and repository;
- safe, caution or destructive risk;
- expected effect;
- confirmation, edit, copy and cancel controls.

Safe and caution actions may be confirmed by a short second upward gesture or a button. A destructive action cannot use gesture confirmation. It routes to Terminal, inserts text without Return and exposes an explicit destructive confirmation there.

Natural-language instructions are not automatically considered harmless. They use the same risk vocabulary as commands, and high-risk instructions are prefilled rather than sent. Existing host-side approval and Inbox boundaries remain authoritative.

## Preserving current controls

The existing Control Deck functionality is not deleted. It becomes context nodes beneath `Tools`:

- Terminal shortcuts and modifier keys;
- dictation;
- scrollback search;
- copy all output;
- font size;
- root destination navigation for users who do not use horizontal paging.

The normal page swipe remains available. VoiceOver receives an equivalent hierarchical list and adjustable actions, because a radial drag is not an accessible replacement for named controls.

## Voice recognition correction

“VoiceOver” and voice input are separate features. iOS VoiceOver remains the system screen reader. OpenPaw hold-to-talk and dictation use a speech-to-text recognizer.

The current source defaults to Apple Speech, but that path is not acceptable for OpenPaw voice input. Repository accuracy evidence says Apple averages roughly 22 percent character error across the bilingual benchmark and corrupts important English command names inside Chinese sentences. Qwen3-ASR 0.6B averages roughly 2 percent and is the model already covered by the app's physical-device accuracy acceptance. Qwen3-ASR 1.7B is larger and potentially more accurate, but costs about 1.9 GB and requires substantially more memory.

The approved product policy is therefore:

1. Default every new and migrated installation to Qwen3-ASR 0.6B.
2. Offer Qwen3-ASR 1.7B as an explicit “Maximum accuracy” option for recent high-memory devices.
3. Never use Apple Speech for OpenPaw voice input, including as a runtime fallback, simulator fallback or migration fallback.
4. If the selected Qwen model is absent or unsupported, voice input is unavailable and shows an actionable download or device-support explanation.
5. Never silently download model weights or silently substitute a different recognizer.
6. Keep any legacy Apple enum value only long enough to decode old settings, then migrate it to Qwen3 0.6B. It must not be exposed by Settings or returned by the runtime engine factory.

The radial launcher's VoiceOver accessibility path does not use these ASR models. Spoken accessibility labels remain owned by iOS.

## Accessibility and motion

- Paw Orb visual size is 56 points with at least a 64-point hit region.
- Every radial node has a minimum 52-point visual target and a 64-point selection region.
- State uses text, glyph and color rather than color alone.
- VoiceOver presents the frozen graph as a drill-down list with the complete proposal and risk read aloud.
- Reduce Motion replaces flying arcs with fade and scale transitions.
- Haptics mark activation, sibling changes, depth changes, freeze, success and failure, and can be disabled.
- The architecture permits a future left-handed mirror without changing graph or execution code.

## Failure behavior

- If Agent events are absent, local proposals still work.
- If Herdr tab metadata is unavailable, the graph creates one truthful synthetic tab and marks the context partial.
- If the structured backend is unavailable but SSH Terminal is connected, Terminal and multiplexer actions remain usable.
- If the host disconnects, the frozen preview remains readable and offers reconnect, copy or cancel.
- If routing succeeds but dispatch fails, the card identifies the failed stage and offers retry, navigate only or copy.
- Credentials, tokens, private keys and complete Terminal history never enter proposal text or Agent-derived metadata.

## Acceptance criteria

On a real iPhone and iOS Simulator:

1. Pressing the Paw Orb with the software keyboard open hides the keyboard and reveals local nodes within 100 ms.
2. The launcher drills through Host, Herdr Session, Tab, Pane, Repo or Tool and proposals using one continuous gesture.
3. `Switch Host` remains reachable without obscuring the normal Session path.
4. Proposal item positions do not change while a gesture is active.
5. Releasing once never dispatches.
6. A confirmed natural-language action routes to the exact target and sends once.
7. A safe Terminal command sends once only after confirmation.
8. A destructive command is only prefilled and cannot run through gesture confirmation.
9. Home, Terminal, Sessions, Inbox, Repo and Settings all expose relevant context.
10. Terminal dictation, typing, scrolling, search and root destination swipes still work.
11. VoiceOver exposes an equivalent named hierarchy.
12. High-accuracy voice preference is visible and truthful, with no silent model download or fallback.
13. Final snapshots show no permanent stacked bottom chrome, clipping or obscured proposal card.

## Git completion policy

After the major implementation and real-device acceptance pass, perform a complete Git audit, commit only feature-related files, push the active branch, and verify local `HEAD` equals the remote branch SHA. Preserve the existing local `apps/ios/OpenPaw.xcodeproj/project.pbxproj` development-team and formatting difference unless this feature requires a separately staged clean project-file change.
