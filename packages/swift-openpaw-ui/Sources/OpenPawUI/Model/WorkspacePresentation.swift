import Foundation
import OpenPawProtocol
import OpenPawTerminalCore

public enum DeviceNetworkPresentation: String, Sendable, Hashable {
    case tailscaleCandidate
    case sshCandidate

    public var sourceLabel: String {
        switch self {
        case .tailscaleCandidate: "Tailscale candidate"
        case .sshCandidate: "SSH candidate"
        }
    }
}

public enum DeviceAvailabilityPresentation: String, Sendable, Hashable {
    case unknown
    case online
    case offline
    case connecting
    case failed
}

public struct WorkspaceMetric: Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public struct WorkspaceDevicePresentation: Sendable, Hashable, Identifiable {
    public let id: HostRecord.ID
    public let title: String
    public let hostname: String
    public let network: DeviceNetworkPresentation
    public let availability: DeviceAvailabilityPresentation
    public let activeSessionCount: Int
    public let pendingApprovalCount: Int
    public let preferredTransportLabel: String
    public let multiplexerLabel: String
    public let connectionActionTitle: String
    public let metrics: [WorkspaceMetric]

    public init(
        host: HostRecord,
        selectedHostID: HostRecord.ID? = nil,
        connection: ConnectionState = .idle,
        activeSessionCount: Int = 0,
        pendingApprovalCount: Int = 0
    ) {
        let isSelected = selectedHostID.map { $0 == host.id } ?? false
        let scopedActiveSessionCount = isSelected ? activeSessionCount : 0
        let scopedPendingApprovalCount = isSelected ? pendingApprovalCount : 0
        let transportLabel = host.preferredTransport?.displayName ?? "Auto"
        let muxLabel = host.multiplexerPreference?.displayName ?? "None"

        self.id = host.id
        self.title = host.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host.hostname : host.nickname
        self.hostname = host.hostname
        self.network = Self.network(for: host)
        self.availability = Self.availability(
            for: host,
            selected: isSelected,
            connection: connection
        )
        self.activeSessionCount = scopedActiveSessionCount
        self.pendingApprovalCount = scopedPendingApprovalCount
        self.preferredTransportLabel = transportLabel
        self.multiplexerLabel = muxLabel
        self.connectionActionTitle = self.availability == .online ? "Resume" : "Connect"
        self.metrics = [
            WorkspaceMetric(id: "active-sessions", label: "Agent sessions", value: "\(scopedActiveSessionCount)"),
            WorkspaceMetric(id: "pending-approvals", label: "Pending approvals", value: "\(scopedPendingApprovalCount)"),
            WorkspaceMetric(id: "transport", label: "Transport", value: transportLabel),
            WorkspaceMetric(id: "multiplexer", label: "Mux preference", value: muxLabel),
        ]
    }

    @MainActor
    public init(host: HostRecord, model: OpenPawModel) {
        let isSelected = model.selectedHostID == host.id
        self.init(
            host: host,
            selectedHostID: model.selectedHostID,
            connection: model.connection,
            activeSessionCount: isSelected ? Self.activeSessionCount(in: model.sessions) : 0,
            pendingApprovalCount: isSelected ? Self.pendingApprovalCount(in: model.inbox) : 0
        )
    }

    private static func network(for host: HostRecord) -> DeviceNetworkPresentation {
        let hostname = host.hostname.lowercased()
        let hasTailscaleTag = host.tags.contains { $0.caseInsensitiveCompare("tailscale") == .orderedSame }
        if hostname.hasSuffix(".ts.net") || hasTailscaleTag {
            return .tailscaleCandidate
        }
        return .sshCandidate
    }

    private static func availability(
        for host: HostRecord,
        selected: Bool,
        connection: ConnectionState
    ) -> DeviceAvailabilityPresentation {
        guard selected else {
            return host.lastSuccessfulTransport == nil ? .unknown : .offline
        }

        switch connection {
        case .connected:
            return .online
        case .resolving, .connecting, .authenticating, .reconnecting:
            return .connecting
        case .disconnected:
            return host.lastSuccessfulTransport == nil ? .unknown : .offline
        case .failed:
            return .failed
        case .idle:
            return host.lastSuccessfulTransport == nil ? .unknown : .offline
        }
    }

    private static func activeSessionCount(in sessions: [SessionSummary]) -> Int {
        sessions.filter { $0.state != .exited }.count
    }

    private static func pendingApprovalCount(in inbox: [InboxItem]) -> Int {
        inbox.filter { $0.status == .pending && $0.category == .permission }.count
    }
}

public enum WorkspaceResumeIntent: Sendable, Hashable {
    case agentSession(String)
    case repository(String)
    case terminal
}

public enum WorkspaceHomeSection: Sendable, Hashable {
    case networkSummary
    case devices
    case agentSessions
    case pendingApprovals
    case recentWorkspaces
}

public struct WorkspaceAgentSessionPresentation: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let state: SessionState
}

public struct WorkspaceRecentWorkspacePresentation: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let repoName: String?
}

public struct WorkspaceHomePresentation: Sendable, Hashable {
    public let agentSessions: [WorkspaceAgentSessionPresentation]
    public let pendingApprovals: [InboxItem]
    public let recentWorkspaces: [WorkspaceRecentWorkspacePresentation]

    public init(sessions: [SessionSummary], pendingInbox: [InboxItem], repos: [RepoSummary]) {
        self.agentSessions = sessions
            .filter { $0.state != .exited }
            .sorted(by: Self.sessionOrder)
            .map { session in
                WorkspaceAgentSessionPresentation(
                    id: session.sessionID,
                    title: session.title?.trimmedNonEmpty ?? session.agent.displayName,
                    subtitle: session.cwd?.trimmedNonEmpty ?? "No working directory reported",
                    state: session.state
                )
            }
        self.pendingApprovals = pendingInbox
        self.recentWorkspaces = Self.recentWorkspaces(sessions: sessions, repos: repos)
    }

    public static func deviceCards(
        hosts: [HostRecord],
        selectedHostID: HostRecord.ID?,
        connection: ConnectionState,
        lastConnectedAt: [HostRecord.ID: Date] = [:],
        activeSessionCount: Int = 0,
        pendingApprovalCount: Int = 0
    ) -> [WorkspaceDevicePresentation] {
        hosts.sorted { lhs, rhs in
            let leftConnectedSelected = lhs.id == selectedHostID && connection.isConnected
            let rightConnectedSelected = rhs.id == selectedHostID && connection.isConnected
            if leftConnectedSelected != rightConnectedSelected { return leftConnectedSelected }
            let leftDate = lastConnectedAt[lhs.id]
            let rightDate = lastConnectedAt[rhs.id]
            if leftDate != rightDate {
                switch (leftDate, rightDate) {
                case let (left?, right?): return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): break
                }
            }
            return lhs.nickname.normalizedWorkspaceSortKey < rhs.nickname.normalizedWorkspaceSortKey
        }.map { host in
            WorkspaceDevicePresentation(
                host: host,
                selectedHostID: selectedHostID,
                connection: connection,
                activeSessionCount: activeSessionCount,
                pendingApprovalCount: pendingApprovalCount
            )
        }
    }

    public static func resumeIntent(
        selectedSessionID: String?,
        sessions: [SessionSummary],
        selectedRepo: String?,
        repos: [RepoSummary]
    ) -> WorkspaceResumeIntent {
        let active = sessions.filter { $0.state != .exited }
        if let selectedSessionID, active.contains(where: { $0.sessionID == selectedSessionID }) {
            return .agentSession(selectedSessionID)
        }
        if let recent = active.sorted(by: sessionOrder).first { return .agentSession(recent.sessionID) }
        if let selectedRepo, repos.contains(where: { $0.name == selectedRepo }) { return .repository(selectedRepo) }
        if let first = repos.first { return .repository(first.name) }
        return .terminal
    }

    public static func sections(
        hosts: [HostRecord], sessions: [SessionSummary], pendingInbox: [InboxItem], repos: [RepoSummary]
    ) -> [WorkspaceHomeSection] {
        var result: [WorkspaceHomeSection] = [.networkSummary]
        if !hosts.isEmpty { result.append(.devices) }
        if sessions.contains(where: { $0.state != .exited }) { result.append(.agentSessions) }
        if !pendingInbox.isEmpty { result.append(.pendingApprovals) }
        if !recentWorkspaces(sessions: sessions, repos: repos).isEmpty { result.append(.recentWorkspaces) }
        return result
    }

    private static func recentWorkspaces(sessions: [SessionSummary], repos: [RepoSummary]) -> [WorkspaceRecentWorkspacePresentation] {
        var seen = Set<String>()
        var rows: [WorkspaceRecentWorkspacePresentation] = []
        for repo in repos where seen.insert(repo.path).inserted {
            rows.append(.init(id: repo.path, title: repo.name, subtitle: repo.path, repoName: repo.name))
        }
        for session in sessions.sorted(by: sessionOrder) {
            guard let cwd = session.cwd?.trimmedNonEmpty, seen.insert(cwd).inserted else { continue }
            rows.append(.init(id: cwd, title: URL(fileURLWithPath: cwd).lastPathComponent, subtitle: cwd, repoName: nil))
        }
        return rows
    }

    private static func sessionOrder(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Bool {
        if lhs.lastEventAt != rhs.lastEventAt { return (lhs.lastEventAt ?? .distantPast) > (rhs.lastEventAt ?? .distantPast) }
        return lhs.sessionID < rhs.sessionID
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var normalizedWorkspaceSortKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    }
}
