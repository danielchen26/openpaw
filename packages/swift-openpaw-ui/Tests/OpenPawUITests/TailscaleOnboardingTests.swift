import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import OpenPawUI
import Testing

private struct StaticRoutePathSource: TailscaleRoutePathSourcing {
    var snapshot: TailscaleRoutePathSnapshot

    func currentSnapshot() async -> TailscaleRoutePathSnapshot { snapshot }
}

@Suite("Tailscale route hint")
struct TailscaleRouteHintTests {
    @Test("A utun path is only a likely route hint")
    func utunIsLikelyAvailable() async {
        let source = StaticRoutePathSource(
            snapshot: TailscaleRoutePathSnapshot(isSatisfied: true, interfaceNames: ["en0", "utun7"])
        )

        #expect(await TailscaleRouteHintResolver(source: source).currentHint() == .likelyAvailable)
    }

    @Test("A Tailscale CGNAT address is only a likely route hint")
    func tailscaleAddressIsLikelyAvailable() async {
        let source = StaticRoutePathSource(
            snapshot: TailscaleRoutePathSnapshot(
                isSatisfied: true,
                interfaceNames: ["en0"],
                addresses: ["100.100.10.20"]
            )
        )

        #expect(await TailscaleRouteHintResolver(source: source).currentHint() == .likelyAvailable)
    }

    @Test("Ordinary or unsatisfied paths do not imply Tailscale")
    func ordinaryPathIsNotDetected() async {
        let ordinary = StaticRoutePathSource(
            snapshot: TailscaleRoutePathSnapshot(
                isSatisfied: true,
                interfaceNames: ["en0"],
                addresses: ["192.168.1.8"]
            )
        )
        let unavailable = StaticRoutePathSource(
            snapshot: TailscaleRoutePathSnapshot(isSatisfied: false, interfaceNames: ["utun3"])
        )

        #expect(await TailscaleRouteHintResolver(source: ordinary).currentHint() == .notDetected)
        #expect(await TailscaleRouteHintResolver(source: unavailable).currentHint() == .notDetected)
    }
}

@Suite("Advanced Tailscale administrator onboarding")
struct TailscaleAdministratorOnboardingTests {
    @Test("The advanced path is clearly an administrator workflow, never normal Tailscale login")
    func truthfulCopy() {
        #expect(AddDeviceFlowCopy.entryActions == [
            "Tailscale devices",
            "Enter SSH details manually",
            "Authorize with Tailnet administrator credentials",
        ])
        #expect(AddDeviceFlowCopy.adminRequirement.contains("Tailnet administrator credentials required"))
        #expect(!AddDeviceFlowCopy.onboardingCopy.joined(separator: " ").localizedCaseInsensitiveContains("Sign in with Tailscale"))
    }

    @Test("Active iPhone Tailscale without a connected host explains the iOS account boundary and next actions")
    func activeRouteWithoutDiscoveryHostCopy() {
        #expect(AddDeviceFlowCopy.activeRouteNoHostTitle == "A Tailscale-compatible route may be active")
        #expect(AddDeviceFlowCopy.activeRouteNoHostExplanation.contains("VPN-style route that may be Tailscale"))
        #expect(AddDeviceFlowCopy.activeRouteNoHostExplanation.contains("iOS does not share the signed-in Tailscale account or device list with OpenPaw"))
        #expect(AddDeviceFlowCopy.activeRouteNoHostExplanation.contains("connected OpenPaw host"))
        #expect(AddDeviceFlowCopy.adminAction == "Authorize with Tailnet administrator credentials")
        #expect(AddDeviceFlowCopy.sshAction == "Enter SSH details manually")

        let copy = AddDeviceFlowCopy.onboardingCopy.joined(separator: " ")
        #expect(!copy.localizedCaseInsensitiveContains("Sign in with Tailscale"))
        #expect(!copy.localizedCaseInsensitiveContains("reads account"))
    }

    @Test("Active route no-host actions enter administrator authorization or manual SSH")
    func activeRouteNoHostNavigation() {
        var state = AddDeviceFlowState(hosts: [])
        state.startTailscaleDiscovery()

        state.startTailscaleAdministrator()
        #expect(state.step == .tailscaleAdministrator)
        state.back()
        #expect(state.step == .welcome)

        state.startTailscaleDiscovery()
        _ = state.startManualSSH()
        #expect(state.step == .editDetails)
        state.back()
        #expect(state.step == .tailscaleCandidates)
    }

    @Test("Administrator credentials validate identifiers without ever echoing the secret")
    func credentialValidation() {
        let empty = TailscaleAdminCredentials(clientID: " ", clientSecret: "super-secret", tailnet: "")
        #expect(empty.validationIssues == [.missingClientID, .missingTailnet])
        #expect(!empty.validationIssues.description.contains("super-secret"))

        let ambiguous = TailscaleAdminCredentials(clientID: "client:other", clientSecret: "secret", tailnet: "tail/net")
        #expect(ambiguous.validationIssues == [.invalidClientID, .invalidTailnet])

        let valid = TailscaleAdminCredentials(clientID: "k123", clientSecret: "secret", tailnet: "example.ts.net")
        #expect(valid.validationIssues.isEmpty)
    }

    @Test("Candidate navigation returns to the administrator list that owns it")
    func adminCandidateBackNavigation() {
        let candidate = AddDeviceCandidate(
            id: "admin-node",
            nickname: "Remote Mac",
            hostname: "remote.tailnet.example",
            source: .tailscaleAdministrator
        )
        var state = AddDeviceFlowState(hosts: [])

        state.startTailscaleAdministrator()
        state.selectCandidate(id: candidate.id, from: [candidate])
        #expect(state.step == .confirmCandidate)

        state.back()
        #expect(state.step == .tailscaleAdministrator)
    }

    @MainActor
    @Test("Connecting the administrator source stores credentials explicitly, loads candidates, and never saves a host")
    func explicitConnectionLoadsCandidatesWithoutSavingHost() async {
        let connector = RecordingTailscaleAdminConnector()
        await connector.setDevices([Self.adminDevice])
        let existing = HostRecord(
            nickname: "Existing",
            hostname: "existing.example",
            username: "operator",
            auth: .agentForwarding
        )
        let model = OpenPawModel(
            hostStore: HostStore(hosts: [existing]),
            tailscaleAdminConnector: connector
        )

        await model.connectTailscaleAdministrator(
            credentials: .init(clientID: "  client-id  ", clientSecret: "secret", tailnet: " example.ts.net ")
        )

        #expect(await connector.connectedCredentials == [
            .init(clientID: "client-id", clientSecret: "secret", tailnet: "example.ts.net")
        ])
        #expect(model.tailscaleAdminConnection == .candidates([Self.adminDevice]))
        #expect(model.hostStore.hosts == [existing])
    }

    @MainActor
    @Test("Invalid administrator credentials fail locally without touching Keychain or the network")
    func invalidCredentialsFailLocally() async {
        let connector = RecordingTailscaleAdminConnector()
        let model = OpenPawModel(tailscaleAdminConnector: connector)

        await model.connectTailscaleAdministrator(
            credentials: .init(clientID: "client:other", clientSecret: "secret", tailnet: "tail/net")
        )

        #expect(await connector.connectedCredentials.isEmpty)
        guard case .failure(let message) = model.tailscaleAdminConnection else {
            Issue.record("expected a typed local validation failure")
            return
        }
        #expect(message.contains("Client ID"))
        #expect(message.contains("tailnet"))
        #expect(!message.contains("secret"))
    }

    @MainActor
    @Test("Disconnect invalidates a suspended administrator discovery result and deletes credentials")
    func disconnectOwnsTheVisibleResult() async {
        let connector = RecordingTailscaleAdminConnector()
        await connector.setDevices([Self.adminDevice])
        await connector.setSuspended(true)
        let model = OpenPawModel(tailscaleAdminConnector: connector)

        let connection = Task {
            await model.connectTailscaleAdministrator(
                credentials: .init(clientID: "client", clientSecret: "secret", tailnet: "example.ts.net")
            )
        }
        await connector.waitUntilFetchStarted()
        await model.disconnectTailscaleAdministrator()
        await connector.resume()
        await connection.value

        #expect(model.tailscaleAdminConnection == .disconnected)
        #expect(await connector.deleteCount == 1)
    }

    private static let adminDevice = TailscaleAdminDeviceCandidate(
        id: "admin-node",
        name: "remote.example.ts.net",
        hostname: "remote",
        addresses: ["100.64.0.9"],
        os: "macOS",
        user: "operator",
        isOnline: true
    )
}

@Suite("Typed connection preflight")
struct ConnectionPreflightTests {
    @Test("The production stages have one stable security order")
    func stageOrder() {
        #expect(ConnectionPreflightStage.allCases == [
            .route,
            .hostKey,
            .authentication,
            .openPawHealth,
            .multiplexer,
            .transportCapabilities,
        ])
    }

    @Test("A report advances one typed stage at a time")
    func typedProgression() {
        var report = ConnectionPreflightReport()
        #expect(report.currentStage == .route)

        report.beginCurrentStage()
        #expect(report[.route] == .running)
        report.passCurrentStage(summary: "Route is reachable")
        #expect(report[.route] == .passed(summary: "Route is reachable"))
        #expect(report.currentStage == .hostKey)

        report.skipCurrentStage(reason: "Already pinned")
        #expect(report[.hostKey] == .skipped(reason: "Already pinned"))
        #expect(report.currentStage == .authentication)
    }

    @Test("A typed failure blocks every later stage")
    func failureBlocksLaterStages() {
        var report = ConnectionPreflightReport()
        report.passCurrentStage(summary: nil)
        report.passCurrentStage(summary: "Pinned key matches")
        report.failCurrentStage(.authenticationRejected)

        #expect(report[.authentication] == .failed(.authenticationRejected))
        #expect(report[.openPawHealth] == .blocked)
        #expect(report[.multiplexer] == .blocked)
        #expect(report[.transportCapabilities] == .blocked)
        #expect(report.currentStage == nil)
        #expect(report.didFail)
    }

    @Test("The production picker exposes only compiled and legally available transports")
    func selectableTransportsAreTruthful() {
        #expect(TransportAvailability.selectable == [.ssh])
        #expect(!TransportAvailability.selectable.contains(.mosh))
        #expect(!TransportAvailability.selectable.contains(.eternalTerminal))
    }

    @MainActor
    @Test("The model publishes the typed report for the exact proposed host")
    func modelRunsTypedPreflight() async {
        var expected = ConnectionPreflightReport()
        for _ in ConnectionPreflightStage.allCases {
            expected.passCurrentStage(summary: "passed")
        }
        let runner = RecordingConnectionPreflightRunner(reports: [expected])
        let model = OpenPawModel(connectionPreflightRunner: runner)
        let host = HostRecord(
            nickname: "Candidate",
            hostname: "candidate.example",
            username: "operator",
            auth: .agentForwarding
        )

        await model.runConnectionPreflight(for: host)

        #expect(await runner.hosts == [host])
        #expect(model.connectionPreflightReport == expected)
        #expect(!model.isConnectionPreflightRunning)
    }

    @MainActor
    @Test("A newer preflight owns the visible report")
    func newerPreflightOwnsVisibleReport() async {
        var stale = ConnectionPreflightReport()
        stale.failCurrentStage(.routeUnavailable)
        var latest = ConnectionPreflightReport()
        latest.passCurrentStage(summary: "new route")
        let runner = RecordingConnectionPreflightRunner(reports: [stale, latest], suspendFirst: true)
        let model = OpenPawModel(connectionPreflightRunner: runner)
        let first = HostRecord(nickname: "A", hostname: "a.example", username: "operator", auth: .agentForwarding)
        let second = HostRecord(nickname: "B", hostname: "b.example", username: "operator", auth: .agentForwarding)

        let firstTask = Task { await model.runConnectionPreflight(for: first) }
        await runner.waitUntilFirstStarted()
        await model.runConnectionPreflight(for: second)
        await runner.resumeFirst()
        await firstTask.value

        #expect(model.connectionPreflightReport == latest)
    }

    @Test("The executor uses only fixed typed probes and completes every stage in order")
    func executorUsesFixedTypedProbes() async {
        let terminal = PreflightTerminal()
        let backend = PreflightBackend()
        let host = HostRecord(
            nickname: "Candidate",
            hostname: "candidate.example",
            username: "operator",
            auth: .agentForwarding,
            preferredTransport: .ssh,
            multiplexerPreference: .tmux
        )
        let report = await TypedConnectionPreflightRunner(
            terminal: terminal,
            capabilities: terminal,
            backend: backend
        ).run(for: host)

        #expect(report[.route] == .passed(summary: "SSH route reached"))
        #expect(report[.hostKey] == .passed(summary: "Pinned host key accepted"))
        #expect(report[.authentication] == .passed(summary: "SSH authentication succeeded"))
        #expect(report[.openPawHealth] == .passed(summary: "OpenPaw host API is reachable"))
        #expect(report[.multiplexer] == .passed(summary: "tmux 3.5"))
        #expect(report[.transportCapabilities] == .passed(summary: "SSH connected"))
        #expect(await terminal.probes == [.multiplexer(.tmux), .transport(.ssh)])
    }

    @Test("Authentication rejection preserves the passed route and host-key stages")
    func authenticationFailureIsTyped() async {
        let terminal = PreflightTerminal(connectError: TransportError.authenticationFailed(reason: "denied"))
        let report = await TypedConnectionPreflightRunner(
            terminal: terminal,
            capabilities: terminal,
            backend: PreflightBackend()
        ).run(for: HostRecord(nickname: "Candidate", hostname: "candidate.example", username: "operator", auth: .agentForwarding))

        #expect(report[.route] == .passed(summary: "SSH route reached"))
        #expect(report[.hostKey] == .passed(summary: "Pinned host key accepted"))
        #expect(report[.authentication] == .failed(.authenticationRejected))
        #expect(report[.openPawHealth] == .blocked)
    }

    @Test("A missing OpenPaw daemon does not hide that SSH itself succeeded")
    func openPawFailureBlocksOnlyLaterCapabilities() async {
        let terminal = PreflightTerminal()
        let backend = PreflightBackend(healthError: OnboardingBackendError.unexpected)
        let report = await TypedConnectionPreflightRunner(
            terminal: terminal,
            capabilities: terminal,
            backend: backend
        ).run(for: HostRecord(nickname: "Candidate", hostname: "candidate.example", username: "operator", auth: .agentForwarding))

        #expect(report[.authentication] == .passed(summary: "SSH authentication succeeded"))
        #expect(report[.openPawHealth] == .failed(.openPawUnavailable))
        #expect(report[.multiplexer] == .blocked)
        #expect(report[.transportCapabilities] == .blocked)
    }
}

@Suite("Flow-owned Tailscale discovery")
struct FlowOwnedTailscaleDiscoveryTests {
    private let host = HostRecord(
        nickname: "Workshop",
        hostname: "workshop.tailnet.example",
        username: "operator",
        auth: .agentForwarding
    )
    private let now = Date(timeIntervalSince1970: 1_787_479_800)

    @MainActor
    @Test("Opening one Add Device flow refreshes once and Retry owns the next request")
    func oncePerFlowEntryAndExplicitRetry() async {
        let backend = TailscaleOnboardingBackend()
        backend.response = TailscaleDevicesResponse(version: 1, candidates: [Self.candidate])
        let model = connectedModel(backend: backend)
        let owner = TailscaleDiscoveryFlowID()

        model.beginTailscaleDiscovery(owner: owner)
        model.beginTailscaleDiscovery(owner: owner)
        await waitForCallCount(1, backend: backend)
        await waitUntil { model.tailscaleDiscovery.candidates.count == 1 }

        #expect(backend.callCount == 1)
        #expect(model.hostStore.hosts == [host], "discovery must never auto-save candidates")
        #expect(
            model.tailscaleDiscoveryMetadata
                == TailscaleDiscoveryMetadata(
                    source: .pairedHost(id: host.id, displayName: host.nickname),
                    routeHint: .likelyAvailable,
                    refreshedAt: now
                )
        )

        model.retryTailscaleDiscovery(owner: owner)
        await waitForCallCount(2, backend: backend)

        #expect(backend.callCount == 2)
    }

    @MainActor
    @Test("A new flow entry receives a fresh request after the prior owner ends")
    func newFlowEntryRefreshesAgain() async {
        let backend = TailscaleOnboardingBackend()
        let model = connectedModel(backend: backend)
        let first = TailscaleDiscoveryFlowID()
        let second = TailscaleDiscoveryFlowID()

        model.beginTailscaleDiscovery(owner: first)
        await waitForCallCount(1, backend: backend)
        model.endTailscaleDiscovery(owner: first)
        model.beginTailscaleDiscovery(owner: second)
        await waitForCallCount(2, backend: backend)

        #expect(backend.callCount == 2)
    }

    @MainActor
    @Test("Changing hosts cancels the old owner's result")
    func hostChangeSuppressesStaleResult() async {
        let backend = TailscaleOnboardingBackend()
        backend.response = TailscaleDevicesResponse(version: 1, candidates: [Self.candidate])
        backend.isSuspended = true
        let second = HostRecord(
            nickname: "Build",
            hostname: "build.tailnet.example",
            username: "operator",
            auth: .agentForwarding
        )
        let model = connectedModel(backend: backend, additionalHosts: [second])
        let owner = TailscaleDiscoveryFlowID()

        model.beginTailscaleDiscovery(owner: owner)
        await backend.waitUntilStarted()
        model.selectedHostID = second.id
        backend.resume()
        await Task.yield()

        #expect(model.tailscaleDiscovery == .idle)
        #expect(model.tailscaleDiscoveryMetadata == nil)
        #expect(model.hostStore.hosts.count == 2)
    }

    @MainActor
    @Test("Missing discovery permission is an explicit recoverable state")
    func permissionDeniedIsTyped() async {
        let backend = TailscaleOnboardingBackend()
        backend.error = HostClientError.forbidden(capability: "devices.read")
        let model = connectedModel(backend: backend)
        let owner = TailscaleDiscoveryFlowID()

        model.beginTailscaleDiscovery(owner: owner)
        await waitUntil {
            if case .permissionDenied = model.tailscaleDiscovery { return true }
            return false
        }

        #expect(
            model.tailscaleDiscovery
                == .permissionDenied(
                    message: "The paired discovery host is missing devices.read. Re-pair it with an operator profile, then Retry."
                )
        )
    }

    @MainActor
    @Test("A known missing devices.read grant fails locally before discovery reaches the host")
    func knownMissingCapabilityFailsClosed() async {
        let backend = TailscaleOnboardingBackend()
        backend.capabilityStatus = .denied
        let model = connectedModel(backend: backend)

        model.beginTailscaleDiscovery(owner: TailscaleDiscoveryFlowID())
        await waitUntil {
            if case .permissionDenied = model.tailscaleDiscovery { return true }
            return false
        }

        #expect(backend.callCount == 0)
        #expect(
            model.tailscaleDiscovery
                == .permissionDenied(
                    message: "The paired discovery host is missing devices.read. Re-pair it with an operator profile, then Retry."
                )
        )
    }

    @MainActor
    @Test("No connected paired host is explained without making a request")
    func noConnectedHostIsLocal() async {
        let backend = TailscaleOnboardingBackend()
        let model = OpenPawModel(
            hostStore: HostStore(hosts: [host]),
            backend: backend,
            tailscaleRouteHintSource: StaticRoutePathSource(
                snapshot: TailscaleRoutePathSnapshot(isSatisfied: true, interfaceNames: ["utun8"])
            ),
            now: { now }
        )

        model.beginTailscaleDiscovery(owner: TailscaleDiscoveryFlowID())
        await waitUntil { model.tailscaleRouteHint == .likelyAvailable }

        #expect(model.tailscaleDiscovery == .noConnectedHost)
        #expect(backend.callCount == 0)
        #expect(model.tailscaleRouteHint == .likelyAvailable)
    }

    @MainActor
    private func connectedModel(
        backend: TailscaleOnboardingBackend,
        additionalHosts: [HostRecord] = []
    ) -> OpenPawModel {
        let model = OpenPawModel(
            hostStore: HostStore(hosts: [host] + additionalHosts),
            backend: backend,
            tailscaleRouteHintSource: StaticRoutePathSource(
                snapshot: TailscaleRoutePathSnapshot(isSatisfied: true, interfaceNames: ["utun8"])
            ),
            now: { now }
        )
        model.connection = .connected(.ssh)
        return model
    }

    private func waitForCallCount(_ count: Int, backend: TailscaleOnboardingBackend) async {
        await waitUntil { backend.callCount >= count }
    }

    private func waitUntil(_ predicate: @escaping @MainActor @Sendable () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await !predicate(), clock.now < deadline {
            await Task.yield()
        }
        #expect(await predicate())
    }

    private static let candidate = TailscaleDeviceCandidate(
        id: "node-workshop",
        displayName: "Workshop peer",
        dnsName: "peer.tailnet.example",
        tailscaleIPs: ["100.100.10.20"],
        os: "macOS",
        online: true
    )
}

private final class TailscaleOnboardingBackend: OpenPawBackend, PairedHostCapabilityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var started = false
    private var suspended = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    var response = TailscaleDevicesResponse(version: 1, candidates: [])
    var error: (any Error)?
    var capabilityStatus: PairedHostCapabilityStatus = .unknown
    var isSuspended: Bool {
        get { locked { suspended } }
        set { locked { suspended = newValue } }
    }
    var callCount: Int { locked { calls } }

    func waitUntilStarted() async {
        if locked({ started }) { return }
        await withCheckedContinuation { continuation in
            locked {
                if started { continuation.resume() } else { startWaiters.append(continuation) }
            }
        }
    }

    func resume() {
        let waiters = locked {
            suspended = false
            let current = resumeWaiters
            resumeWaiters.removeAll()
            return current
        }
        waiters.forEach { $0.resume() }
    }

    func tailscaleDevices() async throws -> TailscaleDevicesResponse {
        let shouldSuspend = locked {
            calls += 1
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return suspended
        }
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                locked {
                    if suspended { resumeWaiters.append(continuation) } else { continuation.resume() }
                }
            }
        }
        if let error { throw error }
        return response
    }

    func pairedCapabilityStatus(_ capability: String, hostID: HostRecord.ID) -> PairedHostCapabilityStatus {
        capabilityStatus
    }

    func health() async throws -> HealthInfo { throw OnboardingBackendError.unexpected }
    func sessions() async throws -> [SessionSummary] { throw OnboardingBackendError.unexpected }
    func inbox(status: InboxStatus?) async throws -> [InboxItem] { throw OnboardingBackendError.unexpected }
    func resolve(item: InboxItem, action: ActionID, answer: String?, detailAcknowledged: Bool) async throws -> ResolveResult { throw OnboardingBackendError.unexpected }
    func events(session: String?, afterSeq: UInt64?) -> AsyncThrowingStream<Event, any Error> { AsyncThrowingStream { $0.finish() } }
    func repos() async throws -> [RepoSummary] { throw OnboardingBackendError.unexpected }
    func repoStatus(_ repo: String) async throws -> RepoStatus { throw OnboardingBackendError.unexpected }
    func diff(repo: String, mode: DiffMode, path: String?) async throws -> Diff { throw OnboardingBackendError.unexpected }
    func tree(repo: String, ref: String, path: String) async throws -> [TreeEntry] { throw OnboardingBackendError.unexpected }
    func blob(repo: String, ref: String, path: String) async throws -> Blob { throw OnboardingBackendError.unexpected }
    func search(repo: String, query: String, path: String?) async throws -> [ContentMatch] { throw OnboardingBackendError.unexpected }
    func upload(data: Data, filename: String) async throws -> UploadResult { throw OnboardingBackendError.unexpected }
    func previewURL(port: Int, path: String) throws -> URL { throw OnboardingBackendError.unexpected }
    func audit(limit: Int) async throws -> [AuditEntry] { throw OnboardingBackendError.unexpected }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private enum OnboardingBackendError: Error { case unexpected }

private actor RecordingTailscaleAdminConnector: TailscaleAdminConnecting {
    private(set) var connectedCredentials: [TailscaleAdminCredentials] = []
    private(set) var deleteCount = 0
    private var devices: [TailscaleAdminDeviceCandidate] = []
    private var suspended = false
    private var fetchStarted = false
    private var fetchStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    func setDevices(_ devices: [TailscaleAdminDeviceCandidate]) { self.devices = devices }
    func setSuspended(_ suspended: Bool) { self.suspended = suspended }

    func connect(_ credentials: TailscaleAdminCredentials) async throws {
        connectedCredentials.append(credentials)
    }

    func fetchSavedDevices() async throws -> [TailscaleAdminDeviceCandidate] {
        fetchStarted = true
        let startWaiters = fetchStartWaiters
        fetchStartWaiters.removeAll()
        startWaiters.forEach { $0.resume() }
        if suspended {
            await withCheckedContinuation { continuation in
                resumeWaiters.append(continuation)
            }
        }
        return devices
    }

    func disconnectAndDeleteCredentials() async throws {
        deleteCount += 1
    }

    func waitUntilFetchStarted() async {
        if fetchStarted { return }
        await withCheckedContinuation { continuation in
            fetchStartWaiters.append(continuation)
        }
    }

    func resume() {
        suspended = false
        let waiters = resumeWaiters
        resumeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor RecordingConnectionPreflightRunner: ConnectionPreflightRunning {
    private(set) var hosts: [HostRecord] = []
    private var reports: [ConnectionPreflightReport]
    private let suspendFirst: Bool
    private var firstStarted = false
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstResumeWaiters: [CheckedContinuation<Void, Never>] = []

    init(reports: [ConnectionPreflightReport], suspendFirst: Bool = false) {
        self.reports = reports
        self.suspendFirst = suspendFirst
    }

    func run(for host: HostRecord) async -> ConnectionPreflightReport {
        let index = hosts.count
        hosts.append(host)
        if index == 0, suspendFirst {
            firstStarted = true
            let waiters = firstStartWaiters
            firstStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstResumeWaiters.append(continuation)
            }
        }
        return reports[index]
    }

    func waitUntilFirstStarted() async {
        if firstStarted { return }
        await withCheckedContinuation { continuation in
            firstStartWaiters.append(continuation)
        }
    }

    func resumeFirst() {
        let waiters = firstResumeWaiters
        firstResumeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor PreflightTerminal: TerminalBackend, TerminalCapabilityProbing {
    nonisolated let stateStream = AsyncStream<ConnectionState> { $0.finish() }
    nonisolated let outputStream = AsyncStream<Data> { $0.finish() }
    private let connectError: TransportError?
    private(set) var probes: [TerminalCapabilityProbe] = []

    init(connectError: TransportError? = nil) { self.connectError = connectError }

    func connect(host: HostRecord) async throws {
        if let connectError { throw connectError }
    }
    func disconnect() async {}
    func send(text: String) async throws {}
    func send(chord: KeyChord, applicationCursorKeys: Bool) async throws {}
    func resize(columns: Int, rows: Int) async throws {}
    func run(command: String) async throws -> String { throw OnboardingBackendError.unexpected }
    func probe(_ probe: TerminalCapabilityProbe) async throws -> String {
        probes.append(probe)
        return switch probe {
        case .multiplexer(.tmux): "tmux 3.5"
        case .multiplexer(let kind): kind.displayName
        case .transport(.ssh): "SSH connected"
        case .transport(let kind): kind.displayName
        }
    }
}

private final class PreflightBackend: OpenPawBackend, @unchecked Sendable {
    let healthError: (any Error)?
    init(healthError: (any Error)? = nil) { self.healthError = healthError }

    func health() async throws -> HealthInfo {
        if let healthError { throw healthError }
        return HealthInfo(version: "test", protocolVersion: "1", agents: [], capabilities: [])
    }
    func sessions() async throws -> [SessionSummary] { [] }
    func inbox(status: InboxStatus?) async throws -> [InboxItem] { [] }
    func resolve(item: InboxItem, action: ActionID, answer: String?, detailAcknowledged: Bool) async throws -> ResolveResult { throw OnboardingBackendError.unexpected }
    func events(session: String?, afterSeq: UInt64?) -> AsyncThrowingStream<Event, any Error> { AsyncThrowingStream { $0.finish() } }
    func repos() async throws -> [RepoSummary] { [] }
    func repoStatus(_ repo: String) async throws -> RepoStatus { throw OnboardingBackendError.unexpected }
    func diff(repo: String, mode: DiffMode, path: String?) async throws -> Diff { throw OnboardingBackendError.unexpected }
    func tree(repo: String, ref: String, path: String) async throws -> [TreeEntry] { [] }
    func blob(repo: String, ref: String, path: String) async throws -> Blob { throw OnboardingBackendError.unexpected }
    func search(repo: String, query: String, path: String?) async throws -> [ContentMatch] { [] }
    func upload(data: Data, filename: String) async throws -> UploadResult { throw OnboardingBackendError.unexpected }
    func previewURL(port: Int, path: String) throws -> URL { throw OnboardingBackendError.unexpected }
    func tailscaleDevices() async throws -> TailscaleDevicesResponse { .init(version: 1, candidates: []) }
    func audit(limit: Int) async throws -> [AuditEntry] { [] }
}
