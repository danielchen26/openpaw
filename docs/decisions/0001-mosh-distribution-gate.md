# ADR 0001: Mosh distribution gate

**Status:** Accepted as a release constraint
**Gate status:** Unresolved

## Context

Mosh would improve roaming and reconnect behavior, but upstream Mosh is GPL-3.0-or-later and an iOS client would also need a credible UDP/background lifecycle. OpenPaw currently uses SSH as its only production terminal transport. A technical prototype cannot answer the distribution, source-delivery, relinking, App Store, or physical-device questions.

## Decision

Gate M0 blocks implementation, linking, selectable UI, distribution, and support claims for native Mosh. Approval requires a written decision by the project owner and qualified licensing counsel that identifies the distribution channel and satisfies every acceptance item below.

For this gate, a **linked or distributed build** means any source, binary, object, framework, package product, or resource reachable from an `OpenPaw.xcodeproj` target or from a SwiftPM dependency edge used by a distributed OpenPaw product. Keeping a file behind an inactive UI flag does not remove it from the gate. The repository remains Apache-2.0 unless an approved M0 decision explicitly changes the applicable licensing and release terms.

| Allowed | Forbidden |
| --- | --- |
| Keep the `RemoteTransport` seam transport-neutral. | Link, copy, translate, or distribute Mosh code before M0 approval. |
| Document Mosh as planned and gated. | Show Mosh as selectable or available in a production build. |
| Research public protocol and lifecycle constraints without importing implementation code. | Claim Mosh support from an SSH-only or simulator-only test. |
| Maintain an isolated legal and technical evidence record. | Treat App Store acceptance as a substitute for license compliance. |

## M0 acceptance

All items are required:

1. Record the intended App Store or non-App-Store distribution channel.
2. Resolve GPLv3 compatibility, static and dynamic linking treatment, required notices, corresponding-source delivery, and downstream relinking obligations.
3. Select a lawful implementation path: GPL-compatible combined distribution, a suitable license exception, or a counsel-approved clean-room protocol client.
4. Record dependency provenance and a reproducible source/build delivery procedure.
5. Pass real-server interoperability, Wi-Fi-to-cellular roaming, background/foreground, process-kill restoration, concurrent-transport, and physical-iPhone acceptance.
6. Update this record to `**Gate status:** Approved` with evidence links before production documentation or UI can call Mosh shipped.

## Consequences

SSH remains the only production transport while M0 is unresolved. Product code must omit Mosh from transport choices rather than present a disabled promise. No current OpenPaw license or release channel is changed by this decision.
