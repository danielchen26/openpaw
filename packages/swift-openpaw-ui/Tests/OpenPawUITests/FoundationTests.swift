import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import XCTest

@testable import OpenPawUI

// MARK: - Syntax highlighting

final class SyntaxHighlighterTests: XCTestCase {

    private let swiftSource = """
        let count = 42 // tally
        let quoted = "say \\"hi\\""
        """

    /// The invariant that matters most: classification never loses, duplicates or reorders a character. Every
    /// other assertion here is about colour; this one is about correctness.
    private func assertReconstructs(_ source: String, _ language: SyntaxLanguage, budget: Int? = nil) {
        let runs = budget.map { SyntaxHighlighter.runs(source, language: language, budget: $0) }
            ?? SyntaxHighlighter.runs(source, language: language)
        XCTAssertEqual(runs.map(\.text).joined(), source)
    }

    func testSwiftKeywordStringWithEscapedQuoteCommentAndNumber() {
        let runs = SyntaxHighlighter.runs(swiftSource, language: .swift)

        XCTAssertEqual(runs.filter { $0.token == .keyword }.map(\.text), ["let", "let"])
        XCTAssertTrue(runs.contains { $0.text == "42" && $0.token == .number })
        XCTAssertEqual(runs.filter { $0.token == .comment }.map(\.text), ["// tally"])

        // One string run, not two: the escaped quote must not close the literal early.
        let strings = runs.filter { $0.token == .string }
        XCTAssertEqual(strings.count, 1)
        XCTAssertEqual(strings.first?.text, #""say \"hi\"""#)

        assertReconstructs(swiftSource, .swift)
    }

    func testIdentifiersAreNotKeywordsAndCapitalisedOnesAreTypes() {
        let runs = SyntaxHighlighter.runs("var store = HostStore()", language: .swift)
        XCTAssertTrue(runs.contains { $0.text == "var" && $0.token == .keyword })
        XCTAssertTrue(runs.contains { $0.text == "HostStore" && $0.token == .type })
        XCTAssertFalse(runs.contains { $0.text == "store" && $0.token != .plain })
    }

    func testMultiLineConstructsSpanNewlines() {
        let python = """
            x = \"\"\"first
            second\"\"\"
            y = 1
            """
        let strings = SyntaxHighlighter.runs(python, language: .python).filter { $0.token == .string }
        XCTAssertEqual(strings.count, 1)
        XCTAssertTrue(strings.first?.text.contains("first\nsecond") == true)

        let rust = "/* outer /* inner */ still */ let x = 1;"
        let comments = SyntaxHighlighter.runs(rust, language: .rust).filter { $0.token == .comment }
        XCTAssertEqual(comments.map(\.text), ["/* outer /* inner */ still */"])
    }

    func testBudgetCapsStylingAndPassesTheRemainderThroughUnstyled() {
        let runs = SyntaxHighlighter.runs(swiftSource, language: .swift, budget: 4)

        // Everything past the budget arrives as exactly one plain run.
        let expectedRemainder = String(swiftSource.unicodeScalars.dropFirst(4))
        XCTAssertEqual(runs.last?.text, expectedRemainder)
        XCTAssertEqual(runs.last?.token, .plain)
        // Only the first four scalars were eligible for styling, so nothing else is coloured.
        XCTAssertEqual(runs.filter { $0.token != .plain }.map(\.text), ["let"])
        assertReconstructs(swiftSource, .swift, budget: 4)
    }

    func testZeroBudgetYieldsOnePlainRun() {
        let runs = SyntaxHighlighter.runs(swiftSource, language: .swift, budget: 0)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.token, .plain)
        XCTAssertEqual(runs.first?.text, swiftSource)
    }

    func testBudgetHoldsOnALargeInput() {
        // A 1 MB blob must be bounded by the budget, not by the input.
        let blob = String(repeating: "let x = \"abc\" // note\n", count: 50_000)
        XCTAssertGreaterThan(blob.utf8.count, 1_000_000)
        let runs = SyntaxHighlighter.runs(blob, language: .swift, budget: 512)
        XCTAssertEqual(runs.map(\.text).joined(), blob)
        XCTAssertEqual(runs.last?.token, .plain)
    }

    func testUnknownLanguageIsPlainAndUntouched() {
        XCTAssertEqual(SyntaxHighlighter.language(forPath: "notes.rtf"), .plain)
        XCTAssertEqual(SyntaxHighlighter.language(forPath: "Makefile"), .plain)
        XCTAssertEqual(SyntaxHighlighter.language(forPath: ".gitignore"), .plain)

        let runs = SyntaxHighlighter.runs(swiftSource, language: .plain)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.token, .plain)
        XCTAssertEqual(runs.first?.text, swiftSource)
    }

    func testLanguageDetectionByExtension() {
        let expected: [String: SyntaxLanguage] = [
            "Sources/App/main.swift": .swift,
            "src/lib.rs": .rust,
            "web/app.ts": .typescript,
            "web/app.tsx": .typescript,
            "web/app.js": .typescript,
            "tests/conftest.py": .python,
            "package.json": .json,
            "README.md": .markdown,
            "scripts/build.sh": .shell,
            "Cargo.toml": .toml,
            ".github/workflows/ci.yml": .yaml,
            "docs/notes.yaml": .yaml,
        ]
        for (path, language) in expected {
            XCTAssertEqual(SyntaxHighlighter.language(forPath: path), language, path)
        }
    }

    func testEveryGrammarSurvivesEveryFixtureWithoutLosingText() {
        let samples = [
            PreviewFixtures.pythonBlob,
            PreviewFixtures.destructiveCommand,
            "# Title\n\nSee `code` and [a link](https://example.test) and **bold**.\n\n```\nfenced\n```\n",
            "[package]\nname = \"openpaw\"\nversion = \"0.4.1\" # pinned\n",
            "steps:\n  - name: build\n    run: cargo build --locked\n",
            "{\"a\": 1, \"b\": [true, null, \"x\\\"y\"]}",
            "export PATH=\"$HOME/bin:$PATH\" # for mosh\nif [ -d \"${dir}\" ]; then echo 1; fi\n",
        ]
        for language in SyntaxLanguage.allCases {
            for sample in samples {
                assertReconstructs(sample, language)
            }
        }
    }

    func testEmptyInputProducesNoRuns() {
        for language in SyntaxLanguage.allCases {
            XCTAssertTrue(SyntaxHighlighter.runs("", language: language).isEmpty)
        }
    }

    func testCodeBlockSplitsRunsIntoLines() {
        let lines = CodeBlock.highlightedLines(of: "let a = 1\nlet b = 2\n", language: .swift)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(lines[0].characters), "let a = 1")
        XCTAssertEqual(String(lines[1].characters), "let b = 2")
    }

    func testCodeBlockKeepsMultiLineCommentsColouredAcrossTheSplit() {
        let lines = CodeBlock.highlightedLines(of: "/* one\ntwo */\nlet x = 1", language: .swift)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(String(lines[1].characters), "two */")
    }
}

// MARK: - Relative time

final class RelativeTimeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    func testTheSixBrackets() {
        XCTAssertEqual(RelativeTime.short(now, now: now), "now")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-12), now: now), "12s")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-(4 * 60 + 5)), now: now), "4m")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-(3 * 3_600 + 61)), now: now), "3h")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-(2 * 86_400 + 3_600)), now: now), "2d")

        // Past a week it becomes a calendar date, built from the same calendar the formatter reads.
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 20
        components.hour = 12
        let august = Calendar.current.date(from: components)
        XCTAssertNotNil(august)
        XCTAssertEqual(
            RelativeTime.short(august!, now: august!.addingTimeInterval(40 * 86_400)),
            "Aug 20"
        )
    }

    func testBracketBoundaries() {
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-1), now: now), "now")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-2), now: now), "2s")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-59), now: now), "59s")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-60), now: now), "1m")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-3_599), now: now), "59m")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-3_600), now: now), "1h")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-86_399), now: now), "23h")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-86_400), now: now), "1d")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-604_799), now: now), "6d")
    }

    /// A host clock running ahead of the phone must not render a negative age.
    func testFutureTimestampsReadAsNow() {
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(90), now: now), "now")
    }

    func testSpokenFormIsWordsNotAbbreviations() {
        XCTAssertEqual(RelativeTime.spoken(now, now: now), "just now")
        XCTAssertEqual(RelativeTime.spoken(now.addingTimeInterval(-1), now: now), "just now")
        XCTAssertEqual(RelativeTime.spoken(now.addingTimeInterval(-12), now: now), "12 seconds ago")
        XCTAssertEqual(RelativeTime.spoken(now.addingTimeInterval(-60), now: now), "1 minute ago")
        XCTAssertEqual(RelativeTime.spoken(now.addingTimeInterval(-86_400), now: now), "1 day ago")
    }
}

// MARK: - Scrollback match model

final class ScrollbackMatchIndexTests: XCTestCase {

    private func match(line: Int, bytes: Range<Int>, text: String) -> ScrollbackMatch {
        ScrollbackMatch(lineNumber: line, line: text, byteRange: bytes)
    }

    func testMatchesMapToTheirLine() {
        let index = ScrollbackMatchIndex([
            match(line: 7, bytes: 10..<14, text: "second hit on seven"),
            match(line: 3, bytes: 0..<4, text: "hit on three"),
            match(line: 7, bytes: 0..<4, text: "first hit on seven"),
        ])

        XCTAssertEqual(index.count, 3)
        XCTAssertEqual(index.matches(onLine: 3).count, 1)
        XCTAssertEqual(index.matches(onLine: 3).first?.line, "hit on three")
        XCTAssertEqual(index.matches(onLine: 7).count, 2)
        XCTAssertTrue(index.matches(onLine: 4).isEmpty)
        XCTAssertTrue(index.matches(onLine: 0).isEmpty)

        // Ordered by line, then by position along the line.
        XCTAssertEqual(index.matches.map(\.lineNumber), [3, 7, 7])
        XCTAssertEqual(index.matches(onLine: 7).map(\.byteRange.lowerBound), [0, 10])
    }

    func testOrdinalsAndWrappingNavigation() {
        let first = match(line: 3, bytes: 0..<4, text: "aaaa")
        let second = match(line: 9, bytes: 2..<6, text: "xxbbbb")
        let index = ScrollbackMatchIndex([first, second])

        XCTAssertEqual(index.ordinal(of: first), 1)
        XCTAssertEqual(index.ordinal(of: second), 2)
        XCTAssertEqual(index.match(atOrdinal: 2)?.lineNumber, 9)
        XCTAssertNil(index.match(atOrdinal: 3))

        XCTAssertEqual(index.next(after: nil)?.lineNumber, 3)
        XCTAssertEqual(index.next(after: first)?.lineNumber, 9)
        XCTAssertEqual(index.next(after: second)?.lineNumber, 3, "next wraps to the first hit")
        XCTAssertEqual(index.previous(before: first)?.lineNumber, 9, "previous wraps to the last hit")
    }

    func testEmptyIndexNavigatesNowhere() {
        let index = ScrollbackMatchIndex()
        XCTAssertTrue(index.isEmpty)
        XCTAssertNil(index.next(after: nil))
        XCTAssertNil(index.previous(before: nil))
    }

    /// Byte offsets are what a buffer search produces; character indices are what rendering needs. A multi-byte
    /// line is the case that catches a naive conversion.
    func testByteRangeConvertsToCharacterRangeAcrossMultiByteText() {
        let line = "caf\u{00E9} rm -rf"
        let bytes = Array(line.utf8)
        XCTAssertEqual(bytes.count, line.count + 1, "the accented character is two bytes")

        let needleStart = 6  // "rm" begins after "café " -> 5 characters, 6 bytes
        let hit = match(line: 7, bytes: needleStart..<(needleStart + 2), text: line)
        let range = ScrollbackMatchIndex.characterRange(of: hit, in: line)
        XCTAssertNotNil(range)
        XCTAssertEqual(range.map { String(line[$0]) }, "rm")
    }

    func testOutOfBoundsByteRangeDoesNotHighlightRatherThanTrapping() {
        let line = "short"
        XCTAssertNil(
            ScrollbackMatchIndex.characterRange(of: match(line: 1, bytes: 0..<99, text: line), in: line)
        )
        // A negative offset is the only malformed range `Range<Int>` can actually hold, and walking a UTF-8 view
        // backwards past its start traps rather than returning nil, so it has to be refused explicitly.
        XCTAssertNil(
            ScrollbackMatchIndex.characterRange(of: match(line: 1, bytes: -3..<2, text: line), in: line)
        )
        // A range that splits a multi-byte character is not renderable and must be refused.
        XCTAssertNil(
            ScrollbackMatchIndex.characterRange(of: match(line: 1, bytes: 0..<1, text: "\u{00E9}x"), in: "\u{00E9}x")
        )
    }

    func testRowIdentityIsTheAbsoluteLineNumber() {
        XCTAssertEqual(ScrollbackTextView.rowID(forLine: 1_482), 1_482)
    }
}

// MARK: - Preview backend

@MainActor
final class PreviewBackendTests: XCTestCase {

    func testPopulatedModelHasAGatedPendingItemAndATranscript() {
        let model = PreviewBackend.model(.populated)

        let gated = model.pendingInbox.filter { $0.risk?.requiresDetailExpansion == true }
        XCTAssertFalse(gated.isEmpty, "the populated scenario must exercise the safety gate")
        XCTAssertFalse(gated[0].risk?.reasons.isEmpty ?? true, "a gate with no stated reason is a dead end")

        let session = model.sessions.first
        XCTAssertNotNil(session)
        XCTAssertFalse(model.chat(for: session!.sessionID).isEmpty)
        XCTAssertEqual(session?.sessionID, PreviewBackend.claudeSessionID)
    }

    /// Every scenario is a paired device. A header reading "no host" beside a live connection state is a
    /// contradiction, and it made three of the shell screens snapshot their empty path under `.populated`.
    func testEveryScenarioHasHostsAndASelectedOne() {
        for scenario in PreviewBackend.Scenario.allCases {
            let model = PreviewBackend.model(scenario)
            XCTAssertEqual(model.hostStore.hosts.count, 2, "\(scenario.rawValue) has no hosts")
            XCTAssertNotNil(model.selectedHostID, "\(scenario.rawValue) selects no host")
            XCTAssertNotNil(model.selectedHost, "\(scenario.rawValue) selects a host that is not in the store")
        }
    }

    /// The connected transport has to be one the selected host could actually have used, or the terminal header
    /// and the host row disagree about the same connection.
    func testConnectedTransportAgreesWithTheSelectedHost() {
        for scenario in [PreviewBackend.Scenario.populated, .reviewingDestructiveCommand, .empty] {
            let model = PreviewBackend.model(scenario)
            guard case .connected(let transport) = model.connection else {
                return XCTFail("\(scenario.rawValue) should be connected")
            }
            let host = model.selectedHost
            XCTAssertNotNil(host)
            let plausible = [host?.lastSuccessfulTransport, host?.preferredTransport, .ssh]
            XCTAssertTrue(
                plausible.contains(transport),
                "\(scenario.rawValue) reports \(transport) but the host records none of it"
            )
        }
    }

    /// Both auth shapes render, and no fixture inlines key material.
    func testHostFixturesCoverBothAuthShapesAndCarryNoSecrets() {
        let hosts = PreviewBackend.model(.populated).hostStore.hosts
        XCTAssertTrue(hosts.contains { $0.auth == .agentForwarding })
        guard let keyed = hosts.first(where: { if case .privateKey = $0.auth { return true } else { return false } })
        else { return XCTFail("no host exercises a keychain-referenced private key") }
        guard case .privateKey(let reference, let passphrase) = keyed.auth else { return }
        XCTAssertEqual(reference.identifier, "id_ed25519")
        XCTAssertNil(passphrase)

        // One host is pinned and one is not, so the unknown-host prompt has a fixture too.
        XCTAssertTrue(hosts.contains { !$0.knownHosts.isEmpty })
        XCTAssertTrue(hosts.contains { $0.knownHosts.isEmpty })
    }

    func testPopulatedInboxCoversEveryCategoryTheDesignHasToHandle() {
        let model = PreviewBackend.model(.populated)
        let categories = Set(model.inbox.map(\.category))
        for expected: InboxCategory in [.permission, .question, .plan, .toolFailure, .completion] {
            XCTAssertTrue(categories.contains(expected), "missing \(expected.rawValue)")
        }

        // Both sides of the gate are present, which is what makes it legible as conditional.
        let permissions = model.pendingInbox.filter { $0.category == .permission }
        XCTAssertTrue(permissions.contains { $0.risk?.requiresDetailExpansion == true })
        XCTAssertTrue(permissions.contains { $0.risk?.requiresDetailExpansion == false })

        // Destructive outranks everything else in the queue.
        XCTAssertEqual(model.pendingInbox.first?.risk?.riskClass, .destructiveShell)
    }

    func testDeniedRequestReadsAsHistoryNotAsAQuestion() {
        let model = PreviewBackend.model(.populated)
        let denied = model.inbox.first { $0.requestID == "req-force-push" }
        XCTAssertNotNil(denied)
        XCTAssertEqual(denied?.status, .resolved)
        XCTAssertEqual(denied?.resolution, ActionID.deny.rawValue)
        XCTAssertFalse(model.pendingInbox.contains { $0.requestID == "req-force-push" })
    }

    func testTheGateRefusesLocallyUntilTheDetailIsAcknowledged() async {
        let model = PreviewBackend.model(.reviewingDestructiveCommand)
        let item = model.pendingInbox.first { $0.risk?.requiresDetailExpansion == true }
        XCTAssertNotNil(item)
        guard let item else { return }

        XCTAssertFalse(model.isDetailAcknowledged(item))
        let refused = await model.resolve(item, action: .approveOnce)
        XCTAssertFalse(refused, "approval must not reach the host before the command has been shown")
        XCTAssertNotNil(model.lastError)

        model.acknowledgeDetail(item)
        XCTAssertTrue(model.isDetailAcknowledged(item))
        let accepted = await model.resolve(item, action: .approveOnce)
        XCTAssertTrue(accepted)
        XCTAssertEqual(model.inbox.first { $0.id == item.id }?.status, .resolved)
    }

    /// Deny is never gated. Blocking the way out of a dangerous request would be the worst possible reading of
    /// the safety model.
    func testDenyDoesNotRequireAcknowledgement() async {
        let backend = PreviewBackend(.reviewingDestructiveCommand)
        let item = backend.inboxItems.first { $0.risk?.requiresDetailExpansion == true }
        XCTAssertNotNil(item)
        guard let item else { return }

        let result = try? await backend.resolve(
            item: item, action: .deny, answer: nil, detailAcknowledged: false
        )
        XCTAssertEqual(result?.status, "accepted")
        let recorded = await backend.journal.last()
        XCTAssertEqual(recorded?.action, .deny)
    }

    func testBackendRefusesUnacknowledgedApprovalTheWayTheHostDoes() async {
        let backend = PreviewBackend(.populated)
        let item = backend.inboxItems.first { $0.risk?.requiresDetailExpansion == true }
        XCTAssertNotNil(item)
        guard let item else { return }

        do {
            _ = try await backend.resolve(
                item: item, action: .approveOnce, answer: nil, detailAcknowledged: false
            )
            XCTFail("the fixture host must reject this the way the real one does")
        } catch let error as HostClientError {
            guard case .badRequest = error else {
                return XCTFail("expected a bad request, got \(error)")
            }
        } catch {
            XCTFail("expected HostClientError, got \(error)")
        }
    }

    func testVitalsShowTheRunningToolAndTheContextMeter() {
        let model = PreviewBackend.model(.populated)
        let vitals = model.vitals(for: PreviewBackend.claudeSessionID)
        XCTAssertEqual(vitals.contextPercent, 78)
        XCTAssertEqual(vitals.costUSD, 2.41)
        XCTAssertGreaterThan(vitals.lastSeq, 0)
        // The session is waiting on a decision, which outranks the still-running tool in the header.
        guard case .waiting = vitals.activity else {
            return XCTFail("expected the header to read as waiting, got \(vitals.activity)")
        }
    }

    func testTranscriptMergesToolLifecyclesAndCarriesAPlanAndADiff() {
        let model = PreviewBackend.model(.populated)
        let chat = model.chat(for: PreviewBackend.claudeSessionID)

        let tools = chat.compactMap { item -> ToolRow? in
            if case .tool(let row) = item { return row }
            return nil
        }
        // Four tool events for `call-pytest` (started plus three chunks) collapse into one row.
        XCTAssertEqual(tools.filter { $0.id == "call-pytest" }.count, 1)
        let pytest = tools.first { $0.id == "call-pytest" }
        XCTAssertEqual(pytest?.status, .running)
        XCTAssertFalse(pytest?.output.isEmpty ?? true)

        let read = tools.first { $0.id == "call-read-conftest" }
        XCTAssertEqual(read?.status, .succeeded(exitCode: 0, durationMS: 41))

        let plans = chat.compactMap { item -> PlanRow? in
            if case .plan(let row) = item { return row }
            return nil
        }
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.steps.count, 5)
        XCTAssertEqual(Set(plans.first?.steps.map(\.status) ?? []).count, 4, "steps are in mixed states")

        let edits = chat.compactMap { item -> FileEditRow? in
            if case .fileEdit(let row) = item { return row }
            return nil
        }
        XCTAssertEqual(edits.first?.path, "tests/conftest.py")
        XCTAssertNotNil(edits.first?.unifiedDiff)

        // Consecutive thinking deltas join into a single row rather than stacking.
        let thinking = chat.compactMap { item -> ThinkingRow? in
            if case .thinking(let row) = item { return row }
            return nil
        }
        XCTAssertEqual(thinking.count, 1)
        XCTAssertTrue(thinking.first?.text.contains("module-scoped") ?? false)
    }

    func testEveryScenarioIsCoherent() async throws {
        for scenario in PreviewBackend.Scenario.allCases {
            let backend = PreviewBackend(scenario)
            switch scenario {
            case .populated, .reviewingDestructiveCommand:
                XCTAssertEqual(backend.sessionList.count, 4)
                let repos = try await backend.repos()
                XCTAssertFalse(repos.isEmpty)
                XCTAssertFalse(backend.inboxItems.isEmpty)
            case .empty:
                XCTAssertTrue(backend.sessionList.isEmpty)
                let items = try await backend.inbox(status: nil)
                let repos = try await backend.repos()
                XCTAssertTrue(items.isEmpty)
                XCTAssertTrue(repos.isEmpty)
            case .disconnected:
                do {
                    _ = try await backend.sessions()
                    XCTFail("a closed tunnel must throw")
                } catch let error as HostClientError {
                    guard case .transport = error else {
                        return XCTFail("expected a transport failure, got \(error)")
                    }
                }
            }
        }
    }

    func testDisconnectedModelPresentsARecoverableError() {
        let model = PreviewBackend.model(.disconnected)
        XCTAssertEqual(model.connection, .disconnected(reason: "the forwarded port closed"))
        XCTAssertEqual(model.lastError?.title, "The tunnel is down")
        XCTAssertEqual(model.lastError?.isRecoverable, true)
    }

    func testEventStreamResumesFromASequenceNumberAndTerminates() async throws {
        let backend = PreviewBackend(.populated)
        var seen: [UInt64] = []
        for try await event in backend.events(session: PreviewBackend.claudeSessionID, afterSeq: 10) {
            seen.append(event.seq)
        }
        XCTAssertFalse(seen.isEmpty, "the stream must replay, and must finish rather than hang")
        XCTAssertEqual(seen, seen.sorted())
        XCTAssertEqual(seen.first, 11)
    }

    func testRepoFixturesCoverTheThreeCasesADiffViewerGetsWrong() async throws {
        let backend = PreviewBackend(.populated)
        let diff = try await backend.diff(repo: "openpaw", mode: .workingTree, path: nil)
        XCTAssertEqual(diff.files.count, 3)

        let modified = diff.files.first { $0.change == .modified && !$0.binary }
        XCTAssertEqual(modified?.hunks.count, 2)
        XCTAssertFalse(modified?.splitRows().isEmpty ?? true)

        let renamed = diff.files.first { $0.change == .renamed }
        XCTAssertEqual(renamed?.oldPath, "docs/tests.md")

        XCTAssertTrue(diff.files.contains { $0.binary })

        // Narrowing to one path returns just that file, with its own totals.
        let single = try await backend.diff(repo: "openpaw", mode: .workingTree, path: "docs/testing.md")
        XCTAssertEqual(single.files.map(\.path), ["docs/testing.md"])
        XCTAssertEqual(single.additions, 1)
    }

    func testTreeIsThreeLevelsDeepAndBlobsCoverTextAndBinary() async throws {
        let backend = PreviewBackend(.populated)
        let root = try await backend.tree(repo: "openpaw", ref: "HEAD", path: "")
        let src = try await backend.tree(repo: "openpaw", ref: "HEAD", path: "src")
        XCTAssertFalse(root.isEmpty)
        XCTAssertFalse(src.isEmpty)
        let leaves = try await backend.tree(repo: "openpaw", ref: "HEAD", path: "src/openpaw")
        XCTAssertTrue(leaves.allSatisfy { $0.kind == .file })

        let text = try await backend.blob(repo: "openpaw", ref: "HEAD", path: "src/openpaw/auth.py")
        XCTAssertNotNil(text.content.text)

        let binary = try await backend.blob(repo: "openpaw", ref: "HEAD", path: "tests/fixtures/token.bin")
        XCTAssertNil(binary.content.text)
        guard case .binary(let sha256) = binary.content else {
            return XCTFail("expected a digest-only blob")
        }
        XCTAssertEqual(sha256.count, 64)
    }

    func testRepoStatusSearchAuditAndPreviewPorts() async throws {
        let backend = PreviewBackend(.populated)

        let status = try await backend.repoStatus("openpaw")
        XCTAssertEqual(status.branch, "feat/inbox-gate")
        XCTAssertFalse(status.staged.isEmpty)
        XCTAssertTrue(status.staged.contains { $0.change == .renamed && $0.oldPath != nil })

        let hits = try await backend.search(repo: "openpaw", query: "JWT_SECRET", path: nil)
        XCTAssertGreaterThan(hits.count, 1)
        let scoped = try await backend.search(repo: "openpaw", query: "JWT_SECRET", path: "src")
        XCTAssertTrue(scoped.allSatisfy { $0.path.hasPrefix("src") })

        let audit = try await backend.audit(limit: 10)
        let clipped = try await backend.audit(limit: 1)
        XCTAssertFalse(audit.isEmpty)
        XCTAssertEqual(clipped.count, 1)

        // An allowed port proxies; anything else is refused rather than probed and failed.
        XCTAssertEqual(
            try backend.previewURL(port: 5173, path: "index.html").absoluteString,
            "http://127.0.0.1:5173/index.html"
        )
        XCTAssertThrowsError(try backend.previewURL(port: 9999, path: "/"))
    }

    /// Snapshots diff byte-for-byte, so the fixture clock must not move.
    func testFixtureTimestampsAreDeterministic() {
        let first = PreviewBackend(.populated).transcripts[PreviewBackend.claudeSessionID]
        let second = PreviewBackend(.populated).transcripts[PreviewBackend.claudeSessionID]
        XCTAssertEqual(first?.map(\.timestamp), second?.map(\.timestamp))
        XCTAssertEqual(first?.map(\.eventID), second?.map(\.eventID))
        XCTAssertEqual(first?.map(\.seq), Array(1...UInt64(first?.count ?? 0)))
    }
}
