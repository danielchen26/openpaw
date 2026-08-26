# iPhone Interaction Simplification Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Simplify OpenPaw's iPhone Home and navigation, make machine connection controls deterministic, stow terminal chrome during search, and expose actionable voice state.

**Architecture:** Preserve the existing model/router/backend boundaries. Add small pure presentation contracts for compact navigation and Home copy, then route connection actions through model-owned operations instead of independent view Tasks. Keep iPad/Mac split behavior unchanged.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing/XCTest, XCUITest, openpaw-snapshot.

---

### Task 1: Simplify Home

**Files:**
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/WorkspaceHomeView.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/WorkspaceHomeViewTests.swift`
- Modify: `apps/ios/OpenPawUITests/HomeInteractionUITests.swift`
- Modify: `tools/openpaw-snapshot/Sources/openpaw-snapshot/ScreenCatalog.swift`

1. Add failing copy/layout tests proving the visible title is Tailscale, advanced repository transfer is absent from Home, and online candidate rows expose a direct connect verb.
2. Run focused tests and observe expected failures.
3. Remove the Home transfer panel, collapse redundant summary copy, rename visible Tailnet terminology, and keep advanced import reachable outside Home.
4. Make online candidate/saved-machine taps invoke the direct connection path and Terminal route.
5. Run focused tests and commit.

### Task 2: Make host actions deterministic

**Files:**
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Model/OpenPawModel.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Components/HostSwitcher.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/HostSwitcherTests.swift`
- Modify: `apps/ios/OpenPawUITests/HostSwitcherUITests.swift`

1. Add failing tests for select-and-connect, reconnect ownership, disconnect cancellation, and disabled overlapping actions.
2. Run focused tests and observe failures.
3. Add model-owned connect/select/reconnect operations with generation checks.
4. Route HostSwitcher actions through these APIs and connect immediately after choosing a different host.
5. Run focused tests and commit.

### Task 3: Compact one-destination navigation

**Files:**
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ShellTests.swift`
- Modify: `apps/ios/OpenPawUITests/RootTabSwipeUITests.swift`

1. Add a failing pure presentation test proving compact navigation exposes one current destination, not all six.
2. Run focused tests and observe failure.
3. Replace the six-item compact destination rail with previous/current/next controls while preserving swipe, accessibility actions, and keyboard paging.
4. Verify regular split navigation remains unchanged.
5. Run tests and commit.

### Task 4: Stow terminal controls during search

**Files:**
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/TerminalScreenView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ControlDeckTests.swift`
- Modify: `apps/ios/OpenPawUITests/ControlDeckUITests.swift`

1. Add failing tests for search begin/end deck transitions.
2. Run tests and observe failure.
3. Stow the custom deck and release terminal first responder before search focus. Restore the prior deck state on close without reopening the keyboard.
4. Run tests and commit.

### Task 5: Make dictation state actionable

**Files:**
- Modify: `apps/ios/OpenPawApp/SpeechDictation.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Model/OpenPawModel.swift`
- Modify: relevant composer/terminal voice view in `RootView.swift`
- Modify: `apps/ios/OpenPawAppTests/LiveDictationTests.swift`
- Modify: `apps/ios/OpenPawUITests/DictationFlowUITests.swift`

1. Add failing state/error presentation tests for denied permission, unavailable recognizer, no speech, and successful transcript.
2. Run tests and observe failure.
3. Preserve typed errors from SpeechDictation and display concise status/action copy.
4. Run focused tests and commit.

### Task 6: Visual and integration acceptance

1. Run all Swift package tests and relevant XCUITests.
2. Build the iOS app for simulator.
3. Generate release snapshots into `$JCODE_SCRATCH_DIR/openpaw-iphone-simplification`.
4. Inspect populated Home, Terminal, and session-space iPhone images for density, clipping, duplicate controls, and one-page behavior.
5. Run `scripts/check.sh` if the focused suite is green.
6. Commit documentation and push only verified files, leaving the pre-existing `project.pbxproj` modification untouched.
