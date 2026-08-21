# OpenPaw Modern Foundation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship the first production milestone of OpenPaw's next-generation experience: a coherent flagship dark design system, a correct and friendly first-run flow, and a modern Tailscale/SSH Workspace Home.

**Architecture:** Keep `OpenPawModel` as the single observable root and keep networking behind existing backends. Add pure presentation models for device/workspace cards so behavior is testable without SwiftUI or a network. Root navigation gains a Home destination and skips backend activity when no trusted host exists. New SwiftUI components preserve the machine/human register while adding connection-state hierarchy and progressive disclosure.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, existing OpenPawProtocol/OpenPawTerminalCore/OpenPawUI packages, headless snapshot renderer, Xcode simulator.

---

## Task 1: Correct first-run state and root destination

**Files:**
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Model/OpenPawModel.swift`
- Test: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ShellTests.swift`

**Step 1: Write the failing tests**

Add tests asserting:

```swift
@Test("Home is the default destination")
func homeIsDefault() {
    #expect(ShellRouter().destination == .home)
}

@Test("The root exposes Home before the work surfaces")
func destinationsStartWithHome() {
    #expect(ShellDestination.allCases.map(\.rawValue) == [
        "home", "terminal", "chat", "inbox", "repo", "settings"
    ])
}

@Test("A model without a trusted host must not refresh a backend")
@MainActor
func emptyModelDoesNotNeedRemoteState() {
    let model = OpenPawModel(hostStore: HostStore())
    #expect(model.canRefreshRemoteState == false)
}
```

**Step 2: Run the tests and verify RED**

Run:

```bash
cd packages/swift-openpaw-ui
swift test --filter RootNavigationTests
```

Expected: failures because `.home` and `canRefreshRemoteState` do not exist.

**Step 3: Implement the minimal behavior**

- Add `.home` to `ShellDestination`, including title, glyph, and navigation behavior.
- Set `ShellRouter.destination` to `.home`.
- Add `OpenPawModel.canRefreshRemoteState`, true only when a selected host and backend exist.
- Guard root `.task`, `AppWiring.start()`, and foreground refresh paths so an empty host store does not call the host API.

**Step 4: Run tests and verify GREEN**

Run:

```bash
swift test --filter RootNavigationTests
swift test
```

Expected: all package tests pass.

**Step 5: Commit**

```bash
git add packages/swift-openpaw-ui apps/ios/OpenPawApp/OpenPawApp.swift
git commit -m "fix: make first-run state local and actionable"
```

## Task 2: Add device and workspace presentation models

**Files:**
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Model/WorkspacePresentation.swift`
- Test: `packages/swift-openpaw-ui/Tests/OpenPawUITests/WorkspacePresentationTests.swift`

**Step 1: Write failing tests**

Cover these pure behaviors:

- `.ts.net` and explicit `tailscale` tags produce a Tailscale source label.
- Unknown hosts remain SSH candidates and are never described as verified Tailscale devices.
- Connected selected host reports `.online`.
- A previously reached disconnected host reports `.offline`, not `.failed`.
- Active session and pending approval counts are scoped to the selected host's current model projection.
- Preferred multiplexer and transport names are human readable.

Example:

```swift
@Test("MagicDNS hostnames are presented as Tailscale candidates, not trusted devices")
func magicDNSCandidate() {
    let host = fixture(hostname: "studio.tail123.ts.net")
    let card = WorkspaceDevicePresentation(host: host, model: fixtureModel(host))
    #expect(card.network == .tailscaleCandidate)
    #expect(card.connectionActionTitle == "Connect")
}
```

**Step 2: Verify RED**

```bash
swift test --filter WorkspacePresentationTests
```

Expected: module cannot find the new types.

**Step 3: Implement minimal pure models**

Define:

- `DeviceNetworkPresentation`
- `DeviceAvailabilityPresentation`
- `WorkspaceDevicePresentation`
- `WorkspaceMetric`

Do not call network APIs. Derive only from trusted local state and label heuristics as candidates.

**Step 4: Verify GREEN**

```bash
swift test --filter WorkspacePresentationTests
swift test
```

**Step 5: Commit**

```bash
git add packages/swift-openpaw-ui
git commit -m "feat: model workspace device presentation"
```

## Task 3: Extend the flagship design tokens

**Files:**
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Theme/OpenPawTheme.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Components/SignalOrb.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Components/StatusPill.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Components/WorkspaceCard.swift`
- Test: `packages/swift-openpaw-ui/Tests/OpenPawUITests/FoundationTests.swift`

**Step 1: Write failing semantic tests**

Test stable mappings rather than pixels:

- Every connection signal state has a label, glyph, and tone.
- Offline and blocked states remain distinguishable without color.
- Workspace card metrics have deterministic ordering.
- Reduce Motion disables orbital rotation.

**Step 2: Verify RED**

```bash
swift test --filter SignalPresentationTests
```

**Step 3: Add tokens and components**

- Add `void`, `graphite`, `signal`, `pulse`, and `caution` aliases while retaining old token compatibility.
- Add `Navigation` typography.
- Implement `SignalOrb` with static fallback under Reduce Motion.
- Implement `StatusPill` with icon and text.
- Implement `WorkspaceCard` using opaque surfaces and one restrained connection highlight.

**Step 4: Verify GREEN**

```bash
swift test --filter SignalPresentationTests
swift test
```

**Step 5: Commit**

```bash
git add packages/swift-openpaw-ui
git commit -m "feat: add OpenPaw signal design primitives"
```

## Task 4: Build the friendly empty Home and onboarding entry

**Files:**
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/WorkspaceHomeView.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/AddDeviceFlow.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/HostEditorView.swift`
- Test: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ShellTests.swift`
- Modify: `tools/openpaw-snapshot/Sources/openpaw-snapshot/ScreenCatalog.swift`

**Step 1: Write failing flow tests**

Test the pure flow state:

```swift
@Test("An empty store starts at the welcome step")
func emptyStartsWelcome() {
    #expect(AddDeviceFlowState(hosts: []).step == .welcome)
}

@Test("Discovery candidates require confirmation")
func candidateNeedsConfirmation() {
    var state = AddDeviceFlowState(hosts: [])
    state.discovered = [.fixture]
    state.selectCandidate(id: .fixtureID)
    #expect(state.step == .confirmCandidate)
}
```

Also test copy contracts: the empty state action is “Add a Tailscale or SSH device,” and no empty state uses “tunnel down.”

**Step 2: Verify RED**

```bash
swift test --filter AddDeviceFlowTests
```

**Step 3: Implement minimal UI**

- `WorkspaceHomeView` shows a guided first-run composition when `hostStore.hosts.isEmpty`.
- Primary action opens `AddDeviceFlow`.
- Flow offers “Find with Tailscale” and “Add SSH details” without claiming automatic discovery is already available.
- Manual path reuses `HostEditorView`.
- Add Home and AddDeviceFlow to snapshot catalog.

**Step 4: Verify GREEN and render snapshots**

```bash
swift test
cd ../../../tools/openpaw-snapshot
swift run openpaw-snapshot --output "$JCODE_SCRATCH_DIR/openpaw-m1-snapshots"
```

Expected: no blank snapshots; empty Home visibly directs the next action.

**Step 5: Commit**

```bash
git add packages/swift-openpaw-ui tools/openpaw-snapshot
git commit -m "feat: add guided device onboarding"
```

## Task 5: Build the populated Workspace Home

**Files:**
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/WorkspaceHomeView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Model/WorkspacePresentation.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift`
- Test: `packages/swift-openpaw-ui/Tests/OpenPawUITests/WorkspacePresentationTests.swift`
- Modify: `tools/openpaw-snapshot/Sources/openpaw-snapshot/ScreenCatalog.swift`

**Step 1: Add failing behavior tests**

Test:

- Hosts sort connected first, then recent, then nickname.
- Resume opens the selected device and last relevant surface.
- Pending approvals outrank passive activity.
- Empty sessions/repositories do not create fake metrics.

**Step 2: Verify RED**

```bash
swift test --filter WorkspacePresentationTests
```

**Step 3: Implement the Home**

Sections:

1. Network summary header
2. Device workspace cards
3. Active agents
4. Pending approvals
5. Recent workspaces

Use existing model data. No fake latency and no unimplemented Tailscale network call. Labels must distinguish local observations from future discovery.

**Step 4: Verify GREEN and visual output**

```bash
swift test
swift run --package-path tools/openpaw-snapshot openpaw-snapshot \
  --output "$JCODE_SCRATCH_DIR/openpaw-m1-snapshots"
```

Inspect Home at iPhone and iPad widths in empty, disconnected, populated, and destructive scenarios.

**Step 5: Commit**

```bash
git add packages/swift-openpaw-ui tools/openpaw-snapshot
git commit -m "feat: add workspace-first home"
```

## Task 6: Fix the Clippy gate

**Files:**
- Modify: `host/crates/openpaw-host/src/api/events.rs:96-98`
- Test: existing host tests

**Step 1: Confirm the gate fails**

```bash
cd host
cargo clippy --workspace --all-targets -- -D warnings
```

Expected: `nonminimal_bool` at the delivered-sequence predicate.

**Step 2: Make the equivalent minimal simplification**

Use `is_none_or(|&high| event.seq > high)` as suggested by Clippy.

**Step 3: Verify**

```bash
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

Expected: both pass.

**Step 4: Commit**

```bash
git add host/crates/openpaw-host/src/api/events.rs
git commit -m "fix: satisfy host clippy gate"
```

## Task 7: Full Milestone 1 acceptance

**Files:**
- Update: `docs/handoff.md`
- Update: `docs/architecture/roadmap.md`
- Update: `docs/plans/2026-08-21-openpaw-next-generation-design.md` if implementation decisions changed

**Step 1: Run canonical checks**

```bash
bash scripts/check.sh
```

Expected: every step passes, including Clippy, app build, 140+ snapshots, and 39 host E2E checks.

**Step 2: Build and run in simulator**

Use an available iPhone simulator:

```bash
xcodebuild -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
```

Install and launch `dev.openpaw.app`. Verify:

- Locked launch
- Empty first-run Home without an error alert
- Add Device flow
- Populated Home using preview or seeded simulator data
- Dynamic Type accessibility size
- Reduce Motion
- Relaunch and state restoration

**Step 3: Update documentation with observed evidence**

Record exact counts, simulator/runtime version, screenshots, and any physical-device blockers.

**Step 4: Commit**

```bash
git add docs
git commit -m "docs: record modern home acceptance"
```

## Subsequent milestones

### Milestone 2: Unified voice

- Add a destination-neutral `VoiceComposerState` with tests.
- Reuse `DictationEngine` for Apple Speech.
- Add editable partial/final transcript and Terminal/Agent destinations.
- Add local model catalog and storage accounting before integrating Whisper.
- Gate risky terminal transcripts before sending.

### Milestone 3: Sessions and resilient transports

- Present Herdr/tmux/Zellij/screen through one session-space model.
- Add real Mosh transport conformance and integration tests.
- Add Eternal Terminal fallback.
- Test background suspension, network switching, app termination, and multiplexer reattachment.

### Milestone 4: Apple ecosystem and release

- Add ActivityKit state derived from the open event protocol.
- Add Watch status and approval actions using single-use action tokens.
- Run physical-device Face ID, microphone, CJK, background, Tailscale, SSH, Herdr, Mosh, and approval acceptance flows.
- Prepare App Store privacy, accessibility, localization, and release artifacts.
