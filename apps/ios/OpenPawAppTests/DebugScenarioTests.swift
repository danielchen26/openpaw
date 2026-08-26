#if DEBUG && targetEnvironment(simulator)
    import Foundation
    import OpenPawTerminalCore
    import OpenPawUI
    import XCTest

    @testable import OpenPawApp

    @MainActor
    final class DebugScenarioTests: XCTestCase {
    func testRecognisesEverySupportedScenarioFromLaunchArguments() {
        for scenario in DebugScenario.allCases {
            XCTAssertEqual(DebugScenario(arguments: ["OpenPaw", "-openpaw-debug-scenario", scenario.rawValue]), scenario)
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
        let model = scenarioModel(.connectedWorkspace, settingsName: "connected")

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
        let model = scenarioModel(.connectionFailures, settingsName: "failure")

        guard case .disconnected(let reason) = model.connection else {
            return XCTFail("expected a disconnected fixture")
        }
        XCTAssertEqual(reason, "the forwarded port closed")
        XCTAssertNotNil(model.lastError)
    }

    func testNoHostsScenarioContainsNoSavedOrSelectedHost() {
        let model = scenarioModel(.noHosts, settingsName: "no-hosts")

        XCTAssertTrue(model.hostStore.hosts.isEmpty)
        XCTAssertNil(model.selectedHostID)
        XCTAssertEqual(model.connection, .idle)
    }

    func testHostSwitcherScenarioSelectsWithoutConnectingAndConnectsOnlyOnRequest() async throws {
        let model = scenarioModel(.hostSwitcher, settingsName: "switcher")
        let second = try XCTUnwrap(model.hostStore.hosts.last)

        XCTAssertEqual(model.hostStore.hosts.map(\.nickname), ["Scenario host", "Build server"])
        XCTAssertEqual(model.connection, .disconnected(reason: nil))

        await model.selectHost(second.id)
        XCTAssertEqual(model.selectedHostID, second.id)
        XCTAssertFalse(model.connection.isConnected)

        await model.connectSelectedHost()
        XCTAssertEqual(model.connection, .connected(.ssh))
    }

    func testScenarioModelUsesInjectedSettingsInstance() {
        let settings = isolatedSettings("shared-settings")
        settings.eventBudgetPerSession = 321

        let model = scenarioModel(.connectedWorkspace, settings: settings)

        XCTAssertEqual(model.eventBudgetPerSession, 321)
        model.eventBudgetPerSession = 654
        XCTAssertEqual(settings.eventBudgetPerSession, 654)
    }

    private func isolatedSettings(_ name: String) -> OpenPawSettings {
        let suite = "DebugScenarioTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return OpenPawSettings(defaults: defaults)
    }

    private func scenarioModel(
        _ scenario: DebugScenario,
        settingsName: String
    ) -> OpenPawModel {
        scenarioModel(scenario, settings: isolatedSettings(settingsName))
    }

    private func scenarioModel(
        _ scenario: DebugScenario,
        settings: OpenPawSettings
    ) -> OpenPawModel {
        scenario.makeModel(
            settings: settings,
            dictationModels: UnavailableDictationModelStore(),
            dictationEngineFactory: nil
        )
    }
    }
#endif
