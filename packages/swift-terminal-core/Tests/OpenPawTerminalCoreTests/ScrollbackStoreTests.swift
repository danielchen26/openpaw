import XCTest

@testable import OpenPawTerminalCore

final class ScrollbackStoreTests: XCTestCase {

    func testPartialChunksJoinAcrossAppends() async {
        let store = ScrollbackStore()
        await store.append(Data("hel".utf8))
        await store.append(Data("lo\nwor".utf8))

        let first = await store.snapshot()
        XCTAssertEqual(first.lineCount, 1)
        XCTAssertEqual(first.line(at: 1), "hello")
        XCTAssertEqual(first.partialLine, "wor")

        await store.append(Data("ld\n".utf8))
        let second = await store.snapshot()
        XCTAssertEqual(second.lines, ["hello", "world"])
        XCTAssertEqual(second.partialLine, "")
    }

    func testMultiByteScalarSplitAcrossChunks() async {
        let store = ScrollbackStore()
        // "é" is 0xC3 0xA9: the chunk boundary lands inside the scalar.
        await store.append(Data([0xC3]))
        await store.append(Data([0xA9, 0x0A]))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.lines, ["é"])
    }

    func testCarriageReturnOverwritesCurrentLine() async {
        let store = ScrollbackStore()
        await store.append(Data("50%\r100%\n".utf8))
        var lines = await store.lines
        XCTAssertEqual(lines, ["100%"])

        // A CR ending one chunk still overwrites when the next chunk arrives.
        await store.append(Data("progress 1\r".utf8))
        await store.append(Data("progress 2\n".utf8))
        lines = await store.lines
        XCTAssertEqual(lines, ["100%", "progress 2"])

        // CRLF split across chunks is one line break, not an overwrite.
        await store.append(Data("done\r".utf8))
        await store.append(Data("\nnext\n".utf8))
        lines = await store.lines
        XCTAssertEqual(lines, ["100%", "progress 2", "done", "next"])
    }

    func testCarriageReturnOverwritesInPlaceLikeATerminal() async {
        let store = ScrollbackStore()
        // A shorter replacement leaves the tail visible, exactly as a real
        // terminal does without an erase-to-end-of-line.
        await store.append(Data("100%\r50%\n".utf8))
        let lines = await store.lines
        XCTAssertEqual(lines, ["50%%"])
    }

    func testByteBudgetEvictsOldestLinesAndKeepsNumbering() async {
        // Each line is 3 bytes plus its newline, so 20 bytes retains 5 lines.
        let store = ScrollbackStore(byteBudget: 20)
        for index in 1...10 {
            await store.append(Data(String(format: "l%02d\n", index).utf8))
        }

        let count = await store.lineCount
        let bytes = await store.byteCount
        let oldest = await store.oldestLineNumber
        let next = await store.nextLineNumber
        let lines = await store.lines
        let sixth = await store.line(at: 6)
        let tenth = await store.line(at: 10)
        let evicted = await store.line(at: 5)
        let future = await store.line(at: 11)

        XCTAssertEqual(count, 5)
        XCTAssertEqual(bytes, 20)
        XCTAssertEqual(lines, ["l06", "l07", "l08", "l09", "l10"])
        XCTAssertEqual(oldest, 6)
        XCTAssertEqual(next, 11)
        XCTAssertEqual(sixth, "l06")
        XCTAssertEqual(tenth, "l10")
        XCTAssertNil(evicted)
        XCTAssertNil(future)
    }

    func testSnapshotIsAnIndependentValue() async {
        let store = ScrollbackStore(byteBudget: 12)
        await store.append(Data("aaa\nbbb\nccc\npar".utf8))
        let snapshot = await store.snapshot()

        XCTAssertEqual(snapshot.lineCount, 3)
        XCTAssertEqual(snapshot.firstLineNumber, 1)
        XCTAssertEqual(snapshot.partialLine, "par")
        XCTAssertEqual(snapshot.line(at: 2), "bbb")
        XCTAssertNil(snapshot.line(at: 4))

        await store.append(Data("t\nddd\n".utf8))
        let lines = await store.lines
        let oldest = await store.oldestLineNumber

        // The snapshot taken earlier is unaffected by later writes.
        XCTAssertEqual(snapshot.lines, ["aaa", "bbb", "ccc"])
        XCTAssertEqual(lines, ["part", "ddd"])
        XCTAssertEqual(oldest, 4)
    }

    func testSearchReportsLineNumbersAndByteRanges() async {
        let store = ScrollbackStore()
        await store.append(Data("build started\n".utf8))
        await store.append(Data("café error error\n".utf8))
        await store.append(Data("ERROR: giving up\n".utf8))
        await store.append(Data("partial error".utf8))

        let insensitive = await store.search("error")
        XCTAssertEqual(insensitive.map(\.lineNumber), [2, 2, 3, 4])
        // "café " is 6 UTF-8 bytes, so the first hit starts at byte 6.
        XCTAssertEqual(insensitive[0].byteRange, 6..<11)
        XCTAssertEqual(insensitive[1].byteRange, 12..<17)
        XCTAssertEqual(insensitive[2].byteRange, 0..<5)
        XCTAssertEqual(insensitive[3].line, "partial error")

        let line = insensitive[0].line
        let range = insensitive[0].range(in: line)
        XCTAssertNotNil(range)
        XCTAssertEqual(range.map { String(line[$0]) }, "error")

        let sensitive = await store.search("ERROR", caseSensitive: true)
        XCTAssertEqual(sensitive.map(\.lineNumber), [3])

        let empty = await store.search("", caseSensitive: false)
        XCTAssertTrue(empty.isEmpty)
        let missing = await store.search("nonexistent")
        XCTAssertTrue(missing.isEmpty)
    }

    func testSearchSkipsEvictedLines() async {
        let store = ScrollbackStore(byteBudget: 12)
        await store.append(Data("err one\n".utf8))
        await store.append(Data("err two\n".utf8))
        await store.append(Data("err three\n".utf8))

        let matches = await store.search("err")
        XCTAssertEqual(matches.map(\.lineNumber), [3])
        XCTAssertEqual(matches.map(\.line), ["err three"])
    }

    func testExportRoundTripsRetainedContent() async {
        let store = ScrollbackStore()
        await store.append(Data("one\ntwo\nthree".utf8))
        var exported = await store.export()
        XCTAssertEqual(exported, Data("one\ntwo\nthree".utf8))

        await store.append(Data("\n".utf8))
        exported = await store.export()
        XCTAssertEqual(exported, Data("one\ntwo\nthree\n".utf8))
    }

    func testClearKeepsNumberingMonotonic() async {
        let store = ScrollbackStore()
        await store.append(Data("a\nb\n".utf8))
        await store.clear()

        let count = await store.lineCount
        let exported = await store.export()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(exported, Data())

        await store.append(Data("c\n".utf8))
        let oldest = await store.oldestLineNumber
        let restored = await store.line(at: 3)
        XCTAssertEqual(oldest, 3)
        XCTAssertEqual(restored, "c")
    }
}
