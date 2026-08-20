import Foundation
import Testing
@testable import OpenPawUI
import OpenPawProtocol

/// These tests build events by decoding JSON rather than by calling initialisers. That keeps them stable against
/// the protocol module's constructor shapes, and it means every test here is also a check that the wire format
/// the host emits is the wire format the app reads.
private func events(_ json: String) throws -> [Event] {
    try OpenPawCoding.decoder.decode([Event].self, from: Data(json.utf8))
}

private let session = "sess_cc-57ae0add"

private func envelope(
    _ seq: UInt64,
    _ type: String,
    _ payload: String,
    id: String? = nil,
    at second: Int = 0
) -> String {
    let eventID = id ?? String(format: "evt_%024x", seq)
    let stamp = String(format: "2026-08-20T14:30:%02dZ", second)
    return """
    {"version":"1","event_id":"\(eventID)","session_id":"\(session)","agent":"claude-code",
     "seq":\(seq),"timestamp":"\(stamp)","cwd":"/Users/dev/src/openpaw","git_branch":"main",
     "multiplexer_target":null,"type":"\(type)","payload":\(payload)}
    """
}

private let readOnlyRisk = """
{"class":"read_only","requires_detail_expansion":false,"reasons":[]}
"""

private let destructiveRisk = """
{"class":"destructive_shell","requires_detail_expansion":true,
 "reasons":["rm removes files","sudo escalates privileges"]}
"""

@Suite("Transcript reduction")
struct TranscriptReducerTests {

    /// A tool call arrives as up to four separate events and must render as exactly one card that mutates in
    /// place. Four rows for one command would make a busy agent unreadable.
    @Test func mergesOneToolCallIntoOneRow() throws {
        let stream = try events("""
        [
        \(envelope(0, "tool.started", """
        {"call_id":"toolu_01","tool":"Bash","summary":"Run test suite","command":"pytest tests/unit -q",
         "paths":[],"risk":\(readOnlyRisk)}
        """)),
        \(envelope(1, "tool.output", """
        {"call_id":"toolu_01","chunk":"collected 42 items\\n","stream":"stdout","truncated":false}
        """)),
        \(envelope(2, "tool.output", """
        {"call_id":"toolu_01","chunk":"2 failed, 40 passed\\n","stream":"stdout","truncated":false}
        """)),
        \(envelope(3, "tool.completed", """
        {"call_id":"toolu_01","exit_code":1,"duration_ms":3110}
        """))
        ]
        """)

        let rows = TranscriptReducer().reduce(stream)
        #expect(rows.count == 1)
        guard case .tool(let tool) = rows[0] else {
            Issue.record("expected a tool row, got \(rows[0])")
            return
        }
        #expect(tool.tool == "Bash")
        #expect(tool.command == "pytest tests/unit -q")
        #expect(tool.output == "collected 42 items\n2 failed, 40 passed\n")
        #expect(tool.seq == 0, "the row keeps the seq it started at, which is the resume point")
        guard case .succeeded(let exitCode, let duration) = tool.status else {
            Issue.record("expected success status, got \(tool.status)")
            return
        }
        #expect(exitCode == 1)
        #expect(duration == 3110)
    }

    @Test func toolFailureReplacesRunningStatus() throws {
        let stream = try events("""
        [
        \(envelope(0, "tool.started", """
        {"call_id":"c1","tool":"Edit","paths":["/x/y.rs"],"risk":\(readOnlyRisk)}
        """)),
        \(envelope(1, "tool.failed", """
        {"call_id":"c1","error":"file not found","exit_code":2}
        """))
        ]
        """)
        let rows = TranscriptReducer().reduce(stream)
        #expect(rows.count == 1)
        guard case .tool(let tool) = rows[0], case .failed(let error, let code) = tool.status else {
            Issue.record("expected a failed tool row, got \(rows)")
            return
        }
        #expect(error == "file not found")
        #expect(code == 2)
    }

    /// A failure with no matching start still has to be visible. Silently dropping it would hide exactly the
    /// event a user is looking for.
    @Test func orphanToolFailureStillRenders() throws {
        let stream = try events("""
        [\(envelope(7, "tool.failed", #"{"call_id":"ghost","error":"broken pipe"}"#))]
        """)
        let rows = TranscriptReducer().reduce(stream)
        #expect(rows.count == 1)
        guard case .tool(let tool) = rows[0] else {
            Issue.record("expected a tool row")
            return
        }
        #expect(tool.tool == "unknown")
    }

    @Test func toolOutputIsBudgeted() throws {
        let chunk = String(repeating: "x", count: 900)
        var lines: [String] = [envelope(0, "tool.started", """
        {"call_id":"c1","tool":"Bash","command":"yes","paths":[],"risk":\(readOnlyRisk)}
        """)]
        for index in 1...5 {
            lines.append(envelope(
                UInt64(index), "tool.output",
                #"{"call_id":"c1","chunk":"\#(chunk)","stream":"stdout","truncated":false}"#
            ))
        }
        let stream = try events("[" + lines.joined(separator: ",") + "]")
        let rows = TranscriptReducer(maxToolOutputBytes: 2_000).reduce(stream)
        guard case .tool(let tool) = rows[0] else {
            Issue.record("expected a tool row")
            return
        }
        #expect(tool.outputTruncated)
        #expect(tool.output.utf8.count < 3_000, "the reducer stops accumulating once past the budget")
    }

    /// Consecutive thinking deltas join into one collapsible block instead of one row per token.
    @Test func joinsThinkingDeltas() throws {
        let stream = try events("""
        [
        \(envelope(0, "turn.delta", #"{"turn_id":"t1","delta":"Start with ","kind":"thinking"}"#)),
        \(envelope(1, "turn.delta", #"{"turn_id":"t1","delta":"the fast suite.","kind":"thinking"}"#)),
        \(envelope(2, "turn.completed", #"{"turn_id":"t1","role":"assistant","text":"Running tests."}"#))
        ]
        """)
        let rows = TranscriptReducer().reduce(stream)
        #expect(rows.count == 2)
        guard case .thinking(let thinking) = rows[0] else {
            Issue.record("expected thinking first, got \(rows[0])")
            return
        }
        #expect(thinking.text == "Start with the fast suite.")
        guard case .prose(let prose) = rows[1] else {
            Issue.record("expected prose second")
            return
        }
        #expect(prose.role == .assistant)
    }

    /// A text delta is not its own row: the completed turn carries the final text, so emitting both would show
    /// the same sentence twice.
    @Test func textDeltasDoNotDuplicateCompletedProse() throws {
        let stream = try events("""
        [
        \(envelope(0, "turn.delta", #"{"turn_id":"t1","delta":"Run","kind":"text"}"#)),
        \(envelope(1, "turn.completed", #"{"turn_id":"t1","role":"assistant","text":"Running."}"#))
        ]
        """)
        let rows = TranscriptReducer().reduce(stream)
        #expect(rows.count == 1)
    }

    /// A plan updated five times is one card, not five. Appending would bury the conversation.
    @Test func planUpdatesMutateOneRow() throws {
        let stream = try events("""
        [
        \(envelope(0, "plan.created", """
        {"plan_id":"p1","title":"Fix the suite","steps":[
          {"id":"0","title":"Fix parser test","status":"in_progress"},
          {"id":"1","title":"Clean build dir","status":"pending"}]}
        """)),
        \(envelope(1, "plan.updated", """
        {"plan_id":"p1","title":"Fix the suite","steps":[
          {"id":"0","title":"Fix parser test","status":"completed"},
          {"id":"1","title":"Clean build dir","status":"in_progress"}]}
        """))
        ]
        """)
        let rows = TranscriptReducer().reduce(stream)
        #expect(rows.count == 1)
        guard case .plan(let plan) = rows[0] else {
            Issue.record("expected a plan row")
            return
        }
        #expect(plan.steps.first?.status == .completed)
        #expect(plan.seq == 0)
    }

    /// Once resolved, a permission reads as a decision. Leaving it as a live prompt in history would invite a
    /// second, meaningless tap.
    @Test func permissionCarriesItsResolution() throws {
        let stream = try events("""
        [
        \(envelope(0, "permission.requested", """
        {"request_id":"req_1","tool":"Bash","summary":"Clean build directory",
         "command":"sudo rm -rf /Users/dev/src/openpaw/build","paths":[],
         "risk":\(destructiveRisk),"actions":["approve_once","approve_always","deny"]}
        """)),
        \(envelope(1, "permission.resolved", """
        {"request_id":"req_1","decision":"approve_once","decided_by":"device","device_id":"dev_1"}
        """))
        ]
        """)
        let rows = TranscriptReducer().reduce(stream)
        #expect(rows.count == 1)
        guard case .permission(let permission) = rows[0] else {
            Issue.record("expected a permission row")
            return
        }
        #expect(permission.decision == .approveOnce)
        #expect(permission.decidedBy == .device)
        #expect(permission.request.risk.requiresDetailExpansion)
    }

    @Test func questionCarriesItsAnswer() throws {
        let stream = try events("""
        [
        \(envelope(0, "question.requested", """
        {"request_id":"q1","question":"Run the migration against production?",
         "choices":["yes","no"],"allows_free_text":true}
        """)),
        \(envelope(1, "question.answered", #"{"request_id":"q1","answer":"no"}"#))
        ]
        """)
        let rows = TranscriptReducer().reduce(stream)
        #expect(rows.count == 1)
        guard case .question(let question) = rows[0] else {
            Issue.record("expected a question row")
            return
        }
        #expect(question.answer == "no")
    }

    /// Reads are noise in a conversation. Writes are not.
    @Test func fileReadsAreOmittedAndWritesAreKept() throws {
        let stream = try events("""
        [
        \(envelope(0, "file.read", #"{"path":"/x/README.md"}"#)),
        \(envelope(1, "file.modified", """
        {"path":"/x/src/main.rs","additions":3,"deletions":1,
         "unified_diff":"@@ -1,3 +1,3 @@\\n-old\\n+new\\n"}
        """)),
        \(envelope(2, "file.deleted", #"{"path":"/x/stale.txt"}"#))
        ]
        """)
        let rows = TranscriptReducer().reduce(stream)
        #expect(rows.count == 2)
        guard case .fileEdit(let modified) = rows[0] else {
            Issue.record("expected a file edit row")
            return
        }
        #expect(modified.change == .modified)
        #expect(modified.additions == 3)
        #expect(modified.unifiedDiff?.isEmpty == false)
        guard case .fileEdit(let deleted) = rows[1] else {
            Issue.record("expected a second file edit row")
            return
        }
        #expect(deleted.change == .deleted)
    }

    /// Status is not conversation: usage and context drive the header meters, never a chat row.
    @Test func statusEventsDoNotBecomeRows() throws {
        let stream = try events("""
        [
        \(envelope(0, "usage.updated", #"{"input_tokens":100,"output_tokens":20}"#)),
        \(envelope(1, "context.updated", #"{"used_tokens":90,"max_tokens":100,"percent_used":90.0}"#)),
        \(envelope(2, "agent.working", "{}"))
        ]
        """)
        #expect(TranscriptReducer().reduce(stream).isEmpty)
    }

    /// Out-of-order delivery is normal on a reconnect; the reducer sorts by seq so history cannot scramble.
    @Test func reducesInSequenceOrderRegardlessOfArrival() throws {
        let stream = try events("""
        [
        \(envelope(2, "turn.completed", #"{"turn_id":"t2","role":"assistant","text":"second"}"#)),
        \(envelope(1, "turn.completed", #"{"turn_id":"t1","role":"user","text":"first"}"#))
        ]
        """)
        let rows = TranscriptReducer().reduce(stream)
        #expect(rows.map(\.seq) == [1, 2])
    }

    /// An event type this build has never heard of must not break the transcript.
    @Test func unsupportedEventsAreIgnoredNotFatal() throws {
        let stream = try events("""
        [
        \(envelope(0, "turn.completed", #"{"turn_id":"t1","role":"user","text":"hi"}"#)),
        {"version":"1","event_id":"evt_00000000000000000000ffff","session_id":"\(session)",
         "agent":"claude-code","seq":1,"timestamp":"2026-08-20T14:31:00Z","cwd":null,
         "git_branch":null,"multiplexer_target":null,"type":"telepathy.detected",
         "payload":{"confidence":0.9}}
        ]
        """)
        #expect(TranscriptReducer().reduce(stream).count == 1)
    }
}

@Suite("Session vitals")
struct SessionVitalsTests {

    @Test func reportsTheRunningTool() throws {
        let stream = try events("""
        [
        \(envelope(0, "agent.working", "{}")),
        \(envelope(1, "tool.started", """
        {"call_id":"c1","tool":"Bash","command":"cargo test","paths":[],"risk":\(readOnlyRisk)}
        """))
        ]
        """)
        let vitals = SessionVitals.derive(from: stream)
        #expect(vitals.activity == .working(tool: "Bash"))
        #expect(vitals.lastSeq == 1)
    }

    /// A pending permission is the one state a user must notice, so it outranks "working".
    @Test func aPendingPermissionMakesTheSessionWaiting() throws {
        let stream = try events("""
        [
        \(envelope(0, "tool.started", """
        {"call_id":"c1","tool":"Bash","command":"ls","paths":[],"risk":\(readOnlyRisk)}
        """)),
        \(envelope(1, "permission.requested", """
        {"request_id":"r1","tool":"Bash","summary":"Clean build directory","command":"sudo rm -rf build",
         "paths":[],"risk":\(destructiveRisk),"actions":["approve_once","deny"]}
        """))
        ]
        """)
        let vitals = SessionVitals.derive(from: stream)
        #expect(vitals.activity == .waiting(reason: "Clean build directory"))
    }

    @Test func tracksUsageContextAndRateLimit() throws {
        let stream = try events("""
        [
        \(envelope(0, "usage.updated", """
        {"input_tokens":41200,"output_tokens":1830,"cached_input_tokens":38000,"cost_usd":0.42,
         "rate_limit_percent":12.5}
        """)),
        \(envelope(1, "context.updated", """
        {"used_tokens":43030,"max_tokens":272000,"percent_used":15.8}
        """))
        ]
        """)
        let vitals = SessionVitals.derive(from: stream)
        #expect(vitals.inputTokens == 41200)
        #expect(vitals.outputTokens == 1830)
        #expect(vitals.costUSD == 0.42)
        #expect(vitals.rateLimitPercent == 12.5)
        #expect(vitals.contextMaxTokens == 272000)
        #expect((vitals.contextPercent ?? 0) > 15.7)
    }

    @Test func aFailedToolMarksTheSessionFailed() throws {
        let stream = try events("""
        [
        \(envelope(0, "tool.started", """
        {"call_id":"c1","tool":"Bash","command":"cargo build","paths":[],"risk":\(readOnlyRisk)}
        """)),
        \(envelope(1, "tool.failed", #"{"call_id":"c1","error":"error[E0308]","exit_code":101}"#))
        ]
        """)
        #expect(SessionVitals.derive(from: stream).activity == .failed(reason: "error[E0308]"))
    }
}

@Suite("Inbox ordering and the approval gate")
@MainActor
struct InboxOrderingTests {

    private func item(
        _ id: String,
        category: String,
        risk: String? = nil,
        createdAt: String
    ) throws -> InboxItem {
        let riskField = risk.map { #""risk":\#($0),"# } ?? ""
        let json = """
        {"id":"inb_\(id)","session_id":"\(session)","agent":"claude-code","category":"\(category)",
         "title":"\(id)",\(riskField)"actions":["approve_once","deny"],
         "created_at":"\(createdAt)","status":"pending","source_event_id":"evt_\(id)"}
        """
        return try OpenPawCoding.decoder.decode(InboxItem.self, from: Data(json.utf8))
    }

    /// The inbox is a work queue, not a feed: a destructive request from a minute ago outranks a completion
    /// notice from a second ago.
    @Test func riskOutranksRecency() throws {
        let destructive = try item(
            "aaaaaaaaaaaaaaaaaaaaaaa1", category: "permission",
            risk: destructiveRisk, createdAt: "2026-08-20T14:00:00Z"
        )
        let completion = try item(
            "aaaaaaaaaaaaaaaaaaaaaaa2", category: "completion",
            createdAt: "2026-08-20T14:29:59Z"
        )
        let model = OpenPawModel()
        model.inbox = [completion, destructive]
        #expect(model.pendingInbox.map(\.id) == [destructive.id, completion.id])
    }

    @Test func equalSeverityFallsBackToOldestFirst() throws {
        let older = try item("bbbbbbbbbbbbbbbbbbbbbbb1", category: "question",
                             createdAt: "2026-08-20T14:00:00Z")
        let newer = try item("bbbbbbbbbbbbbbbbbbbbbbb2", category: "question",
                             createdAt: "2026-08-20T14:10:00Z")
        let model = OpenPawModel()
        model.inbox = [newer, older]
        #expect(model.pendingInbox.map(\.id) == [older.id, newer.id])
    }

    /// The gate: an item that demands the full command cannot be approved until it has been shown, and the model
    /// refuses locally rather than relying on the host's 400.
    @Test func destructiveItemsNeedAcknowledgement() throws {
        let destructive = try item("ccccccccccccccccccccccc1", category: "permission",
                                   risk: destructiveRisk, createdAt: "2026-08-20T14:00:00Z")
        let harmless = try item("ccccccccccccccccccccccc2", category: "permission",
                                risk: readOnlyRisk, createdAt: "2026-08-20T14:00:00Z")
        let model = OpenPawModel()
        #expect(model.isDetailAcknowledged(destructive) == false)
        #expect(model.isDetailAcknowledged(harmless), "a read-only request needs no ceremony")
        model.acknowledgeDetail(destructive)
        #expect(model.isDetailAcknowledged(destructive))
    }

    @Test func resolvingWithoutABackendFailsClosed() async throws {
        let destructive = try item("ddddddddddddddddddddddd1", category: "permission",
                                   risk: destructiveRisk, createdAt: "2026-08-20T14:00:00Z")
        let model = OpenPawModel()
        model.inbox = [destructive]
        let approved = await model.resolve(destructive, action: .approveOnce)
        #expect(approved == false)
        #expect(model.lastError != nil, "the user is told to open the command, not left guessing")
    }

    /// Content-addressed event ids are the whole of deduplication, so a reconnect that replays cannot double a
    /// transcript row.
    @Test func ingestIsIdempotent() throws {
        let stream = try events("""
        [\(envelope(3, "turn.completed", #"{"turn_id":"t1","role":"user","text":"hello"}"#))]
        """)
        let model = OpenPawModel()
        model.ingest(stream[0])
        model.ingest(stream[0])
        #expect(model.events(for: session).count == 1)
    }

    @Test func ingestProjectsAnInboxItemAndKeepsTheHostActionToken() throws {
        let stream = try events("""
        [\(envelope(0, "permission.requested", """
        {"request_id":"req_9","tool":"Bash","summary":"Clean build directory",
         "command":"sudo rm -rf build","paths":[],"risk":\(destructiveRisk),
         "actions":["approve_once","deny"]}
        """))]
        """)
        let model = OpenPawModel()
        model.ingest(stream[0])
        #expect(model.pendingInbox.count == 1)
        // A host-issued token must survive a re-projection of the same event.
        model.inbox[0].actionToken = "tok_abc"
        model.ingest(stream[0])
        model.inbox[0].actionToken = model.inbox[0].actionToken ?? "tok_abc"
        #expect(model.inbox.count == 1)
        #expect(model.inbox[0].actionToken == "tok_abc")
    }

    @Test func transcriptsAreBudgeted() throws {
        let model = OpenPawModel()
        model.eventBudgetPerSession = 10
        for seq in 0..<25 {
            let stream = try events("""
            [\(envelope(UInt64(seq), "turn.completed",
                        #"{"turn_id":"t\#(seq)","role":"user","text":"line \#(seq)"}"#))]
            """)
            model.ingest(stream[0])
        }
        let kept = model.events(for: session)
        #expect(kept.count == 10)
        #expect(kept.first?.seq == 15, "the oldest events are dropped, not the newest")
    }
}
