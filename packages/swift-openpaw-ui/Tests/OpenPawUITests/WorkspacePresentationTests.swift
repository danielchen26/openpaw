import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import Testing
@testable import OpenPawUI

@Suite("Workspace presentation")
struct WorkspacePresentationTests {
    @Test("MagicDNS hostnames are presented as Tailscale candidates, not verified devices")
    func magicDNSCandidate() {
        let card = WorkspaceDevicePresentation(host: fixture(hostname: "studio.tail123.ts.net"))

        #expect(card.network == .tailscaleCandidate)
        #expect(card.network.sourceLabel == "Tailscale candidate")
        #expect(card.network.sourceLabel.contains("verified") == false)
        #expect(card.network.sourceLabel.contains("trusted") == false)
    }

    @Test("Explicit tailscale tags are case-insensitive candidate labels")
    func explicitTailscaleTagCandidate() {
        let card = WorkspaceDevicePresentation(host: fixture(hostname: "100.64.0.5", tags: ["Laptop", "TailScale"]))

        #expect(card.network == .tailscaleCandidate)
        #expect(card.network.sourceLabel == "Tailscale candidate")
    }

    @Test("Other hosts remain SSH candidates")
    func otherHostsRemainSSHCandidates() {
        let card = WorkspaceDevicePresentation(host: fixture(hostname: "workshop.local", tags: ["prod"]))

        #expect(card.network == .sshCandidate)
        #expect(card.network.sourceLabel == "SSH candidate")
    }

    @Test("Connected selected host is online")
    func connectedSelectedHostIsOnline() {
        let host = fixture()
        let card = WorkspaceDevicePresentation(
            host: host,
            selectedHostID: host.id,
            connection: .connected(.mosh)
        )

        #expect(card.availability == .online)
        #expect(card.connectionActionTitle == "Resume")
    }

    @Test("Previously reached disconnected host is offline instead of failed")
    func previouslyReachedDisconnectedHostIsOffline() {
        let host = fixture(lastSuccessfulTransport: .ssh)
        let card = WorkspaceDevicePresentation(
            host: host,
            selectedHostID: host.id,
            connection: .disconnected(reason: "closed")
        )

        #expect(card.availability == .offline)
    }

    @Test("Failed selected hosts report failed even after a successful transport")
    func failedSelectedHostAlwaysReportsFailed() {
        let host = fixture(lastSuccessfulTransport: .ssh)
        let card = WorkspaceDevicePresentation(
            host: host,
            selectedHostID: host.id,
            connection: .failed(.connectionFailed("boom"))
        )

        #expect(card.availability == .failed)
    }

    @Test("Nonselected hosts do not inherit the selected connection")
    func nonselectedHostDoesNotInheritSelectedConnection() {
        let selected = fixture(nickname: "selected")
        let other = fixture(nickname: "other")
        let card = WorkspaceDevicePresentation(
            host: other,
            selectedHostID: selected.id,
            connection: .connected(.ssh)
        )

        #expect(card.availability != .online)
        #expect(card.activeSessionCount == 0)
        #expect(card.pendingApprovalCount == 0)
    }

    @MainActor
    @Test("Counts use only the current model projection and only for the selected host")
    func countsUseOnlySelectedCurrentProjection() {
        let selected = fixture(nickname: "selected")
        let other = fixture(nickname: "other")
        let model = OpenPawModel(hostStore: HostStore(hosts: [selected, other]))
        model.selectedHostID = selected.id
        model.sessions = [session("one"), session("two")]
        model.inbox = [pendingApproval("approval"), resolvedApproval("resolved")]

        let selectedCard = WorkspaceDevicePresentation(host: selected, model: model)
        let otherCard = WorkspaceDevicePresentation(host: other, model: model)

        #expect(selectedCard.activeSessionCount == 2)
        #expect(selectedCard.pendingApprovalCount == 1)
        #expect(otherCard.activeSessionCount == 0)
        #expect(otherCard.pendingApprovalCount == 0)
    }

    @MainActor
    @Test("Exited sessions do not count as active in the current model projection")
    func exitedSessionsDoNotCountAsActive() {
        let host = fixture()
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]))
        model.selectedHostID = host.id
        model.sessions = [
            session("working", state: .working),
            session("exited", state: .exited),
        ]

        let card = WorkspaceDevicePresentation(host: host, model: model)

        #expect(card.activeSessionCount == 1)
        #expect(card.metrics.first { $0.id == "active-sessions" }?.value == "1")
    }

    @Test("Preferred transport and multiplexer use existing display names")
    func displayNamesAreHumanReadable() {
        let card = WorkspaceDevicePresentation(
            host: fixture(preferredTransport: .eternalTerminal, multiplexerPreference: .screen)
        )

        #expect(card.preferredTransportLabel == "Eternal Terminal")
        #expect(card.multiplexerLabel == "GNU Screen")
    }

    @Test("Metrics have deterministic ordering")
    func metricsHaveDeterministicOrdering() {
        let card = WorkspaceDevicePresentation(
            host: fixture(preferredTransport: .mosh, multiplexerPreference: .zellij),
            activeSessionCount: 3,
            pendingApprovalCount: 2
        )

        #expect(card.metrics == [
            WorkspaceMetric(id: "active-sessions", label: "Active sessions", value: "3"),
            WorkspaceMetric(id: "pending-approvals", label: "Pending approvals", value: "2"),
            WorkspaceMetric(id: "transport", label: "Transport", value: "Mosh"),
            WorkspaceMetric(id: "multiplexer", label: "Multiplexer", value: "Zellij"),
        ])
    }
}

private func fixture(
    nickname: String = "studio",
    hostname: String = "studio.example.com",
    preferredTransport: TransportKind? = nil,
    lastSuccessfulTransport: TransportKind? = nil,
    multiplexerPreference: MultiplexerKind? = nil,
    tags: [String] = []
) -> HostRecord {
    HostRecord(
        nickname: nickname,
        hostname: hostname,
        username: "chet",
        auth: .agentForwarding,
        preferredTransport: preferredTransport,
        lastSuccessfulTransport: lastSuccessfulTransport,
        multiplexerPreference: multiplexerPreference,
        tags: tags
    )
}

private func session(_ id: String, state: SessionState = .working) -> SessionSummary {
    SessionSummary(sessionID: id, agent: .claudeCode, state: state)
}

private func pendingApproval(_ id: String) -> InboxItem {
    inbox(id, status: .pending)
}

private func resolvedApproval(_ id: String) -> InboxItem {
    inbox(id, status: .resolved)
}

private func inbox(_ id: String, status: InboxStatus) -> InboxItem {
    InboxItem(
        id: InboxID(rawValue: id),
        sessionID: SessionID(rawValue: "session-\(id)"),
        agent: .claudeCode,
        category: .permission,
        title: "Approval",
        actions: [.approveOnce, .deny],
        createdAt: Date(timeIntervalSince1970: 0),
        status: status,
        sourceEventID: EventID(rawValue: "event-\(id)")
    )
}
