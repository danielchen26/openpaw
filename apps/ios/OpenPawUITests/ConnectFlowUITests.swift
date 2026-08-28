import XCTest

/// Drives the app the way a person does: launch, find the saved host, tap Connect, tap through the host-key sheet,
/// and read the result off the screen.
///
/// The unit suites substitute the transport and the live backend suite calls `SSHTerminalBackend` directly, so
/// neither one proves the button is wired to the connection at all. A Connect button that renders correctly but is
/// bound to nothing would pass every other test in this repo.
///
/// Requires a reachable host, a key on disk, and a matching saved host record in the app's store:
///
///     OPENPAW_LIVE_HOST=127.0.0.1 OPENPAW_LIVE_USER=you OPENPAW_LIVE_KEY=/path/to/key
///     OPENPAW_LIVE_NICKNAME=home
final class ConnectFlowUITests: XCTestCase {

    private let quickPairingTarget = "macbook-pro.tailnet.example"
    private let quickPairingUsername = "openpaw"
    private let quickPairingCredentialLabel = "MacBook Pro credential · Saved private key"
    private let quickPairingFingerprint = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private struct Target {
        var nickname: String
        var keyPath: String
    }

    private func target() throws -> Target {
        let environment = ProcessInfo.processInfo.environment
        guard let keyPath = environment["OPENPAW_LIVE_KEY"], environment["OPENPAW_LIVE_HOST"] != nil else {
            throw XCTSkip("set OPENPAW_LIVE_HOST/USER/KEY to run the connect flow UI test")
        }
        return Target(nickname: environment["OPENPAW_LIVE_NICKNAME"] ?? "home", keyPath: keyPath)
    }

    private func scenarioApp(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-openpaw-debug-scenario", scenario,
            "-openpaw.settings.biometricGate", "<false/>",
        ]
        app.launch()
        return app
    }

    private func pairingURL(
        nickname: String,
        target: String,
        sessionID: String,
        pairingCode: String
    ) throws -> URL {
        let issuedAt = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let envelope: [String: Any] = [
            "v": 1,
            "issued_at": formatter.string(from: issuedAt),
            "expires_at": formatter.string(from: issuedAt.addingTimeInterval(240)),
            "session_id": sessionID,
            "host_api_port": 8765,
            "profile": "operator",
            "pairing_code": pairingCode,
            "nickname": nickname,
            "username": quickPairingUsername,
            "targets": [["hostname": target, "port": 22, "source": "magic_dns"]],
            "host_keys": [["algorithm": "ssh-ed25519", "fingerprint": quickPairingFingerprint]],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let fragment = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try XCTUnwrap(URL(string: "openpaw://pair#v1.\(fragment)"))
    }

    private func openPairingURL(_ url: URL, app: XCUIApplication) {
        app.open(url)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), app.debugDescription)
    }

    private func assertQuickConnectReview(
        in app: XCUIApplication,
        nickname: String,
        target: String,
        fingerprint: String,
        profile: String
    ) {
        XCTAssertTrue(app.staticTexts["Quick Connect to \(nickname)"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["quick-connect.target"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", target)).firstMatch.exists)
        XCTAssertEqual(app.textFields["quick-connect.username"].value as? String, quickPairingUsername)
        XCTAssertTrue(app.staticTexts[quickPairingCredentialLabel].exists)
        XCTAssertTrue(app.staticTexts[fingerprint].exists)
        XCTAssertTrue(app.staticTexts[profile].exists)
        XCTAssertTrue(app.buttons["quick-connect.confirm"].exists)
        XCTAssertEqual(app.buttons["quick-connect.confirm"].label, "Confirm SSH credential and connect")
        XCTAssertFalse(app.staticTexts["Add a device"].exists)
        XCTAssertFalse(app.buttons["Tailscale devices"].exists)
        XCTAssertFalse(app.buttons["Authorize with Tailnet administrator credentials"].exists)
    }

    private func waitForProgress(_ label: String, in app: XCUIApplication, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        let issue = app.alerts["Session discovery issue"]
        while Date() < deadline {
            if app.staticTexts[label].exists { return }
            if issue.exists { issue.buttons["Dismiss"].tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("Timed out waiting for \(label). \(app.debugDescription)")
    }

    private func dismissSessionDiscoveryIssueIfPresent(in app: XCUIApplication) {
        let alert = app.alerts["Session discovery issue"]
        if alert.exists { alert.buttons["Dismiss"].tap() }
    }

    private func assertTerminalDestination(in app: XCUIApplication) {
        let pager = app.otherElements["root.destination.pager"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, pager.value as? String != "Terminal" {
            dismissSessionDiscoveryIssueIfPresent(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(pager.value as? String, "Terminal", app.debugDescription)
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }

    func testMacBookProCandidateQuickConnectsToTerminal() {
        let app = scenarioApp("quickPairing")

        let candidate = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "MacBook Pro,")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 15), app.debugDescription)
        candidate.tap()

        assertQuickConnectReview(
            in: app,
            nickname: "MacBook Pro",
            target: quickPairingTarget,
            fingerprint: "Verify on first connection",
            profile: "SSH only")

        app.buttons["quick-connect.confirm"].tap()
        waitForProgress("Connecting SSH", in: app)
        waitForProgress("Loading workspace", in: app)

        assertTerminalDestination(in: app)
    }

    func testPairingURLUsesDispatcherAndPairsBeforeOpeningTerminal() throws {
        let app = scenarioApp("quickPairing")
        let url = try pairingURL(
            nickname: "MacBook Pro",
            target: quickPairingTarget,
            sessionID: "ses_0123456789abcdef01234567",
            pairingCode: "ABCD-EFGH-IJKL-MNOP-QRST-UVWX")

        openPairingURL(url, app: app)
        assertQuickConnectReview(
            in: app,
            nickname: "MacBook Pro",
            target: quickPairingTarget,
            fingerprint: quickPairingFingerprint,
            profile: "Operator")

        app.buttons["quick-connect.confirm"].tap()
        waitForProgress("Connecting SSH", in: app)
        waitForProgress("Pairing device", in: app)
        waitForProgress("Loading workspace", in: app)

        assertTerminalDestination(in: app)
    }

    func testDelayedFirstPairingURLCannotRouteOrOverwriteSecondProposal() throws {
        let app = scenarioApp("quickPairing")
        let first = try pairingURL(
            nickname: "Delayed Mac",
            target: quickPairingTarget,
            sessionID: "ses_111111111111111111111111",
            pairingCode: "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF")
        let second = try pairingURL(
            nickname: "MacBook Pro",
            target: quickPairingTarget,
            sessionID: "ses_222222222222222222222222",
            pairingCode: "GGGG-HHHH-IIII-JJJJ-KKKK-LLLL")

        openPairingURL(first, app: app)
        XCTAssertTrue(app.staticTexts["Quick Connect to Delayed Mac"].waitForExistence(timeout: 10))
        app.buttons["quick-connect.confirm"].tap()
        waitForProgress("Connecting SSH", in: app)

        openPairingURL(second, app: app)
        assertQuickConnectReview(
            in: app,
            nickname: "MacBook Pro",
            target: quickPairingTarget,
            fingerprint: quickPairingFingerprint,
            profile: "Operator")

        Thread.sleep(forTimeInterval: 7)
        XCTAssertTrue(app.staticTexts["Quick Connect to MacBook Pro"].exists, app.debugDescription)
        XCTAssertNotEqual(app.otherElements["root.destination.pager"].value as? String, "Terminal")

        app.buttons["quick-connect.confirm"].tap()
        waitForProgress("Connecting SSH", in: app)
        waitForProgress("Pairing device", in: app)
        waitForProgress("Loading workspace", in: app)
        assertTerminalDestination(in: app)
    }

    func testAddDeviceAutomaticallyLoadsPairedHostCandidatesWithTruthfulProvenance() {
        let app = scenarioApp("connectedWorkspace")

        let add = app.buttons["Add a Tailscale or SSH device"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()

        XCTAssertTrue(app.buttons["Tailscale devices"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Enter SSH details manually"].exists)
        // The administrator connector is a candidate source, not a fourth front door, so the welcome screen no longer
        // offers it beside the destination it merely feeds.
        XCTAssertFalse(app.buttons["Authorize with Tailnet administrator credentials"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sign in with Tailscale")).firstMatch.exists)

        app.buttons["Tailscale devices"].tap()
        XCTAssertTrue(app.buttons["Authorize with Tailnet administrator credentials"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["A VPN route compatible with Tailscale was detected. This is a connectivity hint, not account access."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["addDevice.tailscale.provenance"].waitForExistence(timeout: 5))
        let candidates = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "not trusted or saved"))
        let candidate = candidates.element(boundBy: max(0, candidates.count - 1))
        XCTAssertTrue(candidate.waitForExistence(timeout: 5), app.debugDescription)
        let scrollViews = app.scrollViews
        let sheetScrollView = scrollViews.element(boundBy: max(0, scrollViews.count - 1))
        for _ in 0..<8 where !candidate.isHittable { sheetScrollView.swipeUp() }
        XCTAssertTrue(candidate.isHittable, app.debugDescription)
        candidate.tap()
        XCTAssertTrue(app.staticTexts["Review before this becomes a host"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Confirm candidate and review SSH details"].exists)
    }

    func testAdvancedAdministratorCandidateRequiresConfirmationAndRunsTypedPreflight() {
        let app = scenarioApp("connectedWorkspace")
        let add = app.buttons["Add a Tailscale or SSH device"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        app.buttons["Tailscale devices"].tap()
        let admin = app.buttons["Authorize with Tailnet administrator credentials"]
        XCTAssertTrue(admin.waitForExistence(timeout: 5), app.debugDescription)
        // The connector now sits under the candidate list it feeds, so it can start below the fold.
        let scrollViews = app.scrollViews
        let sheetScrollView = scrollViews.element(boundBy: max(0, scrollViews.count - 1))
        for _ in 0..<8 where !admin.isHittable { sheetScrollView.swipeUp() }
        XCTAssertTrue(admin.isHittable, app.debugDescription)
        admin.tap()

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Tailnet administrator credentials required")).firstMatch.waitForExistence(timeout: 5))
        app.textFields["addDevice.tailscaleAdmin.clientID"].tap()
        app.textFields["addDevice.tailscaleAdmin.clientID"].typeText("client-id")
        app.secureTextFields["addDevice.tailscaleAdmin.clientSecret"].tap()
        app.secureTextFields["addDevice.tailscaleAdmin.clientSecret"].typeText("fixture-secret")
        app.textFields["addDevice.tailscaleAdmin.tailnet"].tap()
        app.textFields["addDevice.tailscaleAdmin.tailnet"].typeText("example.ts.net")
        app.buttons["addDevice.tailscaleAdmin.connect"].tap()

        let candidate = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "admin-mac.example.ts.net")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5), app.debugDescription)
        candidate.tap()
        XCTAssertTrue(app.staticTexts["Review before this becomes a host"].waitForExistence(timeout: 5))
        app.buttons["Confirm candidate and review SSH details"].tap()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        username.tap()
        username.typeText("openpaw")
        let preflight = app.buttons["connection.preflight.run"]
        for _ in 0..<5 where !preflight.isHittable { app.swipeUp() }
        XCTAssertTrue(preflight.isHittable, app.debugDescription)
        preflight.tap()
        XCTAssertTrue(app.descendants(matching: .any)["connection.preflight.stage.route"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["connection.preflight.stage.transportCapabilities"].exists)
        XCTAssertFalse(app.buttons["Mosh"].exists)
        XCTAssertFalse(app.buttons["Eternal Terminal"].exists)
    }

    func testActiveRouteWithoutHostExplainsAccountBoundaryAndKeepsManualSSHUsable() {
        let app = scenarioApp("noHosts")
        let add = app.buttons["Add a Tailscale or SSH device"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        app.buttons["Tailscale devices"].tap()

        XCTAssertTrue(app.staticTexts["A Tailscale-compatible route may be active"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "VPN-style route that may be Tailscale")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "iOS does not share the signed-in Tailscale account or device list with OpenPaw")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Automatic discovery will stay host-mediated")).firstMatch.exists)
        XCTAssertTrue(app.buttons["Authorize with Tailnet administrator credentials"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sign in with Tailscale")).firstMatch.exists)
        app.buttons["Enter SSH details manually"].tap()
        XCTAssertTrue(app.textFields["Hostname"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["SSH"].exists)
        XCTAssertFalse(app.buttons["Mosh"].exists)
        XCTAssertFalse(app.buttons["Eternal Terminal"].exists)
    }

    /// The state of every real install: a host record exists, but its key was never imported, because the app has no
    /// screen that imports one. Tapping Connect here must explain itself on screen.
    ///
    /// Written after the app vanished on a manual tap. Whatever the cause, "the app is gone and the user is back on
    /// the springboard" is the one outcome this flow must never produce.
    func testTappingConnectWithoutAKeyStaysOnScreen() throws {
        let target = try target()

        let app = XCUIApplication()
        app.launchArguments = ["-openpaw.settings.biometricGate", "<false/>"]
        app.launch()

        let connect = app.buttons["Connect to \(target.nickname)"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15), "Connect button never appeared")
        connect.tap()

        // Give the connection attempt time to fail and unwind.
        Thread.sleep(forTimeInterval: 8)

        // The app must still be frontmost. A crash shows up here as `.notRunning`.
        XCTAssertEqual(app.state, .runningForeground, "the app left the foreground after tapping Connect")
        XCTAssertTrue(connect.exists || app.buttons["Resume \(target.nickname)"].exists,
            "the device card disappeared after tapping Connect")
    }

    func testTappingConnectReachesTheHost() throws {
        let target = try target()

        let app = XCUIApplication()
        app.launchArguments = ["-openpaw-debug-seed-key", target.keyPath]
        // The gate would otherwise sit on a biometric prompt no automation can answer. This is the same key the
        // Settings toggle writes, so the test turns the feature off the way a user would rather than bypassing it.
        //
        // The value must be a plist literal: the argument domain parses `-key NO` as the *string* "NO", which the
        // gate's `object(forKey:) as? Bool` correctly refuses, leaving the lock on and the test stuck.
        app.launchArguments += ["-openpaw.settings.biometricGate", "<false/>"]
        app.launch()

        let connect = app.buttons["Connect to \(target.nickname)"]
        XCTAssertTrue(
            connect.waitForExistence(timeout: 15),
            "Connect button for \(target.nickname) never appeared. On screen:\n\(app.debugDescription)"
        )
        connect.tap()

        // First connection to an unpinned host raises the trust sheet. Tapping it is part of the flow under test:
        // a user reaching their machine for the first time has to get through this screen.
        let trust = app.buttons["Trust this host key and continue connecting"]
        if trust.waitForExistence(timeout: 10) {
            trust.tap()
        }

        // Once connected, the card offers to resume the session instead of opening one, so this label is the
        // screen's own claim that the connection succeeded. Asserting on the UI, not the backend, is the point.
        let resume = app.buttons["Resume \(target.nickname)"]
        XCTAssertTrue(
            resume.waitForExistence(timeout: 45),
            "never reached a connected state for \(target.nickname). On screen:\n\(app.debugDescription)"
        )
    }
}
