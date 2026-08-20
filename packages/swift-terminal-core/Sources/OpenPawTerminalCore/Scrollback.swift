import Foundation

/// One hit from a scrollback search.
public struct ScrollbackMatch: Sendable, Hashable {
    /// Absolute, 1-based line number. Stays stable as older lines are evicted.
    public let lineNumber: Int
    /// The full line the match was found in.
    public let line: String
    /// UTF-8 byte offsets of the match inside ``line``.
    public let byteRange: Range<Int>

    public init(lineNumber: Int, line: String, byteRange: Range<Int>) {
        self.lineNumber = lineNumber
        self.line = line
        self.byteRange = byteRange
    }

    /// Converts ``byteRange`` into a `String` range for attributed rendering.
    public func range(in text: String) -> Range<String.Index>? {
        let utf8 = text.utf8
        guard byteRange.lowerBound >= 0, byteRange.upperBound <= utf8.count else { return nil }
        let lowerUTF8 = utf8.index(utf8.startIndex, offsetBy: byteRange.lowerBound)
        let upperUTF8 = utf8.index(lowerUTF8, offsetBy: byteRange.count)
        guard let lower = String.Index(lowerUTF8, within: text),
            let upper = String.Index(upperUTF8, within: text)
        else { return nil }
        return lower..<upper
    }
}

/// An immutable view of the scrollback, safe to hand to a synchronous renderer.
public struct ScrollbackSnapshot: Sendable, Hashable {
    /// Absolute number of ``lines`` element 0.
    public let firstLineNumber: Int
    /// Completed lines, oldest first.
    public let lines: [String]
    /// The line currently being written (no newline seen yet).
    public let partialLine: String

    public init(firstLineNumber: Int, lines: [String], partialLine: String) {
        self.firstLineNumber = firstLineNumber
        self.lines = lines
        self.partialLine = partialLine
    }

    public var lineCount: Int { lines.count }

    /// Looks a line up by absolute number.
    public func line(at number: Int) -> String? {
        let index = number - firstLineNumber
        guard index >= 0, index < lines.count else { return nil }
        return lines[index]
    }
}

/// A byte-budgeted ring of terminal output lines.
///
/// Raw PTY chunks arrive without respecting line or UTF-8 boundaries, so bytes
/// are buffered until a newline is seen and only then decoded. Carriage returns
/// move a write cursor back to column zero, which makes progress bars
/// (`50%\r75%\r100%`) collapse into a single line exactly as a terminal shows
/// them.
public actor ScrollbackStore {
    public static let defaultByteBudget = 4 * 1024 * 1024

    private struct Stored {
        let text: String
        /// Line bytes plus the newline it stands for.
        let byteCount: Int
    }

    private let byteBudget: Int
    private var stored: [Stored] = []
    private var storedBytes = 0
    private var firstLineNumber = 1
    private var currentBytes: [UInt8] = []
    private var cursor = 0
    /// A CR seen at the very end of a chunk: its effect depends on the next byte.
    private var pendingCarriageReturn = false

    public init(byteBudget: Int = ScrollbackStore.defaultByteBudget) {
        self.byteBudget = max(1, byteBudget)
    }

    // MARK: Ingest

    public func append(_ data: Data) {
        for byte in data {
            if pendingCarriageReturn {
                pendingCarriageReturn = false
                if byte == 0x0A {
                    finalizeLine()
                    continue
                }
                cursor = 0
            }
            switch byte {
            case 0x0A:
                finalizeLine()
            case 0x0D:
                pendingCarriageReturn = true
            default:
                write(byte)
            }
        }
    }

    private func write(_ byte: UInt8) {
        if cursor < currentBytes.count {
            currentBytes[cursor] = byte
        } else {
            currentBytes.append(byte)
        }
        cursor += 1
    }

    private func finalizeLine() {
        let text = String(decoding: currentBytes, as: UTF8.self)
        stored.append(Stored(text: text, byteCount: currentBytes.count + 1))
        storedBytes += currentBytes.count + 1
        currentBytes.removeAll(keepingCapacity: true)
        cursor = 0
        evict()
    }

    private func evict() {
        guard storedBytes > byteBudget else { return }
        var dropped = 0
        var freed = 0
        while storedBytes - freed > byteBudget, dropped < stored.count {
            freed += stored[dropped].byteCount
            dropped += 1
        }
        guard dropped > 0 else { return }
        stored.removeFirst(dropped)
        storedBytes -= freed
        firstLineNumber += dropped
    }

    // MARK: Read

    /// Number of completed lines currently retained.
    public var lineCount: Int { stored.count }

    /// Retained bytes, counting one byte per elided newline.
    public var byteCount: Int { storedBytes }

    /// Absolute number of the oldest retained line.
    public var oldestLineNumber: Int { firstLineNumber }

    /// Absolute number the next completed line will get.
    public var nextLineNumber: Int { firstLineNumber + stored.count }

    public var lines: [String] { stored.map(\.text) }

    /// The line being written, decoded as-is.
    public var partialLine: String { String(decoding: currentBytes, as: UTF8.self) }

    /// Looks a completed line up by absolute number.
    public func line(at number: Int) -> String? {
        let index = number - firstLineNumber
        guard index >= 0, index < stored.count else { return nil }
        return stored[index].text
    }

    public func snapshot() -> ScrollbackSnapshot {
        ScrollbackSnapshot(
            firstLineNumber: firstLineNumber,
            lines: stored.map(\.text),
            partialLine: partialLine
        )
    }

    /// Drops everything retained. Line numbering continues where it left off so
    /// search results taken before the clear cannot alias new lines.
    public func clear() {
        firstLineNumber += stored.count
        stored.removeAll()
        storedBytes = 0
        currentBytes.removeAll()
        cursor = 0
        pendingCarriageReturn = false
    }

    // MARK: Search

    /// All occurrences of `query`, oldest line first, in order within a line.
    /// The in-progress line is searched too so a live match is not missed.
    public func search(_ query: String, caseSensitive: Bool = false) -> [ScrollbackMatch] {
        guard !query.isEmpty else { return [] }
        var results: [ScrollbackMatch] = []
        for (offset, entry) in stored.enumerated() {
            results.append(
                contentsOf: Self.matches(
                    in: entry.text, query: query, caseSensitive: caseSensitive,
                    lineNumber: firstLineNumber + offset))
        }
        let partial = partialLine
        if !partial.isEmpty {
            results.append(
                contentsOf: Self.matches(
                    in: partial, query: query, caseSensitive: caseSensitive,
                    lineNumber: firstLineNumber + stored.count))
        }
        return results
    }

    private static func matches(
        in line: String, query: String, caseSensitive: Bool, lineNumber: Int
    ) -> [ScrollbackMatch] {
        var results: [ScrollbackMatch] = []
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var searchStart = line.startIndex
        while searchStart < line.endIndex,
            let found = line.range(of: query, options: options, range: searchStart..<line.endIndex)
        {
            let lower = line.utf8.distance(from: line.startIndex, to: found.lowerBound)
            let upper = line.utf8.distance(from: line.startIndex, to: found.upperBound)
            results.append(
                ScrollbackMatch(lineNumber: lineNumber, line: line, byteRange: lower..<upper))
            searchStart =
                found.upperBound > found.lowerBound
                ? found.upperBound : line.index(after: found.lowerBound)
        }
        return results
    }

    // MARK: Export

    /// The retained scrollback as it would look in a file: every completed line
    /// newline-terminated, then any in-progress line.
    public func export() -> Data {
        var data = Data()
        data.reserveCapacity(storedBytes + currentBytes.count)
        for entry in stored {
            data.append(contentsOf: Array(entry.text.utf8))
            data.append(0x0A)
        }
        data.append(contentsOf: currentBytes)
        return data
    }
}
