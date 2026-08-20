import Foundation

// MARK: - Modifiers

public struct KeyModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    /// Option on Apple keyboards, Alt elsewhere. Transmitted as an ESC prefix.
    public static let alt = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    /// Never transmitted to the PTY; reserved for app level shortcuts.
    public static let command = KeyModifiers(rawValue: 1 << 3)

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// xterm's `modifyOtherKeys` parameter: 1 + shift(1) + alt(2) + control(4).
    var xtermParameter: Int {
        var value = 1
        if contains(.shift) { value += 1 }
        if contains(.alt) { value += 2 }
        if contains(.control) { value += 4 }
        return value
    }

    var identifiers: [String] {
        var parts: [String] = []
        if contains(.control) { parts.append("ctrl") }
        if contains(.alt) { parts.append("alt") }
        if contains(.shift) { parts.append("shift") }
        if contains(.command) { parts.append("cmd") }
        return parts
    }

    static func parse(_ token: String) -> KeyModifiers? {
        switch token.lowercased() {
        case "ctrl", "control", "^": return .control
        case "alt", "opt", "option", "meta": return .alt
        case "shift": return .shift
        case "cmd", "command", "super": return .command
        default: return nil
        }
    }
}

// MARK: - Keys

/// A key the on-screen terminal toolbar can send.
public enum TerminalKey: Sendable, Hashable {
    /// Literal characters (letters, `|`, `/`, whole words).
    case text(String)
    case escape
    case tab
    case backspace
    case delete
    case enter
    case space
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case insert
    /// F1 through F12.
    case function(Int)

    /// Stable identifier used in the shortcut JSON and in `KeyChord` strings.
    public var identifier: String {
        switch self {
        case .text(let value): return value
        case .escape: return "esc"
        case .tab: return "tab"
        case .backspace: return "backspace"
        case .delete: return "delete"
        case .enter: return "enter"
        case .space: return "space"
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "pgup"
        case .pageDown: return "pgdn"
        case .insert: return "insert"
        case .function(let number): return "f\(number)"
        }
    }

    public init?(identifier: String) {
        guard !identifier.isEmpty else { return nil }
        switch identifier.lowercased() {
        case "esc", "escape": self = .escape
        case "tab": self = .tab
        case "backspace", "bs": self = .backspace
        case "delete", "del": self = .delete
        case "enter", "return", "cr": self = .enter
        case "space", "spc": self = .space
        case "up": self = .up
        case "down": self = .down
        case "left": self = .left
        case "right": self = .right
        case "home": self = .home
        case "end": self = .end
        case "pgup", "pageup": self = .pageUp
        case "pgdn", "pagedown": self = .pageDown
        case "insert", "ins": self = .insert
        default:
            let lowered = identifier.lowercased()
            if lowered.first == "f", let number = Int(lowered.dropFirst()), (1...12).contains(number) {
                self = .function(number)
            } else {
                self = .text(identifier)
            }
        }
    }
}

extension TerminalKey: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let key = TerminalKey(identifier: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "empty key identifier"))
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(identifier)
    }
}

/// A modifier combination plus a key, e.g. `ctrl+c`, `alt+left`, `shift+f5`.
public struct KeyChord: Sendable, Hashable, CustomStringConvertible {
    public var modifiers: KeyModifiers
    public var key: TerminalKey

    public init(_ key: TerminalKey, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public var description: String {
        (modifiers.identifiers + [key.identifier]).joined(separator: "+")
    }

    /// Parses `ctrl+alt+f5`. A trailing `+` means the literal `+` key.
    public init?(parsing text: String) {
        guard !text.isEmpty else { return nil }
        var tokens = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if tokens.count > 1, tokens.last == "" {
            tokens.removeLast()
            tokens[tokens.count - 1] = "+"
        }
        guard let last = tokens.popLast(), let key = TerminalKey(identifier: last) else {
            return nil
        }
        var modifiers: KeyModifiers = []
        for token in tokens {
            guard let modifier = KeyModifiers.parse(token) else { return nil }
            modifiers.insert(modifier)
        }
        self.init(key, modifiers: modifiers)
    }
}

extension KeyChord: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let chord = KeyChord(parsing: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid key chord \(raw)"))
        }
        self = chord
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - Byte generation

private let esc: UInt8 = 0x1b

private func csi(_ body: String) -> [UInt8] {
    [esc, UInt8(ascii: "[")] + Array(body.utf8)
}

private func ss3(_ body: String) -> [UInt8] {
    [esc, UInt8(ascii: "O")] + Array(body.utf8)
}

/// Control byte for `ctrl+<character>` per the VT/ASCII caret notation.
private func controlByte(for character: Character) -> UInt8? {
    guard let ascii = character.asciiValue else { return nil }
    switch ascii {
    case UInt8(ascii: "a")...UInt8(ascii: "z"):
        return ascii - UInt8(ascii: "a") + 1
    case UInt8(ascii: "A")...UInt8(ascii: "Z"):
        return ascii - UInt8(ascii: "A") + 1
    default:
        switch character {
        case "@", " ", "2": return 0x00
        case "[", "3": return 0x1b
        case "\\", "4": return 0x1c
        case "]", "5": return 0x1d
        case "^", "6": return 0x1e
        case "_", "7", "-": return 0x1f
        case "?", "8": return 0x7f
        default: return nil
        }
    }
}

/// Encodes a chord into the exact byte sequence to write to the PTY.
///
/// `applicationCursorKeys` reflects DECCKM (set by `smkx`, which full screen
/// programs like vim and less enable): cursor and Home/End keys then use SS3
/// instead of CSI. Modified cursor keys always use the CSI form with an xterm
/// modifier parameter, in both modes, which is what xterm itself does.
public func bytes(for chord: KeyChord, applicationCursorKeys: Bool = false) -> [UInt8] {
    let modifiers = chord.modifiers
    let parameter = modifiers.xtermParameter
    let modified = parameter > 1

    func cursor(_ final: String) -> [UInt8] {
        if modified { return csi("1;\(parameter)\(final)") }
        return applicationCursorKeys ? ss3(final) : csi(final)
    }

    func tilde(_ code: Int) -> [UInt8] {
        modified ? csi("\(code);\(parameter)~") : csi("\(code)~")
    }

    /// ESC prefix for keys whose modified form is not a CSI parameter.
    func altPrefixed(_ payload: [UInt8]) -> [UInt8] {
        modifiers.contains(.alt) ? [esc] + payload : payload
    }

    switch chord.key {
    case .up: return cursor("A")
    case .down: return cursor("B")
    case .right: return cursor("C")
    case .left: return cursor("D")
    case .home: return cursor("H")
    case .end: return cursor("F")
    case .insert: return tilde(2)
    case .delete: return tilde(3)
    case .pageUp: return tilde(5)
    case .pageDown: return tilde(6)

    case .function(let number):
        switch number {
        case 1...4:
            let final = ["P", "Q", "R", "S"][number - 1]
            return modified ? csi("1;\(parameter)\(final)") : ss3(final)
        case 5...12:
            let codes = [15, 17, 18, 19, 20, 21, 23, 24]
            return tilde(codes[number - 5])
        default:
            return []
        }

    case .tab:
        if modifiers.contains(.shift) { return csi("Z") }
        return altPrefixed([0x09])

    case .escape:
        return altPrefixed([esc])

    case .enter:
        return altPrefixed([0x0d])

    case .backspace:
        return altPrefixed([modifiers.contains(.control) ? 0x08 : 0x7f])

    case .space:
        return altPrefixed([modifiers.contains(.control) ? 0x00 : 0x20])

    case .text(let value):
        var payload: [UInt8] = []
        if modifiers.contains(.control), value.count == 1, let character = value.first,
            let control = controlByte(for: character)
        {
            payload = [control]
        } else {
            payload = Array(value.utf8)
        }
        return altPrefixed(payload)
    }
}

// MARK: - Shortcuts

/// What a toolbar button does when tapped.
public enum ShortcutPayload: Sendable, Hashable {
    /// Send the bytes for a chord.
    case chord(KeyChord)
    /// Send literal text (macros such as `git status\n`).
    case literal(String)
    /// Latch a modifier for the next key press; sends nothing on its own.
    case modifierLatch(KeyModifiers)
}

extension ShortcutPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case chord, text, latch
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let chord = try container.decodeIfPresent(KeyChord.self, forKey: .chord) {
            self = .chord(chord)
        } else if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .literal(text)
        } else if let latch = try container.decodeIfPresent(KeyModifiers.self, forKey: .latch) {
            self = .modifierLatch(latch)
        } else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "shortcut needs one of chord, text, latch"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .chord(let chord): try container.encode(chord, forKey: .chord)
        case .literal(let text): try container.encode(text, forKey: .text)
        case .modifierLatch(let latch): try container.encode(latch, forKey: .latch)
        }
    }
}

public struct Shortcut: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var label: String
    public var payload: ShortcutPayload
    /// Ascending display order in the toolbar.
    public var order: Int

    public init(id: String, label: String, payload: ShortcutPayload, order: Int) {
        self.id = id
        self.label = label
        self.payload = payload
        self.order = order
    }

    /// Bytes this shortcut writes to the PTY. Modifier latches write nothing.
    public func bytes(applicationCursorKeys: Bool = false) -> [UInt8] {
        switch payload {
        case .chord(let chord):
            return OpenPawTerminalCore.bytes(for: chord, applicationCursorKeys: applicationCursorKeys)
        case .literal(let text):
            return Array(text.utf8)
        case .modifierLatch:
            return []
        }
    }
}

/// A user customisable, JSON round-trippable toolbar layout.
public struct ShortcutSet: Sendable, Hashable, Codable {
    public static let currentVersion = 1

    public var version: Int
    public var shortcuts: [Shortcut]

    public init(version: Int = ShortcutSet.currentVersion, shortcuts: [Shortcut]) {
        self.version = version
        self.shortcuts = shortcuts
    }

    /// Shortcuts in display order; ties break on identifier so the toolbar never
    /// reorders itself between launches.
    public func ordered() -> [Shortcut] {
        shortcuts.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    public subscript(id: String) -> Shortcut? {
        shortcuts.first { $0.id == id }
    }

    public func bytes(for id: String, applicationCursorKeys: Bool = false) -> [UInt8]? {
        self[id]?.bytes(applicationCursorKeys: applicationCursorKeys)
    }

    /// The layout OpenPaw ships: the keys a phone keyboard cannot produce.
    public static let `default` = ShortcutSet(shortcuts: [
        Shortcut(id: "esc", label: "esc", payload: .chord(KeyChord(.escape)), order: 0),
        Shortcut(id: "ctrl", label: "ctrl", payload: .modifierLatch(.control), order: 1),
        Shortcut(id: "alt", label: "alt", payload: .modifierLatch(.alt), order: 2),
        Shortcut(id: "tab", label: "tab", payload: .chord(KeyChord(.tab)), order: 3),
        Shortcut(id: "pipe", label: "|", payload: .chord(KeyChord(.text("|"))), order: 4),
        Shortcut(id: "slash", label: "/", payload: .chord(KeyChord(.text("/"))), order: 5),
        Shortcut(id: "up", label: "▲", payload: .chord(KeyChord(.up)), order: 6),
        Shortcut(id: "down", label: "▼", payload: .chord(KeyChord(.down)), order: 7),
        Shortcut(id: "left", label: "◀", payload: .chord(KeyChord(.left)), order: 8),
        Shortcut(id: "right", label: "▶", payload: .chord(KeyChord(.right)), order: 9),
        Shortcut(id: "home", label: "home", payload: .chord(KeyChord(.home)), order: 10),
        Shortcut(id: "end", label: "end", payload: .chord(KeyChord(.end)), order: 11),
        Shortcut(id: "pgup", label: "pgup", payload: .chord(KeyChord(.pageUp)), order: 12),
        Shortcut(id: "pgdn", label: "pgdn", payload: .chord(KeyChord(.pageDown)), order: 13),
        Shortcut(
            id: "ctrl-c", label: "^C",
            payload: .chord(KeyChord(.text("c"), modifiers: .control)), order: 14),
        Shortcut(
            id: "ctrl-d", label: "^D",
            payload: .chord(KeyChord(.text("d"), modifiers: .control)), order: 15),
        Shortcut(
            id: "ctrl-z", label: "^Z",
            payload: .chord(KeyChord(.text("z"), modifiers: .control)), order: 16),
        Shortcut(
            id: "ctrl-r", label: "^R",
            payload: .chord(KeyChord(.text("r"), modifiers: .control)), order: 17),
    ])
}
