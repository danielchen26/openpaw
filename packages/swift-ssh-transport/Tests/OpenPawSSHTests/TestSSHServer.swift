//===----------------------------------------------------------------------===//
//
// This source file is part of the OpenPaw open source project.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

@testable import OpenPawSSH

/// A real, in-process NIOSSH server on an ephemeral loopback port.
///
/// This is not a mock: it performs a genuine key exchange, genuine password authentication and
/// genuine channel multiplexing, so the client under test exercises the same code paths it would
/// against OpenSSH. It provides everything the acceptance tests need:
///
/// * password authentication for one fixed username/password pair;
/// * a session channel with a PTY, a shell that echoes what it receives, and recorded
///   window-change requests;
/// * `exec` channels that return canned stdout for a given command;
/// * `direct-tcpip` channels that really connect to the requested `host:port`.
final class TestSSHServer: Sendable {
    /// The host key this server presents. Generated per instance, never a fixture.
    let hostKey: NIOSSHPrivateKey

    /// The bound loopback port.
    let port: Int

    /// Everything the server observed, for assertions. Shared with the pipeline handlers.
    let observations: Observations

    private let serverChannel: Channel
    private let group: any EventLoopGroup

    private init(
        hostKey: NIOSSHPrivateKey,
        port: Int,
        observations: Observations,
        serverChannel: Channel,
        group: any EventLoopGroup
    ) {
        self.hostKey = hostKey
        self.port = port
        self.observations = observations
        self.serverChannel = serverChannel
        self.group = group
    }

    /// The `SHA256:` fingerprint clients should pin, computed from the generated host key.
    var hostKeyFingerprint: String {
        HostKeyValidator.fingerprint(of: self.hostKey.publicKey)
    }

    // MARK: Lifecycle

    /// Start a server that accepts `username`/`password` and answers `exec` with `execResponses`.
    ///
    /// - Parameter execResponses: Maps an exact command string to the stdout it should produce.
    static func start(
        username: String,
        password: String,
        execResponses: [String: String] = [:]
    ) async throws -> TestSSHServer {
        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let observations = Observations()

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = NIOSSHHandler(
                        role: .server(
                            .init(
                                hostKeys: [hostKey],
                                userAuthDelegate: FixedPasswordDelegate(
                                    username: username,
                                    password: password
                                )
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, type in
                            TestSSHServer.configureChildChannel(
                                child,
                                type: type,
                                execResponses: execResponses,
                                observations: observations
                            )
                        }
                    )
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }

        let serverChannel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let port = serverChannel.localAddress?.port else {
            try? await serverChannel.close().get()
            try? await group.shutdownGracefully()
            throw TestServerError.noBoundPort
        }

        return TestSSHServer(
            hostKey: hostKey,
            port: port,
            observations: observations,
            serverChannel: serverChannel,
            group: group
        )
    }

    func stop() async {
        try? await self.serverChannel.close().get()
        try? await self.group.shutdownGracefully()
    }

    enum TestServerError: Error {
        case noBoundPort
        case unsupportedChannelType(String)
    }

    // MARK: Child channels

    private static func configureChildChannel(
        _ channel: Channel,
        type: SSHChannelType,
        execResponses: [String: String],
        observations: Observations
    ) -> EventLoopFuture<Void> {
        switch type {
        case .session:
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(
                    ServerSessionHandler(execResponses: execResponses, observations: observations)
                )
            }

        case .directTCPIP(let target):
            return Self.bridgeDirectTCPIP(channel, target: target, observations: observations)

        case .forwardedTCPIP:
            return channel.eventLoop.makeFailedFuture(
                TestServerError.unsupportedChannelType("forwarded-tcpip"))
        }
    }

    /// Really connect to the requested address and pipe bytes both ways.
    private static func bridgeDirectTCPIP(
        _ sshChannel: Channel,
        target: SSHChannelType.DirectTCPIP,
        observations: Observations
    ) -> EventLoopFuture<Void> {
        let host = target.targetHost
        let port = target.targetPort
        observations.recordDirectTCPIP(host: host, port: port)

        return ClientBootstrap(group: sshChannel.eventLoop)
            .connect(host: host, port: port)
            .flatMap { upstream -> EventLoopFuture<Void> in
                sshChannel.eventLoop.makeCompletedFuture {
                    // The SSH side speaks SSHChannelData; unwrap it to plain bytes first.
                    let sshSync = sshChannel.pipeline.syncOperations
                    try sshSync.addHandler(SSHDataWrapperHandler())
                    try sshSync.addHandler(ByteBridgeHandler(peer: upstream))

                    try upstream.pipeline.syncOperations.addHandler(
                        ByteBridgeHandler(peer: sshChannel))
                }
            }
            .flatMapError { error in
                // A refused upstream must reject the SSH channel, not leave it hanging.
                sshChannel.close(promise: nil)
                return sshChannel.eventLoop.makeFailedFuture(error)
            }
    }
}

// MARK: - Observations

/// Records what the server saw, so tests can assert on protocol-level effects such as a
/// window-change request actually reaching the peer.
final class Observations: Sendable {
    private struct State {
        var windowChanges: [(columns: Int, rows: Int)] = []
        var ptyRequests: [(term: String, columns: Int, rows: Int)] = []
        var execCommands: [String] = []
        var directTCPIPTargets: [(host: String, port: Int)] = []
        var shellRequests = 0
        var receivedBytes = Data()
    }

    private let state = NIOLockedValueBox(State())

    var windowChanges: [(columns: Int, rows: Int)] {
        self.state.withLockedValue { $0.windowChanges }
    }

    var ptyRequests: [(term: String, columns: Int, rows: Int)] {
        self.state.withLockedValue { $0.ptyRequests }
    }

    var execCommands: [String] {
        self.state.withLockedValue { $0.execCommands }
    }

    var directTCPIPTargets: [(host: String, port: Int)] {
        self.state.withLockedValue { $0.directTCPIPTargets }
    }

    var shellRequestCount: Int {
        self.state.withLockedValue { $0.shellRequests }
    }

    var receivedBytes: Data {
        self.state.withLockedValue { $0.receivedBytes }
    }

    func recordWindowChange(columns: Int, rows: Int) {
        self.state.withLockedValue { $0.windowChanges.append((columns, rows)) }
    }

    func recordPTY(term: String, columns: Int, rows: Int) {
        self.state.withLockedValue { $0.ptyRequests.append((term, columns, rows)) }
    }

    func recordExec(_ command: String) {
        self.state.withLockedValue { $0.execCommands.append(command) }
    }

    func recordDirectTCPIP(host: String, port: Int) {
        self.state.withLockedValue { $0.directTCPIPTargets.append((host, port)) }
    }

    func recordShellRequest() {
        self.state.withLockedValue { $0.shellRequests += 1 }
    }

    func recordReceived(_ data: Data) {
        self.state.withLockedValue { $0.receivedBytes.append(data) }
    }

    /// Poll until `predicate` holds or `timeout` elapses.
    ///
    /// Protocol effects land on the server's event loop asynchronously, so tests need a bounded
    /// wait rather than a bare assertion immediately after the client call returns.
    func wait(
        upTo timeout: Duration,
        for predicate: @Sendable (Observations) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate(self) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate(self)
    }
}

// MARK: - Server-side handlers

/// Accepts exactly one username/password pair, and only via the `password` method.
final class FixedPasswordDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password

    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard case .password(let offered) = request.request else {
            responsePromise.succeed(.failure)
            return
        }
        let ok = request.username == self.username && offered.password == self.password
        responsePromise.succeed(ok ? .success : .failure)
    }
}

/// Implements the server side of a session channel: PTY, shell echo, window changes and exec.
final class ServerSessionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let execResponses: [String: String]
    private let observations: Observations
    private var shellRunning = false

    init(execResponses: [String: String], observations: Observations) {
        self.execResponses = execResponses
        self.observations = observations
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let request as SSHChannelRequestEvent.PseudoTerminalRequest:
            self.observations.recordPTY(
                term: request.term,
                columns: request.terminalCharacterWidth,
                rows: request.terminalRowHeight
            )
            self.reply(success: true, wanted: request.wantReply, context: context)

        case let request as SSHChannelRequestEvent.ShellRequest:
            self.shellRunning = true
            self.observations.recordShellRequest()
            self.reply(success: true, wanted: request.wantReply, context: context)

        case let request as SSHChannelRequestEvent.WindowChangeRequest:
            self.observations.recordWindowChange(
                columns: request.terminalCharacterWidth,
                rows: request.terminalRowHeight
            )

        case let request as SSHChannelRequestEvent.ExecRequest:
            self.observations.recordExec(request.command)
            self.handleExec(request, context: context)

        case let request as SSHChannelRequestEvent.EnvironmentRequest:
            // Mirror OpenSSH's default AcceptEnv, which refuses arbitrary variables.
            self.reply(success: false, wanted: request.wantReply, context: context)

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data, case .channel = channelData.type else {
            return
        }
        self.observations.recordReceived(Data(buffer.readableBytesView))

        // Echo, so the client's `output` stream carries something real.
        guard self.shellRunning else { return }
        context.writeAndFlush(
            self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: nil
        )
    }

    private func handleExec(
        _ request: SSHChannelRequestEvent.ExecRequest,
        context: ChannelHandlerContext
    ) {
        guard let response = self.execResponses[request.command] else {
            self.reply(success: false, wanted: request.wantReply, context: context)
            context.close(promise: nil)
            return
        }
        self.reply(success: true, wanted: request.wantReply, context: context)

        var buffer = context.channel.allocator.buffer(capacity: response.utf8.count)
        buffer.writeString(response)
        context.writeAndFlush(
            self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: nil
        )
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExitStatus(exitStatus: 0),
            promise: nil
        )
        // Close only once the output and exit status have flushed, or the client may miss them.
        // `Channel` is Sendable while `ChannelHandlerContext` is not, so capture the channel.
        let channel = context.channel
        context.eventLoop.scheduleTask(in: .milliseconds(50)) {
            channel.close(promise: nil)
        }
    }

    private func reply(success: Bool, wanted: Bool, context: ChannelHandlerContext) {
        guard wanted else { return }
        if success {
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        } else {
            context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
        }
    }
}

/// Pipes plain bytes to a peer channel, closing it on EOF. Used for `direct-tcpip` bridging.
final class ByteBridgeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        self.peer.writeAndFlush(buffer, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.peer.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.peer.close(promise: nil)
        context.close(promise: nil)
    }
}
