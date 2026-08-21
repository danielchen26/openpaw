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
    func save(_ plan: SessionRestorationPlan) async
    func clearPlan(for hostID: HostID) async
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

    public func save(_ plan: SessionRestorationPlan) async {
        var current = loadIfNeeded()
        current[plan.hostID] = plan
        plans = bounded(current)
        persist()
    }

    public func clearPlan(for hostID: HostID) async {
        var current = loadIfNeeded()
        current.removeValue(forKey: hostID)
        plans = current
        persist()
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
    func executeSessionCommand(_ command: String) async throws
}

public final class EmptySessionSpaceCommandExecutor: SessionSpaceCommandExecuting {
    public init() {}
    public func executeSessionCommand(_ command: String) async throws {}
}

public struct SessionRestorationRecorder: Sendable {
    public init() {}

    public func planForAttach(hostID: HostID, session: RemoteSession, capturedAt: Date = Date()) -> SessionRestorationPlan? {
        guard session.isAlive else { return nil }
        return SessionRestorationPlan(
            hostID: hostID,
            multiplexer: session.kind,
            multiplexerTarget: session.id,
            workingDirectory: session.workingDirectory,
            capturedAt: capturedAt)
    }

    public func planForCreate(hostID: HostID, kind: MultiplexerKind, name: String, capturedAt: Date = Date()) -> SessionRestorationPlan? {
        guard !name.isEmpty else { return nil }
        return SessionRestorationPlan(hostID: hostID, multiplexer: kind, multiplexerTarget: name, capturedAt: capturedAt)
    }

    public func bareShellPlanIfAppropriate(hostID: HostID, remoteDirectory: String, existingPlan: SessionRestorationPlan?, capturedAt: Date = Date()) -> SessionRestorationPlan? {
        guard existingPlan?.isReattachable != true else { return nil }
        return SessionRestorationPlan(
            hostID: hostID,
            workingDirectory: remoteDirectory.isEmpty ? nil : remoteDirectory,
            capturedAt: capturedAt)
    }
}
