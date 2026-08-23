import Foundation
import OpenPawProtocol
import OpenPawTerminalCore

/// The truthful inputs Root can hand to the session list. Empty means OpenPaw did not discover anything, not that a
/// transport is healthy or unhealthy.
public struct SessionSpaceSnapshot: Sendable, Hashable {
    public var hostID: HostID?
    public var connectionGeneration: Int
    public var remoteSessions: [RemoteSession]
    public var restoration: SessionRestorationPlan?
    public var transport: SessionTransportPresentation
    public var issues: [String]

    public init(hostID: HostID? = nil, connectionGeneration: Int = 0, remoteSessions: [RemoteSession] = [], restoration: SessionRestorationPlan? = nil, transport: SessionTransportPresentation = .init(), issues: [String] = []) {
        self.hostID = hostID
        self.connectionGeneration = connectionGeneration
        self.remoteSessions = remoteSessions
        self.restoration = restoration
        self.transport = transport
        self.issues = issues
    }

    /// Which multiplexer a "new session" should be created with.
    ///
    /// An explicit host preference always wins. Otherwise the host itself is the evidence: creating a tmux session on
    /// a host that only runs herdr silently does nothing, so the most common multiplexer among the sessions actually
    /// discovered is used, and tmux remains the fallback only when nothing at all is running.
    public var multiplexerForNewSessions: MultiplexerKind {
        if let preferred = transport.preferredMultiplexer { return preferred }
        let tally = Dictionary(grouping: remoteSessions, by: \.kind).mapValues(\.count)
        // Ties break by name so the choice cannot flip between two equally common multiplexers.
        let winner = tally.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.rawValue > rhs.key.rawValue : lhs.value < rhs.value
        }
        return winner?.key ?? .tmux
    }
}

public struct SessionTransportPresentation: Sendable, Hashable {
    public var preferredMultiplexer: MultiplexerKind?
    public var attemptedMultiplexers: [MultiplexerKind]

    public init(preferredMultiplexer: MultiplexerKind? = nil, attemptedMultiplexers: [MultiplexerKind] = []) {
        self.preferredMultiplexer = preferredMultiplexer
        self.attemptedMultiplexers = attemptedMultiplexers
    }

    public var preferenceLabel: String? {
        guard let preferredMultiplexer else { return nil }
        return "Preference: \(preferredMultiplexer.displayName)"
    }

    public var discoveryLabel: String? {
        guard !attemptedMultiplexers.isEmpty else { return nil }
        return "Checked: \(attemptedMultiplexers.map(\.displayName).joined(separator: ", "))"
    }
}

public enum SessionSpaceProvenance: Sendable, Hashable {
    case agentSession(String)
    case multiplexerSession(kind: MultiplexerKind, id: String)
    case restoration(kind: MultiplexerKind, target: String)
    case replacementMultiplexer(kind: MultiplexerKind, directory: String?)
    case bareShellFallback(directory: String?)
}

public struct SessionSpaceItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var provenance: SessionSpaceProvenance
    public var provenanceBadge: String
    public var stateLabel: String
    public var primaryAction: String
    public var secondaryActions: [String]
}

public struct SessionSpacePresentation: Sendable, Hashable {
    public var agentSessions: [SessionSummary]
    public var remoteSessions: [RemoteSession]
    public var restoration: SessionRestorationPlan?
    public var transport: SessionTransportPresentation

    public init(agentSessions: [SessionSummary], remoteSessions: [RemoteSession], restoration: SessionRestorationPlan?, transport: SessionTransportPresentation = .init()) {
        self.agentSessions = agentSessions
        self.remoteSessions = remoteSessions
        self.restoration = restoration
        self.transport = transport
    }

    public var items: [SessionSpaceItem] {
        agentSessions.map(Self.agentItem) + remoteSessions.map(Self.remoteItem)
    }

    public var restorationItem: SessionSpaceItem? {
        guard let restoration else { return nil }
        if restoration.isReattachable, let kind = restoration.multiplexer, let target = restoration.multiplexerTarget {
            guard remoteSessions.contains(where: { $0.kind == kind && $0.id == target && $0.isAlive }) else {
                return SessionSpaceItem(
                    id: "restore-stale:\(kind.rawValue):\(target)",
                    title: target,
                    subtitle: restoration.workingDirectory,
                    provenance: .replacementMultiplexer(kind: kind, directory: restoration.workingDirectory),
                    provenanceBadge: "\(kind.displayName) restoration",
                    stateLabel: "stale target",
                    primaryAction: "Create replacement session",
                    secondaryActions: [])
            }
            return SessionSpaceItem(
                id: "restore:\(kind.rawValue):\(target)",
                title: target,
                subtitle: restoration.workingDirectory,
                provenance: .restoration(kind: kind, target: target),
                provenanceBadge: "\(kind.displayName) restoration",
                stateLabel: "reattachable",
                primaryAction: "Reattach",
                secondaryActions: [])
        }
        if let kind = restoration.multiplexer {
            return SessionSpaceItem(
                id: "restore-create:\(kind.rawValue):\(restoration.workingDirectory ?? "")",
                title: "New \(kind.displayName) session",
                subtitle: restoration.workingDirectory,
                provenance: .replacementMultiplexer(kind: kind, directory: restoration.workingDirectory),
                provenanceBadge: "\(kind.displayName) restoration",
                stateLabel: "replacement session",
                primaryAction: "Create replacement session",
                secondaryActions: [])
        }
        return SessionSpaceItem(
            id: "bare-shell:\(restoration.workingDirectory ?? "")",
            title: restoration.workingDirectory ?? "Last directory",
            subtitle: nil,
            provenance: .bareShellFallback(directory: restoration.workingDirectory),
            provenanceBadge: "bare shell",
            stateLabel: "not reattachable",
            primaryAction: "Open shell",
            secondaryActions: [])
    }

    public var emptyRemoteMessage: String {
        "No tmux, Zellij, GNU Screen, or Herdr sessions were discovered on this host."
    }

    private static func agentItem(_ session: SessionSummary) -> SessionSpaceItem {
        SessionSpaceItem(
            id: "agent:\(session.sessionID)",
            title: session.title ?? session.sessionID,
            subtitle: session.cwd,
            provenance: .agentSession(session.sessionID),
            provenanceBadge: "\(session.agent.displayName) agent",
            stateLabel: SessionStatePresentation.make(session.state).label,
            primaryAction: "Open transcript",
            secondaryActions: [])
    }

    private static func remoteItem(_ session: RemoteSession) -> SessionSpaceItem {
        SessionSpaceItem(
            id: "mux:\(session.kind.rawValue):\(session.id)",
            title: session.name,
            subtitle: session.workingDirectory,
            provenance: .multiplexerSession(kind: session.kind, id: session.id),
            provenanceBadge: session.kind.displayName,
            stateLabel: session.isAlive ? (session.isAttached ? "attached" : "detached") : "exited or stale",
            primaryAction: session.isAlive ? "Attach" : "Attach unavailable",
            secondaryActions: session.isAlive ? ["Rename", "Kill"] : ["Kill"])
    }
}

public enum SessionSpaceNavigationPolicy: Sendable, Hashable {
    case staysInList
    case opensTerminal
}

public struct SessionSpaceActionPolicy: Sendable, Hashable {
    public static func canUseSnapshot(_ snapshot: SessionSpaceSnapshot, hostID: HostID?, generation: Int, isConnected: Bool) -> Bool {
        isConnected && snapshot.hostID == hostID && snapshot.connectionGeneration == generation
    }

    public static func navigation(for action: String) -> SessionSpaceNavigationPolicy {
        switch action {
        case "Attach", "Create replacement session", "Open shell", "Reattach": .opensTerminal
        default: .staysInList
        }
    }

    public static func allows(_ action: String, item: SessionSpaceItem, snapshot: SessionSpaceSnapshot, hostID: HostID?, generation: Int, isConnected: Bool) -> Bool {
        guard canUseSnapshot(snapshot, hostID: hostID, generation: generation, isConnected: isConnected) else { return false }
        return switch (action, item.provenance) {
        case ("Attach", .multiplexerSession): item.primaryAction == "Attach"
        case ("Rename", .multiplexerSession): item.secondaryActions.contains("Rename")
        case ("Kill", .multiplexerSession): item.secondaryActions.contains("Kill")
        case ("Reattach", .restoration), ("Create replacement session", .replacementMultiplexer), ("Open shell", .bareShellFallback): true
        default: false
        }
    }

    public static func validatedNavigation(for action: String, item: SessionSpaceItem, snapshot: SessionSpaceSnapshot, hostID: HostID?, generation: Int, isConnected: Bool) -> SessionSpaceNavigationPolicy? {
        guard allows(action, item: item, snapshot: snapshot, hostID: hostID, generation: generation, isConnected: isConnected) else { return nil }
        return navigation(for: action)
    }
}

public enum SessionRestorationMutation: Sendable, Hashable {
    case save(SessionRestorationPlan)
    case clearMatching(kind: MultiplexerKind, target: String)
}

/// Everything a session-row action is allowed to do after the snapshot/host generation checks pass.
///
/// Restoration changes are explicitly success-only. A failed create must not leave a plan for a session that never
/// existed, and a failed kill must not discard the only recovery information the user still has.
public struct SessionSpaceActionPlan: Sendable, Hashable {
    public var command: MultiplexerCommand
    public var refreshAfterCommand: Bool
    public var navigation: SessionSpaceNavigationPolicy
    public var restorationOnSuccess: SessionRestorationMutation?
    public var capturedAt: Date

    public init(
        command: MultiplexerCommand,
        refreshAfterCommand: Bool,
        navigation: SessionSpaceNavigationPolicy,
        restorationOnSuccess: SessionRestorationMutation? = nil,
        capturedAt: Date = Date()
    ) {
        self.command = command
        self.refreshAfterCommand = refreshAfterCommand
        self.navigation = navigation
        self.restorationOnSuccess = restorationOnSuccess
        self.capturedAt = capturedAt
    }

    public static func attach(
        hostID: HostID,
        session: RemoteSession,
        capturedAt: Date = Date()
    ) -> SessionSpaceActionPlan? {
        guard let restoration = SessionRestorationRecorder().planForAttach(
            hostID: hostID,
            session: session,
            capturedAt: capturedAt) else { return nil }
        return SessionSpaceActionPlan(
            command: .attach(session),
            refreshAfterCommand: false,
            navigation: .opensTerminal,
            restorationOnSuccess: .save(restoration),
            capturedAt: capturedAt)
    }

    public static func create(
        hostID: HostID,
        kind: MultiplexerKind,
        name: String,
        directory: String? = nil,
        capturedAt: Date = Date()
    ) -> SessionSpaceActionPlan? {
        guard let restoration = SessionRestorationRecorder().planForCreate(
            hostID: hostID,
            kind: kind,
            name: name,
            directory: directory,
            capturedAt: capturedAt) else { return nil }
        return SessionSpaceActionPlan(
            command: .create(kind: kind, name: name, directory: directory),
            refreshAfterCommand: true,
            navigation: .opensTerminal,
            restorationOnSuccess: .save(restoration),
            capturedAt: capturedAt)
    }

    public static func rename(session: RemoteSession, to name: String) -> SessionSpaceActionPlan {
        SessionSpaceActionPlan(
            command: .rename(session, to: name),
            refreshAfterCommand: true,
            navigation: .staysInList)
    }

    public static func kill(session: RemoteSession) -> SessionSpaceActionPlan {
        SessionSpaceActionPlan(
            command: .kill(session),
            refreshAfterCommand: true,
            navigation: .staysInList,
            restorationOnSuccess: .clearMatching(kind: session.kind, target: session.id))
    }

    public static func restore(
        _ restoration: SessionRestorationPlan,
        remoteSessions: [RemoteSession],
        capturedAt: Date = Date()
    ) -> SessionSpaceActionPlan? {
        if let kind = restoration.multiplexer,
           let target = restoration.multiplexerTarget,
           (!restoration.isReattachable
            || !remoteSessions.contains(where: { $0.kind == kind && $0.id == target && $0.isAlive })) {
            let replacementName = restoration.newSessionName
            let replacement = SessionRestorationPlan(
                hostID: restoration.hostID,
                multiplexer: kind,
                multiplexerTarget: replacementName,
                workingDirectory: restoration.workingDirectory,
                agentSessionID: restoration.agentSessionID,
                capturedAt: capturedAt)
            return SessionSpaceActionPlan(
                command: .create(
                    kind: kind,
                    name: replacementName,
                    directory: restoration.workingDirectory),
                refreshAfterCommand: false,
                navigation: .opensTerminal,
                restorationOnSuccess: .save(replacement),
                capturedAt: capturedAt)
        }
        guard let command = restoration.command() else { return nil }
        return SessionSpaceActionPlan(
            command: command,
            refreshAfterCommand: false,
            navigation: .opensTerminal,
            capturedAt: capturedAt)
    }
}

@MainActor
public protocol SessionSpaceProviding: AnyObject {
    func snapshot(for model: OpenPawModel) async -> SessionSpaceSnapshot
}

public final class EmptySessionSpaceProvider: SessionSpaceProviding {
    public init() {}
    public func snapshot(for model: OpenPawModel) async -> SessionSpaceSnapshot { SessionSpaceSnapshot() }
}

public final class LiveMultiplexerSessionSpaceProvider: SessionSpaceProviding {
    private let runner: any CommandRunner
    private let adapters: [any MultiplexerAdapter]
    private let preferred: MultiplexerKind?
    private let restorationStore: (any SessionRestorationStoring)?

    public init(runner: any CommandRunner, adapters: [any MultiplexerAdapter] = MultiplexerAdapters.all, preferred: MultiplexerKind? = nil, restorationStore: (any SessionRestorationStoring)? = nil) {
        self.runner = runner
        self.adapters = adapters
        self.preferred = preferred
        self.restorationStore = restorationStore
    }

    public func snapshot(for model: OpenPawModel) async -> SessionSpaceSnapshot {
        guard let hostID = model.selectedHostID, model.connection.isConnected else { return SessionSpaceSnapshot() }
        var sessions: [RemoteSession] = []
        var issues: [String] = []
        for adapter in adapters {
            do {
                sessions.append(contentsOf: try await adapter.discoverSessions(runner: runner))
            } catch is MultiplexerError {
                issues.append("\(adapter.kind.displayName): discovery output could not be read")
            } catch let failure as CommandFailure {
                if failure.exitCode != 127 {
                    issues.append("\(adapter.kind.displayName): discovery command failed with exit \(failure.exitCode)")
                }
            } catch {
                issues.append("\(adapter.kind.displayName): discovery is unavailable")
            }
        }
        let restoration = await restorationStore?.loadPlan(for: hostID)
        return SessionSpaceSnapshot(
            hostID: hostID,
            connectionGeneration: model.connectionGeneration,
            remoteSessions: sessions,
            restoration: restoration,
            transport: SessionTransportPresentation(preferredMultiplexer: model.selectedHost?.multiplexerPreference ?? preferred, attemptedMultiplexers: adapters.map(\.kind)),
            issues: issues)
    }
}

@MainActor
public protocol SessionRestorationStoring: AnyObject {
    func loadPlan(for hostID: HostID) async -> SessionRestorationPlan?
    /// Applies one success-only mutation after rechecking ownership inside the store's MainActor transaction.
    /// Implementations may suspend before the check, but must not suspend between a `true` check and persistence.
    func apply(
        _ mutation: SessionRestorationMutation,
        expectedHostID: HostID,
        ifCurrent: @escaping @MainActor () -> Bool
    ) async -> Bool
}

public extension SessionRestorationStoring {
    func save(_ plan: SessionRestorationPlan) async {
        _ = await apply(.save(plan), expectedHostID: plan.hostID, ifCurrent: { true })
    }
}

public final class LocalSessionRestorationStore: SessionRestorationStoring {
    private struct Envelope: Codable { var plans: [String: SessionRestorationPlan] }

    private let url: URL
    private let maxPlans: Int
    private let fileManager: FileManager
    private var plans: [HostID: SessionRestorationPlan]?

    public convenience init(maxPlans: Int = 20) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(directory: directory, maxPlans: maxPlans)
    }

    public init(directory: URL, maxPlans: Int = 20, fileManager: FileManager = .default) {
        self.url = directory.appendingPathComponent("session-restoration.json")
        self.maxPlans = max(1, maxPlans)
        self.fileManager = fileManager
    }

    public func loadPlan(for hostID: HostID) async -> SessionRestorationPlan? {
        loadIfNeeded()[hostID]
    }

    public func apply(
        _ mutation: SessionRestorationMutation,
        expectedHostID: HostID,
        ifCurrent: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard ifCurrent() else { return false }
        var current = loadIfNeeded()
        switch mutation {
        case .save(let plan):
            guard plan.hostID == expectedHostID else { return false }
            current[expectedHostID] = plan
            plans = bounded(current)
            persist()
        case .clearMatching(let kind, let target):
            if let plan = current[expectedHostID],
               plan.multiplexer == kind,
               plan.multiplexerTarget == target {
                current.removeValue(forKey: expectedHostID)
                plans = current
                persist()
            }
        }
        return true
    }

    private func loadIfNeeded() -> [HostID: SessionRestorationPlan] {
        if let plans { return plans }
        guard let data = try? Data(contentsOf: url) else {
            plans = [:]
            return [:]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            plans = [:]
            return [:]
        }
        let decoded = envelope.plans.reduce(into: [HostID: SessionRestorationPlan]()) { partial, entry in
            guard let hostID = UUID(uuidString: entry.key), entry.value.hostID == hostID else { return }
            partial[hostID] = entry.value
        }
        plans = bounded(decoded)
        return plans ?? [:]
    }

    private func bounded(_ input: [HostID: SessionRestorationPlan]) -> [HostID: SessionRestorationPlan] {
        Dictionary(uniqueKeysWithValues: input.sorted { $0.value.capturedAt > $1.value.capturedAt }.prefix(maxPlans).map { ($0.key, $0.value) })
    }

    private func persist() {
        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let keyed = (plans ?? [:]).reduce(into: [String: SessionRestorationPlan]()) { $0[$1.key.uuidString] = $1.value }
        guard let data = try? JSONEncoder().encode(Envelope(plans: keyed)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

@MainActor
public protocol SessionSpaceCommandExecuting: AnyObject {
    func executeSessionCommand(_ command: MultiplexerCommand) async throws -> SessionCommandAcknowledgement
}

public struct SessionCommandAcknowledgement: Sendable, Hashable {
    /// The exact remote handle discovered before attach or after acknowledged background creation.
    public var session: RemoteSession?

    public init(session: RemoteSession? = nil) {
        self.session = session
    }
}

public final class EmptySessionSpaceCommandExecutor: SessionSpaceCommandExecuting {
    public init() {}
    public func executeSessionCommand(_ command: MultiplexerCommand) async throws -> SessionCommandAcknowledgement {
        SessionCommandAcknowledgement()
    }
}

/// The complete host ownership state used before and after every suspension in a session action.
///
/// Keeping the snapshot in this value matters: a host can reconnect without changing its id, and rows discovered by
/// the previous connection must not execute against the new terminal merely because the selected host still matches.
public struct SessionSpaceActionContext: Sendable, Hashable {
    public var snapshot: SessionSpaceSnapshot
    public var hostID: HostID?
    public var connectionGeneration: Int
    public var isConnected: Bool

    public init(
        snapshot: SessionSpaceSnapshot,
        hostID: HostID?,
        connectionGeneration: Int,
        isConnected: Bool
    ) {
        self.snapshot = snapshot
        self.hostID = hostID
        self.connectionGeneration = connectionGeneration
        self.isConnected = isConnected
    }

    public func owns(hostID expectedHostID: HostID, generation expectedGeneration: Int) -> Bool {
        isConnected
            && hostID == expectedHostID
            && connectionGeneration == expectedGeneration
            && snapshot.hostID == expectedHostID
            && snapshot.connectionGeneration == expectedGeneration
    }
}

/// Executes one typed session action as a success-only transaction.
///
/// The caller supplies live ownership state instead of a captured Boolean so every await boundary is checked. Routing
/// is returned only after the remote command, optional refresh, and restoration mutation complete while the same host
/// generation still owns the action. A stale action therefore cannot navigate a newer connection or write its recovery
/// state into the visible workflow.
@MainActor
public enum SessionSpaceActionCoordinator {
    public static func run(
        _ action: SessionSpaceActionPlan,
        expectedHostID: HostID,
        expectedGeneration: Int,
        context: @escaping @MainActor () -> SessionSpaceActionContext,
        executor: any SessionSpaceCommandExecuting,
        restorationStore: (any SessionRestorationStoring)? = nil,
        refresh: @escaping @MainActor () async -> Void = {}
    ) async throws -> SessionRootIntent? {
        _ = try action.command.rendered()
        let stillOwnsAction: @MainActor @Sendable () -> Bool = {
            context().owns(hostID: expectedHostID, generation: expectedGeneration)
        }
        guard stillOwnsAction() else { return nil }

        let acknowledgement: SessionCommandAcknowledgement
        do {
            acknowledgement = try await executor.executeSessionCommand(action.command)
        } catch {
            guard stillOwnsAction() else { return nil }
            throw error
        }
        guard stillOwnsAction() else { return nil }

        if let restorationStore, let mutation = resolvedRestorationMutation(
            action.restorationOnSuccess,
            acknowledgement: acknowledgement) {
            let committed = await restorationStore.apply(
                mutation,
                expectedHostID: expectedHostID,
                ifCurrent: stillOwnsAction)
            guard committed else { return nil }
        }

        if action.refreshAfterCommand {
            await refresh()
            guard stillOwnsAction() else { return nil }
        }
        guard stillOwnsAction() else { return nil }
        return rootIntent(for: action, acknowledgement: acknowledgement)
    }

    private static func resolvedRestorationMutation(
        _ mutation: SessionRestorationMutation?,
        acknowledgement: SessionCommandAcknowledgement
    ) -> SessionRestorationMutation? {
        guard case .save(var plan) = mutation, let session = acknowledgement.session else { return mutation }
        guard plan.multiplexer == session.kind else { return mutation }
        plan.multiplexerTarget = session.id
        plan.multiplexerAttachmentTarget = session.terminalID
        if plan.workingDirectory == nil { plan.workingDirectory = session.workingDirectory }
        return .save(plan)
    }

    private static func rootIntent(
        for action: SessionSpaceActionPlan,
        acknowledgement: SessionCommandAcknowledgement
    ) -> SessionRootIntent? {
        guard action.navigation == .opensTerminal else { return nil }
        return switch action.command {
        case .attach(let session): .attachSession(acknowledgement.session ?? session)
        case .create(let kind, let name, _): .attachSession(acknowledgement.session ?? .target(name, kind: kind))
        case .focus, .kill, .rename, .changeDirectory: .openTerminalSession
        }
    }
}

/// Executes only typed session operations. Commands that can complete outside the interactive display use the SSH
/// command channel so success means the remote process exited successfully. Attach/create/focus operations stay in the
/// live PTY because their purpose is to move the user's visible terminal into that session.
public final class TerminalSessionCommandExecutor: SessionSpaceCommandExecuting {
    private struct TerminalRunner: CommandRunner {
        let terminal: any TerminalBackend
        func run(_ command: String) async throws -> String {
            try await terminal.run(command: command)
        }
    }

    private let terminal: any TerminalBackend
    private let runner: any CommandRunner

    public init(terminal: any TerminalBackend) {
        self.terminal = terminal
        self.runner = TerminalRunner(terminal: terminal)
    }

    public init(terminal: any TerminalBackend, runner: any CommandRunner) {
        self.terminal = terminal
        self.runner = runner
    }

    public func executeSessionCommand(_ command: MultiplexerCommand) async throws -> SessionCommandAcknowledgement {
        let rendered = try command.rendered()
        switch command {
        case .kill, .rename:
            _ = try await runner.run(rendered)
            return SessionCommandAcknowledgement()
        case .focus(let kind, let window):
            if kind == .herdr {
                let requested = RemoteSession.target(window.sessionID, kind: .herdr)
                let adapter = HerdrAdapter()
                let output = try await runner.run(adapter.paneProbeCommand(requested))
                try adapter.validatePaneProbeResponse(output, expectedPaneID: requested.id)
                try await terminal.send(text: rendered + "\n")
                return SessionCommandAcknowledgement(session: requested)
            }
            _ = try await runner.run(rendered)
            return SessionCommandAcknowledgement()
        case .attach(let requested):
            let session = try await acknowledgedSession(matching: requested)
            let attach = MultiplexerAdapters.adapter(for: session.kind).attach(session)
            try await terminal.send(text: attach + "\n")
            return SessionCommandAcknowledgement(session: session)
        case .create(let kind, let name, let directory):
            let adapter = MultiplexerAdapters.adapter(for: kind)
            let output = try await runner.run(adapter.createDetached(name: name, directory: directory))
            let session = if kind == .herdr {
                try HerdrAdapter().parseCreatedSession(output, name: name, directory: directory)
            } else {
                try await acknowledgedCreatedSession(kind: kind, name: name)
            }
            try await terminal.send(text: adapter.attach(session) + "\n")
            return SessionCommandAcknowledgement(session: session)
        case .changeDirectory(let directory):
            _ = try await runner.run("test -d \(shellQuoted(directory))")
            try await terminal.send(text: rendered + "\n")
            return SessionCommandAcknowledgement()
        }
    }

    private func acknowledgedSession(matching requested: RemoteSession) async throws -> RemoteSession {
        if requested.kind == .herdr {
            let adapter = HerdrAdapter()
            let output = try await runner.run(adapter.paneProbeCommand(requested))
            try adapter.validatePaneProbeResponse(output, expectedPaneID: requested.id)
            return requested
        }
        let sessions = try await MultiplexerAdapters.adapter(for: requested.kind)
            .discoverSessions(runner: runner)
        guard let session = sessions.first(where: { candidate in
            candidate.isAlive && Self.matches(candidate, target: requested.id)
        }) else {
            throw SessionSpaceCommandExecutionError.sessionUnavailable(
                kind: requested.kind,
                target: requested.id)
        }
        return session
    }

    private func acknowledgedCreatedSession(kind: MultiplexerKind, name: String) async throws -> RemoteSession {
        let sessions = try await MultiplexerAdapters.adapter(for: kind)
            .discoverSessions(runner: runner)
        guard let session = sessions.first(where: { candidate in
            candidate.isAlive && Self.matches(candidate, target: name)
        }) else {
            throw SessionSpaceCommandExecutionError.creationNotAcknowledged(kind: kind, name: name)
        }
        return session
    }

    private static func matches(_ session: RemoteSession, target: String) -> Bool {
        session.id == target || session.name == target || session.id.hasSuffix(".\(target)")
    }
}

public enum SessionSpaceCommandExecutionError: Error, Sendable, Hashable {
    case sessionUnavailable(kind: MultiplexerKind, target: String)
    case creationNotAcknowledged(kind: MultiplexerKind, name: String)
}

public struct SessionRestorationRecorder: Sendable {
    public init() {}

    public func planForAttach(hostID: HostID, session: RemoteSession, capturedAt: Date = Date()) -> SessionRestorationPlan? {
        guard session.isAlive else { return nil }
        return SessionRestorationPlan(
            hostID: hostID,
            multiplexer: session.kind,
            multiplexerTarget: session.id,
            multiplexerAttachmentTarget: session.terminalID,
            workingDirectory: session.workingDirectory,
            capturedAt: capturedAt)
    }

    public func planForCreate(
        hostID: HostID,
        kind: MultiplexerKind,
        name: String,
        directory: String? = nil,
        capturedAt: Date = Date()
    ) -> SessionRestorationPlan? {
        guard !name.isEmpty else { return nil }
        return SessionRestorationPlan(
            hostID: hostID,
            multiplexer: kind,
            multiplexerTarget: name,
            workingDirectory: directory,
            capturedAt: capturedAt)
    }

    public func bareShellPlanIfAppropriate(hostID: HostID, remoteDirectory: String, existingPlan: SessionRestorationPlan?, capturedAt: Date = Date()) -> SessionRestorationPlan? {
        guard existingPlan?.isReattachable != true else { return nil }
        return SessionRestorationPlan(
            hostID: hostID,
            workingDirectory: remoteDirectory.isEmpty ? nil : remoteDirectory,
            capturedAt: capturedAt)
    }
}
