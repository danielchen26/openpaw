import XCTest
import OpenPawProtocol
import OpenPawTerminalCore
@testable import OpenPawUI

final class SessionSpacePresentationTests: XCTestCase {
    // MARK: creating a session on a host with no explicit preference

    func testCreationFollowsWhatIsActuallyRunningOnTheHost() {
        // The user's host runs herdr and no tmux. Creating a session used to fall back to tmux and fail silently.
        let herdr = RemoteSession(id: "w3:p9", name: "fix the build", kind: .herdr)
        let transport = SessionTransportPresentation(preferredMultiplexer: nil, attemptedMultiplexers: [.tmux, .zellij, .screen, .herdr])
        let snapshot = SessionSpaceSnapshot(remoteSessions: [herdr], transport: transport)
        XCTAssertEqual(snapshot.multiplexerForNewSessions, .herdr)
    }

    func testAnExplicitHostPreferenceStillWins() {
        let herdr = RemoteSession(id: "w3:p9", name: "fix the build", kind: .herdr)
        let transport = SessionTransportPresentation(preferredMultiplexer: .screen, attemptedMultiplexers: [.screen])
        let snapshot = SessionSpaceSnapshot(remoteSessions: [herdr], transport: transport)
        XCTAssertEqual(snapshot.multiplexerForNewSessions, .screen)
    }

    func testTheMostCommonRunningMultiplexerWins() {
        // A host with one stray tmux session and three herdr agents should create herdr sessions.
        let sessions = [
            RemoteSession(id: "$0", name: "stray", kind: .tmux),
            RemoteSession(id: "w3:p1", name: "a", kind: .herdr),
            RemoteSession(id: "w3:p9", name: "b", kind: .herdr),
            RemoteSession(id: "w3:pB", name: "c", kind: .herdr),
        ]
        let snapshot = SessionSpaceSnapshot(remoteSessions: sessions, transport: .init(attemptedMultiplexers: [.tmux, .herdr]))
        XCTAssertEqual(snapshot.multiplexerForNewSessions, .herdr)
    }

    func testAnEmptyHostStillFallsBackToTmux() {
        let snapshot = SessionSpaceSnapshot(remoteSessions: [], transport: .init(attemptedMultiplexers: [.tmux, .herdr]))
        XCTAssertEqual(snapshot.multiplexerForNewSessions, .tmux)
    }

    func testMixedProvenancePreservesAgentAndRawSessionsWithDuplicateNames() {
        let agent = SessionSummary(sessionID: "agent-1", agent: .codex, title: "api", multiplexerTarget: "api", state: .waiting, pendingInbox: 2)
        let raw = RemoteSession(id: "$0", name: "api", kind: .tmux, isAttached: false, isAlive: true, windowCount: 2)
        let space = SessionSpacePresentation(agentSessions: [agent], remoteSessions: [raw], restoration: nil, transport: .init(preferredMultiplexer: .tmux, attemptedMultiplexers: [.tmux]))

        XCTAssertEqual(space.items.count, 2)
        XCTAssertEqual(space.items[0].provenance, .agentSession(agent.sessionID))
        XCTAssertEqual(space.items[0].title, "api")
        XCTAssertEqual(space.items[0].provenanceBadge, "Codex agent")
        XCTAssertEqual(space.items[0].primaryAction, "Open transcript")
        XCTAssertEqual(space.items[1].provenance, .multiplexerSession(kind: .tmux, id: "$0"))
        XCTAssertEqual(space.items[1].title, "api")
        XCTAssertEqual(space.items[1].provenanceBadge, "tmux")
        XCTAssertEqual(space.items[1].primaryAction, "Attach")
    }

    func testExitedAndStaleStatesUseTruthfulLabelsAndActions() {
        let exitedAgent = SessionSummary(sessionID: "old", agent: .claudeCode, title: "done", state: .exited)
        let staleZellij = RemoteSession(id: "stale", name: "stale", kind: .zellij, isAttached: false, isAlive: false, windowCount: 1)
        let screenDead = RemoteSession(id: "123.dead", name: "dead", kind: .screen, isAttached: false, isAlive: false, windowCount: 0)
        let space = SessionSpacePresentation(agentSessions: [exitedAgent], remoteSessions: [staleZellij, screenDead], restoration: nil, transport: .init())

        XCTAssertEqual(space.items.map(\.stateLabel), ["exited", "exited or stale", "exited or stale"])
        XCTAssertEqual(space.items[0].primaryAction, "Open transcript")
        XCTAssertEqual(space.items[1].primaryAction, "Attach unavailable")
        XCTAssertEqual(space.items[1].secondaryActions, ["Kill"])
    }

    func testSnapshotsAreBoundToHostAndConnectionGeneration() {
        let hostID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let snapshot = SessionSpaceSnapshot(hostID: hostID, connectionGeneration: 2)

        XCTAssertTrue(SessionSpaceActionPolicy.canUseSnapshot(snapshot, hostID: hostID, generation: 2, isConnected: true))
        XCTAssertFalse(SessionSpaceActionPolicy.canUseSnapshot(snapshot, hostID: hostID, generation: 3, isConnected: true))
        XCTAssertFalse(SessionSpaceActionPolicy.canUseSnapshot(snapshot, hostID: UUID(), generation: 2, isConnected: true))
        XCTAssertFalse(SessionSpaceActionPolicy.canUseSnapshot(snapshot, hostID: hostID, generation: 2, isConnected: false))
    }

    func testActionPolicyMatchesVisibleDeadRowActionsAndNavigation() {
        let hostID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let dead = RemoteSession(id: "dead", name: "dead", kind: .tmux, isAttached: false, isAlive: false, windowCount: 0)
        let live = RemoteSession(id: "live", name: "live", kind: .tmux, isAttached: false, isAlive: true, windowCount: 1)
        let space = SessionSpacePresentation(agentSessions: [], remoteSessions: [dead, live], restoration: nil)
        let snapshot = SessionSpaceSnapshot(hostID: hostID, connectionGeneration: 9, remoteSessions: [dead, live])

        XCTAssertEqual(space.items[0].primaryAction, "Attach unavailable")
        XCTAssertEqual(space.items[0].secondaryActions, ["Kill"])
        XCTAssertFalse(SessionSpaceActionPolicy.allows("Attach", item: space.items[0], snapshot: snapshot, hostID: hostID, generation: 9, isConnected: true))
        XCTAssertTrue(SessionSpaceActionPolicy.allows("Kill", item: space.items[0], snapshot: snapshot, hostID: hostID, generation: 9, isConnected: true))
        XCTAssertTrue(SessionSpaceActionPolicy.allows("Rename", item: space.items[1], snapshot: snapshot, hostID: hostID, generation: 9, isConnected: true))
        XCTAssertEqual(SessionSpaceActionPolicy.navigation(for: "Rename"), .staysInList)
        XCTAssertEqual(SessionSpaceActionPolicy.navigation(for: "Kill"), .staysInList)
        XCTAssertEqual(SessionSpaceActionPolicy.navigation(for: "Attach"), .opensTerminal)
    }

    func testRestorationActionsStayHostMatched() {
        let hostID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let otherHostID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let plan = SessionRestorationPlan(hostID: hostID, multiplexer: .tmux, multiplexerTarget: "$1", workingDirectory: "/repo", capturedAt: Date(timeIntervalSince1970: 0))
        let remote = RemoteSession(id: "$1", name: "$1", kind: .tmux, isAttached: false, isAlive: true, windowCount: 1)
        let item = SessionSpacePresentation(agentSessions: [], remoteSessions: [remote], restoration: plan).restorationItem!
        let snapshot = SessionSpaceSnapshot(hostID: hostID, connectionGeneration: 4, remoteSessions: [remote], restoration: plan)

        XCTAssertTrue(SessionSpaceActionPolicy.allows("Reattach", item: item, snapshot: snapshot, hostID: hostID, generation: 4, isConnected: true))
        XCTAssertFalse(SessionSpaceActionPolicy.allows("Reattach", item: item, snapshot: snapshot, hostID: otherHostID, generation: 4, isConnected: true))
        XCTAssertEqual(SessionSpaceActionPolicy.navigation(for: item.primaryAction), .opensTerminal)
    }

    func testLegacyHerdrRestorationWithoutATerminalIDCreatesAReplacement() {
        let hostID = UUID(uuidString: "89898989-8989-4989-8989-898989898989")!
        let legacy = SessionRestorationPlan(
            hostID: hostID,
            multiplexer: .herdr,
            multiplexerTarget: "w3:p9",
            workingDirectory: "/repo",
            capturedAt: Date(timeIntervalSince1970: 1))
        let remote = RemoteSession(
            id: "w3:p9",
            name: "work",
            kind: .herdr,
            terminalID: "term_current")

        let action = SessionSpaceActionPlan.restore(legacy, remoteSessions: [remote])

        XCTAssertEqual(
            action?.command,
            .create(kind: .herdr, name: "repo", directory: "/repo"))
    }

    func testStaleSnapshotHasNoNavigationCommandAlertOrStoreSideEffects() {
        let hostID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let session = RemoteSession(id: "$1", name: "work", kind: .tmux, isAttached: false, isAlive: true, windowCount: 1)
        let item = SessionSpacePresentation(agentSessions: [], remoteSessions: [session], restoration: nil).items[0]
        let snapshot = SessionSpaceSnapshot(hostID: hostID, connectionGeneration: 1, remoteSessions: [session])

        XCTAssertNil(SessionSpaceActionPolicy.validatedNavigation(for: "Attach", item: item, snapshot: snapshot, hostID: hostID, generation: 2, isConnected: true))
        XCTAssertNil(SessionSpaceActionPolicy.validatedNavigation(for: "Kill", item: item, snapshot: snapshot, hostID: UUID(), generation: 1, isConnected: true))
        XCTAssertNil(SessionSpaceActionPolicy.validatedNavigation(for: "Attach", item: item, snapshot: snapshot, hostID: hostID, generation: 1, isConnected: false))
    }

    func testCreateAndAttachPlansPersistRestorationOnlyAfterTheTypedCommandSucceeds() {
        let hostID = UUID(uuidString: "abababab-abab-abab-abab-abababababab")!
        let remote = RemoteSession(
            id: "$9",
            name: "existing",
            kind: .tmux,
            isAttached: false,
            isAlive: true,
            workingDirectory: "/srv/existing")

        let create = SessionSpaceActionPlan.create(
            hostID: hostID,
            kind: .zellij,
            name: "api",
            directory: "/srv/api")
        XCTAssertEqual(create?.command, .create(kind: .zellij, name: "api", directory: "/srv/api"))
        XCTAssertEqual(create?.navigation, .opensTerminal)
        XCTAssertTrue(create?.refreshAfterCommand ?? false)
        XCTAssertEqual(
            create?.restorationOnSuccess,
            .save(SessionRestorationPlan(
                hostID: hostID,
                multiplexer: .zellij,
                multiplexerTarget: "api",
                workingDirectory: "/srv/api",
                capturedAt: create!.capturedAt)))

        let attach = SessionSpaceActionPlan.attach(hostID: hostID, session: remote)
        XCTAssertEqual(attach?.command, .attach(remote))
        XCTAssertEqual(attach?.navigation, .opensTerminal)
        XCTAssertEqual(
            attach?.restorationOnSuccess,
            .save(SessionRestorationPlan(
                hostID: hostID,
                multiplexer: .tmux,
                multiplexerTarget: "$9",
                workingDirectory: "/srv/existing",
                capturedAt: attach!.capturedAt)))
    }

    func testKillPlanRefreshesAndClearsOnlyTheMatchingRestoration() {
        let session = RemoteSession(id: "$2", name: "api", kind: .tmux)
        let kill = SessionSpaceActionPlan.kill(session: session)

        XCTAssertEqual(kill.command, .kill(session))
        XCTAssertTrue(kill.refreshAfterCommand)
        XCTAssertEqual(kill.navigation, .staysInList)
        XCTAssertEqual(kill.restorationOnSuccess, .clearMatching(kind: .tmux, target: "$2"))
    }

    @MainActor
    func testFailedCreateDoesNotRouteOrPersistRestoration() async {
        let hostID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let snapshot = SessionSpaceSnapshot(hostID: hostID, connectionGeneration: 4)
        let context = SessionSpaceActionContext(
            snapshot: snapshot,
            hostID: hostID,
            connectionGeneration: 4,
            isConnected: true)
        let events = SessionActionEventRecorder()
        let executor = RecordingSessionSpaceExecutor(events: events, error: SessionActionTestError.failed)
        let store = RecordingSessionRestorationStore(events: events)
        let action = SessionSpaceActionPlan.create(hostID: hostID, kind: .tmux, name: "api")!

        do {
            _ = try await SessionSpaceActionCoordinator.run(
                action,
                expectedHostID: hostID,
                expectedGeneration: 4,
                context: { context },
                executor: executor,
                restorationStore: store)
            XCTFail("expected the remote command failure")
        } catch SessionActionTestError.failed {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(events.events, ["execute"])
        XCTAssertTrue(store.savedPlans.isEmpty)
        XCTAssertTrue(store.clearedHostIDs.isEmpty)
    }

    @MainActor
    func testSuccessfulCreateRoutesAndPersistsOnlyAfterRemoteAcknowledgement() async throws {
        let hostID = UUID(uuidString: "13131313-1313-1313-1313-131313131313")!
        let snapshot = SessionSpaceSnapshot(hostID: hostID, connectionGeneration: 7)
        let context = SessionSpaceActionContext(
            snapshot: snapshot,
            hostID: hostID,
            connectionGeneration: 7,
            isConnected: true)
        let events = SessionActionEventRecorder()
        let executor = RecordingSessionSpaceExecutor(events: events)
        let store = RecordingSessionRestorationStore(events: events)
        let action = SessionSpaceActionPlan.create(
            hostID: hostID,
            kind: .zellij,
            name: "release",
            directory: "/srv/release")!

        let intent = try await SessionSpaceActionCoordinator.run(
            action,
            expectedHostID: hostID,
            expectedGeneration: 7,
            context: { context },
            executor: executor,
            restorationStore: store)

        XCTAssertEqual(intent, .attachSession(.target("release", kind: .zellij)))
        XCTAssertEqual(events.events, ["execute", "save"])
        XCTAssertEqual(store.savedPlans.single?.multiplexerTarget, "release")
    }

    @MainActor
    func testAcknowledgedCreatePersistsAndRoutesTheActualRemoteHandle() async throws {
        let hostID = UUID(uuidString: "20202020-2020-2020-2020-202020202020")!
        let snapshot = SessionSpaceSnapshot(hostID: hostID, connectionGeneration: 6)
        let context = SessionSpaceActionContext(
            snapshot: snapshot,
            hostID: hostID,
            connectionGeneration: 6,
            isConnected: true)
        let events = SessionActionEventRecorder()
        let remote = RemoteSession(
            id: "$7",
            name: "release",
            kind: .tmux,
            workingDirectory: "/srv/release")
        let executor = RecordingSessionSpaceExecutor(
            events: events,
            acknowledgement: SessionCommandAcknowledgement(session: remote))
        let store = RecordingSessionRestorationStore(events: events)
        let action = SessionSpaceActionPlan.create(
            hostID: hostID,
            kind: .tmux,
            name: "release",
            directory: "/srv/release")!

        let intent = try await SessionSpaceActionCoordinator.run(
            action,
            expectedHostID: hostID,
            expectedGeneration: 6,
            context: { context },
            executor: executor,
            restorationStore: store)

        XCTAssertEqual(intent, .attachSession(remote))
        XCTAssertEqual(store.savedPlans.single?.multiplexerTarget, "$7")
        XCTAssertEqual(store.savedPlans.single?.workingDirectory, "/srv/release")
    }

    @MainActor
    func testAcknowledgedHerdrCreatePersistsPaneAndTerminalHandles() async throws {
        let hostID = UUID(uuidString: "21212121-2121-4121-8121-212121212121")!
        let snapshot = SessionSpaceSnapshot(hostID: hostID, connectionGeneration: 6)
        let context = SessionSpaceActionContext(
            snapshot: snapshot,
            hostID: hostID,
            connectionGeneration: 6,
            isConnected: true)
        let events = SessionActionEventRecorder()
        let remote = RemoteSession(
            id: "w9:p1",
            name: "release",
            kind: .herdr,
            terminalID: "term_root_9",
            workingDirectory: "/srv/release")
        let executor = RecordingSessionSpaceExecutor(
            events: events,
            acknowledgement: SessionCommandAcknowledgement(session: remote))
        let store = RecordingSessionRestorationStore(events: events)
        let action = SessionSpaceActionPlan.create(
            hostID: hostID,
            kind: .herdr,
            name: "release",
            directory: "/srv/release")!

        let intent = try await SessionSpaceActionCoordinator.run(
            action,
            expectedHostID: hostID,
            expectedGeneration: 6,
            context: { context },
            executor: executor,
            restorationStore: store)

        XCTAssertEqual(intent, .attachSession(remote))
        XCTAssertEqual(store.savedPlans.single?.multiplexerTarget, "w9:p1")
        XCTAssertEqual(store.savedPlans.single?.multiplexerAttachmentTarget, "term_root_9")
    }

    @MainActor
    func testFailedKillKeepsMatchingRestorationAndDoesNotRefresh() async {
        let hostID = UUID(uuidString: "14141414-1414-1414-1414-141414141414")!
        let session = RemoteSession.target("$4", kind: .tmux)
        let plan = SessionRestorationPlan(
            hostID: hostID,
            multiplexer: .tmux,
            multiplexerTarget: "$4",
            capturedAt: Date(timeIntervalSince1970: 1))
        let snapshot = SessionSpaceSnapshot(hostID: hostID, connectionGeneration: 2)
        let context = SessionSpaceActionContext(
            snapshot: snapshot,
            hostID: hostID,
            connectionGeneration: 2,
            isConnected: true)
        let events = SessionActionEventRecorder()
        let executor = RecordingSessionSpaceExecutor(events: events, error: SessionActionTestError.failed)
        let store = RecordingSessionRestorationStore(events: events, plans: [hostID: plan])

        do {
            _ = try await SessionSpaceActionCoordinator.run(
                .kill(session: session),
                expectedHostID: hostID,
                expectedGeneration: 2,
                context: { context },
                executor: executor,
                restorationStore: store,
                refresh: { events.append("refresh") })
            XCTFail("expected the remote command failure")
        } catch SessionActionTestError.failed {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(events.events, ["execute"])
        XCTAssertEqual(store.plans[hostID], plan)
    }

    @MainActor
    func testSuccessfulKillClearsBeforeRefreshingTheVisibleRestorationState() async throws {
        let hostID = UUID(uuidString: "15151515-1515-1515-1515-151515151515")!
        let session = RemoteSession.target("$5", kind: .tmux)
        let plan = SessionRestorationPlan(
            hostID: hostID,
            multiplexer: .tmux,
            multiplexerTarget: "$5",
            capturedAt: Date(timeIntervalSince1970: 1))
        let snapshot = SessionSpaceSnapshot(hostID: hostID, connectionGeneration: 3)
        let context = SessionSpaceActionContext(
            snapshot: snapshot,
            hostID: hostID,
            connectionGeneration: 3,
            isConnected: true)
        let events = SessionActionEventRecorder()
        let executor = RecordingSessionSpaceExecutor(events: events)
        let store = RecordingSessionRestorationStore(events: events, plans: [hostID: plan])
        var visibleRestoration: SessionRestorationPlan? = plan

        let intent = try await SessionSpaceActionCoordinator.run(
            .kill(session: session),
            expectedHostID: hostID,
            expectedGeneration: 3,
            context: { context },
            executor: executor,
            restorationStore: store,
            refresh: {
                events.append("refresh")
                visibleRestoration = await store.loadPlan(for: hostID)
            })

        XCTAssertNil(intent)
        XCTAssertEqual(events.events, ["execute", "load", "clear", "refresh", "load"])
        XCTAssertNil(store.plans[hostID])
        XCTAssertNil(visibleRestoration)
    }

    @MainActor
    func testGenerationChangeWhileCommandIsSuspendedDiscardsNavigationAndRestoration() async throws {
        let hostID = UUID(uuidString: "16161616-1616-1616-1616-161616161616")!
        let state = SessionActionContextBox(SessionSpaceActionContext(
            snapshot: SessionSpaceSnapshot(hostID: hostID, connectionGeneration: 8),
            hostID: hostID,
            connectionGeneration: 8,
            isConnected: true))
        let events = SessionActionEventRecorder()
        let gate = SessionActionGate()
        let executor = RecordingSessionSpaceExecutor(events: events, gate: gate)
        let store = RecordingSessionRestorationStore(events: events)
        let action = SessionSpaceActionPlan.create(hostID: hostID, kind: .tmux, name: "stale")!

        let task = Task { @MainActor in
            try await SessionSpaceActionCoordinator.run(
                action,
                expectedHostID: hostID,
                expectedGeneration: 8,
                context: { state.value },
                executor: executor,
                restorationStore: store)
        }
        await gate.waitUntilStarted()
        state.value.connectionGeneration = 9
        state.value.snapshot.connectionGeneration = 9
        await gate.release()

        let intent = try await task.value
        XCTAssertNil(intent)
        XCTAssertEqual(events.events, ["execute"])
        XCTAssertTrue(store.savedPlans.isEmpty)
    }

    @MainActor
    func testStaleExecutorFailureIsDiscardedInsteadOfSurfacingOnTheNewConnection() async throws {
        let hostID = UUID(uuidString: "17171717-1717-1717-1717-171717171717")!
        let state = SessionActionContextBox(SessionSpaceActionContext(
            snapshot: SessionSpaceSnapshot(hostID: hostID, connectionGeneration: 8),
            hostID: hostID,
            connectionGeneration: 8,
            isConnected: true))
        let events = SessionActionEventRecorder()
        let gate = SessionActionGate()
        let executor = RecordingSessionSpaceExecutor(
            events: events,
            error: SessionActionTestError.failed,
            gate: gate)
        let action = SessionSpaceActionPlan.create(hostID: hostID, kind: .tmux, name: "stale")!

        let task = Task { @MainActor in
            try await SessionSpaceActionCoordinator.run(
                action,
                expectedHostID: hostID,
                expectedGeneration: 8,
                context: { state.value },
                executor: executor)
        }
        await gate.waitUntilStarted()
        state.value.connectionGeneration = 9
        state.value.snapshot.connectionGeneration = 9
        await gate.release()

        let intent = try await task.value
        XCTAssertNil(intent)
        XCTAssertEqual(events.events, ["execute"])
    }

    @MainActor
    func testGenerationChangeWhileRestorationSaveIsSuspendedCannotCommitAStalePlan() async throws {
        let hostID = UUID(uuidString: "18181818-1818-1818-1818-181818181818")!
        let state = SessionActionContextBox(SessionSpaceActionContext(
            snapshot: SessionSpaceSnapshot(hostID: hostID, connectionGeneration: 3),
            hostID: hostID,
            connectionGeneration: 3,
            isConnected: true))
        let events = SessionActionEventRecorder()
        let gate = SessionActionGate()
        let store = RecordingSessionRestorationStore(events: events, mutationGate: gate)
        let action = SessionSpaceActionPlan.create(hostID: hostID, kind: .tmux, name: "stale-save")!

        let task = Task { @MainActor in
            try await SessionSpaceActionCoordinator.run(
                action,
                expectedHostID: hostID,
                expectedGeneration: 3,
                context: { state.value },
                executor: RecordingSessionSpaceExecutor(events: events),
                restorationStore: store)
        }
        await gate.waitUntilStarted()
        state.value.connectionGeneration = 4
        state.value.snapshot.connectionGeneration = 4
        await gate.release()

        let intent = try await task.value
        XCTAssertNil(intent)
        XCTAssertTrue(store.savedPlans.isEmpty)
        XCTAssertNil(store.plans[hostID])
    }

    @MainActor
    func testGenerationChangeWhileRestorationClearIsSuspendedCannotClearTheNewConnectionsPlan() async throws {
        let hostID = UUID(uuidString: "19191919-1919-1919-1919-191919191919")!
        let session = RemoteSession.target("$9", kind: .tmux)
        let plan = SessionRestorationPlan(
            hostID: hostID,
            multiplexer: .tmux,
            multiplexerTarget: "$9",
            capturedAt: Date(timeIntervalSince1970: 1))
        let state = SessionActionContextBox(SessionSpaceActionContext(
            snapshot: SessionSpaceSnapshot(hostID: hostID, connectionGeneration: 5),
            hostID: hostID,
            connectionGeneration: 5,
            isConnected: true))
        let events = SessionActionEventRecorder()
        let gate = SessionActionGate()
        let store = RecordingSessionRestorationStore(
            events: events,
            plans: [hostID: plan],
            mutationGate: gate)

        let task = Task { @MainActor in
            try await SessionSpaceActionCoordinator.run(
                .kill(session: session),
                expectedHostID: hostID,
                expectedGeneration: 5,
                context: { state.value },
                executor: RecordingSessionSpaceExecutor(events: events),
                restorationStore: store,
                refresh: { events.append("refresh") })
        }
        await gate.waitUntilStarted()
        state.value.connectionGeneration = 6
        state.value.snapshot.connectionGeneration = 6
        await gate.release()

        let intent = try await task.value
        XCTAssertNil(intent)
        XCTAssertEqual(store.plans[hostID], plan)
        XCTAssertTrue(store.clearedHostIDs.isEmpty)
    }

    func testMissingRestorationTargetCreatesAndPersistsADeterministicReplacement() {
        let hostID = UUID(uuidString: "cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd")!
        let restoration = SessionRestorationPlan(
            hostID: hostID,
            multiplexer: .tmux,
            multiplexerTarget: "$gone",
            workingDirectory: "/srv/api rocks",
            capturedAt: Date(timeIntervalSince1970: 1))

        let action = SessionSpaceActionPlan.restore(restoration, remoteSessions: [])

        XCTAssertEqual(
            action?.command,
            .create(kind: .tmux, name: "api-rocks", directory: "/srv/api rocks"))
        XCTAssertEqual(action?.navigation, .opensTerminal)
        guard case .save(let replacement) = action?.restorationOnSuccess else {
            return XCTFail("expected a replacement restoration plan")
        }
        XCTAssertEqual(replacement.multiplexerTarget, "api-rocks")
        XCTAssertEqual(replacement.workingDirectory, "/srv/api rocks")
    }

    func testPersistedRestorationIsReconciledWithDiscoveredSessions() {
        let hostID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let live = RemoteSession(id: "$live", name: "live", kind: .tmux, isAttached: false, isAlive: true, windowCount: 1)
        let dead = RemoteSession(id: "$dead", name: "dead", kind: .tmux, isAttached: false, isAlive: false, windowCount: 0)
        let livePlan = SessionRestorationPlan(hostID: hostID, multiplexer: .tmux, multiplexerTarget: "$live", workingDirectory: "/repo", capturedAt: Date(timeIntervalSince1970: 0))
        let deadPlan = SessionRestorationPlan(hostID: hostID, multiplexer: .tmux, multiplexerTarget: "$dead", workingDirectory: "/repo", capturedAt: Date(timeIntervalSince1970: 0))
        let missingPlan = SessionRestorationPlan(hostID: hostID, multiplexer: .tmux, multiplexerTarget: "$missing", workingDirectory: "/repo", capturedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(SessionSpacePresentation(agentSessions: [], remoteSessions: [live, dead], restoration: livePlan).restorationItem?.primaryAction, "Reattach")
        XCTAssertEqual(SessionSpacePresentation(agentSessions: [], remoteSessions: [live, dead], restoration: deadPlan).restorationItem?.stateLabel, "stale target")
        XCTAssertEqual(SessionSpacePresentation(agentSessions: [], remoteSessions: [live, dead], restoration: deadPlan).restorationItem?.primaryAction, "Create replacement session")
        XCTAssertEqual(SessionSpacePresentation(agentSessions: [], remoteSessions: [live, dead], restoration: missingPlan).restorationItem?.stateLabel, "stale target")
        XCTAssertEqual(SessionSpacePresentation(agentSessions: [], remoteSessions: [live, dead], restoration: missingPlan).restorationItem?.primaryAction, "Create replacement session")
    }

    func testRestorationPolicyDistinguishesReattachFromBareShellFallback() {
        let hostID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let reattach = SessionRestorationPlan(
            hostID: hostID,
            multiplexer: .herdr,
            multiplexerTarget: "w3:p9",
            multiplexerAttachmentTarget: "term_65909b7e020c13",
            workingDirectory: "/repo",
            capturedAt: Date(timeIntervalSince1970: 0))
        let replacement = SessionRestorationPlan(hostID: hostID, multiplexer: .tmux, workingDirectory: "/repo", capturedAt: Date(timeIntervalSince1970: 0))
        let fallback = SessionRestorationPlan(hostID: hostID, workingDirectory: "/repo", capturedAt: Date(timeIntervalSince1970: 0))

        let reattachRemote = RemoteSession(
            id: "w3:p9",
            name: "work",
            kind: .herdr,
            terminalID: "term_65909b7e020c13",
            isAttached: false,
            isAlive: true,
            windowCount: 1)

        XCTAssertEqual(SessionSpacePresentation(agentSessions: [], remoteSessions: [reattachRemote], restoration: reattach, transport: .init()).restorationItem?.provenance, .restoration(kind: .herdr, target: "w3:p9"))
        XCTAssertEqual(SessionSpacePresentation(agentSessions: [], remoteSessions: [reattachRemote], restoration: reattach, transport: .init()).restorationItem?.primaryAction, "Reattach")
        XCTAssertEqual(SessionSpacePresentation(agentSessions: [], remoteSessions: [], restoration: replacement, transport: .init()).restorationItem?.provenance, .replacementMultiplexer(kind: .tmux, directory: "/repo"))
        XCTAssertEqual(SessionSpacePresentation(agentSessions: [], remoteSessions: [], restoration: replacement, transport: .init()).restorationItem?.primaryAction, "Create replacement session")
        XCTAssertEqual(SessionSpacePresentation(agentSessions: [], remoteSessions: [], restoration: fallback, transport: .init()).restorationItem?.provenance, .bareShellFallback(directory: "/repo"))
        XCTAssertEqual(SessionSpacePresentation(agentSessions: [], remoteSessions: [], restoration: fallback, transport: .init()).restorationItem?.primaryAction, "Open shell")
    }

    func testNoDiscoveredSessionsDoesNotTurnPreferenceIntoHealth() {
        let space = SessionSpacePresentation(agentSessions: [], remoteSessions: [], restoration: nil, transport: .init(preferredMultiplexer: .screen, attemptedMultiplexers: [.tmux, .zellij, .screen, .herdr]))
        XCTAssertTrue(space.items.isEmpty)
        XCTAssertEqual(space.emptyRemoteMessage, "No tmux, Zellij, GNU Screen, or Herdr sessions were discovered on this host.")
        XCTAssertEqual(space.transport.preferredMultiplexer, .screen)
        XCTAssertEqual(space.transport.preferenceLabel, "Preference: GNU Screen")
        XCTAssertEqual(space.transport.discoveryLabel, "Checked: tmux, Zellij, GNU Screen, Herdr")
    }

    @MainActor
    func testLiveProviderDiscoversThroughAdaptersAndKeepsPreferenceSeparate() async {
        let provider = LiveMultiplexerSessionSpaceProvider(
            runner: RecordingRunner(),
            adapters: [ProviderAdapter(kind: .tmux, result: .success([RemoteSession.target("$0", kind: .tmux)]))],
            preferred: .zellij)

        let model = OpenPawModel(hostStore: HostStore(hosts: [testHost()]))
        model.connection = .connected(.ssh)
        let snapshot = await provider.snapshot(for: model)
        XCTAssertEqual(snapshot.remoteSessions.map(\.id), ["$0"])
        XCTAssertEqual(snapshot.transport.preferredMultiplexer, .zellij)
        XCTAssertEqual(snapshot.transport.attemptedMultiplexers, [.tmux])
        XCTAssertNil(snapshot.restoration)
    }

    @MainActor
    func testLiveProviderKeepsMalformedOutputVisibleButUnavailableAdaptersEmpty() async {
        let provider = LiveMultiplexerSessionSpaceProvider(
            runner: RecordingRunner(),
            adapters: [
                ProviderAdapter(kind: .tmux, result: .success([])),
                ProviderAdapter(kind: .herdr, result: .failure(MultiplexerError.malformedOutput(kind: .herdr, detail: "{"))),
            ])

        let model = OpenPawModel(hostStore: HostStore(hosts: [testHost()]))
        model.connection = .connected(.ssh)
        let snapshot = await provider.snapshot(for: model)
        XCTAssertTrue(snapshot.remoteSessions.isEmpty)
        XCTAssertEqual(snapshot.transport.attemptedMultiplexers, [.tmux, .herdr])
        XCTAssertEqual(snapshot.issues.count, 1)
        XCTAssertTrue(snapshot.issues[0].contains("Herdr"))
    }

    @MainActor
    func testLiveProviderUsesSelectedHostPreferenceAndSanitizesCommandFailures() async {
        let host = HostRecord(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            nickname: "beta",
            hostname: "beta.local",
            port: 22,
            username: "dev",
            auth: .password(reference: try! KeychainReference(identifier: "kc://openpaw/beta/password")),
            multiplexerPreference: .screen)
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]))
        model.connection = .connected(.ssh)
        let provider = LiveMultiplexerSessionSpaceProvider(
            runner: RecordingRunner(),
            adapters: [
                ProviderAdapter(kind: .tmux, result: .failure(CommandFailure(command: "tmux", exitCode: 127, output: "tmux: command not found"))),
                ProviderAdapter(kind: .herdr, result: .failure(CommandFailure(command: "herdr", exitCode: 2, output: "secret raw output"))),
            ],
            preferred: .zellij)

        let snapshot = await provider.snapshot(for: model)
        XCTAssertEqual(snapshot.transport.preferredMultiplexer, .screen)
        XCTAssertEqual(snapshot.issues, ["Herdr: discovery command failed with exit 2"])
    }

    @MainActor
    func testLocalRestorationStoreRoundTripsByHost() async throws {
        let directory = try temporaryDirectory()
        let hostID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let otherHostID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let plan = SessionRestorationPlan(hostID: hostID, multiplexer: .tmux, multiplexerTarget: "$1", workingDirectory: "/repo", capturedAt: Date(timeIntervalSince1970: 1))
        await LocalSessionRestorationStore(directory: directory).save(plan)

        let reloaded = LocalSessionRestorationStore(directory: directory)
        let loaded = await reloaded.loadPlan(for: hostID)
        let otherLoaded = await reloaded.loadPlan(for: otherHostID)
        XCTAssertEqual(loaded, plan)
        XCTAssertNil(otherLoaded)
    }

    @MainActor
    func testLocalRestorationStoreFailsClosedForCorruptData() async throws {
        let directory = try temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("session-restoration.json"))

        let store = LocalSessionRestorationStore(directory: directory)
        let loaded = await store.loadPlan(for: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!)
        XCTAssertNil(loaded)
    }

    @MainActor
    func testLocalRestorationStoreBoundsPlansByNewestCapture() async throws {
        let directory = try temporaryDirectory()
        let store = LocalSessionRestorationStore(directory: directory, maxPlans: 2)
        let old = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let middle = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let newest = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        await store.save(SessionRestorationPlan(hostID: old, workingDirectory: "/old", capturedAt: Date(timeIntervalSince1970: 1)))
        await store.save(SessionRestorationPlan(hostID: middle, workingDirectory: "/middle", capturedAt: Date(timeIntervalSince1970: 2)))
        await store.save(SessionRestorationPlan(hostID: newest, workingDirectory: "/new", capturedAt: Date(timeIntervalSince1970: 3)))

        let reloaded = LocalSessionRestorationStore(directory: directory, maxPlans: 2)
        let oldPlan = await reloaded.loadPlan(for: old)
        let middlePlan = await reloaded.loadPlan(for: middle)
        let newestPlan = await reloaded.loadPlan(for: newest)
        XCTAssertNil(oldPlan)
        XCTAssertEqual(middlePlan?.workingDirectory, "/middle")
        XCTAssertEqual(newestPlan?.workingDirectory, "/new")
    }

    func testRecorderTruthfullyRecordsAttachCreateAndBareShellPlans() {
        let hostID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let recorder = SessionRestorationRecorder()
        let capturedAt = Date(timeIntervalSince1970: 10)
        let session = RemoteSession(id: "$2", name: "api", kind: .zellij, isAttached: false, isAlive: true, windowCount: 1, workingDirectory: "/work")

        let attach = recorder.planForAttach(hostID: hostID, session: session, capturedAt: capturedAt)
        XCTAssertEqual(attach?.hostID, hostID)
        XCTAssertEqual(attach?.multiplexer, .zellij)
        XCTAssertEqual(attach?.multiplexerTarget, "$2")
        XCTAssertEqual(attach?.workingDirectory, "/work")

        let herdr = RemoteSession(
            id: "w3:p9",
            name: "agent",
            kind: .herdr,
            terminalID: "term_65909b7e020c13",
            workingDirectory: "/work")
        let herdrAttach = recorder.planForAttach(
            hostID: hostID,
            session: herdr,
            capturedAt: capturedAt)
        XCTAssertEqual(herdrAttach?.multiplexerTarget, "w3:p9")
        XCTAssertEqual(herdrAttach?.multiplexerAttachmentTarget, "term_65909b7e020c13")

        let create = recorder.planForCreate(hostID: hostID, kind: .screen, name: "created", capturedAt: capturedAt)
        XCTAssertEqual(create?.multiplexer, .screen)
        XCTAssertEqual(create?.multiplexerTarget, "created")
        XCTAssertNil(create?.workingDirectory)

        let bareShell = recorder.bareShellPlanIfAppropriate(hostID: hostID, remoteDirectory: "/latest", existingPlan: create, capturedAt: capturedAt)
        XCTAssertNil(bareShell)
        let replacement = recorder.bareShellPlanIfAppropriate(hostID: hostID, remoteDirectory: "/latest", existingPlan: nil, capturedAt: capturedAt)
        XCTAssertNil(replacement?.multiplexer)
        XCTAssertNil(replacement?.multiplexerTarget)
        XCTAssertEqual(replacement?.workingDirectory, "/latest")
    }

    private func testHost() -> HostRecord {
        HostRecord(nickname: "test", hostname: "test.local", username: "dev", auth: .agentForwarding)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private enum SessionActionTestError: Error {
    case failed
}

@MainActor
private final class SessionActionEventRecorder {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

@MainActor
private final class SessionActionContextBox {
    var value: SessionSpaceActionContext
    init(_ value: SessionSpaceActionContext) { self.value = value }
}

private actor SessionActionGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        started = true
        let waitingForStart = startWaiters
        startWaiters.removeAll()
        waitingForStart.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

@MainActor
private final class RecordingSessionSpaceExecutor: SessionSpaceCommandExecuting {
    let events: SessionActionEventRecorder
    let error: (any Error)?
    let gate: SessionActionGate?
    let acknowledgement: SessionCommandAcknowledgement

    init(
        events: SessionActionEventRecorder,
        error: (any Error)? = nil,
        gate: SessionActionGate? = nil,
        acknowledgement: SessionCommandAcknowledgement = SessionCommandAcknowledgement()
    ) {
        self.events = events
        self.error = error
        self.gate = gate
        self.acknowledgement = acknowledgement
    }

    func executeSessionCommand(_ command: MultiplexerCommand) async throws -> SessionCommandAcknowledgement {
        events.append("execute")
        if let gate { await gate.suspend() }
        if let error { throw error }
        return acknowledgement
    }
}

@MainActor
private final class RecordingSessionRestorationStore: SessionRestorationStoring {
    let events: SessionActionEventRecorder
    var plans: [HostID: SessionRestorationPlan]
    private(set) var savedPlans: [SessionRestorationPlan] = []
    private(set) var clearedHostIDs: [HostID] = []
    let mutationGate: SessionActionGate?

    init(
        events: SessionActionEventRecorder,
        plans: [HostID: SessionRestorationPlan] = [:],
        mutationGate: SessionActionGate? = nil
    ) {
        self.events = events
        self.plans = plans
        self.mutationGate = mutationGate
    }

    func loadPlan(for hostID: HostID) async -> SessionRestorationPlan? {
        events.append("load")
        return plans[hostID]
    }

    func apply(
        _ mutation: SessionRestorationMutation,
        expectedHostID: HostID,
        ifCurrent: @escaping @MainActor () -> Bool
    ) async -> Bool {
        if let mutationGate { await mutationGate.suspend() }
        guard ifCurrent() else { return false }
        switch mutation {
        case .save(let plan):
            guard plan.hostID == expectedHostID else { return false }
            events.append("save")
            savedPlans.append(plan)
            plans[plan.hostID] = plan
        case .clearMatching(let kind, let target):
            events.append("load")
            if let plan = plans[expectedHostID],
               plan.multiplexer == kind,
               plan.multiplexerTarget == target {
                events.append("clear")
                clearedHostIDs.append(expectedHostID)
                plans.removeValue(forKey: expectedHostID)
            }
        }
        return true
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}

private actor RecordingRunner: CommandRunner {
    func run(_ command: String) async throws -> String { "" }
}

private struct ProviderAdapter: MultiplexerAdapter {
    let kind: MultiplexerKind
    let result: Result<[RemoteSession], any Error>

    func discoverSessions(runner: any CommandRunner) async throws -> [RemoteSession] { try result.get() }
    func attach(_ session: RemoteSession) -> String { "attach" }
    func create(name: String, directory: String?) -> String { "create" }
    func createDetached(name: String, directory: String?) -> String { "create detached" }
    func listWindows(session: RemoteSession, runner: any CommandRunner) async throws -> [RemoteWindow] { [] }
    func focus(window: RemoteWindow) -> String { "focus" }
    func kill(_ session: RemoteSession) -> String { "kill" }
    func rename(_ session: RemoteSession, to newName: String) -> String { "rename" }
}
