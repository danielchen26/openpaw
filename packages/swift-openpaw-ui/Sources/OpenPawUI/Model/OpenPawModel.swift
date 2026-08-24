import Foundation
import Observation
import OpenPawProtocol
import OpenPawTerminalCore

/// The single observable root the app and every screen read from.
///
/// It owns no transport and no networking: it is handed an `OpenPawBackend` and a `TerminalBackend`, which is what
/// lets the whole UI render in a headless snapshot run and in tests. All mutation happens on the main actor, so
/// SwiftUI never sees a half-applied update.
public enum TailscaleDiscoveryState: Sendable, Hashable {
    case idle
    case noConnectedHost
    case loading
    case candidates([TailscaleDeviceCandidate])
    case empty
    case permissionDenied(message: String)
    case unavailable(code: TailscaleDiscoveryErrorCode, message: String)
    case failure(message: String)

    public var candidates: [TailscaleDeviceCandidate] { if case .candidates(let items) = self { items } else { [] } }
}

/// Exact ownership of one selected-host connection attempt.
///
/// Host id alone is insufficient because a user can switch A → B → A, and connection generation alone does not name
/// which concurrent connect request won. A route may commit only while all four fields still match the model.
public struct HostConnectionLease: Sendable, Hashable {
    public var hostID: HostRecord.ID
    public var connectionGeneration: Int
    public var hostSelectionToken: Int
    public var requestID: Int

    public init(
        hostID: HostRecord.ID,
        connectionGeneration: Int,
        hostSelectionToken: Int,
        requestID: Int
    ) {
        self.hostID = hostID
        self.connectionGeneration = connectionGeneration
        self.hostSelectionToken = hostSelectionToken
        self.requestID = requestID
    }
}

/// Snapshot of the exact selected-host and connection-request epoch.
///
/// This is intentionally valid for a short validation window, such as credential installation. It detects host
/// selection ABA and same-host reconnects even when the visible selected host id ends where it started.
public struct HostOperationSnapshot: Sendable, Hashable {
    public var selectedHostID: HostRecord.ID?
    public var hostSelectionToken: Int
    public var connectionRequestID: Int

    public init(selectedHostID: HostRecord.ID?, hostSelectionToken: Int, connectionRequestID: Int) {
        self.selectedHostID = selectedHostID
        self.hostSelectionToken = hostSelectionToken
        self.connectionRequestID = connectionRequestID
    }
}

/// Ownership of one completed selected-host transaction.
public struct HostSelectionLease: Sendable, Hashable {
    public var hostID: HostRecord.ID
    public var hostSelectionToken: Int

    public init(hostID: HostRecord.ID, hostSelectionToken: Int) {
        self.hostID = hostID
        self.hostSelectionToken = hostSelectionToken
    }
}

public enum HostConnectPurpose: Sendable, Hashable {
    case normal
    case awaitingPairing
}

public enum HostPairingError: Error, Sendable, Hashable {
    case unavailable
    case staleConnection
}

@MainActor
@Observable
public final class OpenPawModel {

    private struct StructuredConnectSuperseded: Error {}

    // MARK: - Wiring

    public private(set) var backend: (any OpenPawBackend)?
    public private(set) var terminal: (any TerminalBackend)?
    public private(set) var structuredBackendReady = false
    public var dictation: (any DictationEngine)?
    /// Fetches weights for the engines that are not built into iOS. Defaults to a store that downloads nothing, so
    /// a preview or a test that constructs a model cannot start a gigabyte transfer by rendering a screen.
    public var dictationModels: any DictationModelInstalling = UnavailableDictationModelStore()
    /// Builds the engine for whichever recogniser the user picked. Nil in previews and tests, where the injected
    /// `dictation` engine (usually none) stands on its own.
    @ObservationIgnored public var dictationEngineFactory: (any DictationEngineMaking)?
    /// The last thing the user said while holding the screen, staged for whichever screen is on top.
    ///
    /// Staged rather than executed on purpose. Speech recognition is wrong often enough that running what it
    /// heard on a remote machine is not a risk worth taking, so this is a draft the user confirms.
    public var dictatedText: String?

    // MARK: - Hosts and connection

    public var hostStore: HostStore
    public var selectedHostID: HostRecord.ID? {
        didSet {
            if oldValue != selectedHostID {
                connectionGeneration += 1
                invalidateSelectedHostDerivedState()
            }
        }
    }
    public var connection: ConnectionState = .idle {
        didSet {
            connectionGeneration += 1
            updateProviderCapabilityState()
            if oldValue.isConnected, !connection.isConnected {
                markProviderOperationsDisconnected()
            }
        }
    }
    /// Monotonic token for binding derived host/session rows to the exact connection that produced them.
    public private(set) var connectionGeneration = 0
    /// True while the previous transport is being torn down for a newly selected host.
    ///
    /// Selection is deliberately separate from connection: a host chip may change immediately, but Connect remains
    /// unavailable until the old transport has finished closing. That keeps a fast select-then-connect sequence from
    /// letting the previous disconnect land on the new attempt.
    public private(set) var isSwitchingHost = false
    /// Set when a host key is unknown or changed. A changed key is a hard block by contract, so the UI must not
    /// offer a "continue anyway" path for `.changed`.
    public var hostKeyPrompt: HostKeyPrompt?

    // MARK: - Sessions

    public var sessions: [SessionSummary] = []
    public var selectedSessionID: String?
    /// Recent events per agent session, capped so a long-running agent cannot grow the heap without bound.
    public private(set) var transcripts: [String: [Event]] = [:]
    public var eventBudgetPerSession: Int {
        get { settings.eventBudgetPerSession }
        set { settings.eventBudgetPerSession = OpenPawSettings.validatedEventBudget(newValue) }
    }
    @ObservationIgnored private let settings: OpenPawSettings

    // MARK: - Inbox

    public var inbox: [InboxItem] = []
    /// Items the user has expanded far enough that the host will accept a decision.
    public private(set) var acknowledgedDetails: Set<String> = []

    // MARK: - Repositories

    public var repos: [RepoSummary] = []
    public var selectedRepo: String?
    public private(set) var providerListState: ProviderListLoadingState = .idle
    public private(set) var providers: [ProviderStatus] = []
    public var selectedProvider: ProviderID? {
        didSet {
            if oldValue != selectedProvider {
                providerRepoOperationGeneration += 1
                providerRepoPages = ProviderRepoPagesState(provider: selectedProvider)
            }
        }
    }
    public private(set) var canListProviders: ProviderCapabilityAvailability = .unavailable
    public private(set) var canAuthorizeProviders: ProviderCapabilityAvailability = .unavailable
    public private(set) var canImportRepos: ProviderCapabilityAvailability = .unavailable
    public private(set) var providerAuthorizationState: ProviderAuthorizationFlowState = .idle
    public private(set) var providerRepoPages: ProviderRepoPagesState = ProviderRepoPagesState()
    public private(set) var repoImportState: RepoImportOperationState = .idle

    // MARK: - Diagnostics and errors

    public var health: HealthInfo?
    public var lastError: PresentedError?
    public var isRefreshing = false
    public private(set) var tailscaleDiscovery: TailscaleDiscoveryState = .idle
    public private(set) var tailscaleRouteHint: TailscaleRouteHint = .notDetected
    public private(set) var tailscaleDiscoveryMetadata: TailscaleDiscoveryMetadata?
    public private(set) var tailscaleAdminConnection: TailscaleAdminConnectionState = .disconnected
    public private(set) var connectionPreflightReport: ConnectionPreflightReport?
    public private(set) var isConnectionPreflightRunning = false
    public private(set) var homeTailnetBootstrap = HomeTailnetBootstrapState()

    private var tailscaleDiscoveryTask: Task<Void, Never>?
    private var tailscaleDiscoveryGeneration = 0
    private var tailscaleDiscoveryOwner: TailscaleDiscoveryFlowID?
    @ObservationIgnored private let tailscaleRouteHintSource: any TailscaleRoutePathSourcing
    @ObservationIgnored private let tailscaleAdminConnector: (any TailscaleAdminConnecting)?
    @ObservationIgnored private let tailscaleLocalIdentityConnector: (any TailscaleLocalIdentityConnecting)?
    @ObservationIgnored private let connectionPreflightRunner: (any ConnectionPreflightRunning)?
    @ObservationIgnored private let now: @Sendable () -> Date
    private var tailscaleAdminGeneration = 0
    private var homeTailnetBootstrapGeneration = 0
    private var homeTailnetBootstrapTask: Task<Void, Never>?
    private var connectionPreflightGeneration = 0
    private var hostSelectionGeneration = 0
    /// Host teardown may suspend inside a structured tunnel or terminal. Every
    /// newer selection waits for the previous teardown before it can finish, so a
    /// late A selection cannot disconnect a connection that B established later.
    private var hostSelectionOperation: Task<Void, Never>?
    private var connectionRequestID = 0

    private var eventTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var stateTaskHostID: HostRecord.ID?
    private var stateAttemptHasConnected = false
    private var stateStreamGeneration = 0
    private var terminalConnectAcknowledgement: CheckedContinuation<Void, Never>?
    /// Structured lifecycle connects are allowed to suspend while a tunnel opens. A newer request chains behind the
    /// previous one, then tears down whatever it left behind before dialing. This prevents a late connect for host A
    /// from reattaching after the user has selected or connected host B.
    private var structuredConnectRequestID = 0
    private var structuredConnectOperation: Task<Void, any Error>?
    private var providerOperationGeneration = 0
    private var authorizationOperationGeneration = 0
    private var providerRepoOperationGeneration = 0
    private var repoImportOperationGeneration = 0
    private var providerAuthorizationPollTask: Task<Void, Never>?
    private var repoImportPollTask: Task<Void, Never>?
    private var activeAuthorizationProvider: ProviderID?
    private var activeAuthorizationID: String?
    private var activeAuthorizationIntervalSeconds: UInt32 = 5
    private var activeRepoImportID: String?
    private var activeRepoImportLease: HostConnectionLease?
    private var repoImportRefreshTask: Task<Void, Never>?
    private let reducer = TranscriptReducer()

    public init(
        hostStore: HostStore = HostStore(),
        backend: (any OpenPawBackend)? = nil,
        terminal: (any TerminalBackend)? = nil,
        dictation: (any DictationEngine)? = nil,
        dictationModels: (any DictationModelInstalling)? = nil,
        dictationEngineFactory: (any DictationEngineMaking)? = nil,
        tailscaleRouteHintSource: any TailscaleRoutePathSourcing = SystemTailscaleRoutePathSource(),
        tailscaleAdminConnector: (any TailscaleAdminConnecting)? = nil,
        tailscaleLocalIdentityConnector: (any TailscaleLocalIdentityConnecting)? = nil,
        connectionPreflightRunner: (any ConnectionPreflightRunning)? = nil,
        settings: OpenPawSettings = OpenPawSettings(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.hostStore = hostStore
        self.backend = backend
        self.terminal = terminal
        self.dictation = dictation
        self.dictationEngineFactory = dictationEngineFactory
        self.tailscaleRouteHintSource = tailscaleRouteHintSource
        self.tailscaleAdminConnector = tailscaleAdminConnector
        self.tailscaleLocalIdentityConnector = tailscaleLocalIdentityConnector
        self.connectionPreflightRunner = connectionPreflightRunner
        self.settings = settings
        self.now = now
        if let dictationModels { self.dictationModels = dictationModels }
        self.selectedHostID = hostStore.hosts.first?.id
        self.structuredBackendReady = backend.map { !($0 is any StructuredBackendLifecycle) } ?? false
        updateProviderCapabilityState()
    }

    public func attach(backend: (any OpenPawBackend)?, terminal: (any TerminalBackend)?) {
        stateStreamGeneration += 1
        stateTask?.cancel()
        stateTask = nil
        stateTaskHostID = nil
        stateAttemptHasConnected = false
        resumeTerminalConnectAcknowledgement()
        self.backend = backend
        self.terminal = terminal
        structuredBackendReady = backend.map { !($0 is any StructuredBackendLifecycle) } ?? false
        updateProviderCapabilityState()
    }

    // MARK: - Derived state

    public var selectedHost: HostRecord? {
        guard let selectedHostID else { return nil }
        return hostStore.hosts.first { $0.id == selectedHostID }
    }

    public var canRefreshRemoteState: Bool {
        backend != nil && selectedHost != nil && connection.isConnected && structuredBackendReady
    }

    public var pendingInbox: [InboxItem] {
        inbox.filter { $0.status == .pending }.sorted(by: Self.inboxOrder)
    }

    /// Risk first, then oldest first. A destructive request that arrived a minute ago outranks a completion
    /// notice that arrived a second ago — the list is a work queue, not a feed.
    static func inboxOrder(_ lhs: InboxItem, _ rhs: InboxItem) -> Bool {
        let left = severity(lhs), right = severity(rhs)
        if left != right { return left > right }
        return lhs.createdAt < rhs.createdAt
    }

    private static func severity(_ item: InboxItem) -> Int {
        var score: Int
        switch item.category {
        case .permission: score = 40
        case .question: score = 35
        case .plan: score = 25
        case .toolFailure: score = 20
        case .rateLimit: score = 15
        case .contextWarning: score = 12
        case .backgroundJob: score = 8
        case .completion: score = 5
        }
        if let risk = item.risk {
            let bump: Int = switch risk.riskClass {
            case .destructiveShell: 9
            case .credentialAccess: 8
            case .unknown: 6
            case .packageInstallation: 5
            case .networkAccess: 4
            case .gitOperation: 3
            case .localWrite: 2
            case .readOnly: 1
            }
            score += bump
            if risk.requiresDetailExpansion { score += 3 }
        }
        return score
    }

    public func chat(for sessionID: String) -> [ChatItem] {
        reducer.reduce(transcripts[sessionID] ?? [])
    }

    public func vitals(for sessionID: String) -> SessionVitals {
        SessionVitals.derive(from: transcripts[sessionID] ?? [])
    }

    public func events(for sessionID: String) -> [Event] {
        transcripts[sessionID] ?? []
    }

    public func session(_ id: String) -> SessionSummary? {
        sessions.first { $0.sessionID == id }
    }

    /// True once the user has seen the full command for an item that demands it. The approve control must not
    /// exist before this flips — the gate is the product, not a nag.
    public func isDetailAcknowledged(_ item: InboxItem) -> Bool {
        guard let risk = item.risk, risk.requiresDetailExpansion else { return true }
        return acknowledgedDetails.contains(item.id.rawValue)
    }

    public func acknowledgeDetail(_ item: InboxItem) {
        acknowledgedDetails.insert(item.id.rawValue)
    }

    // MARK: - Loading

    public func refresh() async {
        guard canRefreshRemoteState, let backend, let hostID = selectedHostID else { return }
        let generation = connectionGeneration
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let health = backend.health()
            async let sessions = backend.sessions()
            async let inbox = backend.inbox(status: nil)
            async let repos = backend.repos()
            let loadedHealth = try await health
            let loadedSessions = try await sessions
            let loadedInbox = try await inbox
            let loadedRepos = try await repos
            guard selectedHostID == hostID, connectionGeneration == generation, structuredBackendReady else { return }
            self.health = loadedHealth
            self.sessions = loadedSessions
            self.inbox = loadedInbox
            self.repos = loadedRepos
            if selectedSessionID == nil { selectedSessionID = self.sessions.first?.sessionID }
            if selectedRepo == nil { selectedRepo = self.repos.first?.name }
        } catch {
            guard selectedHostID == hostID, connectionGeneration == generation else { return }
            present(error, while: "loading host state")
        }
    }

    public func refreshProviders() async {
        guard let context = providerRequestContext(capability: "providers.read", activity: "loading providers") else { return }
        providerOperationGeneration += 1
        let operation = providerOperationGeneration
        providerListState = .loading
        do {
            let loaded = try await context.backend.providers()
            guard isCurrent(context.lease), providerOperationGeneration == operation else { return }
            providers = loaded
            if selectedProvider == nil { selectedProvider = loaded.first?.id }
            providerListState = .loaded
        } catch {
            guard isCurrent(context.lease), providerOperationGeneration == operation else { return }
            let presented = presentedError(error, while: "loading providers")
            providerListState = .failed(presented)
            lastError = presented
        }
    }

    public func beginProviderAuthorization(_ provider: ProviderID) async {
        guard let context = providerRequestContext(capability: "providers.manage", activity: "authorizing provider") else { return }
        authorizationOperationGeneration += 1
        let operation = authorizationOperationGeneration
        selectedProvider = provider
        providerAuthorizationState = .starting(provider: provider)
        do {
            let start = try await context.backend.beginProviderAuthorization(provider)
            guard isCurrent(context.lease), authorizationOperationGeneration == operation, selectedProvider == provider else { return }
            activeAuthorizationProvider = provider
            activeAuthorizationID = start.authorizationID
            activeAuthorizationIntervalSeconds = start.intervalSeconds
            providerAuthorizationState = .awaitingUser(start)
            startProviderAuthorizationPolling(provider: provider, authorizationID: start.authorizationID, lease: context.lease, intervalSeconds: start.intervalSeconds)
        } catch {
            guard isCurrent(context.lease), authorizationOperationGeneration == operation else { return }
            failAuthorization(provider: provider, authorizationID: nil, error: error)
        }
    }

    public func pollProviderAuthorization() async {
        guard let provider = activeAuthorizationProvider, let authorizationID = activeAuthorizationID else { return }
        await pollProviderAuthorization(provider: provider, authorizationID: authorizationID)
    }

    public func pollProviderAuthorization(provider: ProviderID, authorizationID: String) async {
        guard let context = providerRequestContext(capability: "providers.manage", activity: "checking provider authorization") else { return }
        authorizationOperationGeneration += 1
        let operation = authorizationOperationGeneration
        providerAuthorizationState = .polling(ProviderAuthorizationStatus(authorizationID: authorizationID, state: .pending, provider: provider))
        do {
            let status = try await context.backend.providerAuthorizationStatus(provider: provider, authorizationID: authorizationID)
            guard isCurrent(context.lease), authorizationOperationGeneration == operation, activeAuthorizationProvider == provider, activeAuthorizationID == authorizationID else { return }
            guard status.provider == provider, status.authorizationID == authorizationID else {
                providerAuthorizationPollTask?.cancel()
                providerAuthorizationPollTask = nil
                failAuthorization(provider: provider, authorizationID: authorizationID, error: ProviderWorkflowOwnershipError())
                return
            }
            if !status.state.isTerminalForModel {
                providerAuthorizationState = .polling(status)
            } else {
                providerAuthorizationState = .terminal(status)
                providerAuthorizationPollTask?.cancel()
                providerAuthorizationPollTask = nil
                if status.state == .authorized { await refreshProviders() }
            }
        } catch {
            guard isCurrent(context.lease), authorizationOperationGeneration == operation else { return }
            failAuthorization(provider: provider, authorizationID: authorizationID, error: error)
        }
    }

    public func cancelProviderAuthorization() async {
        let pair: (ProviderID, String)? = switch providerAuthorizationState {
        case .awaitingUser(let start): activeAuthorizationProvider.map { ($0, start.authorizationID) }
        case .polling(let status): (status.provider, status.authorizationID)
        case .failed(let provider, let id, _): id.map { (provider, $0) }
        default: nil
        }
        guard let (provider, authorizationID) = pair,
              let context = providerRequestContext(capability: "providers.manage", activity: "cancelling provider authorization") else { return }
        authorizationOperationGeneration += 1
        let operation = authorizationOperationGeneration
        providerAuthorizationState = .cancelling(authorizationID: authorizationID)
        providerAuthorizationPollTask?.cancel()
        providerAuthorizationPollTask = nil
        do {
            let status = try await context.backend.cancelProviderAuthorization(provider: provider, authorizationID: authorizationID)
            guard isCurrent(context.lease), authorizationOperationGeneration == operation,
                  activeAuthorizationProvider == provider, activeAuthorizationID == authorizationID else { return }
            guard status.provider == provider, status.authorizationID == authorizationID else {
                failAuthorization(provider: provider, authorizationID: authorizationID, error: ProviderWorkflowOwnershipError())
                return
            }
            providerAuthorizationState = .terminal(status)
        } catch {
            guard isCurrent(context.lease), authorizationOperationGeneration == operation else { return }
            failAuthorization(provider: provider, authorizationID: authorizationID, error: error)
        }
    }

    public func revokeProvider(_ provider: ProviderID) async {
        guard let context = providerRequestContext(capability: "providers.manage", activity: "revoking provider") else { return }
        providerOperationGeneration += 1
        let operation = providerOperationGeneration
        do {
            let status = try await context.backend.revokeProvider(provider)
            guard isCurrent(context.lease), providerOperationGeneration == operation else { return }
            providers.removeAll { $0.id == provider }
            providers.append(status)
            if selectedProvider == provider { selectedProvider = nil }
            providerAuthorizationPollTask?.cancel()
            providerAuthorizationPollTask = nil
            activeAuthorizationProvider = nil
            activeAuthorizationID = nil
            providerAuthorizationState = .idle
            providerRepoPages = ProviderRepoPagesState()
        } catch {
            guard isCurrent(context.lease), providerOperationGeneration == operation else { return }
            lastError = presentedError(error, while: "revoking provider")
        }
    }

    public func loadProviderRepos(reset: Bool = false, cursor: String? = nil) async {
        guard let provider = selectedProvider,
              let context = providerRequestContext(capability: "providers.read", activity: "loading provider repositories") else { return }
        if let cursor, !reset,
           (providerRepoPages.provider != provider || providerRepoPages.nextCursor != cursor) {
            lastError = PresentedError(
                title: "Repository page expired",
                detail: "Reload repositories for the selected provider before requesting another page.",
                isRecoverable: true)
            return
        }
        providerRepoOperationGeneration += 1
        let operation = providerRepoOperationGeneration
        let requestCursor = reset ? nil : (cursor ?? providerRepoPages.nextCursor)
        if reset || providerRepoPages.provider != provider { providerRepoPages = ProviderRepoPagesState(provider: provider) }
        providerRepoPages.isLoading = true
        providerRepoPages.error = nil
        do {
            let page = try await context.backend.providerRepos(provider, cursor: requestCursor)
            guard isCurrent(context.lease), providerRepoOperationGeneration == operation, selectedProvider == provider else { return }
            var merged = reset ? [] : providerRepoPages.repos
            var seen = Set(merged.map(\.id))
            for repo in page.repos where seen.insert(repo.id).inserted { merged.append(repo) }
            providerRepoPages = ProviderRepoPagesState(provider: provider, repos: Array(merged.prefix(250)), nextCursor: page.nextCursor, isLoading: false)
        } catch {
            guard isCurrent(context.lease), providerRepoOperationGeneration == operation else { return }
            let presented = presentedError(error, while: "loading provider repositories")
            providerRepoPages.isLoading = false
            providerRepoPages.error = presented
            lastError = presented
        }
    }

    public func startRepoImport(provider: ProviderID, repoID: String, requestedName: String? = nil) async {
        guard let context = providerRequestContext(capability: "repos.manage", activity: "importing repository") else { return }
        repoImportOperationGeneration += 1
        let operation = repoImportOperationGeneration
        repoImportState = .starting(provider: provider, repoID: repoID)
        do {
            let progress = try await context.backend.importRepo(try RepoImportRequest(provider: provider, repoID: repoID, requestedName: requestedName))
            guard isCurrent(context.lease), repoImportOperationGeneration == operation else { return }
            activeRepoImportID = progress.id
            activeRepoImportLease = context.lease
            commitImportProgress(progress)
            if !progress.state.isTerminalForModel { startRepoImportPolling(importID: progress.id, lease: context.lease) }
        } catch {
            guard isCurrent(context.lease), repoImportOperationGeneration == operation else { return }
            failImport(importID: nil, error: error)
        }
    }

    public func pollRepoImport(_ importID: String? = nil) async {
        guard let id = importID ?? repoImportState.importID,
              let context = providerRequestContext(capability: "repos.manage", activity: "checking repository import") else { return }
        guard activeRepoImportID == id else {
            failImport(importID: id, error: ProviderWorkflowOwnershipError())
            return
        }
        repoImportOperationGeneration += 1
        let operation = repoImportOperationGeneration
        do {
            let progress = try await context.backend.repoImportProgress(id)
            guard isCurrent(context.lease), repoImportOperationGeneration == operation,
                  activeRepoImportID == id else { return }
            guard progress.id == id else {
                failImport(importID: id, error: ProviderWorkflowOwnershipError())
                return
            }
            activeRepoImportID = progress.id
            activeRepoImportLease = context.lease
            commitImportProgress(progress)
            if !progress.state.isTerminalForModel { startRepoImportPolling(importID: progress.id, lease: context.lease) }
        } catch {
            guard isCurrent(context.lease), repoImportOperationGeneration == operation else { return }
            failImport(importID: id, error: error)
        }
    }

    public func cancelRepoImport(_ importID: String? = nil) async {
        guard let id = importID ?? repoImportState.importID,
              let context = providerRequestContext(capability: "repos.manage", activity: "cancelling repository import") else { return }
        guard activeRepoImportID == id else {
            failImport(importID: id, error: ProviderWorkflowOwnershipError())
            return
        }
        repoImportOperationGeneration += 1
        let operation = repoImportOperationGeneration
        repoImportState = .cancelling(importID: id)
        repoImportPollTask?.cancel()
        repoImportPollTask = nil
        do {
            let progress = try await context.backend.cancelRepoImport(id)
            guard isCurrent(context.lease), repoImportOperationGeneration == operation,
                  activeRepoImportID == id else { return }
            guard progress.id == id else {
                failImport(importID: id, error: ProviderWorkflowOwnershipError())
                return
            }
            commitImportProgress(progress)
        } catch {
            guard isCurrent(context.lease), repoImportOperationGeneration == operation else { return }
            failImport(importID: id, error: error)
        }
    }

    public func registerRepo(rootID: String, requestedName: String? = nil) async {
        guard let context = providerRequestContext(capability: "repos.manage", activity: "registering repository") else { return }
        repoImportOperationGeneration += 1
        let operation = repoImportOperationGeneration
        do {
            let progress = try await context.backend.registerRepo(try RepoRegisterRequest(rootID: rootID, requestedName: requestedName))
            guard isCurrent(context.lease), repoImportOperationGeneration == operation else { return }
            commitImportProgress(progress)
        } catch {
            guard isCurrent(context.lease), repoImportOperationGeneration == operation else { return }
            failImport(importID: nil, error: error)
        }
    }

    /// Follows the host's SSE stream. Resumes from the highest `seq` we already hold, which is exact because
    /// `seq` is dense per session and `event_id` is content addressed, so a reconnect cannot duplicate a row.
    public func startFollowing(session sessionID: String?) {
        guard canRefreshRemoteState, let backend, let hostID = selectedHostID else { return }
        let generation = connectionGeneration
        eventTask?.cancel()
        let afterSeq = sessionID.flatMap { transcripts[$0]?.map(\.seq).max() }
        eventTask = Task { [weak self, backend] in
            do {
                for try await event in backend.events(session: sessionID, afterSeq: afterSeq) {
                    guard let self, self.selectedHostID == hostID, self.connectionGeneration == generation, self.structuredBackendReady else { return }
                    self.ingest(event)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.selectedHostID == hostID, self.connectionGeneration == generation else { return }
                self.present(error, while: "following the event stream")
            }
        }
    }

    /// Starts discovery once for one Add Device presentation. SwiftUI may call this repeatedly while rendering.
    public func beginTailscaleDiscovery(owner: TailscaleDiscoveryFlowID) {
        guard tailscaleDiscoveryOwner != owner else { return }
        tailscaleDiscoveryOwner = owner
        startTailscaleDiscovery(owner: owner)
    }

    /// Explicit user retry. Only the flow that owns the visible result can replace it.
    public func retryTailscaleDiscovery(owner: TailscaleDiscoveryFlowID) {
        guard tailscaleDiscoveryOwner == owner else { return }
        startTailscaleDiscovery(owner: owner)
    }

    /// Ends one flow without cancelling a newer presentation that already took ownership.
    public func endTailscaleDiscovery(owner: TailscaleDiscoveryFlowID) {
        guard tailscaleDiscoveryOwner == owner else { return }
        cancelTailscaleDiscovery()
    }

    /// Compatibility entry point for older call sites. New Add Device UI uses flow ownership.
    public func refreshTailscaleDevices() {
        if let owner = tailscaleDiscoveryOwner {
            retryTailscaleDiscovery(owner: owner)
        } else {
            beginTailscaleDiscovery(owner: TailscaleDiscoveryFlowID())
        }
    }

    private func startTailscaleDiscovery(owner: TailscaleDiscoveryFlowID) {
        tailscaleDiscoveryGeneration += 1
        let generation = tailscaleDiscoveryGeneration
        tailscaleDiscoveryTask?.cancel()
        guard tailscaleDiscoveryOwner == owner else { return }
        guard let discoveryHost = selectedHost, connection.isConnected, structuredBackendReady, let backend else {
            tailscaleDiscovery = .noConnectedHost
            tailscaleDiscoveryMetadata = nil
            tailscaleDiscoveryTask = Task { [weak self, tailscaleRouteHintSource] in
                let hint = await TailscaleRouteHintResolver(source: tailscaleRouteHintSource).currentHint()
                guard let self, self.tailscaleDiscoveryOwner == owner, self.tailscaleDiscoveryGeneration == generation else { return }
                self.tailscaleRouteHint = hint
            }
            return
        }
        let hostID = discoveryHost.id
        let connectionGeneration = connectionGeneration
        if let capabilityProvider = backend as? any PairedHostCapabilityProviding,
            capabilityProvider.pairedCapabilityStatus("devices.read", hostID: hostID) == .denied
        {
            tailscaleDiscovery = .permissionDenied(
                message: "The paired discovery host is missing devices.read. Re-pair it with an operator profile, then Retry."
            )
            tailscaleDiscoveryMetadata = TailscaleDiscoveryMetadata(
                source: .pairedHost(id: hostID, displayName: discoveryHost.nickname),
                routeHint: tailscaleRouteHint,
                refreshedAt: nil
            )
            tailscaleDiscoveryTask = Task { [weak self, tailscaleRouteHintSource] in
                let hint = await TailscaleRouteHintResolver(source: tailscaleRouteHintSource).currentHint()
                guard let self, self.tailscaleDiscoveryOwner == owner,
                    self.tailscaleDiscoveryGeneration == generation,
                    self.selectedHostID == hostID,
                    self.connectionGeneration == connectionGeneration
                else { return }
                self.tailscaleRouteHint = hint
                self.tailscaleDiscoveryMetadata = TailscaleDiscoveryMetadata(
                    source: .pairedHost(id: hostID, displayName: discoveryHost.nickname),
                    routeHint: hint,
                    refreshedAt: nil
                )
            }
            return
        }
        tailscaleDiscovery = .loading
        tailscaleDiscoveryMetadata = TailscaleDiscoveryMetadata(
            source: .pairedHost(id: hostID, displayName: discoveryHost.nickname),
            routeHint: tailscaleRouteHint,
            refreshedAt: nil
        )
        tailscaleDiscoveryTask = Task { [weak self, backend, tailscaleRouteHintSource, now] in
            let hint = await TailscaleRouteHintResolver(source: tailscaleRouteHintSource).currentHint()
            do {
                let response = try await backend.tailscaleDevices()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.tailscaleDiscoveryOwner == owner, self.tailscaleDiscoveryGeneration == generation, self.selectedHostID == hostID, self.connectionGeneration == connectionGeneration, self.structuredBackendReady else { return }
                    self.tailscaleRouteHint = hint
                    self.tailscaleDiscoveryMetadata = TailscaleDiscoveryMetadata(
                        source: .pairedHost(id: hostID, displayName: discoveryHost.nickname),
                        routeHint: hint,
                        refreshedAt: now()
                    )
                    self.tailscaleDiscovery = response.candidates.isEmpty ? .empty : .candidates(response.candidates)
                }
            } catch is CancellationError {
            } catch HostClientError.unauthorized {
                await MainActor.run {
                    guard let self, self.tailscaleDiscoveryOwner == owner, self.tailscaleDiscoveryGeneration == generation, self.selectedHostID == hostID, self.connectionGeneration == connectionGeneration else { return }
                    self.tailscaleRouteHint = hint
                    self.tailscaleDiscovery = .permissionDenied(
                        message: "The paired discovery host rejected this device. Pair it again, then Retry."
                    )
                }
            } catch HostClientError.forbidden {
                await MainActor.run {
                    guard let self, self.tailscaleDiscoveryOwner == owner, self.tailscaleDiscoveryGeneration == generation, self.selectedHostID == hostID, self.connectionGeneration == connectionGeneration else { return }
                    self.tailscaleRouteHint = hint
                    self.tailscaleDiscovery = .permissionDenied(
                        message: "The paired discovery host is missing devices.read. Re-pair it with an operator profile, then Retry."
                    )
                }
            } catch HostClientError.tailscaleDiscovery(let code, let message) {
                await MainActor.run {
                    guard let self, self.tailscaleDiscoveryOwner == owner, self.tailscaleDiscoveryGeneration == generation, self.selectedHostID == hostID, self.connectionGeneration == connectionGeneration else { return }
                    self.tailscaleRouteHint = hint
                    self.tailscaleDiscovery = .unavailable(code: code, message: message)
                }
            } catch {
                await MainActor.run {
                    guard let self, self.tailscaleDiscoveryOwner == owner, self.tailscaleDiscoveryGeneration == generation, self.selectedHostID == hostID, self.connectionGeneration == connectionGeneration else { return }
                    self.tailscaleRouteHint = hint
                    self.tailscaleDiscovery = .failure(message: "Tailscale discovery failed. Retry or add SSH details manually.")
                }
            }
        }
    }

    public func refreshHomeTailnetBootstrap() {
        homeTailnetBootstrapGeneration += 1
        let generation = homeTailnetBootstrapGeneration
        let hostID = selectedHostID
        let connectionGeneration = connectionGeneration
        let connectedBackend = connection.isConnected && structuredBackendReady ? backend : nil
        homeTailnetBootstrapTask?.cancel()
        homeTailnetBootstrap.phase = .loading
        homeTailnetBootstrap.candidates = []
        homeTailnetBootstrapTask = Task { [weak self, tailscaleRouteHintSource, tailscaleLocalIdentityConnector, tailscaleAdminConnector, connectedBackend, now] in
            let hint = await TailscaleRouteHintResolver(source: tailscaleRouteHintSource).currentHint()
            var identity: TailscaleLocalIdentity?
            var candidates: [AddDeviceCandidate] = []
            var source: HomeTailnetBootstrapState.Source = .none
            var failure: String?

            if let tailscaleLocalIdentityConnector {
                do { identity = try await tailscaleLocalIdentityConnector.localIdentity(); source = .localIdentity }
                catch is CancellationError { return }
                catch { /* local identity can be unavailable on some clients */ }
            }

            if let tailscaleAdminConnector {
                do {
                    let devices = try await tailscaleAdminConnector.fetchSavedDevices()
                    candidates.append(contentsOf: devices.map(AddDeviceCandidate.from))
                    source = source == .none || source == .localIdentity ? .savedAdministrator : .merged
                } catch is CancellationError { return }
                catch TailscaleAdminConnectionError.missingCredentials { }
                catch { failure = Self.tailscaleAdminFailureMessage(error) }
            }

            if candidates.isEmpty, let connectedBackend {
                do {
                    let response = try await connectedBackend.tailscaleDevices()
                    candidates.append(contentsOf: response.candidates.map(AddDeviceCandidate.from))
                    if !candidates.isEmpty { source = source == .none || source == .localIdentity ? .pairedHost : .merged }
                } catch is CancellationError { return }
                catch { if failure == nil { failure = "Paired host Tailscale discovery failed. Retry or add SSH details manually." } }
            }

            let deduped = Self.dedupeHomeTailnetCandidates(candidates)
            await MainActor.run {
                guard let self, self.homeTailnetBootstrapGeneration == generation, self.selectedHostID == hostID, self.connectionGeneration == connectionGeneration else { return }
                self.homeTailnetBootstrap.routeHint = hint
                self.homeTailnetBootstrap.localIdentity = identity
                self.homeTailnetBootstrap.candidates = deduped
                self.homeTailnetBootstrap.source = deduped.isEmpty ? (identity == nil ? .none : .localIdentity) : source
                self.homeTailnetBootstrap.refreshedAt = now()
                if !deduped.isEmpty || identity != nil { self.homeTailnetBootstrap.phase = .loaded }
                else if let failure { self.homeTailnetBootstrap.phase = .failed(failure) }
                else { self.homeTailnetBootstrap.phase = .unavailable }
            }
        }
    }

    public func cancelHomeTailnetBootstrap() {
        homeTailnetBootstrapGeneration += 1
        homeTailnetBootstrapTask?.cancel()
        homeTailnetBootstrapTask = nil
        homeTailnetBootstrap.phase = .idle
    }

    public var suggestedAdministratorTailnet: String? {
        homeTailnetBootstrap.localIdentity?.tailnetName ?? homeTailnetBootstrap.localIdentity?.domainName
    }

    private static func dedupeHomeTailnetCandidates(_ candidates: [AddDeviceCandidate]) -> [AddDeviceCandidate] {
        var seen = Set<String>()
        return candidates.sorted { lhs, rhs in
            let lp = lhs.source == .tailscaleAdministrator ? 0 : 1
            let rp = rhs.source == .tailscaleAdministrator ? 0 : 1
            if lp != rp { return lp < rp }
            return lhs.hostname.localizedStandardCompare(rhs.hostname) == .orderedAscending
        }.filter { candidate in
            let key = ([candidate.dnsName, candidate.hostname] + candidate.tailscaleIPs).compactMap { $0?.lowercased() }.joined(separator: "|")
            return seen.insert(key.isEmpty ? candidate.id : key).inserted
        }
    }

    public func cancelTailscaleDiscovery() {
        tailscaleDiscoveryGeneration += 1
        tailscaleDiscoveryTask?.cancel()
        tailscaleDiscoveryTask = nil
        tailscaleDiscoveryOwner = nil
        tailscaleDiscovery = .idle
        tailscaleDiscoveryMetadata = nil
    }

    /// Stores administrator-created credentials only after the explicit Connect action, then performs one read-only
    /// Devices API request. Returned devices remain proposals and never mutate `hostStore`.
    public func connectTailscaleAdministrator(credentials: TailscaleAdminCredentials) async {
        tailscaleAdminGeneration += 1
        let generation = tailscaleAdminGeneration
        let issues = credentials.validationIssues
        guard issues.isEmpty else {
            tailscaleAdminConnection = .failure(message: Self.tailscaleAdminValidationMessage(issues))
            return
        }
        guard let tailscaleAdminConnector else {
            tailscaleAdminConnection = .failure(message: "The advanced Tailscale connector is unavailable in this build.")
            return
        }

        tailscaleAdminConnection = .connecting
        do {
            try await tailscaleAdminConnector.connect(credentials.normalized)
            guard tailscaleAdminGeneration == generation else { return }
            tailscaleAdminConnection = .refreshing
            let devices = try await tailscaleAdminConnector.fetchSavedDevices()
            guard tailscaleAdminGeneration == generation else { return }
            tailscaleAdminConnection = .candidates(devices)
        } catch is CancellationError {
        } catch {
            guard tailscaleAdminGeneration == generation else { return }
            tailscaleAdminConnection = .failure(message: Self.tailscaleAdminFailureMessage(error))
        }
    }

    /// Refreshes an already saved administrator connection. This never prompts for or returns stored credentials.
    public func refreshTailscaleAdministrator() async {
        tailscaleAdminGeneration += 1
        let generation = tailscaleAdminGeneration
        guard let tailscaleAdminConnector else {
            tailscaleAdminConnection = .failure(message: "The advanced Tailscale connector is unavailable in this build.")
            return
        }
        tailscaleAdminConnection = .refreshing
        do {
            let devices = try await tailscaleAdminConnector.fetchSavedDevices()
            guard tailscaleAdminGeneration == generation else { return }
            tailscaleAdminConnection = .candidates(devices)
        } catch is CancellationError {
        } catch {
            guard tailscaleAdminGeneration == generation else { return }
            tailscaleAdminConnection = .failure(message: Self.tailscaleAdminFailureMessage(error))
        }
    }

    /// Revokes the app's local connection by deleting credentials and invalidating any older in-flight response.
    public func disconnectTailscaleAdministrator() async {
        tailscaleAdminGeneration += 1
        tailscaleAdminConnection = .disconnected
        guard let tailscaleAdminConnector else { return }
        do {
            try await tailscaleAdminConnector.disconnectAndDeleteCredentials()
        } catch is CancellationError {
        } catch {
            tailscaleAdminConnection = .failure(
                message: "OpenPaw could not delete the saved administrator credentials. Try again before leaving this device unattended."
            )
        }
    }

    private static func tailscaleAdminValidationMessage(_ issues: [TailscaleAdminCredentialValidationIssue]) -> String {
        var fields: [String] = []
        if issues.contains(.missingClientID) || issues.contains(.invalidClientID) { fields.append("Client ID") }
        if issues.contains(.missingClientSecret) { fields.append("client secret") }
        if issues.contains(.missingTailnet) || issues.contains(.invalidTailnet) { fields.append("tailnet") }
        return "Check the administrator \(fields.joined(separator: ", ")). Credentials were not saved or sent."
    }

    private static func tailscaleAdminFailureMessage(_ error: any Error) -> String {
        guard let error = error as? TailscaleAdminConnectionError else {
            return "Administrator device discovery failed. Verify the credentials and network, then Retry."
        }
        switch error {
        case .unauthorized:
            return "Tailscale rejected the administrator credentials. Verify the OAuth client and try again."
        case .forbidden:
            return "This OAuth client cannot read tailnet devices. Grant the read-only Devices scope and try again."
        case .rateLimited:
            return "Tailscale rate-limited device discovery. Wait, then Retry."
        case .missingCredentials:
            return "No saved administrator connection. Enter administrator credentials to connect."
        case .invalidCredentials:
            return "Check the administrator credentials. They were not saved or sent."
        case .networkUnavailable:
            return "The Tailscale administrator API is unreachable. Check the network, then Retry."
        case .keychainUnavailable, .keychainFailure:
            return "OpenPaw could not use Keychain for the administrator connection. Check device security settings and try again."
        case .malformedJSON, .httpStatus:
            return "Tailscale returned an unsupported response. Retry, then check Diagnostics if it continues."
        }
    }

    /// Runs a separate, typed probe connection. It never replaces the active terminal and a stale result cannot
    /// overwrite a newer host check.
    public func runConnectionPreflight(for host: HostRecord) async {
        connectionPreflightGeneration += 1
        let generation = connectionPreflightGeneration
        isConnectionPreflightRunning = true
        connectionPreflightReport = ConnectionPreflightReport()
        guard let connectionPreflightRunner else {
            var report = ConnectionPreflightReport()
            report.failCurrentStage(.transportUnavailable)
            connectionPreflightReport = report
            isConnectionPreflightRunning = false
            return
        }

        let report = await connectionPreflightRunner.run(for: host)
        guard connectionPreflightGeneration == generation else { return }
        connectionPreflightReport = report
        isConnectionPreflightRunning = false
    }

    public func cancelConnectionPreflight() {
        connectionPreflightGeneration += 1
        isConnectionPreflightRunning = false
    }

    @_spi(SnapshotTesting) public func setTailscaleDiscoveryForSnapshot(_ state: TailscaleDiscoveryState) {
        tailscaleDiscoveryTask?.cancel()
        tailscaleDiscovery = state
    }

    public func stopFollowing() {
        eventTask?.cancel()
        eventTask = nil
    }

    public func ingest(_ event: Event) {
        let key = event.sessionID.rawValue
        var stream = transcripts[key] ?? []
        // Content-addressed ids make this the whole of deduplication.
        if stream.contains(where: { $0.eventID == event.eventID }) { return }
        stream.append(event)
        if stream.count > eventBudgetPerSession {
            stream.removeFirst(stream.count - eventBudgetPerSession)
        }
        transcripts[key] = stream

        if let item = InboxProjection.from(event: event) {
            upsert(item)
        }
        if case .permissionResolved(let resolution) = event.body {
            resolveLocally(requestID: resolution.requestID, decision: resolution.decision)
        }
        if let index = sessions.firstIndex(where: { $0.sessionID == key }) {
            sessions[index].lastSeq = max(sessions[index].lastSeq, event.seq)
            sessions[index].lastEventAt = event.timestamp
        }
    }

    private func upsert(_ item: InboxItem) {
        if let index = inbox.firstIndex(where: { $0.id == item.id }) {
            // Keep the host-issued action token; a projection made locally has none.
            var merged = item
            merged.actionToken = inbox[index].actionToken ?? item.actionToken
            inbox[index] = merged
        } else {
            inbox.append(item)
        }
    }

    private func resolveLocally(requestID: String, decision: ActionID) {
        for index in inbox.indices where inbox[index].requestID == requestID {
            inbox[index].status = .resolved
            inbox[index].resolution = decision.rawValue
        }
    }

    // MARK: - Actions

    /// Sends a decision. Refuses an *approval* locally when the item's risk demands an expanded command the user
    /// has not opened, so a mis-wired screen fails here instead of at the host with a 400.
    ///
    /// Refusals are never gated. Making someone read a command before they are allowed to say no would be
    /// backwards: a denial the host rejects costs nothing, a denial the UI blocks costs everything.
    @discardableResult
    public func resolve(_ item: InboxItem, action: ActionID, answer: String? = nil) async -> Bool {
        // The gate speaks first. Whether a backend happens to be attached is unrelated to why an approval was
        // refused, and a silent refusal is the one outcome this screen cannot afford.
        guard !action.isApproval || isDetailAcknowledged(item) else {
            lastError = PresentedError(
                title: "Open the full command first",
                detail: "This request is classified \(item.risk?.riskClass.rawValue ?? "unknown"). "
                    + "Read the command before approving it, or deny it now.",
                isRecoverable: true
            )
            return false
        }
        guard canRefreshRemoteState, connection.isConnected, let backend, let hostID = selectedHostID else {
            lastError = PresentedError(
                title: "Structured host features are unavailable",
                detail: "Reconnect the host to send this decision. The agent is still waiting.",
                isRecoverable: true
            )
            return false
        }
        let generation = connectionGeneration
        let hostGeneration = generation
        var resolvedItem = item
        if item.actionToken == nil, !item.isDismissible {
            do {
                guard let hydrated = try await hydrateActionableItem(item, hostID: hostID, generation: hostGeneration) else {
                    guard selectedHostID == hostID,
                          connectionGeneration == hostGeneration,
                          structuredBackendReady else { return false }
                    lastError = PresentedError(
                        title: "Refresh this request first",
                        detail: "The host did not return a current action token for this request. Reconnect before deciding.",
                        isRecoverable: true
                    )
                    return false
                }
                resolvedItem = hydrated
            } catch {
                guard selectedHostID == hostID, connectionGeneration == generation else { return false }
                present(error, while: "refreshing the inbox item")
                return false
            }
        }
        do {
            let result = try await backend.resolve(
                item: resolvedItem,
                action: action,
                answer: answer,
                detailAcknowledged: isDetailAcknowledged(resolvedItem)
            )
            guard selectedHostID == hostID, connectionGeneration == generation, structuredBackendReady else { return false }
            if let index = inbox.firstIndex(where: { $0.id == item.id }) {
                inbox[index].status = .resolved
                inbox[index].resolution = action.rawValue
                inbox[index].actionToken = nil
            }
            if let warning = result.warning {
                let detail: String
                switch warning {
                case "decision_durability_not_confirmed":
                    detail = "The host committed this decision and spent its one-time token, but could not confirm the decision directory was fully synced. Do not retry. Verify that the waiting agent received the decision."
                case "decision_permissions_not_confirmed":
                    detail = "The host committed this decision and spent its one-time token, but could not confirm the decision file's private permissions. Do not retry. Check the host diagnostics before continuing."
                default:
                    detail = "The host committed this decision and spent its one-time token, but reported a storage warning. Do not retry. Verify the agent's state and check host diagnostics."
                }
                lastError = PresentedError(
                    title: "Decision sent with a storage warning",
                    detail: detail,
                    isRecoverable: false)
            }
            return true
        } catch {
            guard selectedHostID == hostID, connectionGeneration == generation, structuredBackendReady else {
                return false
            }
            present(error, while: "sending the decision")
            return false
        }
    }

    private func hydrateActionableItem(
        _ item: InboxItem,
        hostID: HostRecord.ID,
        generation: Int
    ) async throws -> InboxItem? {
        guard canRefreshRemoteState, let backend else { return nil }
        let loaded = try await backend.inbox(status: .pending)
        guard selectedHostID == hostID, connectionGeneration == generation, structuredBackendReady else { return nil }
        guard let hydrated = loaded.first(where: { $0.id == item.id && $0.actionToken != nil }) else { return nil }
        if let index = inbox.firstIndex(where: { $0.id == item.id }) {
            inbox[index] = hydrated
        } else {
            inbox.append(hydrated)
        }
        return hydrated
    }

    @discardableResult
    public func dismiss(_ item: InboxItem) async -> Bool {
        guard item.isDismissible else {
            lastError = PresentedError(
                title: "This item needs a decision",
                detail: "Permission and question requests cannot be archived. Deny or answer the request instead.",
                isRecoverable: false
            )
            return false
        }
        guard canRefreshRemoteState, connection.isConnected, let backend, let hostID = selectedHostID else {
            lastError = PresentedError(
                title: "Structured host features are unavailable",
                detail: "Reconnect the host before dismissing this item so it stays archived after refresh.",
                isRecoverable: true
            )
            return false
        }
        let generation = connectionGeneration
        do {
            let result = try await backend.dismiss(item: item)
            guard selectedHostID == hostID, connectionGeneration == generation, structuredBackendReady else {
                return false
            }
            guard result.item.id == item.id,
                  result.status == .dismissed,
                  result.item.status == .dismissed,
                  result.item.actionToken == nil else {
                throw HostClientError.decoding(InboxDismissResponseError())
            }
            guard let index = inbox.firstIndex(where: { $0.id == item.id }) else { return true }
            inbox[index] = result.item
            return true
        } catch {
            guard selectedHostID == hostID, connectionGeneration == generation else { return false }
            present(error, while: "dismissing the inbox item")
            return false
        }
    }

    public func sendAgentPrompt(_ prompt: String) async -> Bool {
        await sendTerminalLine(prompt, activity: "sending the agent prompt")
    }

    public func executeTerminalDraft(_ command: String) async -> Bool {
        await sendTerminalLine(command, activity: "executing the terminal draft")
    }

    public func commitVoice(_ action: VoiceCommitAction, attachments: [ComposerAttachment] = []) async -> Bool {
        switch action {
        case .sendAgent(let prompt):
            guard let prompt = await agentPrompt(prompt, with: attachments) else { return false }
            return await sendAgentPrompt(prompt)
        case .executeTerminal(let command):
            guard attachments.isEmpty else {
                present(
                    VoiceCommitError.terminalAttachments,
                    while: "executing the terminal draft"
                )
                return false
            }
            return await executeTerminalDraft(command)
        }
    }

    public func send(prompt: String) async {
        _ = await sendAgentPrompt(prompt)
    }

    private func sendTerminalLine(_ text: String, activity: String) async -> Bool {
        guard let terminal, !text.isEmpty else { return false }
        do {
            try await terminal.send(text: text + "\n")
            return true
        } catch {
            present(error, while: activity)
            return false
        }
    }

    public func uploadComposerAttachments(_ attachments: [ComposerAttachment]) async -> [UploadResult]? {
        guard !attachments.isEmpty else { return [] }
        guard backend != nil && structuredBackendReady, let backend else { return nil }
        let hostID = selectedHostID
        let generation = connectionGeneration
        do {
            var uploaded: [UploadResult] = []
            for attachment in attachments {
                let result = try await backend.upload(data: attachment.data, filename: attachment.filename)
                guard selectedHostID == hostID, connectionGeneration == generation, structuredBackendReady else { return nil }
                uploaded.append(result)
            }
            return uploaded
        } catch {
            present(error, while: "uploading composer attachments")
            return nil
        }
    }

    private func agentPrompt(_ prompt: String, with attachments: [ComposerAttachment]) async -> String? {
        guard !attachments.isEmpty else { return prompt }
        guard let uploads = await uploadComposerAttachments(attachments) else {
            return nil
        }
        guard !uploads.isEmpty else { return prompt }
        let paths = uploads.map { "- \($0.path)" }.joined(separator: "\n")
        return prompt + "\n\nAttached files uploaded to:\n" + paths
    }

    public func canSendAgentAttachments() -> Bool { backend != nil && structuredBackendReady && connection.isConnected }

    /// Selects a saved host without dialing it.
    ///
    /// The host id changes before the asynchronous teardown so every in-flight refresh and event stream becomes stale
    /// immediately. The caller must make a separate `connectSelectedHost()` request after this transaction finishes.
    @discardableResult
    public func selectHost(_ hostID: HostRecord.ID?) async -> HostSelectionLease? {
        let connectionRequestSnapshot = connectionRequestID
        let hostSelectionSnapshot = hostSelectionGeneration
        if hostID == selectedHostID {
            if let hostSelectionOperation { await hostSelectionOperation.value }
            guard connectionRequestID == connectionRequestSnapshot,
                  hostSelectionGeneration == hostSelectionSnapshot,
                  let hostID,
                  selectedHostID == hostID,
                  !isSwitchingHost else { return nil }
            return HostSelectionLease(hostID: hostID, hostSelectionToken: hostSelectionSnapshot)
        }
        hostSelectionGeneration += 1
        let selectionGeneration = hostSelectionGeneration
        isSwitchingHost = true

        stateTaskHostID = nil
        stateAttemptHasConnected = false
        selectedHostID = hostID

        let previousOperation = hostSelectionOperation
        let lifecycle = backend as? any StructuredBackendLifecycle
        let terminal = terminal
        let operation = Task { @MainActor [weak self] in
            if let previousOperation { await previousOperation.value }
            guard let self, self.hostSelectionGeneration == selectionGeneration else { return }
            if let lifecycle { await lifecycle.disconnect() }
            await terminal?.disconnect()
            if self.hostSelectionGeneration == selectionGeneration { self.isSwitchingHost = false }
        }
        hostSelectionOperation = operation
        await operation.value
        guard connectionRequestID == connectionRequestSnapshot,
              hostSelectionGeneration == selectionGeneration,
              let hostID,
              selectedHostID == hostID,
              !isSwitchingHost else { return nil }
        return HostSelectionLease(hostID: hostID, hostSelectionToken: selectionGeneration)
    }

    @discardableResult
    public func connectSelectedHost(purpose: HostConnectPurpose = .normal) async -> HostConnectionLease? {
        guard !isSwitchingHost, let terminal, let host = selectedHost else { return nil }
        connectionRequestID += 1
        let requestID = connectionRequestID
        stopFollowing()
        cancelTailscaleDiscovery()
        let preservesActiveRepoImport = activeRepoImportID != nil && activeRepoImportLease?.hostID == host.id
        clearHostDerivedState(preservingActiveRepoImport: preservesActiveRepoImport)
        structuredBackendReady = backend.map { !($0 is any StructuredBackendLifecycle) } ?? false
        stateTaskHostID = nil
        stateAttemptHasConnected = false
        resumeTerminalConnectAcknowledgement()
        if let lifecycle = backend as? any StructuredBackendLifecycle { await lifecycle.disconnect() }
        await terminal.disconnect()
        let targetHostID = host.id
        stateTaskHostID = targetHostID
        ensureTerminalStateTask(terminal)
        connection = .connecting
        do {
            try await terminal.connect(host: host)
            guard connectionRequestID == requestID,
                  selectedHostID == targetHostID else { return nil }
            if !connection.isConnected {
                await withCheckedContinuation { continuation in
                    if connection.isConnected {
                        continuation.resume()
                    } else {
                        self.terminalConnectAcknowledgement = continuation
                    }
                }
            }
            guard connectionRequestID == requestID,
                  selectedHostID == targetHostID,
                  connection.isConnected else { return nil }
            if let lifecycle = backend as? any StructuredBackendLifecycle {
                do {
                    guard try await connectStructuredBackend(lifecycle, host: host) else { return nil }
                    structuredBackendReady = true
                    updateProviderCapabilityState()
                    guard connectionRequestID == requestID,
                          selectedHostID == targetHostID,
                          connection.isConnected,
                          structuredBackendReady else { return nil }
                    if purpose == .normal {
                        await refresh()
                        startFollowing(session: selectedSessionID)
                    }
                } catch {
                    structuredBackendReady = false
                    clearHostDerivedState(preservingActiveRepoImport: preservesActiveRepoImport)
                    presentStructuredBackendUnavailable(error)
                }
            } else {
                structuredBackendReady = backend != nil
                updateProviderCapabilityState()
                if purpose == .normal {
                    await refresh()
                    startFollowing(session: selectedSessionID)
                }
            }
            if structuredBackendReady { resumeRepoImportPollingAfterReconnect() }
        } catch {
            structuredBackendReady = false
            present(error, while: "connecting to \(host.nickname)")
            return nil
        }
        return connectionLease(hostID: targetHostID, requestID: requestID)
    }

    public var currentConnectionLease: HostConnectionLease? {
        guard let hostID = selectedHostID, connection.isConnected else { return nil }
        return HostConnectionLease(
            hostID: hostID,
            connectionGeneration: connectionGeneration,
            hostSelectionToken: hostSelectionGeneration,
            requestID: connectionRequestID)
    }

    public var currentHostOperationSnapshot: HostOperationSnapshot {
        HostOperationSnapshot(
            selectedHostID: selectedHostID,
            hostSelectionToken: hostSelectionGeneration,
            connectionRequestID: connectionRequestID)
    }

    public func ownsHostOperation(_ snapshot: HostOperationSnapshot) -> Bool {
        currentHostOperationSnapshot == snapshot
    }

    public func ownsSelection(_ lease: HostSelectionLease) -> Bool {
        selectedHostID == lease.hostID && hostSelectionGeneration == lease.hostSelectionToken && !isSwitchingHost
    }

    public func ownsConnection(_ lease: HostConnectionLease) -> Bool {
        connectionLease(hostID: lease.hostID, requestID: lease.requestID) == lease
    }

    /// Reopens only the structured side of an owned SSH connection when a pairing retry needs it.
    public func prepareHostPairing(lease: HostConnectionLease) async throws {
        guard ownsConnection(lease), let host = selectedHost, host.id == lease.hostID else {
            throw HostPairingError.staleConnection
        }
        guard let lifecycle = backend as? any StructuredBackendLifecycle else { return }
        if await lifecycle.isReady {
            structuredBackendReady = true
            return
        }
        guard try await connectStructuredBackend(lifecycle, host: host), ownsConnection(lease) else {
            throw HostPairingError.staleConnection
        }
        structuredBackendReady = true
        updateProviderCapabilityState()
    }

    @discardableResult
    public func pairHost(pairingCode: String, deviceName: String, lease: HostConnectionLease) async throws -> PairingResult {
        guard ownsConnection(lease), let pairing = backend as? any OpenPawHostPairing else { throw HostPairingError.unavailable }
        let result = try await pairing.pair(pairingCode: pairingCode, deviceName: deviceName)
        guard ownsConnection(lease) else { throw HostPairingError.staleConnection }
        await refresh()
        startFollowing(session: selectedSessionID)
        return result
    }

    private func connectionLease(hostID: HostRecord.ID, requestID: Int) -> HostConnectionLease? {
        guard connectionRequestID == requestID,
              selectedHostID == hostID,
              connection.isConnected else { return nil }
        return HostConnectionLease(
            hostID: hostID,
            connectionGeneration: connectionGeneration,
            hostSelectionToken: hostSelectionGeneration,
            requestID: requestID)
    }

    /// Connects one structured lifecycle with explicit ownership.
    ///
    /// `disconnect()` is intentionally issued twice in the host-switch race: once by the selection transaction to
    /// cancel a well-behaved in-flight tunnel immediately, and once here after the previous connect has actually
    /// returned. The second teardown is what contains a backend that ignored cancellation and completed late. A newer
    /// request registers before waiting, so only the latest request may perform stale cleanup; the newer operation then
    /// owns the final disconnect/connect pair and cannot be torn down by its predecessor.
    private func connectStructuredBackend(
        _ lifecycle: any StructuredBackendLifecycle,
        host: HostRecord
    ) async throws -> Bool {
        let hostID = host.id
        structuredConnectRequestID += 1
        let requestID = structuredConnectRequestID
        let previousOperation = structuredConnectOperation
        let operation: Task<Void, any Error> = Task {
            if let previousOperation { _ = try? await previousOperation.value }
            guard structuredConnectRequestID == requestID,
                selectedHostID == hostID,
                connection.isConnected
            else { throw StructuredConnectSuperseded() }
            await lifecycle.disconnect()
            guard structuredConnectRequestID == requestID,
                selectedHostID == hostID,
                connection.isConnected
            else {
                if structuredConnectRequestID == requestID { await lifecycle.disconnect() }
                throw StructuredConnectSuperseded()
            }
            do {
                try await lifecycle.connect(hostID: hostID, options: StructuredBackendConnectOptions(hostAPIPort: host.hostAPIPort))
            } catch {
                guard structuredConnectRequestID == requestID,
                    selectedHostID == hostID,
                    connection.isConnected
                else {
                    if structuredConnectRequestID == requestID { await lifecycle.disconnect() }
                    throw StructuredConnectSuperseded()
                }
                await lifecycle.disconnect()
                throw error
            }
            guard structuredConnectRequestID == requestID,
                selectedHostID == hostID,
                connection.isConnected
            else {
                if structuredConnectRequestID == requestID { await lifecycle.disconnect() }
                throw StructuredConnectSuperseded()
            }
            let ready = await lifecycle.isReady
            guard structuredConnectRequestID == requestID,
                selectedHostID == hostID,
                connection.isConnected,
                ready
            else {
                if structuredConnectRequestID == requestID { await lifecycle.disconnect() }
                throw StructuredConnectSuperseded()
            }
        }
        structuredConnectOperation = operation
        defer {
            if structuredConnectRequestID == requestID { structuredConnectOperation = nil }
        }

        do {
            try await operation.value
            return true
        } catch is StructuredConnectSuperseded {
            return false
        } catch {
            guard structuredConnectRequestID == requestID,
                selectedHostID == hostID,
                connection.isConnected
            else { return false }
            throw error
        }
    }

    public func disconnect() async {
        connectionRequestID += 1
        stopFollowing()
        cancelTailscaleDiscovery()
        let preservesActiveRepoImport = activeRepoImportID != nil && activeRepoImportLease?.hostID == selectedHostID
        clearHostDerivedState(preservingActiveRepoImport: preservesActiveRepoImport)
        stateTaskHostID = nil
        stateAttemptHasConnected = false
        resumeTerminalConnectAcknowledgement()
        if let lifecycle = backend as? any StructuredBackendLifecycle { await lifecycle.disconnect() }
        structuredBackendReady = false
        await terminal?.disconnect()
        connection = .disconnected(reason: nil)
    }

    private func resumeTerminalConnectAcknowledgement() {
        terminalConnectAcknowledgement?.resume()
        terminalConnectAcknowledgement = nil
    }

    /// `TerminalBackend.stateStream` is a single event seam, so it has one consumer for the lifetime of the attached
    /// terminal. Replacing that consumer per host can let a cancelled iterator steal the next attempt's `.connected`
    /// event. Attempts are scoped by `stateTaskHostID` instead.
    private func ensureTerminalStateTask(_ terminal: any TerminalBackend) {
        guard stateTask == nil else { return }
        stateStreamGeneration += 1
        let streamGeneration = stateStreamGeneration
        stateTask = Task { [weak self, terminal] in
            for await state in terminal.stateStream {
                guard let self, self.stateStreamGeneration == streamGeneration else { return }
                guard let targetHostID = self.stateTaskHostID,
                    self.selectedHostID == targetHostID
                else { continue }
                if state.isConnected {
                    self.stateAttemptHasConnected = true
                    self.resumeTerminalConnectAcknowledgement()
                }
                // A `.disconnected` before this attempt ever connected belongs to teardown, not the new host.
                if !self.stateAttemptHasConnected, case .disconnected = state { continue }
                self.connection = state
                if state.isTerminal, let lifecycle = self.backend as? any StructuredBackendLifecycle {
                    self.structuredBackendReady = false
                    await lifecycle.disconnect()
                }
                if case .failed(let error) = state {
                    self.present(error, while: "connecting to \(self.selectedHost?.nickname ?? "host")")
                }
            }
            guard let self, self.stateStreamGeneration == streamGeneration else { return }
            self.stateTask = nil
            self.stateTaskHostID = nil
            self.stateAttemptHasConnected = false
            self.resumeTerminalConnectAcknowledgement()
        }
    }

    private func invalidateSelectedHostDerivedState() {
        stopFollowing()
        cancelTailscaleDiscovery()
        clearHostDerivedState()
        stateTaskHostID = nil
        stateAttemptHasConnected = false
        resumeTerminalConnectAcknowledgement()
        structuredBackendReady = false
        connection = .disconnected(reason: "Host selection changed")
    }

    private struct ProviderRequestContext {
        var backend: any OpenPawBackend
        var lease: HostConnectionLease
    }

    private func providerRequestContext(capability: String, activity: String) -> ProviderRequestContext? {
        guard canRefreshRemoteState, connection.isConnected, let backend, let hostID = selectedHostID else {
            lastError = PresentedError(title: "Structured host features are unavailable", detail: "Reconnect the host before \(activity).", isRecoverable: true)
            return nil
        }
        guard let capabilityProvider = backend as? any PairedHostCapabilityProviding else {
            lastError = PresentedError(title: "This device cannot do that", detail: "Re-pair with the operator profile so this app can verify the required capability.", isRecoverable: true)
            return nil
        }
        if capabilityProvider.pairedCapabilityStatus(capability, hostID: hostID) != .granted {
            lastError = PresentedError(title: "This device cannot do that", detail: "It is missing the \(capability) capability. Re-pair with the operator profile.", isRecoverable: true)
            return nil
        }
        return ProviderRequestContext(
            backend: backend,
            lease: HostConnectionLease(hostID: hostID, connectionGeneration: connectionGeneration, hostSelectionToken: hostSelectionGeneration, requestID: connectionRequestID)
        )
    }

    private func isCurrent(_ lease: HostConnectionLease) -> Bool {
        selectedHostID == lease.hostID
            && connectionGeneration == lease.connectionGeneration
            && hostSelectionGeneration == lease.hostSelectionToken
            && connectionRequestID == lease.requestID
            && structuredBackendReady
            && connection.isConnected
    }

    private func presentedError(_ error: any Error, while activity: String) -> PresentedError {
        if let clientError = error as? HostClientError {
            switch clientError {
            case .forbidden(let capability):
                return PresentedError(title: "This device cannot do that", detail: capability.map { "It is missing the \($0) capability. Re-pair with the operator profile." } ?? "Re-pair with the operator profile.", isRecoverable: true)
            case .badRequest, .server, .decoding:
                return PresentedError(title: "The host rejected the request", detail: "The host returned a provider workflow error. Reconnect or re-pair, then retry.", isRecoverable: true)
            case .unauthorized, .notFound, .transport, .tailscaleDiscovery:
                return PresentedError(title: "Provider workflow unavailable", detail: "Reconnect the host and retry this provider workflow.", isRecoverable: true)
            }
        }
        return PresentedError(title: "Failed while \(activity)", detail: "The host returned an unsafe provider workflow error. Reconnect and retry.", isRecoverable: true)
    }

    private func updateProviderCapabilityState() {
        guard canRefreshRemoteState, let hostID = selectedHostID, let provider = backend as? any PairedHostCapabilityProviding else {
            canListProviders = .unavailable
            canAuthorizeProviders = .unavailable
            canImportRepos = .unavailable
            return
        }
        canListProviders = availability(provider.pairedCapabilityStatus("providers.read", hostID: hostID))
        canAuthorizeProviders = availability(provider.pairedCapabilityStatus("providers.manage", hostID: hostID))
        canImportRepos = availability(provider.pairedCapabilityStatus("repos.manage", hostID: hostID))
    }

    private func availability(_ status: PairedHostCapabilityStatus) -> ProviderCapabilityAvailability {
        switch status {
        case .granted: .available
        case .denied, .unknown: .denied
        }
    }

    private func startProviderAuthorizationPolling(provider: ProviderID, authorizationID: String, lease: HostConnectionLease, intervalSeconds: UInt32) {
        providerAuthorizationPollTask?.cancel()
        providerAuthorizationPollTask = Task { [weak self] in
            var delay = intervalSeconds
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) } catch { return }
                guard let self, self.isCurrent(lease), self.activeAuthorizationProvider == provider, self.activeAuthorizationID == authorizationID else { return }
                await self.pollProviderAuthorization(provider: provider, authorizationID: authorizationID)
                guard self.isCurrent(lease), self.activeAuthorizationProvider == provider, self.activeAuthorizationID == authorizationID else { return }
                if case .polling(let status) = self.providerAuthorizationState {
                    if status.state == .slowDown { delay = min(delay + 5, 60) }
                } else { return }
            }
        }
    }

    private func startRepoImportPolling(importID: String, lease: HostConnectionLease) {
        repoImportPollTask?.cancel()
        repoImportPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.isCurrent(lease), self.activeRepoImportID == importID else { return }
                await self.pollRepoImport(importID)
                guard self.isCurrent(lease), self.activeRepoImportID == importID else { return }
                if case .terminal = self.repoImportState { return }
            }
        }
    }

    public func resumeRepoImportPollingAfterReconnect() {
        guard let importID = activeRepoImportID,
              let context = providerRequestContext(capability: "repos.manage", activity: "resuming repository import") else { return }
        activeRepoImportLease = context.lease
        startRepoImportPolling(importID: importID, lease: context.lease)
    }

    private func markProviderOperationsDisconnected() {
        providerAuthorizationPollTask?.cancel()
        repoImportPollTask?.cancel()
        providerAuthorizationPollTask = nil
        repoImportPollTask = nil
        if let importID = activeRepoImportID {
            failImport(importID: importID, error: HostClientError.transport(URLError(.networkConnectionLost)))
        }
    }

    private func failAuthorization(provider: ProviderID, authorizationID: String?, error: any Error) {
        let presented = presentedError(error, while: "authorizing provider")
        providerAuthorizationState = .failed(provider: provider, authorizationID: authorizationID, error: presented)
        lastError = presented
    }

    private func commitImportProgress(_ progress: RepoImportProgress) {
        switch progress.state {
        case .completed, .failed, .cancelled, .recoveryRequired:
            repoImportState = .terminal(progress)
            repoImportPollTask?.cancel()
            repoImportPollTask = nil
            if progress.state == .completed {
                selectedRepo = progress.destinationName
                repoImportRefreshTask?.cancel()
                repoImportRefreshTask = Task { [weak self] in await self?.refresh() }
            }
        default:
            repoImportState = .progress(progress)
        }
    }

    private func failImport(importID: String?, error: any Error) {
        let presented = presentedError(error, while: "importing repository")
        repoImportState = .failed(importID: importID, error: presented)
        lastError = presented
    }

    private func clearHostDerivedState(preservingActiveRepoImport: Bool = false) {
        health = nil
        sessions = []
        selectedSessionID = nil
        inbox = []
        repos = []
        selectedRepo = nil
        transcripts = [:]
        acknowledgedDetails = []
        providerOperationGeneration += 1
        authorizationOperationGeneration += 1
        providerRepoOperationGeneration += 1
        repoImportOperationGeneration += 1
        providerAuthorizationPollTask?.cancel()
        repoImportPollTask?.cancel()
        repoImportRefreshTask?.cancel()
        providerAuthorizationPollTask = nil
        repoImportPollTask = nil
        repoImportRefreshTask = nil
        activeAuthorizationProvider = nil
        activeAuthorizationID = nil
        if !preservingActiveRepoImport {
            activeRepoImportID = nil
            activeRepoImportLease = nil
        }
        providers = []
        selectedProvider = nil
        canListProviders = .unavailable
        canAuthorizeProviders = .unavailable
        canImportRepos = .unavailable
        providerListState = .idle
        providerAuthorizationState = .idle
        providerRepoPages = ProviderRepoPagesState()
        if !preservingActiveRepoImport { repoImportState = .idle }
    }

    private func presentStructuredBackendUnavailable(_ error: any Error) {
        lastError = PresentedError(
            title: "Structured host features are unavailable",
            detail: "The terminal is connected, but OpenPaw could not reach the structured host service. Sessions, approvals, previews, uploads, and Tailscale discovery will stay unavailable until the service is reachable.",
            isRecoverable: true
        )
    }

    // MARK: - Errors

    /// Errors state what happened and what to do about it. They do not apologise and they are never vague.
    public func present(_ error: any Error, while activity: String) {
        // A host key verdict is a decision the trust sheet takes, not a failure to report. Raising an alert as well
        // would put two presentations on screen at once, and the alert wins: SwiftUI dismisses the sheet through its
        // binding, leaving the user unable to see the fingerprint or ever connect.
        if error.isHostKeyDecision { return }
        if let clientError = error as? HostClientError {
            lastError = switch clientError {
            case .unauthorized:
                PresentedError(
                    title: "This device is no longer paired",
                    detail: "Run `openpaw-host pairing-code` on the host and pair again.",
                    isRecoverable: true
                )
            case .forbidden(let capability):
                PresentedError(
                    title: "This device cannot do that",
                    detail: capability.map { "It is missing the \($0) capability. Re-pair with the operator profile." }
                        ?? "Re-pair with the operator profile to approve requests.",
                    isRecoverable: true
                )
            case .notFound:
                PresentedError(
                    title: "The host does not know about that",
                    detail: "It may have restarted while \(activity). Pull to refresh.",
                    isRecoverable: true
                )
            case .badRequest(let message):
                PresentedError(title: "The host rejected the request", detail: message, isRecoverable: true)
            case .server(let status, let body):
                PresentedError(title: "The host failed (\(status))", detail: body, isRecoverable: true)
            case .transport:
                PresentedError(
                    title: "The tunnel is down",
                    detail: "Reconnect the host to restore the forwarded port.",
                    isRecoverable: true
                )
            case .tailscaleDiscovery(_, let message):
                PresentedError(title: "Tailscale discovery unavailable", detail: message, isRecoverable: true)
            case .decoding:
                PresentedError(
                    title: "This app is older than the host",
                    detail: "The host sent something this build cannot read. Update the app.",
                    isRecoverable: false
                )
            }
        } else {
            lastError = PresentedError(
                title: "Failed while \(activity)",
                detail: String(describing: error),
                isRecoverable: true
            )
        }
    }
}

extension Error {
    /// Whether this is a host key verdict awaiting the user's trust decision rather than a failure to report.
    fileprivate var isHostKeyDecision: Bool {
        guard let transport = self as? TransportError else { return false }
        switch transport {
        case .hostKeyUnknown, .hostKeyChanged: return true
        default: return false
        }
    }
}

private struct InboxDismissResponseError: Error {}
private struct ProviderWorkflowOwnershipError: Error {}

public struct PresentedError: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let title: String
    public let detail: String
    public let isRecoverable: Bool

    public init(title: String, detail: String, isRecoverable: Bool) {
        self.title = title
        self.detail = detail
        self.isRecoverable = isRecoverable
    }
}

public struct HostKeyPrompt: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let host: String
    public let verdict: HostKeyVerdict

    public init(host: String, verdict: HostKeyVerdict) {
        self.host = host
        self.verdict = verdict
    }

    /// `.changed` is never acceptable to continue through, so the sheet has no accept control for it.
    public var allowsTrust: Bool {
        if case .unknown = verdict { return true }
        return false
    }
}
