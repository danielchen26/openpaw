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
    case unavailable(code: TailscaleDiscoveryErrorCode, message: String)
    case failure(message: String)

    public var candidates: [TailscaleDeviceCandidate] { if case .candidates(let items) = self { items } else { [] } }
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
        didSet { connectionGeneration += 1 }
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
    public var eventBudgetPerSession: Int = 2_000

    // MARK: - Inbox

    public var inbox: [InboxItem] = []
    /// Items the user has expanded far enough that the host will accept a decision.
    public private(set) var acknowledgedDetails: Set<String> = []

    // MARK: - Repositories

    public var repos: [RepoSummary] = []
    public var selectedRepo: String?

    // MARK: - Diagnostics and errors

    public var health: HealthInfo?
    public var lastError: PresentedError?
    public var isRefreshing = false
    public private(set) var tailscaleDiscovery: TailscaleDiscoveryState = .idle

    private var tailscaleDiscoveryTask: Task<Void, Never>?
    private var tailscaleDiscoveryGeneration = 0
    private var hostSelectionGeneration = 0

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
    private let reducer = TranscriptReducer()

    public init(
        hostStore: HostStore = HostStore(),
        backend: (any OpenPawBackend)? = nil,
        terminal: (any TerminalBackend)? = nil,
        dictation: (any DictationEngine)? = nil,
        dictationModels: (any DictationModelInstalling)? = nil,
        dictationEngineFactory: (any DictationEngineMaking)? = nil
    ) {
        self.hostStore = hostStore
        self.backend = backend
        self.terminal = terminal
        self.dictation = dictation
        self.dictationEngineFactory = dictationEngineFactory
        if let dictationModels { self.dictationModels = dictationModels }
        self.selectedHostID = hostStore.hosts.first?.id
        self.structuredBackendReady = backend.map { !($0 is any StructuredBackendLifecycle) } ?? false
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

    public func refreshTailscaleDevices() {
        tailscaleDiscoveryGeneration += 1
        let generation = tailscaleDiscoveryGeneration
        tailscaleDiscoveryTask?.cancel()
        guard selectedHost != nil, connection.isConnected, structuredBackendReady, let backend, let hostID = selectedHostID else {
            tailscaleDiscovery = .noConnectedHost
            return
        }
        let connectionGeneration = connectionGeneration
        tailscaleDiscovery = .loading
        tailscaleDiscoveryTask = Task { [weak self, backend] in
            do {
                let response = try await backend.tailscaleDevices()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.tailscaleDiscoveryGeneration == generation, self.selectedHostID == hostID, self.connectionGeneration == connectionGeneration, self.structuredBackendReady else { return }
                    self.tailscaleDiscovery = response.candidates.isEmpty ? .empty : .candidates(response.candidates)
                }
            } catch is CancellationError {
            } catch HostClientError.tailscaleDiscovery(let code, let message) {
                await MainActor.run {
                    guard let self, self.tailscaleDiscoveryGeneration == generation, self.selectedHostID == hostID, self.connectionGeneration == connectionGeneration else { return }
                    self.tailscaleDiscovery = .unavailable(code: code, message: message)
                }
            } catch {
                await MainActor.run {
                    guard let self, self.tailscaleDiscoveryGeneration == generation, self.selectedHostID == hostID, self.connectionGeneration == connectionGeneration else { return }
                    self.tailscaleDiscovery = .failure(message: "Tailscale discovery failed. Retry or add SSH details manually.")
                }
            }
        }
    }

    public func cancelTailscaleDiscovery() {
        tailscaleDiscoveryGeneration += 1
        tailscaleDiscoveryTask?.cancel()
        tailscaleDiscoveryTask = nil
        tailscaleDiscovery = .idle
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
        do {
            _ = try await backend.resolve(
                item: item,
                action: action,
                answer: answer,
                detailAcknowledged: isDetailAcknowledged(item)
            )
            guard selectedHostID == hostID, connectionGeneration == generation, structuredBackendReady else { return false }
            if let index = inbox.firstIndex(where: { $0.id == item.id }) {
                inbox[index].status = .resolved
                inbox[index].resolution = action.rawValue
                inbox[index].actionToken = nil
            }
            return true
        } catch {
            present(error, while: "sending the decision")
            return false
        }
    }

    public func dismiss(_ item: InboxItem) {
        guard let index = inbox.firstIndex(where: { $0.id == item.id }) else { return }
        inbox[index].status = .dismissed
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
    public func selectHost(_ hostID: HostRecord.ID?) async {
        guard hostID != selectedHostID else { return }
        hostSelectionGeneration += 1
        let selectionGeneration = hostSelectionGeneration
        isSwitchingHost = true

        stateTaskHostID = nil
        stateAttemptHasConnected = false
        selectedHostID = hostID

        if let lifecycle = backend as? any StructuredBackendLifecycle { await lifecycle.disconnect() }
        await terminal?.disconnect()

        if hostSelectionGeneration == selectionGeneration { isSwitchingHost = false }
    }

    public func connectSelectedHost() async {
        guard !isSwitchingHost, let terminal, let host = selectedHost else { return }
        stopFollowing()
        cancelTailscaleDiscovery()
        clearHostDerivedState()
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
            guard selectedHostID == targetHostID else { return }
            if !connection.isConnected {
                await withCheckedContinuation { continuation in
                    if connection.isConnected {
                        continuation.resume()
                    } else {
                        self.terminalConnectAcknowledgement = continuation
                    }
                }
            }
            guard selectedHostID == targetHostID, connection.isConnected else { return }
            if let lifecycle = backend as? any StructuredBackendLifecycle {
                do {
                    guard try await connectStructuredBackend(lifecycle, hostID: targetHostID) else { return }
                    structuredBackendReady = true
                    guard selectedHostID == targetHostID, connection.isConnected, structuredBackendReady else { return }
                    await refresh()
                    startFollowing(session: selectedSessionID)
                } catch {
                    structuredBackendReady = false
                    clearHostDerivedState()
                    presentStructuredBackendUnavailable(error)
                }
            } else {
                structuredBackendReady = backend != nil
                await refresh()
                startFollowing(session: selectedSessionID)
            }
        } catch {
            structuredBackendReady = false
            present(error, while: "connecting to \(host.nickname)")
        }
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
        hostID: HostRecord.ID
    ) async throws -> Bool {
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
                try await lifecycle.connect(hostID: hostID)
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
        stopFollowing()
        cancelTailscaleDiscovery()
        clearHostDerivedState()
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

    private func clearHostDerivedState() {
        health = nil
        sessions = []
        selectedSessionID = nil
        inbox = []
        repos = []
        selectedRepo = nil
        transcripts = [:]
        acknowledgedDetails = []
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
