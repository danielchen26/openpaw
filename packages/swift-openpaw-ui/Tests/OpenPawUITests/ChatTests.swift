import Foundation
import OpenPawProtocol
import Testing
@testable import OpenPawUI

/// A real two-hunk patch, built line by line rather than as a multi-line literal.
///
/// The whitespace here is load bearing — a context line is a leading space, and one of them is a *blank* context
/// line that is nothing but that space — so the test states each line explicitly instead of trusting the indent
/// stripping rules of a `"""` literal.
private let twoHunkPatch = [
    "diff --git a/Sources/App/Ledger.swift b/Sources/App/Ledger.swift",
    "index 3f1a2b4..9c8d7e6 100644",
    "--- a/Sources/App/Ledger.swift",
    "+++ b/Sources/App/Ledger.swift",
    "@@ -12,7 +12,8 @@ struct Ledger {",
    "     func total() -> Decimal {",
    "-        entries.reduce(0) { $0 + $1.amount }",
    "+        entries",
    "+            .reduce(0) { $0 + $1.amount }",
    "     }",
    " ",
    "@@ -48,4 +49,5 @@ extension Ledger {",
    "     var isBalanced: Bool {",
    "-        total() == .zero",
    "+        total().isZero",
    "     }",
    "+}",
    "\\ No newline at end of file",
].joined(separator: "\n")

private func decodeEvents(_ json: String) throws -> [Event] {
    try OpenPawCoding.decoder.decode([Event].self, from: Data(json.utf8))
}

@Suite("Mini diff parsing")
struct MiniDiffTests {

    @Test func countsEveryLineKindAcrossTwoHunks() {
        let diff = MiniDiff.parse(twoHunkPatch)

        #expect(diff.hunkCount == 2)
        #expect(diff.added == 4)
        #expect(diff.removed == 2)
        #expect(diff.context == 5)
        // The `---` and `+++` file headers begin with `-` and `+`. Counting them as changed lines is the classic
        // way to get a mini diff wrong, so the total is asserted too.
        #expect(diff.lines.count == 11)
    }

    /// The patch already states its numbering; the parser's whole job is to carry it through unchanged, including
    /// restarting at the second hunk header instead of continuing from the first.
    @Test func preservesLineNumbersAndRestartsAtEachHunk() {
        let diff = MiniDiff.parse(twoHunkPatch)

        let first = diff.lines[0]
        #expect(first.kind == .context)
        #expect(first.oldLine == 12)
        #expect(first.newLine == 12)

        let removed = diff.lines[1]
        #expect(removed.kind == .removed)
        #expect(removed.oldLine == 13)
        #expect(removed.newLine == nil)
        #expect(removed.text == "        entries.reduce(0) { $0 + $1.amount }")

        // Two added lines replace one removed line: the new-side cursor advances twice, the old side not at all.
        #expect(diff.lines[2].kind == .added)
        #expect(diff.lines[2].oldLine == nil)
        #expect(diff.lines[2].newLine == 13)
        #expect(diff.lines[3].kind == .added)
        #expect(diff.lines[3].newLine == 14)

        // Closing brace of the first hunk: old side has caught up by one, new side by two.
        #expect(diff.lines[4].oldLine == 14)
        #expect(diff.lines[4].newLine == 15)

        // The blank context line is still a line, and dropping it would misnumber everything after it.
        #expect(diff.lines[5].kind == .context)
        #expect(diff.lines[5].text == "")
        #expect(diff.lines[5].oldLine == 15)
        #expect(diff.lines[5].newLine == 16)

        // Second hunk: numbering comes from its own header, not from where the first hunk left off.
        #expect(diff.lines[6].kind == .context)
        #expect(diff.lines[6].oldLine == 48)
        #expect(diff.lines[6].newLine == 49)
        #expect(diff.lines[7].kind == .removed)
        #expect(diff.lines[7].oldLine == 49)
        #expect(diff.lines[8].kind == .added)
        #expect(diff.lines[8].newLine == 50)
        #expect(diff.lines[9].oldLine == 50)
        #expect(diff.lines[9].newLine == 51)
        #expect(diff.lines[10].kind == .added)
        #expect(diff.lines[10].newLine == 52)
    }

    /// `\ No newline at end of file` is a note about the previous line, not a line of its own.
    @Test func dropsTheNoNewlineNote() {
        let diff = MiniDiff.parse(twoHunkPatch)
        #expect(!diff.lines.contains { $0.text.contains("No newline at end of file") })
    }

    /// Counts are optional in the unified format: a single-line hunk is written `@@ -1 +1 @@`.
    @Test func readsHunkHeadersWithAndWithoutCounts() {
        #expect(MiniDiff.hunkHeader("@@ -12,7 +48,9 @@ struct Ledger {").map { [$0.old, $0.new] } == [12, 48])
        #expect(MiniDiff.hunkHeader("@@ -1 +1 @@").map { [$0.old, $0.new] } == [1, 1])
        // A new file starts its pre-image at zero.
        #expect(MiniDiff.hunkHeader("@@ -0,0 +1,5 @@").map { [$0.old, $0.new] } == [0, 1])
        #expect(MiniDiff.hunkHeader("     func total() -> Decimal {") == nil)
        #expect(MiniDiff.hunkHeader("@@ malformed") == nil)
    }

    @Test func ignoresAPatchWithNoHunks() {
        let headerOnly = [
            "diff --git a/a.txt b/a.txt",
            "old mode 100644",
            "new mode 100755",
        ].joined(separator: "\n")
        let diff = MiniDiff.parse(headerOnly)
        #expect(diff.isEmpty)
        #expect(diff.hunkCount == 0)
    }
}

@Suite("Context window meter")
struct ContextLoadTests {

    /// The exact thresholds, checked on both sides of each boundary. A meter that turns amber one percent early
    /// trains people to ignore it.
    @Test func classifiesEachThresholdBoundary() {
        #expect(ContextLoad(percent: 0) == .nominal)
        #expect(ContextLoad(percent: 84) == .nominal)
        #expect(ContextLoad(percent: 84.99) == .nominal)
        #expect(ContextLoad(percent: 85) == .warn)
        #expect(ContextLoad(percent: 90) == .warn)
        #expect(ContextLoad(percent: 94.99) == .warn)
        #expect(ContextLoad(percent: 95) == .critical)
        #expect(ContextLoad(percent: 100) == .critical)
    }

    /// The meter must agree with the notification the user already received: the host raises a context warning at
    /// its own threshold, and a header that disagreed with the inbox would be a bug the user cannot explain.
    @Test func warnsAtTheSameThresholdTheHostDoes() {
        #expect(ContextLoad.warnPercent == InboxProjection.contextWarningPercent)
        #expect(ContextLoad(percent: InboxProjection.contextWarningPercent) == .warn)
    }

    /// Colour is never the only carrier, so every level owes the reader a word.
    @Test func namesEveryLevel() {
        for load in ContextLoad.allCases {
            #expect(!load.word.isEmpty)
        }
        #expect(ContextLoad.nominal.word != ContextLoad.warn.word)
        #expect(ContextLoad.warn.word != ContextLoad.critical.word)
    }
}

@Suite("Session vitals from the preview fixture")
struct SessionVitalsFixtureTests {

    /// Every tool call the stream opened and never closed, and the name it was opened under. The header must name
    /// one of these, never the last call that finished.
    private static func openTools(in events: [Event]) -> [String: String] {
        var open: [String: String] = [:]
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            switch event.body {
            case .toolStarted(let started): open[started.callID] = started.tool
            case .toolCompleted(let done): open.removeValue(forKey: done.callID)
            case .toolFailed(let failed): open.removeValue(forKey: failed.callID)
            default: break
            }
        }
        return open
    }

    /// The working fixture is captured mid-tool-call with nothing pending. The header has to say the agent is
    /// working *and* which tool it is inside, and the tool it names must be one that is still open: naming the
    /// last call that finished would tell the reader the agent is busy with something it stopped doing.
    @Test func reportsWorkingOnAToolThatIsStillOpen() {
        let events = PreviewBackend.events(for: PreviewBackend.workingSessionID)
        #expect(!events.isEmpty, "the populated fixture must carry a mid-run session")

        let open = Self.openTools(in: events)
        #expect(!open.isEmpty, "the fixture must leave a tool call running for this to mean anything")

        let vitals = SessionVitals.derive(from: events)
        guard case .working(let tool) = vitals.activity else {
            Issue.record("expected .working, got \(vitals.activity)")
            return
        }
        #expect(tool != nil, "the header shows the tool name, so it must be carried through")
        #expect(open.values.contains(tool ?? ""), "vitals named \(tool ?? "nil"), open tools are \(open.values)")
    }

    /// The Claude fixture leaves a tool running *and* three requests unanswered, and then `.waiting` is the only
    /// honest header: a pending decision outranks a running tool, because a header that said "working" while
    /// requests sat unanswered would hide the one thing on screen that needs a person.
    @Test func aPendingRequestOutranksARunningTool() {
        let events = PreviewBackend.events(for: PreviewBackend.claudeSessionID)
        #expect(!Self.openTools(in: events).isEmpty, "a tool is still open, so this is a genuine contest")

        let vitals = SessionVitals.derive(from: events)
        guard case .waiting(let reason) = vitals.activity else {
            Issue.record("expected .waiting while requests are unanswered, got \(vitals.activity)")
            return
        }
        #expect(!reason.isEmpty, "the header states what it is waiting on, not just that it is waiting")
    }

    /// The same stream feeds the meters, so the fixture has to exercise them or the header renders empty in every
    /// snapshot and nobody notices it is broken.
    @Test func carriesTheNumbersTheHeaderMetersNeed() {
        let vitals = SessionVitals.derive(from: PreviewBackend.events(for: PreviewBackend.claudeSessionID))

        #expect(vitals.contextPercent != nil)
        #expect(vitals.contextUsedTokens != nil)
        #expect(vitals.contextMaxTokens != nil)
        #expect(vitals.inputTokens > 0)
        #expect(vitals.outputTokens > 0)
        #expect(vitals.lastSeq > 0)
    }

    /// What the header actually calls: the model's own accessor over its ingested transcript, not a loose array.
    @MainActor
    @Test func theModelReportsTheSameVitalsAsTheRawStream() {
        let model = PreviewBackend.model()
        let direct = SessionVitals.derive(from: PreviewBackend.events(for: PreviewBackend.claudeSessionID))
        #expect(model.vitals(for: PreviewBackend.claudeSessionID) == direct)
    }
}

@Suite("Permission rows in history")
struct PermissionRowStateTests {

    private static let destructive = Risk(
        riskClass: .destructiveShell,
        requiresDetailExpansion: true,
        reasons: ["rm removes files"]
    )

    private static func row(decision: ActionID?, decidedBy: DecidedBy?) -> PermissionRow {
        PermissionRow(
            id: "req_9f21",
            seq: 42,
            timestamp: Date(timeIntervalSince1970: 1_775_000_000),
            request: PermissionRequested(
                requestID: "req_9f21",
                tool: "Bash",
                summary: "Remove the build directory",
                command: "rm -rf .build",
                paths: [".build"],
                risk: destructive,
                actions: [.approveOnce, .deny, .stop]
            ),
            decision: decision,
            decidedBy: decidedBy
        )
    }

    /// A request with no resolution is still asking, and the card renders a control that opens the approval sheet.
    @Test func anUnresolvedRequestIsLive() {
        let row = Self.row(decision: nil, decidedBy: nil)
        #expect(row.isLive)
        #expect(!row.isSettled)
        #expect(row.settledDescription == nil)
    }

    /// Once resolved the row is history. Rendering it as a live prompt would invite a second decision on a request
    /// the host has already closed.
    @Test func aResolvedRequestIsSettledAndReadsAsADecision() {
        let row = Self.row(decision: .approveOnce, decidedBy: .device)
        #expect(row.isSettled)
        #expect(!row.isLive)
        #expect(row.settledDescription == "Approved once · from this device")
    }

    /// The device is not the only thing that can decide: the terminal, a policy and a timeout all resolve requests,
    /// and history has to say which one did, because "who approved this" is an audit question.
    @Test func namesWhoDecided() {
        #expect(Self.row(decision: .deny, decidedBy: .terminal).settledDescription == "Denied · in the terminal")
        #expect(
            Self.row(decision: .approveAlways, decidedBy: .policy).settledDescription
                == "Approved always · by policy"
        )
        #expect(Self.row(decision: .deny, decidedBy: .timeout).settledDescription == "Denied · by timeout")
        #expect(Self.row(decision: .stop, decidedBy: .device).settledDescription == "Stopped · from this device")
        // A decision with no recorded source still reads as settled rather than as a question.
        #expect(Self.row(decision: .acknowledge, decidedBy: nil).settledDescription == "Acknowledged")
    }

    /// Every action reads in the past tense, because by the time it is on screen it has happened.
    @Test func everyActionHasAPastTenseForm() {
        for action in ActionID.allCases {
            let description = Self.row(decision: action, decidedBy: .device).settledDescription
            #expect(description?.hasSuffix("· from this device") == true)
            #expect(description?.isEmpty == false)
        }
    }
}

@Suite("Event log rendering")
struct EventLogTests {

    private static let toolStarted = """
    [{"version":"1","event_id":"evt_0000000000000000000000a1","session_id":"sess_cc-57ae0add",
      "agent":"claude-code","seq":7,"timestamp":"2026-08-20T14:30:02Z","cwd":"/Users/dev/src/openpaw",
      "git_branch":"main","multiplexer_target":null,"type":"tool.started",
      "payload":{"call_id":"toolu_01","tool":"Bash","summary":"Run the unit suite",
      "command":"pytest tests/unit -q","paths":["tests/unit"],
      "risk":{"class":"read_only","requires_detail_expansion":false,"reasons":[]}}}]
    """

    /// A one-line summary has to name the thing that matters for that type. For a tool start that is the tool and
    /// the command, because those are what a person scans a hundred rows looking for.
    @Test func summarisesAToolStart() throws {
        let event = try decodeEvents(Self.toolStarted)[0]
        let line = EventSummary.line(for: event)
        #expect(line.contains("Bash"))
        #expect(line.contains("pytest tests/unit -q"))
        #expect(!line.contains("\n"), "the log row is one line")
    }

    /// The point of this screen is that it shows the wire format, so the payload must come back with snake_case
    /// keys exactly as the host sent them — not re-spelled in Swift's camelCase.
    @Test func printsThePayloadAsItArrivedOnTheWire() throws {
        let event = try decodeEvents(Self.toolStarted)[0]
        let json = EventPayload.json(for: event)

        #expect(json.contains("\"call_id\""))
        #expect(json.contains("\"requires_detail_expansion\""))
        #expect(!json.contains("callID"))
        // Only the payload, not the envelope around it.
        #expect(!json.contains("\"session_id\""))
        #expect(!json.contains("\"seq\""))
        // Indented, so it is readable rather than one long line.
        #expect(json.contains("\n"))
        #expect((try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil, "must still be valid JSON")
    }

    /// An empty selection means "everything". A filter that started by hiding all rows would be a broken screen.
    @Test func anEmptyFilterKeepsEveryEvent() throws {
        let events = try decodeEvents(Self.toolStarted)
        #expect(EventLogFilter.apply(events, types: []).count == events.count)
        #expect(EventLogFilter.apply(events, types: [.toolStarted]).count == 1)
        #expect(EventLogFilter.apply(events, types: [.fileDeleted]).isEmpty)
        #expect(EventLogFilter.counts(of: events) == [.toolStarted: 1])
    }
}

@Suite("Chat formatting")
struct ChatFormatTests {

    /// The disclosure only appears when something is actually hidden, and it has to say how much — so the total is
    /// the real line count, not the capped one.
    @Test func capsOutputAndReportsTheRealTotal() {
        let twenty = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let capped = ChatFormat.head(twenty, lines: 12)
        #expect(capped.total == 20)
        #expect(capped.text.split(separator: "\n").count == 12)
        #expect(capped.text.hasSuffix("line 12"))

        // A trailing newline is not a line, so a short blob must not claim a disclosure it does not need.
        let short = ChatFormat.head("one\ntwo\n", lines: 12)
        #expect(short.total == 2)
        #expect(short.text == "one\ntwo")
    }

    @Test func formatsMachineRegisterNumbers() {
        #expect(ChatFormat.tokens(842) == "842")
        #expect(ChatFormat.tokens(124_000) == "124.0k")
        #expect(ChatFormat.tokens(2_500_000) == "2.50M")
        #expect(ChatFormat.duration(ms: 812) == "812 ms")
        #expect(ChatFormat.duration(ms: 3_110) == "3.1 s")
        #expect(ChatFormat.duration(ms: 72_000) == "1 m 12 s")
        #expect(ChatFormat.percent(62.4) == "62%")
        #expect(ChatFormat.cost(0.4231) == "$0.42")
        #expect(ChatFormat.cost(0.0004) == "<$0.01")
    }

    /// Sequence numbers sit next to these, so the clock is fixed width and 24 hour regardless of device settings.
    @Test func clockIsFixedWidthAndZeroPadded() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let stamp = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 9, minute: 5, second: 3))!
        #expect(ChatFormat.clock(stamp, calendar: calendar) == "09:05:03")
    }

    /// A lifecycle row is a rule with a label, so the label carries all of the meaning: what happened and the code.
    @Test func lifecycleLabelStatesTheOutcome() {
        let completed = LifecycleRow(
            id: "evt_1", seq: 90, timestamp: Date(timeIntervalSince1970: 0),
            kind: .agentCompleted, reason: nil, exitCode: 0
        )
        #expect(completed.summaryLabel == "agent completed · exit 0")

        let failed = LifecycleRow(
            id: "evt_2", seq: 91, timestamp: Date(timeIntervalSince1970: 0),
            kind: .agentFailed, reason: "adapter closed the socket", exitCode: 1
        )
        #expect(failed.summaryLabel == "agent failed · exit 1 · adapter closed the socket")

        let started = LifecycleRow(
            id: "evt_3", seq: 1, timestamp: Date(timeIntervalSince1970: 0),
            kind: .agentStarted, reason: nil, exitCode: nil
        )
        #expect(started.summaryLabel == "agent started")
    }
}

@Suite("Dictation text rules")
struct DictationDraftTests {

    /// Speech always lands in an editable draft first, so both agent and terminal destinations keep staged text in
    /// front of the live guess. Send or Execute is a separate explicit action.
    @Test func showsTheDraftInFrontOfTheLiveGuessForBothDestinations() {
        let composing = DictationDraft.inProgress(
            draft: "Fix the flaking test", partial: "and drop the retry", mode: .composer
        )
        #expect(composing.committed == "Fix the flaking test ")
        #expect(composing.live == "and drop the retry")

        let streaming = DictationDraft.inProgress(
            draft: "Fix the flaking test", partial: "and drop the retry", mode: .terminal
        )
        #expect(streaming.committed == "Fix the flaking test ")
        #expect(streaming.live == "and drop the retry")
    }

    /// Before the first word is recognised there must still be something on screen, or holding the microphone
    /// looks like it did nothing.
    @Test func standsInForAnEmptyGuess() {
        #expect(DictationDraft.inProgress(draft: "", partial: "", mode: .composer).live == "…")
        #expect(DictationDraft.inProgress(draft: "", partial: "", mode: .terminal).live == "…")
    }

    /// Letting go joins the phrase to the draft with exactly one space, and never turns an empty draft into one
    /// that starts with whitespace.
    @Test func joinsPhrasesWithASingleSpace() {
        #expect(DictationDraft.committing(draft: "", phrase: "run the suite") == "run the suite")
        #expect(DictationDraft.committing(draft: "run it", phrase: "twice") == "run it twice")
        #expect(DictationDraft.committing(draft: "run it ", phrase: "twice") == "run it twice")
        #expect(DictationDraft.committing(draft: "run it\n", phrase: "twice") == "run it\ntwice")
        #expect(DictationDraft.committing(draft: "run it", phrase: "  twice  ") == "run it twice")
        // Silence must not append anything, or every accidental tap adds a space to the draft.
        #expect(DictationDraft.committing(draft: "run it", phrase: "   ") == "run it")
        #expect(DictationDraft.committing(draft: "", phrase: "") == "")
    }

    /// Mixed Chinese and English dictation is a primary use, so both locales are always in the switcher no matter
    /// what the device is set to, and the device's own locale leads when it is a third one.
    @Test func alwaysOffersBothFirstClassLocales() {
        let first = DictationDraft.firstClassLocales
        #expect(first.contains("en-US"))
        #expect(first.contains("zh-CN"))

        let onZH = DictationDraft.localeChoices(deviceLocale: "zh_CN", firstClass: first)
        #expect(onZH == first, "a zh-CN device must not be offered zh-CN twice")

        let onEN = DictationDraft.localeChoices(deviceLocale: "en_US", firstClass: first)
        #expect(onEN == first)

        let onJA = DictationDraft.localeChoices(deviceLocale: "ja_JP", firstClass: first)
        #expect(onJA.first == "ja-JP", "the device locale is the default, so it leads")
        #expect(onJA.contains("en-US"))
        #expect(onJA.contains("zh-CN"))
        #expect(onJA.count == first.count + 1)
    }

    @Test func normalisesUnderscoreLocaleIdentifiers() {
        #expect(DictationDraft.normalize("zh_CN") == "zh-CN")
        #expect(DictationDraft.normalize("en-US") == "en-US")
    }
}
