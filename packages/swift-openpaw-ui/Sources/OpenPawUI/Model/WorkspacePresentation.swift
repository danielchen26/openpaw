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
        let isSelected = selectedHostID.map { $0 == host.id } ?? true
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
            WorkspaceMetric(id: "active-sessions", label: "Active sessions", value: "\(scopedActiveSessionCount)"),
            WorkspaceMetric(id: "pending-approvals", label: "Pending approvals", value: "\(scopedPendingApprovalCount)"),
            WorkspaceMetric(id: "transport", label: "Transport", value: transportLabel),
            WorkspaceMetric(id: "multiplexer", label: "Multiplexer", value: muxLabel),
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
