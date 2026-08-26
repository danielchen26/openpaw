# OpenPaw Proactive Radial Launcher Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace compact OpenPaw's paged Control Deck with a bottom-right, context-aware radial launcher that drills through Host, Herdr Session, Tab, Pane, Repo or Tool, previews Top 3 proactive next steps, and safely routes confirmed actions exactly once.

**Architecture:** Build a pure `WorkspaceContextGraph` from existing host, Session, Herdr, repository, Inbox and Agent event state. Render a frozen graph snapshot through an independent radial gesture state machine, and dispatch typed actions through a generation-owned coordinator. Produce immediate local proposals plus background Agent-derived proposals from existing structured plan and workflow events, without sending hidden prompts into the user's session.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, XCTest/XCUITest, OpenPawProtocol normalized events, OpenPawTerminalCore multiplexer adapters, Qwen3-ASR, openpaw-snapshot.

---

## Execution rules

- Work test-first and commit after every task.
- Do not stage the existing local `apps/ios/OpenPaw.xcodeproj/project.pbxproj` development-team or formatting difference.
- Keep the current full-screen hold-to-talk path outside the Paw Orb.
- Never run a destructive command from a radial gesture.
- Treat normalized Agent events as advisory input only. Do not inject a hidden proposal prompt into a live Agent session.
- Freeze graph and proposal ordering for the lifetime of one gesture.
- After every asynchronous boundary, recheck host ID, connection generation, graph snapshot ID and target Session/Tab.

### Task 1: Remove Apple Speech and default voice input to Qwen3 0.6B

**Files:**
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/DictationEngineChoice.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Settings/OpenPawSettings.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/SettingsView.swift`
- Modify: `apps/ios/OpenPawApp/LocalASRModelStore.swift`
- Modify: `apps/ios/OpenPawApp/OpenPawApp.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/DictationEngineChoiceTests.swift`
- Modify: `apps/ios/OpenPawAppTests/LocalDictationAccuracyTests.swift`
- Modify: `apps/ios/OpenPawUITests/DictationEngineSettingsUITests.swift`
- Modify: `apps/ios/OpenPawUITests/DictationFlowUITests.swift`

**Step 1: Write failing no-Apple policy tests**

Add tests proving the concrete product contract:

```swift
@Test func aFreshInstallDefaultsToQwenSmall() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    let settings = OpenPawSettings(defaults: defaults)
    #expect(settings.dictationEngine == .qwen3Small)
}

@Test func aStoredAppleChoiceMigratesToQwenSmall() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.set("apple", forKey: "openpaw.settings.dictationEngine")
    let settings = OpenPawSettings(defaults: defaults)
    #expect(settings.dictationEngine == .qwen3Small)
}

@Test func settingsNeverOfferAppleSpeech() {
    for locale in ["zh-CN", "en-US"] {
        #expect(!DictationEngineChoice.choices(forLocale: locale).contains(.appleSpeech))
    }
}
```

Add app-target tests proving `LocalASREngineFactory.engine(for: .appleSpeech)` returns `nil`, Qwen 0.6B is returned only when installed, and an absent model produces an actionable unavailable state rather than Apple recognition.

**Step 2: Run the focused tests and verify failure**

```bash
cd packages/swift-openpaw-ui
swift test --filter DictationEngineChoiceTests
```

Expected: FAIL because fresh settings and stored Apple currently resolve to Apple Speech.

**Step 3: Make Qwen3 0.6B the only default**

In `OpenPawSettings`, map a missing key, an unknown value and the legacy `apple` value to `.qwen3Small`. Keep `.qwen3Large` and `.parakeet` only when explicitly stored and valid for the selected language.

In `DictationEngineChoice.choices(forLocale:)`, omit `.appleSpeech` from all user-visible choices. Keep the legacy case only for backward decoding until a later schema cleanup.

**Step 4: Remove every runtime Apple fallback**

Change `LocalASREngineFactory` so it no longer stores or constructs a `SpeechDictation` instance. Its legacy `.appleSpeech` branch returns `nil`. In `OpenPawApp`, remove `let appleSpeech = SpeechDictation()`, pass `dictation: nil`, and construct `LocalASREngineFactory(store:)` without an Apple dependency.

The effective behavior must be:

```swift
switch selectedChoice {
case .qwen3Small, .qwen3Large, .parakeet:
    return modelIsInstalledAndSupported ? localEngine : nil
case .appleSpeech:
    return nil
}
```

Do not add a simulator exception that selects Apple. Simulator dictation must truthfully report that local speech models require a physical device.

**Step 5: Make missing-model UI actionable**

Settings must identify Qwen3 0.6B as the default high-accuracy recognizer and expose its 450 MB download action. Label Qwen3 1.7B as `Maximum accuracy` with its 1.9 GB cost. If the selected model is absent, hold-to-talk and the dictation button must show a direct `Download in Settings` explanation instead of listening silently.

**Step 6: Run package, app and UI tests**

```bash
cd packages/swift-openpaw-ui
swift test --filter DictationEngineChoiceTests
cd ../../
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath "$JCODE_SCRATCH_DIR/openpaw-radial-voice" \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:OpenPawUITests/DictationEngineSettingsUITests \
  -only-testing:OpenPawUITests/DictationFlowUITests
```

Expected: Apple is absent from Settings and runtime wiring; missing local weights produce an explicit unavailable/download path.

On a physical iPhone with Qwen3 0.6B already downloaded, run `OpenPawAppTests/LocalDictationAccuracyTests` and require the existing bilingual command corpus to remain below the 15 percent CER threshold through the app wrapper.

**Step 7: Commit**

```bash
git add packages/swift-openpaw-ui/Sources/OpenPawUI/Models/DictationEngineChoice.swift \
  packages/swift-openpaw-ui/Sources/OpenPawUI/Settings/OpenPawSettings.swift \
  packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/SettingsView.swift \
  apps/ios/OpenPawApp/LocalASRModelStore.swift \
  apps/ios/OpenPawApp/OpenPawApp.swift \
  packages/swift-openpaw-ui/Tests/OpenPawUITests/DictationEngineChoiceTests.swift \
  apps/ios/OpenPawAppTests/LocalDictationAccuracyTests.swift \
  apps/ios/OpenPawUITests/DictationEngineSettingsUITests.swift \
  apps/ios/OpenPawUITests/DictationFlowUITests.swift
git commit -m "Require high accuracy local dictation"
```

### Task 2: Preserve Herdr workspace and tab metadata

**Files:**
- Modify: `packages/swift-terminal-core/Sources/OpenPawTerminalCore/Multiplexer.swift`
- Modify: `packages/swift-terminal-core/Tests/OpenPawTerminalCoreTests/MultiplexerAdapterTests.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/SessionSpacePresentation.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/SessionSpacePresentationTests.swift`

**Step 1: Add failing parser tests**

Use the existing real Herdr pane and tab fixtures. Assert that parsing preserves `workspace_id`, `tab_id`, tab label, pane ID and terminal ID instead of flattening away the hierarchy:

```swift
#expect(panes[0].workspaceID == "workspace-main")
#expect(panes[0].tabID == "tab-build")
#expect(panes[0].tabLabel == "Build")
#expect(panes[0].id == "pane-agent")
#expect(panes[0].terminalID == "term-agent")
```

Add a compatibility test proving old JSON without those optional fields still decodes.

**Step 2: Verify the tests fail**

Run:

```bash
cd packages/swift-terminal-core
swift test --filter Herdr
```

Expected: FAIL because `RemoteSession` drops workspace and tab identity.

**Step 3: Extend the transport model minimally**

Add optional fields to `RemoteSession`:

```swift
public var workspaceID: String?
public var tabID: String?
public var tabLabel: String?
```

Add matching snake-case coding keys and defaulted initializer parameters. Extend `HerdrAdapter.AgentDTO` and `TabDTO` parsing so `parseSessions` retains workspace and tab identity. Do not change existing `id` semantics. It remains the command-addressable pane ID.

**Step 4: Preserve metadata through SessionSpace snapshots**

Ensure `LiveMultiplexerSessionSpaceProvider` returns the enriched values unchanged and test that a snapshot retains them across discovery.

**Step 5: Run tests and commit**

```bash
cd packages/swift-terminal-core && swift test --filter Herdr
cd ../swift-openpaw-ui && swift test --filter SessionSpacePresentationTests
cd ../../
git add packages/swift-terminal-core/Sources/OpenPawTerminalCore/Multiplexer.swift \
  packages/swift-terminal-core/Tests/OpenPawTerminalCoreTests/MultiplexerAdapterTests.swift \
  packages/swift-openpaw-ui/Sources/OpenPawUI/Models/SessionSpacePresentation.swift \
  packages/swift-openpaw-ui/Tests/OpenPawUITests/SessionSpacePresentationTests.swift
git commit -m "Preserve Herdr workspace tab context"
```

### Task 3: Build the pure workspace context graph

**Files:**
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/WorkspaceContextGraph.swift`
- Create: `packages/swift-openpaw-ui/Tests/OpenPawUITests/WorkspaceContextGraphTests.swift`

**Step 1: Write failing graph tests**

Cover these requirements:

- current host is the graph root;
- first level contains Herdr workspaces plus one `Switch Host` edge node;
- Herdr panes group under workspace and tab metadata;
- tmux/Zellij/Screen sessions group under session then window, with a synthetic tab if window discovery is absent;
- a working directory associates only with an allowlisted repository;
- stable IDs do not depend on array order;
- missing metadata creates a marked partial synthetic node, not a false label;
- every authenticated destination contributes its relevant tool nodes.

Representative test:

```swift
@Test func herdrBuildsHostWorkspaceTabPaneRepoHierarchy() {
    let graph = WorkspaceContextGraphBuilder().build(fixture)
    let host = graph.root
    let workspace = try #require(host.children.first { $0.kind == .session })
    let tab = try #require(workspace.children.first { $0.kind == .tab })
    let pane = try #require(tab.children.first { $0.kind == .pane })
    #expect(pane.children.contains { $0.kind == .repository && $0.title == "openpaw" })
    #expect(host.children.last?.kind == .switchHost)
}
```

**Step 2: Run and verify failure**

```bash
cd packages/swift-openpaw-ui
swift test --filter WorkspaceContextGraphTests
```

Expected: compile failure because the graph types do not exist.

**Step 3: Implement the graph values**

Use immutable, sendable values:

```swift
public struct WorkspaceContextGraph: Sendable, Hashable {
    public var snapshotID: UUID
    public var hostID: HostID?
    public var connectionGeneration: Int
    public var root: WorkspaceContextNode
}

public struct WorkspaceContextNode: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case host, session, tab, pane, repository, tool, proposal, more, switchHost
    }
    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var isPartial: Bool
    public var children: [WorkspaceContextNode]
    public var action: WorkspaceContextAction?
}
```

Define typed `WorkspaceContextAction` cases but leave proposal cases empty until Task 4. Sort children using explicit rank and stable ID, never localized title alone.

**Step 4: Implement builder input**

Create a single `WorkspaceContextInput` value containing host, destination, repo pane, structured sessions, transcripts, `SessionSpaceSnapshot`, selected IDs, repositories and Inbox. Keep the builder pure and free of `OpenPawModel` references so tests can cover every branch without actors or views.

**Step 5: Run tests and commit**

```bash
cd packages/swift-openpaw-ui
swift test --filter WorkspaceContextGraphTests
cd ../../
git add packages/swift-openpaw-ui/Sources/OpenPawUI/Models/WorkspaceContextGraph.swift \
  packages/swift-openpaw-ui/Tests/OpenPawUITests/WorkspaceContextGraphTests.swift
git commit -m "Add workspace context graph"
```

### Task 4: Produce stable local and Agent-derived proposals

**Files:**
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/ProactiveProposal.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Model/ProposalEngine.swift`
- Create: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ProposalEngineTests.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/WorkspaceContextGraph.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Backend/PreviewBackend.swift`

**Step 1: Write failing proposal tests**

Test that:

- local proposals are available without Agent events;
- the newest `plan.updated` replaces older versions of the same plan;
- the first in-progress step outranks pending steps;
- a failed tool and pending question produce relevant actions;
- current destination and selected Session boost rank without changing IDs;
- only Top 3 plus `More` enter the graph;
- equal scores use stable ID tie-breaking;
- a frozen graph retains the old order when events update;
- credentials, bearer tokens, private-key blocks and long Terminal output are redacted;
- Agent-derived suggestions do not create a new model turn.

Representative test:

```swift
@Test func latestAgentPlanProducesTheSpecificNextStep() {
    let proposals = ProposalEngine().proposals(for: inputWithUpdatedPlan)
    #expect(proposals.first?.source == .agentDerived)
    #expect(proposals.first?.title == "Run the focused parser test")
}
```

**Step 2: Run and verify failure**

```bash
cd packages/swift-openpaw-ui
swift test --filter ProposalEngineTests
```

**Step 3: Implement proposal domain values**

```swift
public struct ProactiveProposal: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, Hashable { case local, agentDerived }
    public enum Risk: Int, Sendable, Hashable { case safe, caution, destructive }
    public enum Payload: Sendable, Hashable {
        case navigate(WorkspaceContextTarget)
        case agentMessage(String)
        case terminalCommand(String)
        case tool(WorkspaceToolAction)
    }
    public var id: String
    public var title: String
    public var detail: String
    public var source: Source
    public var risk: Risk
    public var score: Int
    public var target: WorkspaceContextTarget
    public var payload: Payload
}
```

Extract Agent-derived proposals only from normalized events already in `OpenPawModel.transcripts`: latest plans, unresolved questions, failed tools and recent completed turns. Reuse existing protocol risk data when available. Classify natural-language instructions as destructive when their content requests a destructive operation.

**Step 4: Merge proposals into graph leaves**

Attach `Top 3 + More` under the relevant pane or page node. Preserve proposal IDs across score changes. Do not mutate an existing graph instance.

**Step 5: Seed deterministic preview events**

Extend `PreviewBackend` with one active Herdr workspace, multiple tabs, plan steps, a failed tool, a dirty repo and an Inbox request. These values become unit, snapshot and XCUITest fixtures.

**Step 6: Run tests and commit**

```bash
cd packages/swift-openpaw-ui
swift test --filter ProposalEngineTests
swift test --filter WorkspaceContextGraphTests
cd ../../
git add packages/swift-openpaw-ui/Sources/OpenPawUI/Models/ProactiveProposal.swift \
  packages/swift-openpaw-ui/Sources/OpenPawUI/Model/ProposalEngine.swift \
  packages/swift-openpaw-ui/Sources/OpenPawUI/Models/WorkspaceContextGraph.swift \
  packages/swift-openpaw-ui/Sources/OpenPawUI/Backend/PreviewBackend.swift \
  packages/swift-openpaw-ui/Tests/OpenPawUITests/ProposalEngineTests.swift
git commit -m "Generate contextual next step proposals"
```

### Task 5: Implement radial selection and preview state machines

**Files:**
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/RadialLauncherState.swift`
- Create: `packages/swift-openpaw-ui/Tests/OpenPawUITests/RadialLauncherStateTests.swift`

**Step 1: Write failing state tests**

Test:

- touch down snapshots the graph and enters tracking;
- distance changes depth and angle changes sibling selection;
- moving inward backs up one level;
- returning to origin cancels;
- first release freezes preview and never dispatches;
- a second upward gesture confirms safe and caution proposals;
- destructive proposals reject gesture confirmation;
- graph updates during tracking are held for the next gesture;
- backgrounding, host change and page invalidation cancel safely;
- operation IDs are unique and confirmation is idempotent.

```swift
@Test func firstReleaseOnlyFreezesPreview() {
    var state = RadialLauncherState()
    state.begin(graph: graph, at: .zero)
    state.move(to: proposalPoint)
    let effect = state.end()
    #expect(effect == nil)
    #expect(state.phase == .frozenPreview)
}
```

**Step 2: Run and verify failure**

```bash
cd packages/swift-openpaw-ui
swift test --filter RadialLauncherStateTests
```

**Step 3: Implement pure geometry and state**

Define `RadialLauncherPhase`, `RadialSelection`, `RadialGeometry` and `RadialLauncherState`. Keep geometry pure so hit regions and depth thresholds can be tested without SwiftUI. Use fixed minimums from the design:

```swift
public enum RadialLauncherLayout {
    public static let orbVisualDiameter: CGFloat = 56
    public static let orbHitDiameter: CGFloat = 64
    public static let nodeVisualDiameter: CGFloat = 52
    public static let nodeHitDiameter: CGFloat = 64
}
```

The state machine may emit only typed effects such as `.freeze`, `.confirm(operationID, proposal)` and `.cancel`. It must not reference a terminal or router.

**Step 4: Run tests and commit**

```bash
cd packages/swift-openpaw-ui
swift test --filter RadialLauncherStateTests
cd ../../
git add packages/swift-openpaw-ui/Sources/OpenPawUI/Models/RadialLauncherState.swift \
  packages/swift-openpaw-ui/Tests/OpenPawUITests/RadialLauncherStateTests.swift
git commit -m "Add radial launcher state machine"
```

### Task 6: Route and execute proposals exactly once

**Files:**
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Model/ProposalExecutionCoordinator.swift`
- Create: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ProposalExecutionCoordinatorTests.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/SessionSpacePresentation.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift`

**Step 1: Write failing coordinator tests**

Cover:

- safe agent message focuses the intended Herdr pane, waits for acknowledgement and sends `message + "\n"` once;
- safe command sends `command + "\n"` once after confirmation;
- destructive command focuses the target and sends only `command`, without Return;
- stale host generation sends nothing;
- target Session or Tab change during an await sends nothing;
- duplicate confirmation with one operation ID sends once;
- attach or focus failure leaves the preview available with the failed stage;
- disconnected host offers reconnect rather than dispatch.

Use recording terminal and session executors rather than a live SSH host.

**Step 2: Run and verify failure**

```bash
cd packages/swift-openpaw-ui
swift test --filter ProposalExecutionCoordinatorTests
```

**Step 3: Implement generation-owned execution**

Add a `@MainActor @Observable` coordinator with an injectable context closure:

```swift
public struct ProposalExecutionContext: Sendable, Hashable {
    public var hostID: HostID?
    public var connectionGeneration: Int
    public var graphSnapshotID: UUID
    public var selectedSessionID: String?
    public var selectedTabID: String?
}
```

For every await:

1. check current context owns the operation;
2. route or focus through the existing `SessionSpaceActionCoordinator` and `SessionSpaceCommandExecuting` boundary;
3. recheck ownership;
4. dispatch to `TerminalBackend.send(text:)` once;
5. record the operation ID as completed.

Expose result phases for the preview card: routing, executing, completed and failed(stage, message).

**Step 4: Run tests and commit**

```bash
cd packages/swift-openpaw-ui
swift test --filter ProposalExecutionCoordinatorTests
swift test --filter SessionSpacePresentationTests
cd ../../
git add packages/swift-openpaw-ui/Sources/OpenPawUI/Model/ProposalExecutionCoordinator.swift \
  packages/swift-openpaw-ui/Sources/OpenPawUI/Models/SessionSpacePresentation.swift \
  packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift \
  packages/swift-openpaw-ui/Tests/OpenPawUITests/ProposalExecutionCoordinatorTests.swift
git commit -m "Execute contextual proposals safely"
```

### Task 7: Build the Paw Orb, radial layers and proposal card

**Files:**
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Components/PawOrbView.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Components/ProactiveRadialLauncherView.swift`
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Components/ProposalPreviewCard.swift`
- Create: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ProactiveRadialLauncherTests.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Theme/OpenPawTheme.swift` only if existing tokens cannot express the approved states

**Step 1: Write failing presentation tests**

Test pure presentation helpers for:

- 56-point Orb and 64-point hit region;
- 52-point nodes and 64-point selection regions;
- upper-middle proposal card anchor avoids the dynamic island and bottom keyboard;
- connected, updating, partial and failed status each have text and glyph as well as color;
- Reduce Motion uses fade and scale;
- VoiceOver exposes a hierarchical fallback list;
- destructive preview hides gesture confirmation and shows the explicit destructive action.

**Step 2: Run and verify failure**

```bash
cd packages/swift-openpaw-ui
swift test --filter ProactiveRadialLauncherTests
```

**Step 3: Implement the SwiftUI components**

`ProactiveRadialLauncherView` receives a graph, launcher state binding and effect callback. Attach one `DragGesture(minimumDistance: 0)` to the Paw Orb only. On iOS touch-down, resign the software keyboard. Use `Canvas` or ordinary positioned SwiftUI nodes only if profiling keeps the gesture at 60 fps.

Assign stable accessibility identifiers:

```text
root.proactive-launcher.orb
root.proactive-launcher.node.<stable-id>
root.proactive-launcher.preview
root.proactive-launcher.confirm
root.proactive-launcher.destructive-confirm
root.proactive-launcher.switch-host
```

When VoiceOver is running, a tap on the Orb opens an accessible drill-down list built from the same frozen graph.

**Step 4: Run tests and commit**

```bash
cd packages/swift-openpaw-ui
swift test --filter ProactiveRadialLauncherTests
cd ../../
git add packages/swift-openpaw-ui/Sources/OpenPawUI/Components/PawOrbView.swift \
  packages/swift-openpaw-ui/Sources/OpenPawUI/Components/ProactiveRadialLauncherView.swift \
  packages/swift-openpaw-ui/Sources/OpenPawUI/Components/ProposalPreviewCard.swift \
  packages/swift-openpaw-ui/Tests/OpenPawUITests/ProactiveRadialLauncherTests.swift
git commit -m "Build proactive radial launcher UI"
```

### Task 8: Replace compact Control Deck integration without losing tools

**Files:**
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/ControlDeck.swift`
- Modify or delete after migration: `packages/swift-openpaw-ui/Sources/OpenPawUI/Components/ControlDeckView.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ControlDeckTests.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ShellTests.swift`
- Modify: `apps/ios/OpenPawUITests/RootTabSwipeUITests.swift`
- Modify: `apps/ios/OpenPawUITests/ControlDeckUITests.swift`

**Step 1: Rewrite failing compact-root expectations**

Replace tests that expect a permanent paged strip with tests that expect:

- only the Paw Orb permanently occupies compact bottom chrome;
- root destination swipes still work;
- Terminal shortcuts, dictation, search, copy and font controls exist below the active Tab's Tools node;
- launcher touch does not trigger full-screen hold-to-talk;
- full-screen hold outside the Orb still dictates;
- Terminal search and keyboard ownership remain correct;
- regular split navigation remains unchanged.

**Step 2: Run targeted tests and verify failure**

```bash
cd packages/swift-openpaw-ui
swift test --filter ControlDeckTests
swift test --filter ShellTests
```

**Step 3: Integrate graph and launcher in RootView**

Replace the compact `safeAreaInset` strip with a bottom-trailing overlay. RootView owns:

- latest graph;
- frozen launcher state;
- proposal engine;
- execution coordinator;
- current preview result.

Build graph input from `OpenPawModel`, `sessionSpace`, `ShellRouter`, settings and available tools. Continue refreshing `sessionSpace` through the existing provider. Do not give the Orb gesture to the full-screen push-to-talk catcher.

Move current Control Deck operations into typed `WorkspaceToolAction` handling. Delete unused compact strip code only after every operation has an equivalent route and accessibility label.

**Step 4: Preserve root and terminal gesture arbitration**

Keep destination swipe exclusion around the Orb. Verify horizontal page swipes, Terminal vertical scrolling, software keyboard input, search presentation and hold-to-talk remain independent.

**Step 5: Run package and XCUITests**

```bash
cd packages/swift-openpaw-ui
swift test --filter ControlDeckTests
swift test --filter ShellTests
cd ../../
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath "$JCODE_SCRATCH_DIR/openpaw-radial-root" \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:OpenPawUITests/RootTabSwipeUITests \
  -only-testing:OpenPawUITests/ControlDeckUITests \
  -only-testing:OpenPawUITests/DictationFlowUITests
```

**Step 6: Commit**

```bash
git add packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift \
  packages/swift-openpaw-ui/Sources/OpenPawUI/Models/ControlDeck.swift \
  packages/swift-openpaw-ui/Sources/OpenPawUI/Components/ControlDeckView.swift \
  packages/swift-openpaw-ui/Tests/OpenPawUITests/ControlDeckTests.swift \
  packages/swift-openpaw-ui/Tests/OpenPawUITests/ShellTests.swift \
  apps/ios/OpenPawUITests/RootTabSwipeUITests.swift \
  apps/ios/OpenPawUITests/ControlDeckUITests.swift
git commit -m "Replace compact control deck with radial launcher"
```

If `ControlDeckView.swift` is deleted, stage it with `git add -u` scoped to that path.

### Task 9: Add deterministic launcher scenarios and visual snapshots

**Files:**
- Modify: `apps/ios/OpenPawApp/DebugScenario.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Backend/PreviewBackend.swift`
- Modify: `tools/openpaw-snapshot/Sources/openpaw-snapshot/ScreenCatalog.swift`
- Create: `apps/ios/OpenPawUITests/ProactiveRadialLauncherUITests.swift`

**Step 1: Add deterministic scenario states**

Provide launch arguments or debug scenario variants for:

- connected Home with closed launcher;
- Terminal with keyboard open;
- launcher frozen at Session level;
- launcher frozen on an Agent-derived safe proposal;
- launcher frozen on a destructive command;
- disconnected preview with reconnect action;
- late Agent event arriving while a graph is frozen.

Do not bypass public RootView interfaces in XCUITest. Debug data may seed the backend, but tests must press, drag, release and confirm through accessibility elements.

**Step 2: Write end-user UI tests**

Add tests for:

1. Paw Orb exists on every authenticated destination.
2. Dragging from Orb unfolds Session, Tab and proposal layers.
3. First release shows a preview and does not send.
4. Second confirmation sends one safe proposal.
5. Destructive proposal only prefills Terminal.
6. `Switch Host` opens host selection.
7. Keyboard is dismissed at launcher touch-down.
8. Late proposal refresh does not move frozen nodes.
9. Accessible fallback list exposes the same hierarchy.
10. Terminal dictation still works outside the Orb.

**Step 3: Add snapshot catalogue entries**

Render `RootView` and the launcher-specific component in closed, tracking, safe preview, destructive preview and failure states for iPhone. Include Home, Terminal, Sessions, Inbox, Repo and Settings context variants.

**Step 4: Run UI tests and snapshots**

```bash
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath "$JCODE_SCRATCH_DIR/openpaw-radial-ui" \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:OpenPawUITests/ProactiveRadialLauncherUITests

swift run --package-path tools/openpaw-snapshot openpaw-snapshot \
  --output "$JCODE_SCRATCH_DIR/openpaw-proactive-radial-snapshots"
```

Expected: all UI tests pass and the output includes populated iPhone launcher images without clipping, stacked chrome or an obscured preview card.

**Step 5: Inspect images**

Open at least:

- `RootView.populated@iphone.png`;
- new safe proposal preview image;
- new destructive proposal preview image;
- Home, Terminal, Sessions, Inbox, Repo and Settings context images.

Record observed layout results in the implementation commit or acceptance notes.

**Step 6: Commit**

```bash
git add apps/ios/OpenPawApp/DebugScenario.swift \
  packages/swift-openpaw-ui/Sources/OpenPawUI/Backend/PreviewBackend.swift \
  tools/openpaw-snapshot/Sources/openpaw-snapshot/ScreenCatalog.swift \
  apps/ios/OpenPawUITests/ProactiveRadialLauncherUITests.swift
git commit -m "Add radial launcher acceptance scenarios"
```

### Task 10: Verify on a physical iPhone

**Files:**
- Modify tests only if a real-device failure reveals a product defect.

**Step 1: Build and install with the existing development team from the command line**

Do not edit the project file to store the team.

```bash
xcodebuild -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$JCODE_SCRATCH_DIR/openpaw-radial-device" \
  -skipPackagePluginValidation \
  DEVELOPMENT_TEAM=2Z7U3AQV8D CODE_SIGN_STYLE=Automatic build
```

**Step 2: Run focused physical-device tests**

Use the connected device ID from `xcrun devicectl list devices`:

```bash
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination 'platform=iOS,id=<CONNECTED_DEVICE_ID>' \
  -derivedDataPath "$JCODE_SCRATCH_DIR/openpaw-radial-device" \
  -skipPackagePluginValidation \
  DEVELOPMENT_TEAM=2Z7U3AQV8D CODE_SIGN_STYLE=Automatic \
  -only-testing:OpenPawUITests/ProactiveRadialLauncherUITests
```

**Step 3: Exercise the actual acceptance path manually through public UI**

Observe and record:

- keyboard open, press Orb, keyboard hides;
- one continuous push reaches Session, Tab and Proposal;
- proposal card remains readable under the dynamic island;
- first release does not dispatch;
- second gesture sends one safe action to the selected Herdr pane;
- destructive command arrives without Return;
- full-screen hold-to-talk outside the Orb still transcribes;
- Settings identifies Qwen3 0.6B as the default or Qwen3 1.7B as an explicit maximum-accuracy choice, and never exposes or runs Apple Speech;
- app remains responsive during Agent event refresh.

If the selected Qwen model is not installed, do not download it automatically and do not substitute Apple. Validate the unavailable/download presentation and, if the user elects to download, rerun the real speech path afterward.

**Step 4: Iterate until acceptance behavior is observed**

Do not stop at compilation, snapshot or synthetic tests if the real path disagrees. Add a regression test for every fixed defect.

### Task 11: Full verification, documentation and comprehensive Git update

**Files:**
- Modify: `docs/plans/2026-08-26-proactive-radial-launcher-design.md` only if implementation required an approved design correction
- Modify: `docs/architecture/roadmap.md`
- Modify: `docs/protocol/host-api.md` only if a future read-only advisory host capability was actually added

**Step 1: Run package suites**

```bash
cd packages/swift-terminal-core && swift test
cd ../swift-agent-protocol && swift test
cd ../swift-openpaw-ui && swift test
```

Expected: all package tests pass. Do not report the suite as passing if a command timed out before the final summary.

**Step 2: Run iOS build and relevant full UI suites**

```bash
cd /Users/tianchichen/tmp/openpaw
xcodebuild -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath "$JCODE_SCRATCH_DIR/openpaw-radial-final" \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build

xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath "$JCODE_SCRATCH_DIR/openpaw-radial-final" \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:OpenPawUITests/ProactiveRadialLauncherUITests \
  -only-testing:OpenPawUITests/RootTabSwipeUITests \
  -only-testing:OpenPawUITests/ControlDeckUITests \
  -only-testing:OpenPawUITests/DictationFlowUITests \
  -only-testing:OpenPawUITests/ScenarioLaunchUITests
```

**Step 3: Run repository verification**

```bash
scripts/check.sh
```

**Step 4: Audit every changed file**

```bash
git status --short
git diff --stat
git diff --check
git diff -- apps/ios/OpenPaw.xcodeproj/project.pbxproj
```

Confirm the project-file difference is still only the user's local development-team or formatting state. If a real project-file feature change was necessary, stage a clean feature-only blob separately and document it.

**Step 5: Update roadmap and commit verified documentation**

```bash
git add docs/architecture/roadmap.md \
  docs/plans/2026-08-26-proactive-radial-launcher-design.md \
  docs/plans/2026-08-26-proactive-radial-launcher-implementation.md
git commit -m "Document proactive radial launcher delivery"
```

Skip the commit if no documentation changed.

**Step 6: Push and verify remote SHA**

```bash
git push origin feat/modern-workspace-home
LOCAL_SHA=$(git rev-parse HEAD)
REMOTE_SHA=$(git ls-remote origin refs/heads/feat/modern-workspace-home | awk '{print $1}')
test "$LOCAL_SHA" = "$REMOTE_SHA"
printf 'local=%s\nremote=%s\n' "$LOCAL_SHA" "$REMOTE_SHA"
```

Expected: local and remote SHA are identical, and `git status --short` shows only the pre-existing local `project.pbxproj` difference.
