import XCTest

@testable import OpenPawTerminalCore

final class MockTransportTests: XCTestCase {

    private func collectStates(_ transport: MockTransport) -> Task<[ConnectionState], Never> {
        Task {
            var collected: [ConnectionState] = []
            for await state in transport.state { collected.append(state) }
            return collected
        }
    }

    private func collectOutput(_ transport: MockTransport) -> Task<[Data], Never> {
        Task {
            var collected: [Data] = []
            for await chunk in transport.output { collected.append(chunk) }
            return collected
        }
    }

    func testFullSessionDrivesRealisticStateSequence() async throws {
        let transport = MockTransport(
            script: MockScript(
                banner: [Data("$ ".utf8)],
                responses: [MockResponse(trigger: "ls", text: "README.md\r\n$ ")],
                connectedKind: .mosh))
        let states = collectStates(transport)
        let outputs = collectOutput(transport)

        try await transport.connect(configuration: Fixtures.configuration())
        try await transport.write(Data("ls\n".utf8))
        try await transport.resize(columns: 120, rows: 40)
        await transport.simulateReconnect(attempt: 1, reason: "network changed")
        try await transport.write(Data("exit\n".utf8))
        await transport.disconnect()
        // Disconnecting twice must not emit a second terminal state.
        await transport.disconnect()

        let observedStates = await states.value
        let observedOutput = await outputs.value
        let writes = await transport.recordedWriteText()
        let resizes = await transport.recordedResizes()
        let attempts = await transport.connectAttempts()
        let configuration = await transport.lastConfiguration()

        XCTAssertEqual(
            observedStates,
            [
                .idle,
                .resolving,
                .connecting,
                .authenticating,
                .connected(.mosh),
                .reconnecting(attempt: 1, reason: "network changed"),
                .connected(.mosh),
                .disconnected(reason: nil),
            ])
        XCTAssertEqual(observedOutput, [Data("$ ".utf8), Data("README.md\r\n$ ".utf8)])
        XCTAssertEqual(writes, ["ls\n", "exit\n"])
        XCTAssertEqual(resizes, [PTYSize(columns: 120, rows: 40)])
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(configuration, Fixtures.configuration())
    }

    func testWriteAndResizeRequireAConnection() async {
        let transport = MockTransport()
        do {
            try await transport.write(Data("x".utf8))
            XCTFail("write before connect must fail")
        } catch {
            XCTAssertEqual(error as? TransportError, .notConnected)
        }
        do {
            try await transport.resize(columns: 10, rows: 10)
            XCTFail("resize before connect must fail")
        } catch {
            XCTAssertEqual(error as? TransportError, .notConnected)
        }
        let writes = await transport.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    func testInjectedConnectFailureEndsInFailedState() async throws {
        let transport = MockTransport(script: MockScript(failure: .onConnect(.timeout)))
        let states = collectStates(transport)

        do {
            try await transport.connect(configuration: Fixtures.configuration())
            XCTFail("connect must rethrow the injected failure")
        } catch {
            XCTAssertEqual(error as? TransportError, .timeout)
        }

        let observed = await states.value
        XCTAssertEqual(
            observed, [.idle, .resolving, .connecting, .authenticating, .failed(.timeout)])

        // The transport is dead: writes fail rather than silently queueing.
        do {
            try await transport.write(Data("x".utf8))
            XCTFail("write after failure must fail")
        } catch {
            XCTAssertEqual(error as? TransportError, .notConnected)
        }
    }

    func testInjectedWriteFailureIsNotRecorded() async throws {
        let transport = MockTransport(
            script: MockScript(failure: .onWrite(.channelClosed(reason: "EOF"))))
        try await transport.connect(configuration: Fixtures.configuration())
        do {
            try await transport.write(Data("ls\n".utf8))
            XCTFail("expected the injected write failure")
        } catch {
            XCTAssertEqual(error as? TransportError, .channelClosed(reason: "EOF"))
        }
        let writes = await transport.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
        await transport.disconnect()
    }

    func testInjectedResizeFailureIsNotRecorded() async throws {
        let transport = MockTransport(
            script: MockScript(failure: .onResize(.ptyRequestFailed(reason: "denied"))))
        try await transport.connect(configuration: Fixtures.configuration())
        do {
            try await transport.resize(columns: 100, rows: 30)
            XCTFail("expected the injected resize failure")
        } catch {
            XCTAssertEqual(error as? TransportError, .ptyRequestFailed(reason: "denied"))
        }
        let resizes = await transport.recordedResizes()
        XCTAssertTrue(resizes.isEmpty)
        await transport.disconnect()
    }

    func testScriptedPreviewRespondsToKnownCommands() async throws {
        let transport = MockTransport(script: .shellPreview)
        let outputs = collectOutput(transport)

        try await transport.connect(configuration: Fixtures.configuration())
        try await transport.write(Data("git status\n".utf8))
        transport.emit(Data("noise\r\n".utf8))
        await transport.disconnect()

        let chunks = await outputs.value.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks[0].hasPrefix("Last login:"))
        XCTAssertTrue(chunks[1].contains("On branch main"))
        XCTAssertEqual(chunks[2], "noise\r\n")
    }

    func testMidSessionFailureIsObservable() async throws {
        let transport = MockTransport()
        let states = collectStates(transport)

        try await transport.connect(configuration: Fixtures.configuration())
        await transport.simulateFailure(.channelClosed(reason: "host rebooted"))

        let observed = await states.value
        XCTAssertEqual(observed.last, .failed(.channelClosed(reason: "host rebooted")))
        // A failed transport refuses further traffic.
        do {
            try await transport.write(Data("x".utf8))
            XCTFail("write after failure must fail")
        } catch {
            XCTAssertEqual(error as? TransportError, .notConnected)
        }
    }
}
