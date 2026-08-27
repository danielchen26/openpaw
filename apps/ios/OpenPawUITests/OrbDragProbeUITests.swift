import XCTest

/// Not a regression test: a probe that holds a real touch mid-gesture so an external screenshot can capture
/// the two-layer arc and the live preview card while the finger is still down.
final class OrbDragProbeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHoldAtSecondLayerShowsRingsAndLivePreview() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-openpaw-debug-scenario", "connectedWorkspace",
            "-openpaw.settings.biometricGate", "<false/>",
        ]
        app.launch()

        let orb = app.buttons["root.proactive-launcher.orb"]
        XCTAssertTrue(orb.waitForExistence(timeout: 15), "no orb. On screen:\n\(app.debugDescription)")

        let dismiss = app.alerts.buttons["Dismiss"]
        if dismiss.waitForExistence(timeout: 3) { dismiss.tap() }

        let window = app.windows.firstMatch
        let start = orb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Nearly straight up into the second ring band (>= 148pt). A 45-degree diagonal with two ring-2
        // children rounds to the Tools branch, which has no action and therefore cancels on release; the
        // near-vertical angle deterministically selects slot 0, a window node with an attach action, so the
        // live preview card appears during the hold and the release freezes.
        let frame = window.frame
        let target = window.coordinate(withNormalizedOffset: CGVector(
            dx: (orb.frame.midX - 20) / frame.width,
            dy: (orb.frame.midY - 210) / frame.height
        ))
        // Slow drag, then hold at the second layer for four seconds: the external screenshot lands here.
        start.press(forDuration: 0.3, thenDragTo: target, withVelocity: 200, thenHoldForDuration: 4.0)

        // After release the selection freezes: the preview card must remain with its confirm affordance.
        let confirm = app.buttons["root.proactive-launcher.confirm"]
        let destructive = app.buttons["root.proactive-launcher.destructive-confirm"]
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 3) || destructive.exists,
            "releasing on the second layer did not freeze a preview. On screen:\n\(app.debugDescription)"
        )
    }
}
