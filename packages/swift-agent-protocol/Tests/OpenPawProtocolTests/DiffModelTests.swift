import Foundation
import XCTest

@testable import OpenPawProtocol

final class DiffModelTests: XCTestCase {
    // MARK: Split rows

    /// A hunk with two removals followed by three additions: the first two rows pair up
    /// as replacements, the third addition has no counterpart on the left.
    func testSplitRowsPairsTwoRemovedWithThreeAdded() {
        let hunk = Hunk(
            header: "@@ -10,4 +10,5 @@",
            oldStart: 10,
            oldLines: 4,
            newStart: 10,
            newLines: 5,
            lines: [
                DiffLine(kind: .context, text: "fn main() {", oldLine: 10, newLine: 10),
                DiffLine(kind: .removed, text: "    let a = 1;", oldLine: 11),
                DiffLine(kind: .removed, text: "    let b = 2;", oldLine: 12),
                DiffLine(kind: .added, text: "    let a = 10;", newLine: 11),
                DiffLine(kind: .added, text: "    let b = 20;", newLine: 12),
                DiffLine(kind: .added, text: "    let c = 30;", newLine: 13),
                DiffLine(kind: .context, text: "}", oldLine: 13, newLine: 14),
            ]
        )
        let file = FileDiff(
            path: "src/main.rs", change: .modified, additions: 3, deletions: 2, hunks: [hunk]
        )
        let rows = file.splitRows()

        XCTAssertEqual(rows.count, 5)

        XCTAssertEqual(rows[0].left?.text, "fn main() {")
        XCTAssertEqual(rows[0].right?.text, "fn main() {")

        XCTAssertEqual(rows[1].left?.text, "    let a = 1;")
        XCTAssertEqual(rows[1].left?.kind, .removed)
        XCTAssertEqual(rows[1].right?.text, "    let a = 10;")
        XCTAssertEqual(rows[1].right?.kind, .added)

        XCTAssertEqual(rows[2].left?.text, "    let b = 2;")
        XCTAssertEqual(rows[2].right?.text, "    let b = 20;")

        XCTAssertNil(rows[3].left, "the surplus addition has no left hand counterpart")
        XCTAssertEqual(rows[3].right?.text, "    let c = 30;")

        XCTAssertEqual(rows[4].left?.text, "}")
        XCTAssertEqual(rows[4].right?.text, "}")

        // Line numbers survive so the view can render gutters.
        XCTAssertEqual(rows[1].left?.oldLine, 11)
        XCTAssertEqual(rows[1].right?.newLine, 11)
        XCTAssertNil(rows[1].left?.newLine)
    }

    func testSplitRowsWithMoreRemovalsThanAdditions() {
        let file = FileDiff(
            path: "a.txt",
            change: .modified,
            hunks: [
                Hunk(
                    header: "@@ -1,3 +1,1 @@",
                    oldStart: 1,
                    oldLines: 3,
                    newStart: 1,
                    newLines: 1,
                    lines: [
                        DiffLine(kind: .removed, text: "one", oldLine: 1),
                        DiffLine(kind: .removed, text: "two", oldLine: 2),
                        DiffLine(kind: .removed, text: "three", oldLine: 3),
                        DiffLine(kind: .added, text: "only", newLine: 1),
                    ]
                )
            ]
        )
        let rows = file.splitRows()
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].right?.text, "only")
        XCTAssertNil(rows[1].right)
        XCTAssertNil(rows[2].right)
        XCTAssertEqual(rows.compactMap { $0.left?.text }, ["one", "two", "three"])
    }

    func testSplitRowsTreatsSeparateChangeBlocksIndependently() {
        let file = FileDiff(
            path: "a.txt",
            change: .modified,
            hunks: [
                Hunk(
                    header: "@@ -1,5 +1,5 @@",
                    oldStart: 1,
                    oldLines: 5,
                    newStart: 1,
                    newLines: 5,
                    lines: [
                        DiffLine(kind: .removed, text: "x1", oldLine: 1),
                        DiffLine(kind: .added, text: "y1", newLine: 1),
                        DiffLine(kind: .context, text: "same", oldLine: 2, newLine: 2),
                        DiffLine(kind: .removed, text: "x2", oldLine: 3),
                        DiffLine(kind: .added, text: "y2", newLine: 3),
                    ]
                )
            ]
        )
        let rows = file.splitRows()
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map { $0.left?.text }, ["x1", "same", "x2"])
        XCTAssertEqual(rows.map { $0.right?.text }, ["y1", "same", "y2"])
    }

    func testAdditionAfterAdditionRunFollowedByRemovalStartsANewBlock() {
        // `+a +b -c -d` is two blocks: pure additions, then pure removals.
        let file = FileDiff(
            path: "a.txt",
            change: .modified,
            hunks: [
                Hunk(
                    header: "@@ -1,2 +1,2 @@",
                    oldStart: 1,
                    oldLines: 2,
                    newStart: 1,
                    newLines: 2,
                    lines: [
                        DiffLine(kind: .added, text: "a", newLine: 1),
                        DiffLine(kind: .added, text: "b", newLine: 2),
                        DiffLine(kind: .removed, text: "c", oldLine: 1),
                        DiffLine(kind: .removed, text: "d", oldLine: 2),
                    ]
                )
            ]
        )
        let rows = file.splitRows()
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map { $0.right?.text }, ["a", "b", nil, nil])
        XCTAssertEqual(rows.map { $0.left?.text }, [nil, nil, "c", "d"])
    }

    func testSplitRowsAcrossMultipleHunksDoNotBleedIntoEachOther() {
        let file = FileDiff(
            path: "a.txt",
            change: .modified,
            hunks: [
                Hunk(
                    header: "@@ -1,1 +1,1 @@",
                    oldStart: 1, oldLines: 1, newStart: 1, newLines: 1,
                    lines: [DiffLine(kind: .removed, text: "first", oldLine: 1)]
                ),
                Hunk(
                    header: "@@ -9,1 +9,1 @@",
                    oldStart: 9, oldLines: 1, newStart: 9, newLines: 1,
                    lines: [DiffLine(kind: .added, text: "second", newLine: 9)]
                ),
            ]
        )
        let rows = file.splitRows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].left?.text, "first")
        XCTAssertNil(rows[0].right)
        XCTAssertNil(rows[1].left)
        XCTAssertEqual(rows[1].right?.text, "second")
    }

    func testNoNewlineMarkerAppearsOnBothSides() {
        let file = FileDiff(
            path: "a.txt",
            change: .modified,
            hunks: [
                Hunk(
                    header: "@@ -1,1 +1,1 @@",
                    oldStart: 1, oldLines: 1, newStart: 1, newLines: 1,
                    lines: [
                        DiffLine(kind: .added, text: "x", newLine: 1),
                        DiffLine(kind: .noNewline, text: "\\ No newline at end of file"),
                    ]
                )
            ]
        )
        let rows = file.splitRows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].left?.kind, .noNewline)
        XCTAssertEqual(rows[1].right?.kind, .noNewline)
    }

    func testBinaryFileHasNoRows() {
        let file = FileDiff(path: "logo.png", change: .modified, binary: true)
        XCTAssertTrue(file.splitRows().isEmpty)
    }

    // MARK: Wire shapes

    func testDiffDecodesTheHostShape() throws {
        let json = """
            {"files":[{"path":"src/lib.rs","old_path":"src/old.rs","change":"renamed",\
            "additions":1,"deletions":1,"binary":false,\
            "hunks":[{"header":"@@ -1,1 +1,1 @@","old_start":1,"old_lines":1,\
            "new_start":1,"new_lines":1,"lines":[\
            {"kind":"removed","text":"old","old_line":1},\
            {"kind":"added","text":"new","new_line":1}]}]}],\
            "additions":1,"deletions":1}
            """
        let diff = try OpenPawCoding.decoder.decode(Diff.self, from: Data(json.utf8))
        XCTAssertEqual(diff.additions, 1)
        XCTAssertEqual(diff.deletions, 1)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.id, "src/lib.rs")
        XCTAssertEqual(file.oldPath, "src/old.rs")
        XCTAssertEqual(file.change, .renamed)
        XCTAssertEqual(file.hunks.first?.id, "@@ -1,1 +1,1 @@")
        XCTAssertEqual(file.hunks.first?.lines.map(\.kind), [.removed, .added])
        XCTAssertEqual(file.hunks.first?.lines.map(\.text), ["old", "new"])

        let rows = file.splitRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].left?.text, "old")
        XCTAssertEqual(rows[0].right?.text, "new")

        assertSemanticallyEqual(try OpenPawCoding.encoder.encode(diff), Data(json.utf8))
    }

    func testRepoStatusDecodesTheHostShape() throws {
        let json = """
            {"branch":"main","ahead":2,"behind":1,\
            "staged":[{"path":"src/a.rs","old_path":null,"change":"modified"}],\
            "unstaged":[{"path":"src/b.rs","old_path":"src/old.rs","change":"renamed"}],\
            "untracked":[{"path":"notes.md","old_path":null,"change":"added"}]}
            """
        let status = try OpenPawCoding.decoder.decode(RepoStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.staged.map(\.id), ["src/a.rs"])
        XCTAssertEqual(status.unstaged.first?.oldPath, "src/old.rs")
        XCTAssertEqual(status.unstaged.first?.change, .renamed)
        XCTAssertEqual(status.untracked.first?.change, .added)
        XCTAssertTrue(status.isDirty)

        let clean = try OpenPawCoding.decoder.decode(
            RepoStatus.self,
            from: Data(#"{"branch":"main","ahead":0,"behind":0,"staged":[],"unstaged":[],"untracked":[]}"#.utf8)
        )
        XCTAssertFalse(clean.isDirty)
    }

    func testRepoSummaryAllowsADetachedHead() throws {
        let json = """
            [{"name":"openpaw","path":"/Users/x/openpaw","branch":null,"dirty":true,\
            "ahead":0,"behind":0}]
            """
        let repos = try OpenPawCoding.decoder.decode([RepoSummary].self, from: Data(json.utf8))
        XCTAssertNil(repos.first?.branch)
        XCTAssertEqual(repos.first?.id, "/Users/x/openpaw")
        XCTAssertEqual(repos.first?.dirty, true)
    }

    func testTreeEntriesDecodeAsABareArray() throws {
        let json = """
            [{"name":"src","path":"src","kind":"directory","is_symlink":false},\
            {"name":"main.rs","path":"src/main.rs","kind":"file","size":2048,"is_symlink":false},\
            {"name":"link","path":"src/link","kind":"symlink","is_symlink":true},\
            {"name":"vendor","path":"vendor","kind":"other","is_symlink":false}]
            """
        let entries = try OpenPawCoding.decoder.decode([TreeEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.map(\.kind), [.directory, .file, .symlink, .other])
        XCTAssertEqual(entries[1].size, 2048)
        XCTAssertEqual(entries[2].isSymlink, true)
        XCTAssertEqual(entries[1].id, "src/main.rs")
    }

    func testBlobTextAndBinaryEncodings() throws {
        let text = try OpenPawCoding.decoder.decode(
            Blob.self,
            from: Data(
                """
                {"path":"src/main.rs","bytes":12,"mime":"text/x-rust","truncated":false,\
                "content":{"encoding":"text","value":"fn main() {}"}}
                """.utf8
            )
        )
        XCTAssertEqual(text.content, .text("fn main() {}"))
        XCTAssertEqual(text.content.text, "fn main() {}")

        let binaryJSON = """
            {"path":"logo.png","bytes":40960,"mime":"image/png","truncated":false,\
            "content":{"encoding":"binary","value":{"sha256":"\(String(repeating: "a", count: 64))"}}}
            """
        let binary = try OpenPawCoding.decoder.decode(Blob.self, from: Data(binaryJSON.utf8))
        XCTAssertEqual(binary.content, .binary(sha256: String(repeating: "a", count: 64)))
        XCTAssertNil(binary.content.text, "binary bytes are never shipped, only the digest")
        assertSemanticallyEqual(try OpenPawCoding.encoder.encode(binary), Data(binaryJSON.utf8))

        XCTAssertThrowsError(
            try OpenPawCoding.decoder.decode(
                Blob.self,
                from: Data(
                    """
                    {"path":"x","bytes":1,"mime":"application/octet-stream","truncated":false,\
                    "content":{"encoding":"base64","value":"AAA="}}
                    """.utf8
                )
            ),
            "base64 is deliberately not part of the protocol"
        )
    }

    func testContentMatchesDecodeAsABareArray() throws {
        let json = """
            [{"path":"src/lib.rs","line":42,"text":"// TODO: revisit"},\
            {"path":"src/main.rs","line":7,"text":"// TODO: later"}]
            """
        let matches = try OpenPawCoding.decoder.decode([ContentMatch].self, from: Data(json.utf8))
        XCTAssertEqual(matches.map(\.line), [42, 7])
        XCTAssertEqual(matches[0].id, "src/lib.rs:42")
    }

    func testDiffModeQueryItemsMatchTheRoute() {
        XCTAssertTrue(DiffMode.workingTree.queryItems.isEmpty)
        XCTAssertEqual(
            DiffMode.staged.queryItems, [URLQueryItem(name: "staged", value: "true")]
        )
        XCTAssertEqual(
            DiffMode.commit("abc").queryItems, [URLQueryItem(name: "commit", value: "abc")]
        )
        XCTAssertEqual(
            DiffMode.range(base: "main", head: "topic").queryItems,
            [
                URLQueryItem(name: "base", value: "main"),
                URLQueryItem(name: "head", value: "topic"),
            ]
        )
    }
}
