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

    /// The daemon `scripts/dictation-ui-live.py` started, if this run has one.
    ///
    /// Absent in a normal `check.sh` run, present when the live script drove it. Everything that does not need a
    /// session behaves the same either way; the hold test is the one that changes.
    /// The SSH target handed over by `scripts/dictation-ui-live.py`, when the developer supplied one.
    ///
    /// Distinguishes "the composer is missing because nothing could reach a session" from "the composer is missing
    /// even though everything needed was supplied", which is a regression worth failing on.
    private var sshHost: String? {
        ProcessInfo.processInfo.environment["OPENPAW_UITEST_SSH_HOST"].flatMap { $0.isEmpty ? nil : $0 }
    }

    private var liveDaemon: (port: String, pairingCode: String)? {
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["OPENPAW_UITEST_DIRECT_PORT"], !port.isEmpty,
            let code = environment["OPENPAW_UITEST_PAIRING_CODE"], !code.isEmpty
        else { return nil }
        return (port, code)
    }

    private func launchedApp(seedLegacyAppleTerminalDictation: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        // Must be a plist literal: the argument domain parses `-key NO` as the string "NO", which the gate refuses.
        app.launchArguments = [
            "-openpaw.settings.biometricGate", "<false/>",
            "-openpaw-debug-scenario", "connectedWorkspace",
            "-openpaw-ui-test-steady-terminal-cursor",
            "-openpaw-ui-test-command-option-arrows",
        ]
        if seedLegacyAppleTerminalDictation {
            // Seeds the old persisted value so this test proves launch migration, not so Apple can run.
            app.launchArguments += [
                "-openpaw.settings.dictationEngine", "apple",
                "-openpaw.settings.dictationLocale", "zh-CN",
                "-openpaw.settings.dictationMode", "terminal",
            ]
        }
        let environment = ProcessInfo.processInfo.environment
        if let sshHost = environment["OPENPAW_UITEST_SSH_HOST"], !sshHost.isEmpty {
            // The app only marks the structured backend ready once the terminal connects, so reaching the
            // composer needs a host this machine can actually SSH into. Supplied by scripts/dictation-ui-live.py.
            app.launchArguments += ["-openpaw-debug-ssh-host", sshHost]
            if let key = environment["OPENPAW_UITEST_SSH_KEY"], !key.isEmpty {
                // The UI test runner can read a host path, but the sandboxed app cannot. Passing that path through
                // used to work only while a stale simulator container happened to retain access; after a clean boot
                // the app trapped in its debug seeder before drawing a frame. Read the disposable test key here and
                // hand the bytes to the DEBUG+simulator-only launch hook instead.
                let url = URL(fileURLWithPath: key)
                do {
                    let data = try Data(contentsOf: url)
                    guard !data.isEmpty else {
                        XCTFail("the live UI test SSH key is empty: \(url.path)")
                        return app
                    }
                    app.launchEnvironment["OPENPAW_DEBUG_SEED_KEY_BASE64"] = data.base64EncodedString()
                    app.launchEnvironment["OPENPAW_DEBUG_SEED_KEY_IDENTIFIER"] = url.lastPathComponent
                } catch {
                    XCTFail("the live UI test could not read SSH key \(url.path): \(error.localizedDescription)")
                    return app
                }
            }
        }
        if let live = liveDaemon {
            // Points the structured API straight at loopback and pairs on launch, so the app comes up with real
            // sessions and therefore a real composer. Both hooks are DEBUG+simulator only; see `OpenPawApp.swift`.
            app.launchArguments += [
                "-openpaw-debug-direct-port", live.port,
                "-openpaw-debug-pairing-code", live.pairingCode,
            ]
        }
        app.launch()
        // First contact with a host this simulator has never seen raises the host-key sheet, and an unanswered
        // sheet does not merely block the terminal: it sits over every screen, so even the picker tests fail on
        // "no recogniser picker" while the real problem is an unacknowledged fingerprint. Same handling as
        // ConnectFlowUITests and DictationFlowUITests.
        if sshHost != nil {
            let trust = app.buttons["Trust this host key and continue connecting"]
            if trust.waitForExistence(timeout: 10) { trust.tap() }
        }
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

    private let rootDestinations = ["Home", "Terminal", "Sessions", "Inbox", "Repo", "Settings"]
    private let controlDeckPages = 3

    private func pager(in app: XCUIApplication) -> XCUIElement {
        app.otherElements["root.destination.pager"]
    }

    private func currentRootDestination(in app: XCUIApplication) -> String {
        let value = (pager(in: app).value as? String) ?? ""
        if let title = rootDestinations.first(where: { value.localizedCaseInsensitiveContains($0) }) {
            return title
        }
        let visibleButton = [
            ("Home", "root.destination.home"),
            ("Terminal", "root.destination.terminal"),
            ("Sessions", "root.destination.sessions"),
            ("Inbox", "root.destination.inbox"),
            ("Repo", "root.destination.repo"),
            ("Settings", "root.destination.settings"),
        ].first { app.buttons[$0.1].firstMatch.exists }
        return visibleButton?.0 ?? "Home"
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
        clearAlertIfPresent(app)
        XCTAssertTrue(pager(in: app).waitForExistence(timeout: 15), "the root paging accessibility surface never appeared")
        guard let targetIndex = rootDestinations.firstIndex(of: destination) else {
            return XCTFail("unknown root destination \(destination)")
        }

        var currentIndex = rootDestinations.firstIndex(of: currentRootDestination(in: app)) ?? 0
        var needsGestureAfterLeavingSettingsDetail = false
        if currentIndex == rootDestinations.count - 1, targetIndex < currentIndex {
            let back = app.buttons["BackButton"].firstMatch
            if back.exists, back.isHittable {
                back.tap()
                XCTAssertTrue(
                    app.buttons["settings.category.voice"].firstMatch.waitForExistence(timeout: 5),
                    "Settings home did not reappear after leaving Voice & Dictation")
                needsGestureAfterLeavingSettingsDetail = true
            }
        }

        let window = app.windows.firstMatch
        while currentIndex != targetIndex {
            let movesNext = targetIndex > currentIndex
            if needsGestureAfterLeavingSettingsDetail {
                let sourceX: CGFloat = movesNext ? 0.82 : 0.18
                let destinationX: CGFloat = movesNext ? 0.18 : 0.82
                window.coordinate(withNormalizedOffset: CGVector(dx: sourceX, dy: 0.18))
                    .press(
                        forDuration: 0.05,
                        thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: destinationX, dy: 0.18)))
                needsGestureAfterLeavingSettingsDetail = false
            } else {
                let key = movesNext ? XCUIKeyboardKey.rightArrow.rawValue : XCUIKeyboardKey.leftArrow.rawValue
                app.typeKey(key, modifierFlags: [.command, .option])
            }
            clearAlertIfPresent(app)
            currentIndex += movesNext ? 1 : -1
            assertCurrentRootDestination(rootDestinations[currentIndex], in: app)
        }
    }

    private func goToSettings(_ app: XCUIApplication) {
        if app.buttons["settings.category.voice"].firstMatch.exists { return }
        navigate(to: "Settings", in: app)
    }

    private func control(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[label]
        if button.exists && button.isHittable { return button }
        let deck = app.otherElements["root.control-deck"]
        let strip = deck.exists ? deck : app.windows.firstMatch
        for _ in 0..<controlDeckPages {
            if button.exists && button.isHittable { return button }
            strip.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.94))
                .press(forDuration: 0.05, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.94)))
        }
        return button
    }

    private func pageScrollView(_ app: XCUIApplication) -> XCUIElement {
        let surfaces = app.scrollViews.allElementsBoundByIndex
            + app.collectionViews.allElementsBoundByIndex
        let widest = surfaces
            .filter { $0.exists }
            .max { $0.frame.width < $1.frame.width }
        return widest ?? app.collectionViews.firstMatch
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
        goToSettings(app)
        let voiceCategory = app.buttons["settings.category.voice"].firstMatch
        if !voiceCategory.waitForExistence(timeout: 10) {
            // The tap can be swallowed whole when it lands during the host-key sheet's dismissal animation, which
            // is exactly when a live-daemon launch arrives here. The screen is then still Home, which also has a
            // scroll view, so waiting on a scroll view cannot tell the difference. One more tap, after the window
            // has settled, is the difference between testing Settings and failing on a transition.
            clearTunnelAlerts(app)
            goToSettings(app)
        }
        XCTAssertTrue(
            voiceCategory.waitForExistence(timeout: 10),
            "Settings never rendered its Voice & Dictation category. On screen:\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            scroll(app, to: voiceCategory),
            "Settings rendered Voice & Dictation outside the tappable viewport. On screen:\n\(app.debugDescription)"
        )
        voiceCategory.tap()
        var picker = recogniserPicker(in: app)
        if !picker.waitForExistence(timeout: 10) {
            clearTunnelAlerts(app)
            if voiceCategory.exists, voiceCategory.isHittable { voiceCategory.tap() }
            picker = recogniserPicker(in: app)
        }
        XCTAssertTrue(
            picker.waitForExistence(timeout: 10),
            "Settings never rendered its recogniser control. On screen:\n\(app.debugDescription)"
        )
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
        XCTAssertTrue(
            value.localizedCaseInsensitiveContains("qwen3 0.6b"),
            "a fresh Settings screen should identify Qwen3 0.6B as the default high-accuracy recogniser. Value: \(value)")
    }

    /// A launch argument from an older debug run may still say `apple`, but it must migrate before Settings renders.
    ///
    /// This keeps the simulator harness useful without reintroducing an Apple Speech runtime path: the picker shows
    /// Qwen3 0.6B, its menu never offers Apple, and the simulator explains that local models need a real device.
    func testLegacyAppleLaunchArgumentMigratesToQwenAndDoesNotOfferApple() throws {
        let app = launchedApp(seedLegacyAppleTerminalDictation: true)
        let picker = settingsShowingRecogniser(app)

        let value = (picker.value as? String) ?? ""
        XCTAssertTrue(
            value.localizedCaseInsensitiveContains("qwen3 0.6b"),
            "legacy Apple launch argument did not migrate to Qwen3 0.6B. Value: \(value)")

        picker.tap()
        let apple = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'apple'")).firstMatch
        XCTAssertFalse(apple.waitForExistence(timeout: 2), "the recogniser menu still offers Apple Speech")

        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'qwen3 0.6b'")).firstMatch.tap()

        #if targetEnvironment(simulator)
            let explanation = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'real device'")).firstMatch
            XCTAssertTrue(
                explanation.waitForExistence(timeout: 5),
                "Qwen on a simulator did not show actionable unsupported-device guidance. On screen:\n\(app.debugDescription)")
        #endif
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
        let picker = settingsShowingRecogniser(app)

        // The fresh-install default is Qwen3 0.6B. Its row must already refuse the simulator before the user opens
        // the menu, otherwise the default path still advertises a download that cannot run here.
        var explanation = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] 'real device'")).firstMatch
        XCTAssertTrue(
            explanation.waitForExistence(timeout: 5),
            "the default Qwen3 0.6B row does not explain the simulator limitation. On screen:\n\(app.debugDescription)"
        )
        var download = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] 'download'")).firstMatch
        XCTAssertFalse(download.exists, "the default Qwen3 0.6B row offers an unusable simulator download")

        picker.tap()

        // The menu lists engines by display name. Qwen3 1.7B is unselected on a fresh install, so tapping it proves a
        // local-model choice closes the menu and refreshes the visible unsupported-device guidance.
        let qwen = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'qwen3 1.7b'")).firstMatch
        guard qwen.waitForExistence(timeout: 5) else {
            return XCTFail("the recogniser menu offers no local model at all. On screen:\n\(app.debugDescription)")
        }
        qwen.tap()

        // What the row must now say. Not "Download failed" — nothing was attempted — and not "Not downloaded",
        // which would send the user after weights that could never load here.
        explanation = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] 'real device'")).firstMatch
        XCTAssertTrue(
            explanation.waitForExistence(timeout: 5),
            "picking a local model on a simulator says nothing about why it will not run. "
                + "On screen:\n\(app.debugDescription)"
        )

        // And no button to press, because every action this row could offer ends in the same place.
        download = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] 'download'")).firstMatch
        XCTAssertFalse(
            download.exists,
            "the row offers a download that cannot possibly work on this device"
        )
    }

    /// After choosing a local model, dictation must still be refusable rather than fatal.
    ///
    /// The crash was never in Settings, it was one screen later: pick Qwen, hold the microphone, and the process
    /// aborts inside Metal. So the test follows the user there. Any assertion is secondary to the app still being
    /// alive at the end of it, which is why the last check is that a control still responds.
    ///
    /// The terminal microphone is an explicit accessibility alternative to full-screen hold-to-talk. Pressing that
    /// public control enters the same `PushToTalkController` path without depending on a coordinate or edit-menu
    /// arbitration, so a removed simulator guard fails as a real process death rather than a synthetic state check.
    func testHoldingDictationAfterChoosingALocalModelDoesNotKillTheApp() throws {
        #if !targetEnvironment(simulator)
            throw XCTSkip("on a phone the local model is expected to run, not to be refused")
        #endif

        let app = launchedApp()
        settingsShowingRecogniser(app).tap()
        let qwen = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'qwen3 1.7b'")).firstMatch
        XCTAssertTrue(qwen.waitForExistence(timeout: 5), "the recogniser menu offers no local model to select")
        qwen.tap()

        // Now the public screen the user can always reach in the deterministic workspace. Do not reconnect or depend
        // on a live session: the regression is that selecting a local recogniser on a simulator must be refused with
        // guidance, not that a daemon happens to be available in this UI runner.
        navigate(to: "Terminal", in: app)
        let microphone = control("Dictate into a terminal draft", in: app)
        XCTAssertTrue(microphone.waitForExistence(timeout: 10), "the terminal dictation control never appeared")

        // The app must survive the navigation itself. Selecting a local engine touches the store, and if the guard
        // were removed at the wrong layer the process could die on the way here.
        XCTAssertEqual(
            app.state, .runningForeground,
            "the app died on the way to the composer after a local model was selected")

        // A drag gesture needs a press with duration; a tap is too short to produce onChanged then onEnded.
        microphone.press(forDuration: 1.2)

        let guidance = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'dictation unavailable'")).firstMatch
        XCTAssertTrue(
            guidance.waitForExistence(timeout: 10),
            "holding the selected local recogniser on a simulator did not show unavailable/download guidance. On screen:\n\(app.debugDescription)")

        // The only assertion that matters: the app is still there. `XCUIApplication.state` reads the real process,
        // so an abort inside Metal shows up here as `.notRunning` no matter what the UI looked like a moment ago.
        XCTAssertEqual(
            app.state, .runningForeground,
            "holding dictation with a local model selected killed the app"
        )
    }
}
