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
        case quickPairing

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
        func makeModel(
            terminal: (any TerminalBackend)? = nil,
            settings: OpenPawSettings,
            dictationModels: any DictationModelInstalling = UnavailableDictationModelStore(),
            dictationEngineFactory: (any DictationEngineMaking)? = nil
        ) -> OpenPawModel {
            if self == .quickPairing {
                return makeQuickPairingModel(
                    settings: settings,
                    dictationModels: dictationModels,
                    dictationEngineFactory: dictationEngineFactory
                )
            }
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
            case .empty, .connectedWorkspace, .sessions, .inboxRisks, .repoProviders, .connectionFailures, .quickPairing: [host]
            }
            let modelTerminal: (any TerminalBackend)? = self == .hostSwitcher
                ? DebugScenarioTerminalBackend()
                : terminal
            let model = OpenPawModel(
                hostStore: HostStore(hosts: hosts),
                backend: backend,
                terminal: modelTerminal,
                dictationModels: dictationModels,
                dictationEngineFactory: dictationEngineFactory,
                tailscaleRouteHintSource: DebugTailscaleRoutePathSource(),
                tailscaleAdminConnector: DebugTailscaleAdminConnector(),
                connectionPreflightRunner: DebugConnectionPreflightRunner(),
                settings: settings
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
            case .empty, .connectedWorkspace, .sessions, .inboxRisks, .repoProviders, .quickPairing:
                model.connection = .connected(.ssh)
            }
            return model
        }

        private var previewScenario: PreviewBackend.Scenario {
            switch self {
            case .empty, .noHosts, .hostSwitcher, .quickPairing:
                .empty
            case .connectedWorkspace, .sessions:
                .populated
            case .repoProviders:
                .repoProviders
            case .inboxRisks:
                .reviewingDestructiveCommand
            case .connectionFailures:
                .disconnected
            }
        }

        @MainActor
        private func makeQuickPairingModel(
            settings: OpenPawSettings,
            dictationModels: any DictationModelInstalling,
            dictationEngineFactory: (any DictationEngineMaking)?
        ) -> OpenPawModel {
            let credentialReference = try? KeychainReference(identifier: "quick-pairing-existing-key")
            let auth = credentialReference.map { AuthMethod.privateKey(reference: $0, passphraseRef: nil) }
                ?? .agentForwarding
            let savedHost = HostRecord(
                id: Self.hostID,
                nickname: "MacBook Pro credential",
                hostname: DebugQuickPairingFixture.target,
                port: 22,
                username: DebugQuickPairingFixture.username,
                auth: auth,
                preferredTransport: .ssh,
                lastSuccessfulTransport: .ssh,
                multiplexerPreference: .tmux,
                knownHosts: [
                    KnownHostEntry(
                        keyType: "ssh-ed25519",
                        fingerprint: DebugQuickPairingFixture.fingerprint,
                        addedAt: PreviewBackend.now)
                ],
                tags: ["fixture", "quick-pairing"])
            let backend = DebugQuickPairingBackend()
            let model = OpenPawModel(
                hostStore: HostStore(hosts: [savedHost]),
                backend: backend,
                terminal: DebugQuickPairingTerminalBackend(),
                dictationModels: dictationModels,
                dictationEngineFactory: dictationEngineFactory,
                tailscaleRouteHintSource: DebugTailscaleRoutePathSource(),
                tailscaleAdminConnector: DebugQuickPairingCandidateSource(),
                settings: settings)
            model.connection = .disconnected(reason: nil)
            return model
        }
    }

    private enum DebugQuickPairingFixture {
        static let target = "macbook-pro.tailnet.example"
        static let username = "openpaw"
        static let fingerprint = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

        static func delay(seconds: TimeInterval) async {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
            }
        }
    }

    private actor DebugQuickPairingCandidateSource: TailscaleAdminConnecting {
        func connect(_ credentials: TailscaleAdminCredentials) async throws {}

        func fetchSavedDevices() async throws -> [TailscaleAdminDeviceCandidate] {
            [
                TailscaleAdminDeviceCandidate(
                    id: "debug-quick-pairing-macbook-pro",
                    name: DebugQuickPairingFixture.target,
                    hostname: "MacBook Pro",
                    addresses: ["100.64.0.42"],
                    os: "macOS",
                    user: DebugQuickPairingFixture.username,
                    isOnline: true)
            ]
        }

        func disconnectAndDeleteCredentials() async throws {}
    }

    /// Ignores cancellation deliberately so the two-proposal UI test receives a real late completion to reject.
    private final class DebugQuickPairingTerminalBackend: TerminalBackend, @unchecked Sendable {
        private let stateContinuation: AsyncStream<ConnectionState>.Continuation
        let stateStream: AsyncStream<ConnectionState>
        let outputStream = AsyncStream<Data> { _ in }

        init() {
            var continuation: AsyncStream<ConnectionState>.Continuation!
            stateStream = AsyncStream { continuation = $0 }
            stateContinuation = continuation
        }

        func connect(host: HostRecord) async throws {
            await DebugQuickPairingFixture.delay(seconds: host.nickname == "Delayed Mac" ? 6 : 2)
            stateContinuation.yield(.connected(.ssh))
        }

        func disconnect() async { stateContinuation.yield(.disconnected(reason: nil)) }
        func send(text: String) async throws {}
        func send(chord: KeyChord, applicationCursorKeys: Bool) async throws {}
        func resize(columns: Int, rows: Int) async throws {}
        func run(command: String) async throws -> String { "" }
    }

    private final class DebugQuickPairingBackend: OpenPawBackend, StructuredBackendLifecycle, OpenPawHostPairing, @unchecked Sendable {
        private let preview = PreviewBackend(.empty)
        private let lock = NSLock()
        private var ready = false

        var isReady: Bool { get async { lock.withLock { ready } } }

        func connect(hostID: HostRecord.ID) async throws {
            await DebugQuickPairingFixture.delay(seconds: 0.35)
            lock.withLock { ready = true }
        }

        func disconnect() async { lock.withLock { ready = false } }

        func pair(pairingCode: String, deviceName: String) async throws -> PairingResult {
            await DebugQuickPairingFixture.delay(seconds: 8)
            return PairingResult(deviceID: deviceName, token: "", hmacKeyB64: "", capabilities: [])
        }

        func health() async throws -> HealthInfo { try await preview.health() }
        func sessions() async throws -> [SessionSummary] { try await preview.sessions() }
        func inbox(status: InboxStatus?) async throws -> [InboxItem] { try await preview.inbox(status: status) }
        func resolve(item: InboxItem, action: ActionID, answer: String?, detailAcknowledged: Bool) async throws -> ResolveResult {
            try await preview.resolve(item: item, action: action, answer: answer, detailAcknowledged: detailAcknowledged)
        }
        func events(session: String?, afterSeq: UInt64?) -> AsyncThrowingStream<Event, any Error> {
            preview.events(session: session, afterSeq: afterSeq)
        }
        func repos() async throws -> [RepoSummary] { try await preview.repos() }
        func repoStatus(_ repo: String) async throws -> RepoStatus { try await preview.repoStatus(repo) }
        func diff(repo: String, mode: DiffMode, path: String?) async throws -> Diff { try await preview.diff(repo: repo, mode: mode, path: path) }
        func tree(repo: String, ref: String, path: String) async throws -> [TreeEntry] { try await preview.tree(repo: repo, ref: ref, path: path) }
        func blob(repo: String, ref: String, path: String) async throws -> Blob { try await preview.blob(repo: repo, ref: ref, path: path) }
        func search(repo: String, query: String, path: String?) async throws -> [ContentMatch] { try await preview.search(repo: repo, query: query, path: path) }
        func upload(data: Data, filename: String) async throws -> UploadResult { try await preview.upload(data: data, filename: filename) }
        func previewURL(port: Int, path: String) throws -> URL { try preview.previewURL(port: port, path: path) }
        func tailscaleDevices() async throws -> TailscaleDevicesResponse { try await preview.tailscaleDevices() }
        func audit(limit: Int) async throws -> [AuditEntry] { try await preview.audit(limit: limit) }
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
