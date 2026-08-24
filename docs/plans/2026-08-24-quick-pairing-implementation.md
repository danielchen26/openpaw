# OpenPaw Quick Pairing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Use superpowers:test-driven-development before every behavior change, superpowers:systematic-debugging for any unexpected failure, and superpowers:verification-before-completion before claiming a task is complete.

**Goal:** Add an automatic QR/link/Tailnet Quick Connect flow that always asks the user to confirm the SSH credential, then saves the host, connects SSH, redeems the existing one-time OpenPaw pairing code, stores the returned signer in Keychain, and opens Terminal.

**Architecture:** Define one bounded, versioned pairing envelope shared semantically by the Rust CLI and Swift client. Route QR scans, `openpaw://pair#...` links, and Home Tailnet rows into one `QuickConnectProposal`, one credential-confirmation screen, and one generation-owned coordinator. Preserve the current loopback-only host API and SSH host-key gate; no password, private key, persistent device token, HMAC key, arbitrary command, or cloud relay enters the QR payload.

**Tech Stack:** Swift 6, SwiftUI, VisionKit/DataScanner where available, Foundation URL/JSON encoding, OpenPawSSH KeychainStore, Swift Testing/XCTest/XCUITest, Rust/Clap/Serde, the existing OpenPaw pairing API, and a terminal QR renderer.

**Constraints:**

- Do not stage or modify the user's current `apps/ios/OpenPaw.xcodeproj/project.pbxproj` working-tree change. Keep all new Swift production types inside SwiftPM targets or existing Xcode-owned source files, and add UI-test coverage to existing Xcode source files.
- Do not put passwords, private keys, passphrases, Keychain identifiers, hook tokens, bearer tokens, HMAC keys, provider credentials, or shell commands in links, logs, fixtures, snapshots, or errors.
- Keep pairing codes five-minute, in-memory, single-use capabilities issued and consumed by the running daemon.
- A preselected SSH credential is never submitted until the user taps **Confirm SSH credential and connect**.
- A host-key mismatch is never auto-approved. An unknown key still uses the existing explicit host-key sheet.

---

### Task 1: Define and harden the Swift pairing envelope

**Files:**
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/QuickConnect.swift`
- Create: `packages/swift-openpaw-ui/Tests/OpenPawUITests/QuickConnectTests.swift`
- Modify: `docs/protocol/host-api.md:39-53`

**Step 1: Write failing codec tests**

Add `@Suite("Quick Connect pairing links")` with tests for:

- a known `QuickConnectEnvelopeV1` round-trips through `openpaw://pair#v1.<payload>`;
- URL scheme, host, fragment prefix, and envelope version are exact;
- ordered targets prefer MagicDNS, then Tailnet IPv4/IPv6, then explicit hostname;
- the decoder rejects expired links, expiry more than five minutes after issuance, oversized fragments, unknown versions, invalid ports, whitespace/control characters, user-info embedded in a target, duplicate targets, unsupported fingerprint algorithms, and empty pairing codes;
- `QuickConnectProposal.from(candidate:)` preserves nickname, DNS name, Tailnet addresses, online state, and leaves pairing metadata absent;
- encoded data never contains fixture strings named `password`, `private-key`, `hook-token`, `bearer-token`, or `hmac-secret`;
- malformed input does not mutate a supplied `HostStore`.

Use fixed dates and deterministic UUID/session identifiers. Do not assert only that decoding fails; assert the typed `QuickConnectLinkError` case.

**Step 2: Run the focused suite and observe RED**

```bash
swift test --package-path packages/swift-openpaw-ui --filter QuickConnectTests
```

Expected: compilation fails because the Quick Connect types do not exist.

**Step 3: Implement the minimal pure model**

Create:

```swift
public struct QuickConnectTarget: Sendable, Hashable, Codable {
    public var hostname: String
    public var port: Int
    public var source: Source
}

public struct QuickConnectHostKey: Sendable, Hashable, Codable {
    public var algorithm: String
    public var fingerprint: String
}

public struct QuickConnectEnvelopeV1: Sendable, Hashable, Codable { ... }
public struct QuickConnectProposal: Identifiable, Sendable, Hashable { ... }
public enum QuickConnectLinkCodec { ... }
public enum QuickConnectLinkError: Error, Sendable, Hashable { ... }
```

Rules:

- encode compact sorted-key JSON as UTF-8, then base64url without padding;
- cap decoded fragment bytes before base64 decoding and cap decoded JSON bytes again;
- normalize the existing pairing code without weakening host-side validation;
- accept only `openpaw://pair#v1.<payload>`;
- validate at decode time and return a pure proposal;
- provide `QuickConnectProposal.from(candidate:now:)` for Tailnet rows without a code;
- provide a pure matching function that finds an existing host by normalized hostname/IP, port, and username when one exists.

Update `docs/protocol/host-api.md` with the link shape, allowed fields, forbidden secret classes, and the statement that a scanned proposal is not trust.

**Step 4: Run focused tests and verify GREEN**

```bash
swift test --package-path packages/swift-openpaw-ui --filter QuickConnectTests
```

Expected: all QuickConnect codec/proposal tests pass.

**Step 5: Commit**

```bash
git add packages/swift-openpaw-ui/Sources/OpenPawUI/Models/QuickConnect.swift \
  packages/swift-openpaw-ui/Tests/OpenPawUITests/QuickConnectTests.swift \
  docs/protocol/host-api.md
git commit -m "Define secure Quick Connect pairing links"
```

---

### Task 2: Generate automatic pairing links and terminal QR codes on the Mac

**Files:**
- Create: `host/crates/openpaw-host/src/pairing_link.rs`
- Modify: `host/crates/openpaw-host/src/lib.rs`
- Modify: `host/crates/openpaw-host/src/main.rs:88-139,231-303`
- Modify: `host/crates/openpaw-host/src/api/tailscale.rs`
- Modify: `host/crates/openpaw-host/Cargo.toml`
- Modify: `Cargo.lock`
- Modify: `README.md:83-92`
- Modify: `host/crates/openpaw-host/contrib/README.md:126-150`

**Step 1: Write failing Rust unit tests**

Test pure helpers before touching CLI output:

- explicit `--ssh-host/--ssh-user/--ssh-port` overrides win;
- without overrides, a bounded fixed `tailscale status --json` result uses `Self.DNSName`, then `Self.TailscaleIPs`;
- without Tailscale, a bounded fixed hostname probe is used;
- username comes from an explicit option, then a validated local account name;
- invalid usernames, hostnames, ports, control characters, unbounded command output, and credentials embedded in a host are rejected;
- `/etc/ssh/ssh_host_ed25519_key.pub`-style public-key input produces the standard `SHA256:<base64-without-padding>` fingerprint without retaining key bytes in output;
- the envelope contains the daemon-issued pairing code but not the hook token;
- terminal QR rendering and link rendering describe the same exact envelope;
- code-only output remains byte-for-byte compatible with `pairing-code | pbcopy`.

**Step 2: Run RED**

```bash
cargo test -p openpaw-host pairing_link -- --nocapture
```

Expected: fails because the module and helpers do not exist.

**Step 3: Implement bounded local metadata discovery**

Add a public parser in `api/tailscale.rs` for the local `Self` node without changing the existing peer-list response. Reuse `ProcessTailscaleStatusRunner`, its timeout, output cap, fixed argv, and typed errors.

In `pairing_link.rs`, implement:

- `PairingLinkOptions`;
- `PairingEnvelopeV1` with serde names matching Swift;
- explicit target validation and ordering;
- fixed, bounded fallback hostname discovery;
- validated account-name discovery;
- optional parsing of public SSH host-key files and SHA-256 fingerprints;
- compact JSON plus base64url URL-fragment encoding;
- terminal QR rendering through a narrowly pinned Rust QR dependency with no image or network feature.

Do not sign the envelope with a new ad hoc identity. The security properties are physical display/link provenance, explicit target/fingerprint confirmation, SSH host-key verification, and the existing single-use pairing code.

**Step 4: Extend CLI without breaking code-only automation**

Support:

```bash
openpaw-host pair --name "Daniel's iPhone" --qr
openpaw-host pairing-code --qr
```

Add optional overrides:

```text
--ssh-host
--ssh-user
--ssh-port
--host-key-public-file
```

Default output remains the existing code-only stdout. With `--qr`, print the QR and readable metadata to stderr and the `openpaw://pair#...` link to stdout so it can be piped or copied. Add `--format code|link|json` only if needed to keep tests and scripting unambiguous. Never print the hook token.

**Step 5: Verify Rust and CLI behavior**

```bash
cargo test -p openpaw-host pairing_link
cargo test -p openpaw-host
cargo build -p openpaw-host --release
```

Start a disposable daemon state directory, issue a QR link, decode its fragment with a test helper, and verify the code expires and remains single use through the real `/v1/pair` endpoint.

Expected: all tests pass and the release binary builds.

**Step 6: Update operator documentation and commit**

Document the default automatic target discovery, override flags, QR contents, five-minute expiry, and explicit SSH confirmation.

```bash
git add host/crates/openpaw-host Cargo.lock README.md
git commit -m "Generate local Quick Connect QR links"
```

---

### Task 3: Add a real SSH credential confirmation and storage seam

**Files:**
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/QuickConnect.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/QuickConnectTests.swift`
- Modify: `apps/ios/OpenPawApp/OpenPawApp.swift:300-455`
- Modify: `apps/ios/OpenPawAppTests/BiometricGateTests.swift`

**Step 1: Write failing credential-selection tests**

Require:

- an existing host with the same normalized target preselects its exact `AuthMethod` and device-local profile;
- a different host or username never leaks its credential into the proposal;
- a preselected credential still reports `requiresExplicitConfirmation == true`;
- a new password/private-key draft carries secret material only in ephemeral view state and converts to an `AuthMethod` containing a new `KeychainReference`;
- cancelling or failing storage leaves `HostStore` unchanged;
- `QuickConnectProposal`, its encoded link, debug descriptions, and errors never contain the entered secret;
- saving a private key requests user-presence protection, while password storage remains `WhenUnlockedThisDeviceOnly` without exporting it.

**Step 2: Run RED**

```bash
swift test --package-path packages/swift-openpaw-ui --filter QuickConnectTests
```

Expected: fails on missing credential confirmation types.

**Step 3: Add the UI-package seam**

Define pure/sendable values:

```swift
public enum QuickConnectCredentialChoice: Sendable, Hashable {
    case existing(AuthMethod)
    case password(label: String, secret: String)
    case privateKey(label: String, key: Data, passphraseLabel: String?, passphrase: String?)
}

public protocol QuickConnectCredentialInstalling: Sendable {
    func install(_ choice: QuickConnectCredentialChoice) async throws -> AuthMethod
}
```

Keep all secret-bearing values out of `Codable`, `CustomStringConvertible`, and persistent proposal state. Add a redacted error vocabulary.

**Step 4: Implement the app-owned Keychain adapter in the existing app file**

In `OpenPawApp.swift`, add a small adapter around the already-created `KeychainStore(service: "dev.openpaw.app.ssh")`:

- validate bounded labels;
- create `KeychainReference`s;
- store passwords and private keys through `KeychainStore.store`;
- protect private keys with `requireBiometry: true`;
- clean up newly written items if a later write in the same credential transaction fails;
- return only `AuthMethod` references to the UI/model layer.

Inject the adapter into `RootView`. Do not create a new Xcode source file for this task, so the existing user `project.pbxproj` diff remains untouched.

**Step 5: Verify and commit**

```bash
swift test --package-path packages/swift-openpaw-ui --filter QuickConnectTests
DESTINATION="$(python3 scripts/ios-test-destination.py)"
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$DESTINATION" \
  -only-testing:OpenPawAppTests/BiometricGateTests
```

Expected: focused Swift and app tests pass.

```bash
git add packages/swift-openpaw-ui apps/ios/OpenPawApp/OpenPawApp.swift \
  apps/ios/OpenPawAppTests/BiometricGateTests.swift
git commit -m "Confirm and store Quick Connect SSH credentials"
```

---

### Task 4: Build the generation-owned automatic connection and pairing coordinator

**Files:**
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Backend/OpenPawBackend.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Model/OpenPawModel.swift:199-241,1221-1417`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Models/QuickConnect.swift`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/QuickConnectTests.swift`
- Modify: `apps/ios/OpenPawApp/HostAPIBackend.swift:103-144`
- Modify: `apps/ios/OpenPawAppTests/HostAPIBackendTests.swift`

**Step 1: Write failing coordinator tests**

Use recording terminal, lifecycle, pairer, credential installer, and suspended gates. Cover:

- no host or Keychain mutation occurs before explicit confirmation;
- confirmation installs the credential, upserts/selects exactly one host, records its profile, and starts SSH;
- the SSH target used is the one displayed at confirmation time;
- a pairing proposal connects the structured lifecycle without refreshing protected endpoints, redeems the code, then refreshes host state;
- pairing code is sent exactly once and the returned signer is saved by `HostAPIBackend`;
- a proposal without pairing code reaches Terminal over plain SSH and reports structured pairing as unavailable without failing the terminal;
- an unknown host key pauses in `.awaitingHostTrust`; after the existing trust action, resume continues the same owned request;
- changed host key fails and never pairs;
- expired code before confirmation fails without connecting;
- code expiry after SSH succeeds preserves the saved SSH host and Terminal connection;
- a newer proposal, host switch, reconnect, cancellation, or ABA switch makes all older completions stale;
- pairing/refresh errors never route back to Add Device;
- success returns a current `HostConnectionLease` and a terminal route intent.

**Step 2: Run RED**

```bash
swift test --package-path packages/swift-openpaw-ui --filter QuickConnectTests
```

Expected: fails because the pairer protocol, connect mode, and coordinator do not exist.

**Step 3: Add a narrow pairing capability**

In `OpenPawBackend.swift` define:

```swift
public protocol OpenPawHostPairing: Sendable {
    @discardableResult
    func pair(pairingCode: String, deviceName: String) async throws -> PairingResult
}
```

Make `HostAPIBackend` conform using its existing implementation. Do not add pairing to every preview backend or to the broad `OpenPawBackend` requirements.

**Step 4: Separate SSH connection from protected refresh**

Change the model API to an explicit mode rather than a boolean with unclear call sites:

```swift
public enum HostConnectPurpose: Sendable, Hashable {
    case normal
    case awaitingPairing
}

public func connectSelectedHost(for purpose: HostConnectPurpose = .normal) async -> HostConnectionLease?
```

For `.awaitingPairing`, establish Terminal and the structured lifecycle, mark the lifecycle ready, but do not call protected session/inbox/repo endpoints until pairing succeeds. Preserve all existing ownership checks.

Add a model method that pairs only when the supplied connection lease is still current, then refreshes structured state. It must reject stale leases before and after the async pair call.

**Step 5: Implement `QuickConnectCoordinator`**

Make it `@MainActor @Observable` and expose typed stages:

```text
reviewing
installingCredential
savingHost
connectingSSH
awaitingHostTrust
openingHostAPI
pairing
loadingWorkspace
connected
failed(stage, message)
cancelled
```

The coordinator owns a monotonically increasing generation and current task. It must provide `begin`, `confirm`, `resumeAfterHostTrust`, and `cancel`. It never stores raw secrets after credential installation returns.

**Step 6: Verify focused tests**

```bash
swift test --package-path packages/swift-openpaw-ui --filter QuickConnectTests
DESTINATION="$(python3 scripts/ios-test-destination.py)"
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$DESTINATION" \
  -only-testing:OpenPawAppTests/HostAPIBackendTests
```

Expected: all focused tests pass.

**Step 7: Commit**

```bash
git add packages/swift-openpaw-ui apps/ios/OpenPawApp/HostAPIBackend.swift \
  apps/ios/OpenPawAppTests/HostAPIBackendTests.swift
git commit -m "Coordinate automatic Quick Connect pairing"
```

---

### Task 5: Replace Home candidate onboarding with Quick Connect

**Files:**
- Create: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/QuickConnectView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/WorkspaceHomeView.swift:31-88,160-239`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift:346-405,545-560,965-1025,1342-1405`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/TailscaleOnboardingTests.swift:84-137`
- Modify: `packages/swift-openpaw-ui/Tests/OpenPawUITests/ShellTests.swift`
- Modify: `tools/openpaw-snapshot/Sources/openpaw-snapshot/ScreenCatalog.swift`

**Step 1: Replace the incorrect test contract with failing navigation tests**

The existing test named “Tapping a Home Tailnet device opens that candidate directly for review” currently proves the wrong behavior. Replace it with assertions that:

- a candidate maps to `QuickConnectProposal`;
- tapping it invokes `onQuickConnect` with that proposal;
- `AddDeviceFlowState` is not constructed and `isAdding` remains false;
- the proposal starts on credential review, not candidate confirmation;
- the primary action is **Confirm SSH credential and connect**;
- Add Device remains reachable only through the explicit add-another/manual action.

Add RootView tests that host-key sheets outrank Quick Connect, Quick Connect outranks approvals while active, and successful completion routes `.terminal`.

**Step 2: Run RED**

```bash
swift test --package-path packages/swift-openpaw-ui --filter TailscaleOnboardingTests
swift test --package-path packages/swift-openpaw-ui --filter QuickConnectTests
```

Expected: fails because Home still sets `isAdding` and opens `AddDeviceFlow`.

**Step 3: Implement the screen**

`QuickConnectView` shows:

- `Quick Connect to <name>`;
- target, username, port, online/source metadata;
- fingerprint or “Verify on first connection”;
- requested OpenPaw profile and pairing expiry;
- credential type/reference or secure import fields;
- a Change action;
- progress stages and exact failure copy;
- one primary confirmation action;
- Cancel/Retry without returning to Add Device.

Use accessibility identifiers for the proposal, target, credential selector, primary action, progress stage, and failure stage. Never expose secret values through accessibility.

**Step 4: Move sheet ownership to RootView**

Add `.quickConnect` to `ShellSheet` and keep safety order:

1. host-key decision;
2. active Quick Connect;
3. approval;
4. requested Add Device/manage-hosts sheets.

`WorkspaceHomeView` receives an `onQuickConnect` closure. Candidate rows call it directly. RootView owns the coordinator, presents `QuickConnectView`, resumes it after host trust, and routes to Terminal on success. The explicit add-device button still opens `AddDeviceFlow`.

**Step 5: Add snapshots for reviewing, connecting, awaiting host trust, expired, and connected states**

Use deterministic proposals with no secrets. Build and render the snapshot tool.

**Step 6: Verify and commit**

```bash
swift test --package-path packages/swift-openpaw-ui --filter TailscaleOnboardingTests
swift test --package-path packages/swift-openpaw-ui --filter QuickConnectTests
swift build --package-path tools/openpaw-snapshot -c release
SNAPSHOT_OUTPUT_DIR="$JCODE_SCRATCH_DIR/openpaw-quick-connect-snapshots" \
  tools/openpaw-snapshot/.build/release/openpaw-snapshot
```

Expected: focused suites pass; snapshot render reports zero failed and zero blank.

```bash
git add packages/swift-openpaw-ui tools/openpaw-snapshot
git commit -m "Open Tailnet devices in Quick Connect"
```

---

### Task 6: Route pairing links and add native QR scanning

**Files:**
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/QuickConnectView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/WorkspaceHomeView.swift`
- Modify: `packages/swift-openpaw-ui/Sources/OpenPawUI/Screens/RootView.swift`
- Modify: `apps/ios/OpenPawApp/OpenPawApp.swift:27-115,240-289`
- Modify: `apps/ios/OpenPawApp/Info.plist:67-82`
- Modify: `apps/ios/OpenPawAppTests/BiometricGateTests.swift`

**Step 1: Write failing app URL and scanner-policy tests**

Require:

- `openpaw://inbox/...` behavior remains unchanged;
- `openpaw://pair#v1...` decodes and queues one Quick Connect proposal;
- locked receipt does not bypass the biometric gate;
- a denied/invalid pairing URL cannot open after a later unlock;
- the newest valid pairing link supersedes an older pending link;
- non-OpenPaw QR data and ordinary web links are rejected without opening a browser;
- scanner output reaches the same `receiveOpenPawURL` path as an external link;
- scanner cancellation leaves current navigation untouched.

**Step 2: Run RED**

```bash
DESTINATION="$(python3 scripts/ios-test-destination.py)"
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$DESTINATION" \
  -only-testing:OpenPawAppTests/BiometricGateTests
```

Expected: fails because AppWiring only handles Inbox URLs.

**Step 3: Generalize URL dispatch**

Replace `receiveInboxURL` at the `.onOpenURL` boundary with `receiveOpenPawURL` that parses strictly in this order:

1. `InboxRoute`;
2. `QuickConnectLinkCodec`;
3. reject.

Keep separate pending state and cancellation for Inbox and Quick Connect so one route type cannot accidentally clear or replay the other. Deliver a Quick Connect proposal through a new public `RootView.openQuickConnect(_:)` method only after the gate is unlocked.

**Step 4: Add native scanner UI**

Under `#if os(iOS) && canImport(VisionKit)`, wrap `DataScannerViewController` for QR/barcode text. The scanner:

- accepts one recognized payload at a time;
- immediately pauses after a valid OpenPaw payload;
- rejects non-OpenPaw content in place;
- stops its capture session on dismissal/background;
- has a manual paste-link fallback;
- does not exist as an active camera surface on macOS or unsupported devices.

Add **Scan pairing QR** to Home and Add Device entry UI, both feeding the same URL dispatcher.

Update `NSCameraUsageDescription` to state that the camera may scan a pairing QR or capture an attachment.

**Step 5: Verify and commit**

```bash
DESTINATION="$(python3 scripts/ios-test-destination.py)"
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$DESTINATION" \
  -only-testing:OpenPawAppTests/BiometricGateTests
swift test --package-path packages/swift-openpaw-ui --filter QuickConnectTests
```

Expected: focused tests pass.

```bash
git add packages/swift-openpaw-ui apps/ios/OpenPawApp/OpenPawApp.swift \
  apps/ios/OpenPawApp/Info.plist apps/ios/OpenPawAppTests/BiometricGateTests.swift
git commit -m "Open Quick Connect from QR pairing links"
```

---

### Task 7: Add deterministic simulator acceptance for the reported MacBook Pro path

**Files:**
- Modify: `apps/ios/OpenPawApp/DebugScenario.swift`
- Modify: `apps/ios/OpenPawUITests/ConnectFlowUITests.swift`
- Modify: `apps/ios/OpenPawUITests/ScenarioLaunchUITests.swift`

**Step 1: Write the failing XCUITest first**

Add a deterministic `quickPairing` scenario that exposes a visible online Tailnet candidate named **MacBook Pro**, a preselected test credential label, a fake host-key fingerprint, and a recording pairer/terminal that can finish without network access.

The test must:

1. Launch Home.
2. Wait for the **MacBook Pro** candidate.
3. Tap it.
4. Assert `Quick Connect to MacBook Pro` exists.
5. Assert `Add a device`, `Tailscale devices`, and `Authorize with Tailnet administrator credentials` do not exist.
6. Assert the target, username, credential label, fingerprint, profile, and confirmation button are visible.
7. Tap **Confirm SSH credential and connect**.
8. Assert ordered progress reaches SSH, pairing, and workspace loading.
9. Assert `root.destination.terminal` becomes selected and the terminal surface exists.
10. Relaunch or open a second proposal and prove stale completion from the first cannot route or overwrite the host.

Add a second test that launches the same proposal through an `openpaw://pair#...` URL rather than tapping the row.

**Step 2: Run RED**

```bash
DESTINATION="$(python3 scripts/ios-test-destination.py)"
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$DESTINATION" \
  -only-testing:OpenPawUITests/ConnectFlowUITests/testMacBookProCandidateQuickConnectsToTerminal
```

Expected: fails on the current Add Device screen.

**Step 3: Implement only deterministic DEBUG+simulator fixtures**

Extend the existing `DebugScenario.swift`; do not create a new Xcode source file. Keep every fixture fenced with both `#if DEBUG` and `targetEnvironment(simulator)`. The fake pairing backend records the code and returns success but contains no persistent token or secret literal.

**Step 4: Run GREEN and neighboring UI tests**

```bash
DESTINATION="$(python3 scripts/ios-test-destination.py)"
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$DESTINATION" \
  -only-testing:OpenPawUITests/ConnectFlowUITests \
  -only-testing:OpenPawUITests/ScenarioLaunchUITests
```

Expected: all selected UI tests pass.

**Step 5: Commit**

```bash
git add apps/ios/OpenPawApp/DebugScenario.swift \
  apps/ios/OpenPawUITests/ConnectFlowUITests.swift \
  apps/ios/OpenPawUITests/ScenarioLaunchUITests.swift
git commit -m "Verify MacBook Pro Quick Connect navigation"
```

---

### Task 8: Prove the real host, real SSH, and real pairing workflow

**Files:**
- Create: `scripts/quick-pairing-live.py`
- Create: `scripts/tests/test_quick_pairing_live.py`
- Modify: `scripts/check.sh`
- Modify: `README.md`
- Modify: `docs/handoff.md`

**Step 1: Write failing harness contract tests**

Require the harness to:

- dynamically select an installed iOS simulator;
- start a disposable user-level SSH daemon and a disposable `openpaw-host` state directory;
- generate a real private key outside the repository and import it only through the app's credential path;
- start the host daemon, issue a real QR/link, and open it with `simctl openurl`;
- never print the private key, hook token, pairing code, returned bearer token, or HMAC key to the console;
- drive the UI confirmation and host-key trust steps;
- assert a real SSH connection, real `/v1/pair` redemption, real signer persistence, and Terminal navigation;
- attempt replay of the consumed code and assert rejection;
- clean up child processes and scratch state on success, failure, and signal.

**Step 2: Run RED**

```bash
python3 -m unittest scripts/tests/test_quick_pairing_live.py
```

Expected: fails because the harness does not exist.

**Step 3: Implement the live harness**

Reuse patterns from the existing live SSH and dictation harnesses. Put all disposable files under `$JCODE_SCRATCH_DIR`, not `/tmp`. Use the dynamic destination helper and existing build products when available. Redact secrets from subprocess output before writing logs.

**Step 4: Run focused live acceptance**

```bash
python3 scripts/quick-pairing-live.py
```

Expected final evidence:

```text
real SSH connected
real pairing redeemed once
signer persisted for the selected host
Terminal selected
pairing-code replay rejected
```

A simulator-only fake does not satisfy this step. If the environment blocks camera injection, opening the exact generated `openpaw://` link with `simctl openurl` is acceptance-aligned for parsing/routing; separately scan the rendered QR on a physical iPhone before release.

**Step 5: Add the safe contract test to `scripts/check.sh` and commit**

Do not add the environment-dependent live run to default CI.

```bash
git add scripts README.md docs/handoff.md
git commit -m "Add live Quick Connect acceptance harness"
```

---

### Task 9: Run the complete regression and release-facing acceptance matrix

**Files:**
- Modify only files required by failures found in this task.

**Step 1: Verify formatting and source hygiene**

```bash
git diff --check
python3 scripts/validate-pbxproj-diff.py --staged
```

Expected: no whitespace errors; no staged `project.pbxproj` changes. The user's existing unstaged project-file change remains untouched.

**Step 2: Run all Swift/Rust unit suites**

```bash
swift test --package-path packages/swift-openpaw-ui
swift test --package-path packages/swift-agent-protocol
swift test --package-path packages/swift-terminal-core
swift test --package-path packages/swift-ssh-transport
cargo test -p openpaw-host
```

Expected: zero failures.

**Step 3: Build and render release snapshots**

```bash
swift build --package-path tools/openpaw-snapshot -c release
SNAPSHOT_OUTPUT_DIR="$JCODE_SCRATCH_DIR/openpaw-quick-connect-final" \
  tools/openpaw-snapshot/.build/release/openpaw-snapshot
```

Expected: zero failed and zero blank snapshots.

**Step 4: Run focused app and UI acceptance**

```bash
DESTINATION="$(python3 scripts/ios-test-destination.py)"
xcodebuild test -project apps/ios/OpenPaw.xcodeproj -scheme OpenPaw \
  -destination "$DESTINATION" \
  -only-testing:OpenPawAppTests/HostAPIBackendTests \
  -only-testing:OpenPawAppTests/BiometricGateTests \
  -only-testing:OpenPawUITests/ConnectFlowUITests \
  -only-testing:OpenPawUITests/ScenarioLaunchUITests
```

Expected: zero failures. Read the `.xcresult`; do not infer success from build output alone.

**Step 5: Run the live harness and repository check**

```bash
python3 scripts/quick-pairing-live.py
bash scripts/check.sh
```

Expected: live acceptance evidence appears and repository checks pass.

**Step 6: Physical iPhone acceptance before a shipping claim**

On an iPhone with Tailscale active:

1. Run `openpaw-host pair --qr` on the Mac.
2. Scan the QR using OpenPaw.
3. Confirm the displayed target, host fingerprint, profile, and SSH credential.
4. Trust an unknown host key only after comparing the fingerprint.
5. Observe automatic SSH, pairing, Keychain persistence, and Terminal routing.
6. Relaunch and reconnect without rescanning.
7. Generate a second code and confirm the first consumed/expired code cannot be reused.
8. Tap the Home **MacBook Pro** Tailnet row and verify it opens Quick Connect, never Add Device.

Record device/runtime/app build and the observed result in `docs/handoff.md`. Simulator evidence alone is insufficient for the camera and physical Tailnet claim.

**Step 7: Final commit if verification required fixes**

Stage only files changed for verified regressions and commit one narrow follow-up. Finish with:

```bash
git status --short --branch
git log -10 --oneline
```

The only unrelated working-tree change should remain the user's existing `apps/ios/OpenPaw.xcodeproj/project.pbxproj` modification.
