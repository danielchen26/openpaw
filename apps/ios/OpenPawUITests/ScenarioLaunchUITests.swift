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

    func testConnectedWorkspaceSeedsTheRealHomeSurface() {
        let app = launch(scenario: "connectedWorkspace")

        XCTAssertTrue(app.staticTexts["Scenario host"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open agent session '")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open pending approval '")).firstMatch.exists)
        XCTAssertTrue(app.buttons["Open repository openpaw"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Inbox, '")).firstMatch.exists)
        let sessions = app.buttons["root.destination.sessions"]
        XCTAssertTrue(sessions.exists)
        XCTAssertEqual(sessions.label, "Sessions")
        XCTAssertFalse(app.buttons["Chat"].exists)
    }

    func testFixtureOnlyHostIsAbsentWithoutTheScenarioArgument() {
        let app = launch()

        XCTAssertFalse(app.staticTexts["Scenario host"].waitForExistence(timeout: 3))
    }
}
