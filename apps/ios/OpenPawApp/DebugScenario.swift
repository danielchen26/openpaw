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
        case noHosts
        case hostSwitcher
        case connectedWorkspace
        case sessions
        case inboxRisks
        case repoProviders
        case connectionFailures

        private static let launchFlag = "-openpaw-debug-scenario"
        private static let hostID = UUID(uuidString: "51CE0000-0000-4000-8000-000000000001") ?? UUID()
        private static let buildHostID = UUID(uuidString: "51CE0000-0000-4000-8000-000000000002") ?? UUID()

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
            let buildHost = HostRecord(
                id: Self.buildHostID,
                nickname: "Build server",
                hostname: "build-server.invalid",
                port: 22,
                username: "openpaw",
                auth: .agentForwarding,
                preferredTransport: .ssh,
                multiplexerPreference: .tmux,
                tags: ["fixture", "build"]
            )
            let hosts: [HostRecord] = switch self {
            case .noHosts: []
            case .hostSwitcher: [host, buildHost]
            case .empty, .connectedWorkspace, .sessions, .inboxRisks, .repoProviders, .connectionFailures: [host]
            }
            let modelTerminal: (any TerminalBackend)? = self == .hostSwitcher
                ? DebugScenarioTerminalBackend()
                : terminal
            let model = OpenPawModel(
                hostStore: HostStore(hosts: hosts),
                backend: backend,
                terminal: modelTerminal,
                tailscaleRouteHintSource: DebugTailscaleRoutePathSource(),
                tailscaleAdminConnector: DebugTailscaleAdminConnector(),
                connectionPreflightRunner: DebugConnectionPreflightRunner()
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
            case .noHosts:
                model.connection = .idle
            case .hostSwitcher:
                model.connection = .disconnected(reason: nil)
            case .empty, .connectedWorkspace, .sessions, .inboxRisks, .repoProviders:
                model.connection = .connected(.ssh)
            }
            return model
        }

        private var previewScenario: PreviewBackend.Scenario {
            switch self {
            case .empty, .noHosts, .hostSwitcher:
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

    /// A simulator-only terminal that makes connection actions observable without dialing a network endpoint.
    private final class DebugScenarioTerminalBackend: TerminalBackend, @unchecked Sendable {
        private let stateContinuation: AsyncStream<ConnectionState>.Continuation
        let stateStream: AsyncStream<ConnectionState>
        let outputStream = AsyncStream<Data> { $0.finish() }

        init() {
            var continuation: AsyncStream<ConnectionState>.Continuation!
            stateStream = AsyncStream { continuation = $0 }
            stateContinuation = continuation
        }

        func connect(host: HostRecord) async throws { stateContinuation.yield(.connected(.ssh)) }
        func disconnect() async { stateContinuation.yield(.disconnected(reason: nil)) }
        func send(text: String) async throws {}
        func send(chord: KeyChord, applicationCursorKeys: Bool) async throws {}
        func resize(columns: Int, rows: Int) async throws {}
        func run(command: String) async throws -> String { "" }
    }

    private struct DebugTailscaleRoutePathSource: TailscaleRoutePathSourcing {
        func currentSnapshot() async -> TailscaleRoutePathSnapshot {
            TailscaleRoutePathSnapshot(isSatisfied: true, interfaceNames: ["utun7"])
        }
    }

    private actor DebugTailscaleAdminConnector: TailscaleAdminConnecting {
        private var connected = false

        func connect(_ credentials: TailscaleAdminCredentials) async throws {
            guard credentials.validationIssues.isEmpty else { throw DebugFixtureError.invalidCredentials }
            connected = true
        }

        func fetchSavedDevices() async throws -> [TailscaleAdminDeviceCandidate] {
            guard connected else { throw DebugFixtureError.missingCredentials }
            return [
                TailscaleAdminDeviceCandidate(
                    id: "debug-admin-device",
                    name: "admin-mac.example.ts.net",
                    hostname: "admin-mac",
                    addresses: ["100.64.0.44"],
                    os: "macOS",
                    user: "operator",
                    isOnline: true
                )
            ]
        }

        func disconnectAndDeleteCredentials() async throws { connected = false }
    }

    private struct DebugConnectionPreflightRunner: ConnectionPreflightRunning {
        func run(for host: HostRecord) async -> ConnectionPreflightReport {
            var report = ConnectionPreflightReport()
            report.passCurrentStage(summary: "SSH route reached")
            report.passCurrentStage(summary: "Pinned host key accepted")
            report.passCurrentStage(summary: "SSH authentication succeeded")
            report.passCurrentStage(summary: "OpenPaw host API is reachable")
            if let multiplexer = host.multiplexerPreference {
                report.passCurrentStage(summary: "\(multiplexer.displayName) available")
            } else {
                report.skipCurrentStage(reason: "No multiplexer selected")
            }
            report.passCurrentStage(summary: "SSH connected")
            return report
        }
    }

    private enum DebugFixtureError: Error {
        case invalidCredentials
        case missingCredentials
    }
#endif
