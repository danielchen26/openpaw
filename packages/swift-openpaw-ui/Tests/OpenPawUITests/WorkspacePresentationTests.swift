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

    @Test("The connection action names its device for VoiceOver while the visible title stays short")
    func connectionActionIsDistinguishableBetweenDevices() {
        let laptop = WorkspaceDevicePresentation(host: fixture(nickname: "laptop"))
        let desktop = WorkspaceDevicePresentation(host: fixture(nickname: "desktop"))

        // The button reads "Connect" on every card, so without the device in the spoken label a VoiceOver user
        // choosing between machines hears the same thing for all of them and cannot tell which one they are about
        // to hand credentials to.
        #expect(laptop.connectionActionAccessibilityLabel != desktop.connectionActionAccessibilityLabel)
        #expect(laptop.connectionActionAccessibilityLabel == "Connect to laptop")

        // The visible button is still short: the card already shows the name directly above it.
        #expect(laptop.connectionActionTitle == "Connect")
    }

    @Test("Resuming names its device too")
    func resumeActionNamesItsDevice() {
        let host = fixture(nickname: "studio")
        let card = WorkspaceDevicePresentation(
            host: host,
            selectedHostID: host.id,
            connection: .connected(.ssh)
        )

        #expect(card.connectionActionTitle == "Resume")
        #expect(card.connectionActionAccessibilityLabel == "Resume studio")
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

    @MainActor
    @Test("No selected host keeps all cards unscoped from shared connection and counts")
    func noSelectedHostKeepsAllCardsUnscopedFromSharedConnectionAndCounts() {
        let first = fixture(nickname: "first")
        let second = fixture(nickname: "second", lastSuccessfulTransport: .ssh)
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, second]))
        model.selectedHostID = nil
        model.connection = .failed(.connectionFailed("shared failure"))
        model.sessions = [session("one"), session("two")]
        model.inbox = [pendingApproval("approval")]

        let cards = [
            WorkspaceDevicePresentation(host: first, model: model),
            WorkspaceDevicePresentation(host: second, model: model),
        ]

        for card in cards {
            #expect(card.availability != .online)
            #expect(card.availability != .failed)
            #expect(card.activeSessionCount == 0)
            #expect(card.pendingApprovalCount == 0)
            #expect(card.metrics.first { $0.id == "active-sessions" }?.value == "0")
            #expect(card.metrics.first { $0.id == "pending-approvals" }?.value == "0")
        }
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
        let host = fixture(preferredTransport: .mosh, multiplexerPreference: .zellij)
        let card = WorkspaceDevicePresentation(
            host: host,
            selectedHostID: host.id,
            activeSessionCount: 3,
            pendingApprovalCount: 2
        )

        #expect(card.metrics == [
            WorkspaceMetric(id: "active-sessions", label: "Agent sessions", value: "3"),
            WorkspaceMetric(id: "pending-approvals", label: "Pending approvals", value: "2"),
            WorkspaceMetric(id: "transport", label: "Transport preference", value: "Mosh"),
            WorkspaceMetric(id: "multiplexer", label: "Mux preference", value: "Zellij"),
        ])
    }

    @Test("Home pending approvals include only permission approvals while preserving pending inbox permission order")
    func homePendingApprovalsAreOnlyPermissionsInInboxOrder() {
        let question = inbox("question", status: .pending, category: .question, createdAt: Date(timeIntervalSince1970: 0))
        let laterPermission = inbox("later", status: .pending, category: .permission, createdAt: Date(timeIntervalSince1970: 10))
        let completion = inbox("completion", status: .pending, category: .completion, createdAt: Date(timeIntervalSince1970: 1))
        let earlierPermission = inbox("earlier", status: .pending, category: .permission, createdAt: Date(timeIntervalSince1970: 5))

        let pendingInbox = [question, laterPermission, completion, earlierPermission]
        let presentation = WorkspaceHomePresentation(sessions: [], pendingInbox: pendingInbox, repos: [])

        #expect(presentation.pendingApprovals.map(\.id.rawValue) == ["later", "earlier"])
    }

    @Test("Devices sort connected selected host first, then recency, then normalized nickname")
    func devicesSortBySelectedConnectionRecencyAndNickname() {
        let selected = fixture(nickname: "zeta")
        let recent = fixture(nickname: " beta ")
        let old = fixture(nickname: "Alpha")
        let never = fixture(nickname: "gamma")

        let cards = WorkspaceHomePresentation.deviceCards(
            hosts: [never, old, recent, selected],
            selectedHostID: selected.id,
            connection: .connected(.ssh),
            lastConnectedAt: [recent.id: Date(timeIntervalSince1970: 20), old.id: Date(timeIntervalSince1970: 10)]
        )

        #expect(cards.map(\.id) == [selected.id, recent.id, old.id, never.id])
    }

    @Test("Resume intent chooses active selected session, recent non-exited session, repo, then terminal")
    func resumeIntentResolvesDeterministically() {
        let selected = session("selected", state: .waiting, lastEventAt: Date(timeIntervalSince1970: 5))
        let recent = session("recent", state: .working, lastEventAt: Date(timeIntervalSince1970: 10))
        let exited = session("exited", state: .exited, lastEventAt: Date(timeIntervalSince1970: 100))
        let repo = RepoSummary(name: "app", path: "/work/app", branch: "main", dirty: false, ahead: 0, behind: 0)

        #expect(WorkspaceHomePresentation.resumeIntent(selectedSessionID: "selected", sessions: [recent, selected], selectedRepo: nil, repos: []) == .agentSession("selected"))
        #expect(WorkspaceHomePresentation.resumeIntent(selectedSessionID: nil, sessions: [exited, selected, recent], selectedRepo: nil, repos: []) == .agentSession("recent"))
        #expect(WorkspaceHomePresentation.resumeIntent(selectedSessionID: nil, sessions: [exited], selectedRepo: nil, repos: [repo]) == .repository("app"))
        #expect(WorkspaceHomePresentation.resumeIntent(selectedSessionID: nil, sessions: [], selectedRepo: nil, repos: []) == .terminal)
    }

    @Test("Pending approvals render before passive recent workspace activity")
    func homeSectionsOrderApprovalsBeforeRecentWorkspaces() {
        let sections = WorkspaceHomePresentation.sections(
            hosts: [fixture()], sessions: [session("agent", cwd: "/work/app")], pendingInbox: [pendingApproval("approval")], repos: []
        )

        #expect(sections == [.networkSummary, .devices, .agentSessions, .pendingApprovals, .recentWorkspaces])
    }

    @Test("Empty sessions and repositories do not invent rows or metrics")
    func emptyRemoteStateDoesNotInventRows() {
        let presentation = WorkspaceHomePresentation(sessions: [], pendingInbox: [], repos: [])

        #expect(presentation.agentSessions.isEmpty)
        #expect(presentation.recentWorkspaces.isEmpty)
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

private func session(_ id: String, state: SessionState = .working, cwd: String? = nil, lastEventAt: Date? = nil) -> SessionSummary {
    SessionSummary(sessionID: id, agent: .claudeCode, cwd: cwd, state: state, lastEventAt: lastEventAt)
}

private func pendingApproval(_ id: String) -> InboxItem {
    inbox(id, status: .pending)
}

private func resolvedApproval(_ id: String) -> InboxItem {
    inbox(id, status: .resolved)
}

private func inbox(
    _ id: String,
    status: InboxStatus,
    category: InboxCategory = .permission,
    createdAt: Date = Date(timeIntervalSince1970: 0)
) -> InboxItem {
    InboxItem(
        id: InboxID(rawValue: id),
        sessionID: SessionID(rawValue: "session-\(id)"),
        agent: .claudeCode,
        category: category,
        title: "Approval",
        actions: [.approveOnce, .deny],
        createdAt: createdAt,
        status: status,
        sourceEventID: EventID(rawValue: "event-\(id)")
    )
}
