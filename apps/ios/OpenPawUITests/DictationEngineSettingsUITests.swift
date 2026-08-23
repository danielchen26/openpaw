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

    private func launchedApp(forceAppleTerminalDictation: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        // Must be a plist literal: the argument domain parses `-key NO` as the string "NO", which the gate refuses.
        app.launchArguments = ["-openpaw.settings.biometricGate", "<false/>"]
        if forceAppleTerminalDictation {
            // A simulator cannot run the local models, so the true audio-input test uses Apple's real recogniser.
            // Force every safety-relevant input rather than inheriting whatever a previous manual run left behind:
            // Chinese locale, Apple engine, and words landing in a terminal draft rather than an agent prompt.
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
        var picker = recogniserPicker(in: app)
        if !picker.waitForExistence(timeout: 10) {
            // The tap can be swallowed whole when it lands during the host-key sheet's dismissal animation, which
            // is exactly when a live-daemon launch arrives here. The screen is then still Home, which also has a
            // scroll view, so waiting on a scroll view cannot tell the difference. One more tap, after the window
            // has settled, is the difference between testing Settings and failing on a transition.
            clearTunnelAlerts(app)
            app.buttons["Settings"].firstMatch.tap()
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
    }

    /// Real audio must travel through the simulator's microphone, Apple's recogniser, and the composer into an
    /// editable terminal draft. No test double is involved: `dictation-ui-live.py --audio-file` waits until this
    /// test reports that the audio graph is armed, then plays the file into the Mac input selected for Simulator.
    /// Passing `--audio-device "BlackHole 2ch"` temporarily makes that path a lossless loopback and restores the
    /// developer's original input and output when the run ends.
    ///
    /// A non-empty draft is the acceptance boundary here, not perfect command spelling. Apple's weakness on mixed
    /// Chinese and English is measured separately by `tools/dictation-cer`; this test answers the more basic product
    /// question: can a person speak, see words appear, stop listening, and edit before anything executes?
    func testRealAppleSpeechAudioReachesAnEditableTerminalDraft() throws {
        #if !targetEnvironment(simulator)
            throw XCTSkip("the simulator audio bridge is what this test verifies")
        #endif

        guard liveDaemon != nil, sshHost != nil else {
            throw XCTSkip("a real session needs dictation-ui-live.py with --ssh-host and --ssh-key")
        }
        let environment = ProcessInfo.processInfo.environment
        guard let readyPath = environment["OPENPAW_UITEST_AUDIO_READY"],
            let donePath = environment["OPENPAW_UITEST_AUDIO_DONE"],
            let transcriptPath = environment["OPENPAW_UITEST_AUDIO_TRANSCRIPT"]
        else {
            throw XCTSkip("run dictation-ui-live.py with --audio-file to feed real microphone input")
        }
        for path in [readyPath, donePath, transcriptPath] { try? FileManager.default.removeItem(atPath: path) }

        let app = launchedApp(forceAppleTerminalDictation: true)
        let sessionsTab = app.buttons["Sessions"].firstMatch
        XCTAssertTrue(sessionsTab.waitForExistence(timeout: 15), "the Sessions tab never appeared")
        clearAlertIfPresent(app)
        sessionsTab.tap()

        let sessionRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Run the unit tests, then clean the build directory.'")
        ).firstMatch
        XCTAssertTrue(
            sessionRow.waitForExistence(timeout: 10),
            "the live fixture's agent session never appeared. On screen:\n\(app.debugDescription)"
        )
        sessionRow.tap()
        // The fixture deliberately has no tmux discovery service, so entering its transcript can surface that
        // limitation as a recoverable app alert. Leaving the alert up would make XCTest call the visible microphone
        // "not hittable" even after the layout is correct, and would test the alert rather than voice input.
        clearAlertIfPresent(app)

        let start = app.buttons["Start dictation"]
        XCTAssertTrue(
            start.waitForExistence(timeout: 10),
            "the real composer has no Start dictation control. On screen:\n\(app.debugDescription)"
        )
        let deckHandle = app.buttons["Hide controls"]
        XCTAssertTrue(deckHandle.waitForExistence(timeout: 5), "the app-wide control deck never appeared")
        XCTAssertTrue(
            start.frame.maxY <= deckHandle.frame.minY,
            "the composer microphone is underneath the app-wide control deck, so a person who taps voice opens "
                + "another screen instead. Microphone: \(start.frame); deck begins at \(deckHandle.frame.minY)."
        )
        // Some simulator runtimes report a SwiftUI Button with a simultaneous zero-distance drag as not hittable even
        // when its entire frame is visible. Tapping its centre is the stronger assertion here: if the deck still owns that
        // point, the control will not become Stop below and the test fails on the actual user-visible behaviour.
        func tapVisibleStartControl() {
            if start.isHittable {
                start.tap()
            } else {
                start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }
        tapVisibleStartControl()

        // A fresh runtime can ask for microphone and speech permission separately. Each dialog consumes the tap
        // that opened it, so arm again after allowing until the control enters its starting state.
        let stop = app.buttons["Stop dictation"]
        for _ in 0..<3 where !stop.exists {
            let allow = app.alerts.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'Allow' OR label CONTAINS[c] 'OK'")
            ).firstMatch
            if allow.waitForExistence(timeout: 5) { allow.tap() }
            if start.waitForExistence(timeout: 3) { tapVisibleStartControl() }
        }
        XCTAssertTrue(
            stop.waitForExistence(timeout: 15),
            "Start dictation never became Stop dictation. On screen:\n"
                + app.debugDescription
        )

        // Stop means the user asked to listen; it does not mean the asynchronous engine has installed its input tap.
        // `Listening` is emitted only after `AVAudioEngine.start()` and the recognition task both exist.
        let listening = NSPredicate(format: "value == 'Listening'")
        let engineReady = XCTNSPredicateExpectation(predicate: listening, object: stop)
        XCTAssertEqual(
            XCTWaiter.wait(for: [engineReady], timeout: 15), .completed,
            "dictation never armed its real audio graph. Control value: \(String(describing: stop.value)). "
                + "On screen:\n\(app.debugDescription)"
        )
        FileManager.default.createFile(atPath: readyPath, contents: Data("ready\n".utf8))
        let audioDeadline = Date().addingTimeInterval(45)
        while !FileManager.default.fileExists(atPath: donePath), Date() < audioDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: donePath),
            "the host never played the audio after the recogniser armed"
        )

        // Give SFSpeechRecognizer one final turn of its callback queue before asking it to finish the utterance.
        Thread.sleep(forTimeInterval: 1)
        stop.tap()
        // Rebuild the query after the SwiftUI button changes from waveform/Stop back to mic/Start. XCUI can keep
        // the pre-transition element bound to its old accessibility identity and report `exists == false` even
        // while its own failure snapshot describes the same visible button as `label: 'Start dictation'`.
        let restarted = app.buttons.matching(
            NSPredicate(format: "label == 'Start dictation'")
        ).firstMatch
        XCTAssertTrue(restarted.waitForExistence(timeout: 15), "dictation never stopped")

        let prompt = app.textViews["Prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 15), "the terminal draft editor disappeared after speech")
        let value = (prompt.value as? String) ?? ""
        try? value.write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        XCTAssertTrue(
            value.contains("Draft "),
            "real audio produced no editable draft. Prompt value: \(value). On screen:\n\(app.debugDescription)"
        )
        XCTAssertTrue(prompt.isEnabled, "the dictated terminal draft is present but cannot be edited")
        let execute = app.buttons["Execute the terminal draft"]
        XCTAssertTrue(
            execute.exists && execute.isEnabled,
            "the dictated terminal draft has no enabled explicit execute action. On screen:\n\(app.debugDescription)"
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
    /// The crash was never in Settings, it was one screen later: pick Qwen, hold the microphone, and the process
    /// aborts inside Metal. So the test follows the user there. Any assertion is secondary to the app still being
    /// alive at the end of it, which is why the last check is that a control still responds.
    ///
    /// It hunts for the microphone rather than pressing a location, and that distinction is the whole test. An
    /// earlier version went to the Terminal tab and pressed a coordinate on the text view at (0.5, 0.4). Nothing
    /// there is wired to `startDictation()` — the microphone lives in `ComposerView`, behind a real Button with a
    /// `DragGesture` — so that version never entered the crash path at all. It passed, and it would have gone on
    /// passing with the engine guard deleted, which is the precise failure this file was written to prevent.
    ///
    /// The composer needs a selected agent session, and a session needs the daemon, which is not up in this
    /// environment: both Chat and Terminal render empty states instead. So on a machine with no host, the press
    /// cannot happen and this test says so with `XCTSkip` rather than passing. That is deliberate. A silent pass
    /// here would be counted as coverage of a crash it never went near, which is exactly how the coordinate-press
    /// version survived review. What still runs unconditionally is the part that needs no session: choosing the
    /// local engine, navigating away, and the app being alive and drawing afterwards.
    ///
    /// About that mutation check. An earlier run of this experiment — deleting the guards from
    /// `LocalASRModelStore` — did report the app in state 1, `notRunning`, where healthy is 4, and that was read
    /// as this test catching the crash. Repeating it after the press was corrected tells a more careful story:
    /// with the guards removed it is `testChoosingALocalModelOnASimulatorExplainsItselfAndOffersNoDownload` that
    /// fails, on the settings screen, because merely selecting the engine is enough to reach MLX. This test skips
    /// instead, since the composer is still out of reach. So the file does catch guard removal, but through the
    /// settings test rather than this one, and this one only becomes the real crash check when it runs somewhere
    /// with a live session. Worth knowing before trusting either of them alone.
    func testHoldingDictationAfterChoosingALocalModelDoesNotKillTheApp() throws {
        #if !targetEnvironment(simulator)
            throw XCTSkip("on a phone the local model is expected to run, not to be refused")
        #endif

        let app = launchedApp()
        settingsShowingRecogniser(app).tap()
        let qwen = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'qwen'")).firstMatch
        XCTAssertTrue(qwen.waitForExistence(timeout: 5), "the recogniser menu offers no local model to select")
        qwen.tap()

        // Now the screen the crash happened on. `firstMatch` because these names are both tabs and segments in the
        // dictation destination control that was just scrolled past, and an ambiguous query fails the test for a
        // reason that has nothing to do with the crash.
        let sessionsTab = app.buttons["Sessions"].firstMatch
        XCTAssertTrue(sessionsTab.waitForExistence(timeout: 15), "the Sessions tab never appeared")
        clearAlertIfPresent(app)
        sessionsTab.tap()

        // The Chat tab lands on the sessions *list*; the composer, and with it the microphone, only exists inside
        // one session's transcript. This must be the agent row from `smoke.py`'s checked-in fixture. Its complete
        // accessibility label starts with a dynamic state ("waiting for you", "idle", …), so the stable title is
        // the contract to query. "Attach to …" looks plausible but is a terminal action: tapping it navigates to
        // the terminal and leaves no composer on screen, so the test would fail before approaching voice input.
        clearAlertIfPresent(app)
        let sessionRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Run the unit tests, then clean the build directory.'")
        ).firstMatch
        if sessionRow.waitForExistence(timeout: 10) { sessionRow.tap() }

        // Press the microphone control itself, not a coordinate on the terminal. This test used to press the text
        // view at (0.5, 0.4) and claim in its own name to be holding dictation; nothing there is wired to
        // `startDictation()`, so the crash path was never entered and the test would have passed with the engine
        // guard removed from this screen entirely. The control is a Button carrying a
        // `DragGesture(minimumDistance: 0)`, so a press on it is what actually starts a local engine.
        clearAlertIfPresent(app)

        // Exactly the composer's label, never CONTAINS "dictation". The loose match found the session list row
        // "Attach to ... Prove local dictation actually beats Apple ..." first, because the fixture session's
        // *title* contains the word, pressed that instead, and the test went green having never touched the
        // microphone. Before the hold the composer names this control exactly "Start dictation". Querying that
        // label directly also makes XCTest print `Press "Start dictation" Button` in its activity log, so a future
        // reviewer can prove which control was pressed without trusting this test's variable name.
        let microphone = app.buttons["Start dictation"]
        let reachedTheMicrophone = microphone.waitForExistence(timeout: 10)

        // The app must survive the navigation itself, session or no session. Selecting a local engine touches the
        // store, and if the guard were removed at the wrong layer the process could die on the way here.
        XCTAssertEqual(
            app.state, .runningForeground,
            "the app died on the way to the composer after a local model was selected")

        if !reachedTheMicrophone {
            // A daemon alone is not enough to reach the composer, and that is the app behaving correctly rather
            // than a gap in this test. `OpenPawModel` only sets `structuredBackendReady` once
            // `terminal.connect(host:)` succeeds, so that it never lists a session the user cannot yet type into.
            // The sessions list therefore stays empty until SSH is up. Only when the runner was also given a host
            // to SSH into is an empty composer a real regression.
            if liveDaemon != nil, sshHost != nil {
                return XCTFail(
                    "a live daemon and an SSH host were supplied but the composer never appeared, so the app is "
                        + "not getting from a paired host to a session. On screen:\n\(app.debugDescription)")
            }
            if liveDaemon != nil {
                throw XCTSkip(
                    "paired with a live daemon, but no SSH host was supplied, so the terminal never connects and "
                        + "the app correctly lists no session. Pass --ssh-host to dictation-ui-live.py.")
            }
            // Skip, never pass. Without the daemon there is no agent session, so the composer that carries the
            // microphone is replaced by an empty state and the hold cannot be performed. Reporting success here
            // would credit this file with covering a crash it never approached.
            throw XCTSkip(
                "no agent session on this machine, so the composer and its microphone are not on screen and the "
                    + "hold cannot be performed. Run scripts/dictation-ui-live.py to exercise the crash path.")
        }

        // A drag gesture needs a press with duration; a tap is too short to produce onChanged then onEnded.
        microphone.press(forDuration: 1.2)

        // Microphone or speech permission, which on a fresh simulator container arrives on the first hold.
        let allow = app.alerts.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] 'Allow' OR label CONTAINS[c] 'OK'")).firstMatch
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
            // The permission alert swallows the first hold, so the gesture has to be repeated to reach the engine.
            if microphone.exists, microphone.isHittable { microphone.press(forDuration: 1.2) }
        }

        // The only assertion that matters: the app is still there. `XCUIApplication.state` reads the real process,
        // so an abort inside Metal shows up here as `.notRunning` no matter what the UI looked like a moment ago.
        XCTAssertEqual(
            app.state, .runningForeground,
            "holding dictation with a local model selected killed the app"
        )
        // Still answering, not merely still running. Dictation stages editable text; it must not navigate to the
        // terminal until the person explicitly taps Execute. Requiring this same control therefore catches both a
        // frozen process and an accidental voice-to-execution path.
        XCTAssertTrue(
            microphone.waitForExistence(timeout: 10),
            "the app is running but the composer disappeared after dictation. On screen:\n\(app.debugDescription)"
        )
        XCTAssertEqual(
            app.state, .runningForeground,
            "holding dictation with a local model selected killed the app")
    }
}
