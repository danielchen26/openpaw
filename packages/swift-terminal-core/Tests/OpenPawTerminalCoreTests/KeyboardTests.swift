import XCTest

@testable import OpenPawTerminalCore

final class KeyboardTests: XCTestCase {

    private func chord(_ text: String) -> KeyChord {
        guard let chord = KeyChord(parsing: text) else {
            XCTFail("could not parse chord \(text)")
            return KeyChord(.escape)
        }
        return chord
    }

    // MARK: control bytes

    func testControlLettersMapToC0() {
        XCTAssertEqual(bytes(for: chord("ctrl+a")), [0x01])
        XCTAssertEqual(bytes(for: chord("ctrl+c")), [0x03])
        XCTAssertEqual(bytes(for: chord("ctrl+i")), [0x09])
        XCTAssertEqual(bytes(for: chord("ctrl+z")), [0x1a])
        // Case of the letter must not change the control byte.
        XCTAssertEqual(bytes(for: KeyChord(.text("Z"), modifiers: .control)), [0x1a])
    }

    func testControlPunctuation() {
        XCTAssertEqual(bytes(for: chord("ctrl+space")), [0x00])
        XCTAssertEqual(bytes(for: chord("ctrl+@")), [0x00])
        XCTAssertEqual(bytes(for: chord("ctrl+[")), [0x1b])
        XCTAssertEqual(bytes(for: chord("ctrl+\\")), [0x1c])
        XCTAssertEqual(bytes(for: chord("ctrl+]")), [0x1d])
        XCTAssertEqual(bytes(for: chord("ctrl+?")), [0x7f])
    }

    func testPlainAndAltPrefixedText() {
        XCTAssertEqual(bytes(for: chord("|")), [0x7c])
        XCTAssertEqual(bytes(for: chord("/")), [0x2f])
        XCTAssertEqual(bytes(for: chord("alt+b")), [0x1b, 0x62])
        XCTAssertEqual(bytes(for: chord("alt+f")), [0x1b, 0x66])
        XCTAssertEqual(bytes(for: KeyChord(.text("é"))), Array("é".utf8))
        // cmd is an app-level modifier and is never transmitted.
        XCTAssertEqual(bytes(for: KeyChord(.text("k"), modifiers: .command)), [0x6b])
    }

    // MARK: named keys

    func testNamedKeys() {
        XCTAssertEqual(bytes(for: chord("esc")), [0x1b])
        XCTAssertEqual(bytes(for: chord("alt+esc")), [0x1b, 0x1b])
        XCTAssertEqual(bytes(for: chord("enter")), [0x0d])
        XCTAssertEqual(bytes(for: chord("space")), [0x20])
        XCTAssertEqual(bytes(for: chord("tab")), [0x09])
        XCTAssertEqual(bytes(for: chord("alt+tab")), [0x1b, 0x09])
        XCTAssertEqual(bytes(for: chord("shift+tab")), Array("\u{1b}[Z".utf8))
        XCTAssertEqual(bytes(for: chord("backspace")), [0x7f])
        XCTAssertEqual(bytes(for: chord("ctrl+backspace")), [0x08])
        XCTAssertEqual(bytes(for: chord("delete")), Array("\u{1b}[3~".utf8))
        XCTAssertEqual(bytes(for: chord("insert")), Array("\u{1b}[2~".utf8))
        XCTAssertEqual(bytes(for: chord("pgup")), Array("\u{1b}[5~".utf8))
        XCTAssertEqual(bytes(for: chord("pgdn")), Array("\u{1b}[6~".utf8))
        XCTAssertEqual(bytes(for: chord("ctrl+pgdn")), Array("\u{1b}[6;5~".utf8))
    }

    // MARK: cursor keys in both modes

    func testCursorKeysTable() {
        let cases: [(chord: String, normal: String, application: String)] = [
            ("up", "\u{1b}[A", "\u{1b}OA"),
            ("down", "\u{1b}[B", "\u{1b}OB"),
            ("right", "\u{1b}[C", "\u{1b}OC"),
            ("left", "\u{1b}[D", "\u{1b}OD"),
            ("home", "\u{1b}[H", "\u{1b}OH"),
            ("end", "\u{1b}[F", "\u{1b}OF"),
            // Modified cursor keys use the CSI form in both modes, as xterm does.
            ("shift+up", "\u{1b}[1;2A", "\u{1b}[1;2A"),
            ("alt+right", "\u{1b}[1;3C", "\u{1b}[1;3C"),
            ("ctrl+left", "\u{1b}[1;5D", "\u{1b}[1;5D"),
            ("ctrl+shift+up", "\u{1b}[1;6A", "\u{1b}[1;6A"),
            ("ctrl+alt+shift+down", "\u{1b}[1;8B", "\u{1b}[1;8B"),
            ("ctrl+home", "\u{1b}[1;5H", "\u{1b}[1;5H"),
        ]
        for testCase in cases {
            let parsed = chord(testCase.chord)
            XCTAssertEqual(
                bytes(for: parsed, applicationCursorKeys: false),
                Array(testCase.normal.utf8),
                "normal mode \(testCase.chord)")
            XCTAssertEqual(
                bytes(for: parsed, applicationCursorKeys: true),
                Array(testCase.application.utf8),
                "application mode \(testCase.chord)")
        }
    }

    // MARK: function keys

    func testFunctionKeysTable() {
        let expected: [(String, String)] = [
            ("f1", "\u{1b}OP"),
            ("f2", "\u{1b}OQ"),
            ("f3", "\u{1b}OR"),
            ("f4", "\u{1b}OS"),
            ("f5", "\u{1b}[15~"),
            ("f6", "\u{1b}[17~"),
            ("f7", "\u{1b}[18~"),
            ("f8", "\u{1b}[19~"),
            ("f9", "\u{1b}[20~"),
            ("f10", "\u{1b}[21~"),
            ("f11", "\u{1b}[23~"),
            ("f12", "\u{1b}[24~"),
            ("shift+f5", "\u{1b}[15;2~"),
            ("ctrl+f1", "\u{1b}[1;5P"),
            ("alt+f12", "\u{1b}[24;3~"),
        ]
        for (text, sequence) in expected {
            let parsed = chord(text)
            XCTAssertEqual(bytes(for: parsed), Array(sequence.utf8), text)
            // Function keys already use SS3/CSI explicitly, so DECCKM is
            // irrelevant to them.
            XCTAssertEqual(
                bytes(for: parsed, applicationCursorKeys: true), Array(sequence.utf8), text)
        }
    }

    // MARK: chords

    func testChordParsingAndDescriptionRoundTrip() {
        for text in ["ctrl+c", "alt+left", "ctrl+alt+f5", "shift+tab", "esc", "|", "ctrl++"] {
            let parsed = chord(text)
            XCTAssertEqual(parsed.description, text)
            XCTAssertEqual(KeyChord(parsing: parsed.description), parsed)
        }
        XCTAssertEqual(chord("ctrl+alt+f5").key, .function(5))
        XCTAssertEqual(chord("ctrl+alt+f5").modifiers, [.control, .alt])
        XCTAssertEqual(chord("ctrl++").key, .text("+"))
        XCTAssertNil(KeyChord(parsing: ""))
        XCTAssertNil(KeyChord(parsing: "hyper+c"))
        // Aliases normalise onto the canonical identifiers.
        XCTAssertEqual(KeyChord(parsing: "control+escape"), KeyChord(.escape, modifiers: .control))
        XCTAssertEqual(KeyChord(parsing: "option+pageup"), KeyChord(.pageUp, modifiers: .alt))
    }

    func testKeyChordCodesAsASingleString() throws {
        let chord = KeyChord(.function(7), modifiers: [.control, .shift])
        let data = try JSONEncoder().encode(chord)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"ctrl+shift+f7\"")
        XCTAssertEqual(try JSONDecoder().decode(KeyChord.self, from: data), chord)
        XCTAssertThrowsError(
            try JSONDecoder().decode(KeyChord.self, from: Data("\"hyper+c\"".utf8)))
    }

    // MARK: shortcut sets

    func testDefaultShortcutSetCoversTheToolbarKeys() {
        let set = ShortcutSet.default
        let ordered = set.ordered()
        XCTAssertEqual(ordered.map(\.order), Array(0..<ordered.count))
        for identifier in [
            "esc", "ctrl", "alt", "tab", "pipe", "slash", "up", "down", "left", "right",
            "home", "end", "pgup", "pgdn",
        ] {
            XCTAssertNotNil(set[identifier], identifier)
        }
        XCTAssertEqual(set.bytes(for: "pipe"), [0x7c])
        XCTAssertEqual(set.bytes(for: "ctrl-c"), [0x03])
        XCTAssertEqual(set.bytes(for: "up"), Array("\u{1b}[A".utf8))
        XCTAssertEqual(
            set.bytes(for: "up", applicationCursorKeys: true), Array("\u{1b}OA".utf8))
        // A latched modifier sends nothing by itself.
        XCTAssertEqual(set.bytes(for: "ctrl"), [])
        XCTAssertNil(set.bytes(for: "not-a-shortcut"))
    }

    func testShortcutSetJSONRoundTripsForCustomisation() throws {
        var custom = ShortcutSet.default
        custom.shortcuts.append(
            Shortcut(id: "status", label: "status", payload: .literal("git status\n"), order: 99))

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(custom)
        let decoded = try JSONDecoder().decode(ShortcutSet.self, from: data)

        XCTAssertEqual(decoded, custom)
        XCTAssertEqual(decoded.version, ShortcutSet.currentVersion)
        XCTAssertEqual(decoded.bytes(for: "status"), Array("git status\n".utf8))
        XCTAssertEqual(decoded.ordered().last?.id, "status")

        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"chord\":\"esc\""))
        XCTAssertTrue(json.contains("\"text\":\"git status\\n\""))
    }

    func testShortcutSetRejectsPayloadWithoutAnAction() {
        let json = Data(
            #"{"version":1,"shortcuts":[{"id":"x","label":"x","order":0,"payload":{}}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ShortcutSet.self, from: json))
    }
}
