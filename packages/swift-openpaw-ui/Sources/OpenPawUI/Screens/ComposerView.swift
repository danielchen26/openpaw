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
    /// Existing draft stays visible in front of the guess for both destinations. Speech always lands in an editable
    /// draft first; Send or Execute is a separate explicit action.
    static func inProgress(
        draft: String, partial: String, mode: DictationMode
    ) -> (committed: String, live: String) {
        let live = partial.isEmpty ? "…" : partial
        return (draft.isEmpty ? "" : draft + " ", live)
    }

    /// The draft after letting go in `.composer` mode: joined by a single space, never gaining a leading one.
    static func committing(draft: String, phrase: String) -> String {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return draft }
        guard !draft.isEmpty else { return phrase }
        return draft.hasSuffix(" ") || draft.hasSuffix("\n") ? draft + phrase : draft + " " + phrase
    }

    public static let firstClassLocales = VoiceLocaleChoices.firstClassLocales

    static func normalize(_ identifier: String) -> String { VoiceLocaleChoices.normalize(identifier) }

    static func localeChoices(
        deviceLocale: String,
        firstClass: [String] = VoiceLocaleChoices.firstClassLocales
    ) -> [String] {
        VoiceLocaleChoices.choices(deviceLocale: deviceLocale, firstClass: firstClass)
    }
}

public struct ComposerControlPresentation: Sendable, Equatable {
    public let commitTitle: String
    public let accessibilityLabel: String
    public let isCommitEnabled: Bool
    public let disabledReason: String?
    public let isDestinationSwitchEnabled: Bool
    public let isLocaleSwitchEnabled: Bool
    public let isDraftEditorEnabled: Bool
    public let microphoneAccessibilityLabel: String
    public let microphoneAccessibilityHint: String
    public let microphoneKeyboardShortcut: String

    public static func make(
        destination: VoiceDestination,
        hasAttachments: Bool,
        hasDraft: Bool,
        isSending: Bool,
        isDictating: Bool = false,
        supportsAgentAttachments: Bool = true
    ) -> Self {
        let title = destination == .agent ? "Send" : "Execute"
        let label = destination == .agent ? "Send the agent prompt" : "Execute the terminal draft"
        let hasPayload = destination == .agent ? (hasDraft || hasAttachments) : hasDraft
        let blockedByAttachments = destination == .terminal && hasAttachments
        let blockedByUnsupportedAgentAttachments = destination == .agent && hasAttachments && !supportsAgentAttachments
        return Self(
            commitTitle: title,
            accessibilityLabel: isSending ? (destination == .agent ? "Sending" : "Executing") : label,
            isCommitEnabled: !isSending && !isDictating && hasPayload && !blockedByAttachments && !blockedByUnsupportedAgentAttachments,
            disabledReason: blockedByAttachments
                ? "Remove attachments before executing a terminal draft."
                : (blockedByUnsupportedAgentAttachments ? "Connect to a host before sending attachments." : nil),
            isDestinationSwitchEnabled: !isDictating,
            isLocaleSwitchEnabled: !isDictating,
            isDraftEditorEnabled: !isDictating,
            microphoneAccessibilityLabel: isDictating ? "Stop dictation" : "Start dictation",
            microphoneAccessibilityHint: Self.microphoneHint(destination: destination, isDictating: isDictating),
            microphoneKeyboardShortcut: "⌘⇧M"
        )
    }

    private static func microphoneHint(destination: VoiceDestination, isDictating: Bool) -> String {
        if isDictating {
            return destination == .agent
                ? "Double tap to stop. Words land in the agent draft until you tap Send."
                : "Double tap to stop. Words land in the terminal draft until you tap Execute."
        }
        return destination == .agent
            ? "Double tap to start. Press and hold also works. Words land in the agent draft."
            : "Double tap to start. Press and hold also works. Words land in the terminal draft."
    }
}

public struct ComposerDictationPreferences: Sendable, Equatable {
    public let localeID: String
    public let destination: VoiceDestination

    public static func restored(localeID: String, mode: DictationMode) -> Self {
        Self(localeID: VoiceLocaleChoices.normalize(localeID), destination: VoiceDestination(dictationMode: mode))
    }

    public static func persistedMode(for destination: VoiceDestination) -> DictationMode {
        destination.dictationMode
    }
}

public struct ActiveDictationDraftPresentation: Sendable, Equatable {
    public let editableDraft: String
    public let partialPreview: String
    public let accessibilityValue: String

    public static func make(draft: String, partial: String) -> Self {
        let preview = partial.isEmpty ? "Listening" : partial
        let value = draft.isEmpty
            ? "Current recognition \(preview)"
            : "Draft \(draft). Current recognition \(preview)"
        return Self(editableDraft: draft, partialPreview: preview, accessibilityValue: value)
    }
}

public struct TerminalDictationDraftPresentation: Sendable, Equatable {
    public let isTextFieldEnabled: Bool
    public let isExecuteEnabled: Bool

    public static func make(draft: String, isDictating: Bool) -> Self {
        let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Self(isTextFieldEnabled: !isDictating, isExecuteEnabled: hasDraft && !isDictating)
    }
}


/// The send surface: human register, because everything that leaves this view is something a person said.
///
/// Dictation is here rather than in a settings screen because mixed Chinese and English speech is a primary way
/// this app is used — walking, one hand, describing a change out loud. Two things follow from that. The locale is
/// on screen and switchable in one tap rather than buried, with `zh-CN` and `en-US` both first class. And the
/// mode switch is explicit: speech lands in an editable draft, then Send or Execute is explicit.
@MainActor
public struct ComposerView: View {
    /// A growing editor stops growing here and starts scrolling. Six lines is a paragraph; more than that and the
    /// transcript above has disappeared, which is the thing you are writing about.
    static let maximumLines = 6

    private let engine: (any DictationEngine)?
    private let settings: OpenPawSettings
    private let supportsAgentAttachments: Bool
    private let onCommit: (VoiceCommitAction, [ComposerAttachment]) async -> Bool

    @State private var voice: VoiceComposition
    @State private var attachments: [ComposerAttachment] = []
    @State private var isSending = false
    @State private var isImporting = false

    @State private var localeID: String
    @State private var dictationTask: Task<Void, Never>?
    @State private var dictationTurnID: VoiceTurnID?
    @State private var failure: String?

    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 21
    @ScaledMetric(relativeTo: .body) private var thumbnailSide: CGFloat = 72

    public init(
        engine: (any DictationEngine)? = nil,
        settings: OpenPawSettings = OpenPawSettings(),
        supportsAgentAttachments: Bool = true,
        initialDestination: VoiceDestination? = nil,
        onCommit: @escaping (VoiceCommitAction, [ComposerAttachment]) async -> Bool
    ) {
        self.engine = engine
        self.settings = settings
        self.supportsAgentAttachments = supportsAgentAttachments
        self.onCommit = onCommit
        let restored = ComposerDictationPreferences.restored(localeID: settings.dictationLocaleID, mode: settings.dictationMode)
        let destination = initialDestination ?? restored.destination
        self._voice = State(initialValue: VoiceComposition(destination: destination))
        self._localeID = State(initialValue: restored.localeID)
    }

    /// Present only when an engine exists and the platform granted it. An always-visible but permanently disabled
    /// microphone teaches the user nothing.
    private var hasDictation: Bool { engine?.isAvailable == true }

    private var controlPresentation: ComposerControlPresentation {
        ComposerControlPresentation.make(
            destination: voice.destination,
            hasAttachments: !attachments.isEmpty,
            hasDraft: !voice.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isSending: isSending,
            isDictating: voice.isActive,
            supportsAgentAttachments: supportsAgentAttachments
        )
    }

    private var canCommit: Bool {
        controlPresentation.isCommitEnabled
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
        .onDisappear { cancelDictation() }
        .onChange(of: localeID) { _, newValue in settings.dictationLocaleID = VoiceLocaleChoices.normalize(newValue) }
    }

    // MARK: Editor

    @ViewBuilder
    private var editor: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            if voice.isActive {
                HStack(spacing: OpenPawTheme.Space.small) {
                    Text("listening · \(localeID)").microLabel(OpenPawTheme.warn)
                    Spacer(minLength: 0)
                    Text(voice.destination == .agent ? "to draft" : "to terminal").microLabel(OpenPawTheme.warn)
                }
            }
            TextEditor(text: $voice.draft)
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
                    if voice.draft.isEmpty {
                        Text("Say what you want changed")
                            .font(OpenPawTheme.Human.prose)
                            .foregroundStyle(OpenPawTheme.textTertiary)
                            .padding(.horizontal, OpenPawTheme.Space.small + 4)
                            .padding(.vertical, OpenPawTheme.Space.small)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Prompt")
                .accessibilityValue(activeDraftPresentation.accessibilityValue)
                .disabled(!controlPresentation.isDraftEditorEnabled)
            if voice.isActive {
                Text(activeDraftPresentation.partialPreview)
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Current recognition")
            }
        }
    }

    private var activeDraftPresentation: ActiveDictationDraftPresentation {
        ActiveDictationDraftPresentation.make(draft: voice.draft, partial: voice.partialTranscript)
    }

    private var visibleLines: Int {
        let hard = voice.draft.reduce(into: 1) { total, character in
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
                Text(voice.destination == .agent ? "to draft" : "to terminal").microLabel(OpenPawTheme.warn)
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
        .accessibilityLabel("Listening in \(localeID). \(voice.partialTranscript)")
    }

    /// Draft in primary ink, the live guess in secondary, so it is obvious which words are committed.
    private var spokenSoFar: AttributedString {
        let split = DictationDraft.inProgress(draft: voice.draft, partial: voice.partialTranscript, mode: voice.destination.dictationMode)
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

            commitButton
        }
    }

    private var dictationControls: some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            microphone
            modeToggle
            localeMenu
        }
    }

    /// Where your voice goes is a two-state, safety-relevant choice, so it is a visible toggle carrying the word.
    private var modeToggle: some View {
        Button {
            let next: VoiceDestination = voice.destination == .agent ? .terminal : .agent
            voice.switchDestination(to: next)
            settings.dictationMode = ComposerDictationPreferences.persistedMode(for: next)
        } label: {
            Text(voice.destination == .agent ? "draft" : "terminal")
                .font(OpenPawTheme.Machine.label)
                .textCase(.uppercase)
                .tracking(0.9)
                .foregroundStyle(voice.destination == .agent ? OpenPawTheme.textSecondary : OpenPawTheme.warn)
                .padding(.horizontal, OpenPawTheme.Space.small)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!controlPresentation.isDestinationSwitchEnabled)
        .overlay(
            RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                .strokeBorder(
                    voice.destination == .agent ? OpenPawTheme.line : OpenPawTheme.warn,
                    lineWidth: OpenPawTheme.hairline * 3
                )
        )
        .accessibilityLabel(
            voice.destination == .agent
                ? "Dictation goes to the draft. Switches to terminal draft."
                : "Dictation goes to a terminal draft. Switches to keeping an agent draft."
        )
        .accessibilityHint(controlPresentation.isDestinationSwitchEnabled ? "" : "Stop dictation before changing destination.")
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
        .disabled(!controlPresentation.isLocaleSwitchEnabled)
        .accessibilityLabel("Dictation language \(Self.name(for: localeID))")
        .accessibilityHint(controlPresentation.isLocaleSwitchEnabled ? "" : "Stop dictation before changing language.")
    }

    /// Press and hold to talk. Holding is the right gesture for a walk-and-talk product: it cannot be left running
    /// by accident, and letting go is a decision, not a second aimed tap.
    private var microphone: some View {
        Button(action: { voice.isActive ? stopDictation() : startDictation() }) {
            Image(systemName: voice.isActive ? "waveform" : "mic")
                .imageScale(.medium)
                .foregroundStyle(voice.isActive ? OpenPawTheme.warn : OpenPawTheme.textSecondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                .strokeBorder(
                    voice.isActive ? OpenPawTheme.warn : OpenPawTheme.line,
                    lineWidth: OpenPawTheme.hairline * 3
                )
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in startDictation() }
                .onEnded { _ in stopDictation() }
        )
        .accessibilityLabel(controlPresentation.microphoneAccessibilityLabel)
        .accessibilityHint(controlPresentation.microphoneAccessibilityHint)
        .accessibilityAction { voice.isActive ? stopDictation() : startDictation() }
        .keyboardShortcut("m", modifiers: [.command, .shift])
    }

    private var commitButton: some View {
        let presentation = controlPresentation
        return Button(action: commit) {
            Label(presentation.commitTitle, systemImage: voice.destination == .agent ? "arrow.up" : "terminal")
                .labelStyle(.titleAndIcon)
                .font(OpenPawTheme.Machine.headline)
                .foregroundStyle(canCommit ? OpenPawTheme.textPrimary : OpenPawTheme.textTertiary)
                .padding(.horizontal, OpenPawTheme.Space.medium)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canCommit)
        .overlay(
            RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                .strokeBorder(
                    canCommit ? OpenPawTheme.lineStrong : OpenPawTheme.line,
                    lineWidth: OpenPawTheme.hairline * 3
                )
        )
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint(presentation.disabledReason ?? "")
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

    // MARK: Committing

    private func commit() {
        guard canCommit, let action = voice.commit(hasAttachments: !attachments.isEmpty) else { return }
        let payload = attachments
        isSending = true
        Task {
            let succeeded = await onCommit(action, payload)
            if succeeded {
                voice.clearAfterSuccessfulCommit()
                if case .sendAgent = action { attachments = [] }
            }
            isSending = false
        }
    }

    // MARK: Dictation

    private var localeChoices: [String] {
        VoiceLocaleChoices.choices(deviceLocale: localeID)
    }

    static func normalize(_ identifier: String) -> String {
        VoiceLocaleChoices.normalize(identifier)
    }

    static func name(for identifier: String) -> String {
        let localized = Locale.current.localizedString(forIdentifier: identifier)
        return localized.map { "\($0) · \(identifier)" } ?? identifier
    }

    private func startDictation() {
        guard let engine, engine.isAvailable, !voice.isActive else { return }
        let turnID = voice.start()
        failure = nil
        let locale = Locale(identifier: localeID)
        let destination = voice.destination
        dictationTurnID = turnID
        dictationTask = Task {
            do {
                for try await update in engine.transcribe(locale: locale, mode: destination.dictationMode) {
                    guard dictationTurnID == turnID else { return }
                    voice.apply(update, turn: turnID)
                }
            } catch is CancellationError {
                return
            } catch {
                guard dictationTurnID == turnID else { return }
                failure = "Dictation stopped: \(error.localizedDescription). Check microphone access and hold again."
                voice.stop()
            }
        }
    }

    private func stopDictation() {
        guard voice.isActive else { return }
        voice.stop()
        let task = dictationTask
        dictationTask = nil
        Task {
            await engine?.stop()
            try? await Task.sleep(for: .milliseconds(50))
            task?.cancel()
        }
    }

    private func cancelDictation() {
        guard voice.isActive || dictationTask != nil else { return }
        voice.cancel()
        dictationTurnID = nil
        let task = dictationTask
        dictationTask = nil
        Task {
            await engine?.stop()
            task?.cancel()
        }
    }
}

// MARK: - Previews

#Preview("Composer") {
    let model = PreviewBackend.model()
        return VStack {
            Spacer()
        ComposerView(engine: model.dictation) { action, files in
            await model.commitVoice(action, attachments: files)
        }
    }
    .background(OpenPawTheme.ink)
}

#Preview("Composer · no dictation engine") {
    VStack {
        Spacer()
        ComposerView(engine: nil) { _, _ in false }
    }
    .background(OpenPawTheme.ink)
}
