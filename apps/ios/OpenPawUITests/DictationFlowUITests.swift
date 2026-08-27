import XCTest

/// Drives dictation the way a user does: open the terminal, tap the microphone, and check the app reacts.
///
/// The simulator cannot run the local speech models, so this exercises the app's visible refusal path rather than
/// falling back to Apple's recogniser. What the model hears is covered by the physical-device accuracy test.
final class DictationFlowUITests: XCTestCase {

    /// Swipes the bottom strip to the page a control is on and returns it.
    ///
    /// The controls used to be on a permanent rail. They are now on one paged strip, so a test that only looks
    /// for a button by name would fail for a reason that has nothing to do with what it is testing.
    private func control(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[label]
        if button.exists && button.isHittable { return button }
        let deck = app.otherElements["root.control-deck"]
        let strip = deck.exists ? deck : app.windows.firstMatch
        for _ in 0..<ControlDeckPages {
            if button.exists && button.isHittable { return button }
            strip.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.94))
                .press(forDuration: 0.05, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.94)))
        }
        return button
    }

    private func dismissAlertIfPresent(_ app: XCUIApplication) {
        let dismiss = app.buttons["Dismiss"].firstMatch
        if dismiss.exists && dismiss.isHittable { dismiss.tap() }
    }

    private let rootDestinations = ["Home", "Terminal", "Sessions", "Inbox", "Repo", "Settings"]

    private func pager(in app: XCUIApplication) -> XCUIElement {
        app.otherElements["root.destination.pager"]
    }

    private func currentRootDestination(in app: XCUIApplication) -> String {
        let value = (pager(in: app).value as? String) ?? ""
        if let title = rootDestinations.first(where: { value.localizedCaseInsensitiveContains($0) }) {
            return title
        }
        return "Home"
    }

    private func assertCurrentRootDestination(
        _ title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let pager = pager(in: app)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", title), object: pager)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "expected root destination \(title), got \(String(describing: pager.value))",
            file: file,
            line: line
        )
    }

    private func navigate(to destination: String, in app: XCUIApplication) {
        dismissAlertIfPresent(app)
        XCTAssertTrue(pager(in: app).waitForExistence(timeout: 15), "the root paging accessibility surface never appeared")
        guard let targetIndex = rootDestinations.firstIndex(of: destination) else {
            return XCTFail("unknown root destination \(destination)")
        }

        for _ in 0..<rootDestinations.count {
            let current = currentRootDestination(in: app)
            if current == destination { return }
            let currentIndex = rootDestinations.firstIndex(of: current) ?? 0
            swipeRootDestination(forward: targetIndex >= currentIndex, in: app)
            dismissAlertIfPresent(app)
        }
        assertCurrentRootDestination(destination, in: app)
    }

    /// The strip's previous/next buttons are gone with the Control Deck; the root pager is driven by the same
    /// horizontal fling a user makes.
    private func swipeRootDestination(forward: Bool, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let sourceX: CGFloat = forward ? 0.82 : 0.18
        let destinationX: CGFloat = forward ? 0.18 : 0.82
        window.coordinate(withNormalizedOffset: CGVector(dx: sourceX, dy: 0.18))
            .press(
                forDuration: 0.05,
                thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: destinationX, dy: 0.18))
            )
    }

    private func goToTerminal(_ app: XCUIApplication) {
        navigate(to: "Terminal", in: app)
    }

    /// How many pages the strip has, and so how many swipes can be needed to reach one.
    private let ControlDeckPages = 3

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        // The gate would otherwise sit on a biometric prompt no automation can answer. The seeded key lets the
        // tests that need a live host connect to one.
        app.launchArguments = [
            "-openpaw.settings.biometricGate", "<false/>",
            "-openpaw-debug-scenario", "connectedWorkspace",
            "-openpaw-ui-test-steady-terminal-cursor",
        ]
        app.launch()
        return app
    }

    /// The entry point has to exist and be usable. A microphone button that is present but permanently disabled is
    /// the same thing as no dictation at all, so both are asserted.
    func testTheMicrophoneControlIsAvailableInTheTerminal() throws {
        let app = launchedApp()
        goToTerminal(app)

        // On the strip's view page rather than always on screen: holding anywhere is the everyday route to
        // speech, so a permanent microphone icon was spending width on a job a gesture already does. It still has
        // to exist, because a press held for a third of a second is not a gesture VoiceOver can perform.
        let mic = control("Dictate into a terminal draft", in: app)
        XCTAssertTrue(
            mic.waitForExistence(timeout: 10),
            "no dictation control anywhere on the strip. On screen:\n\(app.debugDescription)"
        )
        XCTAssertTrue(mic.isEnabled, "the dictation control is present but disabled, so speech cannot start")
        XCTAssertTrue(mic.isHittable, "the dictation control cannot be tapped")
    }

    /// Holding the terminal must reach dictation rather than a menu.
    ///
    /// This is a regression test for a defect found on the device, not in a test: holding the terminal opened a
    /// select/copy menu, so "hold anywhere to talk" did nothing on the screen it matters most on. Two menus were
    /// in the way — this app's own confirmation dialog, and the UIKit edit menu `TerminalView` installs itself.
    /// Both are checked here by name, because either one reappearing silently takes the gesture back.
    func testHoldingTheTerminalDoesNotRaiseAMenuInsteadOfDictating() throws {
        let app = launchedApp()
        goToTerminal(app)

        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal surface to hold")
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 1.2)

        // SwiftTerm's own edit menu. It answered a 0.7s press and covered the speech ring.
        for label in ["Select All", "Paste", "Select"] {
            XCTAssertFalse(
                app.menuItems[label].exists || app.buttons[label].exists,
                "holding the terminal raised the system edit menu, which takes the gesture away from speech"
            )
        }
        // This app's own confirmation dialog, which used to answer a 0.45s press.
        XCTAssertFalse(
            app.buttons["Copy all output"].exists && app.buttons["Cancel"].exists,
            "holding the terminal raised the output menu instead of starting dictation"
        )

        let unavailable = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'dictation unavailable'")).firstMatch
        XCTAssertTrue(
            unavailable.waitForExistence(timeout: 5),
            "holding with no local model did not show unavailable/download guidance. On screen:\n\(app.debugDescription)"
        )
        let dismiss = app.buttons["Dismiss"].firstMatch
        if dismiss.exists { dismiss.tap() }

        // What replaced it: copying is still reachable, from the strip's view page rather than from a hold.
        XCTAssertTrue(
            control("Copy all output", in: app).waitForExistence(timeout: 5),
            "the long press lost its menu and the strip did not gain it, so copying is unreachable"
        )
    }

    /// Tapping the terminal must not raise the edit menu either.
    ///
    /// Reported from the device with a screenshot showing the speech ring and Paste / Select All on screen at
    /// once. Suppressing the long press was not enough: `TerminalView` also raises the menu from a *single tap*
    /// near the cursor, so an ordinary tap-to-focus produced a menu nobody asked for, on top of the ring.
    func testTappingNearTheCursorDoesNotRaiseAnEditMenu() throws {
        let app = launchedApp()
        // `connectedWorkspace` is already the authenticated public workspace. Reconnecting it here races the
        // deterministic discovery alert and turns a cursor regression into a host-lifecycle test.
        goToTerminal(app)

        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal surface to tap")
        // Let the shell print its prompt, which is what the cursor and the selection paths need to exist.
        Thread.sleep(forTimeInterval: 5)
        // Tapped where a disconnected terminal's cursor sits: the home row of the grid, hard left. `TerminalView`
        // raises the menu when a tap lands within four columns and two rows of the cursor, which is exactly where
        // a person taps to focus the thing they want to type into.
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.04)).tap()
        // Double taps raise it from their own path, and a hold raises it from two more.
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.04)).doubleTap()
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 1.2)

        for label in ["Select All", "Paste", "Select", "Copy"] {
            XCTAssertFalse(
                app.menuItems[label].exists || app.buttons[label].exists,
                "tapping the terminal raised the \(label) menu; a tap is how you focus a terminal, not how you "
                    + "ask for a menu. On screen:\n\(app.debugDescription)"
            )
        }
    }

    /// Tapping the microphone with no local model available must explain what to do, not silently do nothing and not
    /// arm Apple Speech as a simulator fallback.
    func testTappingTheMicrophoneShowsDownloadGuidanceWhenNoLocalModelCanRun() throws {
        let app = launchedApp()
        goToTerminal(app)

        let mic = control("Dictate into a terminal draft", in: app)
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "no dictation control on the strip")
        mic.tap()

        let guidance = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'dictation unavailable'")).firstMatch
        XCTAssertTrue(
            guidance.waitForExistence(timeout: 10),
            "tapping dictation without a local engine did not show unavailable/download guidance. On screen:\n\(app.debugDescription)"
        )
        XCTAssertFalse(app.buttons["Stop dictation"].exists, "the app armed a recogniser even though no local model can run")
    }

    /// The missing-model path must not open an empty draft row that looks like listening.
    func testUnavailableDictationDoesNotOpenASilentDraft() throws {
        let app = launchedApp()
        goToTerminal(app)

        let mic = control("Dictate into a terminal draft", in: app)
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "no dictation control on the strip")
        mic.tap()

        let draft = app.textFields["Speak, then execute"]
        XCTAssertFalse(
            draft.exists,
            "unavailable dictation opened an empty draft strip instead of showing guidance"
        )
    }
}
