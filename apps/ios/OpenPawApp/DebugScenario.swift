#if DEBUG && targetEnvironment(simulator)
    import Foundation
    import OpenPawProtocol
    import OpenPawTerminalCore
    import OpenPawUI

    /// Simulator-only launch fixtures for deterministic UI and integration tests.
    ///
    /// Unknown, missing, or duplicated arguments return `nil`, which leaves `AppWiring` on its production path.
    enum DebugScenario: String, CaseIterable, Equatable {
        case empty
        case connectedWorkspace
        case sessions
        case inboxRisks
        case repoProviders
        case connectionFailures

        private static let launchFlag = "-openpaw-debug-scenario"
        private static let hostID = UUID(uuidString: "51CE0000-0000-4000-8000-000000000001") ?? UUID()

        init?(arguments: [String]) {
            let flagIndices = arguments.indices.filter { arguments[$0] == Self.launchFlag }
            guard flagIndices.count == 1,
                let flagIndex = flagIndices.first
            else { return nil }
            let valueIndex = arguments.index(after: flagIndex)
            guard valueIndex < arguments.endIndex,
                let scenario = Self(rawValue: arguments[valueIndex])
            else { return nil }
            self = scenario
        }

        @MainActor
        func makeModel(terminal: (any TerminalBackend)? = nil) -> OpenPawModel {
            let backend = PreviewBackend(previewScenario)
            let host = HostRecord(
                id: Self.hostID,
                nickname: "Scenario host",
                hostname: "scenario-host.invalid",
                port: 22,
                username: "openpaw",
                auth: .agentForwarding,
                preferredTransport: .ssh,
                lastSuccessfulTransport: .ssh,
                multiplexerPreference: .tmux,
                tags: ["fixture"]
            )
            let model = OpenPawModel(
                hostStore: HostStore(hosts: [host]),
                backend: backend,
                terminal: terminal
            )
            model.health = backend.healthInfo
            model.sessions = backend.sessionList
            model.inbox = backend.inboxItems
            model.repos = backend.repoList
            for session in backend.sessionList {
                for event in backend.events(for: session.sessionID) {
                    model.ingest(event)
                }
            }
            model.selectedSessionID = backend.sessionList.first?.sessionID
            model.selectedRepo = backend.repoList.first?.name

            switch self {
            case .connectionFailures:
                model.connection = .disconnected(reason: "the forwarded port closed")
                model.present(
                    HostClientError.transport(PreviewBackend.TunnelClosed()),
                    while: "loading host state"
                )
            case .empty, .connectedWorkspace, .sessions, .inboxRisks, .repoProviders:
                model.connection = .connected(.ssh)
            }
            return model
        }

        private var previewScenario: PreviewBackend.Scenario {
            switch self {
            case .empty:
                .empty
            case .connectedWorkspace, .sessions, .repoProviders:
                .populated
            case .inboxRisks:
                .reviewingDestructiveCommand
            case .connectionFailures:
                .disconnected
            }
        }
    }
#endif
