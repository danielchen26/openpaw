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

    func testAddDeviceAutomaticallyLoadsPairedHostCandidatesWithTruthfulProvenance() {
        let app = scenarioApp("connectedWorkspace")

        let add = app.buttons["Add a Tailscale or SSH device"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()

        XCTAssertTrue(app.buttons["Tailscale devices"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["SSH / transport preference"].exists)
        XCTAssertTrue(app.buttons["Advanced Tailscale connector"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sign in with Tailscale")).firstMatch.exists)

        app.buttons["Tailscale devices"].tap()
        XCTAssertTrue(app.staticTexts["Tailscale route detected. This is a connectivity hint, not account access."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["addDevice.tailscale.provenance"].waitForExistence(timeout: 5))
        let candidate = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "not trusted or saved")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5), app.debugDescription)
        candidate.tap()
        XCTAssertTrue(app.staticTexts["Review before this becomes a host"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Confirm candidate and review SSH details"].exists)
    }

    func testAdvancedAdministratorCandidateRequiresConfirmationAndRunsTypedPreflight() {
        let app = scenarioApp("connectedWorkspace")
        let add = app.buttons["Add a Tailscale or SSH device"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        app.buttons["Advanced Tailscale connector"].tap()

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

    func testNoHostStateKeepsManualSSHUsable() {
        let app = scenarioApp("noHosts")
        let add = app.buttons["Add a Tailscale or SSH device"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        app.buttons["Tailscale devices"].tap()

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No connected discovery host")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["SSH / transport preference"].tap()
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
