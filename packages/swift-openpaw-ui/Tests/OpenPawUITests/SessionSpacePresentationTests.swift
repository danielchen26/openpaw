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

    func testStaleSnapshotHasNoNavigationCommandAlertOrStoreSideEffects() {
        let hostID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let session = RemoteSession(id: "$1", name: "work", kind: .tmux, isAttached: false, isAlive: true, windowCount: 1)
        let item = SessionSpacePresentation(agentSessions: [], remoteSessions: [session], restoration: nil).items[0]
        let snapshot = SessionSpaceSnapshot(hostID: hostID, connectionGeneration: 1, remoteSessions: [session])

        XCTAssertNil(SessionSpaceActionPolicy.validatedNavigation(for: "Attach", item: item, snapshot: snapshot, hostID: hostID, generation: 2, isConnected: true))
        XCTAssertNil(SessionSpaceActionPolicy.validatedNavigation(for: "Kill", item: item, snapshot: snapshot, hostID: UUID(), generation: 1, isConnected: true))
        XCTAssertNil(SessionSpaceActionPolicy.validatedNavigation(for: "Attach", item: item, snapshot: snapshot, hostID: hostID, generation: 1, isConnected: false))
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
        let reattach = SessionRestorationPlan(hostID: hostID, multiplexer: .herdr, multiplexerTarget: "hd_01", workingDirectory: "/repo", capturedAt: Date(timeIntervalSince1970: 0))
        let replacement = SessionRestorationPlan(hostID: hostID, multiplexer: .tmux, workingDirectory: "/repo", capturedAt: Date(timeIntervalSince1970: 0))
        let fallback = SessionRestorationPlan(hostID: hostID, workingDirectory: "/repo", capturedAt: Date(timeIntervalSince1970: 0))

        let reattachRemote = RemoteSession(id: "hd_01", name: "hd_01", kind: .herdr, isAttached: false, isAlive: true, windowCount: 1)

        XCTAssertEqual(SessionSpacePresentation(agentSessions: [], remoteSessions: [reattachRemote], restoration: reattach, transport: .init()).restorationItem?.provenance, .restoration(kind: .herdr, target: "hd_01"))
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

private actor RecordingRunner: CommandRunner {
    func run(_ command: String) async throws -> String { "" }
}

private struct ProviderAdapter: MultiplexerAdapter {
    let kind: MultiplexerKind
    let result: Result<[RemoteSession], any Error>

    func discoverSessions(runner: any CommandRunner) async throws -> [RemoteSession] { try result.get() }
    func attach(_ session: RemoteSession) -> String { "attach" }
    func create(name: String, directory: String?) -> String { "create" }
    func listWindows(session: RemoteSession, runner: any CommandRunner) async throws -> [RemoteWindow] { [] }
    func focus(window: RemoteWindow) -> String { "focus" }
    func kill(_ session: RemoteSession) -> String { "kill" }
    func rename(_ session: RemoteSession, to newName: String) -> String { "rename" }
}
