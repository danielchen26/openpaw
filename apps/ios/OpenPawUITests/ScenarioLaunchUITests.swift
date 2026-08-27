import XCTest

final class ScenarioLaunchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(scenario: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-openpaw.settings.biometricGate", "<false/>"]
        if let scenario {
            app.launchArguments += ["-openpaw-debug-scenario", scenario]
        }
        app.launch()
        return app
    }

    private func openInbox(in app: XCUIApplication) {
        // The deck's Inbox button is gone; the Home surface's own Inbox summary is the tap route now.
        let inbox = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Inbox, '")).firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 15), "the Inbox summary never appeared")
        inbox.tap()
    }

    private func inboxRow(containing title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    func testConnectedWorkspaceSeedsTheRealHomeSurface() {
        let app = launch(scenario: "connectedWorkspace")

        XCTAssertTrue(app.staticTexts["1 saved device"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Selected connection is connected.")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open agent session '")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open pending approval '")).firstMatch.exists)
        XCTAssertTrue(app.buttons["Open repository openpaw"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Inbox, '")).firstMatch.exists)
        XCTAssertTrue(app.buttons["root.proactive-launcher.orb"].exists)
        XCTAssertFalse(app.buttons["Chat"].exists)
    }

    func testFixtureOnlyHostIsAbsentWithoutTheScenarioArgument() {
        let app = launch()

        XCTAssertFalse(app.staticTexts["Scenario host"].waitForExistence(timeout: 3))
    }

    func testQuickPairingSeedsMacBookProWithoutLeakingIntoAddDevice() {
        let app = launch(scenario: "quickPairing")

        let candidate = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "MacBook Pro,")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Online"].exists)
        XCTAssertFalse(app.staticTexts["Add a device"].exists)
        XCTAssertFalse(app.buttons["Tailscale devices"].exists)
        XCTAssertFalse(app.buttons["Authorize with Tailnet administrator credentials"].exists)
    }

    func testGatedApprovalAppearsOnlyAfterTheFullCommandIsRevealed() {
        let app = launch(scenario: "connectedWorkspace")
        openInbox(in: app)

        let row = inboxRow(containing: "Clear the pytest caches", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the gated permission never appeared")
        row.tap()

        let reveal = app.buttons["Show the full command"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 10), "the full-command gate was not rendered")
        XCTAssertTrue(app.buttons["Deny"].exists, "the safe refusal disappeared behind the reveal gate")
        XCTAssertFalse(app.buttons["Review and decide"].exists, "approval review appeared before acknowledgement")
        XCTAssertFalse(app.buttons["Approve once"].exists, "approval appeared before acknowledgement")

        reveal.tap()
        let review = app.buttons["Review and decide"]
        XCTAssertTrue(review.waitForExistence(timeout: 5), "revealing the command did not unlock review")
        review.tap()
        XCTAssertTrue(app.buttons["Approve once"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Deny"].exists, "the safe refusal disappeared from the decision sheet")
    }

    func testDenyNeedsNoAcknowledgementAndActionableItemsCannotBeDismissed() {
        let app = launch(scenario: "connectedWorkspace")
        openInbox(in: app)

        let row = inboxRow(containing: "Clear the pytest caches", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the gated permission never appeared")
        row.swipeLeft()

        let deny = app.buttons["Deny"]
        XCTAssertTrue(deny.waitForExistence(timeout: 5), "row swipe did not expose the safe refusal")
        XCTAssertFalse(app.buttons["Dismiss"].exists, "an actionable request exposed the informational archive action")
        deny.tap()
        XCTAssertFalse(row.waitForExistence(timeout: 5), "Deny did not resolve the request without acknowledgement")
    }

    func testInformationalDismissSurvivesAUserRefresh() {
        let app = launch(scenario: "connectedWorkspace")
        openInbox(in: app)

        let title = "README rewrite ready"
        let row = inboxRow(containing: title, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the informational completion never appeared")
        row.swipeLeft()

        let dismiss = app.buttons["Dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "the informational item did not expose Dismiss")
        XCTAssertFalse(app.buttons["Deny"].exists, "an informational item exposed a decision action")
        dismiss.tap()
        XCTAssertFalse(row.waitForExistence(timeout: 5), "Dismiss did not remove the item from the pending queue")

        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), "the Inbox list did not expose its refresh surface")
        list.swipeDown()
        XCTAssertFalse(row.waitForExistence(timeout: 3), "refresh resurrected a durably dismissed item")

        let decided = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Show ' AND label CONTAINS 'already decided items'")
        ).firstMatch
        XCTAssertTrue(decided.waitForExistence(timeout: 5), "the dismissed item was not retained as decided history")
        decided.tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), "the dismissed item vanished instead of staying archived")
    }

    func testInformationalDetailUsesTheDurableDismissRoute() {
        let app = launch(scenario: "connectedWorkspace")
        openInbox(in: app)

        let title = "README rewrite ready"
        let row = inboxRow(containing: title, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the informational completion never appeared")
        row.tap()

        let dismiss = app.buttons["Dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "informational detail did not expose durable Dismiss")
        XCTAssertFalse(app.buttons["Acknowledge"].exists, "informational detail exposed the legacy non-durable action")
        XCTAssertFalse(app.buttons["Deny"].exists, "informational detail exposed a request decision")
        dismiss.tap()

        XCTAssertTrue(
            app.staticTexts["Dismissed on the host. The agent was not answered."].waitForExistence(timeout: 5),
            "the detail did not report a durable host dismissal"
        )
    }
}
