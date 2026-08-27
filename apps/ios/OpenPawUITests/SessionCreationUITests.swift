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

    private struct Target {
        var nickname: String
        var hostname: String
        var port: String
        var username: String
        var keyPath: String
        var keyReference: String { (keyPath as NSString).lastPathComponent }
    }

    private func target() throws -> Target {
        let environment = ProcessInfo.processInfo.environment
        guard let hostname = environment["OPENPAW_LIVE_HOST"],
              let username = environment["OPENPAW_LIVE_USER"],
              let keyPath = environment["OPENPAW_LIVE_KEY"] else {
            throw XCTSkip("set OPENPAW_LIVE_HOST/USER/KEY to run the session creation UI test")
        }
        return Target(
            nickname: environment["OPENPAW_LIVE_NICKNAME"] ?? "home",
            hostname: hostname,
            port: environment["OPENPAW_LIVE_PORT"] ?? "22",
            username: username,
            keyPath: keyPath)
    }

    private func launchConnected() throws -> (XCUIApplication, String) {
        let target = try target()

        let app = XCUIApplication()
        app.launchArguments = ["-openpaw-debug-seed-key", target.keyPath,
                               "-openpaw.settings.biometricGate", "<false/>"]
        app.launch()

        ensureSavedHost(target, in: app)
        let connect = app.buttons["Connect to \(target.nickname)"]
        XCTAssertTrue(
            connect.waitForExistence(timeout: 15),
            "Connect button never appeared. On screen:\n\(app.debugDescription)")
        connect.tap()
        let trust = app.buttons["Trust this host key and continue connecting"]
        if trust.waitForExistence(timeout: 10) { trust.tap() }
        XCTAssertTrue(
            app.buttons["Resume \(target.nickname)"].waitForExistence(timeout: 30),
            "never connected")
        return (app, target.nickname)
    }

    /// A live test must be self-contained. Requiring a manually populated simulator skips the only end-user session
    /// workflow in clean CI, so create the same private-key host a person would create when it is absent.
    private func ensureSavedHost(_ target: Target, in app: XCUIApplication) {
        if app.buttons["Connect to \(target.nickname)"].waitForExistence(timeout: 2) { return }

        let add = app.buttons["Add a Tailscale or SSH device"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "neither the saved host nor Add Device appeared")
        add.tap()
        let ssh = app.buttons["SSH / transport preference"]
        XCTAssertTrue(ssh.waitForExistence(timeout: 5))
        ssh.tap()

        replace(app.textFields["Nickname"], with: target.nickname)
        replace(app.textFields["Hostname"], with: target.hostname)
        replace(app.textFields["Port"], with: target.port)
        replace(app.textFields["Username"], with: target.username)

        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            keyboard.buttons["Return"].firstMatch.tap()
            XCTAssertFalse(
                keyboard.waitForExistence(timeout: 1),
                "the keyboard still covers the Authentication picker")
        }

        let privateKey = app.buttons["Private key"]
        XCTAssertTrue(privateKey.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(privateKey.isHittable, "the Private key segment is visible but not touchable")
        privateKey.press(forDuration: 0.1)
        XCTAssertTrue(privateKey.isSelected, "the Authentication picker did not select Private key")
        replace(app.textFields["Key entry"], with: target.keyReference)

        let save = app.buttons["Save"]
        XCTAssertTrue(save.exists)
        save.tap()
        XCTAssertTrue(
            app.buttons["Connect to \(target.nickname)"].waitForExistence(timeout: 10),
            "saved host did not appear")
    }

    private func replace(_ field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "missing field \(field.identifier)")
        field.tap()
        let old = field.value as? String ?? ""
        if !old.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(value)
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

        let commandFailure = app.alerts["Session command failed"]
        if commandFailure.waitForExistence(timeout: 5) {
            XCTFail("session creation failed before navigation:\n\(commandFailure.debugDescription)")
        }

        // Creation switches to Terminal. Return to Sessions with the root swipe, the same way a person does.
        XCTAssertTrue(
            app.buttons["Escape"].waitForExistence(timeout: 10),
            "session creation did not navigate to the interactive terminal")
        swipeRootBack(app)
        XCTAssertTrue(
            app.otherElements["root.destination.pager"].waitForExistence(timeout: 5),
            "the root pager disappeared after session creation")

        let created = app.buttons["Attach to \(name)"]
        for _ in 0..<10 where !created.exists {
            let refresh = app.buttons["Refresh"]
            if refresh.exists { refresh.tap() }
            for _ in 0..<8 where !created.exists { app.swipeUp() }
            Thread.sleep(forTimeInterval: 2)
        }
        XCTAssertTrue(created.exists, "created a session but it never appeared in the list")
    }

    /// One root fling from Terminal lands on Sessions: the destinations sit beside each other and the deck's
    /// tab buttons are gone.
    private func swipeRootBack(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.18))
            .press(
                forDuration: 0.05,
                thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.18)))
    }
}
