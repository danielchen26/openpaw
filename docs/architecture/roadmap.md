# Roadmap

Ordering is deliberate: each stage is only started once the stage below it is real, tested and shipped, because
every one of these features is a liability if the layer under it is guesswork.

## Shipped

- **Protocol** — normalized event + inbox schema, capability spec, request signing, golden fixtures for three
  agents captured from their real on-disk formats.
- **Host daemon** — loopback axum server, per-device pairing, HMAC-signed requests with replay protection,
  capability enforcement, SSE event bus with backlog replay, audit log, git inspection, allowlisted file access,
  loopback dev-server proxy, upload sink, agent hook ingress.
- **Swift packages** — `OpenPawProtocol` (events, risk classifier, inbox projection, REST + SSE client),
  `OpenPawTerminalCore` (transport seam, tmux/Zellij/screen/Herdr adapters, scrollback, OSC 52/8, keymaps, host
  store, session restoration), `OpenPawSSH` (NIOSSH transport, jump hosts, port forwarder, keychain),
  `OpenPawUI` (every screen).
- **App** — multi-host, multi-session terminal on SwiftTerm with hardware keyboard, CJK input, gestures and a
  shortcut toolbar; tmux discovery and attach; Inbox with risk-gated approvals; Chat View; diff viewer; file
  browser; dev-server preview; Apple Speech dictation in terminal and composer modes; image attachment with
  annotation; Face ID gate; config export/import; workspace-first Home; truthful device signal cards; guided,
  reversible Tailscale-candidate and manual SSH onboarding; adaptive compact navigation.

## In progress — unified mobile workflows

- **Unified voice composer.** One editable state machine for Apple Speech in Agent and Terminal destinations. A
  dictated terminal phrase must remain a draft until the user explicitly chooses Execute; stopping dictation must
  not race or discard a late final transcript. Whisper model management is a separate follow-up.
- **Session space.** Present OpenPaw agent sessions and discovered Herdr/tmux/Zellij/screen sessions together without
  erasing provenance. Wire restoration plans and the existing multiplexer actions into the shipped root flow.
- **Real Tailscale discovery.** The current onboarding labels candidates honestly and never calls them trusted. The
  next step is paired-host discovery plus explicit save/trust and SSH credential handoff. OpenPaw cannot read the
  installed iOS Tailscale application's account or peer list; the boundary is recorded in
  [ADR 0003](../decisions/0003-tailscale-discovery-boundary.md).
- **Repository providers.** Add host-scoped GitHub and Hugging Face authorization, sanitized browsing, hardened
  HTTPS-only import, and canonical workspace registration without returning tokens or introducing a remote shell
  endpoint. The credential and clone boundary is recorded in
  [ADR 0004](../decisions/0004-provider-token-boundary.md).

## Next — resilient mobile transport

- **Mosh transport feasibility.** Native Mosh is not implemented. The hard part is not compiling the C++ core, it is
  the UDP lifecycle across iOS background suspension, resynchronising terminal state after a kill, and third-party
  license compliance in an App Store build. It can only land behind `RemoteTransport` after Gate M0 in
  [ADR 0001](../decisions/0001-mosh-distribution-gate.md) is approved.
- **Eternal Terminal transport integration.** For networks where UDP is simply not allowed. An isolated foundation
  exists, but it is disabled by default, excluded from default `TransportSelector` planning by
  `ExperimentalTransportFeatures.disabled`, and still needs app integration plus real `etserver` and physical-device
  validation before any support claim. App wiring and distribution are additionally blocked by Gate E0 in
  [ADR 0002](../decisions/0002-et-provenance-distribution-gate.md).

### Acceptance debt before any resilient-transport support claim

- Prove native Mosh licensing and iOS background/UDP feasibility, then validate Wi-Fi-to-cellular handoff and terminal
  resynchronisation on physical devices.
- Connect the Eternal Terminal foundation to the app, run against real `etserver`, and validate reconnect/session
  resume on physical devices.
- Keep `TransportSelector` default planning on SSH-only behavior until those checks pass and the experimental feature
  gate is deliberately enabled.

## Then — richer voice engines

Apple's on-device `SFSpeechRecognizer` ships today, with Chinese/English mixed input treated as a first-class
requirement rather than a later fix. Next: WhisperKit and `whisper.cpp` model management (download, delete, storage
accounting, offline state), then Parakeet if its model and mobile runtime licenses allow redistribution. Cloud
transcription stays opt-in and off by default.

## Then — Apple ecosystem

Live Activities and Dynamic Island for a working agent; Apple Watch limited on purpose to *view status, approve,
deny, stop, open iPhone* — a full terminal on a watch is a demo, not a tool; App Intents and Widgets; and an
end-to-end encrypted push relay where the relay can route a notification without being able to read it, and where
possession of a notification still grants nothing.

## Then — beyond iOS

An Android client on the same protocol, and `MultiplexerAdapter` implementations for whatever replaces tmux.

## Explicitly not planned

- A remote-command endpoint on the daemon. The app owns a PTY.
- Uploading your code, transcripts or diffs to any service operated by this project.
- A hosted control plane. The host you own is the control plane.
