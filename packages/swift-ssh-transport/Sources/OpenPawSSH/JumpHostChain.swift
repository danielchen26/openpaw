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
import NIOSSH
import OpenPawTerminalCore

/// Walks a `ProxyJump` chain of arbitrary length.
///
/// Each hop after the first is reached by opening a `direct-tcpip` channel on its predecessor and
/// running a complete SSH handshake *inside* that channel. The bytes of hop N's handshake are
/// therefore encrypted twice: once by hop N's own transport, and again by hop N-1's. This is
/// exactly what `ssh -J` does, and it means no intermediate host ever sees the final host's
/// credentials or traffic in the clear.
///
/// Failures name the hop that broke via ``TransportError/jumpHostFailed(hop:reason:)``, because
/// "connection refused" is useless when three machines are involved.
public enum JumpHostChain {
    /// Dial `configuration.jumpHosts` in order and then `configuration` itself.
    ///
    /// - Parameters:
    ///   - configuration: The final destination. Its `jumpHosts` are the chain, element 0 first.
    ///   - finalCredentials: Already-resolved credentials for the destination.
    ///   - secretResolver: Resolves each jump host's own credentials.
    ///   - hostKeyVerification: Applied at every hop; an unknown intermediate host is as fatal as
    ///     an unknown destination.
    ///   - group: Event loop group for the whole chain.
    ///   - ownsGroup: Whether the returned connection must shut `group` down when it closes.
    /// - Returns: A connection to the final destination whose ``SSHConnection/close()`` tears down
    ///   the entire chain, last hop first.
    static func connect(
        configuration: ConnectionConfiguration,
        finalCredentials: [SSHCredential],
        secretResolver: any SSHSecretResolver,
        hostKeyVerification: @escaping @Sendable (String) -> HostKeyVerdict,
        group: any EventLoopGroup,
        ownsGroup: Bool
    ) async throws -> SSHConnection {
        precondition(!configuration.jumpHosts.isEmpty, "use SSHConnection.connectDirectly for a direct dial")

        // The chain as a flat list: every jump host, then the destination.
        var hops = configuration.jumpHosts
        hops.append(configuration)

        // Hop 0 is a plain TCP dial.
        let firstHop = hops[0]
        let firstCredentials: [SSHCredential]
        do {
            firstCredentials = try await secretResolver.resolveCredentials(for: firstHop.auth)
        } catch {
            throw Self.wrap(error, hop: 0, of: hops.count, host: firstHop.host)
        }

        var current: SSHConnection
        do {
            current = try await SSHConnection.connectDirectly(
                configuration: firstHop,
                credentials: firstCredentials,
                hostKeyValidator: HostKeyValidator(verify: hostKeyVerification),
                group: group,
                ownsGroup: ownsGroup
            )
        } catch {
            throw Self.wrap(error, hop: 0, of: hops.count, host: firstHop.host)
        }

        // Every later hop tunnels through the one before it.
        for index in 1..<hops.count {
            let hop = hops[index]
            let isFinal = index == hops.count - 1

            let credentials: [SSHCredential]
            if isFinal {
                credentials = finalCredentials
            } else {
                do {
                    credentials = try await secretResolver.resolveCredentials(for: hop.auth)
                } catch {
                    await current.close()
                    throw Self.wrap(error, hop: index, of: hops.count, host: hop.host)
                }
            }

            do {
                current = try await Self.tunnel(
                    through: current,
                    to: hop,
                    credentials: credentials,
                    hostKeyVerification: hostKeyVerification
                )
            } catch {
                await current.close()
                throw Self.wrap(error, hop: index, of: hops.count, host: hop.host)
            }
        }

        return current
    }

    /// Open a `direct-tcpip` channel on `previous` and complete an SSH handshake inside it.
    private static func tunnel(
        through previous: SSHConnection,
        to hop: ConnectionConfiguration,
        credentials: [SSHCredential],
        hostKeyVerification: @escaping @Sendable (String) -> HostKeyVerdict
    ) async throws -> SSHConnection {
        let authPromise = previous.eventLoop.makePromise(of: Void.self)
        let validator = HostKeyValidator(verify: hostKeyVerification)
        let username = hop.username

        // The originator address is informational; the jump host only logs it. Reporting loopback
        // is accurate: the connection really does originate on the previous hop itself.
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)

        let tunnelChannel: Channel
        do {
            tunnelChannel = try await previous.openChannel(
                type: .directTCPIP(
                    .init(targetHost: hop.host, targetPort: hop.port, originatorAddress: originator))
            ) { child in
                child.eventLoop.makeCompletedFuture {
                    // Unwrap SSH framing first, so the nested NIOSSHHandler sees a plain byte
                    // stream exactly as it would on a TCP socket.
                    try child.pipeline.syncOperations.addHandler(SSHDataWrapperHandler())
                    try SSHConnection.installClientHandlers(
                        on: child,
                        username: username,
                        credentials: credentials,
                        hostKeyValidator: validator,
                        authPromise: authPromise
                    )
                }
            }
        } catch {
            authPromise.fail(TransportError.cancelled)
            _ = try? await authPromise.futureResult.get()
            throw error
        }

        do {
            let deadline = tunnelChannel.eventLoop.scheduleTask(in: hop.connectTimeout.asTimeAmount) {
                tunnelChannel.close(promise: nil)
            }
            defer { deadline.cancel() }
            try await authPromise.futureResult.get()
        } catch let error as TransportError {
            try? await tunnelChannel.close().get()
            throw error
        } catch {
            try? await tunnelChannel.close().get()
            throw TransportError.authenticationFailed(reason: String(describing: error))
        }

        return SSHConnection(
            channel: tunnelChannel,
            // The tunnel borrows the first hop's group; only that hop may shut it down.
            ownedGroup: nil,
            previousHop: previous,
            label: "\(hop.username)@\(hop.host):\(hop.port)"
        )
    }

    /// Attribute a failure to a hop, leaving the destination's own errors unwrapped.
    ///
    /// The last element of the chain is the host the user asked for, so its errors must stay
    /// recognisable (an ``TransportError/authenticationFailed(reason:)`` there is a bad password,
    /// not a broken proxy).
    private static func wrap(
        _ error: any Error,
        hop index: Int,
        of count: Int,
        host: String
    ) -> TransportError {
        if index == count - 1, let transport = error as? TransportError {
            return transport
        }
        let reason: String
        if let transport = error as? TransportError {
            reason = "\(host): \(transport.description)"
        } else {
            reason = "\(host): \(String(describing: error))"
        }
        return .jumpHostFailed(hop: index, reason: reason)
    }
}
