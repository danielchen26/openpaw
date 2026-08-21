import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI

public enum WorkspaceHomeCopy {
    public static let emptyPrimaryAction = "Add a Tailscale or SSH device"
    public static let headline = "Bring your own machine online"
    public static let message = "OpenPaw connects to your own Mac or server. Credentials remain local on this device, and you stay in control of what is trusted, saved, and opened."
    public static let localControl = "Nothing is dialed from Home until you add SSH details and choose to connect."
    public static let emptyAndOnboardingCopy = [emptyPrimaryAction, headline, message, localControl]
}

@MainActor
public struct WorkspaceHomeView: View {
    private let model: OpenPawModel
    private let settings: OpenPawSettings
    private let candidates: [AddDeviceCandidate]
    private let onDeviceAction: (HostRecord, WorkspaceResumeIntent) -> Void
    private let onOpenAgent: (String) -> Void
    private let onOpenApproval: (String) -> Void
    private let onOpenRepository: (String) -> Void
    @State private var isAdding = false

    public init(
        model: OpenPawModel,
        settings: OpenPawSettings,
        candidates: [AddDeviceCandidate] = [],
        onDeviceAction: @escaping (HostRecord, WorkspaceResumeIntent) -> Void = { _, _ in },
        onOpenAgent: @escaping (String) -> Void = { _ in },
        onOpenApproval: @escaping (String) -> Void = { _ in },
        onOpenRepository: @escaping (String) -> Void = { _ in }
    ) {
        self.model = model
        self.settings = settings
        self.candidates = candidates
        self.onDeviceAction = onDeviceAction
        self.onOpenAgent = onOpenAgent
        self.onOpenApproval = onOpenApproval
        self.onOpenRepository = onOpenRepository
    }

    public var body: some View {
        Group {
            if model.hostStore.hosts.isEmpty {
                emptyFirstRun
            } else {
                populatedHome
            }
        }
        .sheet(isPresented: $isAdding) {
            NavigationStack {
                AddDeviceFlow(model: model, settings: settings, candidates: candidates) { isAdding = false }
            }
        }
    }

    private var populatedHome: some View {
        let presentation = WorkspaceHomePresentation(sessions: model.sessions, pendingInbox: model.pendingInbox, repos: model.repos)
        return ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.xl) {
                networkSummary
                deviceGrid
                if !presentation.agentSessions.isEmpty { agentSessions(presentation.agentSessions) }
                if !presentation.pendingApprovals.isEmpty { approvals(presentation.pendingApprovals) }
                if !presentation.recentWorkspaces.isEmpty { recentWorkspaces(presentation.recentWorkspaces) }
                addDeviceButton
            }
            .padding(OpenPawTheme.Space.xl)
            .frame(maxWidth: 1180, alignment: .leading)
        }
        .background(OpenPawTheme.void)
        .navigationTitle("Home")
    }

    private var networkSummary: some View {
        Panel {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: OpenPawTheme.Space.large) { summaryOrb; summaryText; Spacer(minLength: 0); addDeviceButton }
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) { summaryOrb; summaryText; addDeviceButton }
            }
        }
    }

    private var summaryOrb: some View {
        SignalOrb(signal: ConnectionSignal(availability: model.connection.isConnected ? .online : .unknown), size: 56)
            .accessibilityLabel("Selected device connection signal")
    }

    private var summaryText: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            Text("workspace / local signals").font(OpenPawTheme.Machine.label).foregroundStyle(OpenPawTheme.signal)
            Text("\(model.hostStore.hosts.count) saved device\(model.hostStore.hosts.count == 1 ? "" : "s")")
                .font(OpenPawTheme.Human.title).foregroundStyle(OpenPawTheme.textPrimary)
            Text("Selected connection is \(ConnectionPresentation.make(model.connection).label.lowercased()). Tailscale entries are candidates or saved addresses, not verified devices.")
                .font(OpenPawTheme.Human.prose).foregroundStyle(OpenPawTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var deviceGrid: some View {
        section("Devices") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: OpenPawTheme.Space.medium)], spacing: OpenPawTheme.Space.medium) {
                ForEach(deviceCards) { card in
                    if let host = model.hostStore[card.id] {
                        WorkspaceCard(presentation: card) {
                            onDeviceAction(host, resumeIntent)
                        }
                        .accessibilityLabel("Device \(card.title), \(card.network.sourceLabel), \(card.connectionActionTitle)")
                    }
                }
            }
        }
    }

    private var deviceCards: [WorkspaceDevicePresentation] {
        WorkspaceHomePresentation.deviceCards(
            hosts: model.hostStore.hosts,
            selectedHostID: model.selectedHostID,
            connection: model.connection,
            lastConnectedAt: Dictionary(uniqueKeysWithValues: model.hostStore.hosts.map { ($0.id, settings.profile(for: $0.id).lastConnectedAt) }.compactMap { id, date in date.map { (id, $0) } }),
            activeSessionCount: model.sessions.filter { $0.state != .exited }.count,
            pendingApprovalCount: model.pendingInbox.count
        )
    }

    private var resumeIntent: WorkspaceResumeIntent {
        WorkspaceHomePresentation.resumeIntent(selectedSessionID: model.selectedSessionID, sessions: model.sessions, selectedRepo: model.selectedRepo, repos: model.repos)
    }

    private func agentSessions(_ rows: [WorkspaceAgentSessionPresentation]) -> some View {
        section("Agent sessions") {
            VStack(spacing: OpenPawTheme.Space.small) {
                ForEach(rows) { row in
                    Button { onOpenAgent(row.id) } label: {
                        rowView(title: row.title, subtitle: "Agent session · \(row.state.rawValue) · \(row.subtitle)", glyph: "text.bubble")
                    }
                    .buttonStyle(.plain).accessibilityLabel("Open agent session \(row.title), state \(row.state.rawValue)")
                }
            }
        }
    }

    private func approvals(_ items: [InboxItem]) -> some View {
        section("Pending approvals") {
            VStack(spacing: OpenPawTheme.Space.small) {
                ForEach(items) { item in
                    Button { onOpenApproval(item.id.rawValue) } label: {
                        rowView(title: item.title, subtitle: "\(item.category.rawValue) · \(item.agent.displayName)", glyph: "exclamationmark.shield")
                    }
                    .buttonStyle(.plain).accessibilityLabel("Open pending approval \(item.title)")
                }
            }
        }
    }

    private func recentWorkspaces(_ rows: [WorkspaceRecentWorkspacePresentation]) -> some View {
        section("Recent workspaces") {
            VStack(spacing: OpenPawTheme.Space.small) {
                ForEach(rows) { row in
                    Button { if let repo = row.repoName { onOpenRepository(repo) } } label: {
                        rowView(title: row.title, subtitle: row.subtitle, glyph: row.repoName == nil ? "folder" : "arrow.triangle.branch")
                    }
                    .buttonStyle(.plain).disabled(row.repoName == nil)
                    .accessibilityLabel(row.repoName == nil ? "Workspace path \(row.title)" : "Open repository \(row.title)")
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
            Text(title).font(OpenPawTheme.Machine.headline).foregroundStyle(OpenPawTheme.textPrimary)
            content()
        }
    }

    private func rowView(title: String, subtitle: String, glyph: String) -> some View {
        HStack(spacing: OpenPawTheme.Space.medium) {
            Image(systemName: glyph).frame(width: 28, height: 28).foregroundStyle(OpenPawTheme.signal)
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                Text(title).font(OpenPawTheme.Machine.body).foregroundStyle(OpenPawTheme.textPrimary).lineLimit(2)
                Text(subtitle).font(OpenPawTheme.Human.caption).foregroundStyle(OpenPawTheme.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(OpenPawTheme.Space.medium).frame(minHeight: 44).background(OpenPawTheme.graphite)
        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card, style: .continuous))
    }

    private var emptyFirstRun: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.xl) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: OpenPawTheme.Space.large) { SignalOrb(.discovering, size: 88).accessibilityLabel("Waiting for a device you control"); homeHeroText }
                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) { SignalOrb(.discovering, size: 72).accessibilityLabel("Waiting for a device you control"); homeHeroText }
                }
                Panel { VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) { Text(WorkspaceHomeCopy.message).font(OpenPawTheme.Human.prose).foregroundStyle(OpenPawTheme.textSecondary); Text(WorkspaceHomeCopy.localControl).font(OpenPawTheme.Machine.body).foregroundStyle(OpenPawTheme.textPrimary) } }
                addDeviceButton
            }
            .padding(OpenPawTheme.Space.xl).frame(maxWidth: 760, alignment: .leading)
        }
        .background(OpenPawTheme.void).navigationTitle("Home")
    }

    private var homeHeroText: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            Text("home / first run").font(OpenPawTheme.Machine.label).foregroundStyle(OpenPawTheme.signal)
            Text(WorkspaceHomeCopy.headline).font(OpenPawTheme.Human.display).foregroundStyle(OpenPawTheme.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addDeviceButton: some View {
        Button { isAdding = true } label: {
            Label(WorkspaceHomeCopy.emptyPrimaryAction, systemImage: "plus.circle.fill")
                .font(OpenPawTheme.Machine.headline).foregroundStyle(OpenPawTheme.textPrimary)
                .padding(.horizontal, OpenPawTheme.Space.large).frame(minHeight: 44)
                .background(OpenPawTheme.graphite).clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card).stroke(OpenPawTheme.lineStrong))
        }
        .buttonStyle(.plain).accessibilityLabel(WorkspaceHomeCopy.emptyPrimaryAction)
    }
}
