//===----------------------------------------------------------------------===//
//
// This source file is part of the OpenPaw open source project.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import OpenPawTerminalCore
import Testing

@testable import OpenPawSSH

/// A real loopback TCP echo server, standing in for `openpaw-host` on the far side of the tunnel.
final class EchoServer: Sendable {
    let port: Int
    private let channel: Channel
    private let group: any EventLoopGroup

    private init(port: Int, channel: Channel, group: any EventLoopGroup) {
        self.port = port
        self.channel = channel
        self.group = group
    }

    static func start() async throws -> EchoServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(EchoHandler())
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let port = channel.localAddress?.port else {
            try? await channel.close().get()
            try? await group.shutdownGracefully()
            throw EchoError.noPort
        }
        return EchoServer(port: port, channel: channel, group: group)
    }

    func stop() async {
        try? await self.channel.close().get()
        try? await self.group.shutdownGracefully()
    }

    enum EchoError: Error { case noPort }

    /// Echoes bytes back, uppercased so a test can prove the response came from *here* rather than
    /// from a loopback of its own request somewhere in the tunnel.
    final class EchoHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = self.unwrapInboundIn(data)
            let text = String(decoding: buffer.readableBytesView, as: UTF8.self).uppercased()
            var out = context.channel.allocator.buffer(capacity: text.utf8.count)
            out.writeString(text)
            context.writeAndFlush(self.wrapOutboundOut(out), promise: nil)
        }
    }
}

/// A plain TCP client that sends a payload and waits for a given number of bytes back.
enum TCPProbe {
    static func roundTrip(
        port: Int,
        payload: String,
        expecting expectedBytes: Int,
        timeout: Duration = .seconds(5)
    ) async throws -> String {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let promise = group.next().makePromise(of: String.self)
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        CollectHandler(expecting: expectedBytes, promise: promise))
                }
            }

        // Every exit path must settle `promise`: NIO traps on a promise that is deallocated
        // unfulfilled, so a failed connect or write would abort the test process instead of
        // reporting an error.
        do {
            let channel = try await bootstrap.connect(host: "127.0.0.1", port: port).get()
            var buffer = channel.allocator.buffer(capacity: payload.utf8.count)
            buffer.writeString(payload)
            try await channel.writeAndFlush(buffer).get()

            let deadline = channel.eventLoop.scheduleTask(in: timeout.asTimeAmount) {
                channel.close(promise: nil)
            }
            defer { deadline.cancel() }

            let response = try await promise.futureResult.get()
            try? await channel.close().get()
            try? await group.shutdownGracefully()
            return response
        } catch {
            promise.fail(error)
            _ = try? await promise.futureResult.get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    final class CollectHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer

        private let expecting: Int
        private var promise: EventLoopPromise<String>?
        private var accumulated = [UInt8]()

        init(expecting: Int, promise: EventLoopPromise<String>) {
            self.expecting = expecting
            self.promise = promise
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            self.accumulated.append(contentsOf: self.unwrapInboundIn(data).readableBytesView)
            if self.accumulated.count >= self.expecting {
                self.complete()
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            self.fail(TransportError.channelClosed(reason: "closed before the reply was complete"))
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            self.fail(error)
            context.close(promise: nil)
        }

        private func complete() {
            guard let promise = self.promise else { return }
            self.promise = nil
            promise.succeed(String(decoding: self.accumulated, as: UTF8.self))
        }

        private func fail(_ error: any Error) {
            guard let promise = self.promise else { return }
            self.promise = nil
            promise.fail(error)
        }
    }
}

// MARK: - Tests

@Suite("PortForwarder over a real SSH connection")
struct PortForwarderTests {

    /// Bring up an echo server, an SSH server and a connected transport.
    private func makeStack() async throws -> (
        echo: EchoServer, ssh: TestSSHServer, transport: SSHTransport, connection: SSHConnection
    ) {
        let echo = try await EchoServer.start()
        let ssh = try await TestSSHServer.start(
            username: TransportFixture.username,
            password: TransportFixture.password
        )
        let transport = try TransportFixture.makeTransport(trusting: ssh.hostKeyFingerprint)
        try await transport.connect(
            configuration: try TransportFixture.configuration(port: ssh.port))
        let connection = try #require(await transport.connection)
        return (echo, ssh, transport, connection)
    }

    @Test("bytes round-trip through a forwarded loopback port")
    func bytesRoundTrip() async throws {
        let stack = try await self.makeStack()
        let forwarder = PortForwarder(connection: stack.connection)

        let localPort = try await forwarder.start(
            remoteHost: "127.0.0.1",
            remotePort: UInt16(stack.echo.port)
        )
        #expect(localPort != 0)
        #expect(await forwarder.boundPort == localPort)
        // The forwarded port must not be the echo server's own port, or the test proves nothing.
        #expect(Int(localPort) != stack.echo.port)

        let reply = try await TCPProbe.roundTrip(
            port: Int(localPort), payload: "openpaw", expecting: 7)
        #expect(reply == "OPENPAW")

        // The tunnel really was a direct-tcpip channel aimed at the echo server.
        #expect(
            await stack.ssh.observations.wait(upTo: .seconds(2)) { !$0.directTCPIPTargets.isEmpty })
        let target = try #require(stack.ssh.observations.directTCPIPTargets.first)
        #expect(target.host == "127.0.0.1")
        #expect(target.port == stack.echo.port)

        await forwarder.stop()
        await stack.transport.disconnect()
        await stack.ssh.stop()
        await stack.echo.stop()
    }

    @Test("two concurrent connections are forwarded independently")
    func twoConcurrentConnections() async throws {
        let stack = try await self.makeStack()
        let forwarder = PortForwarder(connection: stack.connection)
        let localPort = try await forwarder.start(
            remoteHost: "127.0.0.1",
            remotePort: UInt16(stack.echo.port)
        )

        // Distinct payloads of equal length: if the forwarder crossed the two SSH channels, each
        // probe would receive the other's bytes and both assertions would fail.
        async let first = TCPProbe.roundTrip(port: Int(localPort), payload: "alpha-1", expecting: 7)
        async let second = TCPProbe.roundTrip(port: Int(localPort), payload: "bravo-2", expecting: 7)

        let (a, b) = try await (first, second)
        #expect(a == "ALPHA-1")
        #expect(b == "BRAVO-2")

        #expect(await forwarder.acceptedConnectionCount >= 2)
        // Two separate direct-tcpip channels were opened, one per accepted connection.
        #expect(
            await stack.ssh.observations.wait(upTo: .seconds(2)) {
                $0.directTCPIPTargets.count >= 2
            })

        await forwarder.stop()
        await stack.transport.disconnect()
        await stack.ssh.stop()
        await stack.echo.stop()
    }

    @Test("an explicit local port is honoured, and starting twice is refused")
    func explicitPortAndDoubleStart() async throws {
        let stack = try await self.makeStack()
        let forwarder = PortForwarder(connection: stack.connection)

        // Ask for an ephemeral port first, then re-bind that exact number to prove the explicit
        // path works without hard-coding a port that might already be in use.
        let probe = PortForwarder(connection: stack.connection)
        let candidate = try await probe.start(remotePort: UInt16(stack.echo.port))
        await probe.stop()

        let bound = try await forwarder.start(
            localPort: candidate,
            remoteHost: "127.0.0.1",
            remotePort: UInt16(stack.echo.port)
        )
        #expect(bound == candidate)

        // A second start on the same forwarder is a programming error, not a silent rebind.
        await #expect(throws: TransportError.self) {
            _ = try await forwarder.start(remotePort: UInt16(stack.echo.port))
        }

        // Still functional after the rejected second start.
        let reply = try await TCPProbe.roundTrip(port: Int(bound), payload: "still-ok", expecting: 8)
        #expect(reply == "STILL-OK")

        await forwarder.stop()
        await stack.transport.disconnect()
        await stack.ssh.stop()
        await stack.echo.stop()
    }

    @Test("stopping the forwarder releases the port")
    func stopReleasesThePort() async throws {
        let stack = try await self.makeStack()
        let forwarder = PortForwarder(connection: stack.connection)
        let localPort = try await forwarder.start(remotePort: UInt16(stack.echo.port))

        #expect(try await TCPProbe.roundTrip(port: Int(localPort), payload: "before", expecting: 6) == "BEFORE")

        await forwarder.stop()
        #expect(await forwarder.boundPort == nil)

        // Nothing should answer on the port any more.
        await #expect(throws: (any Error).self) {
            _ = try await TCPProbe.roundTrip(
                port: Int(localPort), payload: "after", expecting: 5, timeout: .seconds(1))
        }

        await stack.transport.disconnect()
        await stack.ssh.stop()
        await stack.echo.stop()
    }

    @Test("forwarding to a dead remote port fails the accepted connection instead of hanging")
    func deadRemotePortFailsFast() async throws {
        let stack = try await self.makeStack()

        // Take a real port and close it, so nothing is listening on the far side.
        let doomed = try await EchoServer.start()
        let deadPort = doomed.port
        await doomed.stop()

        let forwarder = PortForwarder(connection: stack.connection)
        let localPort = try await forwarder.start(remotePort: UInt16(deadPort))

        await #expect(throws: (any Error).self) {
            _ = try await TCPProbe.roundTrip(
                port: Int(localPort), payload: "nobody-home", expecting: 11, timeout: .seconds(3))
        }

        await forwarder.stop()
        await stack.transport.disconnect()
        await stack.ssh.stop()
        await stack.echo.stop()
    }
}
