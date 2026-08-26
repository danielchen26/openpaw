# OpenPaw iPhone Interaction Simplification Design

**Date:** 2026-08-26

## Product decision

The iPhone app is a remote control for one active machine and one active surface at a time. Compact width must not expose desktop-style simultaneous navigation or advanced administration on the primary path.

## Home

- Use the user-facing term **Tailscale**, not **Tailnet**, in titles and actions. Tailnet remains valid only where the actual account/network name is shown.
- Merge network summary, discovery explanation, and duplicate device grids into one **Machines** section.
- Online candidates and saved online machines are primary actions. A tap selects the machine, connects automatically when needed, and opens Terminal.
- Offline machines remain visible but clearly say that tapping will try to reconnect.
- Move **Remote catalog transfer** out of Home. Rename it **Import repository** and expose it from repository/settings advanced navigation only.
- Keep Add machine and Scan pairing code as secondary actions.

## Terminal and connection controls

- The connected-host chip remains the single machine control.
- Selecting another host connects it directly instead of requiring a second Connect action.
- Reconnect and Disconnect must be generation-owned model operations so overlapping menu tasks cannot leave stale state.
- Disable connection actions while a host operation is active and show concise progress/failure state.

## Compact navigation and Herdr sessions

- iPhone renders exactly one root destination at a time.
- The bottom control shows only the current destination identity plus previous/next affordances. Horizontal paging and accessibility/keyboard alternatives remain available.
- Herdr, tmux, Zellij, and screen sessions stay inside Sessions. Opening one navigates to its detail/terminal surface instead of retaining a side panel beside the active view.
- iPad and Mac retain split navigation.

## Terminal keyboard and voice

- Opening terminal search stows the custom control deck and resigns terminal first responder before focusing the search field.
- Closing search restores the prior control-deck state without forcing the software keyboard open.
- Voice shows explicit permission, listening, recognizing, transcript, and actionable failure states.
- Physical-device acceptance is required for microphone and Apple Speech recognition. Simulator tests cover state transitions and UI behavior only.

## Visual direction

Keep OpenPaw's graphite/signal language, but reduce density. The distinctive mobile signature is a single high-confidence machine row with a live status pulse and one verb. Remove machine-readable eyebrow copy from primary phone surfaces unless it communicates real state.

## Acceptance

1. Home contains no Remote catalog transfer panel and no Tailnet discovery title.
2. Tapping an online machine reaches Terminal without a second Connect action.
3. Host selection, reconnect, and disconnect each have deterministic regression coverage.
4. Terminal search hides/stows the custom keyboard deck.
5. Dictation failures display an actionable reason.
6. Compact root navigation never lays out six destination buttons simultaneously.
7. iPhone snapshots for populated Home, Terminal, and session space are visually reviewed.
