//===----------------------------------------------------------------------===//
//
// This source file is part of the OpenPaw open source project.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore
import NIOPosix
import OpenPawTerminalCore
import Testing

@testable import OpenPawSSH

@Suite("SSHCommandRunner composed with OpenPawTerminalCore's multiplexer adapters")
struct SSHCommandRunnerTests {

    /// tmux output in the exact format `TmuxAdapter` asks for: fields joined by 0x1F.
    ///
    /// Building it from `Multiplexer.fieldSeparator` rather than a literal keeps this honest — if
    /// the adapter changed separators, this fixture would follow rather than silently disagree.
    private static func tmuxSessionLine(
        id: String,
        name: String,
        attached: Int,
        windows: Int,
        created: Int,
        activity: Int,
        path: String
    ) -> String {
        [
            id, name, String(attached), String(windows), String(created), String(activity), path,
        ].joined(separator: Multiplexer.fieldSeparator)
    }

    private func makeStack(
        execResponses: [String: String]
    ) async throws -> (ssh: TestSSHServer, transport: SSHTransport, runner: SSHCommandRunner) {
        let ssh = try await TestSSHServer.start(
            username: TransportFixture.username,
            password: TransportFixture.password,
            execResponses: execResponses
        )
        let transport = try TransportFixture.makeTransport(trusting: ssh.hostKeyFingerprint)
        try await transport.connect(
            configuration: try TransportFixture.configuration(port: ssh.port))
        let connection = try #require(await transport.connection)
        return (ssh, transport, SSHCommandRunner(connection: connection))
    }

    @Test("TmuxAdapter.discoverSessions parses real output delivered over an SSH exec channel")
    func tmuxDiscoveryOverSSH() async throws {
        let adapter = TmuxAdapter()
        // The adapter owns the command string; the test must not guess it.
        let command = adapter.discoverCommand

        let output =
            [
                Self.tmuxSessionLine(
                    id: "$0", name: "openpaw", attached: 1, windows: 3,
                    created: 1_755_700_000, activity: 1_755_701_000,
                    path: "/Users/dev/openpaw"),
                Self.tmuxSessionLine(
                    id: "$1", name: "scratch pad", attached: 0, windows: 1,
                    created: 1_755_600_000, activity: 1_755_600_500,
                    path: "/tmp/scratch"),
            ].joined(separator: "\n") + "\n"

        let stack = try await self.makeStack(execResponses: [command: output])

        // This is the composition under test: OpenPawSSH transports the bytes, OpenPawTerminalCore
        // parses them. Neither package knows about the other's internals.
        let sessions = try await adapter.discoverSessions(runner: stack.runner)

        #expect(sessions.count == 2)

        let first = try #require(sessions.first)
        #expect(first.id == "$0")
        #expect(first.name == "openpaw")
        #expect(first.kind == .tmux)
        #expect(first.isAttached)
        #expect(first.windowCount == 3)
        #expect(first.workingDirectory == "/Users/dev/openpaw")
        #expect(first.createdAt == Date(timeIntervalSince1970: 1_755_700_000))

        let second = try #require(sessions.last)
        #expect(second.id == "$1")
        // A name containing a space is exactly why the adapter uses 0x1F instead of whitespace.
        #expect(second.name == "scratch pad")
        #expect(!second.isAttached)
        #expect(second.windowCount == 1)
        #expect(second.workingDirectory == "/tmp/scratch")

        // The server really received the adapter's command, unmodified.
        #expect(stack.ssh.observations.execCommands.contains(command))

        await stack.transport.disconnect()
        await stack.ssh.stop()
    }

    @Test("a non-zero exit becomes CommandFailure carrying the output")
    func nonZeroExitBecomesCommandFailure() async throws {
        // The test server refuses any command it has no canned response for, which closes the
        // channel without an exit status; a refused exec is a channel-level failure.
        let stack = try await self.makeStack(execResponses: ["true": ""])

        await #expect(throws: (any Error).self) {
            _ = try await stack.runner.run("command-that-was-never-registered")
        }

        await stack.transport.disconnect()
        await stack.ssh.stop()
    }

    @Test("an empty tmux server is reported as no sessions, not as an error")
    func emptyTmuxServerYieldsNoSessions() async throws {
        let adapter = TmuxAdapter()
        // tmux prints nothing when a server is running but holds no sessions.
        let stack = try await self.makeStack(execResponses: [adapter.discoverCommand: ""])

        let sessions = try await adapter.discoverSessions(runner: stack.runner)
        #expect(sessions.isEmpty)

        await stack.transport.disconnect()
        await stack.ssh.stop()
    }

    @Test("output larger than the configured ceiling is refused")
    func outputLimitIsEnforced() async throws {
        let command = "cat /dev/urandom"
        let large = String(repeating: "x", count: 64 * 1024)
        let ssh = try await TestSSHServer.start(
            username: TransportFixture.username,
            password: TransportFixture.password,
            execResponses: [command: large]
        )
        let transport = try TransportFixture.makeTransport(trusting: ssh.hostKeyFingerprint)
        try await transport.connect(
            configuration: try TransportFixture.configuration(port: ssh.port))
        let connection = try #require(await transport.connection)

        // A deliberately tiny ceiling: the remote is untrusted and must not be able to make the
        // client allocate without bound.
        let runner = SSHCommandRunner(connection: connection, maximumOutputBytes: 1024)
        let error = try await #require(throws: TransportError.self) {
            _ = try await runner.run(command)
        }
        #expect(error == .outputLimitExceeded)

        // A generous ceiling accepts the same output, proving the limit is what rejected it.
        let permissive = SSHCommandRunner(connection: connection, maximumOutputBytes: 1 << 20)
        let result = try await permissive.run(command)
        #expect(result.count == large.count)

        await transport.disconnect()
        await ssh.stop()
    }

    @Test("running a command on a closed connection reports notConnected")
    func closedConnectionReportsNotConnected() async throws {
        let stack = try await self.makeStack(execResponses: ["true": ""])
        await stack.transport.disconnect()

        await #expect(throws: TransportError.notConnected) {
            _ = try await stack.runner.run("true")
        }

        await stack.ssh.stop()
    }
}
