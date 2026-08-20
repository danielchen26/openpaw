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
  annotation; Face ID gate; config export/import.

## Next — mobile reliability

- **Mosh transport.** The hard part is not compiling the C++ core, it is the UDP lifecycle across iOS background
  suspension, resynchronising terminal state after a kill, and third-party license compliance in an App Store
  build. It lands behind `RemoteTransport` with its own `TransportKind`, and `TransportSelector` already knows how
  to prefer and explain it.
- **Eternal Terminal transport.** For networks where UDP is simply not allowed. TCP reconnect plus session resume.

## Then — richer voice

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
