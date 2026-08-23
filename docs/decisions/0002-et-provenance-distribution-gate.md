# ADR 0002: Eternal Terminal provenance and distribution gate

**Status:** Accepted as a release constraint
**Gate status:** Unresolved

## Context

Upstream Eternal Terminal is GPL-3.0. OpenPaw contains an isolated Swift protocol foundation whose design studied pinned upstream wire behavior. It is disabled, not wired into the application, and not accepted against a real `etserver`. That history is part of the provenance review and must not be softened into a clean-room claim. Protocol compatibility, clean-room sufficiency, dependency concurrency, distribution obligations, and iOS lifecycle behavior remain unresolved independently of Mosh.

## Decision

Gate E0 keeps Eternal Terminal protocol-only and absent from production UI. No complete ET transport may be linked or distributed until the gate is explicitly approved.

For this gate, a **linked or distributed build** means any source, binary, object, framework, package product, or resource reachable from an `OpenPaw.xcodeproj` target or from a SwiftPM dependency edge used by a distributed OpenPaw product. A disabled runtime flag is not sufficient separation. The repository remains Apache-2.0 unless an approved E0 decision explicitly changes the applicable licensing and release terms.

| Allowed | Forbidden |
| --- | --- |
| Keep isolated protocol tests and non-shipping research artifacts. | Copy or derive from GPL implementation code without an approved distribution path. |
| Preserve disabled architecture seams for future evaluation. | Wire ET into app startup, transport selection, or release packaging. |
| Test wire assumptions in isolated fixtures that contain no secrets. | Claim support based only on copied fixtures, mocks, or a local decoder. |
| Record provenance and interoperability evidence. | Present ET as the automatic fallback while E0 is unresolved. |

## E0 acceptance

All items are required:

1. Complete copyright and protocol-provenance review, including clean-room sufficiency.
2. Resolve GPLv3, App Store, attribution, corresponding-source, and distribution-channel obligations.
3. Pass interoperability against supported real `etserver` versions.
4. Pass reconnect, server restart, network loss, background/foreground, process kill, and physical-iPhone lifecycle tests.
5. Review dependency concurrency and packaging so ET cannot silently alter the SSH production path.
6. Update this record to `**Gate status:** Approved` with evidence links before app wiring or support claims.

## Consequences

ET remains a disabled protocol foundation. SSH remains production behavior, and transport selection must not expose ET while E0 is unresolved.
