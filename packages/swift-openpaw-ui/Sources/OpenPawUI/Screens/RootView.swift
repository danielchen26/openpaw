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
    case sessions
    case inbox
    case repo
    case settings

    public var id: String { rawValue }

    /// Reads persisted and deep-link state from before Chat became the first-class Sessions destination.
    public init?(rawValue: String) {
        switch rawValue {
        case "home": self = .home
        case "terminal": self = .terminal
        case "chat", "sessions": self = .sessions
        case "inbox": self = .inbox
        case "repo": self = .repo
        case "settings": self = .settings
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .home: "Home"
        case .terminal: "Terminal"
        case .sessions: "Sessions"
        case .inbox: "Inbox"
        case .repo: "Repo"
        case .settings: "Settings"
        }
    }

    public var glyph: String {
        switch self {
        case .home: "house"
        case .terminal: "terminal"
        case .sessions: "text.bubble"
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
        case .home, .sessions, .inbox, .repo, .settings: true
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
    /// The host that owns the presented item when navigation came from a notification or custom URL.
    public var approvalRoute: InboxRoute?
    public var inboxRoutePresentation: InboxRoutePresentation?
    private var inboxRouteRequestGeneration = 0
    private var inboxRouteRequestTask: Task<Void, Never>?
    private var inboxRouteTargetHostID: HostID?
    /// Generation whose route-owned host mutation may be rolled back after a privacy lock.
    /// Starting a newer route or invalidating host state clears this marker, so stale work
    /// can never restore an older host over a newer user action.
    private var inboxRouteRollbackGeneration: Int?
    public var inboxDetailItemID: String? {
        get {
            guard inboxRoutePresentation == .detail else { return nil }
            return approvalRoute?.itemID.rawValue
        }
        set {
            guard newValue == nil, inboxRoutePresentation == .detail else { return }
            approvalRoute = nil
            inboxRoutePresentation = nil
        }
    }
    /// Session the compact layout has pushed a transcript for.
    public var sessionID: String?
    /// Multiplexer session the Terminal destination is entering. Cleared at the host-generation boundary.
    public var attachedMultiplexerSession: RemoteSession?

    @available(*, deprecated, renamed: "sessionID")
    public var chatSessionID: String? {
        get { sessionID }
        set { sessionID = newValue }
    }

    public init() {}

    public func openApproval(itemID: String) {
        approvalRoute = nil
        approvalItemID = itemID
        destination = .inbox
    }

    public func openInboxRoute(_ route: InboxRoute) {
        openInboxRoute(route, presentation: .approvalSheet)
    }

    public func openInboxRoute(_ route: InboxRoute, presentation: InboxRoutePresentation) {
        approvalRoute = route
        inboxRoutePresentation = presentation
        approvalItemID = presentation == .approvalSheet ? route.itemID.rawValue : nil
        destination = .inbox
    }

    public func beginInboxRouteRequest(targetHostID: HostID? = nil) -> Int {
        inboxRouteRequestTask?.cancel()
        inboxRouteRequestTask = nil
        inboxRouteTargetHostID = targetHostID
        inboxRouteRollbackGeneration = nil
        inboxRouteRequestGeneration += 1
        return inboxRouteRequestGeneration
    }

    public func trackInboxRouteRequest(_ task: Task<Void, Never>, generation: Int) {
        guard ownsInboxRouteRequest(generation) else {
            task.cancel()
            return
        }
        inboxRouteRequestTask?.cancel()
        inboxRouteRequestTask = task
    }

    public func ownsInboxRouteRequest(_ generation: Int) -> Bool {
        generation == inboxRouteRequestGeneration
    }

    public func mayRollbackInboxRouteRequest(_ generation: Int) -> Bool {
        inboxRouteRollbackGeneration == generation
    }

    public func finishInboxRouteRequest(_ generation: Int) {
        guard ownsInboxRouteRequest(generation) else { return }
        inboxRouteRequestTask = nil
        inboxRouteTargetHostID = nil
    }

    /// Cancels only notification/deep-link work. A biometric lock must not erase
    /// the user's selected Session, repository pane, or terminal attachment.
    public func cancelInboxRouteRequest(rollbackHostMutation: Bool = false) {
        let cancelledGeneration = inboxRouteRequestGeneration
        inboxRouteRequestTask?.cancel()
        inboxRouteRequestTask = nil
        inboxRouteTargetHostID = nil
        inboxRouteRollbackGeneration = rollbackHostMutation ? cancelledGeneration : nil
        inboxRouteRequestGeneration += 1
        approvalItemID = nil
        approvalRoute = nil
        inboxRoutePresentation = nil
    }

    public func perform(_ intent: SessionRootIntent, model: OpenPawModel) {
        switch intent {
        case .openSessionTranscript(let sessionID):
            model.selectedSessionID = sessionID
            self.sessionID = sessionID
            destination = .sessions
        case .openTerminalSession:
            sessionID = nil
            attachedMultiplexerSession = nil
            destination = .terminal
        case .attachSession(let session):
            sessionID = nil
            attachedMultiplexerSession = session
            destination = .terminal
        case .resumeWorkspace(let resume):
            switch resume {
            case .agentSession(let sessionID):
                perform(.openSessionTranscript(sessionID), model: model)
            case .repository(let repository):
                model.selectedRepo = repository
                destination = .repo
            case .terminal:
                perform(.openTerminalSession, model: model)
            }
        }
    }

    /// Clears navigation that names resources owned by one host while leaving the user's root tab in place.
    /// Future Preview and provider/import routes must join this one reset point rather than inventing another host
    /// generation boundary.
    public func invalidateHostScopedState(preservingInboxRouteFor hostID: HostID? = nil) {
        sessionID = nil
        invalidateConnectionScopedState()
        if hostID == nil || inboxRouteTargetHostID != hostID {
            cancelInboxRouteRequest(rollbackHostMutation: false)
        }
        repoPane = .diff
        repoFocusPath = nil
        diffMode = .workingTree
    }

    /// Clears routes owned by one terminal connection even when the selected host id did not change.
    public func invalidateConnectionScopedState() {
        attachedMultiplexerSession = nil
    }
}

public enum InboxRoutePresentation: Sendable, Hashable {
    case detail
    case approvalSheet
}

public enum SessionRootIntent: Sendable, Hashable {
    case openSessionTranscript(String)
    case openTerminalSession
    case attachSession(RemoteSession)
    case resumeWorkspace(WorkspaceResumeIntent)
}

public struct HomeResumeResolution: Sendable, Hashable {
    public var intent: WorkspaceResumeIntent
    public var connection: HostConnectionLease

    public init(intent: WorkspaceResumeIntent, connection: HostConnectionLease) {
        self.intent = intent
        self.connection = connection
    }
}

/// Resolves a Home card into its original intent only after the requested host owns a live connection.
///
/// Returning the intent instead of mutating the router keeps the host check and the route separate: callers can perform
/// one final ownership check immediately before navigation, while tests can suspend connection and prove stale cards do
/// not redirect a newer host.
@MainActor
public enum HomeResumeCoordinator {
    public static func resolve(
        host: HostRecord,
        intent: WorkspaceResumeIntent,
        model: OpenPawModel
    ) async -> HomeResumeResolution? {
        let alreadyReady = model.selectedHostID == host.id && model.connection.isConnected
        if model.selectedHostID != host.id { await model.selectHost(host.id) }
        guard model.selectedHostID == host.id else { return nil }
        let connection: HostConnectionLease?
        if alreadyReady {
            connection = model.currentConnectionLease
        } else {
            connection = await model.connectSelectedHost()
        }
        guard let connection, model.ownsConnection(connection) else { return nil }
        return HomeResumeResolution(intent: intent, connection: connection)
    }
}

public enum RootRequestedSheet: Sendable, Hashable {
    case addDevice
    case manageHosts
}

public enum RootSheetKind: Sendable, Hashable {
    case hostKey
    case quickConnect
    case approval
    case addDevice
    case manageHosts
}

public enum RootSheetPolicy {
    public static func resolve(
        hostKey: Bool,
        quickConnect: Bool,
        approval: Bool,
        requested: RootRequestedSheet?
    ) -> RootSheetKind? {
        if hostKey { return .hostKey }
        if quickConnect { return .quickConnect }
        if approval { return .approval }
        switch requested {
        case .addDevice: return .addDevice
        case .manageHosts: return .manageHosts
        case nil: return nil
        }
    }
}

public enum RootQuickConnectRouting {
    public static func destination(
        for stage: QuickConnectCoordinator.Stage,
        ownsTerminalLease: Bool
    ) -> ShellDestination? {
        guard stage == .connected, ownsTerminalLease else { return nil }
        return .terminal
    }
}

/// Everything that can change which engine the app-wide hold gesture should use.
///
/// Keeping model state in this value is important: downloading Qwen does not change the selected setting, so a
/// root that only watches the picker remains bound to `nil` until it is recreated. Reading `state(of:)` here also
/// registers the observable model store with SwiftUI, and the completed download invalidates the key immediately.
struct RootPushToTalkConfiguration: Equatable {
    let choice: DictationEngineChoice
    let localeID: String
    let mode: DictationMode
    let modelState: DictationModelState
    let hasInjectedEngine: Bool

    @MainActor
    static func make(model: OpenPawModel, settings: OpenPawSettings) -> Self {
        let choice = settings.effectiveDictationEngine
        return Self(
            choice: choice,
            localeID: settings.dictationLocaleID,
            mode: settings.dictationMode,
            modelState: model.dictationModels.state(of: choice),
            hasInjectedEngine: model.dictation != nil
        )
    }
}

private struct ExistingOnlyQuickConnectCredentialInstaller: QuickConnectCredentialInstalling {
    func install(_ choice: QuickConnectCredentialChoice) async throws -> AuthMethod {
        guard case .existing(let auth) = choice else { throw QuickConnectCredentialInstallError.storageFailed }
        return auth
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
    private let quickConnectCoordinator: QuickConnectCoordinator
    private let persistHostStore: @MainActor @Sendable (HostStore) -> Void
    private let onOpenPawURL: (URL) -> Void
    @State private var sessionSpace = SessionSpaceSnapshot()
    /// Hold-anywhere dictation. Owned here so the gesture and its ring exist on every destination rather than
    /// being reimplemented per screen.
    @State private var pushToTalk = PushToTalkController()
    /// The Paw Orb radial launcher: one frozen gesture state and the latest context graph it launches from.
    @State private var launcherState = RadialLauncherState()
    @State private var launcherGraph = WorkspaceContextGraphBuilder().build(
        WorkspaceContextInput(snapshotID: UUID(), host: nil, connectionGeneration: 0, destination: .home))
    /// The terminal key strip: esc, ctrl, arrows. On by default on the Terminal destination, toggled from the
    /// launcher's Tools branch. The strip is the one Control Deck page a terminal cannot be driven without.
    @State private var showsTerminalKeys = true
    @State private var isTerminalSearchPresented = false
    /// Modifiers the key bar is holding down. Owned here because the key bar moved out of the terminal screen and
    /// onto the strip, and a latched `ctrl` has to survive the user swiping to another page.
    @State private var latchedModifiers: KeyModifiers = []
    /// Terminal actions the strip's view page triggers on the terminal screen.
    @State private var terminalControls = TerminalControlBus()
    @State private var requestedSheet: RootRequestedSheet?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// `terminalSurface` is the live PTY view. The app injects its SwiftTerm-backed surface; a headless snapshot run
    /// injects `ScrollbackTextView`. Construct this once and keep it: the router it holds is the navigation state.
    public init(
        model: OpenPawModel,
        terminalSurface: @escaping () -> AnyView,
        quickConnectCoordinator: QuickConnectCoordinator? = nil,
        settings: OpenPawSettings = OpenPawSettings(),
        sessionSpaceProvider: any SessionSpaceProviding = EmptySessionSpaceProvider(),
        sessionCommandExecutor: any SessionSpaceCommandExecuting = EmptySessionSpaceCommandExecutor(),
        restorationStore: (any SessionRestorationStoring)? = nil,
        persistHostStore: @escaping @MainActor @Sendable (HostStore) -> Void = { _ in },
        onOpenPawURL: @escaping (URL) -> Void = { _ in }
    ) {
        self.model = model
        self.terminalSurface = terminalSurface
        self.settings = settings
        self.sessionSpaceProvider = sessionSpaceProvider
        self.sessionCommandExecutor = sessionCommandExecutor
        self.restorationStore = restorationStore
        self.persistHostStore = persistHostStore
        self.onOpenPawURL = onOpenPawURL
        self.quickConnectCoordinator = quickConnectCoordinator ?? QuickConnectCoordinator(
            model: model,
            installer: ExistingOnlyQuickConnectCredentialInstaller())
        self.router = ShellRouter()
        // Roughly 120 bytes a line. The store follows the injected settings owner for this RootView instance.
        self.scrollback = ScrollbackStore(byteBudget: settings.scrollbackLines * 120)
    }

    /// Deep-link entry point. Safe to call before the inbox has loaded: the id is remembered and the sheet opens as
    /// soon as the item arrives.
    public func openApproval(itemID: String) {
        router.openApproval(itemID: itemID)
        Task { await model.refresh() }
    }

    /// Public handoff for Home now and pairing links/scanning in Task 6.
    public func openQuickConnect(_ proposal: QuickConnectProposal) {
        quickConnectCoordinator.begin(proposal)
    }

    /// Host-scoped deep-link entry point. The sheet is not named until the requested host owns a live connection and
    /// the authenticated Inbox refresh returns the exact item.
    public func openInboxRoute(_ route: InboxRoute) {
        let generation = router.beginInboxRouteRequest(targetHostID: route.hostID)
        let task = Task {
            defer { router.finishInboxRouteRequest(generation) }
            let ownsRoute: @MainActor @Sendable () -> Bool = { router.ownsInboxRouteRequest(generation) }
            let mayRollback: @MainActor @Sendable () -> Bool = {
                router.mayRollbackInboxRouteRequest(generation)
            }
            switch await InboxRouteCoordinator.resolve(
                route,
                model: model,
                ownsRoute: ownsRoute,
                mayRollback: mayRollback
            ) {
            case .present(let item):
                guard ownsRoute() else { return }
                router.openInboxRoute(route, presentation: item.isDismissible ? .detail : .approvalSheet)
            case .unknownHost:
                guard ownsRoute() else { return }
                model.lastError = PresentedError(
                    title: "This host is not on this device",
                    detail: "Add or pair the host before opening this Inbox item.",
                    isRecoverable: false
                )
            case .stale:
                guard ownsRoute() else { return }
                router.destination = .inbox
                model.lastError = PresentedError(
                    title: "This Inbox item is no longer available",
                    detail: "The host restarted or no longer has this notification. Refresh the Inbox for current work.",
                    isRecoverable: true
                )
            case .resolved(let status):
                guard ownsRoute() else { return }
                router.destination = .inbox
                model.lastError = PresentedError(
                    title: "This Inbox item is already \(status.rawValue)",
                    detail: "Open the Inbox to review its recorded outcome.",
                    isRecoverable: false
                )
            case .unavailable:
                guard ownsRoute() else { return }
                model.lastError = PresentedError(
                    title: "Could not open this Inbox item",
                    detail: "The requested host did not remain connected. Reconnect it and try the link again.",
                    isRecoverable: true
                )
            }
        }
        router.trackInboxRouteRequest(task, generation: generation)
    }

    /// App-level privacy gates call this before removing the unlocked hierarchy.
    /// It is deliberately narrower than host invalidation so locking the phone
    /// does not discard unrelated workspace navigation.
    public func cancelInboxRouteRequest() {
        router.cancelInboxRouteRequest(rollbackHostMutation: true)
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
        .overlay { pushToTalkLayer }
        .overlay(alignment: .topLeading) { destinationSwipeLayer }
        .background(OpenPawTheme.ink)
        .tint(OpenPawTheme.textPrimary)
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
            guard press.modifiers == [.command, .option] else { return .ignored }
            let decision: DestinationPageDecision = press.key == .leftArrow ? .previous : .next
            return pageRoot(decision) ? .handled : .ignored
        }
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
            router.invalidateHostScopedState(preservingInboxRouteFor: model.selectedHostID)
            invalidateSessionSpace()
            Task {
                if model.canRefreshRemoteState { await model.refresh() }
                await refreshSessionSpace()
            }
        }
        .onChange(of: model.connectionGeneration) { _, _ in
            router.invalidateConnectionScopedState()
            invalidateSessionSpace()
            Task { await refreshSessionSpace() }
        }
        .onChange(of: quickConnectCoordinator.stage) { _, stage in
            routeQuickConnectIfOwned(stage)
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
        // Includes the model-install state, not only the picker. Completing a Qwen download must replace the
        // unavailable binding before the next hold without requiring navigation or relaunch.
        .onChange(of: RootPushToTalkConfiguration.make(model: model, settings: settings)) { _, _ in
            configurePushToTalk()
        }
        .onAppear { configurePushToTalk() }
        .sheet(item: sheetBinding) { sheet in
            switch sheet {
            case .hostKey(let prompt):
                HostKeySheet(prompt: prompt, onTrust: { trust(prompt) }, onCancel: { model.hostKeyPrompt = nil })
            case .quickConnect:
                QuickConnectView(
                    coordinator: quickConnectCoordinator,
                    hostStore: model.hostStore,
                    onCancel: {},
                    onConnected: {
                        router.destination = .terminal
                        quickConnectCoordinator.cancel()
                    })
            case .approval(let item):
                ApprovalSheet(model: model, item: item)
            case .addDevice:
                NavigationStack {
                    AddDeviceFlow(
                        model: model,
                        settings: settings,
                        candidates: model.homeTailnetBootstrap.candidates,
                        onOpenPawURL: { url in
                            requestedSheet = nil
                            onOpenPawURL(url)
                        }
                    ) { requestedSheet = nil }
                }
            case .manageHosts:
                NavigationStack {
                    HostListView(model: model, settings: settings)
                }
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

    // MARK: Root destination paging

    /// Window-level observation keeps child controls alive while the pure policy decides whether a completed fling
    /// belongs to the root. The bridge emits an intent only; this router remains the one owner of destination state.
    @ViewBuilder
    private var destinationSwipeLayer: some View {
        #if os(iOS)
            DestinationSwipeCatcher(
                destination: router.destination,
                isBackNavigationAvailable: router.sessionID != nil,
                isModalPresented: currentSheet != nil || model.lastError != nil,
                onIntent: { _ = pageRoot($0) }
            )
            // The window recognizer does not need a screen-sized view. Keeping its adjustable accessibility
            // element to a point-sized frame prevents it from becoming an invisible accessibility blanket over
            // every tappable row beneath it while VoiceOver can still reach it by identifier and rotor order.
            .frame(width: 1, height: 1)
            .ignoresSafeArea()
        #endif
    }

    @discardableResult
    private func pageRoot(_ decision: DestinationPageDecision) -> Bool {
        let destination = DestinationPagingPolicy.destination(after: decision, from: router.destination)
        guard destination != router.destination else { return false }
        router.destination = destination
        return true
    }

    // MARK: Hold anywhere to talk

    /// The gesture and its ring, installed once for the whole app.
    ///
    /// The catcher observes the window and consumes nothing, so every button, scroll and text field underneath
    /// keeps working while a hold is being measured. The ring is drawn above everything because it has to be
    /// visible over the terminal, a sheet, or whatever else is on screen when the user decides to talk.
    @ViewBuilder
    private var pushToTalkLayer: some View {
        #if os(iOS)
            ZStack {
                PushToTalkCatcher(
                    onBegan: {
                        // A hold is now the input method. Retire the large software keyboard immediately so the
                        // listening ring and the terminal line stay visible while the user speaks.
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        pushToTalk.touchBegan(at: $0)
                    },
                    onArmed: {
                        pushToTalk.arm()
                        // The only confirmation available to someone who is looking at their thumb, not the screen.
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    },
                    onMoved: { pushToTalk.touchMoved(to: $0) },
                    onEnded: { pushToTalk.touchEnded() },
                    onCancelled: { pushToTalk.cancel() }
                )
                .allowsHitTesting(false)
                if let ring = pushToTalk.ring {
                    TouchRing(ring)
                }
            }
            .ignoresSafeArea()
        #endif
    }

    private func configurePushToTalk() {
        // Resolve again whenever the configuration key changes. A completed model download can turn this from nil
        // into a live local engine without changing any setting.
        let engine = model.selectedDictationEngine(for: settings)
        pushToTalk.configure(
            engine: engine,
            locale: settings.dictationLocale,
            mode: settings.dictationMode,
            unavailableMessage: model.dictationUnavailableMessage(for: settings)
        )
        // Speech lands wherever the user is. Terminal text is staged as a draft rather than executed: a
        // misheard command that runs itself on a remote machine is not a bug anyone gets to make twice.
        pushToTalk.onCommit = { [weak model] text in
            guard let model else { return }
            if router.destination == .terminal, let terminal = model.terminal {
                // Put recognised text at the live shell prompt without Return. The user sees and can edit the
                // command exactly like keyboard input; speech must never execute a remote command by itself.
                Task {
                    do {
                        try await terminal.send(text: text)
                    } catch {
                        model.present(error, while: "inserting dictated text into the terminal")
                    }
                }
                return
            }
            // Appended rather than replaced: a second sentence spoken before a screen has claimed the first must
            // not silently delete it. The claimer clears the slot when it takes the words.
            if let pending = model.dictatedText, !pending.isEmpty {
                model.dictatedText = pending + " " + text
            } else {
                model.dictatedText = text
            }
        }
        pushToTalk.onFailure = { [weak model] error in
            model?.present(error, while: "listening for dictation")
        }
    }

    // MARK: Compact

    /// Content above, the Paw Orb floating bottom-trailing, and the terminal keys as the only remaining inset.
    ///
    /// The paged Control Deck strip is gone. Its three pages became: destinations — the existing root swipe plus
    /// the launcher's Tools nodes; view controls — Tools nodes routed through the same `TerminalControlBus`; and
    /// the key strip, which stays as a bottom inset on the Terminal destination only, because esc/ctrl/arrows are
    /// held down mid-command and cannot live behind a two-step launcher.
    private func tabs(width: RootWidth) -> some View {
        navigated(router.destination, width: width)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsTerminalKeyStrip { terminalKeyStrip(width: width) }
            }
            .overlay { launcherLayer }
    }

    /// The room the key strip takes from the content on the Terminal destination, and nothing anywhere else.
    private var deckInset: CGFloat { showsTerminalKeyStrip ? ControlDeck.contentHeight : 0 }

    private var showsTerminalKeyStrip: Bool {
        router.destination == .terminal && showsTerminalKeys && !isTerminalSearchPresented
    }

    /// The radial launcher overlay: radial nodes and the preview card only while a gesture is live, plus the
    /// permanently visible Orb. `allowsHitTesting` stays on because only the Orb and the card have gestures; the
    /// rest of the overlay is `ZStack` space that does not intercept touches.
    @ViewBuilder
    private var launcherLayer: some View {
        ProactiveRadialLauncherView(
            graph: launcherGraph,
            state: launcherStateBinding,
            onEffect: handleLauncherEffect
        )
        .onAppear { rebuildLauncherGraph() }
        .onChange(of: model.connectionGeneration) { _, _ in
            _ = launcherState.invalidate(.hostChanged)
            rebuildLauncherGraph()
        }
        .onChange(of: model.selectedHostID) { _, _ in
            _ = launcherState.invalidate(.hostChanged)
            rebuildLauncherGraph()
        }
        .onChange(of: router.destination) { _, _ in rebuildLauncherGraph() }
        .onChange(of: sessionSpace) { _, _ in rebuildLauncherGraph() }
        .onChange(of: model.sessions) { _, _ in rebuildLauncherGraph() }
        .onChange(of: model.inbox) { _, _ in rebuildLauncherGraph() }
        .onChange(of: model.repos) { _, _ in rebuildLauncherGraph() }
        .onChange(of: model.connection.isConnected) { _, _ in rebuildLauncherGraph() }
    }

    /// The launcher's begin taps flow through the binding, which is where dictation gives up the touch: a
    /// gesture that belongs to the Orb must never simultaneously arm the full-screen hold.
    private var launcherStateBinding: Binding<RadialLauncherState> {
        Binding(
            get: { launcherState },
            set: { newValue in
                let wasIdle = launcherState.phase == .idle
                launcherState = newValue
                if wasIdle, newValue.phase != .idle {
                    pushToTalk.cancel()
                }
            }
        )
    }

    /// The key bar, at the very bottom of the screen and scrolling sideways.
    ///
    /// The one Control Deck page that stays a permanent surface: esc, ctrl and arrows are pressed continuously
    /// while driving a terminal, and a modifier that has to be re-summoned through a launcher for every keypress
    /// is not a modifier. The launcher's Tools branch toggles it for users who want the full screen back.
    private func terminalKeyStrip(width: RootWidth) -> some View {
        ShortcutBarView(
            shortcuts: Binding(get: { settings.shortcuts }, set: { settings.shortcuts = $0 }),
            latched: $latchedModifiers,
            rows: 1,
            onChord: sendChord,
            onText: sendText
        )
        .frame(height: ControlDeck.contentHeight)
        .glassChrome(overTerminal: true, edge: .top)
        .destinationSwipeExclusion(.horizontalChildControl)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("root.terminal-keys")
    }

    private func sendChord(_ chord: KeyChord) {
        guard let terminal = model.terminal else { return }
        Task {
            do {
                try await terminal.send(chord: chord, applicationCursorKeys: settings.applicationCursorKeys)
            } catch {
                model.present(error, while: "sending a key to the terminal")
            }
        }
    }

    private func sendText(_ text: String) {
        guard let terminal = model.terminal else { return }
        Task {
            do {
                try await terminal.send(text: text)
            } catch {
                model.present(error, while: "sending text to the terminal")
            }
        }
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
                    // The root still needs its own inset because the app-wide strip belongs outside this stack.
                    // A modifier here does not follow a later push; the transcript destination repeats the same
                    // contract below so its composer cannot be covered by the strip.
                    .safeAreaPadding(.bottom, deckInset)
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
        .accessibilityIdentifier("root.destination.\(destination.rawValue)")
        .accessibilityLabel(sidebarVoiceLabel(destination))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func sidebarVoiceLabel(_ destination: ShellDestination) -> String {
        guard destination == .inbox, pendingCount > 0 else { return destination.title }
        return "\(destination.title), \(pendingCount) waiting"
    }

    private var hostChip: some View {
        HostSwitcher(
            model: model,
            onAddDevice: { requestedSheet = .addDevice },
            onManageHosts: { requestedSheet = .manageHosts },
            onConnected: { settings.recordConnection(to: $0) }
        )
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
                onOpenRepository: openHomeRepository(_:),
                onQuickConnect: openQuickConnect(_:),
                onOpenPawURL: onOpenPawURL,
                onAddDevice: { requestedSheet = .addDevice }
            )
        case .terminal:
            TerminalScreenView(
                model: model,
                settings: settings,
                scrollback: scrollback,
                controls: terminalControls,
                surface: terminalSurface,
                onFontSizeChange: { _ in },
                onAddDevice: { requestedSheet = .addDevice },
                onManageHosts: { requestedSheet = .manageHosts },
                onSearchPresentationChange: updateTerminalSearchPresentation
            )
        case .sessions:
            sessions(width: width)
        case .inbox:
            InboxView(
                model: model,
                routedItemID: Binding(
                    get: { router.inboxDetailItemID },
                    set: { router.inboxDetailItemID = $0 }
                ),
                bottomAccessoryInset: RootNavigationStyle.style(for: width) == .tabs ? deckInset : 0
            )
        case .repo:
            repo
        case .settings:
            SettingsView(model: model, settings: settings)
        }
    }

    private func updateTerminalSearchPresentation(_ isPresented: Bool) {
        guard isTerminalSearchPresented != isPresented else { return }
        isTerminalSearchPresented = isPresented
    }

    // MARK: Radial launcher

    /// Rebuilds the launcher's graph from current root state. Called on every state change the graph renders
    /// from; the builder is pure and cheap, and a stale graph is a launcher offering sessions that are gone.
    private func rebuildLauncherGraph() {
        let input = RootLauncherIntegration.graphInput(
            model: model,
            sessionSpace: sessionSpace,
            destination: router.destination,
            selectedRepositoryPath: model.selectedRepo)
        let graph = WorkspaceContextGraphBuilder().build(input)
        launcherGraph = graph.attaching(proposals: ProposalEngine().proposals(for: input))
    }

    /// The launcher's terminal: every effect the state machine emits lands here exactly once per operation ID.
    private func handleLauncherEffect(_ effect: RadialLauncherEffect) {
        switch effect {
        case .freeze, .cancel:
            break
        case .confirm(let operationID, let proposal):
            // The dispatch owns the operation now; the orb returns to idle so the preview card does not stay
            // frozen over the destination the action navigates to.
            _ = launcherState.cancel()
            executeLauncherProposal(proposal, operationID: operationID)
        case .confirmAction(let operationID, let action):
            _ = launcherState.cancel()
            performLauncherRoute(RootLauncherIntegration.route(for: action, operationID: operationID))
        }
    }

    private func performLauncherRoute(_ route: RootLauncherIntegration.ConfirmedActionRoute) {
        switch route {
        case .none:
            break
        case .navigate(let destination):
            router.destination = destination
        case .switchHost:
            requestedSheet = .manageHosts
        case .openAgentSession(let sessionID):
            model.selectedSessionID = sessionID
            router.destination = .sessions
        case .attach(let session):
            attachLauncherSession(session)
        case .focusWindow(let kind, let sessionID, let windowID):
            focusLauncherWindow(kind: kind, sessionID: sessionID, windowID: windowID)
        case .openRepository(let path):
            model.selectedRepo = model.repos.first(where: { $0.path == path })?.name ?? model.selectedRepo
            router.destination = .repo
        case .tool(let tool):
            performLauncherTool(tool)
        case .executeProposal(let proposal, let operationID):
            executeLauncherProposal(proposal, operationID: operationID)
        }
    }

    /// Attach through the same guarded path the Sessions screen uses: ownership check, restoration recording,
    /// then the coordinator, which routes to the terminal on success.
    private func attachLauncherSession(_ session: RemoteSession) {
        attachSession(session)
    }

    /// Window focus is an attach followed by a window selection inside the multiplexer. The attach itself is
    /// the part the app owns; the frozen graph's window is selected with the multiplexer's own command so the
    /// user lands looking at the window they aimed at, not whichever was last active.
    private func focusLauncherWindow(kind: MultiplexerKind, sessionID: String, windowID: String) {
        guard canUseCurrentSessionSpace() else { return }
        guard let hostID = model.selectedHostID,
              let action = SessionSpaceActionPlan.attach(
                hostID: hostID,
                session: .target(sessionID, kind: kind)) else {
            presentUnavailableSessionAction()
            return
        }
        runSessionAction(action)
        Task {
            // Give the attach a beat to land before steering the window; a select sent before the client is
            // attached is dropped by tmux without an error.
            try? await Task.sleep(for: .milliseconds(300))
            guard model.connection.isConnected, let terminal = model.terminal else { return }
            let command = Self.windowSelectionCommand(kind: kind, windowID: windowID)
            guard !command.isEmpty else { return }
            try? await terminal.send(text: command)
        }
    }

    static func windowSelectionCommand(kind: MultiplexerKind, windowID: String) -> String {
        switch kind {
        case .tmux: "tmux select-window -t '\(windowID)'\n"
        case .zellij: "zellij action go-to-tab-name '\(windowID)'\n"
        case .screen, .herdr: ""
        }
    }

    /// Tools raise the same signals the Control Deck buttons used to. Terminal-scoped tools also navigate to
    /// the terminal first: a "search scrollback" confirmed from the Sessions screen that silently signals a bus
    /// nobody is listening to would be a launcher that does nothing.
    private func performLauncherTool(_ tool: WorkspaceToolAction) {
        switch tool {
        case .navigate(let destination):
            router.destination = RootLauncherIntegration.shellDestination(for: destination)
        case .terminalKeys:
            router.destination = .terminal
            showsTerminalKeys.toggle()
        case .dictate:
            router.destination = .terminal
            terminalControls.dictate()
        case .search:
            router.destination = .terminal
            terminalControls.search()
        case .copyAll:
            router.destination = .terminal
            terminalControls.copyAll()
        case .fontSmaller:
            settings.terminalFontSize = OpenPawSettings.clamp(fontSize: settings.terminalFontSize - 1)
        case .fontLarger:
            settings.terminalFontSize = OpenPawSettings.clamp(fontSize: settings.terminalFontSize + 1)
        }
    }

    /// Proposals run through the execution coordinator, whose ownership checks are pinned to the frozen graph
    /// that offered the proposal. A world that moved since the freeze downgrades to reconnect-needed, never a
    /// command in the wrong pane.
    private func executeLauncherProposal(_ proposal: ProactiveProposal, operationID: UUID) {
        // Navigation and tool proposals are app-side: no terminal dispatch, so no coordinator.
        switch proposal.payload {
        case .navigate(let target):
            if let destination = target.destination {
                router.destination = RootLauncherIntegration.shellDestination(for: destination)
            }
            return
        case .tool(let tool):
            performLauncherTool(tool)
            return
        case .agentMessage, .terminalCommand:
            break
        }
        guard let hostID = model.selectedHostID, let terminal = model.terminal else { return }
        let graph = launcherGraph
        let coordinator = ProposalExecutionCoordinator(
            expectedHostID: hostID,
            expectedGeneration: model.connectionGeneration,
            expectedGraphSnapshotID: graph.snapshotID,
            context: { [weak model] in
                guard let model else {
                    return ProposalExecutionContext(
                        hostID: nil, connectionGeneration: -1, graphSnapshotID: graph.snapshotID,
                        selectedSessionID: nil, selectedTabID: nil, isConnected: false)
                }
                return RootLauncherIntegration.executionContext(
                    model: model, graph: graph, target: proposal.target)
            },
            executor: sessionCommandExecutor,
            terminal: terminal)
        Task {
            let phase = await coordinator.execute(proposal, operationID: operationID.uuidString)
            switch phase {
            case .completed:
                router.destination = .terminal
            case .reconnectNeeded:
                model.lastError = PresentedError(
                    title: "Action expired",
                    detail: "The connection changed since this suggestion was made. Reconnect and try again.",
                    isRecoverable: true)
            case .failed(_, let message):
                model.lastError = PresentedError(
                    title: "Suggestion failed", detail: message, isRecoverable: true)
            case .routing, .executing:
                break
            }
        }
    }

    private func openHomeDevice(_ host: HostRecord, intent: WorkspaceResumeIntent) {
        Task {
            guard let resolution = await HomeResumeCoordinator.resolve(
                host: host,
                intent: intent,
                model: model),
                model.ownsConnection(resolution.connection) else { return }
            settings.recordConnection(to: host.id)
            routeHomeIntent(resolution.intent)
        }
    }

    private func routeHomeIntent(_ intent: WorkspaceResumeIntent) {
        router.perform(.resumeWorkspace(intent), model: model)
        if case .agentSession(let sessionID) = intent {
            model.startFollowing(session: sessionID)
        }
    }

    private func openHomeAgent(_ sessionID: String) {
        router.perform(.openSessionTranscript(sessionID), model: model)
        model.startFollowing(session: sessionID)
    }

    private func openHomeRepository(_ repo: String) {
        router.perform(.resumeWorkspace(.repository(repo)), model: model)
    }

    @ViewBuilder
    private func sessions(width: RootWidth) -> some View {
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
                .navigationDestination(item: sessionBinding) { sessionID in
                    transcript(sessionID)
                        // SwiftUI does not inherit the list's safe-area padding across a NavigationStack push.
                        // Without this explicit edge the composer sits under the app-wide deck, so a tap meant
                        // for its microphone activates the Terminal destination underneath instead of voice.
                        .safeAreaPadding(.bottom, deckInset)
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

    private func runSessionAction(_ action: SessionSpaceActionPlan) {
        do {
            _ = try action.command.rendered()
        } catch {
            model.lastError = PresentedError(
                title: "Session command rejected",
                detail: "The session identifier is invalid. Refresh sessions and try again.",
                isRecoverable: true)
            return
        }
        guard let hostID = model.selectedHostID else { return }
        let generation = model.connectionGeneration
        Task {
            do {
                let intent = try await SessionSpaceActionCoordinator.run(
                    action,
                    expectedHostID: hostID,
                    expectedGeneration: generation,
                    context: {
                        SessionSpaceActionContext(
                            snapshot: sessionSpace,
                            hostID: model.selectedHostID,
                            connectionGeneration: model.connectionGeneration,
                            isConnected: model.connection.isConnected)
                    },
                    executor: sessionCommandExecutor,
                    restorationStore: restorationStore,
                    refresh: refreshSessionSpace)
                guard let intent,
                      model.selectedHostID == hostID,
                      model.connectionGeneration == generation,
                      model.connection.isConnected else { return }
                router.perform(intent, model: model)
            } catch {
                guard model.selectedHostID == hostID,
                      model.connectionGeneration == generation,
                      model.connection.isConnected else { return }
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
        guard let hostID = model.selectedHostID,
              let action = SessionSpaceActionPlan.attach(hostID: hostID, session: session) else {
            presentUnavailableSessionAction()
            return
        }
        runSessionAction(action)
    }

    private func createSession(_ name: String) {
        guard canUseCurrentSessionSpace() else { return }
        guard let hostID = model.selectedHostID,
              let action = SessionSpaceActionPlan.create(
                hostID: hostID,
                kind: sessionSpace.multiplexerForNewSessions,
                name: name) else {
            presentUnavailableSessionAction()
            return
        }
        runSessionAction(action)
    }

    private func renameSession(_ session: RemoteSession, to name: String) {
        guard canUseCurrentSessionSpace() else { return }
        guard session.isAlive else { presentUnavailableSessionAction(); return }
        runSessionAction(.rename(session: session, to: name))
    }

    private func killSession(_ session: RemoteSession) {
        guard canUseCurrentSessionSpace() else { return }
        runSessionAction(.kill(session: session))
    }

    private func restoreSession(_ plan: SessionRestorationPlan) {
        guard plan.hostID == model.selectedHostID,
              sessionSpace.hostID == model.selectedHostID,
              sessionSpace.connectionGeneration == model.connectionGeneration,
              canUseCurrentSessionSpace() else { return }
        guard let action = SessionSpaceActionPlan.restore(
            plan,
            remoteSessions: sessionSpace.remoteSessions) else {
            presentUnavailableSessionAction()
            return
        }
        runSessionAction(action)
    }

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
        case quickConnect
        case approval(InboxItem)
        case addDevice
        case manageHosts

        var id: String {
            switch self {
            case .hostKey(let prompt): "host-key-\(prompt.id)"
            case .quickConnect: "quick-connect"
            case .approval(let item): "approval-\(item.id.rawValue)"
            case .addDevice: "add-device"
            case .manageHosts: "manage-hosts"
            }
        }
    }

    /// A host key block always outranks an approval. The key decision is about whether you are talking to your own
    /// machine at all, which makes every other decision on screen meaningless until it is settled.
    private var currentSheet: ShellSheet? {
        let approval = router.approvalItemID.flatMap { id in
            model.inbox.first(where: { $0.id.rawValue == id })
        }
        switch RootSheetPolicy.resolve(
            hostKey: model.hostKeyPrompt != nil,
            quickConnect: quickConnectIsActive,
            approval: approval != nil,
            requested: requestedSheet) {
        case .hostKey:
            return model.hostKeyPrompt.map(ShellSheet.hostKey)
        case .quickConnect:
            return .quickConnect
        case .approval:
            return approval.map(ShellSheet.approval)
        case .addDevice:
            return .addDevice
        case .manageHosts:
            return .manageHosts
        case nil:
            return nil
        }
    }

    private var sheetBinding: Binding<ShellSheet?> {
        Binding(
            get: { currentSheet },
            set: { newValue in
                guard newValue == nil else { return }
                switch currentSheet {
                case .hostKey:
                    model.hostKeyPrompt = nil
                case .quickConnect:
                    routeQuickConnectIfOwned(quickConnectCoordinator.stage)
                    quickConnectCoordinator.cancel()
                case .approval:
                    router.approvalItemID = nil
                    router.approvalRoute = nil
                case .addDevice, .manageHosts:
                    requestedSheet = nil
                case nil:
                    break
                }
            }
        )
    }

    private var quickConnectIsActive: Bool {
        guard quickConnectCoordinator.proposal != nil else { return false }
        return switch quickConnectCoordinator.stage {
        case .idle, .cancelled: false
        default: true
        }
    }

    private func routeQuickConnectIfOwned(_ stage: QuickConnectCoordinator.Stage) {
        let ownsTerminalLease = quickConnectCoordinator.terminalRouteIntent.map(model.ownsConnection) ?? false
        if let destination = RootQuickConnectRouting.destination(
            for: stage,
            ownsTerminalLease: ownsTerminalLease) {
            router.destination = destination
            quickConnectCoordinator.cancel()
        }
    }

    func trust(_ prompt: HostKeyPrompt) {
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
            persistHostStore(model.hostStore)
            model.hostKeyPrompt = nil
            if case .awaitingHostTrust = quickConnectCoordinator.stage {
                quickConnectCoordinator.resumeAfterHostTrust()
            } else {
                Task { await model.connectSelectedHost() }
            }
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

    private var sessionBinding: Binding<String?> {
        Binding(get: { router.sessionID }, set: { router.sessionID = $0 })
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.lastError != nil && currentSheet == nil },
            set: { if !$0 { model.lastError = nil } })
    }

    private func selectSession(_ session: SessionSummary) {
        router.perform(.openSessionTranscript(session.sessionID), model: model)
        model.startFollowing(session: session.sessionID)
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
