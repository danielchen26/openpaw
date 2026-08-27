import XCTest
import OpenPawProtocol
import OpenPawTerminalCore
@testable import OpenPawUI

final class ProposalEngineTests: XCTestCase {
    private let hostID = UUID(uuidString: "12345678-1234-1234-1234-1234567890ab")!
    private let snapshotID = UUID(uuidString: "abcdefab-cdef-abcd-efab-cdefabcdefab")!
    private let sessionID = "sess_cc-proposals"

    func testLocalProposalsExistWithoutAgentEvents() {
        let pending = inboxItem(title: "Approve focused tests")
        let input = makeInput(
            destination: .home,
            agentSessions: [session(state: .working)],
            selectedSessionID: sessionID,
            repositories: [repo(name: "openpaw", path: "/work/openpaw", dirty: true)],
            inbox: [pending]
        )

        let proposals = ProposalEngine().proposals(for: input)

        XCTAssertTrue(proposals.allSatisfy { $0.source == .local })
        XCTAssertTrue(proposals.contains { $0.title == "Review openpaw changes" })
        XCTAssertTrue(proposals.contains { $0.title == "Resolve Approve focused tests" })
        XCTAssertTrue(proposals.contains { $0.title == "Continue Proposal session" })
        XCTAssertTrue(proposals.contains { $0.title == "Open Terminal" })
    }

    func testNewestPlanUpdateReplacesOlderVersionAndProducesSpecificNextStep() {
        let created = Plan(
            planID: "plan-1",
            title: "Old plan",
            steps: [.init(id: "old", title: "Read the old file", status: .inProgress)]
        )
        let updated = Plan(
            planID: "plan-1",
            title: "Updated plan",
            steps: [.init(id: "new", title: "Run the focused parser test", status: .inProgress)]
        )
        let input = makeInput(
            agentSessions: [session()],
            transcripts: [sessionID: [
                event(seq: 1, body: .planCreated(created)),
                event(seq: 2, body: .planUpdated(updated)),
            ]],
            selectedSessionID: sessionID
        )

        let proposals = ProposalEngine().proposals(for: input)

        XCTAssertEqual(proposals.first(where: { $0.source == .agentDerived })?.title, "Run the focused parser test")
        XCTAssertFalse(proposals.contains { $0.title == "Read the old file" })
    }

    func testFirstInProgressPlanStepOutranksPendingSteps() {
        let plan = Plan(
            planID: "plan-order",
            steps: [
                .init(id: "pending-first", title: "Prepare the fixture", status: .pending),
                .init(id: "active-first", title: "Fix the parser", status: .inProgress),
                .init(id: "active-second", title: "Fix the renderer", status: .inProgress),
            ]
        )
        let input = makeInput(
            agentSessions: [session()],
            transcripts: [sessionID: [event(seq: 7, body: .planUpdated(plan))]],
            selectedSessionID: sessionID
        )

        let proposals = ProposalEngine().proposals(for: input)

        XCTAssertEqual(proposals.first(where: { $0.source == .agentDerived })?.title, "Fix the parser")
        XCTAssertFalse(proposals.contains { $0.title == "Prepare the fixture" })
        XCTAssertFalse(proposals.contains { $0.title == "Fix the renderer" })
    }

    func testAgentDerivedProposalsUseEligibleSessionsAndNewestPlanPerSession() {
        let exited = session(id: "sess-exited", state: .exited, lastSeq: 90)
        let fallback = session(id: "sess-fallback", state: .idle, lastSeq: 80)
        let olderPlan = Plan(planID: "old-plan", steps: [.init(id: "old", title: "Old fallback step", status: .inProgress)])
        let newestPlan = Plan(planID: "new-plan", steps: [.init(id: "new", title: "Newest fallback step", status: .pending)])
        let exitedPlan = Plan(planID: "exited-plan", steps: [.init(id: "exited", title: "Exited session step", status: .inProgress)])
        let input = makeInput(
            agentSessions: [exited, fallback],
            transcripts: [
                "sess-exited": [event(sessionID: "sess-exited", seq: 1, body: .planUpdated(exitedPlan))],
                "sess-fallback": [
                    event(sessionID: "sess-fallback", seq: 1, timestamp: 10, body: .planUpdated(olderPlan)),
                    event(sessionID: "sess-fallback", seq: 2, timestamp: 20, body: .planUpdated(newestPlan)),
                ],
            ]
        )

        let agent = ProposalEngine().proposals(for: input).filter { $0.source == .agentDerived }

        XCTAssertEqual(agent.map { $0.title }, ["Newest fallback step"])
        XCTAssertEqual(agent.first?.target.sessionID, "sess-fallback")
    }

    func testCrossSessionFreshnessUsesTimestampsWhileProcessingEachSessionBySeq() {
        let olderWallClock = Plan(planID: "a", steps: [.init(id: "a", title: "Older wall clock high seq", status: .inProgress)])
        let newerWallClock = Plan(planID: "b", steps: [.init(id: "b", title: "Newer wall clock low seq", status: .inProgress)])
        let input = makeInput(
            agentSessions: [session(id: "sess-a"), session(id: "sess-b")],
            transcripts: [
                "sess-a": [event(sessionID: "sess-a", seq: 900, timestamp: 100, body: .planUpdated(olderWallClock))],
                "sess-b": [
                    event(sessionID: "sess-b", seq: 2, timestamp: 300, body: .planUpdated(newerWallClock)),
                    event(sessionID: "sess-b", seq: 1, timestamp: 200, body: .planUpdated(Plan(planID: "b", steps: [.init(id: "stale", title: "Stale low seq", status: .inProgress)]))),
                ],
            ]
        )

        let agent = ProposalEngine().proposals(for: input).filter { $0.source == .agentDerived }

        XCTAssertEqual(agent.first?.title, "Newer wall clock low seq")
        XCTAssertFalse(agent.contains { $0.title == "Stale low seq" })
        let scores = Dictionary(uniqueKeysWithValues: agent.map { ($0.title, $0.score) })
        XCTAssertLessThanOrEqual(abs((scores["Newer wall clock low seq"] ?? 0) - (scores["Older wall clock high seq"] ?? 0)), 50)
    }

    func testLocalContinueSessionIgnoresExitedSelectedAndFallsBackByTimestamp() {
        let input = makeInput(
            agentSessions: [
                session(id: "exited-selected", state: .exited, lastSeq: 999, lastEventAt: 999),
                session(id: "older-working", state: .working, lastSeq: 500, lastEventAt: 100),
                session(id: "newer-working", state: .working, lastSeq: 1, lastEventAt: 200),
            ],
            selectedSessionID: "exited-selected"
        )

        let proposal = ProposalEngine().proposals(for: input).first { $0.id.contains("continue-session") }

        XCTAssertEqual(proposal?.target.sessionID, "newer-working")
        XCTAssertFalse(ProposalEngine().proposals(for: input).contains { $0.target.sessionID == "exited-selected" })
    }

    func testFailedToolAndUnansweredQuestionProduceRelevantActions() throws {
        let started = ToolStarted(
            callID: "call-tests",
            tool: "Bash",
            summary: "Run focused tests",
            command: "swift test --filter ParserTests",
            risk: Risk(riskClass: .localWrite, requiresDetailExpansion: false, reasons: ["writes build output"])
        )
        let input = makeInput(
            agentSessions: [session(state: .failed)],
            transcripts: [sessionID: [
                event(seq: 1, body: .toolStarted(started)),
                event(seq: 2, body: .toolFailed(.init(callID: "call-tests", error: "ParserTests failed", exitCode: 1))),
                event(seq: 3, body: .questionRequested(.init(
                    requestID: "question-1",
                    question: "Should I update the golden files?",
                    choices: ["Yes", "No"],
                    allowsFreeText: true
                ))),
            ]],
            selectedSessionID: sessionID
        )

        let proposals = ProposalEngine().proposals(for: input)
        let failed = try XCTUnwrap(proposals.first { $0.title == "Retry Run focused tests" })
        let question = try XCTUnwrap(proposals.first { $0.title == "Answer pending question" })

        XCTAssertEqual(failed.payload, .terminalCommand("swift test --filter ParserTests"))
        XCTAssertEqual(failed.risk, .caution)
        XCTAssertEqual(question.payload, .navigate(question.target))
        XCTAssertTrue(question.detail.contains("Should I update the golden files?"))
    }

    func testCurrentDestinationAndSelectedSessionBoostScoresWithoutChangingIDs() throws {
        let plan = Plan(
            planID: "plan-boost",
            steps: [.init(id: "step-1", title: "Run the focused test", status: .inProgress)]
        )
        let transcript = [sessionID: [event(seq: 1, body: .planUpdated(plan))]]
        let baseline = ProposalEngine().proposals(for: makeInput(
            destination: .home,
            agentSessions: [session()],
            transcripts: transcript
        ))
        let relevant = ProposalEngine().proposals(for: makeInput(
            destination: .sessions,
            agentSessions: [session()],
            transcripts: transcript,
            selectedSessionID: sessionID
        ))
        let baselinePlan = try XCTUnwrap(baseline.first { $0.title == "Run the focused test" })
        let relevantPlan = try XCTUnwrap(relevant.first { $0.title == "Run the focused test" })

        XCTAssertEqual(baselinePlan.id, relevantPlan.id)
        XCTAssertGreaterThan(relevantPlan.score, baselinePlan.score)
    }

    func testGraphAttachesOnlyTopThreePlusMoreUnderRelevantNode() throws {
        let input = makeInput(agentSessions: [session()], selectedSessionID: sessionID)
        let graph = WorkspaceContextGraphBuilder().build(input)
        let target = WorkspaceContextTarget(hostID: hostID, destination: .sessions, sessionID: sessionID)
        let proposals = (0..<5).map { index in
            ProactiveProposal(
                id: "proposal-\(index)",
                title: "Proposal \(index)",
                detail: "Detail \(index)",
                source: .local,
                risk: .safe,
                score: 100 - index,
                target: target,
                payload: .navigate(target)
            )
        }

        let attached = graph.attaching(proposals: proposals)
        let sessionNode = try XCTUnwrap(attached.root.descendants.first {
            $0.action == .openAgentSession(sessionID: sessionID)
        })

        XCTAssertEqual(sessionNode.children.filter { $0.kind == .proposal }.map(\.title), ["Proposal 0", "Proposal 1", "Proposal 2"])
        let more = try XCTUnwrap(sessionNode.children.first { $0.kind == .more })
        guard case .showMoreProposals(let remaining) = more.action else {
            return XCTFail("More must retain the remaining proposals")
        }
        XCTAssertEqual(remaining.map(\.title), ["Proposal 3", "Proposal 4"])
    }

    func testGraphExposesOnlyThreeProposalLeavesGloballyPlusOneMoreAcrossDifferentAttachments() throws {
        let graph = WorkspaceContextGraphBuilder().build(makeInput(agentSessions: [session(id: "sess-a"), session(id: "sess-b")]))
        let proposals = (0..<6).map { index in
            proposal(
                id: "p\(index)",
                score: 100 - index,
                target: WorkspaceContextTarget(hostID: hostID, destination: .sessions, sessionID: index.isMultiple(of: 2) ? "sess-a" : "sess-b")
            )
        }

        let attached = graph.attaching(proposals: proposals)

        XCTAssertEqual(attached.root.descendants.filter { $0.kind == .proposal }.map(\.title).sorted(), ["p0", "p1", "p2"])
        let moreNodes = attached.root.descendants.filter { $0.kind == .more }
        XCTAssertEqual(moreNodes.count, 1)
        guard case .showMoreProposals(let remaining) = moreNodes.first?.action else { return XCTFail("Missing global More") }
        XCTAssertEqual(remaining.map(\.id), ["p3", "p4", "p5"])
    }

    func testAgentTargetsCarrySelectedHerdrContextAndAttachDestinationToolsBelowPane() throws {
        let pane = RemoteSession(id: "pane-1", name: "selected", kind: .herdr, terminalID: "term-1", workspaceID: "workspace-1", tabID: "tab-1", tabLabel: "Code")
        let plan = Plan(planID: "plan-herdr", steps: [.init(id: "step", title: "Use selected pane", status: .inProgress)])
        let input = makeInput(
            agentSessions: [session()],
            transcripts: [sessionID: [event(seq: 1, body: .planUpdated(plan))]],
            selectedSessionID: sessionID,
            selectedTabID: "tab-1",
            selectedPaneID: "pane-1",
            sessionSpace: .init(hostID: hostID, connectionGeneration: 4, remoteSessions: [pane])
        )

        let proposal = try XCTUnwrap(ProposalEngine().proposals(for: input).first { $0.title == "Use selected pane" })
        XCTAssertEqual(proposal.target.multiplexerKind, .herdr)
        XCTAssertEqual(proposal.target.multiplexerSessionID, "pane-1")
        XCTAssertEqual(proposal.target.workspaceID, "workspace-1")
        XCTAssertEqual(proposal.target.tabID, "tab-1")
        XCTAssertEqual(proposal.target.paneID, "pane-1")

        let attached = WorkspaceContextGraphBuilder().build(input).attaching(proposals: [proposal])
        let paneNode = try XCTUnwrap(attached.root.descendants.first { $0.action == .focusHerdrPane(workspaceID: "workspace-1", tabID: "tab-1", paneID: "pane-1", terminalID: "term-1") })
        XCTAssertTrue(paneNode.descendants.contains { $0.kind == .proposal && $0.title == "Use selected pane" })
    }

    func testAgentTargetsDoNotGiveSelectedHerdrPaneToOtherActiveSessions() throws {
        let selectedPane = RemoteSession(id: "pane-selected", name: "selected", kind: .herdr, terminalID: "term-selected", workspaceID: "workspace-1", tabID: "tab-1")
        let otherPane = RemoteSession(id: "pane-other", name: "other", kind: .herdr, terminalID: "term-other", workspaceID: "workspace-2", tabID: "tab-2")
        let selectedPlan = Plan(planID: "selected-plan", steps: [.init(id: "s", title: "Selected plan", status: .inProgress)])
        let otherPlan = Plan(planID: "other-plan", steps: [.init(id: "o", title: "Other plan", status: .inProgress)])
        let input = makeInput(
            agentSessions: [
                session(id: sessionID, state: .working, multiplexerTarget: "pane-selected"),
                session(id: "other-active", state: .working, multiplexerTarget: "term-other"),
            ],
            transcripts: [
                sessionID: [event(seq: 1, body: .planUpdated(selectedPlan))],
                "other-active": [event(sessionID: "other-active", seq: 1, timestamp: 1, body: .planUpdated(otherPlan))],
            ],
            selectedSessionID: sessionID,
            selectedTabID: "tab-1",
            selectedPaneID: "pane-selected",
            sessionSpace: .init(hostID: hostID, connectionGeneration: 4, remoteSessions: [selectedPane, otherPane])
        )

        let proposals = ProposalEngine().proposals(for: input)
        let selected = try XCTUnwrap(proposals.first { $0.title == "Selected plan" })
        let other = try XCTUnwrap(proposals.first { $0.title == "Other plan" })

        XCTAssertEqual(selected.target.paneID, "pane-selected")
        XCTAssertEqual(other.target.paneID, "pane-other")
        XCTAssertNotEqual(other.target.paneID, "pane-selected")
    }

    func testExecutableAgentTargetResolvesExactTmuxSessionIdentity() throws {
        let remote = RemoteSession(id: "$9", name: "work", kind: .tmux)
        let plan = Plan(planID: "plan-tmux", steps: [.init(id: "step", title: "Continue tmux work", status: .inProgress)])
        let input = makeInput(
            agentSessions: [session(multiplexerTarget: "work:2.0")],
            transcripts: [sessionID: [event(seq: 1, body: .planUpdated(plan))]],
            selectedSessionID: sessionID,
            sessionSpace: .init(hostID: hostID, connectionGeneration: 4, remoteSessions: [remote])
        )

        let proposal = try XCTUnwrap(ProposalEngine().proposals(for: input).first { $0.title == "Continue tmux work" })

        XCTAssertEqual(proposal.target.sessionID, sessionID)
        XCTAssertEqual(proposal.target.multiplexerKind, .tmux)
        XCTAssertEqual(proposal.target.multiplexerSessionID, "$9")
    }

    func testEqualScoresUseStableIDTieBreaking() {
        let input = makeInput(repositories: [
            repo(name: "Zulu", path: "/work/zulu", dirty: true),
            repo(name: "Alpha", path: "/work/alpha", dirty: true),
        ])

        let dirty = ProposalEngine().proposals(for: input).filter { $0.title.hasPrefix("Review ") }

        XCTAssertEqual(dirty.count, 2)
        XCTAssertEqual(dirty.map(\.id), dirty.map(\.id).sorted())
    }

    func testFrozenGraphRetainsOldProposalOrderWhenEventsUpdate() throws {
        let target = WorkspaceContextTarget(hostID: hostID, destination: .sessions, sessionID: sessionID)
        let graph = WorkspaceContextGraphBuilder().build(makeInput(agentSessions: [session()]))
        let oldProposals = [
            proposal(id: "a", score: 200, target: target),
            proposal(id: "b", score: 100, target: target),
        ]
        let frozen = graph.attaching(proposals: oldProposals)
        let updated = graph.attaching(proposals: [
            proposal(id: "b", score: 300, target: target),
            proposal(id: "a", score: 50, target: target),
        ])

        XCTAssertEqual(try proposalIDs(in: frozen), ["a", "b"])
        XCTAssertEqual(try proposalIDs(in: updated), ["b", "a"])
        XCTAssertEqual(try proposalIDs(in: frozen), ["a", "b"])
    }

    func testSecretsPrivateKeysBearerTokensAndLongOutputAreRedacted() throws {
        let privateKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        super-secret-private-key-material
        -----END OPENSSH PRIVATE KEY-----
        """
        let command = "curl -H 'Authorization: Bearer abc.def.ghi' -H 'Authorization: Basic dXNlcjpwYXNz' -u admin:password123 https://alice:super-secret@example.test PASSWORD=\"two word secret"
        let longOutput = String(repeating: "terminal-output ", count: 100)
        let input = makeInput(
            agentSessions: [session(state: .failed)],
            transcripts: [sessionID: [
                event(seq: 1, body: .toolStarted(.init(
                    callID: "call-secret",
                    tool: "Bash",
                    summary: "Retry with token=very-secret-token and password=hunter2",
                    command: command,
                    risk: Risk(riskClass: .credentialAccess, requiresDetailExpansion: true, reasons: ["credential access"])
                ))),
                event(seq: 2, body: .toolOutput(.init(callID: "call-secret", chunk: privateKey + longOutput, stream: .stderr, truncated: false))),
                event(seq: 3, body: .toolFailed(.init(callID: "call-secret", error: "Bearer another-secret-token", exitCode: 1))),
            ]]
        )

        let proposal = try XCTUnwrap(ProposalEngine().proposals(for: input).first { $0.title.hasPrefix("Retry ") })
        let visible = proposal.title + "\n" + proposal.detail + "\n" + proposal.payload.textForTesting

        XCTAssertFalse(visible.contains("very-secret-token"))
        XCTAssertFalse(visible.contains("hunter2"))
        XCTAssertFalse(visible.contains("abc.def.ghi"))
        XCTAssertFalse(visible.contains("another-secret-token"))
        XCTAssertFalse(visible.contains("dXNlcjpwYXNz"))
        XCTAssertFalse(visible.contains("alice:super-secret"))
        XCTAssertFalse(visible.contains("two word secret"))
        XCTAssertFalse(visible.contains("word secret"))
        XCTAssertFalse(visible.contains("super-secret-private-key-material"))
        XCTAssertTrue(visible.contains("[REDACTED]"))
        XCTAssertLessThanOrEqual(proposal.detail.count, 513)
        XCTAssertEqual(proposal.risk, .destructive)
    }

    func testDestructiveNaturalLanguageVerbObjectRules() throws {
        for phrase in ["Delete customer records", "Remove production backups", "Destroy the repository", "Purge the codebase"] {
            let input = makeInput(
                agentSessions: [session(state: .failed)],
                transcripts: [sessionID: [
                    event(seq: 1, body: .toolStarted(.init(callID: phrase, tool: "Bash", summary: phrase, command: phrase, risk: .unknown))),
                    event(seq: 2, body: .toolFailed(.init(callID: phrase, error: phrase, exitCode: 1))),
                ]]
            )
            let proposal = try XCTUnwrap(ProposalEngine().proposals(for: input).first { $0.title.hasPrefix("Retry ") })
            XCTAssertEqual(proposal.risk, .destructive, phrase)
        }
    }

    func testDestructiveLanguageUnterminatedSecretsCredentialAssignmentsAndTruncationMarker() throws {
        let input = makeInput(
            agentSessions: [session(state: .failed)],
            transcripts: [sessionID: [
                event(seq: 1, body: .toolStarted(.init(callID: "call-redact", tool: "Bash", summary: "Delete production data", command: "deploy PASSWORD = hunter2 AWS_SECRET_ACCESS_KEY: abc123", risk: .unknown))),
                event(seq: 2, body: .toolOutput(.init(callID: "call-redact", chunk: "-----BEGIN PRIVATE KEY-----\nnever-show\n" + String(repeating: "x", count: 5000), stream: .stderr, truncated: true))),
                event(seq: 3, body: .toolFailed(.init(callID: "call-redact", error: "Delete production data", exitCode: 1))),
            ]]
        )

        let proposal = try XCTUnwrap(ProposalEngine().proposals(for: input).first { $0.title.hasPrefix("Retry ") })
        let visible = proposal.title + "\n" + proposal.detail + "\n" + proposal.payload.textForTesting

        XCTAssertEqual(proposal.risk, .destructive)
        XCTAssertFalse(visible.contains("hunter2"))
        XCTAssertFalse(visible.contains("abc123"))
        XCTAssertFalse(visible.contains("never-show"))
        XCTAssertTrue(visible.contains("[REDACTED"))
        XCTAssertTrue(visible.contains("[truncated"))
        XCTAssertLessThanOrEqual(proposal.detail.count, 513)
    }

    func testProposalExtractionDoesNotMutateTranscriptOrCreateAModelTurn() {
        let completed = event(seq: 1, body: .turnCompleted(.init(
            turnID: "turn-1",
            role: .assistant,
            text: "Next, run the focused tests."
        )))
        let input = makeInput(agentSessions: [session()], transcripts: [sessionID: [completed]])
        let before = input.transcripts

        _ = ProposalEngine().proposals(for: input)

        XCTAssertEqual(input.transcripts, before)
        XCTAssertEqual(input.transcripts[sessionID]?.count, 1)
    }

    func testPreviewFixtureSeedsHerdrTabsAndContextualProposalSources() throws {
        let input = PreviewBackend.scenario(.populated).proactiveWorkspaceContextInput()
        let graph = WorkspaceContextGraphBuilder().build(input)
        let proposals = ProposalEngine().proposals(for: input)

        let workspace = try XCTUnwrap(graph.root.children.first { $0.title == "openpaw-mobile" })
        XCTAssertEqual(Set(workspace.children.map(\.title)), ["Code", "Plan"])
        XCTAssertTrue(proposals.contains { $0.source == .local && $0.title == "Review openpaw changes" })
        XCTAssertTrue(proposals.contains {
            $0.source == .agentDerived && $0.title == "Narrow the token fixture from module to function scope"
        })
        XCTAssertTrue(proposals.contains { $0.source == .agentDerived && $0.title.hasPrefix("Retry ") })
    }

    private func makeInput(
        destination: WorkspaceContextDestination = .sessions,
        agentSessions: [SessionSummary] = [],
        transcripts: [String: [Event]] = [:],
        selectedSessionID: String? = nil,
        selectedTabID: String? = nil,
        selectedPaneID: String? = nil,
        sessionSpace: SessionSpaceSnapshot? = nil,
        repositories: [RepoSummary] = [],
        inbox: [InboxItem] = [],
        isConnected: Bool = true
    ) -> WorkspaceContextInput {
        WorkspaceContextInput(
            snapshotID: snapshotID,
            host: .init(id: hostID, title: "Work Mac"),
            connectionGeneration: 4,
            destination: destination,
            agentSessions: agentSessions,
            transcripts: transcripts,
            sessionSpace: sessionSpace ?? .init(hostID: hostID, connectionGeneration: 4),
            selectedSessionID: selectedSessionID,
            selectedTabID: selectedTabID,
            selectedPaneID: selectedPaneID,
            repositories: repositories,
            inbox: inbox,
            authenticatedDestinations: Set(WorkspaceContextDestination.allCases),
            isConnected: isConnected
        )
    }

    private func session(
        id: String? = nil,
        state: SessionState = .working,
        lastSeq: UInt64 = 20,
        lastEventAt: TimeInterval = 20,
        multiplexerTarget: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            sessionID: id ?? sessionID,
            agent: .claudeCode,
            title: "Proposal session",
            cwd: "/work/openpaw",
            gitBranch: "feat/proposals",
            multiplexerTarget: multiplexerTarget,
            state: state,
            lastEventAt: Date(timeIntervalSince1970: lastEventAt),
            lastSeq: lastSeq
        )
    }

    private func repo(name: String, path: String, dirty: Bool) -> RepoSummary {
        RepoSummary(name: name, path: path, branch: "main", dirty: dirty, ahead: 0, behind: 0)
    }

    private func inboxItem(title: String) -> InboxItem {
        let sid = SessionID(rawValue: sessionID)
        let eventID = EventID(session: sid, sourceKey: "inbox")
        return InboxItem(
            id: InboxID(event: eventID),
            sessionID: sid,
            agent: .claudeCode,
            category: .permission,
            title: title,
            detail: "Run focused tests",
            actions: [.approveOnce, .deny],
            requestID: "request-1",
            createdAt: Date(timeIntervalSince1970: 10),
            status: .pending,
            sourceEventID: eventID
        )
    }

    private func event(seq: UInt64, body: Body) -> Event {
        event(sessionID: sessionID, seq: seq, timestamp: TimeInterval(seq), body: body)
    }

    private func event(sessionID: String, seq: UInt64, timestamp: TimeInterval = 0, body: Body) -> Event {
        let sid = SessionID(rawValue: sessionID)
        return Event(
            eventID: EventID(session: sid, sourceKey: "event-\(seq)"),
            sessionID: sid,
            agent: .claudeCode,
            seq: seq,
            timestamp: Date(timeIntervalSince1970: timestamp == 0 ? TimeInterval(seq) : timestamp),
            cwd: "/work/openpaw",
            gitBranch: "feat/proposals",
            body: body
        )
    }

    private func proposal(id: String, score: Int, target: WorkspaceContextTarget) -> ProactiveProposal {
        ProactiveProposal(
            id: id,
            title: id,
            detail: id,
            source: .local,
            risk: .safe,
            score: score,
            target: target,
            payload: .navigate(target)
        )
    }

    private func proposalIDs(in graph: WorkspaceContextGraph) throws -> [String] {
        let node = try XCTUnwrap(graph.root.descendants.first {
            $0.action == .openAgentSession(sessionID: sessionID)
        })
        return node.children.compactMap { child in
            guard case .openProposal(let proposal) = child.action else { return nil }
            return proposal.id
        }
    }
}

private extension ProactiveProposal.Payload {
    var textForTesting: String {
        switch self {
        case .navigate: ""
        case .agentMessage(let text), .terminalCommand(let text): text
        case .tool(let action): action.title
        }
    }
}
