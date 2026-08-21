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
        let fallback = SessionRestorationPlan(hostID: hostID, workingDirectory: "/repo", capturedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(SessionSpacePresentation(agentSessions: [], remoteSessions: [], restoration: reattach, transport: .init()).restorationItem?.provenance, .restoration(kind: .herdr, target: "hd_01"))
        XCTAssertEqual(SessionSpacePresentation(agentSessions: [], remoteSessions: [], restoration: reattach, transport: .init()).restorationItem?.primaryAction, "Reattach")
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
}
