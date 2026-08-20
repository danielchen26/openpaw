import Foundation
import OpenPawProtocol
import SwiftUI
import XCTest

@testable import OpenPawUI

/// Pure logic behind the four read-only repository screens. No view is instantiated here: what is worth
/// defending is the pairing, the budget, the language map, the markdown registers and the navigation refusal.
final class RepoTests: XCTestCase {

    // MARK: - Split diff pairing

    /// Two removals followed by three additions is the interesting case: the first two pair up as replacements
    /// and the third addition has nothing to sit beside, so it must appear alone on the right.
    func testSplitRowsPairsRemovalsWithAdditionsAndLeavesTrailingAdditionUnpaired() {
        let file = Self.replacementFile()
        let rows = file.splitRows()

        XCTAssertEqual(rows.count, 5, "one context, three change rows, one context")

        XCTAssertEqual(rows[0].left?.text, "unchanged before")
        XCTAssertEqual(rows[0].right?.text, "unchanged before")

        XCTAssertEqual(rows[1].left?.text, "removed one")
        XCTAssertEqual(rows[1].right?.text, "added one")

        XCTAssertEqual(rows[2].left?.text, "removed two")
        XCTAssertEqual(rows[2].right?.text, "added two")

        XCTAssertNil(rows[3].left, "the third addition replaces nothing")
        XCTAssertEqual(rows[3].right?.text, "added three")

        XCTAssertEqual(rows[4].left?.text, "unchanged after")
        XCTAssertEqual(rows[4].right?.text, "unchanged after")
    }

    /// Line numbers have to survive the pairing, because they are the only way a reader locates a change.
    func testSplitRowsCarryOldAndNewLineNumbersOnTheCorrectSides() {
        let rows = Self.replacementFile().splitRows()

        XCTAssertEqual(rows[1].left?.oldLine, 11)
        XCTAssertEqual(rows[1].right?.newLine, 11)
        XCTAssertEqual(rows[2].left?.oldLine, 12)
        XCTAssertEqual(rows[2].right?.newLine, 12)
        XCTAssertNil(rows[3].left?.oldLine)
        XCTAssertEqual(rows[3].right?.newLine, 13)
    }

    /// The planner must delegate pairing rather than reimplement it, and must keep the `@@` marker that a split
    /// view otherwise loses.
    func testSplitPlannerKeepsHunkHeaderAndDelegatesPairing() {
        let file = Self.replacementFile()
        let planned = DiffRowPlanner.split(file)

        guard case .hunkHeader(_, let header) = planned.first else {
            return XCTFail("the first planned row should be the hunk header")
        }
        XCTAssertEqual(header, "@@ -10,4 +10,5 @@")

        let pairs: [(DiffLine?, DiffLine?)] = planned.compactMap { row in
            guard case .split(_, let left, let right) = row else { return nil }
            return (left, right)
        }
        let expected = file.splitRows()
        XCTAssertEqual(pairs.count, expected.count)
        for (index, pair) in pairs.enumerated() {
            XCTAssertEqual(pair.0?.text, expected[index].left?.text, "row \(index) left")
            XCTAssertEqual(pair.1?.text, expected[index].right?.text, "row \(index) right")
        }
    }

    // MARK: - Line budget

    func testLineBudgetTruncatesAtTheLimitAndReportsTheRemainder() {
        let rows = Array(1...10)
        let capped = LineBudget(limit: 4).apply(to: rows)

        XCTAssertEqual(capped.rows, [1, 2, 3, 4], "the leading rows survive, in order")
        XCTAssertEqual(capped.rendered, 4)
        XCTAssertEqual(capped.total, 10)
        XCTAssertEqual(capped.withheld, 6)
        XCTAssertTrue(capped.isTruncated)
        XCTAssertEqual(capped.note, "Showing first 4 lines of 10. 6 more are not rendered.")
    }

    func testLineBudgetIsSilentWhenNothingIsWithheld() {
        let capped = LineBudget(limit: 50).apply(to: Array(1...10))

        XCTAssertEqual(capped.rendered, 10)
        XCTAssertEqual(capped.withheld, 0)
        XCTAssertFalse(capped.isTruncated)
        XCTAssertNil(capped.note, "an untruncated file says nothing about truncation")
    }

    /// Hunk markers are chrome. A file whose budget is spent on `@@` lines would show less code than promised.
    func testLineBudgetDoesNotChargeHunkHeaders() {
        let file = FileDiff(
            path: "src/wide.rs",
            change: .modified,
            additions: 10,
            hunks: (0..<2).map { hunkIndex in
                Hunk(
                    header: "@@ -\(hunkIndex * 10),5 +\(hunkIndex * 10),5 @@",
                    oldStart: UInt32(hunkIndex * 10),
                    oldLines: 5,
                    newStart: UInt32(hunkIndex * 10),
                    newLines: 5,
                    lines: (0..<5).map { DiffLine(kind: .added, text: "line \($0)", newLine: UInt32($0 + 1)) }
                )
            }
        )

        let planned = DiffRowPlanner.unified(file)
        XCTAssertEqual(planned.count, 12, "ten lines plus two headers")

        let capped = LineBudget(limit: 6).apply(to: planned) { $0.chargesBudget }
        XCTAssertEqual(capped.rendered, 6, "six real lines")
        XCTAssertEqual(capped.total, 10, "headers are not counted in the total either")
        XCTAssertEqual(capped.withheld, 4)
        XCTAssertEqual(capped.rows.filter(\.chargesBudget).count, 6)
        XCTAssertTrue(
            capped.rows.contains { !$0.chargesBudget },
            "headers still render; they just do not cost anything"
        )
    }

    func testLineBudgetOfZeroRendersNothingAndStillCounts() {
        let capped = LineBudget(limit: 0).apply(to: Array(1...3))

        XCTAssertTrue(capped.rows.isEmpty)
        XCTAssertEqual(capped.total, 3)
        XCTAssertEqual(capped.withheld, 3)
    }

    // MARK: - Language detection

    func testLanguageDetectionMapsTheExtensionsTheDiffAndBlobViewersRelyOn() {
        let expectations: [(path: String, language: SyntaxLanguage)] = [
            ("Sources/OpenPawUI/Screens/DiffViewerView.swift", .swift),
            ("host/crates/openpaw-git/src/patch.rs", .rust),
            ("web/src/app.ts", .typescript),
            ("tools/generate.py", .python),
            ("package.json", .json),
            ("README.md", .markdown),
            ("scripts/deploy.sh", .shell),
        ]

        for expectation in expectations {
            XCTAssertEqual(
                SyntaxHighlighter.language(forPath: expectation.path),
                expectation.language,
                expectation.path
            )
        }
    }

    func testLanguageDetectionFallsBackToPlainForAnythingUnrecognised() {
        XCTAssertEqual(SyntaxHighlighter.language(forPath: "vendor/blob.qqq"), .plain)
        XCTAssertEqual(SyntaxHighlighter.language(forPath: "LICENSE"), .plain)
    }

    // MARK: - Markdown registers

    /// The whole point of the markdown preview is that prose and code do not look alike. If a code span ever
    /// renders in the serif face, the two-register idea is gone and this test is the thing that notices.
    func testMarkdownRenderingStylesCodeSpansDifferentlyFromProse() {
        let source = """
            # Rebuild the host

            - run `cargo build --workspace` first
            - then read the log
            """

        let rendered = MarkdownRenderer.render(source)
        XCTAssertFalse(rendered.characters.isEmpty, "a heading and a list must produce text")

        var headingFont: Font?
        var proseFont: Font?
        var codeFont: Font?

        for run in rendered.runs {
            let text = String(rendered[run.range].characters)
            if text.contains("Rebuild the host") { headingFont = run.font }
            if text.contains("cargo build --workspace") { codeFont = run.font }
            if text.contains("then read the log") { proseFont = run.font }
        }

        XCTAssertEqual(codeFont, OpenPawTheme.Machine.code, "code spans belong to the machine register")
        XCTAssertEqual(proseFont, OpenPawTheme.Human.proseTight, "list prose belongs to the human register")
        XCTAssertNotEqual(codeFont, proseFont, "a code span must not look like a sentence")
        XCTAssertNotNil(headingFont)
        XCTAssertNotEqual(headingFont, proseFont, "a heading must not look like body text")
    }

    func testMarkdownBlocksRecoverHeadingLevelAndListStructure() {
        let blocks = MarkdownRenderer.blocks(
            """
            # Title

            ## Detail

            - one
            - two
            """
        )

        XCTAssertTrue(blocks.contains { $0.kind == .heading(level: 1) })
        XCTAssertTrue(blocks.contains { $0.kind == .heading(level: 2) })

        let listItems = blocks.filter { block in
            if case .listItem = block.kind { return true }
            return false
        }
        XCTAssertEqual(listItems.count, 2, "both bullets are their own block")
    }

    func testMarkdownRendererFallsBackToPlainProseRatherThanRenderingNothing() {
        let rendered = MarkdownRenderer.render("just a sentence")

        XCTAssertEqual(String(rendered.characters), "just a sentence")
        XCTAssertFalse(rendered.characters.isEmpty)
    }

    // MARK: - Blob windowing

    func testBlobWindowKeepsTheFocusLineInsideTheBudget() {
        let text = (1...5_000).map { "line \($0)" }.joined(separator: "\n")
        let window = BlobText.window(text, budget: LineBudget(limit: 300), focusLine: 4_000)

        XCTAssertEqual(window.shown, 300)
        XCTAssertEqual(window.total, 5_000)
        XCTAssertTrue(window.isTruncated)
        XCTAssertLessThanOrEqual(window.firstLine, 4_000)
        XCTAssertGreaterThan(window.firstLine + window.shown, 4_000, "the hit must be on screen")
        XCTAssertTrue(window.text.contains("line 4000"))
        XCTAssertEqual(window.note, "Showing lines \(window.firstLine) to \(window.firstLine + 299) of 5000.")
    }

    func testBlobWindowStartsAtTheTopWhenThereIsNoFocusLine() {
        let text = (1...100).map(String.init).joined(separator: "\n")
        let window = BlobText.window(text, budget: LineBudget(limit: 10))

        XCTAssertEqual(window.firstLine, 1)
        XCTAssertEqual(window.shown, 10)
        XCTAssertEqual(window.note, "Showing first 10 lines of 100. 90 more are not rendered.")
    }

    func testBlobWindowLeavesShortFilesAlone() {
        let window = BlobText.window("a\nb\nc", budget: .blob)

        XCTAssertEqual(window.text, "a\nb\nc")
        XCTAssertEqual(window.firstLine, 1)
        XCTAssertFalse(window.isTruncated)
        XCTAssertNil(window.note)
    }

    // MARK: - Preview navigation policy

    /// The preview is a window onto one forwarded port. Anything else is the open internet wearing the
    /// preview's chrome, so the policy refuses it and says which origin it expected.
    func testPreviewPolicyAllowsTheProxyOriginAndRefusesEverythingElse() throws {
        let proxy = URL(string: "http://127.0.0.1:49871/")!
        let policy = try XCTUnwrap(PreviewNavigationPolicy(proxyURL: proxy))

        XCTAssertTrue(policy.decide(for: proxy).isAllowed)
        XCTAssertTrue(
            policy.decide(for: URL(string: "http://127.0.0.1:49871/settings?tab=network#top")!).isAllowed,
            "paths, queries and fragments do not change the origin"
        )
        XCTAssertTrue(policy.decide(for: URL(string: "about:blank")!).isAllowed, "WebKit's own empty page")

        XCTAssertFalse(policy.decide(for: URL(string: "https://example.com/track.js")!).isAllowed)
        XCTAssertFalse(
            policy.decide(for: URL(string: "http://127.0.0.1:3000/")!).isAllowed,
            "a different port is a different dev server"
        )
        XCTAssertFalse(
            policy.decide(for: URL(string: "https://127.0.0.1:49871/")!).isAllowed,
            "a different scheme is a different origin"
        )
    }

    func testPreviewPolicyRefusalNamesTheOriginItExpectedAndTheOneItSaw() throws {
        let policy = try XCTUnwrap(
            PreviewNavigationPolicy(proxyURL: URL(string: "http://127.0.0.1:49871/")!)
        )

        guard case .refuse(let reason) = policy.decide(for: URL(string: "https://example.com/oauth")!) else {
            return XCTFail("a foreign origin must be refused")
        }
        XCTAssertTrue(reason.contains("example.com"), "the reason names where the page tried to go")
        XCTAssertTrue(reason.contains("127.0.0.1"), "and where it is allowed to go")
    }

    func testPreviewOriginResolvesDefaultPortsSoTheyCompareEqual() {
        XCTAssertEqual(
            PreviewOrigin(url: URL(string: "http://example.com/a")!),
            PreviewOrigin(url: URL(string: "http://example.com:80/b")!)
        )
        XCTAssertNil(PreviewOrigin(url: URL(string: "mailto:someone@example.com")!))
    }

    // MARK: - Remote address

    /// The address bar shows where the bytes live, not which ephemeral loopback port the tunnel picked today.
    func testRemoteAddressShowsTheHostAndItsPortRatherThanTheLocalProxy() {
        let address = PreviewAddress.remote(
            proxyURL: URL(string: "http://127.0.0.1:49871/settings?tab=network"),
            hostLabel: "studio",
            port: 5173
        )

        XCTAssertEqual(address, "studio:5173/settings?tab=network")
        XCTAssertFalse(address.contains("49871"), "the local proxy port teaches the wrong mental model")
        XCTAssertFalse(address.contains("127.0.0.1"))
    }

    func testRemoteAddressFallsBackToTheRootPathBeforeAnythingHasLoaded() {
        XCTAssertEqual(
            PreviewAddress.remote(proxyURL: nil, hostLabel: "studio", port: 3000),
            "studio:3000/"
        )
    }

    // MARK: - Preview errors

    func testPreviewErrorForAnEmptyAllowlistTellsTheUserWhereToAddThePort() {
        let error = PreviewError.portNotAllowlisted(port: 5173, allowlisted: [])

        XCTAssertEqual(error.title, "This host proxies no ports")
        XCTAssertTrue(error.direction.contains("preview_ports"))
    }

    func testPreviewErrorForAWrongPortListsTheOnesThatWork() {
        let error = PreviewError.portNotAllowlisted(port: 8080, allowlisted: [3000, 5173])

        XCTAssertEqual(error.title, "That port is not allowlisted")
        XCTAssertTrue(error.direction.contains("3000, 5173"))
    }

    func testPreviewErrorForADeadDevServerNamesThePortAndTheAction() {
        let error = PreviewError.devServerNotRunning(port: 5173)

        XCTAssertEqual(error.title, "Nothing is listening on port 5173")
        XCTAssertTrue(error.direction.contains("Start the dev server"))
    }

    /// The daemon answers the proxy route itself: 403 when the allowlist refuses the port, 502/503/504 when the
    /// tunnel is live but nothing is behind it. Both are successful navigations to WebKit, so this mapping is
    /// the only thing standing between the reader and a raw gateway error rendered as their dev server.
    func testProxyStatusDistinguishesARefusedPortFromADeadDevServer() {
        XCTAssertEqual(
            PreviewError(proxyStatus: 403, port: 8080, allowlisted: [3000, 5173]),
            .portNotAllowlisted(port: 8080, allowlisted: [3000, 5173])
        )
        for status in [502, 503, 504] {
            XCTAssertEqual(
                PreviewError(proxyStatus: status, port: 5173, allowlisted: [5173]),
                .devServerNotRunning(port: 5173),
                "status \(status) is upstream's fault, not the daemon's"
            )
        }
    }

    func testProxyStatusLeavesOrdinarySuccessesAndAppErrorsAlone() {
        // A dev server is entitled to answer 404 or 500 for its own routes; that is the page's business.
        for status in [200, 204, 301, 304, 404, 418, 500] {
            XCTAssertNil(
                PreviewError(proxyStatus: status, port: 5173, allowlisted: [5173]),
                "status \(status) is the page's own answer and must render"
            )
        }
    }

    // MARK: - Layout threshold

    /// A phone is always compact, and so is any window too narrow to carry a list beside a diff. The width rule
    /// is what makes this decidable on macOS at all: `horizontalSizeClass` does not exist there, so a
    /// size-class-only test would have reported "regular" for a 390-point render.
    func testNarrowWidthsUseTheStackedLayoutOnEveryPlatform() {
        XCTAssertTrue(DiffViewerView.prefersCompact(width: 390, sizeClassIsCompact: false), "iPhone width")
        XCTAssertTrue(DiffViewerView.prefersCompact(width: 719, sizeClassIsCompact: false), "just too narrow")
        XCTAssertFalse(DiffViewerView.prefersCompact(width: 720, sizeClassIsCompact: false), "exactly enough")
        XCTAssertFalse(DiffViewerView.prefersCompact(width: 1_024, sizeClassIsCompact: false), "iPad landscape")
    }

    func testACompactSizeClassOverridesAGenerousWidth() {
        XCTAssertTrue(
            DiffViewerView.prefersCompact(width: 1_366, sizeClassIsCompact: true),
            "an iPad in a narrow slide-over reports compact even when the pane is wide"
        )
    }

    /// Split needs room for the list plus a diff column that does not scroll for every line.
    func testSplitThresholdLeavesRoomForBothPanes() {
        XCTAssertGreaterThanOrEqual(DiffViewerView.splitMinimumWidth, 320 + 380)
    }

    // MARK: - Patch text

    /// `Copy patch` promises something a person can paste into `git apply`. That promise is only kept if the
    /// prefixes, the header and the file markers are all exactly right.
    func testUnifiedPatchRebuildsAnApplyablePatch() {
        let patch = UnifiedPatch.text(for: Self.replacementFile())
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertEqual(lines[0], "diff --git a/src/app.swift b/src/app.swift")
        XCTAssertEqual(lines[1], "--- a/src/app.swift")
        XCTAssertEqual(lines[2], "+++ b/src/app.swift")
        XCTAssertEqual(lines[3], "@@ -10,4 +10,5 @@")
        XCTAssertEqual(lines[4], " unchanged before")
        XCTAssertEqual(lines[5], "-removed one")
        XCTAssertEqual(lines[6], "-removed two")
        XCTAssertEqual(lines[7], "+added one")
        XCTAssertEqual(lines[8], "+added two")
        XCTAssertEqual(lines[9], "+added three")
        XCTAssertEqual(lines[10], " unchanged after")
    }

    func testUnifiedPatchMarksRenamesAndRefusesToInventBinaryContent() {
        let renamed = UnifiedPatch.text(
            for: FileDiff(path: "new/name.swift", oldPath: "old/name.swift", change: .renamed)
        )
        XCTAssertTrue(renamed.contains("rename from old/name.swift"))
        XCTAssertTrue(renamed.contains("rename to new/name.swift"))

        let binary = UnifiedPatch.text(
            for: FileDiff(path: "assets/icon.png", change: .modified, binary: true)
        )
        XCTAssertTrue(binary.contains("Binary files a/assets/icon.png and b/assets/icon.png differ"))
        XCTAssertFalse(binary.contains("@@"), "there are no hunks to print")
    }

    func testDeletedFileUsesDevNullOnTheNewSide() {
        let patch = UnifiedPatch.text(for: FileDiff(path: "gone.txt", change: .deleted))

        XCTAssertTrue(patch.contains("--- a/gone.txt"))
        XCTAssertTrue(patch.contains("+++ /dev/null"))
    }

    // MARK: - Status grouping

    func testStatusGroupsDropEmptySectionsAndKeepGitsOrder() {
        let status = RepoStatus(
            branch: "main",
            ahead: 2,
            staged: [StatusEntry(path: "a.swift", change: .modified)],
            unstaged: [],
            untracked: [StatusEntry(path: "scratch.txt", change: .added)]
        )

        let groups = RepoStatusGroup.groups(of: status)
        XCTAssertEqual(groups.map(\.kind), [.staged, .untracked], "an empty section is noise")
        XCTAssertTrue(status.isDirty)
    }

    /// Staged paths must open the staged comparison. Sending them to the working-tree diff would show a reader
    /// the opposite of what they clicked on.
    func testStatusGroupsPointAtTheComparisonThatExplainsThem() {
        XCTAssertEqual(RepoStatusGroup.Kind.staged.diffMode, .staged)
        XCTAssertEqual(RepoStatusGroup.Kind.unstaged.diffMode, .workingTree)
        XCTAssertEqual(RepoStatusGroup.Kind.untracked.diffMode, .workingTree)
    }

    func testCleanStatusHasNoGroupsAtAll() {
        let status = RepoStatus(branch: "main")

        XCTAssertFalse(status.isDirty)
        XCTAssertTrue(RepoStatusGroup.groups(of: status).isEmpty)
    }

    // MARK: - Search grouping

    func testSearchMatchesGroupByFileInTheHostsRankedOrder() {
        let groups = SearchGroup.group([
            ContentMatch(path: "b.swift", line: 4, text: "needle"),
            ContentMatch(path: "a.swift", line: 9, text: "needle"),
            ContentMatch(path: "b.swift", line: 40, text: "needle again"),
        ])

        XCTAssertEqual(groups.map(\.path), ["b.swift", "a.swift"], "first-seen order, not alphabetical")
        XCTAssertEqual(groups[0].matches.map(\.line), [4, 40])
        XCTAssertEqual(groups[1].matches.count, 1)
    }

    // MARK: - Tree ordering

    func testTreeOrderPutsDirectoriesFirstThenNamesCaseInsensitively() {
        let entries = [
            TreeEntry(name: "README.md", path: "README.md", kind: .file),
            TreeEntry(name: "sources", path: "sources", kind: .directory),
            TreeEntry(name: "Assets", path: "Assets", kind: .directory),
            TreeEntry(name: "build.sh", path: "build.sh", kind: .file),
        ]

        let ordered = entries.sorted(by: TreeEntryCopy.order).map(\.name)
        XCTAssertEqual(ordered, ["Assets", "sources", "build.sh", "README.md"])
    }

    /// A symlink is never opened, whichever way the host reports it. This is a security property, so it is
    /// asserted rather than assumed.
    func testSymlinksNeverOpenHoweverTheHostReportsThem() {
        let byKind = TreeEntry(name: "link", path: "link", kind: .symlink)
        let byFlag = TreeEntry(name: "link", path: "link", kind: .file, isSymlink: true)
        let plain = TreeEntry(name: "main.swift", path: "main.swift", kind: .file)

        XCTAssertFalse(TreeEntryCopy.opens(byKind))
        XCTAssertFalse(TreeEntryCopy.opens(byFlag))
        XCTAssertTrue(TreeEntryCopy.opens(plain))
        XCTAssertEqual(TreeEntryCopy.glyph(byFlag), "link", "and it does not look like a file")
    }

    // MARK: - Recent files

    func testRecentFilesAreMostRecentFirstWithoutDuplicatesAndCapped() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "openpaw.tests.\(UUID().uuidString)"))
        let store = RecentFilesStore(repo: "openpaw", defaults: defaults)

        store.record("a.swift")
        store.record("b.swift")
        store.record("a.swift")
        XCTAssertEqual(store.paths, ["a.swift", "b.swift"], "revisiting a file promotes it")

        for index in 0..<RecentFilesStore.capacity { store.record("file\(index).swift") }
        XCTAssertEqual(store.paths.count, RecentFilesStore.capacity)
        XCTAssertFalse(store.paths.contains("a.swift"), "the oldest entries fall off the end")

        let reloaded = RecentFilesStore(repo: "openpaw", defaults: defaults)
        XCTAssertEqual(reloaded.paths, store.paths, "recents survive the view being rebuilt")
    }

    // MARK: - Fixtures

    /// One hunk: a context line, two removals, three additions, a context line.
    private static func replacementFile() -> FileDiff {
        FileDiff(
            path: "src/app.swift",
            change: .modified,
            additions: 3,
            deletions: 2,
            hunks: [
                Hunk(
                    header: "@@ -10,4 +10,5 @@",
                    oldStart: 10,
                    oldLines: 4,
                    newStart: 10,
                    newLines: 5,
                    lines: [
                        DiffLine(kind: .context, text: "unchanged before", oldLine: 10, newLine: 10),
                        DiffLine(kind: .removed, text: "removed one", oldLine: 11),
                        DiffLine(kind: .removed, text: "removed two", oldLine: 12),
                        DiffLine(kind: .added, text: "added one", newLine: 11),
                        DiffLine(kind: .added, text: "added two", newLine: 12),
                        DiffLine(kind: .added, text: "added three", newLine: 13),
                        DiffLine(kind: .context, text: "unchanged after", oldLine: 13, newLine: 14),
                    ]
                )
            ]
        )
    }
}
