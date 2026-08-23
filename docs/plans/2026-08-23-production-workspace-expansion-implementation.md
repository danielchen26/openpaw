# OpenPaw Production Workspace Expansion Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Use superpowers:test-driven-development for every behavior change, superpowers:systematic-debugging for failures, and superpowers:verification-before-completion before each phase is declared complete.

**Goal:** Deliver a production-ready OpenPaw experience with truthful Tailscale-assisted device onboarding, Mosh-first resilient transport after legal approval, safe root tab swiping, Terminal host selection, complete Sessions and Inbox workflows, host-scoped GitHub/Hugging Face imports, categorized Settings, and comprehensive cross-feature verification.

**Architecture:** Preserve the existing local-first split: SwiftUI is the control surface, `TerminalBackend` owns interactive transport, and the authenticated loopback host API owns typed structured actions. Add central navigation and connection policies, a mutable canonical workspace registry, host-scoped provider authorization, deterministic simulator fixtures, and gated transport implementations. Do not add arbitrary remote execution or expose credentials through the protocol.

**Tech Stack:** Swift 6, SwiftUI, Network.framework, AuthenticationServices where needed for browser presentation, SwiftNIO SSH, Rust/Axum, Tokio, Serde, Git CLI behind a hardened typed wrapper, XCTest/XCUITest, Swift Testing, Rust tests, snapshot tests, iOS 26.5 simulator, and physical iPhone acceptance.

---

## Execution rules

1. Work in the dependency order below. Do not begin Mosh production wiring before Gate M0 is recorded.
2. Start every task with a failing unit, integration, UI, or contract test.
3. Make one cohesive commit per task. Structural Xcode project changes needed for new sources/resources may be committed, but personal signing values in `apps/ios/OpenPaw.xcodeproj/project.pbxproj` must never be staged. Stage structural hunks with a separate cached patch and validate them before commit.
4. Keep DEBUG fixtures fenced with both `#if DEBUG` and `targetEnvironment(simulator)`.
5. Never make a remote API accept shell text, a destination path, a Git config fragment, or a provider token in a response.
6. Use the newest installed iOS simulator dynamically. Do not hardcode a simulator UDID.
7. A passing mock test does not replace the live-host or physical-device acceptance listed in the release matrix.

## Phase and gate map

- **P0, decisions and test infrastructure:** Tasks 1-2
- **P1, navigation and connections:** Tasks 3-6
- **P2, Sessions and Inbox:** Tasks 7-9
- **P3, Settings:** Tasks 10-11
- **P4, repository providers:** Tasks 12-15
- **P5, Mosh and transport:** Tasks 16-17
- **P6, parity polish and release:** Tasks 18-20

---

### Task 1: Record the irreversible product, license, and protocol decisions

**Files:**
- Create: `docs/decisions/0001-mosh-distribution-gate.md`
- Create: `docs/decisions/0002-et-provenance-distribution-gate.md`
- Create: `docs/decisions/0003-tailscale-discovery-boundary.md`
- Create: `docs/decisions/0004-provider-token-boundary.md`
- Modify: `docs/architecture/roadmap.md`
- Modify: `docs/architecture/README.md`

**Step 1: Write acceptance assertions before implementation**

Each ADR must include a short machine-checkable “Allowed / Forbidden” table:

- Mosh is forbidden in any linked or distributed build until Gate M0 resolves GPLv3 compatibility with the intended App Store or non-App-Store channel, corresponding-source delivery, relinking obligations, static/dynamic linking treatment, and required notices.
- Eternal Terminal remains protocol-only and disabled until Gate E0 resolves upstream GPLv3/protocol provenance, clean-room sufficiency, App Store/distribution obligations, real `etserver` interoperability, reconnect behavior, dependency concurrency, and physical-device lifecycle.
- OpenPaw may detect a likely Tailscale route, but may not claim to read the installed Tailscale account.
- Provider tokens live on the selected host and never appear in API responses, logs, settings export, or simulator fixtures.
- Structured clone/import is allowed; arbitrary command execution remains forbidden.

**Step 2: Add a documentation check**

Modify `scripts/check.sh` to fail if production-facing documentation claims direct installed-app Tailscale account discovery, marks Mosh shipped while Gate M0 remains unresolved, or marks Eternal Terminal app-integrated while Gate E0 remains unresolved. Keep the check literal and narrow so wording changes do not create a brittle linter.

**Step 3: Verify**

Run:

```bash
bash scripts/check.sh
```

Expected: PASS.

**Step 4: Commit**

```bash
git add docs/decisions docs/architecture scripts/check.sh
git commit -m "Document transport and provider security gates"
```

---

### Task 2: Add deterministic fixtures and dynamic iOS destination selection

This task comes first because every later XCUITest should reuse one reliable launch and host fixture instead of repeatedly rebuilding ad hoc harnesses.

**Files:**
- Create: `scripts/ios-test-destination.py`
- Create: `scripts/tests/test_ios_test_destination.py`
- Create: `scripts/validate-pbxproj-diff.py`
- Create: `scripts/tests/test_validate_pbxproj_diff.py`
- Create: `apps/ios/OpenPawApp/DebugScenario.swift`
- Modify: `apps/ios/OpenPawApp/OpenPawApp.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Backend/PreviewBackend.swift`
- Create: `apps/ios/OpenPawAppTests/DebugScenarioTests.swift`
- Create: `apps/ios/OpenPawUITests/ScenarioLaunchUITests.swift`
- Modify: `scripts/check.sh`

**Step 1: Write failing selector tests**

Test a captured `simctl list -j` fixture and require the script to:

- Select the newest available iOS runtime.
- Prefer a phone device.
- Reject unavailable/shutdown-only malformed entries correctly.
- Print an `xcodebuild -destination` value, not a persistent UDID in source.

**Step 2: Write failing fixture contract tests**

Define scenarios such as:

```swift
enum DebugScenario: String {
    case empty
    case connectedWorkspace
    case sessions
    case inboxRisks
    case repoProviders
    case connectionFailures
}
```

Require decoding to be strict and require unknown scenarios to fall back to production wiring rather than partially seeding state.

**Step 3: Implement the simulator-only fixture boundary**

- Read `-openpaw-debug-scenario <name>` only under DEBUG + simulator.
- Seed the real `OpenPawModel` through a deterministic backend and host store.
- Keep connection state, sessions, Inbox items, repos, provider metadata, restoration plans, and typed failures in one scenario definition.
- Do not add a shipping environment variable or URL that selects fixtures.

**Step 4: Add a smoke XCUITest**

Launch `connectedWorkspace`, assert the named host, session badge, Inbox badge, and repository appear. Launch without the argument and assert fixture-only labels do not exist.

**Step 5: Add a signing-safe project-diff validator**

New app, app-test, UI-test, package, or privacy-resource files may require legitimate structural changes to `project.pbxproj`. Add a validator that inspects the staged project diff and rejects changes to `DEVELOPMENT_TEAM`, `CODE_SIGN_*`, `PROVISIONING_PROFILE*`, signing identities, and unrelated build settings. The implementation workflow must create a structural-only patch against `HEAD`, apply it with `git apply --cached`, and leave the user's working-tree signing diff untouched.

**Step 6: Verify**

```bash
python3 -m unittest scripts/tests/test_ios_test_destination.py scripts/tests/test_validate_pbxproj_diff.py
swift test --package-path packages/swift-openpaw-ui
DESTINATION="$(python3 scripts/ios-test-destination.py)"
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$DESTINATION" \
  -only-testing:OpenPawUITests/ScenarioLaunchUITests
```

Expected: PASS.

**Step 7: Commit**

```bash
git add scripts apps/ios/OpenPawApp apps/ios/OpenPawAppTests apps/ios/OpenPawUITests packages/swift-openpaw-ui
# Stage only required PBX file-reference/build-phase hunks using a patch against HEAD.
python3 scripts/validate-pbxproj-diff.py --staged
git commit -m "Add deterministic iOS acceptance fixtures"
```

---

### Task 3: Make Sessions a first-class destination and centralize root paging policy

**Files:**
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/ControlDeck.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/DestinationPaging.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Components/ControlDeckView.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ControlDeckTests.swift`
- Create: `packages/swift-openpaw-ui/Tests/OpenPawUITests/DestinationPagingTests.swift`

**Step 1: Write failing policy tests**

Require:

- Order: Home, Terminal, Sessions, Inbox, Repo, Settings.
- `chat` is migrated to `sessions` for persisted debug/deep-link state.
- One swipe changes one destination.
- No wrap at either end.
- A horizontal movement must exceed distance, velocity, and horizontal-dominance thresholds.
- Leading-edge back, active modal, active horizontal child control, text selection, and Inbox row action suppress root paging.

**Step 2: Implement a pure `DestinationPagingPolicy`**

Keep threshold calculation and exclusion reasoning out of SwiftUI views. Return a typed result:

```swift
enum DestinationPageDecision {
    case previous
    case next
    case ignore(DestinationPageSuppression)
}
```

**Step 3: Rename the root destination**

Rename `.chat` to `.sessions`; `SessionListView` remains the root and `ChatView` remains session detail. Update labels, icons, accessibility IDs, restoration, and deep-link mapping.

**Step 4: Preserve the control deck**

Keep its horizontal page, vertical fold, and stow behaviors. Increase the stowed handle's hit area to at least 44 by 44 points using `contentShape` while retaining its visual size. Add a reliable edge-swipe-right restore gesture.

**Step 5: Verify**

```bash
swift test --package-path packages/swift-openpaw-ui --filter DestinationPagingTests
swift test --package-path packages/swift-openpaw-ui --filter ControlDeckTests
```

Expected: PASS.

**Step 6: Commit**

```bash
git add packages/swift-openpaw-ui
git commit -m "Define safe root destination paging"
```

---

### Task 4: Add production root swipe arbitration and accessibility controls

**Files:**
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Components/DestinationSwipeCatcher.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/InboxView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/DiffViewerView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/TerminalScreenView.swift`
- Create: `apps/ios/OpenPawUITests/RootTabSwipeUITests.swift`
- Modify: `apps/ios/OpenPawUITests/ControlDeckUITests.swift`

**Step 1: Write failing XCUITests**

Using the deterministic scenario, assert:

- A deliberate left/right fling changes destinations on Home, Terminal, Sessions, Inbox, Repo, and Settings.
- Terminal typing, text selection, and vertical scroll are not cancelled.
- Leading-edge right swipe pops a pushed detail rather than changing the root destination.
- Horizontal diff scrolling remains local.
- Inbox row swipe exposes actions and does not change tabs.
- Deny never executes via `allowsFullSwipe`.
- `⌘⌥←` and `⌘⌥→` change destinations.
- VoiceOver adjustable actions expose Previous Tab and Next Tab.

**Step 2: Implement a non-cancelling recognizer bridge**

Use a UIKit recognizer delegate where SwiftUI gesture precedence cannot express the exclusions. The bridge must:

- Set `cancelsTouchesInView = false`.
- Consult `DestinationPagingPolicy`.
- Observe exclusion markers from child surfaces.
- Never recognize while a modal or navigation transition is active.
- Send only a destination intent to `RootView`; it must not own navigation state.

**Step 3: Add explicit accessibility and keyboard actions**

Tabs remain directly tappable. The gestures are additive, never the sole navigation path.

**Step 4: Verify**

```bash
DESTINATION="$(python3 scripts/ios-test-destination.py)"
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$DESTINATION" \
  -only-testing:OpenPawUITests/RootTabSwipeUITests \
  -only-testing:OpenPawUITests/ControlDeckUITests
```

Expected: PASS without flaky retries.

**Step 5: Commit**

```bash
git add packages/swift-openpaw-ui apps/ios/OpenPawUITests
git commit -m "Add accessible root tab swipe navigation"
```

---

### Task 5: Build a shared Terminal Host Switcher

**Files:**
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Components/HostSwitcher.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/TerminalScreenView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Model/OpenPawModel.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ShellTests.swift`
- Create: `apps/ios/OpenPawUITests/HostSwitcherUITests.swift`

**Step 1: Write failing model tests**

Assert that changing the selected host:

- Increments connection generation.
- Cancels/stales prior refreshes.
- Clears session-specific routes and `chatSessionID`.
- Clears stale Inbox detail, Repo selection, Preview URL, and provider/import state.
- Does not automatically connect without an explicit action.

**Step 2: Write failing UI tests**

Assert:

- “No host” is a tappable menu, not passive text.
- With no saved hosts, it opens Add Device.
- A saved disconnected host can be selected, then connected.
- Connected host offers Disconnect/Reconnect.
- Compact Terminal and regular sidebar use identical host/status labels and actions.

**Step 3: Implement `HostSwitcher`**

Render status, transport, and saved hosts. Selection updates `selectedHostID`. Connection actions call existing model methods. Add Device and Manage Hosts route through one root presentation API.

**Step 4: Verify**

```bash
swift test --package-path packages/swift-openpaw-ui --filter ShellTests
DESTINATION="$(python3 scripts/ios-test-destination.py)"
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$DESTINATION" \
  -only-testing:OpenPawUITests/HostSwitcherUITests
```

**Step 5: Commit**

```bash
git add packages/swift-openpaw-ui apps/ios/OpenPawUITests
git commit -m "Add terminal host selection and connection actions"
```

---

### Task 6: Make Add Device automatically useful with Tailscale and typed preflight

**Files:**
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Model/TailscaleRouteHint.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/ConnectionPreflight.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/AddDeviceFlow.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Model/OpenPawModel.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Backend/OpenPawBackend.swift`
- Modify: `apps/ios/OpenPawApp/HostAPIBackend.swift`
- Modify: `apps/ios/OpenPawApp/SSHTerminalBackend.swift`
- Create: `apps/ios/OpenPawApp/TailscaleAdminConnector.swift`
- Create: `apps/ios/OpenPawAppTests/TailscaleAdminConnectorTests.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/TailscaleAdminConnection.swift`
- Modify: `host/crates/openpaw-host/src/api/tailscale.rs`
- Modify: `host/crates/openpaw-host/tests/api.rs`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ShellTests.swift`
- Modify: `apps/ios/OpenPawUITests/ConnectFlowUITests.swift`

**Step 1: Write failing route-hint tests**

Use an injectable path source. Require that utun/Tailscale-looking routes produce only `.likelyAvailable`, never an account name or candidate list.

**Step 2: Write failing auto-discovery tests**

Opening Add Device must:

- Choose a reachable paired host with `devices.read`.
- Refresh candidates once per flow entry and support explicit Retry.
- Preserve generation and request ownership if the selected host changes.
- Explain no-host, daemon-unavailable, Tailscale-missing, command-failed, timeout, malformed-output, and permission-denied states.
- Never auto-save a candidate.

**Step 3: Add a typed connection preflight**

Stages:

```text
route → host key → authentication → OpenPaw health → multiplexer → transport capabilities
```

Use existing terminal/backend abstractions. If a fixed remote capability probe is necessary, define a typed enum in `TerminalBackend`; do not expose a user-provided command string through new APIs.

**Step 4: Implement the optional zero-host admin connector**

This is not normal Tailscale login. Require the user to provide an admin-created OAuth client ID, client secret, and tailnet identifier. Store the credentials in the iOS Keychain, never in `UserDefaults` or settings export. Mint short-lived access tokens only when refreshing the Devices API, request read-only device scope, redact all authentication values, and support Disconnect/Delete. Use an injectable `URLSession` and local mock server/`URLProtocol` tests for success, 401/403, rate limit, malformed JSON, cancellation, and token refresh. The official Devices API is not paginated today, so assert one request with no invented cursor; add pagination only if the official response later defines it. Candidates still require confirmation before a host record is saved.

**Step 5: Improve the flow**

Show three choices: Tailscale devices, SSH / transport preference, Advanced Tailscale connector. Manual entry remains usable without a daemon. Candidate confirmation shows discovery source and exact SSH target. Show Mosh or ET as selectable only when that transport is legally approved and compiled into the current build. The advanced row must say “Tailnet administrator credentials required,” not “Sign in with Tailscale.”

**Step 6: Verify**

```bash
cargo test --manifest-path host/Cargo.toml -p openpaw-host tailscale
swift test --package-path packages/swift-openpaw-ui --filter AddDeviceFlowTests
DESTINATION="$(python3 scripts/ios-test-destination.py)"
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$DESTINATION" \
  -only-testing:OpenPawAppTests/TailscaleAdminConnectorTests \
  -only-testing:OpenPawUITests/ConnectFlowUITests
```

**Step 7: Commit**

```bash
git add host packages/swift-openpaw-ui apps/ios/OpenPawApp apps/ios/OpenPawUITests
python3 scripts/validate-pbxproj-diff.py --staged
git commit -m "Make Tailscale-assisted onboarding automatic and truthful"
```

---

### Task 7: Fix Sessions routing, restoration, and lifecycle correctness

**Files:**
- Modify: `packages/swift-terminal-core/Sources/OpenPawTerminalCore/Multiplexer.swift`
- Modify: `packages/swift-terminal-core/Tests/OpenPawTerminalCoreTests/MultiplexerAdapterTests.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/SessionListView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Model/OpenPawModel.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/SessionSpacePresentation.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/SessionSpacePresentationTests.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ShellTests.swift`

**Step 1: Write regression tests for known defects**

- Creating a session calls `recordCreateRestorationPlan` and persists enough information to restore after relaunch.
- Attaching routes to Terminal and selects the attached session.
- Selecting transcript routes to Chat detail without leaving stale state after host change.
- A home resume intent survives connection; `openHomeDevice` must not always force Terminal.
- Kill requires confirmation, removes the row after host acknowledgement, and clears restoration state.

**Step 2: Make the session execution boundary typed**

Replace `SessionSpaceCommandExecuting.executeSessionCommand(_ command: String)` with a typed `MultiplexerCommand`. Each multiplexer adapter renders fixed templates after strict validation of session, window, and workspace identifiers. The command travels over the user's interactive terminal channel so plain SSH hosts remain supported. Do not add a free-form structured host endpoint. If a typed `sessions.manage` host capability is added later, it may be preferred and audited while retaining this fallback.

**Step 3: Centralize session intents**

Introduce typed root intents such as `openSessionTranscript`, `attachSession`, `restoreSession`, and `resumeWorkspace`. Route mutation happens in one place.

**Step 4: Verify**

```bash
swift test --package-path packages/swift-terminal-core --filter MultiplexerAdapterTests
swift test --package-path packages/swift-openpaw-ui --filter SessionSpacePresentationTests
swift test --package-path packages/swift-openpaw-ui --filter ShellTests
```

**Step 5: Commit**

```bash
git add packages/swift-terminal-core packages/swift-openpaw-ui
git commit -m "Complete session routing and restoration"
```

---

### Task 8: Make Inbox dismissal, deep links, and decisions durable

**Files:**
- Modify: `protocol/capability-spec/capabilities.json`
- Modify: `packages/swift-agent-protocol/Sources/OpenPawProtocol/Payloads.swift`
- Modify: `packages/swift-agent-protocol/Sources/OpenPawProtocol/HostClient.swift`
- Modify: `packages/swift-agent-protocol/Tests/OpenPawProtocolTests/HostClientTests.swift`
- Modify: `host/crates/openpaw-protocol/src/payload.rs`
- Modify: `host/crates/openpaw-protocol/src/lib.rs`
- Modify: `host/crates/openpaw-protocol/tests/schema_conformance.rs`
- Modify: `protocol/json-schema/inbox-item.schema.json` when the wire shape changes
- Modify: `host/crates/openpaw-host/src/api/inbox.rs`
- Modify: `host/crates/openpaw-host/src/api/mod.rs`
- Modify: `host/crates/openpaw-host/src/audit.rs`
- Modify: `host/crates/openpaw-host/tests/api.rs`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Backend/OpenPawBackend.swift`
- Modify: `apps/ios/OpenPawApp/HostAPIBackend.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Model/OpenPawModel.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/InboxView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/InboxTests.swift`

**Step 1: Write failing host API tests**

Require:

- Dismiss is a typed, authenticated, capability-gated mutation.
- Dismiss persists across list refresh and restart if Inbox persistence supports restart.
- Dismiss is idempotent and audited.
- An item from another root/device scope cannot be dismissed.
- Approve-once action tokens cannot be replayed.
- High-risk approval requires acknowledgement; Deny does not.

**Step 2: Add the narrow dismiss endpoint**

Add the smallest capability needed, such as `inbox.write`, without widening execution privileges. Return a typed item state.

**Step 3: Wire app deep links and notifications**

Use one `InboxRoute` containing host ID and item ID. On open:

1. Select/connect the host if allowed.
2. Refresh Inbox.
3. Find the item.
4. Present detail or a typed stale/resolved error.

Connect the existing `openApproval` path to the app's URL/notification handler. Clear it on host switch.

**Step 4: Preserve destructive safeguards**

Trailing swipe may expose Deny/Dismiss, but Deny uses `allowsFullSwipe: false`. A gated item cannot expose Approve until detail acknowledgement.

**Step 5: Verify**

```bash
cargo test --manifest-path host/Cargo.toml -p openpaw-host inbox
swift test --package-path packages/swift-openpaw-ui --filter InboxTests
```

**Step 6: Commit**

```bash
git add protocol host packages/swift-openpaw-ui apps/ios/OpenPawApp
python3 scripts/validate-pbxproj-diff.py --staged
git commit -m "Make inbox actions durable and routable"
```

---

### Task 9: Add complete Sessions and Inbox acceptance suites

**Files:**
- Modify: `apps/ios/OpenPawUITests/SessionCreationUITests.swift`
- Create: `apps/ios/OpenPawUITests/SessionWorkflowUITests.swift`
- Create: `apps/ios/OpenPawUITests/InboxWorkflowUITests.swift`
- Create: `scripts/session-inbox-live.py`
- Modify: `scripts/check.sh`

**Step 1: Add deterministic XCUITests**

Sessions:

- Groups render.
- Select pushes transcript.
- Create enables, submits, and clears input.
- Attach routes to Terminal.
- Kill requires confirmation.
- Restoration banner performs its action.
- Host switch removes stale sessions.

Inbox:

- Badge and filters update.
- Gated item hides Approve before Reveal/acknowledge.
- Acknowledge reveals Approve.
- Deny succeeds without acknowledgement.
- Dismiss remains absent after refresh.
- Permission, stale, disconnected, and replay failures show recovery UI.
- Deep link opens the correct host/item.

**Step 2: Add an environment-gated live harness**

The harness launches a disposable authenticated host and verifies:

- Connect and host-key trust.
- Create session appears after refresh.
- Attach reaches the expected tmux/Zellij target.
- Approve-once emits/receives `permissionResolved` once.
- Kill removes the session.
- Audit records the mutations.

**Step 3: Verify**

```bash
DESTINATION="$(python3 scripts/ios-test-destination.py)"
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$DESTINATION" \
  -only-testing:OpenPawUITests/SessionWorkflowUITests \
  -only-testing:OpenPawUITests/InboxWorkflowUITests
python3 scripts/session-inbox-live.py --help
```

Expected: deterministic suite PASS. Live suite PASS when its explicit environment prerequisites are present, otherwise SKIP with a reason.

**Step 4: Commit**

```bash
git add apps/ios/OpenPawUITests scripts
git commit -m "Cover sessions and inbox end to end"
```

---

### Task 10: Extract, version, validate, and migrate the Settings domain

**Files:**
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Settings/OpenPawSettings.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Settings/SettingsSnapshot.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Settings/SettingsValidation.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/SettingsView.swift`
- Modify: `apps/ios/OpenPawApp/OpenPawApp.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ShellTests.swift`
- Create: `packages/swift-openpaw-ui/Tests/OpenPawUITests/SettingsValidationTests.swift`

**Step 1: Write hostile import tests**

Reject or require confirmation for:

- Negative event budget, which currently can reach `removeFirst` with an invalid count.
- Ports outside 1...65535.
- Invalid scrollback, font, grace, model, and timeout values.
- Unknown future schema versions.
- Import that turns biometric protection off without explicit confirmation.
- Duplicate or malformed host profiles.

Require additive migration via `decodeIfPresent` for older snapshots.

**Step 2: Define one runtime owner**

`OpenPawSettings` owns the persisted value. `GateController` observes settings changes and updates immediately, including grace interval. Remove the second one-time read from app startup.

**Step 3: Persist currently inert settings**

- `eventBudgetPerSession`
- shortcut bar visibility
- preview port
- biometric grace interval

Keep scoping: global defaults, per-host `SessionProfile`, live session state.

**Step 4: Add import diff and reset model**

Parsing returns a proposed snapshot and a list of changes. The UI applies only after confirmation. Security reductions have a separate warning. Reset is category-aware and has a complete reset option.

**Step 5: Verify**

```bash
swift test --package-path packages/swift-openpaw-ui --filter SettingsValidationTests
swift test --package-path packages/swift-openpaw-ui --filter ShellTests
```

**Step 6: Commit**

```bash
git add packages/swift-openpaw-ui apps/ios/OpenPawApp
python3 scripts/validate-pbxproj-diff.py --staged
git commit -m "Harden settings persistence and migration"
```

---

### Task 11: Replace the long Settings page with categorized navigation

**Files:**
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/SettingsView.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/Settings/SettingsHomeView.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/Settings/AppearanceSettingsView.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/Settings/TerminalSettingsView.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/Settings/VoiceSettingsView.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/Settings/ConnectionSettingsView.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/Settings/SessionSettingsView.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/Settings/AgentSettingsView.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/Settings/RepositorySettingsView.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/Settings/SecuritySettingsView.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/Settings/DataSettingsView.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/Settings/DiagnosticsSettingsView.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/Settings/AboutSettingsView.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ShellTests.swift`
- Modify: `tools/openpaw-snapshot/Sources/openpaw-snapshot/ScreenCatalog.swift`
- Create: `apps/ios/OpenPawUITests/SettingsNavigationUITests.swift`

**Step 1: Write failing category/search tests**

Require stable category IDs, searchable keywords, deep-link destination, and correct iPhone/iPad presentation. Add accessibility identifiers for every category and key control.

**Step 2: Implement navigation architecture**

- iPhone: `NavigationStack` with searchable category list.
- iPad: `NavigationSplitView` with category sidebar and detail.
- Search results link directly to the owning control.
- Host-specific settings remain in `HostEditorView`; Settings links to hosts rather than duplicating profile ownership.

**Step 3: Add missing controls**

Expose shortcut-bar visibility/editor, preview port, persisted event budget, biometric grace interval, transport explanation, provider connections, import diff, reset, diagnostics, and legal notices.

**Step 4: Snapshot and accessibility verification**

Create iPhone and iPad snapshots for category home, Security, Sessions & Budgets, Repositories & Providers, import diff, and validation error. Test Dynamic Type, VoiceOver labels, 44-point targets, keyboard focus, dark/light/contrast where supported.

**Step 5: Verify**

```bash
swift test --package-path packages/swift-openpaw-ui
DESTINATION="$(python3 scripts/ios-test-destination.py)"
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$DESTINATION" \
  -only-testing:OpenPawUITests/SettingsNavigationUITests
swift run --package-path tools/openpaw-snapshot openpaw-snapshot \
  --output "$JCODE_SCRATCH_DIR/openpaw-settings-snapshots"
```

**Step 6: Commit**

```bash
git add packages/swift-openpaw-ui apps/ios/OpenPawUITests
git commit -m "Organize settings into searchable categories"
```

---

### Task 12: Add provider and repository-import protocol contracts

**Files:**
- Modify: `protocol/capability-spec/capabilities.json`
- Modify: `packages/swift-agent-protocol/Sources/OpenPawProtocol/Payloads.swift`
- Modify: `packages/swift-agent-protocol/Sources/OpenPawProtocol/HostClient.swift`
- Modify: `packages/swift-agent-protocol/Tests/OpenPawProtocolTests/HostClientTests.swift`
- Modify: `host/crates/openpaw-protocol/src/payload.rs`
- Modify: `host/crates/openpaw-protocol/src/lib.rs`
- Modify: `host/crates/openpaw-protocol/tests/schema_conformance.rs`
- Create: `protocol/json-schema/provider.schema.json`
- Create: `protocol/json-schema/repo-import.schema.json`
- Modify: `host/crates/openpaw-host/src/api/mod.rs`
- Modify: `host/crates/openpaw-host/src/state.rs`
- Modify: `host/crates/openpaw-host/tests/api.rs`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Backend/OpenPawBackend.swift`
- Modify: `apps/ios/OpenPawApp/HostAPIBackend.swift`

**Step 1: Write failing contract tests**

Define and test:

- `providers.read`: provider status and sanitized metadata.
- `providers.manage`: begin/cancel/revoke device authorization.
- `repos.manage`: add existing root and import a repository.
- No response type has a token, authorization header, local credential path, or arbitrary environment map.
- Import destination is a server-selected ID/name, never a path.
- Progress events are bounded and redact source URLs if they contain credentials.

**Step 2: Add versioned typed endpoints**

Proposed surface:

```text
GET    /v1/providers
POST   /v1/providers/:provider/authorize
GET    /v1/providers/:provider/authorize/:id
DELETE /v1/providers/:provider
GET    /v1/providers/:provider/repos
POST   /v1/repos/import
GET    /v1/repos/import/:id
POST   /v1/repos/register
```

Use existing HMAC request signing, nonce protection, root scoping, audit, and SSE event conventions.

**Step 3: Update both hand-maintained protocol implementations and schema conformance**

Add matching Swift and Rust payloads explicitly in the files above. Extend JSON-schema fixtures and `schema_conformance.rs`. Add round-trip fixtures that both implementations decode. Do not assume a generator exists, and do not introduce one inside this feature unless it is separately designed and reviewed.

**Step 4: Verify**

```bash
cargo test --workspace --manifest-path host/Cargo.toml
swift test --package-path packages/swift-agent-protocol
bash scripts/check.sh
```

**Step 5: Commit**

```bash
git add protocol host packages/swift-openpaw-ui apps/ios/OpenPawApp
python3 scripts/validate-pbxproj-diff.py --staged
git commit -m "Define secure repository provider contracts"
```

---

### Task 13: Implement host-scoped provider authorization and token storage

**Files:**
- Create: `host/crates/openpaw-providers/Cargo.toml`
- Create: `host/crates/openpaw-providers/src/lib.rs`
- Create: `host/crates/openpaw-providers/src/github.rs`
- Create: `host/crates/openpaw-providers/src/huggingface.rs`
- Create: `host/crates/openpaw-providers/src/store.rs`
- Create: `host/crates/openpaw-providers/tests/providers.rs`
- Modify: `host/Cargo.toml`
- Create: `host/crates/openpaw-host/src/api/providers.rs`
- Modify: `host/crates/openpaw-host/src/api/mod.rs`
- Modify: `host/crates/openpaw-host/src/config.rs`
- Modify: `host/crates/openpaw-host/src/audit.rs`
- Modify: `host/crates/openpaw-host/tests/api.rs`

**Step 1: Write failing provider tests**

With local mock HTTP servers, require:

- GitHub and Hugging Face device authorization request/poll success, pending, slow-down, denial, expiry, cancellation, and provider outage.
- Minimum requested scopes.
- Token persistence uses mode 0600 and atomic replacement.
- Token values never implement `Debug` in a revealing way and never enter errors.
- Provider status exposes identity and scopes, not credentials.
- Revoke/delete removes the local token and records audit.

**Step 2: Define a small provider trait**

```rust
trait RepoProvider {
    fn id(&self) -> ProviderId;
    async fn begin_authorization(&self) -> Result<DeviceAuthorization, ProviderError>;
    async fn poll_authorization(&self, handle: &AuthorizationHandle) -> Result<AuthorizationState, ProviderError>;
    async fn list_repositories(&self, token: &SecretToken, cursor: Option<&str>) -> Result<RepoPage, ProviderError>;
    async fn clone_credential(&self, token: &SecretToken, repo: &RemoteRepo) -> Result<CloneCredential, ProviderError>;
}
```

Keep secret types inside this crate. The host API receives sanitized provider values only.

**Step 3: Implement host-side device flows**

The phone opens the provider verification URL. The host polls and stores the resulting token. Client IDs may be public build configuration; client secrets are not embedded.

**Step 4: Verify**

```bash
cargo test --manifest-path host/Cargo.toml -p openpaw-providers
cargo test --manifest-path host/Cargo.toml -p openpaw-host providers
```

**Step 5: Commit**

```bash
git add host
git commit -m "Add host-scoped GitHub and Hugging Face providers"
```

---

### Task 14: Add a mutable canonical Workspace Registry and hardened typed clone

**Files:**
- Create: `host/crates/openpaw-host/src/workspaces.rs`
- Modify: `host/crates/openpaw-host/src/state.rs`
- Modify: `host/crates/openpaw-host/src/config.rs`
- Modify: `host/crates/openpaw-host/src/api/repos.rs`
- Modify: `host/crates/openpaw-host/src/audit.rs`
- Modify: `host/crates/openpaw-host/src/bus.rs`
- Modify: `host/crates/openpaw-git/src/lib.rs`
- Modify: `host/crates/openpaw-git/src/repo.rs`
- Modify: `host/crates/openpaw-git/tests/repo.rs`
- Modify: `host/crates/openpaw-host/tests/api.rs`
- Modify: `host/crates/openpaw-files/tests/boundary.rs`

**Step 1: Write boundary and no-exec tests**

Require rejection of:

- `file://`, `ssh://`, scp-like, `ext::`, local paths, submodule protocol escalation, and encoded protocol tricks.
- Repository names containing separators, dot traversal, control characters, percent-encoded separators, or collisions.
- Caller-selected destination directories.
- Git templates, hooks, fsmonitor, credential prompts, system/global config, and external protocols.
- Symlink escape between create and canonicalize.
- Imports exceeding time or byte policy.

Preserve and extend the existing no-exec tests in `openpaw-host/tests/api.rs`.

**Step 2: Implement the registry**

Replace boot-only `Arc<Roots>` with a concurrency-safe snapshot registry. Registration:

1. Resolves a server-selected destination under `<state_dir>/repos`.
2. Imports into a temporary sibling directory.
3. Canonicalizes and verifies containment.
4. Atomically renames to final destination.
5. Persists the workspace list atomically.
6. Publishes a new immutable snapshot to readers.

**Step 3: Implement hardened clone**

Invoke Git with fixed arguments and environment:

```text
--no-local
--template=
GIT_CONFIG_NOSYSTEM=1
GIT_TERMINAL_PROMPT=0
-c protocol.allow=never
-c protocol.https.allow=always
-c protocol.file.allow=never
-c protocol.ext.allow=never
-c core.hooksPath=/dev/null
-c core.fsmonitor=false
```

Pass authorization through a short-lived, redacted mechanism supported by Git, never in argv or logs. Disable Hugging Face LFS smudge by default. Kill the process group on timeout/cancel.

**Step 4: Add progress and audit**

Emit bounded phases: queued, authorizing, cloning, validating, registering, complete, failed, cancelled. Audit actor, provider, sanitized repo ID, result, and policy decision.

**Step 5: Verify**

```bash
cargo test --manifest-path host/Cargo.toml -p openpaw-git
cargo test --manifest-path host/Cargo.toml -p openpaw-files
cargo test --manifest-path host/Cargo.toml -p openpaw-host repos
```

**Step 6: Commit**

```bash
git add host
git commit -m "Add safe dynamic repository imports"
```

---

### Task 15: Build GitHub and Hugging Face connection and import UI

**Files:**
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/RepositoryProvider.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/ProviderConnectionView.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RepositoryImportView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RepoStatusView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Model/OpenPawModel.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Backend/PreviewBackend.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/RepoTests.swift`
- Create: `apps/ios/OpenPawUITests/RepositoryImportUITests.swift`

**Step 1: Write failing model/UI tests**

Require:

- Empty Repo offers Add existing checkout, Import from GitHub, and Import from Hugging Face.
- Provider authorization shows verification URL/code, pending, success, denied, expired, cancel, and revoke.
- Repository list supports pagination/search and makes private/public state clear.
- Import requires selected host and structured `repos.manage` capability.
- Progress survives tab changes and reconnect.
- Cancel is idempotent.
- Success selects the new workspace and refreshes status/tree/diff.
- Host switch clears provider/import state.
- No UI or accessibility value contains token-like text.

**Step 2: Implement provider connection**

Open the verification URL with the system browser/authentication session, display the user code, and poll the host's typed status endpoint. Provider accounts are visibly scoped to the selected host.

**Step 3: Implement import UX**

Show destination name, LFS policy, estimated metadata when available, capability requirements, and audit notice. Keep large Hugging Face blobs opt-in and blocked until a quota design lands.

**Step 4: Verify**

```bash
swift test --package-path packages/swift-openpaw-ui --filter RepoTests
DESTINATION="$(python3 scripts/ios-test-destination.py)"
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$DESTINATION" \
  -only-testing:OpenPawUITests/RepositoryImportUITests
```

**Step 5: Commit**

```bash
git add packages/swift-openpaw-ui apps/ios/OpenPawUITests
git commit -m "Add GitHub and Hugging Face repository imports"
```

---

### Task 16: Complete Gate M0 and build a feature-flagged Mosh feasibility target

Do not perform this task until ADR 0001 has an approved production distribution path. If the gate remains unresolved, mark Mosh unavailable and continue with Task 17's ET/SSH path without pretending Mosh ships.

**Files:**
- Modify: `docs/decisions/0001-mosh-distribution-gate.md`
- Create: `packages/swift-mosh-transport/Package.swift`
- Create: `packages/swift-mosh-transport/Sources/OpenPawMoshTransport/MoshTransport.swift`
- Create: `packages/swift-mosh-transport/Sources/OpenPawMoshTransport/MoshBootstrap.swift`
- Create: `packages/swift-mosh-transport/Tests/OpenPawMoshTransportTests/MoshTransportTests.swift`
- Modify: `packages/swift-terminal-core/Sources/OpenPawTerminalCore/TransportSelector.swift`
- Modify: `packages/swift-terminal-core/Tests/OpenPawTerminalCoreTests/TransportSelectorTests.swift`
- Create: `apps/ios/OpenPawAppTests/MoshLiveTests.swift`

**Step 1: Write failing protocol/state tests**

Cover:

- SSH bootstrap parsing without shell interpolation.
- UDP session key handling and zeroization.
- Roaming address change.
- Replay, malformed packet, timeout, and server exit.
- Resize, send, output, disconnect, and cancellation semantics matching `TerminalBackend`.
- No secret in `Debug`, logs, crash breadcrumbs, or state restoration.

**Step 2: Implement behind `OPENPAW_ENABLE_MOSH`**

The production build must compile without this flag. `TransportAvailability.built` includes Mosh only when the package is actually linked.

**Step 3: Add physical-device feasibility tests**

Test against a disposable `mosh-server` host:

- Same Wi-Fi connect/type/resize.
- Wi-Fi to cellular and back without losing the terminal.
- Foreground/background within supported window.
- Sleep/wake.
- UDP blocked produces typed failure for fallback.
- Force kill does not claim transport continuity; relaunch restores the multiplexer session.

Record device, iOS version, server version, network transitions, packet loss, reconnect time, and failures in the ADR.

**Step 4: Verify**

```bash
swift test --package-path packages/swift-mosh-transport
swift test --package-path packages/swift-terminal-core --filter TransportSelectorTests
OPENPAW_RUN_LIVE_MOSH=1 xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "id=$OPENPAW_IOS_DEVICE_ID" \
  -only-testing:OpenPawAppTests/MoshLiveTests
```

**Step 5: Commit**

```bash
git add docs/decisions packages/swift-mosh-transport packages/swift-terminal-core apps/ios/OpenPawAppTests
python3 scripts/validate-pbxproj-diff.py --staged
git commit -m "Prove Mosh transport on a physical iPhone"
```

---

### Task 17: Complete Gate E0, then implement ET and automatic transport selection

Do not create or link `ETTerminalTransport` until ADR 0002 approves the upstream-provenance, GPLv3/App Store, attribution/source, and distribution path and the operational acceptance design. If E0 remains unresolved, retain the current isolated protocol foundation, leave `ExperimentalTransportFeatures.eternalTerminalInterop` disabled, omit ET from the app/UI, and wire only the legally approved built transports, which may be Mosh → SSH or SSH-only.

**Files:**
- Modify: `docs/decisions/0002-et-provenance-distribution-gate.md`
- Modify: `packages/swift-et-transport/Package.swift`
- Create after E0 approval: `packages/swift-et-transport/Sources/OpenPawETTransport/ETTerminalTransport.swift`
- Create after E0 approval: `packages/swift-et-transport/Sources/OpenPawETTransport/ETBootstrap.swift`
- Create after E0 approval: `packages/swift-et-transport/Tests/OpenPawETTransportTests/ETTerminalTransportTests.swift`
- Modify: `apps/ios/OpenPawApp/OpenPawApp.swift`
- Modify: `apps/ios/OpenPawApp/SSHTerminalBackend.swift`
- Create: `apps/ios/OpenPawApp/SelectingTerminalBackend.swift`
- Modify: `packages/swift-terminal-core/Sources/OpenPawTerminalCore/TransportSelector.swift`
- Modify: `packages/swift-terminal-core/Sources/OpenPawTerminalCore/Hosts.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/HostEditorView.swift`
- Modify: `apps/ios/OpenPawAppTests/SSHTerminalBackendTests.swift`
- Create: `apps/ios/OpenPawAppTests/SelectingTerminalBackendTests.swift`

**Step 1: Close Gate E0 with evidence**

Record legal review of upstream GPLv3/protocol provenance and clean-room sufficiency, intended App Store or alternative distribution, complete-source/notice obligations, and the line between protocol interoperability and derivative implementation. Define required real-`etserver`, reconnect, concurrency, and physical-device lifecycle evidence. If the decision is not approved, stop this task after preserving the disabled foundation and test the Mosh → SSH or SSH-only selector path.

**Step 2: Write failing ET transport tests**

Require the existing framing/secretbox/replay foundation to support a complete terminal lifecycle: verified SSH bootstrap, authenticated ET connection, input/output, resize, cancellation, reconnect, malformed frame handling, replay refusal, and secret redaction. Keep ET behind its experimental build flag until these tests and live interoperability pass.

**Step 3: Write failing selection integration tests**

Require:

- Automatic preference attempts built transports in policy order.
- User-pinned transport does not silently choose another without confirmation, except an explicit “Allow fallback” setting.
- Missing `mosh-server`, blocked UDP, ET disabled, and SSH failure produce typed attempt diagnostics.
- Successful fallback records `lastSuccessfulTransport` through `HostStore.recordSuccessfulTransport`.
- Next connect prefers last-known-good only when compatible with current preference and availability.
- Host-key verification occurs before bootstrap credentials.
- Disconnect/cancel stops only the owned attempt and cannot tear down a newer connection.

**Step 4: Implement the complete ET backend and selecting backend**

Finish `ETTerminalTransport` only after E0. Then let `SelectingTerminalBackend` own the attempt loop and expose one state/output stream. Concrete SSH/Mosh/ET transports stay isolated. Remove the hardcoded SSH-only factory in `AppWiring.init`. Mosh remains separately blocked unless Gate M0 and Task 16 passed. The selector plans only transports whose legal and operational gates passed and whose implementations are linked.

**Step 5: Make availability honest**

The host editor displays only linked transports whose gates passed. Unbuilt or unapproved transports may appear in an informational comparison marked unavailable, not as a saveable preference.

**Step 6: Verify**

Always verify the selector's disabled/unavailable path:

```bash
swift test --package-path packages/swift-terminal-core
```

Only after E0 approval, verify the ET implementation and app integration:

```bash
swift test --package-path packages/swift-et-transport
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$(python3 scripts/ios-test-destination.py)" \
  -only-testing:OpenPawAppTests/SelectingTerminalBackendTests \
  -only-testing:OpenPawAppTests/SSHTerminalBackendTests
```

**Step 7: Commit**

```bash
git add packages/swift-et-transport apps/ios/OpenPawApp apps/ios/OpenPawAppTests packages/swift-terminal-core packages/swift-openpaw-ui
python3 scripts/validate-pbxproj-diff.py --staged
git commit -m "Select resilient transports with safe fallback"
```

---

### Task 18: Add high-value Moshi-parity polish without expanding the security surface

**Files:**
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/RecentWorkspace.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/WorkspaceHomeView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/SessionListView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Theme/OpenPawTheme.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/Settings/AppearanceSettingsView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/Settings/TerminalSettingsView.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ShellTests.swift`
- Modify: `tools/openpaw-snapshot/Sources/openpaw-snapshot/ScreenCatalog.swift`

**Step 1: Write failing behavior tests**

Add only the release-critical parity items:

- Per-host recent workspaces/directories with bounded history and privacy-aware labels.
- One-tap jump to a known multiplexer session/window where the adapter supports it.
- Expanded terminal themes and fonts with contrast checks and snapshot coverage.
- App icon selection only if the asset/license work is complete.
- Existing image, OSC52, link, shortcut, and voice features remain discoverable through Settings/help.

**Step 2: Keep deferred features explicit**

Live Activities, Dynamic Island, Apple Watch, and webhook notifications remain a separate roadmap item after push/deep-link infrastructure. Do not hide them as half-working toggles.

**Step 3: Verify**

```bash
swift test --package-path packages/swift-openpaw-ui
swift run --package-path tools/openpaw-snapshot openpaw-snapshot \
  --output "$JCODE_SCRATCH_DIR/openpaw-parity-snapshots"
```

**Step 4: Commit**

```bash
git add packages/swift-openpaw-ui
git commit -m "Polish workspace recovery and appearance"
```

---

### Task 19: Run the cross-feature acceptance matrix and fix every regression

**Files:**
- Create: `docs/verification/production-workspace-expansion.md`
- Modify: implementation files and tests only as failures demand

**Step 1: Run complete static and package checks**

```bash
bash scripts/check.sh
cargo fmt --all --manifest-path host/Cargo.toml -- --check
cargo clippy --workspace --all-targets --all-features --manifest-path host/Cargo.toml -- -D warnings
cargo test --workspace --manifest-path host/Cargo.toml
swift test --package-path packages/swift-terminal-core
swift test --package-path packages/swift-agent-protocol
swift test --package-path packages/swift-openpaw-ui
```

Expected: all PASS.

**Step 2: Run focused iOS 26.5 simulator suites sequentially**

Avoid parallel `xcodebuild` against shared DerivedData.

```bash
DESTINATION="$(python3 scripts/ios-test-destination.py)"
DD="$JCODE_SCRATCH_DIR/openpaw-production-expansion-dd"

xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$DESTINATION" -derivedDataPath "$DD" \
  -only-testing:OpenPawAppTests

xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$DESTINATION" -derivedDataPath "$DD" \
  -only-testing:OpenPawUITests
```

Expected: all PASS on the newest installed iOS runtime, which must be iOS 26.5 or newer for release acceptance.

**Step 3: Run snapshot suite**

```bash
swift run --package-path tools/openpaw-snapshot openpaw-snapshot \
  --output "$JCODE_SCRATCH_DIR/openpaw-production-expansion-snapshots"
```

Inspect iPhone and iPad outputs for clipped text, empty states, contrast, Dynamic Type, connection states, provider authorization, import progress, Sessions, Inbox, and categorized Settings.

**Step 4: Run live disposable-host acceptance**

Verify:

- Pairing, signed requests, replay refusal, and capability negotiation.
- Tailscale candidate refresh from a connected host.
- Session create, attach, restore, and kill.
- Inbox acknowledge, approve-once, deny, dismiss, and audit.
- Public GitHub and Hugging Face import.
- Private provider authorization and import using a test account/repository.
- Cancellation and daemon restart during import.
- Host switch invalidation across every tab.

Do not use personal production repositories or tokens.

**Step 5: Run physical-device acceptance**

On the connected iPhone:

- Tailscale app active, route hint visible, paired-host candidate discovery succeeds.
- Add a MagicDNS host manually when no discovery host is selected.
- Host key unknown/change paths are decidable and safe.
- Apple Speech dictation reaches an editable Terminal draft.
- Root swipes do not break Terminal interaction or system back.
- Biometric toggle and grace interval take effect without relaunch.
- Provider authorization callback/device flow and revoke work.
- If Mosh is approved: Wi-Fi/cellular roaming, background, blocked-UDP fallback, and force-kill session restoration pass.

**Step 6: Record evidence and iterate**

For every row, record command, environment, result, log/artifact path, and linked defect. Fix failures and rerun the narrowest failing test, then the affected matrix row. Do not declare completion with known intermittent exit 65 failures; distinguish infrastructure errors from product failures and make the harness deterministic.

**Step 7: Commit**

```bash
git add docs/verification scripts
git add apps/ios/OpenPawAppTests apps/ios/OpenPawUITests
git add packages/swift-agent-protocol/Tests packages/swift-openpaw-ui/Tests packages/swift-terminal-core/Tests packages/swift-et-transport/Tests
git add host/crates/openpaw-protocol/tests host/crates/openpaw-host/tests host/crates/openpaw-git/tests host/crates/openpaw-files/tests
# Add source fixes separately and inspect the staged list.
python3 scripts/validate-pbxproj-diff.py --staged
git commit -m "Verify the production workspace expansion"
```

---

### Task 20: Release readiness, privacy, licensing, and final repository hygiene

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture/roadmap.md`
- Create: `apps/ios/OpenPawApp/PrivacyInfo.xcprivacy`
- Create: `docs/privacy.md`
- Create: `docs/legal/third-party-licenses.md`
- Modify: `NOTICE`
- Modify: `LICENSE` only if the approved Mosh distribution decision changes the project license
- Create: `docs/releases/production-workspace-expansion.md`

**Step 1: Audit release claims**

- Say “Mosh” only if Gate M0 and Task 16 physical acceptance passed.
- Say “Eternal Terminal” is app-integrated only if Gate E0 and Task 17 interoperability/lifecycle acceptance passed.
- Explain that Tailscale discovery is host-mediated and that the optional admin connector requires an admin-created client.
- Explain provider account scope per host and token deletion.
- Document fallback behavior and the no-exec security model.

**Step 2: Audit privacy and secrets**

Search tracked files, test logs, snapshots, settings exports, and fixtures for:

- Personal signing identifiers.
- SSH keys/passphrases.
- Tailscale OAuth credentials.
- GitHub/Hugging Face tokens or authorization headers.
- Private hostnames, tailnet names, repository names, and device IDs.

Use test tokens only in process environment and redact them from artifacts.

**Step 3: Audit the staged commit**

```bash
git diff --check
git status --short
git diff --cached --name-only
git diff --cached -- apps/ios/OpenPaw.xcodeproj/project.pbxproj
```

Expected: no whitespace errors; any staged project diff contains only required file, resource, package, or build-phase structure and contains no signing values.

**Step 4: Final verification**

Run Task 19 again from a clean build directory. Require two consecutive green simulator/UI runs for gesture and lifecycle suites, plus one physical-device pass.

**Step 5: Commit**

```bash
git add README.md docs NOTICE apps/ios/OpenPawApp/PrivacyInfo.xcprivacy
# Stage LICENSE only when Gate M0 explicitly changed the distribution license.
python3 scripts/validate-pbxproj-diff.py --staged
git commit -m "Prepare the production workspace expansion release"
```

---

## Requirement-to-acceptance traceability

| User requirement | Owning tasks | Acceptance evidence |
|---|---|---|
| Add Tailscale/SSH device automatically | 5-6 | Route hint, auto paired-host refresh, optional admin connector, manual fallback, preflight XCUITests, physical Tailscale pass |
| SSH should use Mosh | 1, 16-17 | Approved M0 license/distribution ADR, Mosh package tests, physical roaming matrix, automatic fallback tests |
| Eternal Terminal fallback | 1, 17 | Approved E0 provenance/distribution ADR, real `etserver` interoperability, reconnect/lifecycle tests, honest disabled fallback when unresolved |
| Compare with Moshi and add gaps | 18 | Parity matrix, recent workspace/session jump/theme snapshots; deferred ecosystem features explicitly tracked |
| Swipe left/right to switch every tab | 3-4 | Pure gesture-policy tests plus XCUITests on all six destinations and conflict cases |
| Terminal No Host dropdown/connect | 5 | HostSwitcher model tests and XCUITests on empty/disconnected/connected states |
| Deeply test Sessions | 7, 9, 19 | Deterministic XCUITests plus live create/attach/restore/kill |
| Deeply test Inbox | 8-9, 19 | Host API tests, deterministic risk/deep-link tests, live approve/deny/dismiss/audit |
| GitHub/Hugging Face import | 12-15 | Provider mock tests, no-exec boundary tests, XCUITests, live public/private imports |
| Rich categorized Settings | 10-11 | Hostile migration tests, category/search XCUITests, iPhone/iPad snapshots, live biometric check |
| Modern production release | 2, 19-20 | Dynamic iOS 26.5 suite, complete Swift/Rust tests, snapshots, disposable host, physical iPhone, privacy/license audit |

## Minimal-retry execution strategy

- Land deterministic fixture and simulator selection before feature UI.
- Build pure policies and host contracts before SwiftUI wiring.
- Run focused tests after every red/green step.
- Run expensive Xcode/live/snapshot matrices only at phase boundaries.
- Keep external providers behind local mock servers until live acceptance.
- Keep Mosh and ET behind separate build flags until their independent legal and physical/interoperability gates pass.
- Reuse one disposable host harness for Tailscale, Sessions, Inbox, Repo, and audit.
- Keep all feature state host-scoped and invalidate it through one generation mechanism, reducing stale-state bugs across tabs.

## Completion criteria

The plan is complete when every traceability row has observed evidence, no security, provenance, or licensing gate is bypassed, the newest iOS 26.5 simulator passes without retries, the physical iPhone matrix passes, repository imports retain the no-exec boundary, and personal signing configuration remains uncommitted even when legitimate Xcode target-membership changes are committed.
