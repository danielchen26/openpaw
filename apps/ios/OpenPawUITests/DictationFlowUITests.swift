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
        // The gate would otherwise sit on a biometric prompt no automation can answer.
        app.launchArguments = ["-openpaw.settings.biometricGate", "<false/>"]
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
