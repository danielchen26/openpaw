import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI

// MARK: - Layout selection

/// The two widths the app is designed for.
///
/// Our own type rather than `UserInterfaceSizeClass`, for two reasons: the choice stays testable, and the size
/// class is not a reliable signal on its own — macOS reports `.regular` at every window size, so a phone-sized
/// frame would otherwise be handed a two-pane layout it cannot fit. The measured width is the honest question,
/// "is there room for two panes?", and it answers correctly on every platform.
public enum RootWidth: String, Sendable, Hashable, CaseIterable {
    case compact
    case regular

    /// Narrowest width where a 220pt sidebar and a usable terminal both fit. Below it the tab bar is the only
    /// honest answer; iPad portrait (1024pt) and any Mac window clear it, an iPhone (393-440pt) does not.
    public static let twoPaneThreshold: CGFloat = 700

    /// `isCompactSizeClass` still participates: on iOS it is what tells us we are in Slide Over rather than
    /// full screen, which the width alone can miss at the margins.
    public static func resolve(width: CGFloat, isCompactSizeClass: Bool = false) -> RootWidth {
        if isCompactSizeClass { return .compact }
        return width < twoPaneThreshold ? .compact : .regular
    }
}

/// How the six destinations are presented.
public enum RootNavigationStyle: String, Sendable, Hashable, CaseIterable {
    /// Tab bar at the bottom: one thumb, one hand, six reachable targets.
    case tabs
    /// Sidebar plus detail: room to keep the session list and the transcript on screen together.
    case split

    public static func style(for width: RootWidth) -> RootNavigationStyle {
        switch width {
        case .compact: .tabs
        case .regular: .split
        }
    }
}

/// Fixed compact-navigation geometry.
///
/// The custom tab items contain flexible SwiftUI content. Giving their container an explicit height prevents that
/// flexibility from claiming the unused half of a phone screen while still leaving room for the icon and label.
public enum RootNavigationLayout {
    public static func compactTabBarHeight(isAccessibilitySize: Bool) -> CGFloat {
        isAccessibilitySize ? 72 : 64
    }

    public static func showsVisualTabTitles(isAccessibilitySize: Bool) -> Bool {
        !isAccessibilitySize
    }
}

// MARK: - Destinations

public enum ShellDestination: String, Sendable, Hashable, CaseIterable, Identifiable {
    case home
    case terminal
    case chat
    case inbox
    case repo
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: "Home"
        case .terminal: "Terminal"
        case .chat: "Chat"
        case .inbox: "Inbox"
        case .repo: "Repo"
        case .settings: "Settings"
        }
    }

    public var glyph: String {
        switch self {
        case .home: "house"
        case .terminal: "terminal"
        case .chat: "text.bubble"
        case .inbox: "tray.full"
        case .repo: "arrow.triangle.branch"
        case .settings: "gearshape"
        }
    }

    /// Whether this destination ever pushes a detail view, and so needs a navigation stack around it.
    ///
    /// The terminal never does: it carries its own header and every control it has is in its own footer.
    public var pushesDetail: Bool {
        switch self {
        case .terminal: false
        case .home, .chat, .inbox, .repo, .settings: true
        }
    }
}

/// The panes of the repo destination. One destination rather than four tabs because they are four views of the same
/// working tree, and a reviewer moves between them constantly.
public enum RepoPane: String, Sendable, Hashable, CaseIterable, Identifiable {
    case diff
    case files
    case preview
    case status

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .diff: "Diff"
        case .files: "Files"
        case .preview: "Preview"
        case .status: "Status"
        }
    }
}

// MARK: - Router

/// Navigation state that has to survive the view value being rebuilt, and that the app can drive from outside.
///
/// A notification tap has to be able to open one specific approval, and a `View` is a value: by the time SwiftUI
/// hands it to the window there is nothing to call a method on. Holding this reference in `RootView` means every copy
/// of the struct shares the same navigation state, so `openApproval(itemID:)` works from the app's deep-link handler.
@MainActor
@Observable
public final class ShellRouter {
    public var destination: ShellDestination = .home
    public var repoPane: RepoPane = .diff
    /// Path the repo panes should scroll to, set when a transcript or a status row hands one over.
    public var repoFocusPath: String?
    public var diffMode: DiffMode = .workingTree
    /// `InboxItem.id.rawValue` of the item whose approval sheet should be open.
    public var approvalItemID: String?
    /// Session the compact layout has pushed a transcript for.
    public var chatSessionID: String?

    public init() {}

    public func openApproval(itemID: String) {
        approvalItemID = itemID
        destination = .inbox
    }
}

// MARK: - Root

/// The app's navigation spine, and the owner of everything that must exist exactly once: the router, the device
/// settings, the terminal scrollback, and the three things that interrupt you — a host key decision, an approval, and
/// an error.
///
/// Sheets are deliberately a single slot rather than three independent `.sheet` modifiers. Two of them are decisions
/// about safety, and if a host key block and an approval ever raced, the approval must not win.
@MainActor
public struct RootView: View {
    private let model: OpenPawModel
    private let terminalSurface: () -> AnyView
    private let router: ShellRouter
    private let settings: OpenPawSettings
    private let scrollback: ScrollbackStore
    private let sessionSpaceProvider: any SessionSpaceProviding
    private let sessionCommandExecutor: any SessionSpaceCommandExecuting
    private let restorationStore: (any SessionRestorationStoring)?
    @State private var sessionSpace = SessionSpaceSnapshot()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// `terminalSurface` is the live PTY view. The app injects its SwiftTerm-backed surface; a headless snapshot run
    /// injects `ScrollbackTextView`. Construct this once and keep it: the router it holds is the navigation state.
    public init(
        model: OpenPawModel,
        terminalSurface: @escaping () -> AnyView,
        sessionSpaceProvider: any SessionSpaceProviding = EmptySessionSpaceProvider(),
        sessionCommandExecutor: any SessionSpaceCommandExecuting = EmptySessionSpaceCommandExecutor(),
        restorationStore: (any SessionRestorationStoring)? = nil
    ) {
        self.model = model
        self.terminalSurface = terminalSurface
        self.sessionSpaceProvider = sessionSpaceProvider
        self.sessionCommandExecutor = sessionCommandExecutor
        self.restorationStore = restorationStore
        self.router = ShellRouter()
        let settings = OpenPawSettings()
        self.settings = settings
        // Roughly 120 bytes a line. The budget is fixed for the life of the process; changing it in Settings takes
        // effect the next time the app launches, which is the honest trade for a store that never reallocates.
        self.scrollback = ScrollbackStore(byteBudget: settings.scrollbackLines * 120)
    }

    /// Deep-link entry point. Safe to call before the inbox has loaded: the id is remembered and the sheet opens as
    /// soon as the item arrives.
    public func openApproval(itemID: String) {
        router.openApproval(itemID: itemID)
        Task { await model.refresh() }
    }

    /// True only where a size class exists and reports compact.
    private var isCompactSizeClass: Bool {
        #if os(iOS)
            horizontalSizeClass == .compact
        #else
            false
        #endif
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = RootWidth.resolve(
                width: proxy.size.width, isCompactSizeClass: isCompactSizeClass)
            Group {
                switch RootNavigationStyle.style(for: width) {
                case .tabs: tabs(width: width)
                case .split: split(width: width)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(OpenPawTheme.ink)
        .tint(OpenPawTheme.textPrimary)
        .task {
            // A device with hosts but no selection has nothing to show a status about. Adopting the first entry
            // is what the model does at init; doing it here too covers a store loaded after the model was built.
            if model.selectedHostID == nil {
                model.selectedHostID = model.hostStore.hosts.first?.id
            }
            guard model.canRefreshRemoteState else { return }
            await model.refresh()
            model.startFollowing(session: model.selectedSessionID)
            await refreshSessionSpace()
        }
        .onChange(of: model.selectedHostID) { _, _ in
            invalidateSessionSpace()
            Task {
                if model.canRefreshRemoteState { await model.refresh() }
                await refreshSessionSpace()
            }
        }
        .onChange(of: model.connectionGeneration) { _, _ in
            invalidateSessionSpace()
            Task { await refreshSessionSpace() }
        }
#if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task {
                if model.canRefreshRemoteState { await model.refresh() }
                await refreshSessionSpace()
            }
        }
#endif
        .task { await pumpScrollback() }
        .sheet(item: sheetBinding) { sheet in
            switch sheet {
            case .hostKey(let prompt):
                HostKeySheet(prompt: prompt, onTrust: { trust(prompt) }, onCancel: { model.hostKeyPrompt = nil })
            case .approval(let item):
                ApprovalSheet(model: model, item: item)
            }
        }
        .alert(
            model.lastError?.title ?? "Something failed",
            isPresented: errorBinding,
            presenting: model.lastError
        ) { error in
            if error.isRecoverable {
                Button("Try again") { Task { await model.refresh() } }
            }
            Button("Dismiss", role: .cancel) { model.lastError = nil }
        } message: { error in
            Text(error.detail)
        }
    }

    // MARK: Compact

    /// Content above, tab bar below, both ours.
    ///
    /// Not a `TabView`, for the same reason the sidebar is not a `List`: the platform control brings a surface we
    /// cannot reach and, on macOS, places its strip at the top with labels that do not draw — so the compact
    /// layout could not be verified on the only machine this project renders on. Five fixed destinations need a
    /// row of five buttons, and that is a thing we can own completely and check.
    private func tabs(width: RootWidth) -> some View {
        VStack(spacing: 0) {
            navigated(router.destination, width: width)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            tabBar
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(ShellDestination.allCases) { destination in
                tabItem(destination)
            }
        }
        .frame(
            height: RootNavigationLayout.compactTabBarHeight(
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            ),
            alignment: .center
        )
        .background(OpenPawTheme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(OpenPawTheme.line).frame(height: OpenPawTheme.hairline)
        }
    }

    private func tabItem(_ destination: ShellDestination) -> some View {
        let isSelected = router.destination == destination
        return Button {
            router.destination = destination
        } label: {
            VStack(spacing: OpenPawTheme.Space.hair) {
                // The selected tab is marked by a rule along the edge it touches, mirroring the sidebar.
                Rectangle()
                    .fill(isSelected ? OpenPawTheme.textPrimary : Color.clear)
                    .frame(height: 2)
                Image(systemName: destination.glyph)
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .overlay(alignment: .topTrailing) {
                        if destination == .inbox, pendingCount > 0 {
                            Text("\(pendingCount)")
                                .font(OpenPawTheme.Machine.label)
                                .padding(.horizontal, OpenPawTheme.Space.tight)
                                .foregroundStyle(OpenPawTheme.ink)
                                .background(OpenPawTheme.warn)
                                .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.chip))
                                .alignmentGuide(.top) { $0[.bottom] / 2 }
                                .alignmentGuide(.trailing) { $0[.leading] }
                        }
                    }
                if RootNavigationLayout.showsVisualTabTitles(
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                ) {
                    Text(destination.title)
                        .font(OpenPawTheme.Machine.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.bottom, OpenPawTheme.Space.small)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(isSelected ? OpenPawTheme.textPrimary : OpenPawTheme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sidebarVoiceLabel(destination))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Wraps a destination in a `NavigationStack` only when it has somewhere to push.
    ///
    /// The terminal has its own header and nothing to navigate to, so a stack there contributes an empty
    /// navigation bar — which renders as a bare light strip above a dark screen and steals 44pt from the PTY.
    @ViewBuilder
    private func navigated(_ destination: ShellDestination, width: RootWidth) -> some View {
        if destination.pushesDetail {
            NavigationStack {
                content(destination, width: width)
            }
        } else {
            content(destination, width: width)
        }
    }

    // MARK: Regular

    /// Sidebar plus detail, built from an `HStack` rather than a `NavigationSplitView`.
    ///
    /// The platform split view lays its sidebar column out in a view hierarchy of its own, which nothing we do
    /// reaches: a column-width modifier applies while the content and ground do not draw, leaving a bare white
    /// column in a dark app. Since all six destinations are always wanted at this width, there is no collapse
    /// behaviour to inherit and nothing else the split view was buying. This is two panes and a hairline, ours
    /// end to end, and it renders identically on both platforms.
    private func split(width: RootWidth) -> some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Rectangle()
                .fill(OpenPawTheme.line)
                .frame(width: OpenPawTheme.hairline)
            navigated(router.destination, width: width)
                .frame(maxWidth: .infinity)
        }
    }

    /// Six fixed destinations and one host chip.
    ///
    /// Deliberately not a `List`. A list of six static rows buys nothing here — no editing, no swipe, no dynamic
    /// content — and costs the platform's sidebar material plus row-realisation behaviour that leaves the column
    /// empty in a headless render.
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
                Text("OpenPaw")
                    .microLabel()
                    .padding(.horizontal, OpenPawTheme.Space.medium)
                    .padding(.top, OpenPawTheme.Space.medium)
                    .padding(.bottom, OpenPawTheme.Space.small)

                ForEach(ShellDestination.allCases) { destination in
                    sidebarRow(destination)
                }

                Text("Host")
                    .microLabel()
                    .padding(.horizontal, OpenPawTheme.Space.medium)
                    .padding(.top, OpenPawTheme.Space.xl)
                    .padding(.bottom, OpenPawTheme.Space.small)

                hostChip
                    .padding(.horizontal, OpenPawTheme.Space.medium)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
        .background(OpenPawTheme.panel)
    }

    private func sidebarRow(_ destination: ShellDestination) -> some View {
        let isSelected = router.destination == destination
        return Button {
            router.destination = destination
        } label: {
            HStack(spacing: OpenPawTheme.Space.small) {
                // A 2pt rule rather than a filled pill: the selected row is stated, not decorated.
                Rectangle()
                    .fill(isSelected ? OpenPawTheme.textPrimary : Color.clear)
                    .frame(width: 2)
                    .accessibilityHidden(true)
                Image(systemName: destination.glyph)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(destination.title)
                    .font(OpenPawTheme.Machine.body)
                Spacer(minLength: 0)
                if destination == .inbox, pendingCount > 0 {
                    Text("\(pendingCount)")
                        .font(OpenPawTheme.Machine.label)
                        .padding(.horizontal, OpenPawTheme.Space.small)
                        .padding(.vertical, OpenPawTheme.Space.hair)
                        .foregroundStyle(OpenPawTheme.ink)
                        .background(OpenPawTheme.warn)
                        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.chip))
                }
            }
            .padding(.trailing, OpenPawTheme.Space.medium)
            .frame(minHeight: 44)
            .foregroundStyle(isSelected ? OpenPawTheme.textPrimary : OpenPawTheme.textSecondary)
            .background(isSelected ? OpenPawTheme.well : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sidebarVoiceLabel(destination))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func sidebarVoiceLabel(_ destination: ShellDestination) -> String {
        guard destination == .inbox, pendingCount > 0 else { return destination.title }
        return "\(destination.title), \(pendingCount) waiting"
    }

    private var hostChip: some View {
        let status = ConnectionPresentation.make(model.connection)
        return Button {
            router.destination = .settings
        } label: {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
                Text(model.selectedHost?.nickname ?? "No host")
                    .font(OpenPawTheme.Machine.body)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                HStack(spacing: OpenPawTheme.Space.tight) {
                    Circle()
                        .fill(status.tone)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(status.label).microLabel(status.tone)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.selectedHost?.nickname ?? "No host"), \(status.label). Opens settings")
    }

    // MARK: Destination content

    @ViewBuilder
    private func content(_ destination: ShellDestination, width: RootWidth) -> some View {
        switch destination {
        case .home:
            WorkspaceHomeView(
                model: model,
                settings: settings,
                onDeviceAction: openHomeDevice(_:intent:),
                onOpenAgent: openHomeAgent(_:),
                onOpenApproval: { router.openApproval(itemID: $0) },
                onOpenRepository: openHomeRepository(_:)
            )
        case .terminal:
            TerminalScreenView(
                model: model,
                settings: settings,
                scrollback: scrollback,
                surface: terminalSurface,
                onFontSizeChange: { _ in }
            )
        case .chat:
            chat(width: width)
        case .inbox:
            InboxView(model: model)
        case .repo:
            repo
        case .settings:
            SettingsView(model: model, settings: settings)
        }
    }

    private func openHomeDevice(_ host: HostRecord, intent: WorkspaceResumeIntent) {
        let canResumeSelectedHost = host.id == model.selectedHostID && model.connection.isConnected
        model.selectedHostID = host.id
        if canResumeSelectedHost {
            routeHomeIntent(intent)
        } else {
            Task {
                await model.connectSelectedHost()
                if model.connection.isConnected {
                    settings.recordConnection(to: host.id)
                    router.destination = .terminal
                }
            }
        }
    }

    private func routeHomeIntent(_ intent: WorkspaceResumeIntent) {
        switch intent {
        case .agentSession(let sessionID):
            openHomeAgent(sessionID)
        case .repository(let repo):
            openHomeRepository(repo)
        case .terminal:
            router.destination = .terminal
        }
    }

    private func openHomeAgent(_ sessionID: String) {
        model.selectedSessionID = sessionID
        router.chatSessionID = sessionID
        router.destination = .chat
    }

    private func openHomeRepository(_ repo: String) {
        model.selectedRepo = repo
        router.destination = .repo
    }

    @ViewBuilder
    private func chat(width: RootWidth) -> some View {
        switch RootNavigationStyle.style(for: width) {
        case .tabs:
            SessionListView(
                model: model,
                remoteSessions: sessionSpace.remoteSessions,
                restoration: sessionSpace.restoration,
                transport: sessionSpace.transport,
                onSelect: selectSession,
                onAttach: attachSession,
                onCreate: createSession,
                onRename: renameSession,
                onKill: killSession,
                onRestore: restoreSession,
                onRefresh: refreshModelAndSessionSpace
            )
                .navigationDestination(item: chatSessionBinding) { sessionID in
                    transcript(sessionID)
                }
        case .split:
            HStack(spacing: 0) {
                SessionListView(
                model: model,
                remoteSessions: sessionSpace.remoteSessions,
                restoration: sessionSpace.restoration,
                transport: sessionSpace.transport,
                onSelect: selectSession,
                onAttach: attachSession,
                onCreate: createSession,
                onRename: renameSession,
                onKill: killSession,
                onRestore: restoreSession,
                onRefresh: refreshModelAndSessionSpace
            )
                    .frame(width: 340)
                Rectangle()
                    .fill(OpenPawTheme.line)
                    .frame(width: OpenPawTheme.hairline)
                if let sessionID = model.selectedSessionID {
                    transcript(sessionID)
                } else {
                    EmptyStateView(
                        glyph: "text.bubble",
                        title: "No session open",
                        message: "Pick a session on the left to read what the agent said and did.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func transcript(_ sessionID: String) -> some View {
        ChatView(
            model: model,
            settings: settings,
            sessionID: sessionID,
            onOpenFile: openFile(_:),
            onApprove: { router.openApproval(itemID: $0) }
        )
    }

    private func refreshSessionSpace() async {
        let requestedHostID = model.selectedHostID
        let requestedGeneration = model.connectionGeneration
        guard model.connection.isConnected else { sessionSpace = SessionSpaceSnapshot(); return }
        let snapshot = await sessionSpaceProvider.snapshot(for: model)
        guard requestedHostID == model.selectedHostID,
              requestedGeneration == model.connectionGeneration,
              snapshot.hostID == model.selectedHostID,
              snapshot.connectionGeneration == model.connectionGeneration else { return }
        sessionSpace = snapshot
        if !snapshot.issues.isEmpty {
            model.lastError = PresentedError(
                title: "Session discovery issue",
                detail: snapshot.issues.joined(separator: "\n"),
                isRecoverable: true)
        }
    }

    private func refreshModelAndSessionSpace() async {
        if model.canRefreshRemoteState { await model.refresh() }
        await refreshSessionSpace()
    }

    private func invalidateSessionSpace() {
        sessionSpace = SessionSpaceSnapshot(hostID: model.selectedHostID, connectionGeneration: model.connectionGeneration)
    }

    private func runSessionCommand(_ command: String, refreshAfterCommand: Bool) {
        Task {
            do {
                guard sessionSpace.hostID == model.selectedHostID,
                      sessionSpace.connectionGeneration == model.connectionGeneration,
                      model.connection.isConnected else {
                    throw SessionSpaceActionError.unavailable
                }
                try await sessionCommandExecutor.executeSessionCommand(command)
                if refreshAfterCommand { await refreshSessionSpace() }
            } catch {
                model.lastError = PresentedError(title: "Session command failed", detail: safeSessionActionMessage(error), isRecoverable: true)
            }
        }
    }

    private func canUseCurrentSessionSpace() -> Bool {
        SessionSpaceActionPolicy.canUseSnapshot(
            sessionSpace,
            hostID: model.selectedHostID,
            generation: model.connectionGeneration,
            isConnected: model.connection.isConnected)
    }

    private func attachSession(_ session: RemoteSession) {
        guard canUseCurrentSessionSpace() else { return }
        guard session.isAlive else { presentUnavailableSessionAction(); return }
        recordAttachRestorationPlan(session)
        runSessionCommand(MultiplexerAdapters.adapter(for: session.kind).attach(session), refreshAfterCommand: false)
        router.destination = .terminal
    }

    private func createSession(_ name: String) {
        guard canUseCurrentSessionSpace() else { return }
        let adapter = MultiplexerAdapters.adapter(for: sessionSpace.multiplexerForNewSessions)
        runSessionCommand(adapter.create(name: name, directory: nil), refreshAfterCommand: false)
        router.destination = .terminal
    }

    private func renameSession(_ session: RemoteSession, to name: String) {
        guard canUseCurrentSessionSpace() else { return }
        guard session.isAlive else { presentUnavailableSessionAction(); return }
        runSessionCommand(MultiplexerAdapters.adapter(for: session.kind).rename(session, to: name), refreshAfterCommand: true)
    }

    private func killSession(_ session: RemoteSession) {
        guard canUseCurrentSessionSpace() else { return }
        clearRestorationPlan(ifMatches: session)
        runSessionCommand(MultiplexerAdapters.adapter(for: session.kind).kill(session), refreshAfterCommand: true)
    }

    private func restoreSession(_ plan: SessionRestorationPlan) {
        guard plan.hostID == model.selectedHostID,
              sessionSpace.hostID == model.selectedHostID,
              sessionSpace.connectionGeneration == model.connectionGeneration,
              canUseCurrentSessionSpace() else { return }
        let command: String?
        if let kind = plan.multiplexer,
           let target = plan.multiplexerTarget,
           !sessionSpace.remoteSessions.contains(where: { $0.kind == kind && $0.id == target && $0.isAlive }) {
            command = MultiplexerAdapters.adapter(for: kind).create(name: "openpaw", directory: plan.workingDirectory)
        } else {
            command = plan.restorationCommand()
        }
        guard let command else { presentUnavailableSessionAction(); return }
        runSessionCommand(command, refreshAfterCommand: false)
        router.destination = .terminal
    }

    private func recordAttachRestorationPlan(_ session: RemoteSession) {
        guard let hostID = model.selectedHostID, sessionSpace.hostID == hostID else { return }
        if let plan = SessionRestorationRecorder().planForAttach(hostID: hostID, session: session) {
            Task { await restorationStore?.save(plan) }
        }
    }

    private func recordCreateRestorationPlan(kind: MultiplexerKind, name: String) {
        guard let hostID = model.selectedHostID, sessionSpace.hostID == hostID else { return }
        if let plan = SessionRestorationRecorder().planForCreate(hostID: hostID, kind: kind, name: name) {
            Task { await restorationStore?.save(plan) }
        }
    }

    private func clearRestorationPlan(ifMatches session: RemoteSession) {
        guard let hostID = model.selectedHostID, sessionSpace.hostID == hostID else { return }
        Task {
            guard let plan = await restorationStore?.loadPlan(for: hostID), plan.multiplexer == session.kind, plan.multiplexerTarget == session.id else { return }
            await restorationStore?.clearPlan(for: hostID)
        }
    }

    private enum SessionSpaceActionError: Error { case unavailable }

    private func presentUnavailableSessionAction() {
        model.lastError = PresentedError(title: "Session action unavailable", detail: "Refresh sessions and try again.", isRecoverable: true)
    }

    private func safeSessionActionMessage(_ error: any Error) -> String {
        if let failure = error as? CommandFailure {
            return "The remote command exited with status \(failure.exitCode)."
        }
        return "The session action could not be completed. Check the connection and try again."
    }

    @ViewBuilder
    private var repo: some View {
        if let name = model.selectedRepo ?? model.repos.first?.name {
            VStack(spacing: 0) {
                repoBar(name)
                repoPane(name)
            }
        } else {
            EmptyStateView(
                glyph: "folder",
                title: "No repositories",
                message: repoEmptyMessage,
                actionTitle: "Refresh",
                action: { Task { await model.refresh() } })
        }
    }

    private var repoEmptyMessage: String {
        """
        The host exposes no repositories yet. Run openpaw-host init --repo with a checkout on the host, and it \
        appears here.
        """
    }

    private func repoBar(_ name: String) -> some View {
        VStack(spacing: OpenPawTheme.Space.small) {
            if model.repos.count > 1 {
                Picker("Repository", selection: repoBinding) {
                    ForEach(model.repos) { summary in
                        Text(summary.name).tag(summary.name)
                    }
                }
                .labelsHidden()
                .frame(minHeight: 44)
            } else {
                HStack(spacing: OpenPawTheme.Space.small) {
                    Text("repo").microLabel()
                    Text(name)
                        .font(OpenPawTheme.Machine.body)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                    Spacer(minLength: 0)
                }
            }
            Picker("Repo pane", selection: repoPaneBinding) {
                ForEach(RepoPane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, OpenPawTheme.Space.medium)
        .padding(.vertical, OpenPawTheme.Space.small)
        .background(OpenPawTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(OpenPawTheme.line).frame(height: OpenPawTheme.hairline)
        }
    }

    @ViewBuilder
    private func repoPane(_ name: String) -> some View {
        switch router.repoPane {
        case .diff:
            DiffViewerView(
                model: model, repo: name, mode: router.diffMode, focusPath: router.repoFocusPath,
                openInFileBrowser: openFile(_:))
        case .files:
            FileBrowserView(
                model: model, repo: name, focusPath: router.repoFocusPath, sendPathToAgent: sendPath(_:))
        case .preview:
            PreviewWebView(model: model, port: settings.previewPort)
        case .status:
            RepoStatusView(model: model, repo: name, openDiff: openDiff(_:_:))
        }
    }

    /// A path named anywhere in the app opens in the file browser. One rule, so tapping a path never surprises.
    private func openFile(_ path: String) {
        router.repoFocusPath = path
        router.repoPane = .files
        router.destination = .repo
    }

    private func openDiff(_ path: String, _ mode: DiffMode) {
        router.repoFocusPath = path
        router.diffMode = mode
        router.repoPane = .diff
        router.destination = .repo
    }

    /// Types a path at the prompt rather than running it: quoting is applied because a path with a space in it is
    /// the one that breaks.
    private func sendPath(_ path: String) {
        guard let terminal = model.terminal else { return }
        Task {
            do {
                try await terminal.send(text: shellQuoted(path))
            } catch {
                model.present(error, while: "sending a path to the terminal")
            }
        }
    }

    // MARK: Sheets

    private enum ShellSheet: Identifiable {
        case hostKey(HostKeyPrompt)
        case approval(InboxItem)

        var id: String {
            switch self {
            case .hostKey(let prompt): "host-key-\(prompt.id)"
            case .approval(let item): "approval-\(item.id.rawValue)"
            }
        }
    }

    /// A host key block always outranks an approval. The key decision is about whether you are talking to your own
    /// machine at all, which makes every other decision on screen meaningless until it is settled.
    private var currentSheet: ShellSheet? {
        if let prompt = model.hostKeyPrompt { return .hostKey(prompt) }
        guard let id = router.approvalItemID,
            let item = model.inbox.first(where: { $0.id.rawValue == id })
        else { return nil }
        return .approval(item)
    }

    private var sheetBinding: Binding<ShellSheet?> {
        Binding(
            get: { currentSheet },
            set: { newValue in
                guard newValue == nil else { return }
                model.hostKeyPrompt = nil
                router.approvalItemID = nil
            }
        )
    }

    private func trust(_ prompt: HostKeyPrompt) {
        // Only `.unknown` reaches here: the sheet has no trust control for a changed key.
        guard prompt.allowsTrust, case .unknown(let fingerprint) = prompt.verdict,
            let host = model.selectedHost
        else {
            model.hostKeyPrompt = nil
            return
        }
        do {
            let entry = KnownHostEntry(keyType: "ssh-ed25519", fingerprint: fingerprint, addedAt: Date())
            try model.hostStore.trust(entry, for: host.id)
            model.hostKeyPrompt = nil
            Task { await model.connectSelectedHost() }
        } catch {
            model.present(error, while: "pinning the host key")
        }
    }

    // MARK: Bindings

    private var pendingCount: Int { model.pendingInbox.count }

    private var destinationBinding: Binding<ShellDestination> {
        Binding(get: { router.destination }, set: { router.destination = $0 })
    }

    private var repoPaneBinding: Binding<RepoPane> {
        Binding(get: { router.repoPane }, set: { router.repoPane = $0 })
    }

    private var repoBinding: Binding<String> {
        Binding(
            get: { model.selectedRepo ?? model.repos.first?.name ?? "" },
            set: { name in
                model.selectedRepo = name
                // A different repository means the remembered path belongs to something else.
                router.repoFocusPath = nil
            }
        )
    }

    private var chatSessionBinding: Binding<String?> {
        Binding(get: { router.chatSessionID }, set: { router.chatSessionID = $0 })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
    }

    private func selectSession(_ session: SessionSummary) {
        model.selectedSessionID = session.sessionID
        model.startFollowing(session: session.sessionID)
        router.chatSessionID = session.sessionID
    }

    /// Feeds the scrollback store from the PTY so search and copy work whichever surface the app injected. The
    /// store is the app's own record of the session; the surface only draws the live screen.
    private func pumpScrollback() async {
        guard let terminal = model.terminal else { return }
        for await chunk in terminal.outputStream {
            await scrollback.append(chunk)
        }
    }
}

#Preview("Root, populated") {
    let model = PreviewBackend.model(.populated)
    let store = ScrollbackStore()
    RootView(model: model, terminalSurface: { AnyView(ScrollbackTextView(store: store)) })
        .preferredColorScheme(.dark)
}

#Preview("Root, empty") {
    let model = PreviewBackend.model(.empty)
    let store = ScrollbackStore()
    RootView(model: model, terminalSurface: { AnyView(ScrollbackTextView(store: store)) })
        .preferredColorScheme(.dark)
}
