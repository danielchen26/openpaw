import XCTest

/// Selects a local recogniser the way a user does, and reads what the real screen says back.
///
/// Everything else that covers this screen substitutes something. The snapshot catalogue draws it with
/// `StubDictationModelStore`, which is frozen in whatever state the picture wants; the unit tests call
/// `LocalASRModelStore` directly without a view. Both would keep passing if the picker were bound to nothing, or
/// if the row read its state from the wrong store, or if the download button were wired to a closure that does
/// not exist. This is the only test that touches the real screen backed by the real store.
///
/// It runs on a simulator on purpose, because that is where the interesting answer is. MLX cannot allocate a
/// Metal heap there, so choosing Qwen used to be a way to make the app disappear: `state(of:)` said installed if
/// the weights happened to be on disk, the factory built an engine, and the first hold aborted the process inside
/// Metal with no Swift frame in between. The app now refuses the local engines here, and refusing has to be
/// something the user can see rather than something only a unit test knows.
final class DictationEngineSettingsUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        // Must be a plist literal: the argument domain parses `-key NO` as the string "NO", which the gate refuses.
        app.launchArguments = ["-openpaw.settings.biometricGate", "<false/>"]
        app.launch()
        return app
    }

    /// Clears the backend's "tunnel is down" alert, which returns.
    ///
    /// Dismissing it once is not enough and that cost me a test run. The daemon retries on a timer, so the alert
    /// comes back mid-scroll, and while it is up every control underneath reports `exists == true` and
    /// `isHittable == false` — the picker was on screen at y=574 and untappable. That reads exactly like a broken
    /// control, which is a bad way to spend an afternoon.
    ///
    /// Also registers an interruption monitor, because the alert can arrive between a query and a tap where no
    /// amount of polling would see it.
    private func clearTunnelAlerts(_ app: XCUIApplication) {
        addUIInterruptionMonitor(withDescription: "tunnel alert") { alert in
            let dismiss = alert.buttons["Dismiss"]
            guard dismiss.exists else { return false }
            dismiss.tap()
            return true
        }
        for _ in 0..<4 {
            let dismiss = app.buttons["Dismiss"].firstMatch
            guard dismiss.waitForExistence(timeout: 2) else { return }
            dismiss.tap()
        }
    }

    /// Dismisses the alert if it is up right now, cheap enough to call before every interaction.
    private func clearAlertIfPresent(_ app: XCUIApplication) {
        let dismiss = app.buttons["Dismiss"].firstMatch
        if dismiss.exists && dismiss.isHittable { dismiss.tap() }
    }

    private func pageScrollView(_ app: XCUIApplication) -> XCUIElement {
        let widest = app.scrollViews.allElementsBoundByIndex
            .filter { $0.exists }
            .max { $0.frame.width < $1.frame.width }
        return widest ?? app.scrollViews.firstMatch
    }

    /// Scrolls Settings until `element` is actually on screen and tappable.
    ///
    /// Direction matters, and getting it wrong is why this test failed the first time it ran. A SwiftUI ScrollView
    /// builds its whole subtree, so every control in Settings *exists* from the moment the screen appears no matter
    /// where it sits: `exists` is true for a row 1,200 points above the viewport. Swiping blindly walks straight
    /// past the target and reports it missing while it is right there in the hierarchy. So this compares frames and
    /// swipes toward the element, and stops when it stops moving rather than after a fixed count.
    ///
    /// Worth knowing for any test on this screen: asserting `exists` on a Settings control proves almost nothing.
    @discardableResult
    private func scroll(_ app: XCUIApplication, to element: XCUIElement) -> Bool {
        for _ in 0..<20 {
            guard element.exists else { return false }
            // The alert returns on the daemon's retry timer, and while it is up nothing underneath is hittable.
            clearAlertIfPresent(app)
            let page = pageScrollView(app)
            guard page.exists else { return false }
            let frame = element.frame
            let viewport = page.frame
            // A little inside the edges, because a row flush against the tab bar is present but not tappable.
            let margin: CGFloat = 80
            if frame.minY >= viewport.minY + margin, frame.maxY <= viewport.maxY - margin {
                return element.isHittable
            }
            let before = frame.minY
            if frame.minY < viewport.minY + margin {
                page.swipeDown()
            } else {
                page.swipeUp()
            }
            // The content stopped moving, so the element is as close to the middle as this screen can put it.
            if element.exists, abs(element.frame.minY - before) < 1 { return element.isHittable }
        }
        return element.exists && element.isHittable
    }

    /// The recogniser control, found by its accessibility label rather than by position.
    private func recogniserPicker(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'dictation recogniser'")).firstMatch
    }

    /// Opens Settings and scrolls to the recogniser control, failing with what was on screen if it never arrives.
    private func settingsShowingRecogniser(_ app: XCUIApplication) -> XCUIElement {
        clearTunnelAlerts(app)
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(pageScrollView(app).waitForExistence(timeout: 10), "Settings never rendered")
        let picker = recogniserPicker(in: app)
        XCTAssertTrue(
            scroll(app, to: picker),
            // Reports hittability and frame explicitly, because "not found" and "found but covered by an alert"
            // look identical in a hierarchy dump and are completely different bugs.
            "no recogniser picker in Settings. exists=\(picker.exists) "
                + "hittable=\(picker.exists ? String(describing: picker.isHittable) : "n/a") "
                + "frame=\(picker.exists ? String(describing: picker.frame) : "n/a"). "
                + "On screen:\n\(app.debugDescription)")
        return picker
    }

    /// The recogniser picker must be reachable, must name what is selected, and must offer the local models.
    ///
    /// A picker whose selection matches none of its tags renders as an empty box, which is a bug this repo has
    /// already had once: a user who chose Parakeet and then switched to Chinese was shown a recogniser field with
    /// nothing in it. A snapshot catches that only if somebody thought to add that exact combination as a screen.
    func testTheRecogniserPickerNamesWhatIsSelected() {
        let app = launchedApp()
        let picker = settingsShowingRecogniser(app)

        // The value is the whole point of the control. An empty one tells the user nothing about which recogniser
        // their voice is about to go to, which for a screen whose only job is that choice is a total failure.
        let value = (picker.value as? String) ?? ""
        XCTAssertFalse(
            value.trimmingCharacters(in: .whitespaces).isEmpty,
            "the recogniser picker shows no selection, so the screen does not say which engine will run"
        )
    }

    /// Choosing a local model on a simulator must say why it cannot run, and must not offer a download.
    ///
    /// This is the user-visible half of the simulator guard. The unit test proves the store refuses; this proves
    /// the refusal reaches a person. The two failure modes it rules out are the ones that actually happened: the
    /// app disappearing on the next hold, and a Download button offering to spend 450 MB arriving at the same
    /// wall.
    func testChoosingALocalModelOnASimulatorExplainsItselfAndOffersNoDownload() throws {
        #if !targetEnvironment(simulator)
            throw XCTSkip("this asserts what a simulator shows, and a phone shows something else entirely")
        #endif

        let app = launchedApp()
        settingsShowingRecogniser(app).tap()

        // The menu lists engines by display name. Qwen is the one the product ships for Chinese, so it is the one
        // a user reaching for this setting is most likely to pick.
        let qwen = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'qwen'")).firstMatch
        guard qwen.waitForExistence(timeout: 5) else {
            return XCTFail("the recogniser menu offers no local model at all. On screen:\n\(app.debugDescription)")
        }
        qwen.tap()

        // What the row must now say. Not "Download failed" — nothing was attempted — and not "Not downloaded",
        // which would send the user after weights that could never load here.
        let explanation = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] 'real device'")).firstMatch
        XCTAssertTrue(
            explanation.waitForExistence(timeout: 5),
            "picking a local model on a simulator says nothing about why it will not run. "
                + "On screen:\n\(app.debugDescription)"
        )

        // And no button to press, because every action this row could offer ends in the same place.
        let download = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] 'download'")).firstMatch
        XCTAssertFalse(
            download.exists,
            "the row offers a download that cannot possibly work on this device"
        )
    }

    /// After choosing a local model, dictation must still be refusable rather than fatal.
    ///
    /// The crash was never in Settings, it was one screen later: pick Qwen, go to the terminal, hold the button,
    /// and the process aborts inside Metal. So the test follows the user there. Any assertion is secondary to the
    /// app still being alive at the end of it, which is why the last check is that a control still responds.
    ///
    /// Confirmed to actually catch it, rather than assumed to. With the three simulator guards deleted from
    /// `LocalASRModelStore`, this test reports the app in state 1 — `notRunning` — where a healthy run reports 4.
    /// The app is gone by the time the assertion runs. That is the whole reason this file exists, and it is worth
    /// re-running that experiment before ever weakening it.
    func testHoldingDictationAfterChoosingALocalModelDoesNotKillTheApp() throws {
        #if !targetEnvironment(simulator)
            throw XCTSkip("on a phone the local model is expected to run, not to be refused")
        #endif

        let app = launchedApp()
        settingsShowingRecogniser(app).tap()
        let qwen = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'qwen'")).firstMatch
        XCTAssertTrue(qwen.waitForExistence(timeout: 5), "the recogniser menu offers no local model to select")
        qwen.tap()

        // Now the screen the crash happened on. `firstMatch` because "Terminal" is both a tab and a segment in the
        // dictation destination control that was just scrolled past, and an ambiguous query fails the test for a
        // reason that has nothing to do with the crash.
        let terminalTab = app.buttons["Terminal"].firstMatch
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 15), "the Terminal tab never appeared")
        clearAlertIfPresent(app)
        terminalTab.tap()

        let terminal = app.textViews.firstMatch
        if terminal.waitForExistence(timeout: 10) {
            terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 1.0)
        }
        let allow = app.alerts.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] 'Allow' OR label CONTAINS[c] 'OK'")).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }

        // The only assertion that matters: the app is still there. `XCUIApplication.state` reads the real process,
        // so an abort inside Metal shows up here as `.notRunning` no matter what the UI looked like a moment ago.
        XCTAssertEqual(
            app.state, .runningForeground,
            "holding dictation with a local model selected killed the app"
        )
        // Still answering, not merely still running. A process can survive an abort on a background thread and
        // leave a frozen screen, which to the user is the same thing. Checked against the terminal's own key bar
        // rather than the tab bar: the tab bar is replaced by the key bar on this screen, so waiting for "Settings"
        // here fails on an app that is perfectly healthy — which it did, and cost a run to work out.
        XCTAssertTrue(
            app.buttons["Escape"].firstMatch.waitForExistence(timeout: 10),
            "the app is running but no longer draws the terminal. On screen:\n\(app.debugDescription)"
        )
    }
}
