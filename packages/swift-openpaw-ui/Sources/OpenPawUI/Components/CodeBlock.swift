import SwiftUI

/// Source, output, or a command, in the recessed `well` surface.
///
/// It scrolls horizontally and never wraps. Wrapping code is a small mercy that costs a large one: once a long
/// line folds, indentation stops meaning depth and a diff stops being scannable. Line numbers are opt-in because
/// a one-line command does not need them and a file does.
///
/// Highlighting runs over the whole text once rather than line by line, so a block comment or a triple-quoted
/// string that spans lines is coloured correctly instead of resetting at every newline.
public struct CodeBlock: View {
    private let text: String
    private let language: SyntaxLanguage
    private let showsLineNumbers: Bool
    private let firstLine: Int
    private let highlightedLines: ClosedRange<Int>?
    private let isCopyable: Bool

    public init(
        text: String,
        language: SyntaxLanguage = .plain,
        showsLineNumbers: Bool = false,
        firstLine: Int = 1,
        highlightedLines: ClosedRange<Int>? = nil,
        isCopyable: Bool = true
    ) {
        self.text = text
        self.language = language
        self.showsLineNumbers = showsLineNumbers
        self.firstLine = firstLine
        self.highlightedLines = highlightedLines
        self.isCopyable = isCopyable
    }

    private var lines: [AttributedString] {
        Self.highlightedLines(of: text, language: language)
    }

    /// Widest line number, so the gutter is one column wide for the whole block.
    private var numberDigits: Int {
        max(2, String(firstLine + max(0, lines.count - 1)).count)
    }

    public var body: some View {
        // The copy control gets its own column rather than an overlay. As an overlay it sat on top of the code
        // and any line wider than the block disappeared under the glyph at scroll offset zero — reserving
        // trailing padding inside the scroll content only helped once you had already scrolled to the end.
        HStack(alignment: .top, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                        row(offset: offset, line: line)
                    }
                }
                .padding(.vertical, OpenPawTheme.Space.small)
                .padding(.horizontal, OpenPawTheme.Space.medium)
            }

            if isCopyable {
                // A hairline marks the column as chrome rather than content, the same way panels do.
                Rectangle()
                    .fill(OpenPawTheme.line)
                    .frame(width: OpenPawTheme.hairline * 3)
                CopyButton(text: text)
            }
        }
        .background(OpenPawTheme.well)
        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous))
    }

    private func row(offset: Int, line: AttributedString) -> some View {
        let number = firstLine + offset
        let isHighlighted = highlightedLines?.contains(number) ?? false

        return HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.medium) {
            if showsLineNumbers {
                // `ZStack`, not `overlay`: an overlay is offered exactly its host's measured size, so the
                // number wraps or overflows as soon as text layout rounds the two differently. Here the hidden
                // zeroes reserve the column and the number sizes itself.
                ZStack(alignment: .trailing) {
                    Text(String(repeating: "0", count: numberDigits))
                        .font(OpenPawTheme.Machine.codeSmall)
                        .monospacedDigit()
                        .hidden()
                    Text(String(number))
                        .font(OpenPawTheme.Machine.codeSmall)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(OpenPawTheme.diffGutter)
                }
                .accessibilityHidden(true)
            }

            Text(line)
                .font(OpenPawTheme.Machine.code)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
        .background(alignment: .leading) {
            if isHighlighted {
                // A fill plus a leading bar: the highlight survives greyscale and a dimmed screen.
                ZStack(alignment: .leading) {
                    OpenPawTheme.panel
                    Rectangle().fill(OpenPawTheme.lineStrong).frame(width: 2)
                }
            }
        }
    }

    // MARK: Line splitting

    /// Splits the highlighter's runs into one `AttributedString` per line. Linear in the input: each run is walked
    /// once and cut at its newlines.
    static func highlightedLines(of text: String, language: SyntaxLanguage) -> [AttributedString] {
        var lines: [AttributedString] = []
        var current = AttributedString()

        func append(_ piece: Substring, _ token: SyntaxToken) {
            guard !piece.isEmpty else { return }
            var styled = AttributedString(String(piece))
            styled.foregroundColor = token.color()
            current.append(styled)
        }

        for run in SyntaxHighlighter.runs(text, language: language) {
            var cursor = run.text.startIndex
            while let newline = run.text[cursor...].firstIndex(of: "\n") {
                append(run.text[cursor..<newline], run.token)
                lines.append(current)
                current = AttributedString()
                cursor = run.text.index(after: newline)
            }
            append(run.text[cursor...], run.token)
        }
        // A trailing newline ends the last line rather than starting an empty one.
        if !current.characters.isEmpty || lines.isEmpty {
            lines.append(current)
        }
        return lines
    }
}

// MARK: - Copy

/// Quiet, out of the way, and 44 pt of tappable area regardless of how small the glyph looks.
private struct CopyButton: View {
    let text: String

    @State private var didCopy = false

    var body: some View {
        Button {
            OpenPawClipboard.copy(text)
            didCopy = true
        } label: {
            Group {
                if didCopy {
                    Text("copied").microLabel(OpenPawTheme.ok)
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OpenPawTheme.textTertiary)
                }
            }
            .padding(.horizontal, OpenPawTheme.Space.small)
            .frame(minWidth: 44, minHeight: 44)
            // No backing fill: it existed only to obscure the code this button used to sit on top of.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(didCopy ? "Copied" : "Copy")
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .milliseconds(1_500))
            didCopy = false
        }
    }
}

#Preview("Code") {
    ScrollView {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
            CodeBlock(text: PreviewFixtures.destructiveCommand, language: .shell)

            CodeBlock(
                text: PreviewFixtures.pythonBlob,
                language: .python,
                showsLineNumbers: true,
                firstLine: 1,
                highlightedLines: 17...18
            )

            CodeBlock(
                text: """
                    struct Seal: View {
                        // Hatched until the detail is opened.
                        let risk: Risk
                        var body: some View {
                            Text("sealed \\(risk.reasons.count) reasons")
                        }
                    }
                    """,
                language: .swift,
                showsLineNumbers: true
            )
        }
        .padding(OpenPawTheme.Space.large)
    }
    .background(OpenPawTheme.ink)
}
