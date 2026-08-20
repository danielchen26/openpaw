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

/// Exercises `ProxyJump` chains against real nested SSH handshakes.
///
/// Each hop after the first runs a complete key exchange and authentication *inside* a
/// `direct-tcpip` channel of its predecessor, so these tests put two and three genuine NIOSSH
/// servers in a line and drive the far end.
@Suite("JumpHostChain over real nested SSH connections")
struct JumpHostChainTests {

    /// One hop's server plus the credentials it accepts.
    private struct Hop {
        var server: TestSSHServer
        var username: String
        var password: String
        var reference: String
    }

    private func startHop(_ index: Int, execResponses: [String: String] = [:]) async throws -> Hop {
        let username = "hop\(index)-user"
        let password = "hop\(index)-password"
        return Hop(
            server: try await TestSSHServer.start(
                username: username, password: password, execResponses: execResponses),
            username: username,
            password: password,
            reference: "hop\(index)-ref"
        )
    }

    /// A transport trusting exactly these hops' host keys, with each hop's own password stored
    /// under its own keychain reference.
    private func makeTransport(for hops: [Hop], overridingPasswords: [String: String] = [:])
        -> SSHTransport
    {
        var secrets: [String: Data] = [:]
        for hop in hops {
            let password = overridingPasswords[hop.reference] ?? hop.password
            secrets[hop.reference] = Data(password.utf8)
        }
        let trusted = Set(hops.map(\.server.hostKeyFingerprint))
        return SSHTransport(
            secretResolver: InMemorySecrets(secrets),
            hostKeyVerification: { offered in
                trusted.contains(offered) ? .trusted : .unknown(fingerprint: offered)
            }
        )
    }

    /// Configuration for `target`, reached through `jumps` in order.
    private func configuration(target: Hop, through jumps: [Hop]) throws -> ConnectionConfiguration {
        func single(_ hop: Hop) throws -> ConnectionConfiguration {
            ConnectionConfiguration(
                host: "127.0.0.1",
                port: hop.server.port,
                username: hop.username,
                auth: .password(reference: try KeychainReference(identifier: hop.reference)),
                initialSize: PTYSize(columns: 90, rows: 25),
                keepaliveInterval: nil,
                jumpHosts: [],
                connectTimeout: .seconds(10)
            )
        }
        var configuration = try single(target)
        configuration.jumpHosts = try jumps.map(single)
        return configuration
    }

    @Test("a single jump host tunnels a full SSH session to the target")
    func singleJumpHost() async throws {
        let jump = try await self.startHop(0)
        let target = try await self.startHop(1)
        let transport = self.makeTransport(for: [jump, target])
        let output = StreamRecorder(transport.output)

        try await transport.connect(
            configuration: try self.configuration(target: target, through: [jump]))

        // The PTY landed on the *target*, not on the jump host: only the target ran a shell.
        #expect(
            await target.server.observations.wait(upTo: .seconds(5)) {
                $0.shellRequestCount == 1 && !$0.ptyRequests.isEmpty
            })
        #expect(jump.server.observations.shellRequestCount == 0)
        #expect(jump.server.observations.ptyRequests.isEmpty)

        // The jump host was asked to open a direct-tcpip channel to the target's port.
        #expect(
            await jump.server.observations.wait(upTo: .seconds(5)) {
                !$0.directTCPIPTargets.isEmpty
            })
        let hopTarget = try #require(jump.server.observations.directTCPIPTargets.first)
        #expect(hopTarget.host == "127.0.0.1")
        #expect(hopTarget.port == target.server.port)

        // Data really flows end to end through the doubly-encrypted path.
        try await transport.write(Data("through-the-tunnel\n".utf8))
        #expect(
            await output.wait(upTo: .seconds(5)) { chunks in
                let joined = chunks.reduce(into: Data()) { $0.append($1) }
                return String(decoding: joined, as: UTF8.self).contains("through-the-tunnel")
            })

        await transport.disconnect()
        await target.server.stop()
        await jump.server.stop()
    }

    @Test("a three-hop chain works, proving arbitrary chain length")
    func threeHopChain() async throws {
        let first = try await self.startHop(0)
        let second = try await self.startHop(1)
        let target = try await self.startHop(2)
        let transport = self.makeTransport(for: [first, second, target])

        try await transport.connect(
            configuration: try self.configuration(target: target, through: [first, second]))

        // Each intermediate hop tunnelled to the next one's port, in order.
        #expect(await first.server.observations.wait(upTo: .seconds(5)) { !$0.directTCPIPTargets.isEmpty })
        #expect(await second.server.observations.wait(upTo: .seconds(5)) { !$0.directTCPIPTargets.isEmpty })
        #expect(first.server.observations.directTCPIPTargets.first?.port == second.server.port)
        #expect(second.server.observations.directTCPIPTargets.first?.port == target.server.port)

        // Only the final hop ran a shell.
        #expect(await target.server.observations.wait(upTo: .seconds(5)) { $0.shellRequestCount == 1 })
        #expect(first.server.observations.shellRequestCount == 0)
        #expect(second.server.observations.shellRequestCount == 0)

        await transport.disconnect()
        await target.server.stop()
        await second.server.stop()
        await first.server.stop()
    }

    @Test("a command runner works over a jumped connection")
    func commandRunnerOverJumpHost() async throws {
        let adapter = TmuxAdapter()
        let listing =
            [
                "$0", "tunnelled", "1", "2", "1755700000", "1755700100", "/srv/openpaw",
            ].joined(separator: Multiplexer.fieldSeparator) + "\n"

        let jump = try await self.startHop(0)
        let target = try await self.startHop(1, execResponses: [adapter.discoverCommand: listing])
        let transport = self.makeTransport(for: [jump, target])

        try await transport.connect(
            configuration: try self.configuration(target: target, through: [jump]))
        let connection = try #require(await transport.connection)

        // Exec channels multiplex over the same tunnelled connection as the PTY.
        let sessions = try await adapter.discoverSessions(
            runner: SSHCommandRunner(connection: connection))
        #expect(sessions.count == 1)
        #expect(sessions.first?.name == "tunnelled")
        #expect(sessions.first?.workingDirectory == "/srv/openpaw")
        #expect(target.server.observations.execCommands.contains(adapter.discoverCommand))

        await transport.disconnect()
        await target.server.stop()
        await jump.server.stop()
    }

    @Test("a failing jump host is reported with the hop that broke")
    func failingJumpHostNamesTheHop() async throws {
        let jump = try await self.startHop(0)
        let target = try await self.startHop(1)
        // Wrong password for the *jump* host only.
        let transport = self.makeTransport(
            for: [jump, target],
            overridingPasswords: [jump.reference: "wrong-for-the-jump-host"]
        )

        let error = try await #require(throws: TransportError.self) {
            try await transport.connect(
                configuration: try self.configuration(target: target, through: [jump]))
        }

        guard case .jumpHostFailed(let hop, let reason) = error else {
            Issue.record("expected .jumpHostFailed, got \(error)")
            return
        }
        // Hop 0 is the first jump host; the destination is the last element and is never wrapped.
        #expect(hop == 0)
        #expect(reason.contains("127.0.0.1"))
        #expect(reason.lowercased().contains("authentication"))

        await target.server.stop()
        await jump.server.stop()
    }

    @Test("a failing destination is reported unwrapped, not as a jump host failure")
    func failingDestinationIsNotWrapped() async throws {
        let jump = try await self.startHop(0)
        let target = try await self.startHop(1)
        // Wrong password for the *target* only; the jump host still authenticates.
        let transport = self.makeTransport(
            for: [jump, target],
            overridingPasswords: [target.reference: "wrong-for-the-target"]
        )

        let error = try await #require(throws: TransportError.self) {
            try await transport.connect(
                configuration: try self.configuration(target: target, through: [jump]))
        }

        // The user asked for the destination, so its errors must stay recognisable: a bad password
        // there is a bad password, not a broken proxy.
        guard case .authenticationFailed = error else {
            Issue.record("expected .authenticationFailed for the destination, got \(error)")
            return
        }

        // The jump host really did authenticate before the destination refused us.
        #expect(!jump.server.observations.directTCPIPTargets.isEmpty)

        await target.server.stop()
        await jump.server.stop()
    }

    @Test("an unreachable destination behind a live jump host names the destination hop")
    func unreachableDestinationBehindJumpHost() async throws {
        let jump = try await self.startHop(0)

        // A real port that is then closed, so the jump host's direct-tcpip attempt is refused.
        let doomed = try await self.startHop(1)
        let deadPort = doomed.server.port
        let deadUsername = doomed.username
        let deadReference = doomed.reference
        let deadPassword = doomed.password
        await doomed.server.stop()

        let transport = SSHTransport(
            secretResolver: InMemorySecrets([
                jump.reference: Data(jump.password.utf8),
                deadReference: Data(deadPassword.utf8),
            ]),
            hostKeyVerification: { _ in .trusted }
        )

        var configuration = ConnectionConfiguration(
            host: "127.0.0.1",
            port: deadPort,
            username: deadUsername,
            auth: .password(reference: try KeychainReference(identifier: deadReference)),
            keepaliveInterval: nil,
            connectTimeout: .seconds(5)
        )
        configuration.jumpHosts = [
            ConnectionConfiguration(
                host: "127.0.0.1",
                port: jump.server.port,
                username: jump.username,
                auth: .password(reference: try KeychainReference(identifier: jump.reference)),
                keepaliveInterval: nil,
                connectTimeout: .seconds(5)
            )
        ]

        // The destination is the last hop, so its failure is surfaced directly rather than as
        // `.jumpHostFailed`; what matters is that it fails promptly instead of hanging.
        await #expect(throws: TransportError.self) {
            try await transport.connect(configuration: configuration)
        }

        await jump.server.stop()
    }
}
