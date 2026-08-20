import Foundation
import XCTest

@testable import OpenPawProtocol

final class EventCodingTests: XCTestCase {
    // MARK: Envelope

    private func envelope(type: String, payload: String) -> String {
        """
        {"version":"1","event_id":"evt_0123456789abcdef01234567",\
        "session_id":"sess_cc-6f7b","agent":"claude-code","seq":7,\
        "timestamp":"2026-08-20T14:30:00Z","cwd":"/Users/x/proj","git_branch":"main",\
        "multiplexer_target":null,"type":"\(type)","payload":\(payload)}
        """
    }

    /// One literal per event type in `event.schema.json`, exercised whether or not the
    /// `openpaw-agents` slice has generated its golden files yet.
    private static let payloadsByType: [(String, String)] = [
        ("agent.started", #"{"title":"Refactor the parser"}"#),
        ("agent.working", #"{}"#),
        ("agent.completed", #"{"reason":"turn finished","exit_code":0,"title":"Done"}"#),
        ("agent.failed", #"{"reason":"process exited","exit_code":2}"#),
        ("turn.started", #"{"turn_id":"t1","role":"user","text":"fix the flake"}"#),
        ("turn.delta", #"{"turn_id":"t1","delta":"weighing options","kind":"thinking"}"#),
        (
            "turn.completed",
            #"{"turn_id":"t1","role":"assistant","text":"done","thinking":"two options"}"#
        ),
        (
            "tool.started",
            """
            {"call_id":"c1","tool":"Bash","summary":"list files","command":"ls -la",\
            "paths":["/Users/x/proj"],"risk":{"class":"read_only",\
            "requires_detail_expansion":false,"reasons":["`ls` only reads"]}}
            """
        ),
        (
            "tool.output",
            #"{"call_id":"c1","chunk":"total 12\n","stream":"stdout","truncated":false}"#
        ),
        (
            "tool.completed",
            #"{"call_id":"c1","exit_code":0,"duration_ms":41,"summary":"3 entries"}"#
        ),
        ("tool.failed", #"{"call_id":"c1","error":"command not found: fzf","exit_code":127}"#),
        (
            "permission.requested",
            """
            {"request_id":"r1","tool":"Bash","summary":"Delete the build directory",\
            "command":"rm -rf build","paths":["build"],\
            "risk":{"class":"destructive_shell","requires_detail_expansion":true,\
            "reasons":["`rm` deletes files irreversibly"]},\
            "actions":["approve_once","approve_always","deny"],\
            "expires_at":"2026-08-20T14:35:00Z"}
            """
        ),
        (
            "permission.resolved",
            """
            {"request_id":"r1","decision":"approve_once","decided_by":"device",\
            "device_id":"dev_1"}
            """
        ),
        (
            "question.requested",
            """
            {"request_id":"q1","question":"Which database should the migration target?",\
            "choices":["postgres","sqlite"],"allows_free_text":true}
            """
        ),
        ("question.answered", #"{"request_id":"q1","answer":"postgres"}"#),
        (
            "plan.created",
            """
            {"plan_id":"p1","title":"Ship the adapter","steps":[\
            {"id":"s1","title":"Parse the rollout","status":"completed"},\
            {"id":"s2","title":"Normalize events","status":"in_progress"},\
            {"id":"s3","title":"Write goldens","status":"pending"},\
            {"id":"s4","title":"Drop the spike","status":"cancelled"}]}
            """
        ),
        ("plan.updated", #"{"plan_id":"p1","steps":[]}"#),
        ("file.read", #"{"path":"src/main.rs","bytes":2048}"#),
        ("file.created", #"{"path":"src/adapter.rs","additions":120,"deletions":0}"#),
        (
            "file.modified",
            """
            {"path":"src/lib.rs","additions":3,"deletions":1,\
            "unified_diff":"@@ -1,2 +1,4 @@\\n-old\\n+new\\n"}
            """
        ),
        ("file.deleted", #"{"path":"src/spike.rs"}"#),
        (
            "usage.updated",
            """
            {"input_tokens":12000,"output_tokens":800,"cached_input_tokens":9000,\
            "cost_usd":0.42,"rate_limit_percent":91.5,\
            "rate_limit_resets_at":"2026-08-20T18:00:00Z"}
            """
        ),
        ("context.updated", #"{"used_tokens":170000,"max_tokens":200000,"percent_used":85.0}"#),
    ]

    func testEveryEventTypeIsCovered() {
        XCTAssertEqual(
            Set(Self.payloadsByType.map(\.0)),
            Set(EventType.allCases.map(\.rawValue)),
            "hand written literals must cover every event type in the schema"
        )
    }

    func testHandWrittenEventsRoundTrip() throws {
        for (type, payload) in Self.payloadsByType {
            try assertEventRoundTrips(envelope(type: type, payload: payload))
        }
    }

    func testDecodedEnvelopeAndPayloadFields() throws {
        let json = envelope(
            type: "turn.delta", payload: #"{"turn_id":"t1","delta":"x","kind":"text"}"#
        )
        let event = try OpenPawCoding.decoder.decode(Event.self, from: Data(json.utf8))
        XCTAssertEqual(event.version, "1")
        XCTAssertEqual(event.eventID.rawValue, "evt_0123456789abcdef01234567")
        XCTAssertEqual(event.sessionID.rawValue, "sess_cc-6f7b")
        XCTAssertEqual(event.agent, .claudeCode)
        XCTAssertEqual(event.seq, 7)
        XCTAssertEqual(event.cwd, "/Users/x/proj")
        XCTAssertEqual(event.gitBranch, "main")
        XCTAssertNil(event.multiplexerTarget)
        XCTAssertEqual(event.kind, .turnDelta)
        XCTAssertEqual(event.id, event.eventID)
        guard case .turnDelta(let payload) = event.body else {
            return XCTFail("expected .turnDelta, got \(event.body)")
        }
        XCTAssertEqual(payload.turnID, "t1")
        XCTAssertEqual(payload.kind, .text)
    }

    func testPayloadKeysAreSnakeCase() throws {
        let json = envelope(
            type: "usage.updated",
            payload: #"{"input_tokens":1,"output_tokens":2,"cost_usd":0.5}"#
        )
        let event = try OpenPawCoding.decoder.decode(Event.self, from: Data(json.utf8))
        guard case .usageUpdated(let usage) = event.body else {
            return XCTFail("expected .usageUpdated")
        }
        XCTAssertEqual(usage.inputTokens, 1)
        XCTAssertEqual(usage.outputTokens, 2)
        XCTAssertEqual(usage.costUSD, 0.5)
        XCTAssertNil(usage.cachedInputTokens)

        let object = try JSONValue(data: try OpenPawCoding.encoder.encode(event))
        let payload = try XCTUnwrap(object["payload"]?.objectValue)
        XCTAssertEqual(Set(payload.keys), ["input_tokens", "output_tokens", "cost_usd"])
    }

    func testEncoderAlwaysEmitsTheThreeContextKeysAsNull() throws {
        let event = Event(
            eventID: EventID(rawValue: "evt_0123456789abcdef01234567"),
            sessionID: SessionID(rawValue: "sess_cx-1"),
            agent: .codex,
            timestamp: Date(timeIntervalSince1970: 1_787_245_200),
            body: .agentWorking(AgentLifecycle())
        )
        let object = try JSONValue(data: try OpenPawCoding.encoder.encode(event))
        XCTAssertEqual(object["cwd"], JSONValue.null)
        XCTAssertEqual(object["git_branch"], JSONValue.null)
        XCTAssertEqual(object["multiplexer_target"], JSONValue.null)
        // Payload optionals stay omitted rather than becoming explicit nulls.
        XCTAssertEqual(object["payload"], JSONValue.object([:]))
        XCTAssertEqual(object["timestamp"]?.stringValue, "2026-08-20T17:00:00Z")
        XCTAssertEqual(object["seq"]?.intValue, 0)
    }

    func testSeqAndContextBuilders() {
        let session = SessionID(agent: .claudeCode, raw: "abc")
        let event = Event(
            session: session,
            agent: .claudeCode,
            sourceKey: "hook:1",
            timestamp: Date(timeIntervalSince1970: 0),
            body: .agentStarted(AgentLifecycle())
        )
        XCTAssertEqual(event.seq, 0)
        XCTAssertEqual(event.eventID, EventID(session: session, sourceKey: "hook:1"))
        let updated = event.withSeq(42).withContext(cwd: "/tmp", gitBranch: "topic")
        XCTAssertEqual(updated.seq, 42)
        XCTAssertEqual(updated.cwd, "/tmp")
        XCTAssertEqual(updated.gitBranch, "topic")
        XCTAssertEqual(updated.eventID, event.eventID, "context must not change identity")
    }

    // MARK: Timestamps

    func testTimestampsAcceptOptionalFractionalSeconds() throws {
        let whole = try OpenPawCoding.decoder.decode(
            Event.self, from: Data(envelope(type: "agent.working", payload: "{}").utf8)
        )
        let fractional = try OpenPawCoding.decoder.decode(
            Event.self,
            from: Data(
                envelope(type: "agent.working", payload: "{}")
                    .replacingOccurrences(of: "14:30:00Z", with: "14:30:00.000Z").utf8
            )
        )
        XCTAssertEqual(whole.timestamp, fractional.timestamp)
        XCTAssertEqual(RFC3339.string(from: whole.timestamp), "2026-08-20T14:30:00Z")
    }

    func testSubSecondPrecisionUsesTheHostsTrimmedForm() throws {
        // The host (Rust `time`) emits `.5Z`, never `.500Z`, so that is the canonical
        // form a client must reproduce byte for byte.
        let json = envelope(type: "agent.working", payload: "{}")
            .replacingOccurrences(of: "14:30:00Z", with: "14:30:00.5Z")
        try assertEventRoundTrips(json)
        let event = try OpenPawCoding.decoder.decode(Event.self, from: Data(json.utf8))
        XCTAssertEqual(RFC3339.string(from: event.timestamp), "2026-08-20T14:30:00.5Z")

        // Two and three digit fractions keep only their significant digits.
        XCTAssertEqual(
            RFC3339.string(from: try XCTUnwrap(RFC3339.date(from: "2026-08-20T14:30:00.250Z"))),
            "2026-08-20T14:30:00.25Z"
        )
        XCTAssertEqual(
            RFC3339.string(from: try XCTUnwrap(RFC3339.date(from: "2026-08-20T14:30:00.001Z"))),
            "2026-08-20T14:30:00.001Z"
        )
        // Any spelling of a whole second collapses to no fractional field at all.
        for spelling in ["2026-08-20T14:30:00Z", "2026-08-20T14:30:00.0Z", "2026-08-20T14:30:00.000Z"] {
            XCTAssertEqual(
                RFC3339.string(from: try XCTUnwrap(RFC3339.date(from: spelling))),
                "2026-08-20T14:30:00Z",
                spelling
            )
        }
    }

    func testNumericOffsetTimestampNormalizesToUTC() {
        XCTAssertEqual(
            RFC3339.date(from: "2026-08-20T16:30:00+02:00"),
            RFC3339.date(from: "2026-08-20T14:30:00Z")
        )
        XCTAssertNil(RFC3339.date(from: "20 August 2026"))
    }

    func testMalformedTimestampFailsDecoding() {
        let json = envelope(type: "agent.working", payload: "{}")
            .replacingOccurrences(of: "2026-08-20T14:30:00Z", with: "yesterday")
        XCTAssertThrowsError(
            try OpenPawCoding.decoder.decode(Event.self, from: Data(json.utf8))
        )
    }

    // MARK: Forward compatibility

    func testUnsupportedEventTypeRoundTripsLosslessly() throws {
        let json = envelope(
            type: "sandbox.escalated",
            payload: """
                {"request_id":"s1","escalation":{"kind":"network","hosts":["api.example.com"],\
                "attempts":3,"allowed":false},"note":null}
                """
        )
        let event = try OpenPawCoding.decoder.decode(Event.self, from: Data(json.utf8))
        XCTAssertNil(event.kind, "an unknown type must not masquerade as a known one")
        XCTAssertEqual(event.body.typeName, "sandbox.escalated")
        guard case .unsupported(let type, let payload) = event.body else {
            return XCTFail("expected .unsupported, got \(event.body)")
        }
        XCTAssertEqual(type, "sandbox.escalated")
        XCTAssertEqual(payload["escalation"]?["attempts"]?.intValue, 3)
        XCTAssertEqual(payload["escalation"]?["allowed"]?.boolValue, false)
        XCTAssertEqual(payload["escalation"]?["hosts"]?.arrayValue?.count, 1)
        XCTAssertEqual(payload["note"], JSONValue.null)
        XCTAssertNil(InboxProjection.from(event: event))

        // The payload tree is preserved verbatim, nulls included, so an older phone can
        // relay events it cannot interpret.
        let produced = try JSONValue(data: try OpenPawCoding.encoder.encode(event))
        let original = try JSONValue(data: Data(json.utf8))
        XCTAssertEqual(produced["payload"], original["payload"])
        XCTAssertEqual(produced["type"], original["type"])
        XCTAssertEqual(produced["event_id"], original["event_id"])
    }

    func testUnsupportedEventSurvivesTheSSEDecodePath() async throws {
        let json = envelope(type: "sandbox.escalated", payload: #"{"note":"held"}"#)
        var received: [Event] = []
        for try await event in SSE.events(from: ByteStream(text: "data: \(json)\n\n")) {
            received.append(event)
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.body.typeName, "sandbox.escalated")
        XCTAssertNil(received.first?.kind)
    }

    // MARK: Golden files

    func testGoldenEventFilesDecodeAndReencode() throws {
        let files = Repo.goldenEventFiles()
        guard !files.isEmpty else {
            // The openpaw-agents slice owns generation; nothing on disk to verify yet.
            return
        }
        var total = 0
        for file in files {
            let data = try Data(contentsOf: file)
            let elements = try XCTUnwrap(
                try JSONValue(data: data).arrayValue,
                "\(file.lastPathComponent) is not a JSON array"
            )
            let events = try OpenPawCoding.decoder.decode([Event].self, from: data)
            XCTAssertEqual(events.count, elements.count, file.lastPathComponent)
            for (event, element) in zip(events, elements) {
                assertSemanticallyEqual(
                    try OpenPawCoding.encoder.encode(event),
                    try OpenPawCoding.encoder.encode(element),
                    "\(file.lastPathComponent) \(event.eventID.rawValue)"
                )
                XCTAssertEqual(event.version, OpenPawCoding.version)
                XCTAssertTrue(
                    event.eventID.rawValue.hasPrefix("evt_"),
                    "\(event.eventID.rawValue) is not a well formed event id"
                )
                XCTAssertTrue(event.sessionID.rawValue.hasPrefix("sess_"))
                total += 1
            }
        }
        XCTAssertGreaterThan(total, 0, "golden files were present but held no events")
    }

    // MARK: Derived identifiers

    func testSessionIDSanitizesAndPrefixes() {
        XCTAssertEqual(
            SessionID(agent: .claudeCode, raw: "57ae0add/f501 42d6").rawValue,
            "sess_cc-57ae0add-f501-42d6"
        )
        XCTAssertEqual(
            SessionID(agent: .openCode, raw: "ses_abc.1:2").rawValue, "sess_oc-ses_abc.1:2"
        )
    }

    func testEventAndInboxIDsAreContentAddressed() {
        let session = SessionID(agent: .codex, raw: "rollout-1")
        let first = EventID(session: session, sourceKey: "line:12")
        let second = EventID(session: session, sourceKey: "line:12")
        let other = EventID(session: session, sourceKey: "line:13")
        XCTAssertEqual(first, second, "ingestion must be idempotent")
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(first.rawValue.count, 4 + 24)
        XCTAssertTrue(first.rawValue.hasPrefix("evt_"))
        XCTAssertTrue(
            first.rawValue.dropFirst(4).allSatisfy { $0.isHexDigit && !$0.isUppercase }
        )

        let inbox = InboxID(event: first)
        XCTAssertEqual(inbox, InboxID(event: second))
        XCTAssertTrue(inbox.rawValue.hasPrefix("inb_"))
        XCTAssertEqual(inbox.rawValue.count, 4 + 24)
    }

    func testAgentShortCodesAreDistinct() {
        let codes = AgentKind.allCases.map(\.short)
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertEqual(AgentKind.claudeCode.short, "cc")
        XCTAssertEqual(AgentKind.codex.short, "cx")
        XCTAssertEqual(AgentKind.openCode.short, "oc")
        XCTAssertEqual(AgentKind.generic.short, "gn")
        XCTAssertEqual(AgentKind.geminiCLI.rawValue, "gemini-cli")
        XCTAssertEqual(AgentKind.qwenCode.rawValue, "qwen-code")
    }
}
