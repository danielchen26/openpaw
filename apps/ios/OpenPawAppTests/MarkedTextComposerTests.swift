import XCTest

@testable import OpenPawApp

/// Pins the rule that marked text never reaches the PTY. The failure mode this guards is silent and remote: the
/// shell receives Pinyin letters as commands and nobody sees it locally.
final class MarkedTextComposerTests: XCTestCase {

    /// Drives the machine and collects exactly the bytes the transport would have been given.
    private struct Harness {
        var composer = MarkedTextComposer()
        var sent = ""

        mutating func mark(_ text: String) { record(composer.setMarkedText(text)) }
        mutating func insert(_ text: String) { record(composer.insertText(text)) }
        mutating func unmark() { record(composer.unmarkText()) }
        mutating func backspace() { record(composer.deleteBackward()) }
        mutating func type(_ text: String) { record(composer.typed(text)) }

        private mutating func record(_ emission: MarkedTextComposer.Emission) {
            if case .send(let text) = emission { sent += text }
        }
    }

    func testPinyinCompositionSendsOnlyTheCommittedHanzi() {
        var harness = Harness()
        for stage in ["n", "ni", "nih", "niha", "nihao"] { harness.mark(stage) }
        harness.insert("你好")

        XCTAssertEqual(harness.sent, "你好")
        XCTAssertFalse(harness.composer.isComposing)
        XCTAssertEqual(harness.composer.markedText, "")
    }

    func testCandidateReplacementDoesNotDoubleSend() {
        var harness = Harness()
        harness.mark("ni")
        // Selecting a candidate marks it, then commits the same string.
        harness.mark("你")
        harness.insert("你")
        XCTAssertEqual(harness.sent, "你")
    }

    func testUnmarkAcceptsTheMarkedTextVerbatim() {
        var harness = Harness()
        harness.mark("ｱｲ")
        harness.unmark()
        XCTAssertEqual(harness.sent, "ｱｲ")
        XCTAssertFalse(harness.composer.isComposing)
    }

    func testUnmarkWithNothingMarkedSendsNothing() {
        var harness = Harness()
        harness.unmark()
        XCTAssertEqual(harness.sent, "")
    }

    func testClearingMarkedTextWithAnEmptyStringSendsNothing() {
        var harness = Harness()
        harness.mark("nih")
        harness.mark("")
        XCTAssertEqual(harness.sent, "")
        XCTAssertFalse(harness.composer.isComposing)
    }

    /// Backspace during composition edits the candidate, it does not delete a character on the remote line.
    func testBackspaceIsLocalWhileComposing() {
        var harness = Harness()
        harness.mark("nih")
        harness.backspace()
        XCTAssertEqual(harness.sent, "")
        XCTAssertEqual(harness.composer.markedText, "ni")
        harness.backspace()
        harness.backspace()
        XCTAssertEqual(harness.sent, "")
        XCTAssertFalse(harness.composer.isComposing)
    }

    func testBackspaceSendsDeleteWhenNotComposing() {
        var harness = Harness()
        harness.backspace()
        XCTAssertEqual(harness.sent, "\u{7F}")
    }

    /// The first backspace after the composition drains must reach the remote side, otherwise the user has to press
    /// it twice at the boundary.
    func testBackspaceAfterCompositionDrainsSendsDelete() {
        var harness = Harness()
        harness.mark("n")
        harness.backspace()
        harness.backspace()
        XCTAssertEqual(harness.sent, "\u{7F}")
    }

    func testAsciiTypingIsUnaffected() {
        var harness = Harness()
        harness.type("g")
        harness.type("i")
        harness.type("t")
        harness.type(" status\r")
        XCTAssertEqual(harness.sent, "git status\r")
    }

    func testAbandoningCompositionSendsNothing() {
        var harness = Harness()
        harness.mark("nihao")
        harness.composer.abandon()
        XCTAssertEqual(harness.sent, "")
        XCTAssertFalse(harness.composer.isComposing)
    }

    /// A mixed line is the realistic case: an English command with a Chinese argument. Nothing romanised may leak
    /// into the middle of it.
    func testMixedAsciiAndCompositionPreservesOrderWithoutLeaking() {
        var harness = Harness()
        harness.type("echo ")
        harness.mark("ni")
        harness.mark("nihao")
        harness.insert("你好")
        harness.type("\r")
        XCTAssertEqual(harness.sent, "echo 你好\r")
    }
}
