import OpenPawTerminalCore
import SwiftUI

/// Terminal scrollback, rendered as text rather than as a terminal.
///
/// The live PTY surface is a platform view and cannot be snapshot-rendered headlessly, so this is what the
/// scrollback search screen uses and what the snapshot tool draws: real monospaced lines out of
/// `ScrollbackStore`, selectable, with search hits marked in place. It is a genuine renderer, not a stand-in —
/// scrollback search is a reading task, and reading is what this is good at.
public struct ScrollbackTextView: View {

    private enum Source {
        case snapshot(ScrollbackSnapshot)
        case store(ScrollbackStore)
    }

    private let source: Source
    private let index: ScrollbackMatchIndex
    /// The hit the view scrolls to and marks as current. Driving focus from outside keeps navigation
    /// ("next", "previous") with whoever owns the search, instead of hiding it in view state.
    private let focusedLine: Int?
    private let showsLineNumbers: Bool

    @State private var loaded: ScrollbackSnapshot?

    public init(
        snapshot: ScrollbackSnapshot,
        matches: [ScrollbackMatch] = [],
        focused: ScrollbackMatch? = nil,
        showsLineNumbers: Bool = false
    ) {
        source = .snapshot(snapshot)
        index = ScrollbackMatchIndex(matches)
        focusedLine = focused?.lineNumber
        self.showsLineNumbers = showsLineNumbers
    }

    public init(
        store: ScrollbackStore,
        matches: [ScrollbackMatch] = [],
        focused: ScrollbackMatch? = nil,
        showsLineNumbers: Bool = false
    ) {
        source = .store(store)
        index = ScrollbackMatchIndex(matches)
        focusedLine = focused?.lineNumber
        self.showsLineNumbers = showsLineNumbers
    }

    /// Row identity is the absolute line number, which is what makes jump-to-match exact: line numbers survive
    /// eviction from the head of the buffer, array offsets do not.
    public static func rowID(forLine lineNumber: Int) -> Int { lineNumber }

    private var snapshot: ScrollbackSnapshot? {
        switch source {
        case .snapshot(let value): return value
        case .store: return loaded
        }
    }

    public var body: some View {
        Group {
            if let snapshot, !snapshot.lines.isEmpty || !snapshot.partialLine.isEmpty {
                content(snapshot)
            } else if case .store = source, loaded == nil {
                // Not an empty buffer: the snapshot has not been read off the actor yet.
                WorkingIndicator(label: "scrollback")
                    .padding(OpenPawTheme.Space.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                EmptyStateView(
                    glyph: "terminal",
                    title: "No output yet",
                    message: "Everything this session prints is kept here, searchable, for as long as the "
                        + "buffer holds it."
                )
            }
        }
        .background(OpenPawTheme.well)
        .task {
            if case .store(let store) = source {
                loaded = await store.snapshot()
            }
        }
    }

    private func content(_ snapshot: ScrollbackSnapshot) -> some View {
        let numberWidth = max(3, String(snapshot.firstLineNumber + snapshot.lines.count).count)

        return ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(snapshot.lines.enumerated()), id: \.offset) { offset, line in
                        let lineNumber = snapshot.firstLineNumber + offset
                        row(lineNumber: lineNumber, line: line, numberWidth: numberWidth)
                            .id(Self.rowID(forLine: lineNumber))
                    }
                    // The line still being written. `ScrollbackStore.search` covers it, so leaving it out would
                    // let a hit on the newest output have nowhere to land.
                    if !snapshot.partialLine.isEmpty {
                        let lineNumber = snapshot.firstLineNumber + snapshot.lines.count
                        row(lineNumber: lineNumber, line: snapshot.partialLine, numberWidth: numberWidth)
                            .id(Self.rowID(forLine: lineNumber))
                    }
                }
                .padding(.vertical, OpenPawTheme.Space.small)
                .padding(.horizontal, OpenPawTheme.Space.medium)
            }
            .onAppear { scroll(proxy) }
            .onChange(of: focusedLine) { scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let focusedLine else { return }
        // `.center` would centre on *both* axes, which drags a long line sideways and takes the line-number
        // gutter off screen with it. Vertically centred, horizontally pinned to the start of the line.
        // No animation either: the app's motion budget is spent, and a jump to a hit is not one of the two.
        proxy.scrollTo(Self.rowID(forLine: focusedLine), anchor: UnitPoint(x: 0, y: 0.5))
    }

    private func row(lineNumber: Int, line: String, numberWidth: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.medium) {
            if showsLineNumbers {
                // `ZStack`, not `overlay`, for the same reason as CodeBlock: an overlay inherits its host's
                // measured width and a four-digit line number then wraps or spills out of the gutter.
                ZStack(alignment: .trailing) {
                    Text(String(repeating: "0", count: numberWidth))
                        .font(OpenPawTheme.Machine.codeSmall)
                        .monospacedDigit()
                        .hidden()
                    Text(String(lineNumber))
                        .font(OpenPawTheme.Machine.codeSmall)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(OpenPawTheme.diffGutter)
                }
                .accessibilityHidden(true)
            }

            Text(marked(line: line, lineNumber: lineNumber))
                .font(OpenPawTheme.Machine.code)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
        }
    }

    /// Applies every hit on this line, with the focused one marked twice over — a stronger fill *and* an
    /// underline — so "which one am I on" does not depend on telling two tints apart.
    private func marked(line: String, lineNumber: Int) -> AttributedString {
        var attributed = AttributedString(line)
        let hits = index.matches(onLine: lineNumber)
        guard !hits.isEmpty else { return attributed }

        let isFocusedLine = focusedLine == lineNumber
        for hit in hits {
            guard let range = ScrollbackMatchIndex.characterRange(of: hit, in: line),
                let lower = attributed.index(
                    attributed.startIndex,
                    offsetByCharacters: line.distance(from: line.startIndex, to: range.lowerBound)
                ) as AttributedString.Index?,
                let upper = attributed.index(
                    attributed.startIndex,
                    offsetByCharacters: line.distance(from: line.startIndex, to: range.upperBound)
                ) as AttributedString.Index?,
                lower < upper
            else { continue }

            attributed[lower..<upper].backgroundColor =
                isFocusedLine ? SyntaxPalette.machine.type.opacity(0.45) : OpenPawTheme.lineStrong
            if isFocusedLine {
                attributed[lower..<upper].underlineStyle = .single
            }
        }
        return attributed
    }
}

// MARK: - Match model

/// Search hits, grouped by the line they fall on.
///
/// Rendering asks "what is on this line" once per visible row, so the grouping is built once up front rather than
/// filtered per row — the difference between linear and quadratic on a buffer with thousands of hits. It also owns
/// the ordering, which is what "next match" and "3 of 12" are made of.
public struct ScrollbackMatchIndex: Sendable {
    public let matches: [ScrollbackMatch]
    private let byLine: [Int: [ScrollbackMatch]]

    public init(_ matches: [ScrollbackMatch] = []) {
        let ordered = matches.sorted {
            ($0.lineNumber, $0.byteRange.lowerBound) < ($1.lineNumber, $1.byteRange.lowerBound)
        }
        self.matches = ordered
        self.byLine = Dictionary(grouping: ordered, by: \.lineNumber)
    }

    public var count: Int { matches.count }
    public var isEmpty: Bool { matches.isEmpty }
    public var first: ScrollbackMatch? { matches.first }

    /// Every hit that falls on `lineNumber`, in the order they appear along the line.
    public func matches(onLine lineNumber: Int) -> [ScrollbackMatch] {
        byLine[lineNumber] ?? []
    }

    /// One-based position in the whole result set, for "3 of 12".
    public func ordinal(of match: ScrollbackMatch) -> Int? {
        matches.firstIndex(where: { Self.isSame($0, match) }).map { $0 + 1 }
    }

    public func match(atOrdinal ordinal: Int) -> ScrollbackMatch? {
        let position = ordinal - 1
        guard matches.indices.contains(position) else { return nil }
        return matches[position]
    }

    /// Wraps at the end, because a search that stops at the last hit makes the user scroll back by hand.
    public func next(after match: ScrollbackMatch?) -> ScrollbackMatch? {
        guard !matches.isEmpty else { return nil }
        guard let match, let position = matches.firstIndex(where: { Self.isSame($0, match) }) else {
            return matches.first
        }
        return matches[(position + 1) % matches.count]
    }

    public func previous(before match: ScrollbackMatch?) -> ScrollbackMatch? {
        guard !matches.isEmpty else { return nil }
        guard let match, let position = matches.firstIndex(where: { Self.isSame($0, match) }) else {
            return matches.last
        }
        return matches[(position - 1 + matches.count) % matches.count]
    }

    /// Converts a match's UTF-8 byte range into a `String` range on the given line.
    ///
    /// The store reports byte offsets because that is what a byte-oriented buffer search produces; SwiftUI needs
    /// character indices. Doing the conversion here, on values, is what makes it testable — and returning `nil`
    /// rather than trapping means a match whose line has since been rewritten simply does not highlight.
    public static func characterRange(of match: ScrollbackMatch, in line: String) -> Range<String.Index>? {
        let bytes = line.utf8
        // `Range` already guarantees lower <= upper, so only a negative offset needs checking — walking a
        // `String.UTF8View` backwards past its start traps, and `limitedBy:` does not catch that.
        guard match.byteRange.lowerBound >= 0,
            let lowerByte = bytes.index(
                bytes.startIndex, offsetBy: match.byteRange.lowerBound, limitedBy: bytes.endIndex
            ),
            let upperByte = bytes.index(
                bytes.startIndex, offsetBy: match.byteRange.upperBound, limitedBy: bytes.endIndex
            ),
            // Both ends must land on a character boundary; a range that splits a grapheme is not renderable.
            let lower = String.Index(lowerByte, within: line),
            let upper = String.Index(upperByte, within: line)
        else { return nil }
        return lower..<upper
    }

    /// Identity is *position*, not content: a line whose text has since been rewritten is still the same hit, so
    /// comparing `line` too would silently break "next match" on a live buffer.
    private static func isSame(_ lhs: ScrollbackMatch, _ rhs: ScrollbackMatch) -> Bool {
        lhs.lineNumber == rhs.lineNumber && lhs.byteRange == rhs.byteRange
    }
}
