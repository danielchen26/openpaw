import XCTest

@testable import OpenPawTerminalCore

final class ClipboardTests: XCTestCase {

    // MARK: OSC 52

    func testEncodeUsesBothTerminatorForms() throws {
        let data = Data("hello".utf8)
        XCTAssertEqual(
            try OSC52.encode(data, selection: .clipboard, terminator: .bel),
            "\u{1b}]52;c;aGVsbG8=\u{07}")
        XCTAssertEqual(
            try OSC52.encode(data, selection: .primary, terminator: .st),
            "\u{1b}]52;p;aGVsbG8=\u{1b}\\")
    }

    func testRoundTripsBothTerminatorForms() throws {
        for terminator in OSC52Terminator.allCases {
            let payload = Data("git commit -m 'ship it'\n".utf8)
            let sequence = try OSC52.encode(payload, terminator: terminator)
            guard case .set(let decoded)? = try OSC52.decode(sequence) else {
                return XCTFail("expected a set command for \(terminator)")
            }
            XCTAssertEqual(decoded.selection, .clipboard)
            XCTAssertEqual(decoded.data, payload)
            XCTAssertEqual(decoded.text, "git commit -m 'ship it'\n")
        }
    }

    func testDecodesSequenceEmbeddedInOutput() throws {
        let sequence = try OSC52.encode(Data("copied".utf8), terminator: .st)
        let stream = "before\r\n" + sequence + "after\r\n"
        guard case .set(let payload)? = try OSC52.decode(stream) else {
            return XCTFail("expected a set command")
        }
        XCTAssertEqual(payload.text, "copied")
    }

    func testDecodesQueryAndSelectionAliases() throws {
        XCTAssertEqual(try OSC52.decode("\u{1b}]52;p;?\u{07}"), .query(.primary))
        // An empty selection is xterm's default and means the clipboard.
        guard case .set(let payload)? = try OSC52.decode("\u{1b}]52;;aGk=\u{07}") else {
            return XCTFail("expected a set command")
        }
        XCTAssertEqual(payload.selection, .clipboard)
        XCTAssertEqual(payload.text, "hi")
    }

    func testReturnsNilWhenThereIsNoSequence() throws {
        XCTAssertNil(try OSC52.decode("just terminal output\r\n"))
    }

    func testRefusesOversizedPayloadOnEncode() {
        XCTAssertThrowsError(try OSC52.encode(Data(repeating: 0x41, count: 5), limit: 4)) { error in
            XCTAssertEqual(error as? ClipboardError, .payloadTooLarge(bytes: 5, limit: 4))
        }
    }

    func testRefusesOversizedPayloadOnDecode() throws {
        let big = try OSC52.encode(Data(repeating: 0x41, count: 1_000), limit: 2_000)
        XCTAssertThrowsError(try OSC52.decode(big, limit: 100)) { error in
            guard case ClipboardError.payloadTooLarge(_, let limit) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(limit, 100)
        }
        // Exactly at the limit is allowed.
        let exact = try OSC52.encode(Data(repeating: 0x41, count: 100))
        guard case .set(let payload)? = try OSC52.decode(exact, limit: 100) else {
            return XCTFail("expected a set command")
        }
        XCTAssertEqual(payload.data.count, 100)
    }

    func testRejectsMalformedSequences() {
        XCTAssertThrowsError(try OSC52.decode("\u{1b}]52;c;aGk=")) { error in
            XCTAssertEqual(error as? ClipboardError, .malformedSequence("unterminated sequence"))
        }
        XCTAssertThrowsError(try OSC52.decode("\u{1b}]52;c-no-separator\u{07}")) { error in
            guard case ClipboardError.malformedSequence = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertThrowsError(try OSC52.decode("\u{1b}]52;z;aGk=\u{07}")) { error in
            XCTAssertEqual(error as? ClipboardError, .unsupportedSelection("z"))
        }
        XCTAssertThrowsError(try OSC52.decode("\u{1b}]52;c;!!!not-base64!!!\u{07}")) { error in
            XCTAssertEqual(error as? ClipboardError, .invalidBase64)
        }
    }

    func testAcceptsUnpaddedBase64() throws {
        // "hi" encodes to "aGk=" but some emitters drop the padding.
        guard case .set(let payload)? = try OSC52.decode("\u{1b}]52;c;aGk\u{07}") else {
            return XCTFail("expected a set command")
        }
        XCTAssertEqual(payload.text, "hi")
    }

    // MARK: OSC 8

    func testParsesHyperlinkWithSTTerminator() {
        let input = "see \u{1b}]8;;https://example.com/a\u{1b}\\Example\u{1b}]8;;\u{1b}\\ done"
        let scan = OSC8.parse(input)

        XCTAssertEqual(scan.text, "see Example done")
        XCTAssertEqual(scan.links.count, 1)
        XCTAssertEqual(scan.links[0].url, "https://example.com/a")
        XCTAssertEqual(scan.links[0].text, "Example")
        XCTAssertEqual(scan.links[0].range, 4..<11)
        XCTAssertNil(scan.links[0].id)
        XCTAssertEqual(String(Array(scan.text)[scan.links[0].range]), "Example")
    }

    func testParsesHyperlinkWithBELTerminatorAndIDParameter() {
        let input = "🐾 \u{1b}]8;id=42:foo=bar;file:///tmp/log\u{07}log\u{1b}]8;;\u{07}!"
        let scan = OSC8.parse(input)

        XCTAssertEqual(scan.text, "🐾 log!")
        XCTAssertEqual(scan.links.count, 1)
        XCTAssertEqual(scan.links[0].url, "file:///tmp/log")
        XCTAssertEqual(scan.links[0].id, "42")
        // Character offsets, so the emoji counts as one position.
        XCTAssertEqual(scan.links[0].range, 2..<5)
        XCTAssertEqual(String(Array(scan.text)[scan.links[0].range]), "log")
    }

    func testParsesMultipleLinksAndPlainText() {
        let input =
            "\u{1b}]8;;https://a\u{07}A\u{1b}]8;;\u{07} and \u{1b}]8;;https://b\u{07}B\u{1b}]8;;\u{07}"
        let scan = OSC8.parse(input)

        XCTAssertEqual(scan.text, "A and B")
        XCTAssertEqual(scan.links.map(\.url), ["https://a", "https://b"])
        XCTAssertEqual(scan.links.map(\.range), [0..<1, 6..<7])
    }

    func testUnclosedHyperlinkStillReportsARange() {
        let scan = OSC8.parse("\u{1b}]8;;https://a\u{07}tail")
        XCTAssertEqual(scan.text, "tail")
        XCTAssertEqual(scan.links.map(\.range), [0..<4])
        XCTAssertEqual(scan.links[0].text, "tail")
    }

    func testTextWithoutHyperlinksIsUnchanged() {
        let scan = OSC8.parse("plain output\r\n")
        XCTAssertEqual(scan.text, "plain output\r\n")
        XCTAssertTrue(scan.links.isEmpty)
    }
}
