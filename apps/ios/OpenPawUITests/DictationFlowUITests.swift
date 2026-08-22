import XCTest

/// Drives dictation the way a user does: open the terminal, tap the microphone, and check the app reacts.
///
/// The simulator's audio input is the host Mac's microphone, so this exercises the real `AVAudioEngine` and
/// `SFSpeechRecognizer` path rather than a substitute. What the recogniser *hears* depends on whether anyone is
/// speaking, so the assertions are about the app's own behaviour — the control arms, the draft row opens for input,
/// and stopping puts it back — which is exactly the part that would break without anyone noticing.
final class DictationFlowUITests: XCTestCase {

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        // The gate would otherwise sit on a biometric prompt no automation can answer. The seeded key lets the
        // tests that need a live host connect to one.
        app.launchArguments = [
            "-openpaw-debug-seed-key", "/tmp/openpaw-sim-key",
            "-openpaw.settings.biometricGate", "<false/>",
        ]
        app.launch()
        return app
    }

    /// The entry point has to exist and be usable. A microphone button that is present but permanently disabled is
    /// the same thing as no dictation at all, so both are asserted.
    func testTheMicrophoneControlIsAvailableInTheTerminal() throws {
        let app = launchedApp()
        XCTAssertTrue(app.buttons["Terminal"].waitForExistence(timeout: 15), "the Terminal tab never appeared")
        app.buttons["Terminal"].tap()

        let mic = app.buttons["Dictate into a terminal draft"]
        XCTAssertTrue(
            mic.waitForExistence(timeout: 10),
            "no dictation control in the terminal. On screen:\n\(app.debugDescription)"
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
        XCTAssertTrue(app.buttons["Terminal"].waitForExistence(timeout: 15), "the Terminal tab never appeared")
        app.buttons["Terminal"].tap()

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

        // What replaced it: copying is still reachable, from the rail rather than from a hold.
        app.buttons["Show more terminal controls"].tap()
        XCTAssertTrue(
            app.buttons["Copy all output"].waitForExistence(timeout: 5),
            "the long press lost its menu and the rail did not gain it, so copying is unreachable"
        )
    }

    /// Tapping the terminal must not raise the edit menu either.
    ///
    /// Reported from the device with a screenshot showing the speech ring and Paste / Select All on screen at
    /// once. Suppressing the long press was not enough: `TerminalView` also raises the menu from a *single tap*
    /// near the cursor, so an ordinary tap-to-focus produced a menu nobody asked for, on top of the ring.
    func testTappingNearTheCursorDoesNotRaiseAnEditMenu() throws {
        let app = launchedApp()
        // Connected on purpose. A disconnected terminal has no cursor and no text, so every path to this menu is
        // unreachable and the test would pass while the defect is fully intact — which it did, twice.
        let connect = app.buttons["Connect to home"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15), "no host to connect to")
        connect.tap()
        let trust = app.buttons["Trust this host key and continue connecting"]
        if trust.waitForExistence(timeout: 10) { trust.tap() }
        XCTAssertTrue(app.buttons["Resume home"].waitForExistence(timeout: 30), "never connected")
        app.buttons["Terminal"].tap()

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

    /// Tapping the microphone has to actually arm dictation. The label flipping to "Stop dictation" is the app's own
    /// claim that the audio graph is live; without it the user is talking to a control that did nothing.
    func testTappingTheMicrophoneStartsAndStopsDictation() throws {
        let app = launchedApp()
        XCTAssertTrue(app.buttons["Terminal"].waitForExistence(timeout: 15), "the Terminal tab never appeared")
        app.buttons["Terminal"].tap()

        let mic = app.buttons["Dictate into a terminal draft"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "no dictation control in the terminal")
        mic.tap()

        // The microphone permission dialog appears on a machine that has not answered it yet. Allowing it is part of
        // the flow a first-time user goes through.
        let allow = app.alerts.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Allow' OR label CONTAINS[c] 'OK'")).firstMatch
        if allow.waitForExistence(timeout: 5) { allow.tap() }

        let stop = app.buttons["Stop dictation"]
        XCTAssertTrue(
            stop.waitForExistence(timeout: 15),
            "the control never armed, so nothing is listening. On screen:\n\(app.debugDescription)"
        )

        stop.tap()
        XCTAssertTrue(
            app.buttons["Dictate into a terminal draft"].waitForExistence(timeout: 15),
            "dictation never stopped, so the microphone would stay live after the user asked it not to"
        )
    }

    /// The dictated words land in an editable draft that is only sent on an explicit tap. That is the product's
    /// safety property: speech never runs a command by itself.
    func testTheDraftIsEditableAndExecutedOnlyOnDemand() throws {
        let app = launchedApp()
        XCTAssertTrue(app.buttons["Terminal"].waitForExistence(timeout: 15), "the Terminal tab never appeared")
        app.buttons["Terminal"].tap()

        // The draft strip only exists while there is something to draft, so dictation has to be armed first. That is
        // the design: no speech in progress and nothing dictated means no half-open command sitting on screen.
        let mic = app.buttons["Dictate into a terminal draft"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "no dictation control in the terminal")
        mic.tap()
        let allow = app.alerts.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Allow' OR label CONTAINS[c] 'OK'")).firstMatch
        if allow.waitForExistence(timeout: 5) { allow.tap() }

        let draft = app.textFields["Speak, then execute"]
        XCTAssertTrue(
            draft.waitForExistence(timeout: 15),
            "dictation is armed but there is no draft to speak into. On screen:\n\(app.debugDescription)"
        )
        // Typing is refused while the recogniser is running, so the keyboard and the transcript cannot fight over
        // the same field. The draft becomes editable once speech stops, which is when a user corrects what was heard.
        XCTAssertFalse(draft.isEnabled, "the draft accepts typing mid-utterance, which races the transcript")

        // Execute stays refused for as long as there is nothing to run, so a stray tap on a silent draft cannot
        // send an empty command to the host.
        let execute = app.buttons["Execute"]
        XCTAssertTrue(execute.exists, "there is no way to send a dictated draft")
        XCTAssertFalse(execute.isEnabled, "an empty draft can be executed, which would send nothing to the host")

        app.buttons["Stop dictation"].tap()
        XCTAssertTrue(
            app.buttons["Dictate into a terminal draft"].waitForExistence(timeout: 15),
            "dictation never stopped"
        )
        // Nothing was said, so nothing is drafted and the strip retires rather than leaving an empty row on screen.
        XCTAssertFalse(
            draft.exists,
            "an empty draft strip stayed on screen after dictation ended"
        )
    }
}
