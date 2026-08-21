import Foundation
import OpenPawTerminalCore
import XCTest

@testable import OpenPawApp

final class SSHTerminalBackendTests: XCTestCase {
    func testRunCommandCapturesSuccessWithoutPublishingProbeOutput() async throws {
        let transport = ControlledTransport()
        let backend = makeBackend(transport)
        try await backend.connect(host: host())

        async let output = backend.run(command: "printf ok")
        let written = await transport.waitForWrite(containing: "printf ok")
        let marker = try XCTUnwrap(Self.marker(in: written))
        await transport.emitOutput("ok\n\(marker):0\nafter")
        let captured = try await output

        XCTAssertEqual(captured, "ok")
        let visible = await firstVisibleOutput(from: backend)
        XCTAssertEqual(visible, "after")
    }

    func testRunCommandCompletesWhenMarkerArrivesBeforeWaiterSuspends() async throws {
        let transport = ControlledTransport(autoRespond: { command in
            guard let marker = Self.marker(in: command) else { return nil }
            return "fast\n\(marker):0\n"
        })
        let backend = makeBackend(transport)
        try await backend.connect(host: host())

        let captured = try await backend.run(command: "printf fast")

        XCTAssertEqual(captured, "fast")
    }

    func testRunCommandThrowsCommandFailureForMissingBinary127() async throws {
        let transport = ControlledTransport()
        let backend = makeBackend(transport)
        try await backend.connect(host: host())

        async let output = backend.run(command: "missing-binary")
        let marker = try XCTUnwrap(Self.marker(in: await transport.waitForWrite(containing: "missing-binary")))
        await transport.emitOutput("nope\n\(marker):127\n")

        do {
            _ = try await output
            XCTFail("Expected CommandFailure")
        } catch let failure as CommandFailure {
            XCTAssertEqual(failure.exitCode, 127)
            XCTAssertEqual(failure.output, "nope")
        }
    }

    func testRunCommandFailsImmediatelyWhenTransportDrops() async throws {
        let transport = ControlledTransport()
        let backend = makeBackend(transport)
        try await backend.connect(host: host())

        async let output = backend.run(command: "sleep 10")
        _ = await transport.waitForWrite(containing: "sleep 10")
        await transport.emitState(.disconnected(reason: "drop"))

        do {
            _ = try await output
            XCTFail("Expected a transport failure")
        } catch {
            // Success: the important contract is immediate failure on terminal state, not timeout expiry.
        }
    }

    func testOrdinaryTerminalOutputStillPublishesWhenNoCaptureIsActive() async throws {
        let transport = ControlledTransport()
        let backend = makeBackend(transport)
        try await backend.connect(host: host())

        async let visible = firstVisibleOutput(from: backend)
        await transport.emitOutput("ordinary")

        XCTAssertEqual(await visible, "ordinary")
    }

    private func makeBackend(_ transport: ControlledTransport) -> SSHTerminalBackend {
        SSHTerminalBackend(
            makeTransport: { _ in transport },
            makeConfiguration: { $0.connectionConfiguration },
            onHostKeyProblem: { _ in })
    }

    private func host() -> HostRecord {
        HostRecord(nickname: "test", hostname: "example.invalid", username: "me", auth: .agentForwarding)
    }

    private func firstVisibleOutput(from backend: SSHTerminalBackend) async -> String {
        for await chunk in backend.outputStream {
            return String(decoding: chunk, as: UTF8.self)
        }
        return ""
    }

    private static func marker(in text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "'" }).first { $0.hasPrefix("__openpaw_") }.map(String.init)
    }
}

private actor ControlledTransport: RemoteTransport {
    private let autoRespond: (@Sendable (String) -> String?)?
    private var writes: [String] = []
    private var writeWaiters: [(String, CheckedContinuation<String, Never>)] = []
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    private let outputContinuation: AsyncStream<Data>.Continuation

    nonisolated let state: AsyncStream<ConnectionState>
    nonisolated let output: AsyncStream<Data>

    init(autoRespond: (@Sendable (String) -> String?)? = nil) {
        self.autoRespond = autoRespond
        var stateContinuation: AsyncStream<ConnectionState>.Continuation!
        self.state = AsyncStream { stateContinuation = $0 }
        self.stateContinuation = stateContinuation
        var outputContinuation: AsyncStream<Data>.Continuation!
        self.output = AsyncStream { outputContinuation = $0 }
        self.outputContinuation = outputContinuation
    }

    func connect(configuration: ConnectionConfiguration) async throws {
        stateContinuation.yield(.connected(.ssh))
    }

    func write(_ data: Data) async throws {
        let text = String(decoding: data, as: UTF8.self)
        writes.append(text)
        for (index, waiter) in writeWaiters.enumerated().reversed() where text.contains(waiter.0) {
            writeWaiters.remove(at: index)
            waiter.1.resume(returning: text)
        }
        if let response = autoRespond?(text) {
            outputContinuation.yield(Data(response.utf8))
        }
    }

    func resize(columns: Int, rows: Int) async throws {}
    func disconnect() async {}

    func emitOutput(_ text: String) {
        outputContinuation.yield(Data(text.utf8))
    }

    func emitState(_ state: ConnectionState) {
        stateContinuation.yield(state)
    }

    func waitForWrite(containing needle: String) async -> String {
        if let write = writes.first(where: { $0.contains(needle) }) { return write }
        return await withCheckedContinuation { continuation in
            writeWaiters.append((needle, continuation))
        }
    }
}
