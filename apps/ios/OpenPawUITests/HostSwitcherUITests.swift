import XCTest

/// The compact terminal header and regular sidebar share one host control. These tests intentionally drive that
/// public surface instead of reaching into the model so a passive label, an implicit connection, or divergent
/// compact/regular actions is observable here.
final class HostSwitcherUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-openpaw.settings.biometricGate", "<false/>",
            "-openpaw-debug-scenario", scenario,
            "-openpaw-ui-test-steady-terminal-cursor",
        ]
        app.launch()
        return app
    }

    private func hostSwitcher(in app: XCUIApplication) -> XCUIElement {
        let switcher = app.buttons["host.switcher"]
        if !switcher.waitForExistence(timeout: 2) {
            let terminal = app.buttons["root.destination.terminal"]
            XCTAssertTrue(terminal.waitForExistence(timeout: 10))
            terminal.tap()
        }
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        return switcher
    }

    private func waitForValue(
        _ value: String,
        of element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed, file: file, line: line)
    }

    func testNoHostChipOpensAddDeviceInsteadOfSendingTheUserToPassiveSettingsCopy() {
        let app = launch("noHosts")
        let switcher = hostSwitcher(in: app)

        XCTAssertEqual(switcher.label, "No host")
        XCTAssertEqual(switcher.value as? String, "Add a device")
        switcher.tap()

        XCTAssertTrue(app.navigationBars["Add a device"].waitForExistence(timeout: 8))
    }

    func testSelectingADifferentHostConnectsImmediatelyAndConnectedHostsOfferBothActions() {
        let app = launch("hostSwitcher")
        let switcher = hostSwitcher(in: app)
        waitForValue("disconnected · SSH", of: switcher)

        switcher.tap()
        let buildServer = app.buttons["host.switcher.host.build-server"]
        XCTAssertTrue(buildServer.waitForExistence(timeout: 5))
        buildServer.tap()

        XCTAssertEqual(switcher.label, "Build server")
        waitForValue("connected · SSH", of: switcher)

        switcher.tap()
        XCTAssertTrue(app.buttons["host.switcher.disconnect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["host.switcher.reconnect"].exists)
        app.buttons["host.switcher.reconnect"].tap()
        waitForValue("connected · SSH", of: switcher)

        switcher.tap()
        XCTAssertTrue(app.buttons["host.switcher.disconnect"].waitForExistence(timeout: 5))
        app.buttons["host.switcher.disconnect"].tap()
        waitForValue("disconnected · SSH", of: switcher)
    }

    /// Run on both the newest phone and iPad simulator. The same identifier, label, value, and menu actions must be
    /// present whether the shared component is in the compact Terminal header or the regular sidebar.
    func testSharedHostControlPublishesOneStatusAndActionVocabularyAtEveryWidth() {
        let app = launch("hostSwitcher")
        let switcher = hostSwitcher(in: app)

        XCTAssertEqual(switcher.label, "Scenario host")
        waitForValue("disconnected · SSH", of: switcher)
        switcher.tap()
        XCTAssertTrue(app.buttons["host.switcher.connect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["host.switcher.add-device"].exists)
        XCTAssertTrue(app.buttons["host.switcher.manage-hosts"].exists)
        app.buttons["host.switcher.manage-hosts"].tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 8))
    }
}
