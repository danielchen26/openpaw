import XCTest
import OpenPawProtocol
import OpenPawTerminalCore
@testable import OpenPawUI

@MainActor
final class ProposalExecutionCoordinatorTests: XCTestCase {
    private let hostID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let snapshotID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    func testSafeAgentMessageFocusesHerdrPaneAndSendsMessageWithOneReturn() async throws {
        let terminal = RecordingProposalTerminal()
        let executor = RecordingProposalSessionExecutor()
        let coordinator = makeCoordinator(terminal: terminal, executor: executor)
        let proposal = herdrProposal(payload: .agentMessage("continue"), risk: .safe)

        let result = await coordinator.execute(proposal, operationID: "op-1")

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(executor.commands, [.attach(herdrSession())])
        XCTAssertEqual(terminal.sentTexts, ["continue\n"])
    }

    func testSafeTerminalCommandSendsCommandWithOneReturnAfterRoute() async throws {
        let terminal = RecordingProposalTerminal()
        let executor = RecordingProposalSessionExecutor()
        let coordinator = makeCoordinator(terminal: terminal, executor: executor)
        let proposal = herdrProposal(payload: .terminalCommand("swift test"), risk: .safe)

        let result = await coordinator.execute(proposal, operationID: "op-2")

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(executor.commands, [.attach(herdrSession())])
        XCTAssertEqual(terminal.sentTexts, ["swift test\n"])
    }

    func testDestructiveTerminalCommandRoutesButDoesNotPressReturn() async throws {
        let terminal = RecordingProposalTerminal()
        let executor = RecordingProposalSessionExecutor()
        let coordinator = makeCoordinator(terminal: terminal, executor: executor)
        let proposal = herdrProposal(payload: .terminalCommand("rm -rf build"), risk: .destructive)

        let result = await coordinator.execute(proposal, operationID: "op-3")

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(executor.commands, [.attach(herdrSession())])
        XCTAssertEqual(terminal.sentTexts, ["rm -rf build"])
    }

    func testStaleGenerationBeforeDispatchSendsNothing() async throws {
        let terminal = RecordingProposalTerminal()
        let executor = RecordingProposalSessionExecutor()
        var context = liveContext()
        let coordinator = makeCoordinator(terminal: terminal, executor: executor, context: { context })
        context.connectionGeneration = 2

        let result = await coordinator.execute(herdrProposal(payload: .agentMessage("continue")), operationID: "op-4")

        XCTAssertEqual(result, .reconnectNeeded)
        XCTAssertEqual(executor.commands, [])
        XCTAssertEqual(terminal.sentTexts, [])
    }

    func testTargetTabChangeDuringRouteSendsNothing() async throws {
        let terminal = RecordingProposalTerminal()
        let executor = RecordingProposalSessionExecutor()
        var context = liveContext()
        executor.onExecute = { context.selectedTabID = "other-tab" }
        let coordinator = makeCoordinator(terminal: terminal, executor: executor, context: { context })

        let result = await coordinator.execute(herdrProposal(payload: .agentMessage("continue")), operationID: "op-5")

        XCTAssertEqual(result, .reconnectNeeded)
        XCTAssertEqual(terminal.sentTexts, [])
    }

    func testDuplicateOperationIDDispatchesOnlyOnce() async throws {
        let terminal = RecordingProposalTerminal()
        let executor = RecordingProposalSessionExecutor()
        let coordinator = makeCoordinator(terminal: terminal, executor: executor)
        let proposal = herdrProposal(payload: .agentMessage("continue"))

        _ = await coordinator.execute(proposal, operationID: "same")
        _ = await coordinator.execute(proposal, operationID: "same")

        XCTAssertEqual(executor.commands.count, 1)
        XCTAssertEqual(terminal.sentTexts, ["continue\n"])
    }

    func testConcurrentDuplicateOperationIDDispatchesOnlyOnce() async throws {
        let terminal = RecordingProposalTerminal()
        let executor = RecordingProposalSessionExecutor()
        executor.delayNanoseconds = 50_000_000
        let coordinator = makeCoordinator(terminal: terminal, executor: executor)
        let proposal = herdrProposal(payload: .agentMessage("continue"))

        async let first = coordinator.execute(proposal, operationID: "same-concurrent")
        async let second = coordinator.execute(proposal, operationID: "same-concurrent")
        _ = await (first, second)

        XCTAssertEqual(executor.commands.count, 1)
        XCTAssertEqual(terminal.sentTexts, ["continue\n"])
    }

    func testRouteFailureExposesFailedStageAndKeepsPreview() async throws {
        let terminal = RecordingProposalTerminal()
        let executor = RecordingProposalSessionExecutor()
        executor.error = TestError.boom
        let coordinator = makeCoordinator(terminal: terminal, executor: executor)

        let result = await coordinator.execute(herdrProposal(payload: .agentMessage("continue")), operationID: "op-6")

        if case .failed(let stage, let message) = result {
            XCTAssertEqual(stage, .routing)
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("expected failed routing")
        }
        XCTAssertEqual(coordinator.previewProposal?.id, "proposal")
        XCTAssertEqual(terminal.sentTexts, [])
    }

    func testDisconnectedContextReturnsReconnectNeededRatherThanDispatch() async throws {
        let terminal = RecordingProposalTerminal()
        let executor = RecordingProposalSessionExecutor()
        var context = liveContext()
        context.isConnected = false
        let coordinator = makeCoordinator(terminal: terminal, executor: executor, context: { context })

        let result = await coordinator.execute(herdrProposal(payload: .agentMessage("continue")), operationID: "op-7")

        XCTAssertEqual(result, .reconnectNeeded)
        XCTAssertEqual(executor.commands, [])
        XCTAssertEqual(terminal.sentTexts, [])
    }

    func testMissingHerdrTerminalIDFailsClosed() async throws {
        let terminal = RecordingProposalTerminal()
        let executor = RecordingProposalSessionExecutor()
        let coordinator = makeCoordinator(terminal: terminal, executor: executor)
        let target = WorkspaceContextTarget(hostID: hostID, multiplexerKind: .herdr, sessionID: "session", workspaceID: "workspace", tabID: "tab", paneID: "pane", terminalID: nil)
        let proposal = ProactiveProposal(id: "proposal", title: "Send", detail: "", source: .local, risk: .safe, score: 1, target: target, payload: .agentMessage("continue"))

        let result = await coordinator.execute(proposal, operationID: "op-8")

        if case .failed(let stage, _) = result { XCTAssertEqual(stage, .routing) } else { XCTFail("expected failure") }
        XCTAssertEqual(executor.commands, [])
        XCTAssertEqual(terminal.sentTexts, [])
    }

    func testNonHerdrExecutionRoutesWithNativeMultiplexerIdentityRatherThanAgentSessionID() async throws {
        let terminal = RecordingProposalTerminal()
        let executor = RecordingProposalSessionExecutor()
        let coordinator = makeCoordinator(terminal: terminal, executor: executor)
        let target = WorkspaceContextTarget(
            hostID: hostID,
            multiplexerKind: .tmux,
            multiplexerSessionID: "$9",
            sessionID: "session")
        let proposal = ProactiveProposal(
            id: "proposal",
            title: "Continue",
            detail: "",
            source: .agentDerived,
            risk: .safe,
            score: 1,
            target: target,
            payload: .agentMessage("continue"))

        let result = await coordinator.execute(proposal, operationID: "op-tmux")

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(executor.commands, [.attach(.target("$9", kind: .tmux))])
        XCTAssertEqual(terminal.sentTexts, ["continue\n"])
    }

    private func liveContext() -> ProposalExecutionContext {
        ProposalExecutionContext(hostID: hostID, connectionGeneration: 1, graphSnapshotID: snapshotID, selectedSessionID: "session", selectedTabID: "tab", isConnected: true)
    }

    private func herdrSession() -> RemoteSession {
        RemoteSession(id: "pane", name: "pane", kind: .herdr, terminalID: "terminal", workspaceID: "workspace", tabID: "tab")
    }

    private func herdrProposal(payload: ProactiveProposal.Payload, risk: ProactiveProposal.Risk = .safe) -> ProactiveProposal {
        let target = WorkspaceContextTarget(hostID: hostID, multiplexerKind: .herdr, sessionID: "session", workspaceID: "workspace", tabID: "tab", paneID: "pane", terminalID: "terminal")
        return ProactiveProposal(id: "proposal", title: "Send", detail: "", source: .local, risk: risk, score: 1, target: target, payload: payload)
    }

    private func makeCoordinator(
        terminal: RecordingProposalTerminal,
        executor: RecordingProposalSessionExecutor,
        context: @escaping @MainActor () -> ProposalExecutionContext? = { nil }
    ) -> ProposalExecutionCoordinator {
        let provider: @MainActor () -> ProposalExecutionContext = { context() ?? self.liveContext() }
        return ProposalExecutionCoordinator(expectedHostID: hostID, expectedGeneration: 1, expectedGraphSnapshotID: snapshotID, context: provider, executor: executor, terminal: terminal)
    }
}

@MainActor
private final class RecordingProposalSessionExecutor: SessionSpaceCommandExecuting {
    var commands: [MultiplexerCommand] = []
    var error: Error?
    var onExecute: (() -> Void)?
    var delayNanoseconds: UInt64 = 0

    func executeSessionCommand(_ command: MultiplexerCommand) async throws -> SessionCommandAcknowledgement {
        commands.append(command)
        onExecute?()
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let error { throw error }
        if case .attach(let session) = command { return SessionCommandAcknowledgement(session: session) }
        return SessionCommandAcknowledgement()
    }
}

private final class RecordingProposalTerminal: TerminalBackend, @unchecked Sendable {
    var stateStream: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
    var outputStream: AsyncStream<Data> { AsyncStream { $0.finish() } }
    private(set) var sentTexts: [String] = []
    func connect(host: HostRecord) async throws {}
    func disconnect() async {}
    func send(text: String) async throws { sentTexts.append(text) }
    func send(chord: KeyChord, applicationCursorKeys: Bool) async throws {}
    func resize(columns: Int, rows: Int) async throws {}
    func run(command: String) async throws -> String { "" }
}

private enum TestError: Error { case boom }
