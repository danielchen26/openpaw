import XCTest

/// Drives session creation the way a person does: connect, open Sessions, type a name and tap Create.
///
/// Every layer below this passed while the feature was broken end to end. The adapter tests asserted commands that
/// no CLI has, and the field the user types into was not reachable at all, so only driving the real screen catches it.
///
///     OPENPAW_LIVE_HOST=127.0.0.1 OPENPAW_LIVE_USER=you OPENPAW_LIVE_KEY=/path/to/key
///     OPENPAW_LIVE_NICKNAME=home
final class SessionCreationUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchConnected() throws -> (XCUIApplication, String) {
        let environment = ProcessInfo.processInfo.environment
        guard let keyPath = environment["OPENPAW_LIVE_KEY"], environment["OPENPAW_LIVE_HOST"] != nil else {
            throw XCTSkip("set OPENPAW_LIVE_HOST/USER/KEY to run the session creation UI test")
        }
        let nickname = environment["OPENPAW_LIVE_NICKNAME"] ?? "home"

        let app = XCUIApplication()
        app.launchArguments = ["-openpaw-debug-seed-key", keyPath,
                               "-openpaw.settings.biometricGate", "<false/>"]
        app.launch()

        let connect = app.buttons["Connect to \(nickname)"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15), "Connect button never appeared")
        connect.tap()
        let trust = app.buttons["Trust this host key and continue connecting"]
        if trust.waitForExistence(timeout: 10) { trust.tap() }
        XCTAssertTrue(app.buttons["Resume \(nickname)"].waitForExistence(timeout: 30), "never connected")
        return (app, nickname)
    }

    /// The name field lives below however many sessions the host is running, so it is reached by scrolling. A field
    /// that the accessibility tree does not expose as a text field cannot be typed into by this test, by VoiceOver,
    /// or by any other assistive technology.
    func testTheNewSessionFieldCanBeTypedInto() throws {
        let (app, _) = try launchConnected()
        app.buttons["Sessions"].tap()

        let field = app.textFields["New session"]
        for _ in 0..<8 where !field.exists { app.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the New session field is not reachable")

        field.tap()
        field.typeText("frommyphone")
        XCTAssertEqual(field.value as? String, "frommyphone")

        let create = app.buttons["Create"]
        XCTAssertTrue(create.exists, "no Create button")
        XCTAssertTrue(create.isEnabled, "Create stayed disabled after typing a name")
    }

    /// Tapping Create must produce a session the user can see, not just send a command. The whole defect was a
    /// command that ran and changed nothing, so the assertion is on the resulting screen.
    func testCreatingASessionMakesOneAppear() throws {
        let (app, _) = try launchConnected()
        app.buttons["Sessions"].tap()

        let name = "openpaw-uitest"
        let field = app.textFields["New session"]
        for _ in 0..<8 where !field.exists { app.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the New session field is not reachable")
        field.tap()
        field.typeText(name)
        app.buttons["Create"].tap()

        // Creation switches to Terminal, so come back to the list and let discovery re-run.
        XCTAssertTrue(app.buttons["Sessions"].waitForExistence(timeout: 10))
        app.buttons["Sessions"].tap()

        let created = app.buttons["Attach to \(name)"]
        for _ in 0..<10 where !created.exists {
            let refresh = app.buttons["Refresh"]
            if refresh.exists { refresh.tap() }
            for _ in 0..<8 where !created.exists { app.swipeUp() }
            Thread.sleep(forTimeInterval: 2)
        }
        XCTAssertTrue(created.exists, "created a session but it never appeared in the list")
    }
}
