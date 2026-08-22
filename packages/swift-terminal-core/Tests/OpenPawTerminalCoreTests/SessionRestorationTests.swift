import XCTest

@testable import OpenPawTerminalCore

final class SessionRestorationTests: XCTestCase {

    private let hostID = UUID(uuidString: "3C3C3C3C-0000-4000-8000-000000000009")!
    private let capturedAt = Date(timeIntervalSince1970: 1_755_697_800)

    private func plan(
        multiplexer: MultiplexerKind? = .tmux,
        target: String? = "agent main",
        directory: String? = "/Users/dev/openpaw",
        agentSessionID: String? = "sess_cc-openpaw"
    ) -> SessionRestorationPlan {
        SessionRestorationPlan(
            hostID: hostID,
            multiplexer: multiplexer,
            multiplexerTarget: target,
            workingDirectory: directory,
            agentSessionID: agentSessionID,
            capturedAt: capturedAt)
    }

    // MARK: commands

    func testReattachCommandsForTmuxTarget() {
        XCTAssertEqual(plan().commands(), ["tmux attach-session -t 'agent main'"])
        XCTAssertTrue(plan().isReattachable)
    }

    func testReattachCommandsForOtherMultiplexers() {
        XCTAssertEqual(
            plan(multiplexer: .zellij, target: "agent-main").commands(),
            ["zellij attach agent-main"])
        XCTAssertEqual(
            plan(multiplexer: .screen, target: "31183.agent-main").commands(),
            ["screen -x 31183.agent-main"])
        XCTAssertEqual(
            plan(multiplexer: .herdr, target: "hd_01").commands(),
            ["herdr agent attach hd_01"])
    }

    func testCreatesASessionWhenThereIsNoTarget() {
        let fresh = plan(target: nil, directory: "/srv/api rocks")
        XCTAssertFalse(fresh.isReattachable)
        XCTAssertEqual(fresh.newSessionName, "api-rocks")
        XCTAssertEqual(
            fresh.commands(),
            ["tmux new-session -A -s api-rocks -c '/srv/api rocks'"])

        let nameless = plan(target: "", directory: nil)
        XCTAssertEqual(nameless.newSessionName, "openpaw")
        XCTAssertEqual(nameless.commands(), ["tmux new-session -A -s openpaw"])
    }

    func testBareShellOnlyRestoresTheDirectory() {
        XCTAssertEqual(
            plan(multiplexer: nil, target: nil, directory: "/srv/x").commands(), ["cd /srv/x"])
        XCTAssertEqual(
            plan(multiplexer: nil, target: nil, directory: "/srv/a b").commands(),
            ["cd '/srv/a b'"])
        XCTAssertTrue(plan(multiplexer: nil, target: nil, directory: nil).commands().isEmpty)
    }

    func testPlanCodesWithSnakeCaseKeys() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(plan())
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(json.contains("\"host_id\""))
        XCTAssertTrue(json.contains("\"multiplexer_target\":\"agent main\""))
        XCTAssertTrue(json.contains("\"agent_session_id\":\"sess_cc-openpaw\""))
        XCTAssertTrue(json.contains("\"working_directory\":\"\\/Users\\/dev\\/openpaw\""))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(SessionRestorationPlan.self, from: data), plan())
    }

    // MARK: policy

    func testPolicyBoundaries() {
        let policy = RestorationPolicy()
        let subject = plan()

        // Inside the silent window, including the exact boundary.
        XCTAssertEqual(
            policy.decide(suspendedFor: 0, plan: subject, targetStillExists: true), .reattach)
        XCTAssertEqual(
            policy.decide(suspendedFor: -30, plan: subject, targetStillExists: true), .reattach)
        XCTAssertEqual(
            policy.decide(suspendedFor: 15 * 60, plan: subject, targetStillExists: true),
            .reattach)

        // One second past it, the user is asked.
        XCTAssertEqual(
            policy.decide(suspendedFor: 15 * 60 + 1, plan: subject, targetStillExists: true),
            .promptUser(reason: "suspended for 15m"))
        XCTAssertEqual(
            policy.decide(suspendedFor: 3 * 3600, plan: subject, targetStillExists: true),
            .promptUser(reason: "suspended for 3h"))
        XCTAssertEqual(
            policy.decide(suspendedFor: 12 * 3600, plan: subject, targetStillExists: true),
            .promptUser(reason: "suspended for 12h"))

        // Beyond the prompt window a fresh session is the honest default.
        XCTAssertEqual(
            policy.decide(suspendedFor: 12 * 3600 + 1, plan: subject, targetStillExists: true),
            .newSession(reason: "suspended for 12h"))
        XCTAssertEqual(
            policy.decide(suspendedFor: 3 * 86400 + 7200, plan: subject, targetStillExists: true),
            .newSession(reason: "suspended for 3d 2h"))
    }

    func testPolicyRequiresAReattachableTarget() {
        let policy = RestorationPolicy.default

        XCTAssertEqual(
            policy.decide(suspendedFor: 5, plan: nil, targetStillExists: true),
            .newSession(reason: "no previous session was captured"))
        XCTAssertEqual(
            policy.decide(
                suspendedFor: 5, plan: plan(multiplexer: nil, target: nil),
                targetStillExists: true),
            .newSession(reason: "the previous terminal was not inside a multiplexer"))
        XCTAssertEqual(
            policy.decide(suspendedFor: 5, plan: plan(), targetStillExists: false),
            .newSession(reason: "the multiplexer session agent main is gone"))
    }

    func testPolicyWindowsAreConfigurableAndCodable() throws {
        let policy = RestorationPolicy(silentReattachWindow: 60, promptWindow: 120)
        XCTAssertEqual(policy.decide(suspendedFor: 60, plan: plan(), targetStillExists: true), .reattach)
        XCTAssertEqual(
            policy.decide(suspendedFor: 90, plan: plan(), targetStillExists: true),
            .promptUser(reason: "suspended for 1m"))
        XCTAssertEqual(
            policy.decide(suspendedFor: 121, plan: plan(), targetStillExists: true),
            .newSession(reason: "suspended for 2m"))

        let data = try JSONEncoder().encode(policy)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("silent_reattach_window"))
        XCTAssertEqual(try JSONDecoder().decode(RestorationPolicy.self, from: data), policy)
    }

    func testDurationFormatting() {
        XCTAssertEqual(formatApproximateDuration(0), "0s")
        XCTAssertEqual(formatApproximateDuration(59), "59s")
        XCTAssertEqual(formatApproximateDuration(60), "1m")
        XCTAssertEqual(formatApproximateDuration(3599), "59m")
        XCTAssertEqual(formatApproximateDuration(3600), "1h")
        XCTAssertEqual(formatApproximateDuration(3660), "1h 1m")
        XCTAssertEqual(formatApproximateDuration(86400), "1d")
        XCTAssertEqual(formatApproximateDuration(86400 + 3600), "1d 1h")
        XCTAssertEqual(formatApproximateDuration(-5), "0s")
    }
}
