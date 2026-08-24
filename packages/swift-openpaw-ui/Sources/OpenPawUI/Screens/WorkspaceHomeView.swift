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

public enum WorkspaceHomeCandidateSelection {
    public static func merge(
        explicit: [AddDeviceCandidate],
        bootstrap: [AddDeviceCandidate]
    ) -> [AddDeviceCandidate] {
        var seen = Set<String>()
        return (explicit + bootstrap).filter { seen.insert($0.id).inserted }
    }

    public static func visibleRows(
        explicit: [AddDeviceCandidate],
        bootstrap: [AddDeviceCandidate]
    ) -> [AddDeviceCandidate] {
        merge(explicit: explicit, bootstrap: bootstrap)
    }

    public static func openQuickConnect(
        _ candidate: AddDeviceCandidate,
        now: Date = Date(),
        onQuickConnect: (QuickConnectProposal) -> Void
    ) {
        onQuickConnect(.from(candidate: candidate, now: now))
    }

    public static func openAddDevice(_ onAddDevice: () -> Void) {
        onAddDevice()
    }
}

public enum WorkspaceHomeCandidateAction: Sendable, Hashable {
    case candidate
    case addAnother
    case manual

    public var opensAddDevice: Bool { self != .candidate }
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
    private let onQuickConnect: (QuickConnectProposal) -> Void
    private let onOpenPawURL: (URL) -> Void
    private let onAddDevice: () -> Void
    @State private var isShowingProviderImport = false
    #if os(iOS) && canImport(VisionKit)
        @State private var isShowingPairingScanner = false
    #endif
    @Environment(\.scenePhase) private var scenePhase

    public init(
        model: OpenPawModel,
        settings: OpenPawSettings,
        candidates: [AddDeviceCandidate] = [],
        onDeviceAction: @escaping (HostRecord, WorkspaceResumeIntent) -> Void = { _, _ in },
        onOpenAgent: @escaping (String) -> Void = { _ in },
        onOpenApproval: @escaping (String) -> Void = { _ in },
        onOpenRepository: @escaping (String) -> Void = { _ in },
        onQuickConnect: @escaping (QuickConnectProposal) -> Void = { _ in },
        onOpenPawURL: @escaping (URL) -> Void = { _ in },
        onAddDevice: @escaping () -> Void = {}
    ) {
        self.model = model
        self.settings = settings
        self.candidates = candidates
        self.onDeviceAction = onDeviceAction
        self.onOpenAgent = onOpenAgent
        self.onOpenApproval = onOpenApproval
        self.onOpenRepository = onOpenRepository
        self.onQuickConnect = onQuickConnect
        self.onOpenPawURL = onOpenPawURL
        self.onAddDevice = onAddDevice
    }

    public var body: some View {
        Group {
            if model.hostStore.hosts.isEmpty {
                emptyFirstRun
            } else {
                populatedHome
            }
        }
        .sheet(isPresented: $isShowingProviderImport) {
            NavigationStack { ProviderImportView(model: model) }
        }
        #if os(iOS) && canImport(VisionKit)
            .fullScreenCover(isPresented: $isShowingPairingScanner) {
                OpenPawPairingScannerView(
                    onOpenPawURL: { url in
                        isShowingPairingScanner = false
                        Task { @MainActor in
                            await Task.yield()
                            onOpenPawURL(url)
                        }
                    },
                    onCancel: { isShowingPairingScanner = false })
            }
        #endif
        .task { model.refreshHomeTailnetBootstrap() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshHomeTailnetBootstrap() } }
    }

    private var populatedHome: some View {
        let presentation = WorkspaceHomePresentation(sessions: model.sessions, pendingInbox: model.pendingInbox, repos: model.repos)
        return ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.xl) {
                networkSummary
                tailnetBootstrapPanel
                deviceGrid
                remoteCatalogTransfer
                if !presentation.agentSessions.isEmpty { agentSessions(presentation.agentSessions) }
                if !presentation.pendingApprovals.isEmpty { approvals(presentation.pendingApprovals) }
                if !presentation.recentWorkspaces.isEmpty { recentWorkspaces(presentation.recentWorkspaces) }
                addDeviceButton
                scanPairingButton
            }
            .padding(OpenPawTheme.Space.xl)
            .frame(maxWidth: 1180, alignment: .leading)
        }
        .background(OpenPawTheme.void)
        .navigationTitle("Home")
    }

    private var remoteCatalogTransfer: some View {
        section("Remote catalog transfer") {
            Panel {
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                    Text("remote catalog / host transfer / local workspace")
                        .font(OpenPawTheme.Machine.label)
                        .foregroundStyle(OpenPawTheme.signal)
                    Text("Import a remote repository through your host")
                        .font(OpenPawTheme.Human.title)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                    Text(remoteCatalogDetail)
                        .font(OpenPawTheme.Human.prose)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                    Button(remoteCatalogActionTitle) {
                        if model.connection.isConnected, model.canListProviders == .available {
                            isShowingProviderImport = true
                        } else if let host = model.selectedHost {
                            onDeviceAction(host, .terminal)
                        }
                    }
                    .disabled(remoteCatalogActionDisabled)
                    .frame(minHeight: 44)
                    .buttonStyle(.borderedProminent)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Remote catalog transfer")
            .accessibilityValue(remoteCatalogDetail)
        }
    }

    private var remoteCatalogDetail: String {
        let host = model.selectedHost?.nickname ?? "this host"
        guard model.connection.isConnected else { return "Connect \(host) first. Repository browsing and imports run on the host, not from this device." }
        if model.canListProviders == .denied || model.canAuthorizeProviders == .denied || model.canImportRepos == .denied {
            return "This paired device cannot import repositories. Re-pair this device with providers.read, providers.manage, and repos.manage to authorize and import repositories."
        }
        if model.canListProviders == .unavailable { return "Provider import is unavailable on this host. Install or update openpaw-host with provider support, then reconnect." }
        return "OpenPaw never clones a repository on this phone. The selected host authorizes, clones, validates, and registers the workspace it owns."
    }

    private var remoteCatalogActionTitle: String {
        guard model.connection.isConnected else { return "Connect host" }
        return model.canListProviders == .available ? "Browse remote catalogs" : "Provider import unavailable"
    }

    private var remoteCatalogActionDisabled: Bool {
        model.connection.isConnected && model.canListProviders != .available
    }

    private var tailnetBootstrapPanel: some View {
        let state = model.homeTailnetBootstrap
        let visibleCandidates = visibleTailnetCandidates
        return Panel {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Text("tailnet / local identity / candidates")
                    .font(OpenPawTheme.Machine.label)
                    .foregroundStyle(OpenPawTheme.signal)
                Text("Tailnet discovery")
                    .font(OpenPawTheme.Human.title)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                Text(tailnetBootstrapDetail(state))
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !visibleCandidates.isEmpty {
                    VStack(spacing: OpenPawTheme.Space.small) {
                        ForEach(visibleCandidates) { candidate in
                            Button {
                                WorkspaceHomeCandidateSelection.openQuickConnect(
                                    candidate,
                                    onQuickConnect: onQuickConnect)
                            } label: {
                                tailnetCandidateRow(candidate)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(candidate.accessibilityLabel)
                        }
                    }
                }
                Button(visibleCandidates.isEmpty ? "Review candidates" : "Add another device") {
                    WorkspaceHomeCandidateSelection.openAddDevice(onAddDevice)
                }
                .disabled(state.phase == .loading)
                .frame(minHeight: 44)
                .buttonStyle(.borderedProminent)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tailnet discovery")
        .accessibilityValue(tailnetBootstrapDetail(state))
    }

    private var visibleTailnetCandidates: [AddDeviceCandidate] {
        WorkspaceHomeCandidateSelection.visibleRows(
            explicit: candidates,
            bootstrap: model.homeTailnetBootstrap.candidates
        )
    }

    private func tailnetCandidateRow(_ candidate: AddDeviceCandidate) -> some View {
        HStack(spacing: OpenPawTheme.Space.medium) {
            Circle()
                .fill(candidate.online ? OpenPawTheme.ok : OpenPawTheme.textTertiary)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                Text(candidate.nickname)
                    .font(OpenPawTheme.Machine.body)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .lineLimit(1)
                Text(candidate.dnsName ?? candidate.hostname)
                    .font(OpenPawTheme.Machine.code)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(candidate.online ? "Online" : "Offline")
                .font(OpenPawTheme.Human.caption)
                .foregroundStyle(candidate.online ? OpenPawTheme.ok : OpenPawTheme.textTertiary)
            Image(systemName: "chevron.right")
                .foregroundStyle(OpenPawTheme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(OpenPawTheme.Space.medium)
        .frame(minHeight: 52)
        .background(OpenPawTheme.graphite)
        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card).stroke(OpenPawTheme.lineStrong))
    }

    private func tailnetBootstrapDetail(_ state: HomeTailnetBootstrapState) -> String {
        let identity = state.localIdentity.flatMap { identity in
            let account = identity.profile?.displayName ?? identity.profile?.loginName ?? "signed-in local profile"
            let tailnet = identity.tailnetName ?? identity.domainName ?? "unknown tailnet"
            return "Local identity: \(account) on \(tailnet)."
        } ?? "Local identity unavailable. iOS cannot read the Tailscale app Keychain or account database. Quad100 may be unavailable on some clients."
        let candidates = "Discovered \(state.candidateCount) candidate\(state.candidateCount == 1 ? "" : "s") from \(state.source.rawValue). Candidates are not trusted, saved, or connected automatically."
        switch state.phase {
        case .idle: return identity + " Ready to check saved OpenPaw credentials or a connected host."
        case .loading: return identity + " Loading saved administrator credentials or connected-host discovery."
        case .loaded: return identity + " " + candidates
        case .unavailable: return identity + " Full peer enumeration requires saved OpenPaw API authorization or a connected OpenPaw host."
        case .failed(let message): return identity + " " + message
        }
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
            pendingApprovalCount: model.pendingInbox.filter { $0.category == .permission }.count
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
                tailnetBootstrapPanel
                addDeviceButton
                scanPairingButton
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
        Button { WorkspaceHomeCandidateSelection.openAddDevice(onAddDevice) } label: {
            Label(WorkspaceHomeCopy.emptyPrimaryAction, systemImage: "plus.circle.fill")
                .font(OpenPawTheme.Machine.headline).foregroundStyle(OpenPawTheme.textPrimary)
                .padding(.horizontal, OpenPawTheme.Space.large).frame(minHeight: 44)
                .background(OpenPawTheme.graphite).clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card).stroke(OpenPawTheme.lineStrong))
        }
        .buttonStyle(.plain).accessibilityLabel(WorkspaceHomeCopy.emptyPrimaryAction)
    }

    @ViewBuilder private var scanPairingButton: some View {
        #if os(iOS) && canImport(VisionKit)
            Button { isShowingPairingScanner = true } label: {
                Label("Scan pairing QR", systemImage: "qrcode.viewfinder")
                    .font(OpenPawTheme.Machine.headline).foregroundStyle(OpenPawTheme.textPrimary)
                    .padding(.horizontal, OpenPawTheme.Space.large).frame(minHeight: 44)
                    .background(OpenPawTheme.graphite).clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card).stroke(OpenPawTheme.lineStrong))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scan pairing QR")
        #endif
    }
}
