import Foundation

// MARK: - OSC 52 (clipboard)

public enum ClipboardSelection: String, Sendable, Hashable, Codable, CaseIterable {
    case clipboard = "c"
    case primary = "p"
    case secondary = "q"
    case select = "s"
}

public enum OSC52Terminator: Sendable, Hashable, CaseIterable {
    /// `BEL`, the form xterm documents first and tmux emits.
    case bel
    /// `ESC \`, the ANSI string terminator; required by some terminals.
    case st

    public var text: String {
        switch self {
        case .bel: return "\u{07}"
        case .st: return "\u{1b}\\"
        }
    }
}

public struct ClipboardPayload: Sendable, Hashable {
    public var selection: ClipboardSelection
    public var data: Data

    public init(selection: ClipboardSelection, data: Data) {
        self.selection = selection
        self.data = data
    }

    /// UTF-8 interpretation of ``data``, repairing invalid sequences.
    public var text: String { String(decoding: data, as: UTF8.self) }
}

/// A decoded OSC 52 sequence.
public enum OSC52Command: Sendable, Hashable {
    case set(ClipboardPayload)
    /// `OSC 52 ; <sel> ; ? ST` — the host asking the terminal for the clipboard.
    case query(ClipboardSelection)
}

public enum ClipboardError: Error, Sendable, Hashable, CustomStringConvertible {
    case payloadTooLarge(bytes: Int, limit: Int)
    case malformedSequence(String)
    case invalidBase64
    case unsupportedSelection(String)

    public var description: String {
        switch self {
        case .payloadTooLarge(let bytes, let limit):
            return "clipboard payload of \(bytes) bytes exceeds the \(limit) byte limit"
        case .malformedSequence(let detail):
            return "malformed OSC 52 sequence (\(detail))"
        case .invalidBase64:
            return "clipboard payload is not valid base64"
        case .unsupportedSelection(let raw):
            return "unsupported clipboard selection `\(raw)`"
        }
    }
}

public enum OSC52 {
    /// Default cap. Terminals commonly refuse far less; 100 kB keeps a code
    /// paste working while making a rogue agent unable to stuff the pasteboard.
    public static let defaultByteLimit = 100_000

    private static let introducer = "\u{1b}]52;"

    /// Builds the escape sequence that puts `data` on the device clipboard.
    public static func encode(
        _ data: Data,
        selection: ClipboardSelection = .clipboard,
        terminator: OSC52Terminator = .bel,
        limit: Int = OSC52.defaultByteLimit
    ) throws -> String {
        guard data.count <= limit else {
            throw ClipboardError.payloadTooLarge(bytes: data.count, limit: limit)
        }
        return introducer + selection.rawValue + ";" + data.base64EncodedString()
            + terminator.text
    }

    /// Decodes the first OSC 52 sequence in `text`, or `nil` when there is none.
    public static func decode(_ text: String, limit: Int = OSC52.defaultByteLimit) throws
        -> OSC52Command?
    {
        guard let start = text.range(of: introducer) else { return nil }
        let body = text[start.upperBound...]

        var payload = ""
        var terminated = false
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if character == "\u{07}" {
                terminated = true
                break
            }
            if character == "\u{1b}" {
                let next = body.index(after: index)
                guard next < body.endIndex, body[next] == "\\" else {
                    throw ClipboardError.malformedSequence("ESC not followed by `\\`")
                }
                terminated = true
                break
            }
            payload.append(character)
            index = body.index(after: index)
        }
        guard terminated else {
            throw ClipboardError.malformedSequence("unterminated sequence")
        }

        guard let separator = payload.firstIndex(of: ";") else {
            throw ClipboardError.malformedSequence("missing `;` between selection and payload")
        }
        let selectionRaw = String(payload[payload.startIndex..<separator])
        let encoded = String(payload[payload.index(after: separator)...])

        // An empty selection means the xterm default, `s0`, which resolves to
        // the clipboard for our purposes. Multi-character forms use the first.
        let selection: ClipboardSelection
        if selectionRaw.isEmpty {
            selection = .clipboard
        } else if let first = selectionRaw.first,
            let parsed = ClipboardSelection(rawValue: String(first))
        {
            selection = parsed
        } else {
            throw ClipboardError.unsupportedSelection(selectionRaw)
        }

        if encoded == "?" { return .query(selection) }

        // 4 base64 characters carry 3 bytes, less the padding: reject an
        // oversized payload before allocating a buffer for it.
        let padding = encoded.suffix(2).filter { $0 == "=" }.count
        let approximateBytes = max(0, (encoded.count / 4) * 3 - padding)
        guard approximateBytes <= limit else {
            throw ClipboardError.payloadTooLarge(bytes: approximateBytes, limit: limit)
        }
        guard let data = decodeBase64(encoded) else { throw ClipboardError.invalidBase64 }
        guard data.count <= limit else {
            throw ClipboardError.payloadTooLarge(bytes: data.count, limit: limit)
        }
        return .set(ClipboardPayload(selection: selection, data: data))
    }

    /// Tolerates the unpadded base64 some emitters produce.
    private static func decodeBase64(_ encoded: String) -> Data? {
        if let data = Data(base64Encoded: encoded) { return data }
        let remainder = encoded.count % 4
        guard remainder != 0 else { return nil }
        let padded = encoded + String(repeating: "=", count: 4 - remainder)
        return Data(base64Encoded: padded)
    }
}

// MARK: - OSC 8 (hyperlinks)

/// A hyperlink discovered in terminal output.
public struct Hyperlink: Sendable, Hashable {
    public var url: String
    /// The visible label.
    public var text: String
    /// Character offsets of ``text`` inside ``HyperlinkScan/text``.
    public var range: Range<Int>
    /// The `id=` parameter, when the emitter supplied one.
    public var id: String?

    public init(url: String, text: String, range: Range<Int>, id: String? = nil) {
        self.url = url
        self.text = text
        self.range = range
        self.id = id
    }
}

public struct HyperlinkScan: Sendable, Hashable {
    /// The input with every OSC 8 escape removed.
    public var text: String
    public var links: [Hyperlink]

    public init(text: String, links: [Hyperlink]) {
        self.text = text
        self.links = links
    }
}

public enum OSC8 {
    /// Strips OSC 8 hyperlink escapes and reports where each link's label ended
    /// up, so the UI can make the label tappable.
    ///
    /// Shape: `ESC ] 8 ; params ; URI (BEL|ST) label ESC ] 8 ; ; (BEL|ST)`.
    public static func parse(_ input: String) -> HyperlinkScan {
        let characters = Array(input)
        var visible: [Character] = []
        var links: [Hyperlink] = []
        var open: (url: String, id: String?, start: Int)?
        var index = 0

        func closeLink(at end: Int) {
            guard let pending = open else { return }
            open = nil
            let label = String(visible[pending.start..<end])
            links.append(
                Hyperlink(url: pending.url, text: label, range: pending.start..<end, id: pending.id)
            )
        }

        while index < characters.count {
            if characters[index] == "\u{1b}", matches(characters, at: index, "\u{1b}]8;") {
                var cursor = index + 4
                var body: [Character] = []
                var terminated = false
                while cursor < characters.count {
                    if characters[cursor] == "\u{07}" {
                        cursor += 1
                        terminated = true
                        break
                    }
                    if characters[cursor] == "\u{1b}", cursor + 1 < characters.count,
                        characters[cursor + 1] == "\\"
                    {
                        cursor += 2
                        terminated = true
                        break
                    }
                    body.append(characters[cursor])
                    cursor += 1
                }
                guard terminated else {
                    // Unterminated introducer: emit it literally rather than
                    // swallowing the rest of the line.
                    visible.append(characters[index])
                    index += 1
                    continue
                }
                let text = String(body)
                let split = text.firstIndex(of: ";")
                let params = split.map { String(text[text.startIndex..<$0]) } ?? ""
                let uri = split.map { String(text[text.index(after: $0)...]) } ?? ""
                closeLink(at: visible.count)
                if !uri.isEmpty {
                    open = (url: uri, id: identifier(in: params), start: visible.count)
                }
                index = cursor
                continue
            }
            visible.append(characters[index])
            index += 1
        }
        closeLink(at: visible.count)
        return HyperlinkScan(text: String(visible), links: links)
    }

    private static func matches(_ characters: [Character], at index: Int, _ needle: String) -> Bool
    {
        let needleCharacters = Array(needle)
        guard index + needleCharacters.count <= characters.count else { return false }
        for offset in 0..<needleCharacters.count
        where characters[index + offset] != needleCharacters[offset] {
            return false
        }
        return true
    }

    /// `id=abc:key=value` → `abc`.
    private static func identifier(in params: String) -> String? {
        for pair in params.split(separator: ":") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0] == "id", !parts[1].isEmpty {
                return String(parts[1])
            }
        }
        return nil
    }
}
