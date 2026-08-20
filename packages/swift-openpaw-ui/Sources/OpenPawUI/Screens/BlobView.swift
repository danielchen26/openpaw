import ImageIO
import OpenPawProtocol
import SwiftUI

// MARK: - Markdown

/// One block of a rendered markdown document.
///
/// Markdown is block-structured and `Text` is not, so a real preview has to be laid out block by block. The
/// parser gives us `PresentationIntent`; this turns that into something a `VStack` can walk.
public struct MarkdownBlock: Identifiable {
    public enum Kind: Hashable {
        case paragraph
        case heading(level: Int)
        case listItem(ordinal: Int?, depth: Int)
        case codeBlock(language: String?)
        case quote
        case thematicBreak
    }

    public let id: Int
    public let kind: Kind
    public let text: AttributedString

    public init(id: Int, kind: Kind, text: AttributedString) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// Markdown in the two registers: prose in the serif face, anything the machine would execute in the mono one.
///
/// The split is the point. A reader skimming a README can see at a glance which parts are sentences and which
/// parts are commands they could paste.
public enum MarkdownRenderer {

    /// Block structure, which is what the preview lays out.
    public static func blocks(_ source: String) -> [MarkdownBlock] {
        guard let parsed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: true,
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            // Unparsable markdown is still text, and showing it beats showing nothing.
            var fallback = AttributedString(source)
            fallback.font = OpenPawTheme.Human.prose
            fallback.foregroundColor = OpenPawTheme.textPrimary
            return [MarkdownBlock(id: 0, kind: .paragraph, text: fallback)]
        }

        var out: [MarkdownBlock] = []
        var currentIntent: PresentationIntent?
        var currentKind: MarkdownBlock.Kind = .paragraph
        var currentText = AttributedString()
        var isOpen = false

        for run in parsed.runs {
            let intent = run.presentationIntent
            if !isOpen || intent != currentIntent {
                if isOpen {
                    out.append(MarkdownBlock(id: out.count, kind: currentKind, text: currentText))
                }
                currentIntent = intent
                currentKind = kind(of: intent)
                currentText = AttributedString()
                isOpen = true
            }
            var slice = AttributedString(parsed[run.range])
            style(&slice, blockKind: currentKind, inline: run.inlinePresentationIntent)
            currentText.append(slice)
        }
        if isOpen {
            out.append(MarkdownBlock(id: out.count, kind: currentKind, text: currentText))
        }
        return out.filter { !$0.text.characters.isEmpty || $0.kind == .thematicBreak }
    }

    /// The whole document as one string, for callers that cannot lay blocks out — the pasteboard, and any
    /// accessibility summary that wants the prose without the syntax.
    public static func render(_ source: String) -> AttributedString {
        var out = AttributedString()
        for block in blocks(source) {
            if !out.characters.isEmpty {
                var separator = AttributedString("\n")
                separator.font = OpenPawTheme.Human.prose
                out.append(separator)
            }
            out.append(block.text)
        }
        return out
    }

    /// Plain text of the rendered document, with the markdown syntax gone.
    public static func plainText(_ source: String) -> String {
        String(render(source).characters)
    }

    // MARK: Intent mapping

    static func kind(of intent: PresentationIntent?) -> MarkdownBlock.Kind {
        guard let intent else { return .paragraph }
        var heading: Int?
        var ordinal: Int?
        var isListItem = false
        var isOrdered = false
        var listDepth = 0
        var isCode = false
        var codeLanguage: String?
        var isQuote = false
        var isBreak = false

        for component in intent.components {
            switch component.kind {
            case .header(let level):
                heading = level
            case .listItem(let index):
                isListItem = true
                ordinal = index
            case .orderedList:
                isOrdered = true
                listDepth += 1
            case .unorderedList:
                listDepth += 1
            case .codeBlock(let languageHint):
                isCode = true
                codeLanguage = languageHint
            case .blockQuote:
                isQuote = true
            case .thematicBreak:
                isBreak = true
            default:
                continue
            }
        }

        if let heading { return .heading(level: heading) }
        if isCode { return .codeBlock(language: codeLanguage) }
        if isBreak { return .thematicBreak }
        if isListItem { return .listItem(ordinal: isOrdered ? ordinal : nil, depth: max(1, listDepth)) }
        if isQuote { return .quote }
        return .paragraph
    }

    /// Inline code and fenced code cross into the machine register; everything else stays human.
    static func style(
        _ slice: inout AttributedString,
        blockKind: MarkdownBlock.Kind,
        inline: InlinePresentationIntent?
    ) {
        let isCodeSpan = inline?.contains(.code) ?? false
        var isCodeBlock = false
        if case .codeBlock = blockKind { isCodeBlock = true }

        if isCodeSpan || isCodeBlock {
            slice.font = OpenPawTheme.Machine.code
            slice.foregroundColor = OpenPawTheme.textPrimary
            slice.backgroundColor = OpenPawTheme.well
            return
        }

        var font = baseFont(for: blockKind)
        if inline?.contains(.stronglyEmphasized) == true { font = font.bold() }
        if inline?.contains(.emphasized) == true { font = font.italic() }
        slice.font = font
        slice.foregroundColor = foreground(for: blockKind)
        if inline?.contains(.strikethrough) == true { slice.strikethroughStyle = .single }
    }

    static func baseFont(for kind: MarkdownBlock.Kind) -> Font {
        switch kind {
        case .heading(let level):
            switch level {
            case 1: OpenPawTheme.Human.display
            case 2: OpenPawTheme.Human.title
            default: OpenPawTheme.Human.prose.weight(.semibold)
            }
        case .paragraph:
            OpenPawTheme.Human.prose
        case .listItem:
            OpenPawTheme.Human.proseTight
        case .quote:
            OpenPawTheme.Human.proseTight.italic()
        case .codeBlock:
            OpenPawTheme.Machine.code
        case .thematicBreak:
            OpenPawTheme.Human.caption
        }
    }

    static func foreground(for kind: MarkdownBlock.Kind) -> Color {
        switch kind {
        case .heading: OpenPawTheme.textPrimary
        case .paragraph, .listItem: OpenPawTheme.textPrimary
        case .quote: OpenPawTheme.textSecondary
        case .codeBlock: OpenPawTheme.textPrimary
        case .thematicBreak: OpenPawTheme.textTertiary
        }
    }
}

// MARK: - Text windowing

/// The slice of a file that is actually on screen, and the sentence explaining the rest.
public struct BlobTextWindow {
    public let text: String
    public let firstLine: Int
    public let shown: Int
    public let total: Int

    public init(text: String, firstLine: Int, shown: Int, total: Int) {
        self.text = text
        self.firstLine = firstLine
        self.shown = shown
        self.total = total
    }

    public var isTruncated: Bool { shown < total }

    public var note: String? {
        guard isTruncated else { return nil }
        if firstLine > 1 {
            return "Showing lines \(firstLine) to \(firstLine + shown - 1) of \(total)."
        }
        return "Showing first \(shown) lines of \(total). \(total - shown) more are not rendered."
    }
}

public enum BlobText {

    /// Applies the budget, keeping `focusLine` inside the window when there is one. A search hit on line 9,000
    /// is useless if the viewer only ever renders the first two thousand.
    public static func window(
        _ text: String,
        budget: LineBudget,
        focusLine: Int? = nil
    ) -> BlobTextWindow {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let total = lines.count
        guard total > budget.limit, budget.limit > 0 else {
            return BlobTextWindow(text: text, firstLine: 1, shown: total, total: total)
        }
        var start = 0
        if let focusLine, focusLine - 1 >= budget.limit {
            // Leave a third of the window above the hit so the reader sees its context.
            start = min(total - budget.limit, max(0, focusLine - 1 - budget.limit / 3))
        }
        let end = min(total, start + budget.limit)
        let slice = lines[start..<end].joined(separator: "\n")
        return BlobTextWindow(text: slice, firstLine: start + 1, shown: end - start, total: total)
    }
}

// MARK: - Image decoding

/// A decoded raster with the pixel size the file actually declares.
public struct DecodedBlobImage {
    public let image: Image
    public let pixelWidth: Int
    public let pixelHeight: Int

    public var sizeLabel: String { "\(pixelWidth) × \(pixelHeight) px" }
}

/// ImageIO rather than UIKit or AppKit, so one code path decodes on both platforms.
enum BlobImageDecoder {
    static func decode(_ data: Data) -> DecodedBlobImage? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return DecodedBlobImage(
            image: Image(decorative: cgImage, scale: 1),
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height
        )
    }
}

// MARK: - Blob view

/// One file, as the host reads it at a given ref.
///
/// Four shapes arrive here and each gets its own treatment: source becomes numbered, highlighted code; markdown
/// becomes a real rendered document with a way back to the source; an image becomes an image; and a binary
/// becomes its digest and an explanation, because the host ships digests for binaries and never their bytes.
public struct BlobView: View {

    private enum Presentation: String, CaseIterable, Identifiable, Hashable {
        case rendered
        case raw

        var id: String { rawValue }
        var title: String {
            switch self {
            case .rendered: "Rendered"
            case .raw: "Source"
            }
        }
    }

    @Bindable private var model: OpenPawModel
    private let repo: String
    private let ref: String
    private let path: String
    private let focusLine: Int?
    private let budget: LineBudget
    private let sendPathToAgent: (String) -> Void

    @State private var blob: Blob?
    @State private var isLoading = false
    @State private var failure: String?
    @State private var presentation: Presentation = .rendered
    @State private var didCopyPath = false

    public init(
        model: OpenPawModel,
        repo: String,
        ref: String,
        path: String,
        focusLine: Int? = nil,
        budget: LineBudget = .blob,
        sendPathToAgent: @escaping (String) -> Void
    ) {
        self._model = Bindable(model)
        self.repo = repo
        self.ref = ref
        self.path = path
        self.focusLine = focusLine
        self.budget = budget
        self.sendPathToAgent = sendPathToAgent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(OpenPawTheme.line)
            content
        }
        .background(OpenPawTheme.ink)
        .navigationTitle(RepoPath.lastSegment(path))
        .task(id: BlobLoadKey(ref: ref, path: path)) { await load() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            Text(path)
                .font(OpenPawTheme.Machine.headline)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .textSelection(.enabled)

            HStack(spacing: OpenPawTheme.Space.large) {
                MonoField(label: "Ref", value: DiffModeCopy.shorten(ref))
                if let blob {
                    MonoField(label: "Type", value: blob.mime)
                    MonoField(label: "Size", value: RepoBytes.short(blob.bytes))
                }
            }

            HStack(spacing: OpenPawTheme.Space.small) {
                RepoActionButton(
                    title: didCopyPath ? "Path copied" : "Copy path",
                    glyph: didCopyPath ? "checkmark" : "doc.on.clipboard"
                ) {
                    OpenPawClipboard.copy(path)
                    didCopyPath = true
                }
                RepoActionButton(title: "Send path to the agent", glyph: "paperplane") {
                    sendPathToAgent(path)
                }
                if isMarkdown {
                    Picker("Presentation", selection: $presentation) {
                        ForEach(Presentation.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 190)
                    .accessibilityLabel("Showing the \(presentation.title.lowercased())")
                }
            }
        }
        .padding(.horizontal, OpenPawTheme.Space.large)
        .padding(.vertical, OpenPawTheme.Space.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenPawTheme.panel)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let failure {
            EmptyStateView(
                glyph: "exclamationmark.triangle",
                title: "The file did not load",
                message: failure,
                actionTitle: "Try again"
            ) {
                Task { await load() }
            }
        } else if let blob {
            switch blob.content {
            case .text(let text):
                textContent(blob: blob, text: text)
            case .binary(let sha256):
                binaryContent(blob: blob, sha256: sha256)
            }
        } else if isLoading {
            EmptyStateView(
                glyph: "doc.text",
                title: "Reading \(RepoPath.lastSegment(path))",
                message: "OpenPaw is fetching it from \(repo) at \(DiffModeCopy.shorten(ref))."
            )
        } else {
            EmptyStateView(
                glyph: "doc",
                title: "Nothing loaded yet",
                message: "Pull the file again to read it."
            )
        }
    }

    @ViewBuilder private func textContent(blob: Blob, text: String) -> some View {
        if isImageMime(blob.mime) {
            imageContent(blob: blob, data: Data(text.utf8), source: text)
        } else if isMarkdown, presentation == .rendered {
            markdownContent(text)
        } else {
            codeContent(blob: blob, text: text)
        }
    }

    private func codeContent(blob: Blob, text: String) -> some View {
        let window = BlobText.window(text, budget: budget, focusLine: focusLine)
        let highlight = focusLine.flatMap { line -> ClosedRange<Int>? in
            guard line >= window.firstLine, line < window.firstLine + window.shown else { return nil }
            return line...line
        }

        return VStack(alignment: .leading, spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                CodeBlock(
                    text: window.text,
                    language: SyntaxHighlighter.language(forPath: path),
                    showsLineNumbers: true,
                    firstLine: window.firstLine,
                    highlightedLines: highlight,
                    isCopyable: true
                )
                .padding(.vertical, OpenPawTheme.Space.small)
            }
            .background(OpenPawTheme.well)

            if let note = truncationNote(blob: blob, window: window) {
                truncationBanner(note)
            }
        }
    }

    private func markdownContent(_ source: String) -> some View {
        let window = BlobText.window(source, budget: budget)

        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                    ForEach(MarkdownRenderer.blocks(window.text)) { block in
                        MarkdownBlockView(block: block)
                    }
                    RepoActionButton(title: "Copy text", glyph: "doc.on.clipboard") {
                        OpenPawClipboard.copy(MarkdownRenderer.plainText(window.text))
                    }
                    .padding(.top, OpenPawTheme.Space.small)
                }
                .textSelection(.enabled)
                .padding(OpenPawTheme.Space.xl)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .background(OpenPawTheme.panelWarm)

            if let note = window.note {
                truncationBanner(note)
            }
        }
    }

    @ViewBuilder private func imageContent(blob: Blob, data: Data, source: String) -> some View {
        if let decoded = BlobImageDecoder.decode(data) {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                    decoded.image
                        .interpolation(.high)
                        .border(OpenPawTheme.line)
                        .accessibilityLabel("Image, \(decoded.sizeLabel)")
                    Text(decoded.sizeLabel).microLabel()
                }
                .padding(OpenPawTheme.Space.xl)
            }
            .background(OpenPawTheme.well)
        } else {
            // A vector or otherwise text-encoded image: the source is the truthful rendering of it.
            VStack(alignment: .leading, spacing: 0) {
                Panel(label: "Vector source") {
                    Text(
                        "\(blob.mime) is a text format. OpenPaw shows its source rather than rasterising it, "
                            + "so what you read is exactly what is in the repository."
                    )
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                }
                .padding(OpenPawTheme.Space.large)
                codeContent(blob: blob, text: source)
            }
        }
    }

    private func binaryContent(blob: Blob, sha256: String) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
            Panel(label: "Binary") {
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                    Text("This file is binary, so the host sent its digest instead of its bytes.")
                        .font(OpenPawTheme.Human.prose)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                    Text(
                        "OpenPaw never moves opaque bytes across the tunnel. The digest is enough to tell "
                            + "whether the file changed, and it costs 32 bytes instead of "
                            + "\(RepoBytes.short(blob.bytes))."
                    )
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textSecondary)

                    MonoField(label: "sha256", value: sha256, isCopyable: true)
                    MonoField(label: "Bytes", value: "\(blob.bytes)")
                    MonoField(label: "Type", value: blob.mime)

                    RepoActionButton(title: "Send path to the agent", glyph: "paperplane") {
                        sendPathToAgent(path)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(OpenPawTheme.Space.large)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func truncationBanner(_ note: String) -> some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            Image(systemName: "scissors").accessibilityHidden(true)
            Text(note)
        }
        .font(OpenPawTheme.Machine.codeSmall)
        .foregroundStyle(OpenPawTheme.warn)
        .padding(.horizontal, OpenPawTheme.Space.large)
        .padding(.vertical, OpenPawTheme.Space.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenPawTheme.panel)
    }

    /// The host can truncate too, and the two cuts mean different things: one is the tunnel, one is this screen.
    private func truncationNote(blob: Blob, window: BlobTextWindow) -> String? {
        switch (blob.truncated, window.note) {
        case (true, let note?):
            "\(note) The host also truncated this file before sending it."
        case (true, nil):
            "The host truncated this file before sending it. Open it on the host to read the rest."
        case (false, let note):
            note
        }
    }

    // MARK: Kinds

    private var isMarkdown: Bool {
        guard let blob else { return false }
        if blob.mime.hasPrefix("text/markdown") { return true }
        return SyntaxHighlighter.language(forPath: path) == .markdown
    }

    private func isImageMime(_ mime: String) -> Bool {
        mime.hasPrefix("image/")
    }

    // MARK: Loading

    private func load() async {
        guard let backend = model.backend else {
            failure = "No host is connected. Connect a host to read its files."
            return
        }
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            blob = try await backend.blob(repo: repo, ref: ref, path: path)
        } catch {
            model.present(error, while: "reading \(path)")
            failure = model.lastError?.detail ?? String(describing: error)
        }
    }
}

struct BlobLoadKey: Hashable, Sendable {
    let ref: String
    let path: String
}

// MARK: - Markdown blocks

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block.kind {
        case .thematicBreak:
            Divider().overlay(OpenPawTheme.line)

        case .codeBlock(let language):
            CodeBlock(
                text: String(block.text.characters),
                language: language.map { SyntaxHighlighter.language(forPath: "block.\($0)") } ?? .plain,
                showsLineNumbers: false,
                firstLine: 1,
                highlightedLines: nil,
                isCopyable: true
            )

        case .quote:
            HStack(alignment: .top, spacing: OpenPawTheme.Space.medium) {
                Rectangle()
                    .fill(OpenPawTheme.lineStrong)
                    .frame(width: OpenPawTheme.Space.hair)
                Text(block.text)
            }

        case .listItem(let ordinal, let depth):
            HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                Text(ordinal.map { "\($0)." } ?? "·")
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .accessibilityHidden(true)
                Text(block.text)
            }
            .padding(.leading, CGFloat(depth - 1) * OpenPawTheme.Space.large)

        case .heading(let level):
            Text(block.text)
                .padding(.top, level <= 2 ? OpenPawTheme.Space.medium : 0)

        case .paragraph:
            Text(block.text)
        }
    }
}

// MARK: - Preview

#Preview("Blob") {
    NavigationStack {
        BlobView(
            model: PreviewBackend.model(.populated),
            repo: "openpaw",
            ref: "HEAD",
            path: "README.md",
            sendPathToAgent: { _ in }
        )
    }
}
