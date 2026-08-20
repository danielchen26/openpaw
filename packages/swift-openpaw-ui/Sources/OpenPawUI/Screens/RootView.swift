import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI

// MARK: - Layout selection

/// The two widths the app is designed for. Kept as our own type rather than `UserInterfaceSizeClass` so the choice
/// is testable and so the macOS build, which has no size class, does not need a special case at every call site.
public enum RootWidth: String, Sendable, Hashable, CaseIterable {
    case compact
    case regular
}

/// How the five destinations are presented.
public enum RootNavigationStyle: String, Sendable, Hashable, CaseIterable {
    /// Tab bar at the bottom: one thumb, one hand, five reachable targets.
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

// MARK: - Destinations

public enum ShellDestination: String, Sendable, Hashable, CaseIterable, Identifiable {
    case terminal
    case chat
    case inbox
    case repo
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .terminal: "Terminal"
        case .chat: "Chat"
        case .inbox: "Inbox"
        case .repo: "Repo"
        case .settings: "Settings"
        }
    }

    public var glyph: String {
        switch self {
        case .terminal: "terminal"
        case .chat: "text.bubble"
        case .inbox: "tray.full"
        case .repo: "arrow.triangle.branch"
        case .settings: "gearshape"
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
    public var destination: ShellDestination = .terminal
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

    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// `terminalSurface` is the live PTY view. The app injects its SwiftTerm-backed surface; a headless snapshot run
    /// injects `ScrollbackTextView`. Construct this once and keep it: the router it holds is the navigation state.
    public init(model: OpenPawModel, terminalSurface: @escaping () -> AnyView) {
        self.model = model
        self.terminalSurface = terminalSurface
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

    public var width: RootWidth {
        #if os(iOS)
            horizontalSizeClass == .compact ? .compact : .regular
        #else
            .regular
        #endif
    }

    public var body: some View {
        Group {
            switch RootNavigationStyle.style(for: width) {
            case .tabs: tabs
            case .split: split
            }
        }
        .background(OpenPawTheme.ink)
        .tint(OpenPawTheme.textPrimary)
        .task {
            await model.refresh()
            model.startFollowing(session: model.selectedSessionID)
        }
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

    private var tabs: some View {
        TabView(selection: destinationBinding) {
            ForEach(ShellDestination.allCases) { destination in
                NavigationStack {
                    content(destination)
                }
                .tabItem {
                    Label(destination.title, systemImage: destination.glyph)
                }
                .badge(destination == .inbox ? pendingCount : 0)
                .tag(destination)
            }
        }
    }

    // MARK: Regular

    private var split: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                content(router.destination)
            }
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                ForEach(ShellDestination.allCases) { destination in
                    HStack(spacing: OpenPawTheme.Space.small) {
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
                    .frame(minHeight: 44)
                    .listRowBackground(Color.clear)
                    .accessibilityLabel(sidebarVoiceLabel(destination))
                    .tag(destination)
                }
            } header: {
                Text("OpenPaw").microLabel()
            }

            Section {
                hostChip
                    .listRowBackground(Color.clear)
            } header: {
                Text("Host").microLabel()
            }
        }
        .listStyle(.plain)
        // A `List` brings its own surface — the light sidebar material on macOS, grouped grey on iOS. Both fight
        // the ink ground, so the list's own background is removed and the panel tone put back underneath.
        .scrollContentBackground(.hidden)
        .background(OpenPawTheme.panel)
        .foregroundStyle(OpenPawTheme.textPrimary)
        .navigationTitle("OpenPaw")
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
    private func content(_ destination: ShellDestination) -> some View {
        switch destination {
        case .terminal:
            TerminalScreenView(
                model: model,
                settings: settings,
                scrollback: scrollback,
                surface: terminalSurface,
                onFontSizeChange: { _ in }
            )
        case .chat:
            chat
        case .inbox:
            InboxView(model: model)
        case .repo:
            repo
        case .settings:
            SettingsView(model: model, settings: settings)
        }
    }

    @ViewBuilder
    private var chat: some View {
        switch RootNavigationStyle.style(for: width) {
        case .tabs:
            SessionListView(model: model, onSelect: selectSession)
                .navigationDestination(item: chatSessionBinding) { sessionID in
                    transcript(sessionID)
                }
        case .split:
            HStack(spacing: 0) {
                SessionListView(model: model, onSelect: selectSession)
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
            sessionID: sessionID,
            onOpenFile: openFile(_:),
            onApprove: { router.openApproval(itemID: $0) }
        )
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

    private var sidebarSelection: Binding<ShellDestination?> {
        Binding(
            get: { router.destination },
            set: { if let destination = $0 { router.destination = destination } }
        )
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
