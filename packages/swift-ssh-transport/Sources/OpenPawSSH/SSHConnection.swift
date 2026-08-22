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
import NIOSSH
import OpenPawTerminalCore

// MARK: - Credentials

/// A credential that has already been fetched out of the keychain and, for keys, parsed.
///
/// `OpenPawTerminalCore.AuthMethod` deliberately carries only ``KeychainReference`` values so
/// that persisted configuration can never contain secret material. This type is the short-lived
/// in-memory counterpart, produced immediately before a handshake and discarded after it.
public enum SSHCredential: Sendable {
    case password(String)
    case privateKey(NIOSSHPrivateKey)
}

/// Resolves a ``KeychainReference`` into the secret bytes it points at.
///
/// ``KeychainStore`` is the production implementation; tests supply an in-memory one.
public protocol SSHSecretResolver: Sendable {
    func secret(for reference: KeychainReference) async throws -> Data
}

extension SSHSecretResolver {
    /// Turn an ``AuthMethod`` into the ordered list of credentials to offer the server.
    ///
    /// Private keys are parsed here rather than during the handshake so that a malformed key
    /// surfaces as ``TransportError/invalidPrivateKey(_:)`` before any network traffic happens.
    public func resolveCredentials(for method: AuthMethod) async throws -> [SSHCredential] {
        switch method {
        case .password(let reference):
            let bytes = try await self.secret(for: reference)
            guard let password = String(data: bytes, encoding: .utf8) else {
                throw TransportError.authenticationFailed(
                    reason: "the stored password for \(reference) is not valid UTF-8")
            }
            return [.password(password)]

        case .privateKey(let reference, let passphraseRef):
            let keyBytes = try await self.secret(for: reference)
            var passphrase: String?
            if let passphraseRef {
                let raw = try await self.secret(for: passphraseRef)
                guard let text = String(data: raw, encoding: .utf8) else {
                    throw TransportError.invalidPrivateKey(
                        "the stored passphrase for \(passphraseRef) is not valid UTF-8")
                }
                passphrase = text
            }
            let key = try PrivateKeyLoader.load(data: keyBytes, passphrase: passphrase)
            return [.privateKey(key)]

        case .agentForwarding:
            // NIOSSH implements no ssh-agent client, so there is genuinely nothing to offer.
            throw TransportError.authenticationFailed(
                reason: "SSH agent forwarding is not supported by the NIOSSH transport")
        }
    }
}

// MARK: - Connection

/// An authenticated SSH connection.
///
/// This wraps the channel that carries the SSH transport (a TCP socket for a direct connection,
/// or a `direct-tcpip` child channel of the previous hop when tunnelled through a jump host) and
/// exposes the two things everything else in this module needs: the ability to open a session
/// channel and the ability to open a `direct-tcpip` channel.
///
/// ``SSHTransport`` layers a PTY and a shell on top of this; ``PortForwarder`` and
/// ``SSHCommandRunner`` reuse the same connection.
public final class SSHConnection: Sendable {
    /// The channel carrying the SSH transport for this hop.
    let channel: Channel

    /// The event loop group, when this connection created it and must therefore shut it down.
    ///
    /// A tunnelled hop borrows its predecessor's group and leaves this `nil`.
    private let ownedGroup: (any EventLoopGroup)?

    /// The previous hop in a `ProxyJump` chain, retained so closing the last connection tears
    /// down the whole chain in order.
    private let previousHop: SSHConnection?

    /// Human-readable label used in errors, e.g. `"user@host:22"`.
    public let label: String

    init(
        channel: Channel,
        ownedGroup: (any EventLoopGroup)?,
        previousHop: SSHConnection?,
        label: String
    ) {
        self.channel = channel
        self.ownedGroup = ownedGroup
        self.previousHop = previousHop
        self.label = label
    }

    /// The event loop this connection's channel runs on.
    public var eventLoop: any EventLoop { self.channel.eventLoop }

    /// The group child channels should be created on.
    var group: any EventLoopGroup { self.channel.eventLoop }

    /// Completes when the underlying channel closes.
    public var closeFuture: EventLoopFuture<Void> { self.channel.closeFuture }

    /// Whether the transport channel is still active.
    public var isActive: Bool { self.channel.isActive }

    /// Close this connection, and any jump-host hops behind it, then release an owned group.
    public func close() async {
        try? await self.channel.close().get()
        await self.previousHop?.close()
        if let ownedGroup {
            try? await ownedGroup.shutdownGracefully()
        }
    }
}

// MARK: - Opening child channels

extension SSHConnection {
    /// Open an SSH child channel of `type`, running `initializer` on it before it goes active.
    ///
    /// `NIOSSHHandler` is not `Sendable` and its methods must run on the channel's event loop,
    /// so the handler is reached through the pipeline future rather than being stored.
    func openChannel(
        type: SSHChannelType,
        initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        do {
            return try await self.openChannelFuture(type: type, initializer: initializer).get()
        } catch let error as TransportError {
            throw error
        } catch {
            throw TransportError.channelClosed(reason: String(describing: error))
        }
    }

    /// Future-based counterpart of ``openChannel(type:initializer:)``.
    ///
    /// ``PortForwarder`` needs this: it opens one SSH channel per accepted TCP connection from
    /// inside a NIO channel initializer, where hopping out to an actor per connection would add
    /// latency and reorder setup against the first inbound bytes.
    func openChannelFuture(
        type: SSHChannelType,
        initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        let transportChannel = self.channel
        guard transportChannel.isActive else {
            return transportChannel.eventLoop.makeFailedFuture(TransportError.notConnected)
        }
        return transportChannel.pipeline.handler(type: NIOSSHHandler.self)
            .flatMap { sshHandler -> EventLoopFuture<Channel> in
                let promise = transportChannel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: type) { child, actualType in
                    guard SSHConnection.matches(requested: type, actual: actualType) else {
                        return child.eventLoop.makeFailedFuture(
                            TransportError.protocolViolation(
                                detail: "peer opened a \(actualType) channel, expected \(type)"))
                    }
                    return initializer(child)
                }
                return promise.futureResult
            }
    }

    /// Compare channel types by case only: `DirectTCPIP` carries an originator address that the
    /// peer is not obliged to echo back verbatim.
    private static func matches(requested: SSHChannelType, actual: SSHChannelType) -> Bool {
        switch (requested, actual) {
        case (.session, .session): return true
        case (.directTCPIP, .directTCPIP): return true
        case (.forwardedTCPIP, .forwardedTCPIP): return true
        default: return false
        }
    }

    /// Open a `direct-tcpip` channel forwarding to `host:port` on the far side.
    ///
    /// The returned channel speaks plain `ByteBuffer`s: an ``SSHDataWrapperHandler`` is installed
    /// to translate to and from ``SSHChannelData``.
    func openDirectTCPIP(
        host: String,
        port: Int,
        originator: SocketAddress,
        initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        let type = SSHChannelType.directTCPIP(
            .init(targetHost: host, targetPort: port, originatorAddress: originator))
        return try await self.openChannel(type: type) { child in
            child.eventLoop.makeCompletedFuture {
                try child.pipeline.syncOperations.addHandler(SSHDataWrapperHandler())
            }.flatMap {
                initializer(child)
            }
        }
    }
}

// MARK: - Establishing a connection

extension SSHConnection {
    /// Dial `configuration` directly over TCP and complete user authentication.
    ///
    /// Any `ProxyJump` chain in `configuration` is ignored here; ``JumpHostChain`` is responsible
    /// for walking it and calls this only for the first hop.
    static func connectDirectly(
        configuration: ConnectionConfiguration,
        credentials: [SSHCredential],
        hostKeyValidator: HostKeyValidator,
        group: any EventLoopGroup,
        ownsGroup: Bool
    ) async throws -> SSHConnection {
        let label = "\(configuration.username)@\(configuration.host):\(configuration.port)"
        let authPromise = group.next().makePromise(of: Void.self)
        let username = configuration.username

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(configuration.connectTimeout.asTimeAmount)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try SSHConnection.installClientHandlers(
                        on: channel,
                        username: username,
                        credentials: credentials,
                        hostKeyValidator: hostKeyValidator,
                        authPromise: authPromise
                    )
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: configuration.host, port: configuration.port).get()
        } catch {
            authPromise.fail(TransportError.cancelled)
            _ = try? await authPromise.futureResult.get()
            if ownsGroup { try? await group.shutdownGracefully() }
            throw Self.mapConnectError(error, configuration: configuration)
        }

        do {
            try await Self.awaitAuthentication(
                authPromise,
                on: channel,
                timeout: configuration.connectTimeout
            )
        } catch {
            try? await channel.close().get()
            if ownsGroup { try? await group.shutdownGracefully() }
            throw error
        }

        return SSHConnection(
            channel: channel,
            ownedGroup: ownsGroup ? group : nil,
            previousHop: nil,
            label: label
        )
    }

    /// Install the SSH client handlers on an already-connected channel.
    ///
    /// Shared by the direct TCP path and by ``JumpHostChain``'s tunnelled path, which passes a
    /// `direct-tcpip` child channel here after unwrapping its ``SSHChannelData`` framing.
    static func installClientHandlers(
        on channel: Channel,
        username: String,
        credentials: [SSHCredential],
        hostKeyValidator: HostKeyValidator,
        authPromise: EventLoopPromise<Void>
    ) throws {
        let sync = channel.pipeline.syncOperations
        let handler = NIOSSHHandler(
            role: .client(
                .init(
                    userAuthDelegate: ClientAuthenticationDelegate(
                        username: username,
                        credentials: credentials
                    ),
                    serverAuthDelegate: hostKeyValidator
                )
            ),
            allocator: channel.allocator,
            inboundChildChannelInitializer: nil
        )
        try sync.addHandler(handler)
        try sync.addHandler(AuthenticationGate(promise: authPromise))
    }

    /// Wait for `UserAuthSuccessEvent`, bounded by `timeout` and by the channel closing.
    private static func awaitAuthentication(
        _ promise: EventLoopPromise<Void>,
        on channel: Channel,
        timeout: Duration
    ) async throws {
        // `NIOSSHHandler.channelInactive` does not forward the event, so `AuthenticationGate` sitting behind it
        // never hears that the socket died. Watch `closeFuture` instead: a server that accepts the TCP connection
        // and then never sends a banner would otherwise leave this await unresolved forever, which the user sees
        // as a connection stuck on "authenticating" with no error and nothing to retry.
        channel.closeFuture.whenComplete { _ in
            promise.fail(
                TransportError.authenticationFailed(
                    reason: "the connection closed before authentication completed"))
        }
        let scheduled = channel.eventLoop.scheduleTask(in: timeout.asTimeAmount) {
            promise.fail(TransportError.timeout)
            channel.close(promise: nil)
        }
        defer { scheduled.cancel() }
        do {
            try await promise.futureResult.get()
        } catch let error as TransportError {
            throw error
        } catch {
            throw TransportError.authenticationFailed(reason: String(describing: error))
        }
    }

    /// Turn a NIO connect failure into the most specific ``TransportError`` we can justify.
    private static func mapConnectError(
        _ error: any Error,
        configuration: ConnectionConfiguration
    ) -> TransportError {
        if let transport = error as? TransportError { return transport }
        if let ioError = error as? IOError {
            switch ioError.errnoCode {
            case ECONNREFUSED:
                return .connectionRefused(host: configuration.host, port: configuration.port)
            case ETIMEDOUT:
                return .timeout
            default:
                return .connectionFailed(ioError.description)
            }
        }
        if let connectionError = error as? NIOConnectionError {
            // NIOConnectionError aggregates Happy Eyeballs' per-address attempts. A DNS failure
            // with no connection attempts at all means the name never resolved; otherwise at least
            // one address was tried and the errno of those attempts is the useful signal.
            if connectionError.connectionErrors.isEmpty,
                connectionError.dnsAError != nil || connectionError.dnsAAAAError != nil
            {
                return .nameResolutionFailed(host: configuration.host)
            }
            for candidate in connectionError.connectionErrors {
                if let ioError = candidate.error as? IOError, ioError.errnoCode == ECONNREFUSED {
                    return .connectionRefused(host: configuration.host, port: configuration.port)
                }
            }
            return .connectionFailed(String(describing: error))
        }
        if case ChannelError.connectTimeout = error {
            return .timeout
        }
        return .connectionFailed(String(describing: error))
    }
}

// MARK: - Authentication plumbing

/// Offers the resolved credentials in order, filtered by what the server says it accepts.
///
/// This is a class with mutable state because it is invoked repeatedly on one event loop as the
/// server rejects offers; NIOSSH does not require the delegate to be `Sendable`.
final class ClientAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let credentials: [SSHCredential]
    private var next = 0
    private var offered: [String] = []

    init(username: String, credentials: [SSHCredential]) {
        self.username = username
        self.credentials = credentials
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        while self.next < self.credentials.count {
            let credential = self.credentials[self.next]
            self.next += 1

            switch credential {
            case .password(let password) where availableMethods.contains(.password):
                self.offered.append("password")
                nextChallengePromise.succeed(
                    .init(username: self.username, serviceName: "ssh-connection", offer: .password(.init(password: password)))
                )
                return
            case .privateKey(let key) where availableMethods.contains(.publicKey):
                self.offered.append("publickey")
                nextChallengePromise.succeed(
                    .init(username: self.username, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key)))
                )
                return
            case .password, .privateKey:
                // The server will not accept this credential's method; try the next credential.
                continue
            }
        }

        // Failing the promise is how NIOSSH is told authentication cannot proceed. The error
        // travels back out through the connection future unchanged, so this is the error the
        // caller sees for a wrong password.
        nextChallengePromise.fail(
            TransportError.authenticationFailed(reason: Self.reason(offered: self.offered, server: availableMethods))
        )
    }

    private static func reason(
        offered: [String],
        server: NIOSSHAvailableUserAuthenticationMethods
    ) -> String {
        var accepted: [String] = []
        if server.contains(.password) { accepted.append("password") }
        if server.contains(.publicKey) { accepted.append("publickey") }
        if server.contains(.hostBased) { accepted.append("hostbased") }

        if offered.isEmpty {
            return accepted.isEmpty
                ? "the server offered no usable authentication method"
                : "no configured credential matches the server's methods (\(accepted.joined(separator: ", ")))"
        }
        return "the server rejected every credential offered (tried \(offered.joined(separator: ", ")))"
    }
}

/// Succeeds a promise when user authentication completes, and fails it if the connection dies or
/// errors first.
///
/// Without this, the only signal that authentication finished would be a channel open succeeding,
/// which conflates authentication failures with channel policy rejections.
final class AuthenticationGate: ChannelInboundHandler {
    typealias InboundIn = Any

    private var promise: EventLoopPromise<Void>?
    private var firstError: (any Error)?

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            self.promise?.succeed(())
            self.promise = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if self.firstError == nil { self.firstError = error }
        if let promise = self.promise {
            self.promise = nil
            promise.fail(error)
        }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let promise = self.promise {
            self.promise = nil
            promise.fail(
                self.firstError
                    ?? TransportError.authenticationFailed(
                        reason: "the connection closed before authentication completed")
            )
        }
        context.fireChannelInactive()
    }
}

// MARK: - SSH child channel framing

/// Translates between an SSH child channel's ``SSHChannelData`` and plain `ByteBuffer`s.
///
/// `stderr` data is passed through as a distinct inbound event rather than being merged into the
/// byte stream, so callers that care (``SSHCommandRunner``) can separate the two and callers that
/// do not can ignore it.
final class SSHDataWrapperHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    /// Fired for `stderr` payloads instead of `channelRead`.
    struct StandardErrorData {
        var buffer: ByteBuffer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else {
            context.fireErrorCaught(
                TransportError.protocolViolation(detail: "SSH channel delivered a file region"))
            return
        }

        switch channelData.type {
        case .channel:
            context.fireChannelRead(self.wrapInboundOut(buffer))
        case .stdErr:
            context.fireUserInboundEventTriggered(StandardErrorData(buffer: buffer))
        default:
            context.fireErrorCaught(
                TransportError.protocolViolation(
                    detail: "SSH channel delivered unknown extended data type \(channelData.type)"))
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = self.unwrapOutboundIn(data)
        context.write(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

// MARK: - Duration bridging

extension Duration {
    /// Convert to NIO's `TimeAmount`, saturating rather than trapping on absurd values.
    var asTimeAmount: TimeAmount {
        let (seconds, attoseconds) = self.components
        let nanosFromAtto = attoseconds / 1_000_000_000
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else {
            return seconds < 0 ? .nanoseconds(.min) : .nanoseconds(.max)
        }
        let (total, addOverflow) = scaled.addingReportingOverflow(nanosFromAtto)
        guard !addOverflow else {
            return seconds < 0 ? .nanoseconds(.min) : .nanoseconds(.max)
        }
        return .nanoseconds(total)
    }
}
