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

/// The SSH implementation of ``RemoteTransport``: an authenticated connection plus a session
/// channel with a PTY and an interactive shell.
///
/// Concurrency shape: the type is a `final class` whose stored properties are all immutable, so it
/// is `Sendable` by construction. Everything mutable lives in the private `Session` actor. NIO
/// objects are reached either through thread-safe `Channel` entry points (`writeAndFlush`,
/// `triggerUserOutboundEvent`) or inside event-loop closures, never by sharing non-`Sendable`
/// handlers across concurrency domains.
public final class SSHTransport: RemoteTransport {
    /// Connection state updates. Buffered so a slow observer cannot stall the event loop.
    public let state: AsyncStream<ConnectionState>

    /// Terminal output, including anything the peer sends as `stderr`.
    public let output: AsyncStream<Data>

    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    private let outputContinuation: AsyncStream<Data>.Continuation

    /// Number of output chunks dropped because the consumer fell behind.
    ///
    /// Terminal output is lossy under back-pressure by design: blocking the event loop to wait for
    /// a UI that is not draining would stall the whole connection, keepalives included. Callers can
    /// surface this count so the loss is visible rather than silent.
    private let droppedChunks = NIOLockedValueBox(0)

    private let secretResolver: any SSHSecretResolver
    private let hostKeyVerification: @Sendable (String) -> HostKeyVerdict
    private let providedGroup: (any EventLoopGroup)?
    private let session = Session()

    /// Largest single write accepted by ``write(_:)``. Keystrokes and pastes are far below this;
    /// anything above it is a bug, or an attempt to use the PTY for file transfer.
    public static let maximumWriteSize = 1 << 20

    /// - Parameters:
    ///   - secretResolver: Resolves the keychain references inside `AuthMethod`.
    ///   - hostKeyVerification: Consulted with the offered host key's `SHA256:` fingerprint.
    ///   - outputBufferCount: How many output chunks to buffer before dropping the oldest.
    ///   - eventLoopGroup: Group to run on. When `nil`, ``connect(configuration:)`` creates and
    ///     owns a single-threaded group that ``disconnect()`` shuts down.
    public init(
        secretResolver: any SSHSecretResolver,
        hostKeyVerification: @escaping @Sendable (String) -> HostKeyVerdict,
        outputBufferCount: Int = 512,
        eventLoopGroup: (any EventLoopGroup)? = nil
    ) {
        self.secretResolver = secretResolver
        self.hostKeyVerification = hostKeyVerification
        self.providedGroup = eventLoopGroup

        var stateContinuation: AsyncStream<ConnectionState>.Continuation!
        self.state = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { stateContinuation = $0 }
        self.stateContinuation = stateContinuation

        var outputContinuation: AsyncStream<Data>.Continuation!
        self.output = AsyncStream(bufferingPolicy: .bufferingNewest(max(1, outputBufferCount))) {
            outputContinuation = $0
        }
        self.outputContinuation = outputContinuation
    }

    /// Output chunks discarded because the consumer of ``output`` fell behind.
    public var droppedOutputChunkCount: Int {
        self.droppedChunks.withLockedValue { $0 }
    }

    /// The live connection, for callers that want to multiplex more channels over it.
    ///
    /// ``PortForwarder`` and ``SSHCommandRunner`` are built on this rather than on a second TCP
    /// connection, which is the whole point of having an SSH transport.
    public var connection: SSHConnection? {
        get async { await self.session.connection }
    }

    /// All mutable connection state, isolated in an actor.
    private actor Session {
        var connection: SSHConnection?
        var channel: Channel?
        var keepalive: NIOLoopBoundBox<RepeatedTask?>?
        var size: PTYSize = .default

        func adopt(connection: SSHConnection, channel: Channel, size: PTYSize) {
            self.connection = connection
            self.channel = channel
            self.size = size
        }

        func adopt(keepalive: NIOLoopBoundBox<RepeatedTask?>?) {
            self.keepalive = keepalive
        }

        func record(size: PTYSize) {
            self.size = size
        }

        /// Hand back and clear everything, so teardown runs exactly once.
        func take() -> (
            connection: SSHConnection?, channel: Channel?, keepalive: NIOLoopBoundBox<RepeatedTask?>?
        ) {
            defer {
                self.connection = nil
                self.channel = nil
                self.keepalive = nil
            }
            return (self.connection, self.channel, self.keepalive)
        }
    }
}

// MARK: - RemoteTransport

extension SSHTransport {
    public func connect(configuration: ConnectionConfiguration) async throws {
        guard await self.session.channel == nil else {
            throw TransportError.protocolViolation(detail: "this transport is already connected")
        }

        self.stateContinuation.yield(.resolving)

        do {
            let credentials = try await self.secretResolver.resolveCredentials(for: configuration.auth)

            self.stateContinuation.yield(.connecting)

            let group = self.providedGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let ownsGroup = self.providedGroup == nil

            self.stateContinuation.yield(.authenticating)

            let connection: SSHConnection
            if configuration.jumpHosts.isEmpty {
                connection = try await SSHConnection.connectDirectly(
                    configuration: configuration,
                    credentials: credentials,
                    hostKeyValidator: HostKeyValidator(verify: self.hostKeyVerification),
                    group: group,
                    ownsGroup: ownsGroup
                )
            } else {
                connection = try await JumpHostChain.connect(
                    configuration: configuration,
                    finalCredentials: credentials,
                    secretResolver: self.secretResolver,
                    hostKeyVerification: self.hostKeyVerification,
                    group: group,
                    ownsGroup: ownsGroup
                )
            }

            let channel: Channel
            do {
                channel = try await self.openShell(on: connection, configuration: configuration)
            } catch {
                await connection.close()
                throw error
            }

            await self.session.adopt(
                connection: connection,
                channel: channel,
                size: configuration.initialSize
            )

            if let interval = configuration.keepaliveInterval {
                await self.session.adopt(
                    keepalive: Self.startKeepalive(on: connection, interval: interval))
            }

            self.stateContinuation.yield(.connected(.ssh))
        } catch let error as TransportError {
            self.stateContinuation.yield(.failed(error))
            throw error
        } catch {
            let wrapped = TransportError.connectionFailed(String(describing: error))
            self.stateContinuation.yield(.failed(wrapped))
            throw wrapped
        }
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        guard data.count <= Self.maximumWriteSize else {
            throw TransportError.protocolViolation(
                detail: "write of \(data.count) bytes exceeds the \(Self.maximumWriteSize) byte limit")
        }
        guard let channel = await self.session.channel, channel.isActive else {
            throw TransportError.notConnected
        }

        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        do {
            try await channel.writeAndFlush(buffer).get()
        } catch {
            throw TransportError.channelClosed(reason: String(describing: error))
        }
    }

    public func resize(columns: Int, rows: Int) async throws {
        guard let channel = await self.session.channel, channel.isActive else {
            throw TransportError.notConnected
        }
        let size = PTYSize(columns: columns, rows: rows)
        await self.session.record(size: size)

        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: size.columns,
            terminalRowHeight: size.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        // A window change never wants a reply, so this promise reports only whether the message
        // reached the wire.
        do {
            let promise = channel.eventLoop.makePromise(of: Void.self)
            channel.triggerUserOutboundEvent(request, promise: promise)
            try await promise.futureResult.get()
        } catch {
            throw TransportError.channelClosed(reason: String(describing: error))
        }
    }

    public func disconnect() async {
        let (connection, channel, keepalive) = await self.session.take()

        if let keepalive {
            let loop = keepalive.eventLoop
            try? await loop.submit {
                keepalive.value?.cancel()
                keepalive.value = nil
            }.get()
        }

        if let channel {
            try? await channel.close().get()
        }
        await connection?.close()

        self.stateContinuation.yield(.disconnected(reason: nil))
    }
}

// MARK: - Session channel setup

extension SSHTransport {
    /// Open a session channel, request a PTY of the configured type and size, request any
    /// environment variables, then start a shell.
    private func openShell(
        on connection: SSHConnection,
        configuration: ConnectionConfiguration
    ) async throws -> Channel {
        let outputContinuation = self.outputContinuation
        let stateContinuation = self.stateContinuation
        let droppedChunks = self.droppedChunks

        let channel = try await connection.openChannel(type: .session) { child in
            child.eventLoop.makeCompletedFuture {
                let sync = child.pipeline.syncOperations
                try sync.addHandler(SSHDataWrapperHandler())
                try sync.addHandler(ChannelReplyTracker())
                try sync.addHandler(
                    TerminalOutputHandler(
                        emit: { data in
                            switch outputContinuation.yield(data) {
                            case .dropped:
                                droppedChunks.withLockedValue { $0 += 1 }
                            default:
                                break
                            }
                        },
                        finished: { reason in
                            stateContinuation.yield(.disconnected(reason: reason))
                        }
                    )
                )
            }
        }

        try await Self.request(
            SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: configuration.terminalType,
                terminalCharacterWidth: configuration.initialSize.columns,
                terminalRowHeight: configuration.initialSize.rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            ),
            on: channel,
            describedAs: "pseudo-terminal allocation"
        )

        // Environment requests are advisory: OpenSSH's default `AcceptEnv` rejects almost
        // everything, and a refused variable must not abort an otherwise good session.
        for (name, value) in configuration.environment.sorted(by: { $0.key < $1.key }) {
            try? await Self.request(
                SSHChannelRequestEvent.EnvironmentRequest(wantReply: true, name: name, value: value),
                on: channel,
                describedAs: "environment variable \(name)"
            )
        }

        try await Self.request(
            SSHChannelRequestEvent.ShellRequest(wantReply: true),
            on: channel,
            describedAs: "shell invocation"
        )

        return channel
    }

    /// Send a channel request that wants a reply, and wait for the peer's success or failure.
    ///
    /// ``ChannelReplyTracker`` repurposes the outbound-event promise so it completes on the reply
    /// rather than on the write, which is the only way to observe `SSH_MSG_CHANNEL_FAILURE`.
    static func request(
        _ event: some Sendable,
        on channel: Channel,
        describedAs description: String
    ) async throws {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.triggerUserOutboundEvent(event, promise: promise)
        do {
            try await promise.futureResult.get()
        } catch let error as TransportError {
            throw error
        } catch {
            throw TransportError.ptyRequestFailed(
                reason: "\(description) failed: \(String(describing: error))")
        }
    }
}

// MARK: - Keepalive

extension SSHTransport {
    /// Start a periodic liveness probe on the SSH transport channel.
    ///
    /// The probe is an unsolicited `cancel-tcpip-forward` global request for a port we never
    /// forwarded. A healthy peer answers `SSH_MSG_REQUEST_FAILURE`, which is itself a positive
    /// liveness signal; this is the same trick OpenSSH's `keepalive@openssh.com` uses. It is also
    /// the only keepalive expressible through NIOSSH's public API, because
    /// `sendGlobalRequestMessage` is internal to that library.
    private static func startKeepalive(
        on connection: SSHConnection,
        interval: Duration
    ) -> NIOLoopBoundBox<RepeatedTask?> {
        let channel = connection.channel
        let loop = channel.eventLoop
        // `NIOLoopBoundBox.init` may only be called on the loop; `makeEmptyBox` is the sanctioned
        // way to create one from outside, because writing `nil` cannot smuggle a value across.
        let box = NIOLoopBoundBox.makeEmptyBox(valueType: RepeatedTask.self, eventLoop: loop)
        let amount = interval.asTimeAmount

        loop.execute {
            let task = loop.scheduleRepeatedTask(initialDelay: amount, delay: amount) { _ in
                guard channel.isActive,
                    let handler = try? channel.pipeline.syncOperations.handler(
                        type: NIOSSHHandler.self)
                else {
                    box.value?.cancel()
                    box.value = nil
                    return
                }

                let promise = loop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
                handler.sendTCPForwardingRequest(.cancel(host: "", port: 0), promise: promise)
                promise.futureResult.whenComplete { _ in
                    // Either answer proves liveness. A conforming server replies
                    // SSH_MSG_REQUEST_FAILURE, which NIOSSH surfaces as a failed promise, and
                    // `NIOSSHError.globalRequestRefused` is internal to that library so the case
                    // cannot be named here anyway. What matters is that the probe forced a real
                    // write: if the link is dead, the write errors and NIO closes the channel,
                    // which drives the state stream to `.disconnected` on its own.
                }
            }
            box.value = task
        }

        return box
    }
}

// MARK: - Channel handlers

/// Completes the promises of reply-wanting channel requests when the peer answers.
///
/// NIOSSH delivers `SSH_MSG_CHANNEL_SUCCESS`/`FAILURE` as inbound user events with no correlation
/// id, so replies are matched to requests in FIFO order, which is what the protocol guarantees.
final class ChannelReplyTracker: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private struct Pending {
        var promise: EventLoopPromise<Void>
        var description: String
    }

    private var pending: [Pending] = []

    func triggerUserOutboundEvent(
        context: ChannelHandlerContext,
        event: Any,
        promise: EventLoopPromise<Void>?
    ) {
        guard let promise, let description = Self.replyWanted(event) else {
            context.triggerUserOutboundEvent(event, promise: promise)
            return
        }

        self.pending.append(Pending(promise: promise, description: description))

        // Forward with a fresh promise: a write failure must also fail the caller's promise,
        // otherwise a dead channel leaves the request awaiting a reply that never arrives.
        // `NIOLoopBound` carries `self` into the callback: channel handlers are not `Sendable`,
        // but the callback provably runs on this same event loop, which is what it asserts.
        let writePromise = context.eventLoop.makePromise(of: Void.self)
        let target = promise.futureResult
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        writePromise.futureResult.whenFailure { error in
            bound.value.failPending(identifiedBy: target, with: error)
        }
        context.triggerUserOutboundEvent(event, promise: writePromise)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            if !self.pending.isEmpty {
                self.pending.removeFirst().promise.succeed(())
            }
        } else if event is ChannelFailureEvent {
            if !self.pending.isEmpty {
                let entry = self.pending.removeFirst()
                entry.promise.fail(
                    TransportError.ptyRequestFailed(reason: "the host refused \(entry.description)"))
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        let outstanding = self.pending
        self.pending = []
        for entry in outstanding {
            entry.promise.fail(
                TransportError.channelClosed(
                    reason: "the channel closed while awaiting \(entry.description)"))
        }
        context.fireChannelInactive()
    }

    private func failPending(identifiedBy future: EventLoopFuture<Void>, with error: any Error) {
        guard let index = self.pending.firstIndex(where: { $0.promise.futureResult === future })
        else { return }
        let entry = self.pending.remove(at: index)
        entry.promise.fail(TransportError.channelClosed(reason: String(describing: error)))
    }

    /// The channel requests we send with `wantReply: true`, and how to describe them in errors.
    private static func replyWanted(_ event: Any) -> String? {
        switch event {
        case let request as SSHChannelRequestEvent.PseudoTerminalRequest:
            return request.wantReply ? "a pseudo-terminal (TERM=\(request.term))" : nil
        case let request as SSHChannelRequestEvent.ShellRequest:
            return request.wantReply ? "a shell" : nil
        case let request as SSHChannelRequestEvent.ExecRequest:
            return request.wantReply ? "exec of \(request.command)" : nil
        case let request as SSHChannelRequestEvent.EnvironmentRequest:
            return request.wantReply ? "environment variable \(request.name)" : nil
        case let request as SSHChannelRequestEvent.SubsystemRequest:
            return request.wantReply ? "subsystem \(request.subsystem)" : nil
        default:
            return nil
        }
    }
}

/// Forwards terminal bytes into the transport's `output` stream and reports termination.
final class TerminalOutputHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let emit: @Sendable (Data) -> Void
    private let finished: @Sendable (String?) -> Void
    private var exitStatus: Int?
    private var failure: String?
    private var reported = false

    init(emit: @escaping @Sendable (Data) -> Void, finished: @escaping @Sendable (String?) -> Void) {
        self.emit = emit
        self.finished = finished
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        if buffer.readableBytes > 0 {
            self.emit(Data(buffer.readableBytesView))
        }
        context.fireChannelRead(data)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let stderr as SSHDataWrapperHandler.StandardErrorData:
            // A PTY session normally merges the two streams, but honour a server that separates
            // them rather than silently discarding the bytes.
            if stderr.buffer.readableBytes > 0 {
                self.emit(Data(stderr.buffer.readableBytesView))
            }
        case let status as SSHChannelRequestEvent.ExitStatus:
            self.exitStatus = status.exitStatus
        case let signal as SSHChannelRequestEvent.ExitSignal:
            self.failure = "the remote shell was killed by SIG\(signal.signalName)"
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if self.failure == nil { self.failure = String(describing: error) }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !self.reported {
            self.reported = true
            self.finished(self.terminationReason())
        }
        context.fireChannelInactive()
    }

    private func terminationReason() -> String? {
        if let failure { return failure }
        if let exitStatus, exitStatus != 0 {
            return "the remote shell exited with status \(exitStatus)"
        }
        return nil
    }
}
