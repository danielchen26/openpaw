import Foundation
import OpenPawProtocol
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Attachment

/// An image the user picked and has not sent yet.
///
/// The thumbnail is decoded once, when the file is chosen, rather than every time the strip lays out. A composer
/// that decodes a 12 megapixel screenshot on each layout pass drops frames while you are still typing.
///
/// Every field is immutable, which is what lets an attachment cross into the send closure — that call leaves the
/// main actor, so the payload has to be safe to hand over rather than merely convenient to read.
public struct ComposerAttachment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let data: Data
    public let filename: String
    public let preview: Image?

    public init(id: UUID = UUID(), data: Data, filename: String, preview: Image?) {
        self.id = id
        self.data = data
        self.filename = filename
        self.preview = preview
    }

    /// Decodes the thumbnail with whatever image type this platform has.
    public init(data: Data, filename: String) {
        self.init(id: UUID(), data: data, filename: filename, preview: Self.decode(data))
    }

    static func decode(_ data: Data) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }
}

// MARK: - Dictation text rules

/// The text rules behind press-and-hold dictation, as plain functions.
///
/// The two things that matter about speech input are what you see while you are still talking and what survives
/// letting go, and neither should need a microphone to check. Keeping them here rather than inside the view's body
/// is what makes that possible.
enum DictationDraft {

    /// What the editor shows mid-phrase, split into the part already committed and the live guess.
    ///
    /// In `.composer` mode the existing draft stays visible in front of the guess, because the phrase is about to
    /// join it. In `.terminal` mode there is no draft to join — each finished phrase has already left — so only the
    /// guess shows, and showing a stale draft there would imply text is queued when none is.
    static func inProgress(
        draft: String, partial: String, mode: DictationMode
    ) -> (committed: String, live: String) {
        let live = partial.isEmpty ? "…" : partial
        switch mode {
        case .composer:
            return (draft.isEmpty ? "" : draft + " ", live)
        case .terminal:
            return ("", live)
        }
    }

    /// The draft after letting go in `.composer` mode: joined by a single space, never gaining a leading one.
    static func committing(draft: String, phrase: String) -> String {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return draft }
        guard !draft.isEmpty else { return phrase }
        return draft.hasSuffix(" ") || draft.hasSuffix("\n") ? draft + phrase : draft + " " + phrase
    }

    /// The two locales this product is designed around. Anything else the device offers is added in front of them.
    public static let firstClassLocales = ["en-US", "zh-CN"]

    /// `en_US` and `en-US` are the same locale; the switcher must not offer both.
    static func normalize(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
    }

    /// The switcher's contents: the device's own locale first when it is not already one of the first-class two,
    /// then those two, always both present. Mixed Chinese and English dictation is a primary use, so neither is
    /// ever more than one tap away regardless of what the device is set to.
    static func localeChoices(
        deviceLocale: String, firstClass: [String] = firstClassLocales
    ) -> [String] {
        let device = normalize(deviceLocale)
        var identifiers = firstClass
        if !identifiers.contains(device) { identifiers.insert(device, at: 0) }
        return identifiers
    }
}

// MARK: - Composer

/// The send surface: human register, because everything that leaves this view is something a person said.
///
/// Dictation is here rather than in a settings screen because mixed Chinese and English speech is a primary way
/// this app is used — walking, one hand, describing a change out loud. Two things follow from that. The locale is
/// on screen and switchable in one tap rather than buried, with `zh-CN` and `en-US` both first class. And the
/// mode switch is explicit: speech either lands in an editable draft you can fix before sending, or it goes
/// straight to the terminal as each phrase is recognised, and you can always see which of the two is armed.
@MainActor
public struct ComposerView: View {
    /// A growing editor stops growing here and starts scrolling. Six lines is a paragraph; more than that and the
    /// transcript above has disappeared, which is the thing you are writing about.
    static let maximumLines = 6

    private let engine: (any DictationEngine)?
    private let onSend: (String, [ComposerAttachment]) async -> Void

    @State private var draft = ""
    @State private var attachments: [ComposerAttachment] = []
    @State private var isSending = false
    @State private var isImporting = false

    @State private var mode: DictationMode = .composer
    @State private var localeID: String
    @State private var isDictating = false
    @State private var partial = ""
    @State private var dictationTask: Task<Void, Never>?
    @State private var failure: String?

    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 21
    @ScaledMetric(relativeTo: .body) private var thumbnailSide: CGFloat = 72

    public init(
        engine: (any DictationEngine)? = nil,
        onSend: @escaping (String, [ComposerAttachment]) async -> Void
    ) {
        self.engine = engine
        self.onSend = onSend
        // The device locale is the right default; the switcher exists for the second language, not the first.
        self._localeID = State(initialValue: Self.normalize(Locale.current.identifier))
    }

    /// Present only when an engine exists and the platform granted it. An always-visible but permanently disabled
    /// microphone teaches the user nothing.
    private var hasDictation: Bool { engine?.isAvailable == true }

    private var canSend: Bool {
        !isSending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            if let failure {
                Text(failure)
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.bad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !attachments.isEmpty {
                attachmentStrip
            }

            editor

            controls
        }
        .padding(OpenPawTheme.Space.medium)
        .background(OpenPawTheme.panelWarm)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OpenPawTheme.line)
                .frame(height: OpenPawTheme.hairline)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            onCompletion: { result in attach(result) }
        )
    }

    // MARK: Editor

    @ViewBuilder
    private var editor: some View {
        if isDictating {
            liveTranscript
        } else {
            TextEditor(text: $draft)
                .font(OpenPawTheme.Human.prose)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(height: lineHeight * CGFloat(visibleLines))
                .padding(.horizontal, OpenPawTheme.Space.small)
                .padding(.vertical, OpenPawTheme.Space.tight)
                .background(
                    RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                        .fill(OpenPawTheme.well)
                )
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Say what you want changed")
                            .font(OpenPawTheme.Human.prose)
                            .foregroundStyle(OpenPawTheme.textTertiary)
                            .padding(.horizontal, OpenPawTheme.Space.small + 4)
                            .padding(.vertical, OpenPawTheme.Space.small)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Prompt")
        }
    }

    private var visibleLines: Int {
        let hard = draft.reduce(into: 1) { total, character in
            if character == "\n" { total += 1 }
        }
        return min(Self.maximumLines, max(1, hard))
    }

    /// The partial transcript replaces the editor in place, so the words appear exactly where they will end up.
    private var liveTranscript: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            HStack(spacing: OpenPawTheme.Space.small) {
                Text("listening · \(localeID)").microLabel(OpenPawTheme.warn)
                Spacer(minLength: 0)
                Text(mode == .composer ? "to draft" : "to terminal").microLabel(OpenPawTheme.warn)
            }

            Text(spokenSoFar)
                .font(OpenPawTheme.Human.prose)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: lineHeight, alignment: .topLeading)
                .padding(.horizontal, OpenPawTheme.Space.small)
                .padding(.vertical, OpenPawTheme.Space.tight)
                .background(
                    RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                        .fill(OpenPawTheme.well)
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Listening in \(localeID). \(partial)")
    }

    /// Draft in primary ink, the live guess in secondary, so it is obvious which words are committed.
    private var spokenSoFar: AttributedString {
        let split = DictationDraft.inProgress(draft: draft, partial: partial, mode: mode)
        var text = AttributedString(split.committed)
        text.foregroundColor = OpenPawTheme.textPrimary
        var live = AttributedString(split.live)
        live.foregroundColor = OpenPawTheme.textSecondary
        text.append(live)
        return text
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            iconButton("paperclip", label: "Attach an image") { isImporting = true }

            if hasDictation {
                dictationControls
            }

            Spacer(minLength: 0)

            sendButton
        }
    }

    private var dictationControls: some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            microphone
            modeToggle
            localeMenu
        }
    }

    /// Where your voice goes is a two-state, safety-relevant choice — terminal mode submits each finished phrase
    /// the moment it is recognised — so it is a visible toggle carrying the word, not a row inside a menu. It is
    /// tinted `warn` while armed for the terminal, and the word is what carries the meaning if the tint does not.
    private var modeToggle: some View {
        Button {
            mode = mode == .composer ? .terminal : .composer
        } label: {
            Text(mode == .composer ? "draft" : "terminal")
                .font(OpenPawTheme.Machine.label)
                .textCase(.uppercase)
                .tracking(0.9)
                .foregroundStyle(mode == .composer ? OpenPawTheme.textSecondary : OpenPawTheme.warn)
                .padding(.horizontal, OpenPawTheme.Space.small)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                .strokeBorder(
                    mode == .composer ? OpenPawTheme.line : OpenPawTheme.warn,
                    lineWidth: OpenPawTheme.hairline * 3
                )
        )
        .accessibilityLabel(
            mode == .composer
                ? "Dictation goes to the draft. Switches to sending straight to the terminal."
                : "Dictation goes straight to the terminal. Switches to keeping a draft."
        )
    }

    private var localeMenu: some View {
        Menu {
            Picker("Language", selection: $localeID) {
                ForEach(localeChoices, id: \.self) { identifier in
                    Text(Self.name(for: identifier)).tag(identifier)
                }
            }
        } label: {
            Text(localeID)
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .padding(.horizontal, OpenPawTheme.Space.small)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .fixedSize()
        .accessibilityLabel("Dictation language \(Self.name(for: localeID))")
    }

    /// Press and hold to talk. Holding is the right gesture for a walk-and-talk product: it cannot be left running
    /// by accident, and letting go is a decision, not a second aimed tap.
    private var microphone: some View {
        Image(systemName: isDictating ? "waveform" : "mic")
            .imageScale(.medium)
            .foregroundStyle(isDictating ? OpenPawTheme.warn : OpenPawTheme.textSecondary)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                    .strokeBorder(
                        isDictating ? OpenPawTheme.warn : OpenPawTheme.line,
                        lineWidth: OpenPawTheme.hairline * 3
                    )
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in startDictation() }
                    .onEnded { _ in stopDictation() }
            )
            .accessibilityLabel("Hold to dictate")
            .accessibilityHint(mode == .composer ? "Words land in the draft" : "Words go straight to the terminal")
    }

    private var sendButton: some View {
        Button(action: send) {
            Label("Send", systemImage: "arrow.up")
                .labelStyle(.titleAndIcon)
                .font(OpenPawTheme.Machine.headline)
                .foregroundStyle(canSend ? OpenPawTheme.textPrimary : OpenPawTheme.textTertiary)
                .padding(.horizontal, OpenPawTheme.Space.medium)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .overlay(
            RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                .strokeBorder(
                    canSend ? OpenPawTheme.lineStrong : OpenPawTheme.line,
                    lineWidth: OpenPawTheme.hairline * 3
                )
        )
        .accessibilityLabel(isSending ? "Sending" : "Send the prompt")
    }

    private func iconButton(_ glyph: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .imageScale(.medium)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Attachments

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OpenPawTheme.Space.small) {
                ForEach(attachments) { attachment in
                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
                        ZStack(alignment: .topTrailing) {
                            thumbnail(attachment)
                            Button {
                                attachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .imageScale(.medium)
                                    .foregroundStyle(OpenPawTheme.textPrimary)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(attachment.filename)")
                        }
                        Text(attachment.filename)
                            .font(OpenPawTheme.Machine.codeSmall)
                            .foregroundStyle(OpenPawTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: thumbnailSide + OpenPawTheme.Space.xxl, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, OpenPawTheme.Space.hair)
        }
    }

    @ViewBuilder
    private func thumbnail(_ attachment: ComposerAttachment) -> some View {
        if let preview = attachment.preview {
            preview
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: thumbnailSide, height: thumbnailSide)
                .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card))
        } else {
            // A file the platform could not decode is still a real attachment; it just has no picture.
            RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                .fill(OpenPawTheme.well)
                .frame(width: thumbnailSide, height: thumbnailSide)
                .overlay {
                    Image(systemName: "doc")
                        .foregroundStyle(OpenPawTheme.textTertiary)
                }
        }
    }

    private func attach(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            var picked: [ComposerAttachment] = []
            var unreadable: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    unreadable.append(url.lastPathComponent)
                    continue
                }
                picked.append(ComposerAttachment(data: data, filename: url.lastPathComponent))
            }
            attachments.append(contentsOf: picked)
            failure = unreadable.isEmpty
                ? nil
                : "Could not read \(unreadable.joined(separator: ", ")). Copy the file into Files and pick it again."
        case .failure(let error):
            failure = "Could not open the picker: \(error.localizedDescription)"
        }
    }

    // MARK: Sending

    private func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = attachments
        isSending = true
        Task {
            await onSend(text, payload)
            draft = ""
            attachments = []
            isSending = false
        }
    }

    // MARK: Dictation

    private var localeChoices: [String] {
        DictationDraft.localeChoices(deviceLocale: localeID)
    }

    static func normalize(_ identifier: String) -> String {
        DictationDraft.normalize(identifier)
    }

    static func name(for identifier: String) -> String {
        let localized = Locale.current.localizedString(forIdentifier: identifier)
        return localized.map { "\($0) · \(identifier)" } ?? identifier
    }

    private func startDictation() {
        guard let engine, engine.isAvailable, !isDictating else { return }
        isDictating = true
        partial = ""
        failure = nil
        let locale = Locale(identifier: localeID)
        let mode = self.mode
        dictationTask = Task {
            do {
                for try await update in engine.transcribe(locale: locale, mode: mode) {
                    // A finished phrase in terminal mode goes out immediately — that is what "straight to the
                    // terminal" means, and waiting for the release would just be a slower draft.
                    if mode == .terminal, update.isFinal {
                        let phrase = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        partial = ""
                        if !phrase.isEmpty { await onSend(phrase, []) }
                    } else {
                        partial = update.text
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                failure = "Dictation stopped: \(error.localizedDescription). Check microphone access and hold again."
                isDictating = false
            }
        }
    }

    private func stopDictation() {
        guard isDictating else { return }
        isDictating = false
        let tail = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = self.mode
        partial = ""
        let task = dictationTask
        dictationTask = nil
        Task {
            await engine?.stop()
            task?.cancel()
            guard !tail.isEmpty else { return }
            switch mode {
            case .composer:
                // Kept as an editable draft: speech recognition is wrong often enough that sending unread is
                // the wrong default when the words are about to change someone's repository.
                draft = DictationDraft.committing(draft: draft, phrase: tail)
            case .terminal:
                await onSend(tail, [])
            }
        }
    }
}

// MARK: - Previews

#Preview("Composer") {
    let model = PreviewBackend.model()
    return VStack {
        Spacer()
        ComposerView(engine: model.dictation) { prompt, files in
            await model.send(prompt: prompt)
            _ = files
        }
    }
    .background(OpenPawTheme.ink)
}

#Preview("Composer · no dictation engine") {
    VStack {
        Spacer()
        ComposerView(engine: nil) { _, _ in }
    }
    .background(OpenPawTheme.ink)
}
