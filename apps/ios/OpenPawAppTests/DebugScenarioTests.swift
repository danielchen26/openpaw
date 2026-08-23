import OpenPawTerminalCore
import XCTest

@testable import OpenPawApp

@MainActor
final class DebugScenarioTests: XCTestCase {
    func testRecognisesEverySupportedScenarioFromLaunchArguments() {
        for scenario in DebugScenario.allCases {
            XCTAssertEqual(
                DebugScenario(arguments: ["OpenPaw", "-openpaw-debug-scenario", scenario.rawValue]),
                scenario
            )
        }
    }

    func testUnknownOrIncompleteScenarioFallsBackToProductionWiring() {
        XCTAssertNil(DebugScenario(arguments: ["OpenPaw", "-openpaw-debug-scenario", "unknown"]))
        XCTAssertNil(DebugScenario(arguments: ["OpenPaw", "-openpaw-debug-scenario"]))
        XCTAssertNil(
            DebugScenario(
                arguments: [
                    "OpenPaw", "-openpaw-debug-scenario", "connectedWorkspace",
                    "-openpaw-debug-scenario", "sessions",
                ]
            )
        )
    }

    func testConnectedWorkspaceSeedsOneSSHHostAndCoherentWorkspaceState() {
        let model = DebugScenario.connectedWorkspace.makeModel()

        XCTAssertEqual(model.hostStore.hosts.map(\.nickname), ["Scenario host"])
        XCTAssertEqual(model.selectedHostID, model.hostStore.hosts.first?.id)
        XCTAssertEqual(model.connection, .connected(.ssh))
        XCTAssertFalse(model.sessions.isEmpty)
        XCTAssertFalse(model.pendingInbox.isEmpty)
        XCTAssertFalse(model.repos.isEmpty)
        XCTAssertNotNil(model.selectedSessionID)
        XCTAssertNotNil(model.selectedRepo)
    }

    func testFailureScenarioUsesTypedDisconnectedState() {
        let model = DebugScenario.connectionFailures.makeModel()

        guard case .disconnected(let reason) = model.connection else {
            return XCTFail("expected a disconnected fixture")
        }
        XCTAssertEqual(reason, "the forwarded port closed")
        XCTAssertNotNil(model.lastError)
    }
}
