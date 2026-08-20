# Contributing to OpenPaw

## Ground rules

1. **No decompiling, no reverse-engineering paid products, no private APIs.** Everything OpenPaw reads is written
   by tools running on the user's own machine, in formats you can inspect with `cat`. A contribution that depends
   on anything else will be rejected regardless of how well it works.
2. **No stubs on `main`.** A merged function does the real thing. `TODO: implement`, silent `nil` returns and fake
   fallbacks are worse than an unimplemented feature, because they lie to the next reader.
3. **Every security boundary has a test that attacks it.** Path traversal, symlink escape, replayed nonce,
   expired action token, wrong capability. If you add a boundary, add the attack.

## Repository map

| Area | Build | Test |
| --- | --- | --- |
| `host/` | `cargo build --workspace` | `cargo test --workspace` |
| `packages/swift-*` | `swift build` in the package dir | `swift test` in the package dir |
| `apps/ios/` | `xcodebuild -scheme OpenPaw -destination 'generic/platform=iOS Simulator' build` | snapshot renderer in `tools/openpaw-snapshot` |

## Adding an agent adapter

An adapter is only accepted with all four of these:

1. A **fixture** in `protocol/fixtures/<agent>/` captured from the agent's real on-disk format. Redact content,
   keep the shape. Say which CLI version produced it.
2. A **golden file** in `protocol/fixtures/normalized/<agent>.events.json`, regenerated with
   `OPENPAW_UPDATE_GOLDEN=1 cargo test -p openpaw-agents`.
3. A **format version string** from `AgentAdapter::format_version()` and a row in
   `docs/agent-adapters/README.md`'s capability matrix.
4. **Incremental-parse coverage**: parsing twice from a saved cursor must not duplicate an `event_id`. Event ids
   are content-addressed precisely so that ingestion is idempotent; do not defeat that by hashing a timestamp.

These formats change without notice. That is expected and is why adapters are versioned rather than assumed
stable. An adapter that stops matching should degrade to `GenericAdapter` behaviour, not crash the supervisor.

## Adding a host route

Every route needs: a capability from `protocol/capability-spec/capabilities.json`, an audit entry if it mutates
anything, and an integration test asserting 401 unsigned / 403 under-privileged / 200 correct. Routes that would
execute caller-supplied commands are out of scope permanently — the app has a PTY for that.

## Adding a protocol event

Change `protocol/json-schema/event.schema.json` first, then the Rust `Body` enum, then the Swift `Body` enum, then
the fixtures. Swift decodes unknown event types into `.unsupported`, so old clients keep working; do not remove or
repurpose an existing event type in place — add a new one.

## UI verification

No iOS simulator runtime is installed on the reference machine, so `OpenPawUI` screens are verified by rendering them
headlessly on macOS. That is the reason every screen in `packages/swift-openpaw-ui` must compile for macOS as well as
iOS: platform-specific code goes behind `#if os(iOS)` / `#if canImport(UIKit)` with a macOS path supplied.

```
cd tools/openpaw-snapshot && swift run openpaw-snapshot --output /tmp/openpaw-snapshots
```

It writes one PNG per screen per `PreviewBackend.Scenario` at iPhone and iPad sizes, prints a manifest with pixel
dimensions, byte sizes and ink coverage, and exits non-zero if any render came back empty or drew nothing but its
background.

**Render through `NSHostingView` and `cacheDisplay(in:to:)`, never `ImageRenderer`.** `ImageRenderer` does not draw the
contents of a `ScrollView`: the scroll view's background, frame and overlays appear, and every child inside it comes
out empty. Isolated with four variants in one image — `CodeBlock` blank, the identical `Text(AttributedString)` outside
a `ScrollView` renders, `CodeBlock(isCopyable: false)` blank, and a bare `ScrollView(.horizontal) { Text("…") }` blank.
Since almost every screen in the app is inside a `ScrollView`, an `ImageRenderer` snapshot set is uniformly blank while
looking perfectly stable run to run, which is worse than no snapshots at all. The same views render completely through
a real host view. `UIHostingView` is the iOS equivalent.

When Xcode cannot run — a machine whose first-launch system content is stale fails every `xcodebuild` invocation with
`IDESimulatorFoundation` failing to load, fixable only with `sudo xcodebuild -runFirstLaunch` — type-check the iOS app
without it:

```
apps/ios/scripts/typecheck-ios.sh
```

That builds the local packages for `arm64-apple-ios17.0-simulator`, type-checks every file in `apps/ios/OpenPawApp`
under Swift 6, and validates the hand-written `project.pbxproj` for dangling object references. `xcodebuild` is still
the real gate in CI.

## Style

Rust: `cargo fmt`, `cargo clippy --workspace --all-targets -- -D warnings`. Swift: 4-space indent, no force
unwraps outside tests, `Sendable` on every public value type, Swift 6 language mode.
