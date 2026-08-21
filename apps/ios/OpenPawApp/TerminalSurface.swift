import OpenPawTerminalCore
import OpenPawUI
import SwiftTerm
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The live PTY, bridged into SwiftUI.
///
/// Everything the user types, pastes, dictates or taps on the shortcut bar leaves through exactly one funnel —
/// `Coordinator.transmit` — so there is a single place where composition state, bracketed paste and the connection
/// are consulted. Bytes arriving from the host take the mirror-image path: one `AsyncStream` pump into
/// `TerminalView.feed(byteArray:)`.
struct TerminalSurface: UIViewRepresentable {

    let backend: any TerminalBackend
    /// Point size, owned by the caller so pinch zoom survives a session switch.
    @Binding var fontSize: CGFloat
    /// An OSC 8 hyperlink the user tapped. The app decides whether to open it, because a link in agent output is
    /// attacker-controlled text.
    var onOpenLink: (URL) -> Void = { _ in }
    /// An image on the clipboard when the user pasted. A terminal cannot accept pixels, but a prompt can.
    var onPasteImage: (UIImage) -> Void = { _ in }
    /// The window title the remote side set, usually the running command.
    var onChangeTitle: (String) -> Void = { _ in }
    /// The remote working directory from OSC 7, used to open the right repository.
    var onChangeDirectory: (String) -> Void = { _ in }

    static let minimumFontSize: CGFloat = 8
    static let maximumFontSize: CGFloat = 28
    static let defaultFontSize: CGFloat = 13

    func makeCoordinator() -> Coordinator {
        Coordinator(backend: backend, onChangeFontSize: { size in fontSize = size })
    }

    func makeUIView(context: Context) -> OpenPawTerminalView {
        let view = OpenPawTerminalView(frame: CGRect(x: 0, y: 0, width: 480, height: 640))
        view.coordinator = context.coordinator
        view.terminalDelegate = context.coordinator
        view.applyOpenPawPalette()
        view.configureTextInput()
        view.installPinchZoom()
        view.apply(fontSize: fontSize)
        context.coordinator.apply(callbacks: self)
        context.coordinator.attach(view: view)
        return view
    }

    func updateUIView(_ view: OpenPawTerminalView, context: Context) {
        context.coordinator.apply(callbacks: self)
        if abs(view.font.pointSize - fontSize) > 0.01 {
            view.apply(fontSize: fontSize)
        }
    }

    static func dismantleUIView(_ view: OpenPawTerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    /// `@preconcurrency` on the conformance: `TerminalViewDelegate` comes from a module built in Swift 5 language
    /// mode, so its requirements carry no isolation, while every one of them is in practice called from UIKit on the
    /// main thread. The attribute lets the main-actor witnesses satisfy them with a dynamic check instead of forcing
    /// a `MainActor.assumeIsolated` wrapper around eleven one-line methods.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {

        private let backend: any TerminalBackend
        private let onChangeFontSize: (CGFloat) -> Void

        private var onOpenLink: (URL) -> Void = { _ in }
        private var onPasteImage: (UIImage) -> Void = { _ in }
        private var onChangeTitle: (String) -> Void = { _ in }
        private var onChangeDirectory: (String) -> Void = { _ in }

        private weak var view: OpenPawTerminalView?
        private var pump: Task<Void, Never>?
        private var lastReportedSize: PTYSize?

        /// The app's own record of input-method state.
        ///
        /// ## Why this exists even though SwiftTerm already gets it right
        ///
        /// SwiftTerm's `UITextInput` conformance is correct on the point that matters: `setMarkedText` only updates
        /// its local text-input storage, and bytes are transmitted from `commitTextInput`, which runs on
        /// `insertText` and on the `unmarkText` commit path. Provisional Pinyin therefore never reaches `send`.
        ///
        /// What SwiftTerm cannot know about is the other ways *this app* originates input: the shortcut bar,
        /// dictation in `.terminal` mode, paste, and programmatic sends from a screen. Any of those can fire while
        /// an input method has text marked, and injecting bytes into the middle of a composition is the same bug
        /// wearing a different hat — the remote line editor receives `\t` or `\u{3}` between a half-typed candidate
        /// and its commit, the keyboard silently cancels the composition, and the marked characters are lost with no
        /// record anywhere.
        ///
        /// So the funnel commits first. `transmit` asks the composer whether a composition is open; if it is, the
        /// composition is committed — which is what the user's own next keystroke would have done — and only then
        /// are the app's bytes appended. The order is always composed text, then the app's bytes. Never interleaved,
        /// and never the raw romanisation.
        private var composer = MarkedTextComposer()

        init(backend: any TerminalBackend, onChangeFontSize: @escaping (CGFloat) -> Void) {
            self.backend = backend
            self.onChangeFontSize = onChangeFontSize
            super.init()
        }

        func apply(callbacks surface: TerminalSurface) {
            onOpenLink = surface.onOpenLink
            onPasteImage = surface.onPasteImage
            onChangeTitle = surface.onChangeTitle
            onChangeDirectory = surface.onChangeDirectory
        }

        func attach(view: OpenPawTerminalView) {
            self.view = view
            pump?.cancel()
            let stream = backend.outputStream
            pump = Task { @MainActor [weak self] in
                for await chunk in stream {
                    guard let view = self?.view else { return }
                    // One copy per host chunk, not per byte: `feed` wants a byte slice and `Data` is already
                    // contiguous, so this is the cheapest bridge available.
                    view.feed(byteArray: [UInt8](chunk)[...])
                }
            }
        }

        func detach() {
            pump?.cancel()
            pump = nil
            composer.abandon()
            view = nil
        }

        // MARK: The single outbound funnel

        /// Sends text, committing any in-flight composition first. See the note on `composer`.
        func transmit(_ text: String) {
            guard !text.isEmpty else { return }
            var payload = ""
            if case .send(let composed) = composer.unmarkText() {
                payload += composed
            }
            payload += text
            let backend = backend
            Task { try? await backend.send(text: payload) }
        }

        /// Sends a chord built by the caller. Chord *encoding* belongs to the transport, which knows whether the
        /// remote application asked for application cursor keys, so this only decides ordering against composition.
        func transmit(chord: KeyChord) {
            let applicationCursorKeys = view?.getTerminal().applicationCursor ?? false
            let backend = backend
            if case .send(let composed) = composer.unmarkText() {
                Task { try? await backend.send(text: composed) }
            }
            Task { try? await backend.send(chord: chord, applicationCursorKeys: applicationCursorKeys) }
        }

        /// Bracketed paste. The wrapper tells the remote line editor that the run is pasted text rather than typed
        /// keystrokes, which is what stops a pasted trailing newline from executing a half-read command and what
        /// keeps a pasted block out of history expansion. When the remote side has not enabled the mode, sending the
        /// wrapper anyway would print `[200~` into the buffer, so it is conditional.
        func paste(_ text: String) {
            guard let terminal = view?.getTerminal(), terminal.bracketedPasteMode else {
                transmit(text)
                return
            }
            transmit("\u{1B}[200~" + text + "\u{1B}[201~")
        }

        func pasteboardContents() {
            let pasteboard = UIPasteboard.general
            // Images first: a screenshot on the clipboard is the most common thing pasted into this app, and
            // pasting its description into a shell would be absurd.
            if pasteboard.hasImages, let image = pasteboard.image {
                onPasteImage(image)
                return
            }
            if let text = pasteboard.string, !text.isEmpty {
                paste(text)
            }
        }

        func changeFontSize(to size: CGFloat) {
            let clamped = min(max(size, TerminalSurface.minimumFontSize), TerminalSurface.maximumFontSize)
            view?.apply(fontSize: clamped)
            onChangeFontSize(clamped)
        }

        // MARK: TerminalViewDelegate

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            report(columns: newCols, rows: newRows)
        }

        /// Called by the view after layout, because a rotation or the keyboard appearing changes the cell grid
        /// without the remote side asking for anything.
        func geometryChanged(columns: Int, rows: Int) {
            report(columns: columns, rows: rows)
        }

        private func report(columns: Int, rows: Int) {
            let size = PTYSize(columns: columns, rows: rows)
            guard size != lastReportedSize else { return }
            lastReportedSize = size
            let backend = backend
            Task { try? await backend.resize(columns: size.columns, rows: size.rows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            onChangeTitle(title)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard let directory, !directory.isEmpty else { return }
            onChangeDirectory(directory)
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Everything SwiftTerm decided to transmit arrives here: typed characters, committed compositions, the
            // hardware chords it encodes itself in `pressesBegan`, and its own paste path. A chord is not valid
            // UTF-8 text on its own, so decode permissively rather than dropping the chunk.
            let text = String(decoding: data, as: UTF8.self)
            guard !text.isEmpty else { return }
            let backend = backend
            Task { try? await backend.send(text: text) }
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            // OSC 8 payloads are attacker-controlled — agent output can contain any string. Only http(s) is handed
            // upwards, so a `file://` or a custom scheme cannot be used to reach another app on the device.
            guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else { return }
            onOpenLink(url)
        }

        func bell(source: TerminalView) {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }

        /// OSC 52 write: the remote side asked to put something on this device's clipboard.
        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8), !text.isEmpty else { return }
            UIPasteboard.general.setItems(
                [[UTType.utf8PlainText.identifier: text]],
                // A remote host writing the clipboard is convenient for lifting a URL out of a build log and a
                // liability for everything else, so the write expires instead of following the user into other apps.
                options: [.expirationDate: Date().addingTimeInterval(120)]
            )
        }

        /// OSC 52 read: refused. A remote process must not be able to exfiltrate whatever the user last copied,
        /// which may be a password from their password manager.
        func clipboardRead(source: TerminalView) -> Data? { nil }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

// MARK: - The view

/// `TerminalView` with OpenPaw's palette, input configuration, zoom and Command-key chrome.
final class OpenPawTerminalView: TerminalView {

    weak var coordinator: TerminalSurface.Coordinator?
    private var lastGeometry: PTYSize?
    private var pinchBaseFontSize: CGFloat = TerminalSurface.defaultFontSize

    // MARK: Appearance

    /// The terminal face for one SGR variant, with a CJK fallback attached.
    ///
    /// `UIFont.monospacedSystemFont` has no CJK glyphs whatsoever — `CTFontGetGlyphsForCharacters` returns false
    /// for 中, 文, 字 and every other Han character. Left alone, CoreText silently substitutes a face per run, and
    /// the one it picks (`.PingFangUITextSC`) is a *UI* face the app never chose: it is not the family the rest of
    /// OpenPaw sets, and its weight is selected by CoreText rather than by the terminal's SGR state.
    ///
    /// No font shipped on iOS has both a monospaced Latin set and Han glyphs, so the fix is a cascade: keep the
    /// system monospaced face for Latin and name PingFang as the fallback for everything it cannot draw, which
    /// makes the choice explicit and stable instead of leaving it to a per-run guess.
    static func terminalFont(ofSize size: CGFloat, traits: UIFontDescriptor.SymbolicTraits = []) -> UIFont {
        let base = UIFont.monospacedSystemFont(ofSize: size, weight: traits.contains(.traitBold) ? .bold : .regular)
        // Traits first, cascade second. `withSymbolicTraits` resolves against a concrete family and drops any
        // cascade list already on the descriptor, so attaching the fallback first would silently lose it and
        // bold Chinese would fall back to CoreText's own substitution again.
        let varied = base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor
        let fallbacks = ["PingFangSC-Regular", "HiraginoSans-W3", "AppleSDGothicNeo-Regular"]
            .map { UIFontDescriptor(fontAttributes: [.name: $0]) }
        return UIFont(descriptor: varied.addingAttributes([.cascadeList: fallbacks]), size: size)
    }

    /// Builds all four SGR variants explicitly rather than letting SwiftTerm derive them.
    ///
    /// `TerminalView.font` runs the base font through `FontSet(font:)`, which derives bold and italic with
    /// `withSymbolicTraits` — and that drops the cascade list, so any Chinese in bold or italic output would lose
    /// the fallback that the regular weight has. Setting the four faces directly keeps every variant on the same
    /// family.
    func apply(fontSize: CGFloat) {
        setFonts(
            normal: Self.terminalFont(ofSize: fontSize),
            bold: Self.terminalFont(ofSize: fontSize, traits: .traitBold),
            italic: Self.terminalFont(ofSize: fontSize, traits: .traitItalic),
            boldItalic: Self.terminalFont(ofSize: fontSize, traits: [.traitBold, .traitItalic])
        )
    }

    /// The terminal is the machine register at its purest, so it takes the recessed `well` surface and the primary
    /// ink straight from the theme rather than inventing a second palette.
    func applyOpenPawPalette() {
        nativeBackgroundColor = UIColor(OpenPawTheme.well)
        nativeForegroundColor = UIColor(OpenPawTheme.textPrimary)
        backgroundColor = UIColor(OpenPawTheme.well)
        indicatorStyle = .white
    }

    // MARK: Input configuration

    /// The settings that actually make CJK and shell input work.
    ///
    /// Autocorrection is the loudest failure: with it on, the keyboard capitalises the first word of every command
    /// and — worst for input methods — inserts its own candidate over the one the user picked. Smart quotes turn
    /// `"$PATH"` into typographic quotes, which the shell reads as a literal. Smart dashes turn `--force` into an en
    /// dash. Each produces bytes the user never typed, on a surface where bytes are commands. SwiftTerm already
    /// defaults these off; setting them here means a future upstream default cannot quietly change that.
    func configureTextInput() {
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        keyboardAppearance = .dark
        returnKeyType = .default
        // Composition must look provisional. Underlining it is how the user can tell the characters on screen have
        // not been sent yet, which is exactly the invariant the coordinator maintains.
        markedTextStyle = [
            NSAttributedString.Key.underlineStyle: NSUnderlineStyle.single.rawValue,
            NSAttributedString.Key.foregroundColor: UIColor(OpenPawTheme.textPrimary),
        ]
        allowMouseReporting = true
        optionAsMetaKey = true
    }

    // MARK: Zoom

    /// Pinch changes the point size, not a transform. Scaling the layer would blur the glyphs and, worse, would
    /// leave the cell grid unchanged, so the remote side would keep drawing 80 columns into a view now showing 40.
    /// Re-deriving the font makes the grid change and the resize get reported.
    func installPinchZoom() {
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch)))
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchBaseFontSize = font.pointSize
        case .changed, .ended:
            coordinator?.changeFontSize(to: (pinchBaseFontSize * gesture.scale).rounded())
        default:
            break
        }
    }

    // MARK: Geometry

    override func layoutSubviews() {
        super.layoutSubviews()
        let terminal = getTerminal()
        let size = PTYSize(columns: terminal.cols, rows: terminal.rows)
        guard size != lastGeometry else { return }
        lastGeometry = size
        coordinator?.geometryChanged(columns: size.columns, rows: size.rows)
    }

    // MARK: Paste

    override func paste(_ sender: Any?) {
        // Routed through the coordinator so an image on the clipboard becomes an attachment, and so bracketed paste
        // has one implementation rather than two.
        coordinator?.pasteboardContents()
    }

    // MARK: Key commands

    /// Only Command-modified chords become `UIKeyCommand`s.
    ///
    /// This is not a style choice. A `UIKeyCommand` swallows its chord before `pressesBegan` sees it, so declaring
    /// Control-C here would stop the user from ever interrupting a remote process — the single most important key in
    /// a terminal. The remote side cannot receive Command, and iOS reserves nothing with Command inside a terminal,
    /// so Command is both the only modifier safe to intercept and the only one useful for app chrome.
    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(title: "Zoom In", action: #selector(zoomIn), input: "+", modifierFlags: .command),
            UIKeyCommand(title: "Zoom Out", action: #selector(zoomOut), input: "-", modifierFlags: .command),
            UIKeyCommand(title: "Actual Size", action: #selector(zoomReset), input: "0", modifierFlags: .command),
            UIKeyCommand(title: "Paste", action: #selector(pasteFromKeyboard), input: "v", modifierFlags: .command),
            UIKeyCommand(title: "Interrupt", action: #selector(sendInterrupt), input: ".", modifierFlags: .command),
            UIKeyCommand(title: "Clear Screen", action: #selector(clearScreen), input: "k", modifierFlags: .command),
            UIKeyCommand(
                title: "End of File", action: #selector(sendEndOfFile), input: "d", modifierFlags: .command
            ),
        ]
        for command in commands {
            command.wantsPriorityOverSystemBehavior = true
        }
        return commands
    }

    @objc private func zoomIn() { coordinator?.changeFontSize(to: font.pointSize + 1) }
    @objc private func zoomOut() { coordinator?.changeFontSize(to: font.pointSize - 1) }
    @objc private func zoomReset() { coordinator?.changeFontSize(to: TerminalSurface.defaultFontSize) }
    @objc private func pasteFromKeyboard() { coordinator?.pasteboardContents() }

    // Control bytes are fixed by the terminal standard and do not depend on cursor-key mode, so they go out as text
    // rather than round-tripping through a chord encoder that would have to be told the same three facts.
    @objc private func sendInterrupt() { coordinator?.transmit("\u{03}") }
    @objc private func clearScreen() { coordinator?.transmit("\u{0C}") }
    @objc private func sendEndOfFile() { coordinator?.transmit("\u{04}") }
}
