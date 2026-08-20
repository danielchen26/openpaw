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

/// Forwards a local loopback port over the SSH connection to a remote `host:port`.
///
/// This is the transport under everything the phone does with `openpaw-host`: the structured HTTP
/// API and the browser preview proxy both reach the daemon through a forwarded loopback port rather
/// than any listening socket on the host. That is why the daemon can bind loopback only.
///
/// Each accepted TCP connection gets its own `direct-tcpip` SSH channel, opened from inside the
/// channel initializer so that setup cannot race the first inbound bytes. Everything runs on the
/// SSH connection's event loop, which keeps many concurrent connections cheap and removes
/// cross-loop hazards in the glue.
public actor PortForwarder {
    private let connection: SSHConnection

    /// Number of currently open forwarded connections, shared with the pipeline handlers.
    private let liveConnections = NIOLockedValueBox(0)

    /// Total connections accepted since ``start(localPort:remoteHost:remotePort:)``.
    private let acceptedConnections = NIOLockedValueBox(0)

    private var listener: Channel?
    private var target: (host: String, port: UInt16)?

    public init(connection: SSHConnection) {
        self.connection = connection
    }

    /// The port currently bound on `127.0.0.1`, if running.
    public var boundPort: UInt16? {
        self.listener?.localAddress?.port.map(UInt16.init)
    }

    /// Forwarded connections currently open.
    public var activeConnectionCount: Int {
        self.liveConnections.withLockedValue { $0 }
    }

    /// Forwarded connections accepted in total.
    public var acceptedConnectionCount: Int {
        self.acceptedConnections.withLockedValue { $0 }
    }

    /// Start listening on loopback and forwarding to `remoteHost:remotePort`.
    ///
    /// - Parameters:
    ///   - localPort: Port to bind on `127.0.0.1`. `nil` or `0` binds an ephemeral port.
    ///   - remoteHost: Host to connect to *from the far side* of the SSH connection.
    ///   - remotePort: Port on `remoteHost`.
    /// - Returns: The port actually bound, which is what callers need when they asked for `0`.
    public func start(
        localPort: UInt16? = nil,
        remoteHost: String = "127.0.0.1",
        remotePort: UInt16
    ) async throws -> UInt16 {
        guard self.listener == nil else {
            throw TransportError.protocolViolation(detail: "this forwarder is already running")
        }
        guard self.connection.isActive else {
            throw TransportError.notConnected
        }

        let connection = self.connection
        let live = self.liveConnections
        let accepted = self.acceptedConnections
        let loop = self.connection.eventLoop

        // Binding the accept loop and the child loop to the SSH connection's loop puts the inbound
        // socket, the SSH child channel and the glue on one thread. That is what makes the bridge
        // below safe without locks or loop hops on the data path.
        let bootstrap = ServerBootstrap(group: loop)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            // A forwarded stream may be half-closed by either side; HTTP/1.0 style responses and
            // the preview proxy both depend on EOF propagating rather than a full reset.
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            // Hold inbound data until the SSH channel exists, then release it. Without this the
            // first request bytes can arrive before there is anywhere to send them.
            .childChannelOption(.autoRead, value: false)
            .childChannelInitializer { inbound in
                PortForwarder.bridge(
                    inbound: inbound,
                    over: connection,
                    remoteHost: remoteHost,
                    remotePort: remotePort,
                    live: live,
                    accepted: accepted
                )
            }

        let channel: Channel
        do {
            channel = try await bootstrap.bind(
                host: "127.0.0.1",
                port: Int(localPort ?? 0)
            ).get()
        } catch {
            throw TransportError.connectionFailed(
                "could not bind 127.0.0.1:\(localPort ?? 0): \(String(describing: error))")
        }

        guard let bound = channel.localAddress?.port else {
            try? await channel.close().get()
            throw TransportError.connectionFailed("the forwarder bound no port")
        }

        self.listener = channel
        self.target = (remoteHost, remotePort)
        return UInt16(bound)
    }

    /// Stop listening. Connections already established are closed with the listener.
    public func stop() async {
        guard let listener = self.listener else { return }
        self.listener = nil
        self.target = nil
        try? await listener.close().get()
    }

    /// Open a `direct-tcpip` channel for one accepted connection and glue the two together.
    private static func bridge(
        inbound: Channel,
        over connection: SSHConnection,
        remoteHost: String,
        remotePort: UInt16,
        live: NIOLockedValueBox<Int>,
        accepted: NIOLockedValueBox<Int>
    ) -> EventLoopFuture<Void> {
        accepted.withLockedValue { $0 += 1 }

        // The originator is reported to the far side for its logs; the accepted socket's real peer
        // address is the honest answer. An accepted TCP channel always has one, so the fallback
        // only guards the theoretical nil and never invents a plausible-looking address.
        let originator: SocketAddress
        if let remote = inbound.remoteAddress {
            originator = remote
        } else {
            do {
                originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            } catch {
                inbound.close(promise: nil)
                return inbound.eventLoop.makeFailedFuture(
                    TransportError.connectionFailed(
                        "could not describe the originating address: \(String(describing: error))"))
            }
        }

        let type = SSHChannelType.directTCPIP(
            .init(
                targetHost: remoteHost,
                targetPort: Int(remotePort),
                originatorAddress: originator
            )
        )

        return connection.openChannelFuture(type: type) { child in
            child.eventLoop.makeCompletedFuture {
                // The SSH child channel speaks SSHChannelData; unwrap to plain bytes so both ends
                // of the bridge exchange ByteBuffers.
                try child.pipeline.syncOperations.addHandler(SSHDataWrapperHandler())
            }.flatMap {
                child.setOption(.allowRemoteHalfClosure, value: true)
            }
        }.flatMap { child -> EventLoopFuture<Void> in
            live.withLockedValue { $0 += 1 }

            return inbound.eventLoop.makeCompletedFuture {
                try child.pipeline.syncOperations.addHandler(
                    ForwardingBridgeHandler(peer: inbound, onClose: nil))
                try inbound.pipeline.syncOperations.addHandler(
                    ForwardingBridgeHandler(
                        peer: child,
                        onClose: { live.withLockedValue { $0 -= 1 } }
                    )
                )
            }.map {
                // Both directions are wired; let the buffered inbound bytes flow.
                inbound.read()
            }
        }.flatMapError { error in
            // The far side refused the tunnel: close the accepted socket rather than leaving a
            // client waiting on a connection that can never carry data.
            inbound.close(promise: nil)
            return inbound.eventLoop.makeFailedFuture(error)
        }
    }
}

/// Copies bytes to a peer channel and propagates half-close and teardown in both directions.
final class ForwardingBridgeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let peer: Channel
    private let onClose: (@Sendable () -> Void)?
    private var closed = false

    init(peer: Channel, onClose: (@Sendable () -> Void)?) {
        self.peer = peer
        self.onClose = onClose
    }

    func channelActive(context: ChannelHandlerContext) {
        context.read()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        // Only ask for more once this chunk has been handed to the peer, so a slow peer applies
        // back-pressure to the fast side instead of being buffered without bound. `ChannelHandler`
        // context is not `Sendable`, but the completion provably runs on this event loop, which is
        // exactly the invariant `NIOLoopBound` asserts.
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { result in
            switch result {
            case .success:
                bound.value.read()
            case .failure:
                bound.value.close(promise: nil)
            }
        }
        self.peer.writeAndFlush(buffer, promise: promise)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.fireChannelReadComplete()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            // The peer saw EOF from us; forward EOF rather than a reset so a request/response
            // exchange that signals completion by closing still works.
            self.peer.close(mode: .output, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.finish()
        self.peer.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.finish()
        self.peer.close(promise: nil)
        context.close(promise: nil)
    }

    private func finish() {
        guard !self.closed else { return }
        self.closed = true
        self.onClose?()
    }
}
