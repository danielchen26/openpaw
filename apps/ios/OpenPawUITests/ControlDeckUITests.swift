import XCTest

/// The strip of controls at the bottom of the screen.
///
/// Written from a photograph of a phone: three full-width bars stacked at the bottom — a terminal control rail, a
/// tab bar and the key bar — with the key bar crushed against the home indicator. Each bar was reasonable on its
/// own, and nothing in the app was in a position to see that together they took a fifth of the screen.
final class ControlDeckUITests: XCTestCase {

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-openpaw-debug-seed-key", "/tmp/openpaw-sim-key",
            "-openpaw.settings.biometricGate", "<false/>",
        ]
        app.launch()
        return app
    }

    /// The measurement the defect was reported as: how much of the screen the chrome takes.
    ///
    /// A phone screen is 852 points tall. The three stacked bars came to 150 before the home indicator's own
    /// inset, so the terminal got what was left. One paged strip has to cost a fraction of that.
    func testTheBottomOfTheScreenIsOneStripAndNotAStackOfBars() throws {
        let app = launchedApp()
        XCTAssertTrue(app.buttons["Terminal"].waitForExistence(timeout: 15), "the Terminal tab never appeared")
        app.buttons["Terminal"].tap()

        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal surface")

        let screen = app.windows.firstMatch.frame
        let chrome = screen.maxY - terminal.frame.maxY
        XCTAssertLessThan(
            chrome, 110,
            "the terminal ends \(Int(chrome)) points above the bottom of the screen, so the chrome under it is "
                + "still a stack of bars rather than one strip. On screen:\n\(app.debugDescription)"
        )
    }

    /// Swiping the strip moves between pages of controls.
    ///
    /// This is the whole mechanism: the groups sit beside each other rather than on top of each other, which is
    /// what makes the row cost one row. If the swipe does not page, the strip is just a smaller tab bar.
    func testSwipingTheStripPagesBetweenControlGroups() throws {
        let app = launchedApp()
        XCTAssertTrue(app.buttons["Terminal"].waitForExistence(timeout: 15), "the Terminal tab never appeared")
        app.buttons["Terminal"].tap()

        // Arriving at the terminal lands on the keys, because a phone keyboard has no esc, ctrl or arrows.
        // Looked up by the spoken label rather than the cap: "esc" is not a word, so VoiceOver says "Escape".
        let esc = app.buttons["Escape"]
        XCTAssertTrue(
            esc.waitForExistence(timeout: 10),
            "the terminal did not land on the keys page. On screen:\n\(app.debugDescription)"
        )

        // One swipe left reaches the app's destinations, one more reaches the terminal's own controls.
        swipeStrip(app, toward: .leading)
        XCTAssertTrue(
            app.buttons["Settings"].waitForExistence(timeout: 5),
            "swiping the strip did not reach the destinations page. On screen:\n\(app.debugDescription)"
        )
        swipeStrip(app, toward: .leading)
        XCTAssertTrue(
            app.buttons["Copy all output"].waitForExistence(timeout: 5),
            "swiping again did not reach the view page. On screen:\n\(app.debugDescription)"
        )

        // And back, because a strip you can only page one way is a strip you can get lost on.
        swipeStrip(app, toward: .trailing)
        XCTAssertTrue(
            app.buttons["Settings"].waitForExistence(timeout: 5),
            "the strip does not page backwards"
        )
    }

    /// The microphone icon is gone from the permanent chrome.
    ///
    /// Requested directly: holding anywhere already dictates, so a microphone button sitting on screen at all
    /// times was spending permanent width on a job a gesture does. It still exists on the view page, because a
    /// long press is not a gesture VoiceOver can perform.
    func testTheMicrophoneIsNotPermanentlyOnScreen() throws {
        let app = launchedApp()
        XCTAssertTrue(app.buttons["Terminal"].waitForExistence(timeout: 15), "the Terminal tab never appeared")
        app.buttons["Terminal"].tap()
        XCTAssertTrue(app.buttons["Escape"].waitForExistence(timeout: 10), "the keys page never appeared")

        XCTAssertFalse(
            app.buttons["Dictate into a terminal draft"].exists,
            "the microphone is still taking permanent space next to the keys"
        )

        swipeStrip(app, toward: .leading)
        swipeStrip(app, toward: .leading)
        XCTAssertTrue(
            app.buttons["Dictate into a terminal draft"].waitForExistence(timeout: 5),
            "the microphone left the chrome and did not arrive on the view page, so VoiceOver has no way to "
                + "dictate at all"
        )
    }

    /// The strip folds away entirely, and comes back.
    ///
    /// Asked for as "hideable". Folding has to leave the handle behind: a strip that vanishes completely leaves a
    /// terminal with no controls and a gesture nobody was told about as the only way back.
    func testTheStripFoldsAwayAndComesBack() throws {
        let app = launchedApp()
        XCTAssertTrue(app.buttons["Terminal"].waitForExistence(timeout: 15), "the Terminal tab never appeared")
        app.buttons["Terminal"].tap()
        XCTAssertTrue(app.buttons["Escape"].waitForExistence(timeout: 10), "the keys page never appeared")

        app.buttons["Hide controls"].tap()
        XCTAssertFalse(app.buttons["Escape"].waitForExistence(timeout: 2), "the strip did not fold away")

        let handle = app.buttons["Show controls"]
        XCTAssertTrue(handle.exists, "the strip folded away completely, leaving no way to bring it back")
        handle.tap()
        XCTAssertTrue(app.buttons["Escape"].waitForExistence(timeout: 5), "the strip did not come back")
    }

    /// Swiping the strip off the left of the screen gives the whole screen to the content.
    ///
    /// Asked for directly: fold the strip all the way to the left and what is behind it is full screen. Stowing
    /// is one more step in the direction the pages already run, so it costs no new gesture — and unlike folding,
    /// which a stray vertical swipe can trigger, it is only reachable by deliberately swiping past the first page.
    func testSwipingTheStripOffTheLeftGivesTheScreenToTheContent() throws {
        let app = launchedApp()
        XCTAssertTrue(app.buttons["Terminal"].waitForExistence(timeout: 15), "the Terminal tab never appeared")
        app.buttons["Terminal"].tap()

        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal surface")
        XCTAssertTrue(app.buttons["Escape"].waitForExistence(timeout: 10), "the keys page never appeared")

        let screen = app.windows.firstMatch.frame
        let before = screen.maxY - terminal.frame.maxY

        // The keys are the first page, so one more swipe backwards takes the strip off the side.
        swipeStrip(app, toward: .trailing)

        XCTAssertFalse(
            app.buttons["Escape"].waitForExistence(timeout: 2),
            "the strip is still on screen after being swiped off the side"
        )
        let after = screen.maxY - terminal.frame.maxY
        XCTAssertLessThan(
            after, before,
            "the terminal did not grow when the strip was stowed: it ends \(Int(after)) points above the bottom "
                + "of the screen, the same as before, so the strip gave back none of the height it was dismissed "
                + "for"
        )
        XCTAssertLessThan(
            after, 12,
            "the terminal still stops \(Int(after)) points short of the bottom with the strip stowed, so this is "
                + "not the full screen that was asked for"
        )

        // And back, by the same gesture reversed, to the page it left from.
        let handle = app.buttons["Show controls"]
        XCTAssertTrue(handle.exists, "stowing left nothing behind, so there is no way back except a gesture "
            + "nobody was told about")
        handle.tap()
        XCTAssertTrue(
            app.buttons["Escape"].waitForExistence(timeout: 5),
            "the strip did not come back to the page it left from"
        )
    }

    private enum Toward { case leading, trailing }

    /// Swipes across the strip itself, which is the bottom row of the screen.
    private func swipeStrip(_ app: XCUIApplication, toward: Toward) {
        let window = app.windows.firstMatch
        let from = toward == .leading ? 0.75 : 0.25
        let to = toward == .leading ? 0.25 : 0.75
        window.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.955))
            .press(
                forDuration: 0.05,
                thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.955)))
    }
}
