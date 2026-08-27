import XCTest

/// Root destination paging is additive navigation, not a replacement for the controls already owned by each screen.
///
/// These tests use the deterministic simulator scenario so every destination, an Inbox decision, a session detail,
/// and a real horizontally scrolling diff exist without a daemon or network. They deliberately drive the public UI:
/// a regression in gesture arbitration has to be visible here, not only in the pure policy tests.
final class RootTabSwipeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(
        _ scenario: String = "connectedWorkspace",
        restoresKeyboardModifiers: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-openpaw.settings.biometricGate", "<false/>",
            "-openpaw-debug-scenario", scenario,
            "-openpaw-ui-test-steady-terminal-cursor",
        ]
        if restoresKeyboardModifiers {
            app.launchArguments.append("-openpaw-ui-test-command-option-arrows")
        }
        app.launch()
        let dismiss = app.alerts.buttons["Dismiss"]
        if dismiss.waitForExistence(timeout: 2) { dismiss.tap() }
        XCTAssertTrue(pager(in: app).waitForExistence(timeout: 15), "the root paging accessibility surface never appeared")
        return app
    }

    private func pager(in app: XCUIApplication) -> XCUIElement {
        app.otherElements["root.destination.pager"]
    }

    private func assertCurrent(_ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let pager = pager(in: app)
        let predicate = NSPredicate(format: "value == %@", title)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: pager)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed, "expected root destination \(title), got \(String(describing: pager.value))", file: file, line: line)
    }

    private func navigate(to destination: String, in app: XCUIApplication) {
        let titles = ["Home", "Terminal", "Sessions", "Inbox", "Repo", "Settings"]
        guard let target = titles.firstIndex(of: destination) else {
            XCTFail("unknown root destination \(destination)")
            return
        }
        for _ in 0..<target {
            fling(.next, in: app)
        }
        assertCurrent(destination, in: app)
    }

    private enum Direction { case previous, next }

    private func fling(_ direction: Direction, in app: XCUIApplication, y: CGFloat = 0.18) {
        let window = app.windows.firstMatch
        let sourceX: CGFloat = direction == .next ? 0.82 : 0.18
        let destinationX: CGFloat = direction == .next ? 0.18 : 0.82
        window.coordinate(withNormalizedOffset: CGVector(dx: sourceX, dy: y))
            .press(
                forDuration: 0.05,
                thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: destinationX, dy: y))
            )
    }

    func testDeliberateFlingsPageEveryRootDestinationOneStepAndNeverWrap() {
        let app = launch()
        assertCurrent("Home", in: app)

        for title in ["Terminal", "Sessions", "Inbox", "Repo", "Settings"] {
            fling(.next, in: app)
            assertCurrent(title, in: app)
        }
        fling(.next, in: app)
        assertCurrent("Settings", in: app)

        for title in ["Repo", "Inbox", "Sessions", "Terminal", "Home"] {
            fling(.previous, in: app)
            assertCurrent(title, in: app)
        }
        fling(.previous, in: app)
        assertCurrent("Home", in: app)
    }

    /// The deck's destination buttons are gone; the launcher orb is the only permanent navigation chrome, and
    /// the root pager remains the accessibility surface that reports where the user is.
    func testTheOrbReplacesTheDestinationButtons() {
        let app = launch()

        XCTAssertTrue(app.buttons["root.proactive-launcher.orb"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["root.destination.next"].exists)
        XCTAssertFalse(app.buttons["root.destination.previous"].exists)
        XCTAssertFalse(app.buttons["root.destination.home"].exists)

        fling(.next, in: app)
        assertCurrent("Terminal", in: app)
        fling(.next, in: app)
        assertCurrent("Sessions", in: app)
        XCTAssertTrue(app.buttons["root.proactive-launcher.orb"].exists)
    }

    func testTerminalTypingAndVerticalScrollingStayInTheTerminal() {
        let app = launch()
        navigate(to: "Terminal", in: app)
        assertCurrent("Terminal", in: app)

        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "the terminal surface never appeared")
        // Scroll before opening the software keyboard. SwiftTerm's cursor blink keeps XCTest's global animation-idle
        // heuristic busy while the keyboard is visible, but it is not part of the gesture ownership being tested.
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(
                forDuration: 0.1,
                thenDragTo: terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            )
        assertCurrent("Terminal", in: app)

        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        // `typeText` waits for XCTest's `hasKeyboardFocus` attribute, which custom UITextInput implementations such
        // as SwiftTerm do not publish even while they are first responder. Physical key events exercise the same
        // terminal input path without a three-minute accessibility retry loop. The first synthetic press can be the
        // event that settles SwiftTerm's custom first responder after a coordinate tap, so use it only as a warm-up and
        // assert the complete sequence that follows it.
        app.typeKey("w", modifierFlags: [])
        for key in ["x", "q", "z"] {
            app.typeKey(key, modifierFlags: [])
        }
        let typed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "xqz"),
            object: terminal
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [typed], timeout: 5), .completed,
            "typed terminal input was not retained by the terminal surface"
        )
        assertCurrent("Terminal", in: app)
    }

    func testLeadingEdgeBackPopsSessionDetailInsteadOfChangingTheRootDestination() {
        let app = launch("sessions")
        navigate(to: "Sessions", in: app)
        assertCurrent("Sessions", in: app)

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fix the flaking auth tests")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the deterministic session row never appeared")
        row.tap()
        XCTAssertTrue(app.textViews["Prompt"].waitForExistence(timeout: 10), "the session transcript did not push")

        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
            .press(
                forDuration: 0.05,
                thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.45))
            )

        XCTAssertTrue(row.waitForExistence(timeout: 10), "the leading-edge gesture did not return to the session list")
        assertCurrent("Sessions", in: app)
    }

    func testActiveTextSelectionStaysLocalToTheEditor() {
        let app = launch("sessions")
        navigate(to: "Sessions", in: app)
        assertCurrent("Sessions", in: app)

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fix the flaking auth tests")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the deterministic session row never appeared")
        row.tap()

        let prompt = app.textViews["Prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "the editable session prompt did not appear")
        prompt.tap()
        prompt.typeText("selection sentinel")
        prompt.doubleTap()

        prompt.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: prompt.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5))
            )

        XCTAssertTrue(prompt.exists, "root paging removed the editor while it owned an active text selection")
        assertCurrent("Sessions", in: app)
    }

    func testPresentedAddDeviceSheetSuppressesRootPaging() {
        let app = launch()
        assertCurrent("Home", in: app)

        let addDevice = app.buttons["Add a Tailscale or SSH device"].firstMatch
        XCTAssertTrue(addDevice.waitForExistence(timeout: 10), "the populated Home add-device action never appeared")
        addDevice.tap()
        XCTAssertTrue(app.navigationBars["Add a device"].waitForExistence(timeout: 10), "the Add Device sheet did not open")

        fling(.next, in: app, y: 0.35)

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the Add Device sheet lost its close action")
        close.tap()
        assertCurrent("Home", in: app)
    }

    func testDiffHorizontalScrollAndInboxRowActionsRemainLocal() {
        let app = launch("repoProviders")
        navigate(to: "Repo", in: app)
        assertCurrent("Repo", in: app)

        let file = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "tests/conftest.py")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "the deterministic diff file never appeared")
        file.tap()
        let horizontal = app.scrollViews.allElementsBoundByIndex.last
        XCTAssertNotNil(horizontal, "the diff has no horizontal scroll surface")
        horizontal?.swipeLeft()
        assertCurrent("Repo", in: app)

        // Root destinations share a NavigationStack today. Return from the diff before changing destinations so
        // this assertion exercises Inbox's row gesture rather than a stale repo detail still covering the root.
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the diff navigation back button never appeared")
        back.tap()

        navigate(to: "Inbox", in: app)
        assertCurrent("Inbox", in: app)
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "inbox.item."))
            .firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 10),
            "the deterministic Inbox row never appeared. On screen:\n\(app.debugDescription)"
        )
        row.swipeLeft()
        XCTAssertTrue(app.buttons["Deny"].waitForExistence(timeout: 5), "row swipe did not expose Deny")
        XCTAssertFalse(app.buttons["Dismiss"].exists, "an actionable row exposed the informational archive action")
        XCTAssertTrue(row.exists, "a full swipe executed an Inbox decision instead of only exposing its actions")
        assertCurrent("Inbox", in: app)
    }

    func testKeyboardAndVoiceOverAlternativesExposeTheSamePaging() {
        let app = launch()
        let pager = pager(in: app)
        XCTAssertEqual(pager.label, "Root tabs")
        XCTAssertEqual(pager.value as? String, "Home")

        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [.command, .option])
        assertCurrent("Terminal", in: app)
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [.command, .option])
        assertCurrent("Home", in: app)
    }

    func testOrdinaryArrowDoesNotInvokeTheRootShortcut() {
        let app = launch(restoresKeyboardModifiers: false)
        assertCurrent("Home", in: app)

        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])

        assertCurrent("Home", in: app)
    }
}
