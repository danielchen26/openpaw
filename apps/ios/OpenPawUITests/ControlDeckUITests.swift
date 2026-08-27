import XCTest

/// The chrome at the bottom of the screen after the radial launcher replaced the paged strip.
///
/// The original defect was a photograph of a phone: three full-width bars stacked at the bottom taking a fifth
/// of the screen. The launcher's answer is one 56pt orb floating over the content and, on the terminal only,
/// the key strip. These tests measure that the answer holds on a real screen.
final class ControlDeckUITests: XCTestCase {

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-openpaw.settings.biometricGate", "<false/>",
            "-openpaw-debug-scenario", "connectedWorkspace",
            "-openpaw-ui-test-steady-terminal-cursor",
        ]
        app.launch()
        let dismiss = app.alerts.buttons["Dismiss"]
        if dismiss.waitForExistence(timeout: 2) { dismiss.tap() }
        return app
    }

    private func swipeToTerminal(_ app: XCUIApplication) {
        let pager = app.otherElements["root.destination.pager"]
        XCTAssertTrue(pager.waitForExistence(timeout: 15), "the root paging surface never appeared")
        let window = app.windows.firstMatch
        let predicate = NSPredicate(format: "value == %@", "Terminal")
        // The debug scenario raises a discovery alert on a delay; it swallows the fling, so clear it between
        // attempts rather than once at launch.
        for _ in 0..<4 {
            let dismiss = app.alerts.buttons["Dismiss"]
            if dismiss.waitForExistence(timeout: 2) { dismiss.tap() }
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.18))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.18)))
            let wait = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: pager)], timeout: 4)
            if wait == .completed { return }
        }
        XCTFail("swiping from Home did not reach the Terminal. On screen:\n\(app.debugDescription)")
    }

    /// The launcher is the app's permanent control surface, so the orb must exist on every destination —
    /// including Home, before any host interaction.
    func testThePawOrbIsPresentOnLaunch() throws {
        let app = launchedApp()
        let orb = app.buttons["root.proactive-launcher.orb"]
        XCTAssertTrue(orb.waitForExistence(timeout: 15), "the Paw Orb never appeared. On screen:\n\(app.debugDescription)")
    }

    /// The measurement the original defect was reported as: how much of the screen the chrome takes.
    ///
    /// A phone screen is 852 points tall. The three stacked bars came to 150 before the home indicator's own
    /// inset. Now the terminal keeps everything except one key strip.
    func testTheBottomOfTheScreenIsOneStripAndNotAStackOfBars() throws {
        let app = launchedApp()
        swipeToTerminal(app)

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

    /// The terminal keeps its key strip: esc, ctrl and arrows are held down mid-command and cannot live behind
    /// a two-step launcher gesture.
    func testTheTerminalKeepsItsKeyStrip() throws {
        let app = launchedApp()
        swipeToTerminal(app)

        // Looked up by the spoken label rather than the cap: "esc" is not a word, so VoiceOver says "Escape".
        let esc = app.buttons["Escape"]
        XCTAssertTrue(
            esc.waitForExistence(timeout: 10),
            "the terminal lost its key strip. On screen:\n\(app.debugDescription)"
        )
    }

    /// The key strip exists only on the terminal. On Home it would be a row of keys with nothing to receive
    /// them, spending the exact space the launcher redesign reclaimed.
    func testTheKeyStripDoesNotLeakOntoOtherDestinations() throws {
        let app = launchedApp()
        let orb = app.buttons["root.proactive-launcher.orb"]
        XCTAssertTrue(orb.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Escape"].exists, "the terminal key strip is on Home")
    }

    /// The microphone icon is gone from the permanent chrome: holding anywhere already dictates, and the
    /// launcher's Tools branch carries the accessible route.
    func testTheMicrophoneIsNotPermanentlyOnScreen() throws {
        let app = launchedApp()
        swipeToTerminal(app)
        XCTAssertTrue(app.buttons["Escape"].waitForExistence(timeout: 10), "the key strip never appeared")

        XCTAssertFalse(
            app.buttons["Dictate into a terminal draft"].exists,
            "the microphone is still taking permanent space next to the keys"
        )
    }
}
