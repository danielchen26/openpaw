import Foundation
import XCTest

@testable import OpenPawProtocol

final class InboxProjectionTests: XCTestCase {
    private let session = SessionID(agent: .claudeCode, raw: "6f7b")
    private let timestamp = Date(timeIntervalSince1970: 1_787_245_200)

    private func event(_ body: Body, sourceKey: String = "k") -> Event {
        Event(
            session: session,
            agent: .claudeCode,
            sourceKey: sourceKey,
            timestamp: timestamp,
            body: body
        )
    }

    // MARK: Non-actionable events

    func testNonActionableEventsProjectToNil() {
        let bodies: [Body] = [
            .agentStarted(AgentLifecycle()),
            .agentWorking(AgentLifecycle()),
            .turnStarted(TurnStarted(turnID: "t", role: .user)),
            .turnDelta(TurnDelta(turnID: "t", delta: "x", kind: .text)),
            .turnCompleted(TurnCompleted(turnID: "t", role: .assistant, text: "ok")),
            .toolStarted(ToolStarted(callID: "c", tool: "Bash")),
            .toolOutput(ToolOutput(callID: "c", chunk: "x", stream: .stdout, truncated: false)),
            .toolCompleted(ToolCompleted(callID: "c", exitCode: 0)),
            .permissionResolved(
                PermissionResolved(requestID: "r", decision: .approveOnce, decidedBy: .device)
            ),
            .questionAnswered(QuestionAnswered(requestID: "q", answer: "yes")),
            .fileRead(FileChange(path: "a")),
            .fileCreated(FileChange(path: "a")),
            .fileModified(FileChange(path: "a")),
            .fileDeleted(FileChange(path: "a")),
            .unsupported(type: "future.thing", payload: .object([:])),
        ]
        for body in bodies {
            XCTAssertNil(
                InboxProjection.from(event: event(body)),
                "\(body.typeName) carries no decision and must not become an inbox item"
            )
        }
    }

    func testSubThresholdContextAndUsageProjectToNil() {
        XCTAssertNil(
            InboxProjection.from(
                event: event(
                    .contextUpdated(
                        ContextUpdated(usedTokens: 100, maxTokens: 200, percentUsed: 84.9)
                    )
                )
            )
        )
        XCTAssertNil(
            InboxProjection.from(
                event: event(
                    .usageUpdated(
                        UsageUpdated(inputTokens: 1, outputTokens: 1, rateLimitPercent: 89.9)
                    )
                )
            )
        )
        // A usage update with no rate limit information is never a warning.
        XCTAssertNil(
            InboxProjection.from(
                event: event(.usageUpdated(UsageUpdated(inputTokens: 1, outputTokens: 1)))
            )
        )
    }

    // MARK: Permissions

    func testDestructivePermissionRequiresDetailExpansion() throws {
        let risk = Risk.classifyCommand("rm -rf build")
        XCTAssertEqual(risk.riskClass, .destructiveShell)

        let source = event(
            .permissionRequested(
                PermissionRequested(
                    requestID: "r1",
                    tool: "Bash",
                    summary: "Delete the build directory",
                    command: "rm -rf build",
                    paths: ["build"],
                    risk: risk,
                    actions: [.approveOnce, .deny],
                    expiresAt: timestamp.addingTimeInterval(300)
                )
            )
        )
        let item = try XCTUnwrap(InboxProjection.from(event: source))
        XCTAssertEqual(item.id, InboxID(event: source.eventID))
        XCTAssertEqual(item.category, .permission)
        XCTAssertEqual(item.title, "Delete the build directory")
        XCTAssertEqual(item.detail, "rm -rf build")
        XCTAssertEqual(item.command, "rm -rf build")
        XCTAssertEqual(item.actions, [.approveOnce, .deny])
        XCTAssertEqual(item.requestID, "r1")
        XCTAssertEqual(item.status, .pending)
        XCTAssertNil(item.actionToken, "tokens are issued by the host, never by the projection")
        XCTAssertNil(item.resolution)
        XCTAssertEqual(item.createdAt, timestamp)
        XCTAssertEqual(item.sourceEventID, source.eventID)
        XCTAssertEqual(item.sessionID, session)

        guard case .requiresDetailExpansion(let reasons) = item.approvalGate else {
            return XCTFail("a destructive permission must not offer a one tap approval")
        }
        XCTAssertEqual(reasons, risk.reasons)
        XCTAssertTrue(reasons.contains("requires review: rm deletes files"))
        XCTAssertFalse(item.approvalGate.isOneTap)
    }

    func testReadOnlyPermissionIsOneTap() throws {
        let item = try XCTUnwrap(
            InboxProjection.from(
                event: event(
                    .permissionRequested(
                        PermissionRequested(
                            requestID: "r2",
                            tool: "Bash",
                            summary: "List the project",
                            command: "ls -la",
                            risk: Risk.classifyCommand("ls -la"),
                            actions: [.approveOnce, .approveAlways, .deny]
                        )
                    )
                )
            )
        )
        XCTAssertEqual(item.approvalGate, .oneTap)
        XCTAssertTrue(item.approvalGate.isOneTap)
        XCTAssertTrue(item.approvalGate.reasons.isEmpty)
    }

    func testPermissionWithoutCommandFallsBackToSummaryDetail() throws {
        let item = try XCTUnwrap(
            InboxProjection.from(
                event: event(
                    .permissionRequested(
                        PermissionRequested(
                            requestID: "r3",
                            tool: "Write",
                            summary: "Create src/new.rs",
                            risk: Risk.classifyTool("Write", input: ["file_path": "src/new.rs"]),
                            actions: [.approveOnce]
                        )
                    )
                )
            )
        )
        XCTAssertEqual(item.detail, "Create src/new.rs")
        XCTAssertNil(item.command)
    }

    // MARK: Questions, plans, failures

    func testQuestionProjection() throws {
        let item = try XCTUnwrap(
            InboxProjection.from(
                event: event(
                    .questionRequested(
                        QuestionRequested(
                            requestID: "q1",
                            question: "Which database?",
                            choices: ["postgres", "sqlite"],
                            allowsFreeText: true
                        )
                    )
                )
            )
        )
        XCTAssertEqual(item.category, .question)
        XCTAssertEqual(item.title, "Which database?")
        XCTAssertEqual(item.detail, "postgres, sqlite")
        XCTAssertEqual(item.actions, [.answer])
        XCTAssertEqual(item.requestID, "q1")
        XCTAssertEqual(item.approvalGate, .oneTap)
    }

    func testQuestionWithoutChoicesHasNoDetail() throws {
        let item = try XCTUnwrap(
            InboxProjection.from(
                event: event(
                    .questionRequested(
                        QuestionRequested(requestID: "q2", question: "Why?", allowsFreeText: true)
                    )
                )
            )
        )
        XCTAssertNil(item.detail)
    }

    func testPlanProjectionCountsCompletedSteps() throws {
        let plan = Plan(
            planID: "p1",
            title: "Ship the adapter",
            steps: [
                PlanStep(id: "s1", title: "Parse", status: .completed),
                PlanStep(id: "s2", title: "Normalize", status: .inProgress),
                PlanStep(id: "s3", title: "Golden", status: .pending),
                PlanStep(id: "s4", title: "Spike", status: .cancelled),
            ]
        )
        let item = try XCTUnwrap(InboxProjection.from(event: event(.planCreated(plan))))
        XCTAssertEqual(item.category, .plan)
        XCTAssertEqual(item.title, "Ship the adapter (1/4 steps complete)")
        XCTAssertEqual(
            item.detail,
            """
            [x] Parse
            [~] Normalize
            [ ] Golden
            [-] Spike
            """
        )
        XCTAssertEqual(item.actions, [.acknowledge])

        let untitled = try XCTUnwrap(
            InboxProjection.from(event: event(.planUpdated(Plan(planID: "p2"))))
        )
        XCTAssertEqual(untitled.title, "Plan (0/0 steps complete)")
        XCTAssertNil(untitled.detail)
    }

    func testToolAndAgentFailuresBecomeToolFailureItems() throws {
        let toolFailure = try XCTUnwrap(
            InboxProjection.from(
                event: event(.toolFailed(ToolFailed(callID: "c9", error: "exit 127")))
            )
        )
        XCTAssertEqual(toolFailure.category, .toolFailure)
        XCTAssertEqual(toolFailure.title, "Tool call c9 failed")
        XCTAssertEqual(toolFailure.detail, "exit 127")

        let agentFailure = try XCTUnwrap(
            InboxProjection.from(
                event: event(.agentFailed(AgentLifecycle(reason: "process exited", exitCode: 2)))
            )
        )
        XCTAssertEqual(agentFailure.category, .toolFailure)
        XCTAssertEqual(agentFailure.title, "Agent failed")
        XCTAssertEqual(agentFailure.detail, "process exited")

        let completion = try XCTUnwrap(
            InboxProjection.from(
                event: event(.agentCompleted(AgentLifecycle(reason: "turn finished")))
            )
        )
        XCTAssertEqual(completion.category, .completion)
        XCTAssertEqual(completion.title, "Agent completed")
    }

    // MARK: Thresholds

    func testContextWarningAtThreshold() throws {
        let item = try XCTUnwrap(
            InboxProjection.from(
                event: event(
                    .contextUpdated(
                        ContextUpdated(usedTokens: 170_000, maxTokens: 200_000, percentUsed: 85.0)
                    )
                )
            )
        )
        XCTAssertEqual(item.category, .contextWarning)
        XCTAssertEqual(item.title, "Context window 85% used")
        XCTAssertEqual(item.detail, "170000 of 200000 tokens used")
        XCTAssertEqual(item.actions, [.acknowledge])
    }

    func testRateLimitWarningRoundsHalfAwayFromZero() throws {
        let item = try XCTUnwrap(
            InboxProjection.from(
                event: event(
                    .usageUpdated(
                        UsageUpdated(
                            inputTokens: 1,
                            outputTokens: 1,
                            rateLimitPercent: 90.5,
                            rateLimitResetsAt: Date(timeIntervalSince1970: 1_787_260_800)
                        )
                    )
                )
            )
        )
        XCTAssertEqual(item.category, .rateLimit)
        XCTAssertEqual(item.title, "Rate limit 91% consumed")
        XCTAssertEqual(item.detail, "resets at 2026-08-20T21:20:00Z")
    }

    // MARK: Wire shape

    func testInboxItemDecodesTheHostShape() throws {
        let json = """
            {"id":"inb_0123456789abcdef01234567","session_id":"sess_cc-6f7b",\
            "agent":"claude-code","category":"permission","title":"Force push main",\
            "detail":"git push --force origin main","command":"git push --force origin main",\
            "risk":{"class":"network_access","requires_detail_expansion":true,\
            "reasons":["force pushes and can destroy remote history"]},\
            "actions":["approve_once","deny"],"request_id":"r7",\
            "action_token":"tok_1","created_at":"2026-08-20T17:00:00Z",\
            "expires_at":"2026-08-20T17:05:00Z","status":"pending",\
            "source_event_id":"evt_0123456789abcdef01234567"}
            """
        let item = try OpenPawCoding.decoder.decode(InboxItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.id.rawValue, "inb_0123456789abcdef01234567")
        XCTAssertEqual(item.category, .permission)
        XCTAssertEqual(item.risk?.riskClass, .networkAccess)
        XCTAssertEqual(item.actionToken, "tok_1")
        XCTAssertEqual(item.requestID, "r7")
        XCTAssertNil(item.resolution)
        XCTAssertEqual(item.approvalGate.reasons, ["force pushes and can destroy remote history"])
        XCTAssertFalse(item.approvalGate.isOneTap)

        assertSemanticallyEqual(try OpenPawCoding.encoder.encode(item), Data(json.utf8))
    }

    func testInboxItemToleratesAMissingRequestID() throws {
        let json = """
            {"id":"inb_0123456789abcdef01234567","session_id":"sess_cc-6f7b",\
            "agent":"codex","category":"completion","title":"Agent completed",\
            "actions":["acknowledge"],"created_at":"2026-08-20T17:00:00Z",\
            "status":"resolved","resolution":"acknowledged",\
            "source_event_id":"evt_0123456789abcdef01234567"}
            """
        let item = try OpenPawCoding.decoder.decode(InboxItem.self, from: Data(json.utf8))
        XCTAssertNil(item.requestID)
        XCTAssertNil(item.risk)
        XCTAssertEqual(item.approvalGate, .oneTap)
        XCTAssertEqual(item.status, .resolved)
        XCTAssertEqual(item.resolution, "acknowledged")
    }

    func testExpiry() {
        var item = InboxItem(
            id: InboxID(rawValue: "inb_0123456789abcdef01234567"),
            sessionID: session,
            agent: .claudeCode,
            category: .permission,
            title: "t",
            actions: [.approveOnce],
            createdAt: timestamp,
            expiresAt: timestamp.addingTimeInterval(300),
            status: .pending,
            sourceEventID: EventID(rawValue: "evt_0123456789abcdef01234567")
        )
        XCTAssertFalse(item.hasExpired(at: timestamp.addingTimeInterval(299)))
        XCTAssertTrue(item.hasExpired(at: timestamp.addingTimeInterval(300)))
        item.status = .expired
        XCTAssertEqual(item.status, .expired)
    }
}
