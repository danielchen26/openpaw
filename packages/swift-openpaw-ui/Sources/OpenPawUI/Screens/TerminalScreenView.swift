import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

// MARK: - Connection presentation

/// How a `ConnectionState` reads on screen: a word, a colour, a glyph and — when the transport is retrying — the
/// explanation of what it is doing, because "reconnecting" with no reason is the most useless status in software.
public struct ConnectionPresentation: Sendable, Hashable {
    public let label: String
    public let detail: String?
    public let tone: Color
    public let glyph: String

    public init(label: String, detail: String?, tone: Color, glyph: String) {
        self.label = label
        self.detail = detail
        self.tone = tone
        self.glyph = glyph
    }

    public static func make(_ state: ConnectionState) -> ConnectionPresentation {
        switch state {
        case .idle:
            ConnectionPresentation(label: "idle", detail: nil, tone: OpenPawTheme.textTertiary, glyph: "circle")
        case .resolving:
            ConnectionPresentation(
                label: "resolving", detail: "Looking up the address.", tone: OpenPawTheme.textSecondary,
                glyph: "circle.dotted")
        case .connecting:
            ConnectionPresentation(
                label: "connecting", detail: "Opening the channel.", tone: OpenPawTheme.textSecondary,
                glyph: "circle.dotted")
        case .authenticating:
            ConnectionPresentation(
                label: "authenticating", detail: "Proving who you are.", tone: OpenPawTheme.textSecondary,
                glyph: "circle.dotted")
        case .connected:
            ConnectionPresentation(label: "connected", detail: nil, tone: OpenPawTheme.ok, glyph: "circle.fill")
        case .reconnecting(let attempt, let reason):
            ConnectionPresentation(
                label: "reconnecting",
                // The fallback explanation: what dropped, and which attempt this is.
                detail: "Attempt \(attempt). \(reason)",
                tone: OpenPawTheme.warn,
                glyph: "arrow.triangle.2.circlepath")
        case .disconnected(let reason):
            ConnectionPresentation(
                label: "disconnected", detail: reason, tone: OpenPawTheme.textTertiary, glyph: "circle")
        case .failed(let error):
            ConnectionPresentation(
                label: "failed", detail: Self.failureDetail(error), tone: OpenPawTheme.bad,
                glyph: "xmark.circle.fill")
        }
    }

    private static func failureDetail(_ error: TransportError) -> String {
        error.allowsTransportFallback
            ? "\(error.description). OpenPaw will try the next transport."
            : error.description
    }

    /// The transport that actually carried the session, when there is one. Shown beside the state rather than
    /// buried: "connected over Mosh" and "connected over SSH" behave differently when the link drops.
    public static func transportLabel(_ state: ConnectionState) -> String? {
        if case .connected(let kind) = state { return kind.displayName }
        return nil
    }
}

// MARK: - Terminal screen

/// The chrome around the terminal surface.
///
/// The surface itself is injected: the app hands in its SwiftTerm-backed view, and a headless snapshot hands in
/// `ScrollbackTextView`. Everything else on this screen — header, keys, dictation, search, cell size — is written
/// once here and behaves identically for both.
@MainActor
public struct TerminalScreenView: View {
    private let model: OpenPawModel
    private let settings: OpenPawSettings
    private let scrollback: ScrollbackStore
    private let controls: TerminalControlBus
    private let surface: () -> AnyView
    private let onFontSizeChange: (CGFloat) -> Void

    @State private var latched: KeyModifiers = []
    @State private var isSearching = false
    @State private var query = ""
    @State private var matches: [ScrollbackMatch] = []
    @State private var focused: ScrollbackMatch?
    @State private var lineCount = 0
    @State private var pinchBase: CGFloat?
    @State private var voice = VoiceComposition(destination: .terminal)
    @State private var dictationTask: Task<Void, Never>?
    @State private var dictationTranscription: DictationTranscription?
    @State private var dictationTurnID: VoiceTurnID?

    public init(
        model: OpenPawModel,
        settings: OpenPawSettings,
        scrollback: ScrollbackStore,
        controls: TerminalControlBus = TerminalControlBus(),
        surface: @escaping () -> AnyView,
        onFontSizeChange: @escaping (CGFloat) -> Void
    ) {
        self.model = model
        self.settings = settings
        self.scrollback = scrollback
        self.controls = controls
        self.surface = surface
        self.onFontSizeChange = onFontSizeChange
    }

    public var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                terminal
                footer
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // The header floats on the scrollback rather than sitting in the stack above it. Stacked, it would
            // be a solid bar with nothing behind it, and the glass would be blurring a flat colour.
            .safeAreaInset(edge: .top, spacing: 0) { header }
        }
        .background(OpenPawTheme.ink)
        .overlay {
            if isSearching {
                search
            }
        }
        .onDisappear(perform: cancelDictation)
        .onChange(of: model.dictatedText) { _, text in claimDictatedText(text) }
        // Also on appear, not only on change: a sentence spoken on another screen is waiting to be claimed by
        // whichever screen can hold a draft, and arriving here is the moment this one can.
        .onAppear {
            claimDictatedText(model.dictatedText)
            // The strip at the bottom of the app owns these buttons now, but the state they act on is here.
            controls.onDictate = { toggleDictation() }
            controls.onSearch = { isSearching = true }
            controls.onCopyAll = { Task { await copyAllOutput() } }
        }
        // Released on the way out so a tap on the strip from another screen does not reach a terminal the user is
        // no longer looking at.
        .onDisappear { controls.release() }
        // The strip draws the microphone, so it has to be told what the microphone is doing.
        .onChange(of: voice.isActive) { _, isActive in controls.report(isDictating: isActive) }
    }

    // MARK: Header

    private var header: some View {
        let status = ConnectionPresentation.make(model.connection)
        let host = model.selectedHost?.nickname
        return VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                Image(systemName: host == nil ? "circle.dashed" : status.glyph)
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(host == nil ? OpenPawTheme.textTertiary : status.tone)
                    .accessibilityHidden(true)
                Text(host ?? "No host")
                    .font(OpenPawTheme.Machine.headline)
                    .foregroundStyle(host == nil ? OpenPawTheme.textSecondary : OpenPawTheme.textPrimary)
                // With no host there is nothing a connection state could be true about, so it is not claimed.
                // A header must never state two things that cannot both hold.
                if host != nil {
                    Text(status.label).microLabel(status.tone)
                    if let transport = ConnectionPresentation.transportLabel(model.connection) {
                        Text(transport).microLabel()
                    }
                } else {
                    Text("add one in settings").microLabel()
                }
                Spacer(minLength: OpenPawTheme.Space.small)
                connectionButton
            }
            if host != nil, let detail = status.detail {
                Text(detail)
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, OpenPawTheme.Space.medium)
        .padding(.vertical, OpenPawTheme.Space.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Glass, like the strip at the other end of the screen. Scrollback passing under the header is what says
        // the terminal is a continuous surface the chrome floats on rather than a pane boxed in by two bars.
        .glassChrome(overTerminal: true, edge: .bottom)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headerVoiceLabel(status))
    }

    private func headerVoiceLabel(_ status: ConnectionPresentation) -> String {
        guard let host = model.selectedHost?.nickname else { return "No host selected" }
        guard let detail = status.detail else { return "\(host), \(status.label)" }
        return "\(host), \(status.label). \(detail)"
    }

    @ViewBuilder
    private var connectionButton: some View {
        if model.connection.isConnected {
            Button("Disconnect") { Task { await model.disconnect() } }
                .buttonStyle(.plain)
                .font(OpenPawTheme.Machine.label)
                .frame(minHeight: 44)
                .foregroundStyle(OpenPawTheme.textSecondary)
        } else {
            Button("Connect") { Task { await connect() } }
                .buttonStyle(.plain)
                .font(OpenPawTheme.Machine.label)
                .frame(minHeight: 44)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .disabled(model.selectedHost == nil)
        }
    }

    private func connect() async {
        await model.connectSelectedHost()
        if model.connection.isConnected, let id = model.selectedHostID {
            settings.recordConnection(to: id)
        }
    }

    // MARK: Terminal

    private var terminal: some View {
        surface()
            // Terminals grow from the bottom: new output arrives at the bottom edge and history scrolls up off
            // the top. Filling the height without an anchor centres a short session in the middle of the pane.
            //
            // `.bottomLeading` on both, never `.bottom`: `UnitPoint.bottom` is x 0.5, so it would centre the
            // columns horizontally and break every aligned thing a terminal prints — tables, diffs, tree output.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .defaultScrollAnchor(.bottomLeading)
            .background(settings.terminalTheme.background)
            .contentShape(Rectangle())
            // Pinch reports through the injected closure; this view never resizes the PTY itself.
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let base = pinchBase ?? settings.terminalFontSize
                        if pinchBase == nil { pinchBase = base }
                        apply(fontSize: base * value.magnification)
                    }
                    .onEnded { _ in pinchBase = nil }
            )
            // No long press here. Holding the terminal means "talk to it": that gesture is what the app is built
            // around, and any menu that answers a hold first takes it away. Select and copy moved to the rail's
            // search control, which reaches the same scrollback. See `PushToTalk.reservedForSpeech`.
            .overlay {
                #if os(iOS)
                    // Two-finger tap toggles the key bar. The recognizer lives on the window and passes touches
                    // through, so typing and scrolling are untouched.
                    TwoFingerTapCatcher { settings.isShortcutBarVisible.toggle() }
                        .allowsHitTesting(false)
                #endif
            }
    }

    /// Speech from the hold-anywhere gesture lands in the terminal draft rather than being executed.
    ///
    /// The user is holding a screen, not confirming a command, and a misheard `rm` that ran itself would be
    /// unrecoverable. Staging it keeps the confirmation the Execute button already provides.
    private func claimDictatedText(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        voice.draft = voice.draft.isEmpty ? text : voice.draft + " " + text
        model.dictatedText = nil
    }

    // MARK: Footer

    /// All that is left at the bottom of this screen: the dictation draft, when there is one.
    ///
    /// The key bar and the control rail moved to the app-wide strip below. Three stacked rows was the defect —
    /// this screen owned two of them and the shell owned the third, so nothing was in a position to see that
    /// together they took a fifth of the screen.
    @ViewBuilder
    private var footer: some View {
        if voice.isActive || !voice.draft.isEmpty {
            dictationDraftRow
        }
    }

    private var dictationDraftRow: some View {
        let presentation = TerminalDictationDraftPresentation.make(draft: voice.draft, isDictating: voice.isActive)
        return HStack(spacing: OpenPawTheme.Space.small) {
            Text("draft").microLabel()
            TextField("Speak, then execute", text: $voice.draft)
                .font(OpenPawTheme.Machine.body)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .textFieldStyle(.plain)
                .disabled(!presentation.isTextFieldEnabled)
            Button("Execute") {
                executeTerminalDraft()
            }
            .buttonStyle(.plain)
            .font(OpenPawTheme.Machine.label)
            .frame(minHeight: 44)
            .foregroundStyle(OpenPawTheme.textPrimary)
            .disabled(!presentation.isExecuteEnabled)
        }
        .padding(.horizontal, OpenPawTheme.Space.medium)
        .padding(.vertical, OpenPawTheme.Space.tight)
        // Speech is something a person said, so the draft strip sits on the warm surface.
        .background(OpenPawTheme.panelWarm)
    }

    // MARK: Search

    private var search: some View {
        VStack(spacing: 0) {
            searchBar
            ScrollbackTextView(
                store: scrollback, matches: matches, focused: focused, showsLineNumbers: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OpenPawTheme.well)
        }
        .background(OpenPawTheme.ink)
        .task(id: query) { await runSearch() }
    }

    private var searchBar: some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(OpenPawTheme.textTertiary)
                .accessibilityHidden(true)
            TextField("Find in scrollback", text: $query)
                .font(OpenPawTheme.Machine.body)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            Text(matchSummary).microLabel()
            Button {
                focused = ScrollbackMatchIndex(matches).previous(before: focused)
            } label: {
                Image(systemName: "chevron.up").frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(matches.isEmpty)
            .accessibilityLabel("Previous match")
            Button {
                focused = ScrollbackMatchIndex(matches).next(after: focused)
            } label: {
                Image(systemName: "chevron.down").frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(matches.isEmpty)
            .accessibilityLabel("Next match")
            Button("Done") {
                isSearching = false
                query = ""
                matches = []
                focused = nil
            }
            .buttonStyle(.plain)
            .font(OpenPawTheme.Machine.label)
            .frame(minHeight: 44)
            .foregroundStyle(OpenPawTheme.textPrimary)
        }
        .foregroundStyle(OpenPawTheme.textSecondary)
        .padding(.horizontal, OpenPawTheme.Space.medium)
        .padding(.vertical, OpenPawTheme.Space.small)
        .background(OpenPawTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(OpenPawTheme.line).frame(height: OpenPawTheme.hairline)
        }
    }

    private var matchSummary: String {
        guard !query.isEmpty else { return "\(lineCount) lines" }
        guard !matches.isEmpty else { return "no matches" }
        let index = ScrollbackMatchIndex(matches)
        guard let focused, let ordinal = index.ordinal(of: focused) else { return "\(matches.count) matches" }
        return "\(ordinal) of \(matches.count)"
    }

    private func runSearch() async {
        lineCount = await scrollback.lineCount
        guard !query.isEmpty else {
            matches = []
            focused = nil
            return
        }
        let found = await scrollback.search(query)
        matches = found
        focused = found.first
    }

    private func copyAllOutput() async {
        let data = await scrollback.export()
        OpenPawClipboard.copy(String(decoding: data, as: UTF8.self))
    }

    // MARK: Sending

    private var shortcutsBinding: Binding<ShortcutSet> {
        Binding(get: { settings.shortcuts }, set: { settings.shortcuts = $0 })
    }

    private func send(chord: KeyChord) {
        guard let terminal = model.terminal else { return }
        Task {
            do {
                try await terminal.send(chord: chord, applicationCursorKeys: settings.applicationCursorKeys)
            } catch {
                model.present(error, while: "sending a key to the terminal")
            }
        }
    }

    private func send(text: String) {
        guard let terminal = model.terminal else { return }
        Task {
            do {
                try await terminal.send(text: text)
            } catch {
                model.present(error, while: "sending text to the terminal")
            }
        }
    }

    private func executeTerminalDraft() {
        guard let terminal = model.terminal, let action = voice.commit(), let text = action.terminalTextToSend else { return }
        stopDictation()
        Task {
            do {
                try await terminal.send(text: text)
                voice.clearAfterSuccessfulCommit()
            } catch {
                model.present(error, while: "executing a terminal draft")
            }
        }
    }

    private func apply(fontSize: CGFloat) {
        let clamped = min(
            max(fontSize.rounded(), OpenPawSettings.fontSizeRange.lowerBound),
            OpenPawSettings.fontSizeRange.upperBound)
        guard clamped != settings.terminalFontSize else { return }
        settings.terminalFontSize = clamped
        onFontSizeChange(clamped)
    }

    // MARK: Dictation

    private func toggleDictation() {
        voice.isActive ? stopDictation() : startDictation()
    }

    private func startDictation() {
        guard let engine = model.dictation, engine.isAvailable else { return }
        let mode = VoiceDestination.terminal.dictationMode
        let locale = settings.dictationLocale
        let turnID = voice.start()
        let transcription = engine.transcribe(locale: locale, mode: mode)
        dictationTurnID = turnID
        dictationTranscription = transcription
        dictationTask = Task {
            do {
                for try await update in transcription.updates {
                    guard dictationTurnID == turnID else { return }
                    voice.apply(update, turn: turnID)
                }
            } catch is CancellationError {
                // Stopping is not a failure.
            } catch {
                guard dictationTurnID == turnID else { return }
                model.present(error, while: "listening for dictation")
            }
            guard dictationTurnID == turnID else { return }
            voice.stop()
        }
    }

    private func stopDictation() {
        let engine = model.dictation
        voice.stop()
        let task = dictationTask
        dictationTask = nil
        let transcription = dictationTranscription
        dictationTranscription = nil
        let timeout: Duration = engine?.deliversFinalAfterStop == true ? .seconds(20) : .seconds(2)
        Task {
            await transcription?.stopAndWait(for: task, timeout: timeout)
        }
    }

    private func cancelDictation() {
        voice.cancel()
        dictationTurnID = nil
        let task = dictationTask
        dictationTask = nil
        let transcription = dictationTranscription
        dictationTranscription = nil
        task?.cancel()
        Task {
            await transcription?.stop()
        }
    }
}

// MARK: - Two finger tap

#if os(iOS)

    /// Installs a two-finger tap recognizer on the enclosing window.
    ///
    /// It has to be the window rather than an overlay view: an overlay that accepts touches would swallow the
    /// terminal's own scrolling and text input, and a view whose `hitTest` returns nil never receives the touches
    /// its own recognizer needs. On the window the recognizer observes without consuming.
    struct TwoFingerTapCatcher: UIViewRepresentable {
        let action: () -> Void

        func makeUIView(context: Context) -> UIView {
            let view = WindowGestureHost()
            view.isUserInteractionEnabled = false
            view.coordinator = context.coordinator
            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {
            context.coordinator.action = action
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(action: action)
        }

        static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
            coordinator.detach()
        }

        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            var action: () -> Void
            private var recognizer: UITapGestureRecognizer?
            private weak var installedOn: UIWindow?

            init(action: @escaping () -> Void) {
                self.action = action
            }

            func attach(to window: UIWindow) {
                guard installedOn !== window else { return }
                detach()
                let tap = UITapGestureRecognizer(target: self, action: #selector(fire))
                tap.numberOfTouchesRequired = 2
                tap.numberOfTapsRequired = 1
                tap.cancelsTouchesInView = false
                tap.delaysTouchesBegan = false
                tap.delaysTouchesEnded = false
                tap.delegate = self
                window.addGestureRecognizer(tap)
                recognizer = tap
                installedOn = window
            }

            func detach() {
                if let recognizer, let installedOn {
                    installedOn.removeGestureRecognizer(recognizer)
                }
                recognizer = nil
                installedOn = nil
            }

            @objc private func fire() {
                action()
            }

            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
            ) -> Bool {
                true
            }
        }

        private final class WindowGestureHost: UIView {
            weak var coordinator: Coordinator?

            override func didMoveToWindow() {
                super.didMoveToWindow()
                if let window {
                    coordinator?.attach(to: window)
                } else {
                    coordinator?.detach()
                }
            }
        }
    }

#endif

#Preview("Terminal") {
    let model = PreviewBackend.model(.populated)
    let store = ScrollbackStore()
    TerminalScreenView(
        model: model,
        settings: OpenPawSettings.preview(),
        scrollback: store,
        surface: { AnyView(ScrollbackTextView(store: store)) },
        onFontSizeChange: { _ in }
    )
    .preferredColorScheme(.dark)
}

#Preview("Terminal, disconnected") {
    let model = PreviewBackend.model(.disconnected)
    let store = ScrollbackStore()
    TerminalScreenView(
        model: model,
        settings: OpenPawSettings.preview(),
        scrollback: store,
        surface: { AnyView(ScrollbackTextView(store: store)) },
        onFontSizeChange: { _ in }
    )
    .preferredColorScheme(.dark)
}
