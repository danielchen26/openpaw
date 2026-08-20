//===----------------------------------------------------------------------===//
//
// This source file is part of the OpenPaw open source project.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore
import NIOSSH
import OpenPawTerminalCore

/// Runs one-shot commands over an existing SSH connection.
///
/// This is the ``CommandRunner`` the multiplexer adapters in `OpenPawTerminalCore` are written
/// against, so `TmuxAdapter`, `ZellijAdapter` and friends work against a real host without knowing
/// anything about SSH. Each call opens its own `exec` channel, which is what OpenSSH does for
/// `ssh host command` and keeps commands independent of the interactive PTY session.
///
/// Two limits are enforced because the output is remote and untrusted:
/// a wall-clock ``timeout`` and a ``maximumOutputBytes`` ceiling. A command that exceeds either is
/// aborted and reported rather than being allowed to consume unbounded memory or hang a UI.
public struct SSHCommandRunner: CommandRunner, Sendable {
    private let connection: SSHConnection

    /// How long a single command may take before its channel is closed.
    public let timeout: Duration

    /// Maximum combined stdout+stderr accepted from one command.
    public let maximumOutputBytes: Int

    public init(
        connection: SSHConnection,
        timeout: Duration = .seconds(20),
        maximumOutputBytes: Int = 1 << 20
    ) {
        self.connection = connection
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }

    /// Run `command` and return its standard output.
    ///
    /// - Throws: ``CommandFailure`` when the command exits non-zero, which is how the adapters tell
    ///   "the multiplexer is not running" from a broken connection; ``TransportError`` when the
    ///   channel, the timeout or the output limit is at fault.
    public func run(_ command: String) async throws -> String {
        guard self.connection.isActive else {
            throw TransportError.notConnected
        }

        let loop = self.connection.eventLoop
        let completion = loop.makePromise(of: ExecOutcome.self)
        let limit = self.maximumOutputBytes

        let channel = try await self.connection.openChannel(type: .session) { child in
            child.eventLoop.makeCompletedFuture {
                let sync = child.pipeline.syncOperations
                try sync.addHandler(SSHDataWrapperHandler())
                try sync.addHandler(ChannelReplyTracker())
                try sync.addHandler(
                    ExecOutputCollector(limit: limit, completion: completion))
            }
        }

        // Close the channel if the command overruns; the collector then fails with `.timeout`.
        let deadline = loop.scheduleTask(in: self.timeout.asTimeAmount) {
            channel.close(promise: nil)
        }
        defer { deadline.cancel() }

        do {
            try await SSHTransport.request(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
                on: channel,
                describedAs: "exec of \(command)"
            )
        } catch {
            try? await channel.close().get()
            throw error
        }

        let outcome = try await completion.futureResult.get()

        // An exec channel that closes without an exit-status message is a protocol violation, but
        // in practice it also means the peer died mid-command, so report the closure.
        guard let exitCode = outcome.exitStatus else {
            if let failure = outcome.failureReason {
                throw TransportError.channelClosed(reason: failure)
            }
            throw TransportError.channelClosed(
                reason: "the peer closed the exec channel without an exit status")
        }

        guard exitCode == 0 else {
            throw CommandFailure(
                command: command,
                exitCode: Int32(exitCode),
                output: outcome.standardOutput + outcome.standardError
            )
        }
        return outcome.standardOutput
    }
}

// MARK: - Collector

/// What one `exec` channel produced.
struct ExecOutcome: Sendable {
    var standardOutput: String
    var standardError: String
    var exitStatus: Int?
    var failureReason: String?
}

/// Accumulates an `exec` channel's output and completes a promise when the channel closes.
final class ExecOutputCollector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let limit: Int
    private var completion: EventLoopPromise<ExecOutcome>?
    private var standardOutput: [UInt8] = []
    private var standardError: [UInt8] = []
    private var exitStatus: Int?
    private var failureReason: String?

    init(limit: Int, completion: EventLoopPromise<ExecOutcome>) {
        self.limit = limit
        self.completion = completion
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        self.append(buffer.readableBytesView, to: .standardOutput, context: context)
        context.fireChannelRead(data)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let stderr as SSHDataWrapperHandler.StandardErrorData:
            self.append(stderr.buffer.readableBytesView, to: .standardError, context: context)
        case let status as SSHChannelRequestEvent.ExitStatus:
            self.exitStatus = status.exitStatus
        case let signal as SSHChannelRequestEvent.ExitSignal:
            self.failureReason = "the command was killed by SIG\(signal.signalName)"
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if self.failureReason == nil {
            self.failureReason = String(describing: error)
        }
        // A limit breach already failed the promise; anything else is reported at close.
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.finish(
            with: ExecOutcome(
                standardOutput: String(decoding: self.standardOutput, as: UTF8.self),
                standardError: String(decoding: self.standardError, as: UTF8.self),
                exitStatus: self.exitStatus,
                failureReason: self.failureReason
            )
        )
        context.fireChannelInactive()
    }

    /// Which accumulator a chunk belongs to.
    private enum Stream {
        case standardOutput
        case standardError
    }

    /// Append bytes, aborting the whole command if the combined output exceeds the limit.
    ///
    /// The destination is named rather than passed `inout`: computing the running total reads both
    /// accumulators, which would overlap an `inout` access to one of them and trap on exclusivity.
    private func append(
        _ bytes: ByteBufferView,
        to stream: Stream,
        context: ChannelHandlerContext
    ) {
        let total = self.standardOutput.count + self.standardError.count + bytes.count
        guard total <= self.limit else {
            self.fail(with: TransportError.outputLimitExceeded)
            context.close(promise: nil)
            return
        }
        switch stream {
        case .standardOutput:
            self.standardOutput.append(contentsOf: bytes)
        case .standardError:
            self.standardError.append(contentsOf: bytes)
        }
    }

    private func fail(with error: any Error) {
        guard let promise = self.completion else { return }
        self.completion = nil
        promise.fail(error)
    }

    private func finish(with outcome: ExecOutcome) {
        guard let promise = self.completion else { return }
        self.completion = nil
        promise.succeed(outcome)
    }
}
