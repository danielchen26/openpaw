import XCTest
import OpenPawProtocol
import OpenPawTerminalCore
@testable import OpenPawUI

final class SessionSpacePresentationTests: XCTestCase {
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

    func testRestorationPolicyDistinguishesReattachFromBareShellFallback() {
        let hostID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let reattach = SessionRestorationPlan(hostID: hostID, multiplexer: .herdr, multiplexerTarget: "hd_01", workingDirectory: "/repo", capturedAt: Date(timeIntervalSince1970: 0))
        let replacement = SessionRestorationPlan(hostID: hostID, multiplexer: .tmux, workingDirectory: "/repo", capturedAt: Date(timeIntervalSince1970: 0))
        let fallback = SessionRestorationPlan(hostID: hostID, workingDirectory: "/repo", capturedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(SessionSpacePresentation(agentSessions: [], remoteSessions: [], restoration: reattach, transport: .init()).restorationItem?.provenance, .restoration(kind: .herdr, target: "hd_01"))
        XCTAssertEqual(SessionSpacePresentation(agentSessions: [], remoteSessions: [], restoration: reattach, transport: .init()).restorationItem?.primaryAction, "Reattach")
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

    private func testHost() -> HostRecord {
        HostRecord(nickname: "test", hostname: "test.local", username: "dev", auth: .agentForwarding)
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
