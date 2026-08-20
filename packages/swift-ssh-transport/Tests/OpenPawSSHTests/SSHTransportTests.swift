//===----------------------------------------------------------------------===//
//
// This source file is part of the OpenPaw open source project.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOConcurrencyHelpers
import OpenPawTerminalCore
import Testing

@testable import OpenPawSSH

/// An `SSHSecretResolver` backed by a dictionary, so tests can hand out secrets without a keychain.
struct InMemorySecrets: SSHSecretResolver {
    var secrets: [String: Data]

    init(_ secrets: [String: Data]) {
        self.secrets = secrets
    }

    func secret(for reference: KeychainReference) async throws -> Data {
        guard let value = self.secrets[reference.identifier] else {
            throw KeychainStubError.missing(reference.identifier)
        }
        return value
    }

    enum KeychainStubError: Error {
        case missing(String)
    }
}

/// Collect items from an `AsyncStream` in the background so a test can await specific values
/// without racing the producer.
///
/// `AsyncStream` has a single consumer, so tests must start draining *before* the action that
/// produces the values they assert on.
final class StreamRecorder<Element: Sendable>: Sendable {
    private let items = NIOLockedValueBox<[Element]>([])
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<Element>) {
        let items = self.items
        self.task = Task {
            for await element in stream {
                items.withLockedValue { $0.append(element) }
            }
        }
    }

    deinit {
        self.task.cancel()
    }

    var current: [Element] {
        self.items.withLockedValue { $0 }
    }

    /// Wait until `predicate` matches the accumulated values, or give up after `timeout`.
    @discardableResult
    func wait(
        upTo timeout: Duration = .seconds(5),
        for predicate: @Sendable ([Element]) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate(self.current) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate(self.current)
    }
}

// MARK: - Fixtures

enum TransportFixture {
    static let username = "openpaw"
    static let password = "correct-horse-battery-staple"
    static let passwordRef = "test-password"

    /// A transport that trusts exactly `fingerprint`, plus a matching configuration.
    static func makeTransport(
        trusting fingerprint: String,
        password: String = Self.password
    ) throws -> SSHTransport {
        let secrets = InMemorySecrets([Self.passwordRef: Data(password.utf8)])
        return SSHTransport(
            secretResolver: secrets,
            hostKeyVerification: { offered in
                offered == fingerprint
                    ? .trusted
                    : .changed(expected: fingerprint, actual: offered)
            }
        )
    }

    static func configuration(
        port: Int,
        columns: Int = 100,
        rows: Int = 30,
        terminalType: String = "xterm-256color",
        keepalive: Duration? = nil
    ) throws -> ConnectionConfiguration {
        ConnectionConfiguration(
            host: "127.0.0.1",
            port: port,
            username: Self.username,
            auth: .password(reference: try KeychainReference(identifier: Self.passwordRef)),
            terminalType: terminalType,
            initialSize: PTYSize(columns: columns, rows: rows),
            keepaliveInterval: keepalive,
            connectTimeout: .seconds(10)
        )
    }
}

// MARK: - Tests

@Suite("SSHTransport against a real in-process server")
struct SSHTransportTests {

    @Test("password authentication succeeds and requests the configured PTY and shell")
    func passwordAuthenticationSucceeds() async throws {
        let server = try await TestSSHServer.start(
            username: TransportFixture.username,
            password: TransportFixture.password
        )
        defer { Task { await server.stop() } }

        let transport = try TransportFixture.makeTransport(trusting: server.hostKeyFingerprint)
        let states = StreamRecorder(transport.state)

        try await transport.connect(
            configuration: try TransportFixture.configuration(
                port: server.port, columns: 120, rows: 40, terminalType: "xterm-kitty"))

        #expect(await states.wait { $0.contains(.connected(.ssh)) })

        // The PTY request really reached the server with the configured geometry and TERM.
        #expect(
            await server.observations.wait(upTo: .seconds(5)) { !$0.ptyRequests.isEmpty },
            "the server never received a PTY request")
        let pty = try #require(server.observations.ptyRequests.first)
        #expect(pty.term == "xterm-kitty")
        #expect(pty.columns == 120)
        #expect(pty.rows == 40)

        #expect(
            await server.observations.wait(upTo: .seconds(5)) { $0.shellRequestCount == 1 },
            "the server never received a shell request")

        await transport.disconnect()
    }

    @Test("output written to the shell comes back on the output stream")
    func outputArrivesOnTheStream() async throws {
        let server = try await TestSSHServer.start(
            username: TransportFixture.username,
            password: TransportFixture.password
        )
        defer { Task { await server.stop() } }

        let transport = try TransportFixture.makeTransport(trusting: server.hostKeyFingerprint)
        // Start draining before connecting: AsyncStream has one consumer and buffers only newest.
        let output = StreamRecorder(transport.output)

        try await transport.connect(
            configuration: try TransportFixture.configuration(port: server.port))

        let payload = "echo openpaw-lives\n"
        try await transport.write(Data(payload.utf8))

        // The test server echoes what the shell receives, so the exact bytes must return.
        let arrived = await output.wait(upTo: .seconds(5)) { chunks in
            let joined = chunks.reduce(into: Data()) { $0.append($1) }
            return String(decoding: joined, as: UTF8.self).contains("openpaw-lives")
        }
        #expect(arrived, "the echoed payload never arrived on the output stream")
        #expect(transport.droppedOutputChunkCount == 0)

        await transport.disconnect()
    }

    @Test("resize sends a window-change request the server observes")
    func resizeIsObservedByTheServer() async throws {
        let server = try await TestSSHServer.start(
            username: TransportFixture.username,
            password: TransportFixture.password
        )
        defer { Task { await server.stop() } }

        let transport = try TransportFixture.makeTransport(trusting: server.hostKeyFingerprint)
        try await transport.connect(
            configuration: try TransportFixture.configuration(port: server.port, columns: 80, rows: 24))

        try await transport.resize(columns: 203, rows: 61)

        #expect(
            await server.observations.wait(upTo: .seconds(5)) { !$0.windowChanges.isEmpty },
            "the server never observed a window change")
        let change = try #require(server.observations.windowChanges.last)
        #expect(change.columns == 203)
        #expect(change.rows == 61)

        await transport.disconnect()
    }

    @Test("a wrong password fails with TransportError.authenticationFailed")
    func wrongPasswordFailsAuthentication() async throws {
        let server = try await TestSSHServer.start(
            username: TransportFixture.username,
            password: TransportFixture.password
        )
        defer { Task { await server.stop() } }

        let transport = try TransportFixture.makeTransport(
            trusting: server.hostKeyFingerprint,
            password: "not-the-password"
        )
        let states = StreamRecorder(transport.state)

        await #expect(throws: TransportError.self) {
            try await transport.connect(
                configuration: try TransportFixture.configuration(port: server.port))
        }

        // Assert the *specific* error, not merely that something threw: a host-key or connection
        // failure would also throw TransportError and would mean the test proved nothing.
        do {
            let retry = try TransportFixture.makeTransport(
                trusting: server.hostKeyFingerprint,
                password: "still-not-the-password"
            )
            try await retry.connect(
                configuration: try TransportFixture.configuration(port: server.port))
            Issue.record("authentication unexpectedly succeeded with a wrong password")
        } catch let error as TransportError {
            guard case .authenticationFailed = error else {
                Issue.record("expected .authenticationFailed, got \(error)")
                return
            }
        }

        // The failure is reported on the state stream too, so the UI can react.
        #expect(
            await states.wait {
                $0.contains { state in
                    if case .failed(let error) = state, case .authenticationFailed = error {
                        return true
                    }
                    return false
                }
            })
    }

    @Test("disconnect transitions the state stream to disconnected")
    func disconnectTransitionsToDisconnected() async throws {
        let server = try await TestSSHServer.start(
            username: TransportFixture.username,
            password: TransportFixture.password
        )
        defer { Task { await server.stop() } }

        let transport = try TransportFixture.makeTransport(trusting: server.hostKeyFingerprint)
        let states = StreamRecorder(transport.state)

        try await transport.connect(
            configuration: try TransportFixture.configuration(port: server.port))
        #expect(await states.wait { $0.contains(.connected(.ssh)) })

        await transport.disconnect()

        #expect(
            await states.wait {
                $0.contains { state in
                    if case .disconnected = state { return true }
                    return false
                }
            }, "no .disconnected state was published")

        // Writing after disconnect is a programming error, and must be reported rather than
        // silently dropped.
        await #expect(throws: TransportError.notConnected) {
            try await transport.write(Data("ignored".utf8))
        }
    }

    @Test("an unknown host key is rejected before any credential is offered")
    func unknownHostKeyIsRejected() async throws {
        let server = try await TestSSHServer.start(
            username: TransportFixture.username,
            password: TransportFixture.password
        )
        defer { Task { await server.stop() } }

        let secrets = InMemorySecrets([TransportFixture.passwordRef: Data(TransportFixture.password.utf8)])
        // Nothing is pinned, so every key is unknown.
        let transport = SSHTransport(
            secretResolver: secrets,
            hostKeyVerification: { offered in .unknown(fingerprint: offered) }
        )

        do {
            try await transport.connect(
                configuration: try TransportFixture.configuration(port: server.port))
            Issue.record("connected despite an unknown host key")
        } catch let error as TransportError {
            guard case .hostKeyUnknown(let fingerprint) = error else {
                Issue.record("expected .hostKeyUnknown, got \(error)")
                return
            }
            // The reported fingerprint must be the server's actual key, so the UI can pin it.
            #expect(fingerprint == server.hostKeyFingerprint)
        }
    }

    @Test("keepalive probes keep a connection healthy rather than tearing it down")
    func keepaliveDoesNotKillTheConnection() async throws {
        let server = try await TestSSHServer.start(
            username: TransportFixture.username,
            password: TransportFixture.password
        )
        defer { Task { await server.stop() } }

        let transport = try TransportFixture.makeTransport(trusting: server.hostKeyFingerprint)
        let states = StreamRecorder(transport.state)

        // The probe is an unsolicited global request the server refuses. If a refusal were treated
        // as a dead link, this short interval would disconnect us within the sleep below.
        try await transport.connect(
            configuration: try TransportFixture.configuration(
                port: server.port, keepalive: .milliseconds(120)))
        #expect(await states.wait { $0.contains(.connected(.ssh)) })

        try await Task.sleep(for: .milliseconds(600))

        #expect(
            !states.current.contains { state in
                if case .disconnected = state { return true }
                if case .failed = state { return true }
                return false
            },
            "keepalive refusals tore down a healthy connection")

        // Still usable after several probes.
        try await transport.write(Data("still here\n".utf8))
        await transport.disconnect()
    }

    @Test("connecting to a closed port reports connection refused, not a hang")
    func closedPortIsReportedPromptly() async throws {
        // Bind and immediately release a port so we know nothing is listening on it.
        let server = try await TestSSHServer.start(
            username: TransportFixture.username,
            password: TransportFixture.password
        )
        let deadPort = server.port
        await server.stop()

        let transport = try TransportFixture.makeTransport(trusting: "SHA256:irrelevant")

        do {
            try await transport.connect(
                configuration: try TransportFixture.configuration(port: deadPort))
            Issue.record("connected to a port with no listener")
        } catch let error as TransportError {
            switch error {
            case .connectionRefused, .connectionFailed, .timeout:
                break
            default:
                Issue.record("expected a connection failure, got \(error)")
            }
        }
    }
}
