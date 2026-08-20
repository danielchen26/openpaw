import Foundation
import Observation
import OpenPawProtocol
import OpenPawTerminalCore

/// The single observable root the app and every screen read from.
///
/// It owns no transport and no networking: it is handed an `OpenPawBackend` and a `TerminalBackend`, which is what
/// lets the whole UI render in a headless snapshot run and in tests. All mutation happens on the main actor, so
/// SwiftUI never sees a half-applied update.
@MainActor
@Observable
public final class OpenPawModel {

    // MARK: - Wiring

    public private(set) var backend: (any OpenPawBackend)?
    public private(set) var terminal: (any TerminalBackend)?
    public var dictation: (any DictationEngine)?

    // MARK: - Hosts and connection

    public var hostStore: HostStore
    public var selectedHostID: HostRecord.ID?
    public var connection: ConnectionState = .idle
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

    private var eventTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private let reducer = TranscriptReducer()

    public init(
        hostStore: HostStore = HostStore(),
        backend: (any OpenPawBackend)? = nil,
        terminal: (any TerminalBackend)? = nil,
        dictation: (any DictationEngine)? = nil
    ) {
        self.hostStore = hostStore
        self.backend = backend
        self.terminal = terminal
        self.dictation = dictation
        self.selectedHostID = hostStore.hosts.first?.id
    }

    public func attach(backend: (any OpenPawBackend)?, terminal: (any TerminalBackend)?) {
        self.backend = backend
        self.terminal = terminal
    }

    // MARK: - Derived state

    public var selectedHost: HostRecord? {
        guard let selectedHostID else { return nil }
        return hostStore.hosts.first { $0.id == selectedHostID }
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
        guard let backend else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let health = backend.health()
            async let sessions = backend.sessions()
            async let inbox = backend.inbox(status: nil)
            async let repos = backend.repos()
            self.health = try await health
            self.sessions = try await sessions
            self.inbox = try await inbox
            self.repos = try await repos
            if selectedSessionID == nil { selectedSessionID = self.sessions.first?.sessionID }
            if selectedRepo == nil { selectedRepo = self.repos.first?.name }
        } catch {
            present(error, while: "loading host state")
        }
    }

    /// Follows the host's SSE stream. Resumes from the highest `seq` we already hold, which is exact because
    /// `seq` is dense per session and `event_id` is content addressed, so a reconnect cannot duplicate a row.
    public func startFollowing(session sessionID: String?) {
        guard let backend else { return }
        eventTask?.cancel()
        let afterSeq = sessionID.flatMap { transcripts[$0]?.map(\.seq).max() }
        eventTask = Task { [weak self] in
            do {
                for try await event in backend.events(session: sessionID, afterSeq: afterSeq) {
                    guard let self else { return }
                    self.ingest(event)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.present(error, while: "following the event stream")
            }
        }
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
        guard let backend else {
            lastError = PresentedError(
                title: "No host is connected",
                detail: "Reconnect the host to send this decision. The agent is still waiting.",
                isRecoverable: true
            )
            return false
        }
        do {
            _ = try await backend.resolve(
                item: item,
                action: action,
                answer: answer,
                detailAcknowledged: isDetailAcknowledged(item)
            )
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

    public func send(prompt: String) async {
        guard let terminal, !prompt.isEmpty else { return }
        do {
            try await terminal.send(text: prompt + "\n")
        } catch {
            present(error, while: "sending to the terminal")
        }
    }

    public func connectSelectedHost() async {
        guard let terminal, let host = selectedHost else { return }
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await state in terminal.stateStream {
                guard let self else { return }
                self.connection = state
                if case .failed(let error) = state {
                    self.present(error, while: "connecting to \(host.nickname)")
                }
            }
        }
        do {
            try await terminal.connect(host: host)
        } catch {
            present(error, while: "connecting to \(host.nickname)")
        }
    }

    public func disconnect() async {
        stopFollowing()
        stateTask?.cancel()
        stateTask = nil
        await terminal?.disconnect()
        connection = .disconnected(reason: nil)
    }

    // MARK: - Errors

    /// Errors state what happened and what to do about it. They do not apologise and they are never vague.
    public func present(_ error: any Error, while activity: String) {
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
