import XCTest

/// Covers the screens a person actually operates: scrolling Home, reaching dictation, and the terminal's type.
///
/// These are all things that render correctly in a snapshot and still fail in the hand, so only driving the real
/// app finds them.
final class HomeInteractionUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        // The gate would otherwise sit on a biometric prompt no automation can answer. Must be a plist literal:
        // the argument domain parses `-key NO` as the string "NO", which the gate correctly refuses.
        app.launchArguments = ["-openpaw.settings.biometricGate", "<false/>"]
        app.launch()
        return app
    }

    /// The backend surfaces a "tunnel is down" alert on a cold launch, and an alert blocks every gesture beneath
    /// it. Without this a scrolling test measures the alert instead of the screen and reports a scroll bug that
    /// isn't there.
    private func dismissAnyAlert(_ app: XCUIApplication) {
        let dismiss = app.buttons["Dismiss"].firstMatch
        if dismiss.waitForExistence(timeout: 3) { dismiss.tap() }
    }

    /// The screen's own scroll view, which is the full-width one. Cards on these screens embed small scroll views
    /// of their own, and `scrollViews.firstMatch` picks one of those instead.
    ///
    /// Filtered in Swift rather than by predicate: XCUITest predicates only reach a few attributes and reject any
    /// key path into `frame`.
    private func pageScrollView(_ app: XCUIApplication) -> XCUIElement {
        let widest = app.scrollViews.allElementsBoundByIndex
            .filter { $0.exists }
            .max { $0.frame.width < $1.frame.width }
        return widest ?? app.scrollViews.firstMatch
    }

    /// Re-resolves the page scroll view before every swipe. These screens load their content asynchronously, so
    /// the number of scroll views changes underfoot and an element captured by index goes stale mid-scroll.
    private func swipeUpOnPage(_ app: XCUIApplication) {
        pageScrollView(app).swipeUp()
    }

    func testHomeUsesTailscaleCopyAndOmitsRemoteCatalogTransfer() {
        let app = launchedApp()

        let discovery = app.staticTexts["Tailscale discovery"].firstMatch
        XCTAssertTrue(discovery.waitForExistence(timeout: 15), "Home does not expose Tailscale discovery copy")

        dismissAnyAlert(app)
        XCTAssertFalse(app.staticTexts["Tailnet discovery"].exists)
        XCTAssertFalse(app.staticTexts["Remote catalog transfer"].exists)
        XCTAssertFalse(app.buttons["Browse remote catalogs"].exists)
    }

    /// The device list has to be reachable. With one saved device the content already runs past the bottom of the
    /// screen, so if the scroll view will not move, the buttons below the fold cannot be tapped at all.
    func testHomeScrollsToReachContentBelowTheFold() {
        let app = launchedApp()

        let addButton = app.buttons["Add a Tailscale or SSH device"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 15), "Home never rendered")

        dismissAnyAlert(app)

        let scrollView = pageScrollView(app)
        XCTAssertTrue(scrollView.exists, "Home is not inside a scroll view")

        // The bottom-most control on the screen. Reaching it is the whole point of scrolling.
        let bottomButton = app.buttons.matching(identifier: "Add a Tailscale or SSH device").element(boundBy: 1)
        guard bottomButton.exists else {
            return XCTFail("expected a second add-device button at the end of the list")
        }

        let before = bottomButton.frame.origin.y
        scrollView.swipeUp()
        let after = bottomButton.frame.origin.y

        XCTAssertLessThan(after, before, "the Home scroll view did not move when swiped")
    }

    /// Settings is the longest screen in the app, so if the shell traps content under the tab bar it shows here
    /// first: the last section becomes unreachable no matter how far you scroll.
    func testBottomOfSettingsIsReachable() {
        let app = launchedApp()

        dismissAnyAlert(app)
        app.buttons["Settings"].firstMatch.tap()

        let scrollView = pageScrollView(app)
        XCTAssertTrue(scrollView.waitForExistence(timeout: 10), "Settings never rendered")

        // Scroll to the end.
        for _ in 0..<12 { swipeUpOnPage(app) }

        // "About" is the final section, so its text is the last thing a user can reach.
        let about = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'about'")).firstMatch
        XCTAssertTrue(about.exists, "never reached the last section of Settings. On screen:\n\(app.debugDescription)")

        let tabBarTop = app.buttons["Settings"].firstMatch.frame.minY
        XCTAssertLessThanOrEqual(
            about.frame.maxY, tabBarTop,
            "the last section of Settings sits under the tab bar and cannot be read"
        )
    }

    /// The dictation language control renders as a bare chevron with no visible text, so there is no way to tell
    /// which language speech will be recognised as, or that the control is a language picker at all.
    func testDictationLanguagePickerShowsItsCurrentLanguage() {
        let app = launchedApp()

        dismissAnyAlert(app)
        app.buttons["Settings"].firstMatch.tap()

        let scrollView = pageScrollView(app)
        XCTAssertTrue(scrollView.waitForExistence(timeout: 10), "Settings never rendered")

        let language = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'dictation language'")).firstMatch
        XCTAssertTrue(language.waitForExistence(timeout: 5),
            "no dictation language control found. On screen:\n\(app.debugDescription)")

        // The control must name the language it is currently set to, not just offer a chevron.
        let shown = language.label + " " + (language.value as? String ?? "")
        XCTAssertTrue(
            shown.lowercased().contains("english") || shown.contains("中文")
                || shown.lowercased().contains("chinese"),
            "the dictation language control does not show which language is selected: '\(shown)'"
        )
    }

    /// Scrolling to the very bottom must actually reveal the last control.
    ///
    /// The shell stacks its own tab bar under the content rather than insetting the scroll view's safe area, so the
    /// final row can sit permanently under the bar: the list appears to stop scrolling because the thing you are
    /// scrolling towards never clears the bar, and it cannot be tapped.
    func testBottomOfHomeIsNotTrappedUnderTheTabBar() {
        let app = launchedApp()

        let anyAddButton = app.buttons["Add a Tailscale or SSH device"].firstMatch
        XCTAssertTrue(anyAddButton.waitForExistence(timeout: 15), "Home never rendered")

        dismissAnyAlert(app)

        let scrollView = pageScrollView(app)
        // Scroll until the content stops moving, i.e. the true bottom.
        var previous = CGFloat.greatestFiniteMagnitude
        for _ in 0..<8 {
            let bottom = app.buttons.matching(identifier: "Add a Tailscale or SSH device").allElementsBoundByIndex.last
            guard let bottom, bottom.exists else { break }
            let y = bottom.frame.origin.y
            if abs(y - previous) < 1 { break }
            previous = y
            swipeUpOnPage(app)
        }

        guard let bottom = app.buttons.matching(identifier: "Add a Tailscale or SSH device").allElementsBoundByIndex.last,
            bottom.exists
        else {
            return XCTFail("the last add-device button vanished while scrolling")
        }

        // The tab bar owns the strip along the bottom. Anything the user is meant to tap has to end above it.
        let tabBar = app.buttons["Settings"].firstMatch
        XCTAssertTrue(tabBar.exists, "the tab bar is missing")
        let tabBarTop = tabBar.frame.minY

        XCTAssertLessThanOrEqual(
            bottom.frame.maxY, tabBarTop,
            "the last control on Home stays under the tab bar even when scrolled to the end, so it cannot be tapped"
        )
    }
}
