import Foundation
import OpenPawProtocol
import OpenPawTerminalCore

/// The truthful inputs Root can hand to the session list. Empty means OpenPaw did not discover anything, not that a
/// transport is healthy or unhealthy.
public struct SessionSpaceSnapshot: Sendable, Hashable {
    public var remoteSessions: [RemoteSession]
    public var restoration: SessionRestorationPlan?
    public var transport: SessionTransportPresentation

    public init(remoteSessions: [RemoteSession] = [], restoration: SessionRestorationPlan? = nil, transport: SessionTransportPresentation = .init()) {
        self.remoteSessions = remoteSessions
        self.restoration = restoration
        self.transport = transport
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

@MainActor
public protocol SessionSpaceProviding: AnyObject {
    func snapshot(for model: OpenPawModel) async -> SessionSpaceSnapshot
}

public final class EmptySessionSpaceProvider: SessionSpaceProviding {
    public init() {}
    public func snapshot(for model: OpenPawModel) async -> SessionSpaceSnapshot { SessionSpaceSnapshot() }
}
