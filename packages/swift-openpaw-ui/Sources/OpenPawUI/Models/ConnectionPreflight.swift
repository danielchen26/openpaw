import Foundation
import OpenPawTerminalCore

/// App-owned runner for a complete preflight. The UI receives only a typed report, never a remote command string.
public protocol ConnectionPreflightRunning: Sendable {
    func run(for host: HostRecord) async -> ConnectionPreflightReport
}

/// Fixed remote checks understood by production terminal implementations. Callers cannot supply shell text.
public enum TerminalCapabilityProbe: Sendable, Hashable {
    case multiplexer(MultiplexerKind)
    case transport(TransportKind)
}

public protocol TerminalCapabilityProbing: Sendable {
    func probe(_ probe: TerminalCapabilityProbe) async throws -> String
}

/// Runs a disposable connection through the complete security-sensitive preflight. Production injects a terminal and
/// host backend dedicated to this runner, so the user's active terminal is never replaced or disconnected.
public struct TypedConnectionPreflightRunner: ConnectionPreflightRunning, Sendable {
    private let terminal: any TerminalBackend
    private let capabilities: any TerminalCapabilityProbing
    private let backend: any OpenPawBackend

    public init(
        terminal: any TerminalBackend,
        capabilities: any TerminalCapabilityProbing,
        backend: any OpenPawBackend
    ) {
        self.terminal = terminal
        self.capabilities = capabilities
        self.backend = backend
    }

    public func run(for host: HostRecord) async -> ConnectionPreflightReport {
        var report = ConnectionPreflightReport()
        report.beginCurrentStage()
        do {
            try await terminal.connect(host: host)
            report.passCurrentStage(summary: "SSH route reached")
            report.passCurrentStage(summary: "Pinned host key accepted")
            report.passCurrentStage(summary: "SSH authentication succeeded")
        } catch {
            classifyConnection(error, report: &report)
            return await finish(report)
        }

        report.beginCurrentStage()
        do {
            if let lifecycle = backend as? any StructuredBackendLifecycle {
                try await lifecycle.connect(hostID: host.id)
            }
            _ = try await backend.health()
            report.passCurrentStage(summary: "OpenPaw host API is reachable")
        } catch is CancellationError {
            report.failCurrentStage(.cancelled)
            return await finish(report)
        } catch {
            report.failCurrentStage(.openPawUnavailable)
            return await finish(report)
        }

        if let multiplexer = host.multiplexerPreference {
            report.beginCurrentStage()
            do {
                let summary = try await capabilities.probe(.multiplexer(multiplexer))
                report.passCurrentStage(summary: summary)
            } catch is CancellationError {
                report.failCurrentStage(.cancelled)
                return await finish(report)
            } catch {
                report.failCurrentStage(.multiplexerUnavailable)
                return await finish(report)
            }
        } else {
            report.skipCurrentStage(reason: "No multiplexer selected")
        }

        report.beginCurrentStage()
        do {
            let selectedTransport = host.preferredTransport ?? .ssh
            let summary = try await capabilities.probe(.transport(selectedTransport))
            report.passCurrentStage(summary: summary)
        } catch is CancellationError {
            report.failCurrentStage(.cancelled)
        } catch {
            report.failCurrentStage(.transportUnavailable)
        }
        return await finish(report)
    }

    private func classifyConnection(_ error: any Error, report: inout ConnectionPreflightReport) {
        guard let transportError = error as? TransportError else {
            report.failCurrentStage(.routeUnavailable)
            return
        }
        switch transportError {
        case .hostKeyUnknown:
            report.passCurrentStage(summary: "SSH route reached")
            report.failCurrentStage(.hostKeyUnknown)
        case .hostKeyChanged:
            report.passCurrentStage(summary: "SSH route reached")
            report.failCurrentStage(.hostKeyChanged)
        case .unsupportedKeyType:
            report.passCurrentStage(summary: "SSH route reached")
            report.failCurrentStage(.hostKeyUnknown)
        case .authenticationFailed, .invalidPrivateKey:
            report.passCurrentStage(summary: "SSH route reached")
            report.passCurrentStage(summary: "Pinned host key accepted")
            report.failCurrentStage(.authenticationRejected)
        case .timeout:
            report.failCurrentStage(.timedOut)
        case .cancelled:
            report.failCurrentStage(.cancelled)
        case .unavailable, .remoteBinaryMissing:
            report.failCurrentStage(.transportUnavailable)
        case .nameResolutionFailed, .connectionRefused, .connectionFailed, .jumpHostFailed,
            .ptyRequestFailed, .channelClosed, .protocolViolation, .notConnected,
            .outputLimitExceeded:
            report.failCurrentStage(.routeUnavailable)
        }
    }

    private func finish(_ report: ConnectionPreflightReport) async -> ConnectionPreflightReport {
        if let lifecycle = backend as? any StructuredBackendLifecycle {
            await lifecycle.disconnect()
        }
        await terminal.disconnect()
        return report
    }
}

/// Security-sensitive preflight stages have one fixed order. No stage is represented by a shell command string.
public enum ConnectionPreflightStage: String, CaseIterable, Sendable, Hashable {
    case route
    case hostKey
    case authentication
    case openPawHealth
    case multiplexer
    case transportCapabilities

    public var displayName: String {
        switch self {
        case .route: "Route"
        case .hostKey: "Host key"
        case .authentication: "Authentication"
        case .openPawHealth: "OpenPaw health"
        case .multiplexer: "Multiplexer"
        case .transportCapabilities: "Transport"
        }
    }
}

public enum ConnectionPreflightFailure: String, Sendable, Hashable {
    case routeUnavailable
    case timedOut
    case hostKeyUnknown
    case hostKeyChanged
    case authenticationRejected
    case openPawUnavailable
    case multiplexerUnavailable
    case transportUnavailable
    case cancelled

    public var displayName: String {
        switch self {
        case .routeUnavailable: "Route unavailable"
        case .timedOut: "Timed out"
        case .hostKeyUnknown: "Host key needs review"
        case .hostKeyChanged: "Host key changed"
        case .authenticationRejected: "Authentication rejected"
        case .openPawUnavailable: "OpenPaw host API unavailable"
        case .multiplexerUnavailable: "Multiplexer unavailable"
        case .transportUnavailable: "Transport unavailable"
        case .cancelled: "Cancelled"
        }
    }
}

public enum ConnectionPreflightStageState: Sendable, Hashable {
    case pending
    case running
    case passed(summary: String?)
    case skipped(reason: String)
    case failed(ConnectionPreflightFailure)
    case blocked
}

/// A deterministic report suitable for both a progress UI and persisted diagnostics.
public struct ConnectionPreflightReport: Sendable, Hashable {
    private var states: [ConnectionPreflightStage: ConnectionPreflightStageState]

    public init() {
        self.states = Dictionary(uniqueKeysWithValues: ConnectionPreflightStage.allCases.map { ($0, .pending) })
    }

    public subscript(stage: ConnectionPreflightStage) -> ConnectionPreflightStageState {
        states[stage] ?? .pending
    }

    public var currentStage: ConnectionPreflightStage? {
        guard !didFail else { return nil }
        return ConnectionPreflightStage.allCases.first { states[$0] == .pending || states[$0] == .running }
    }

    public var didFail: Bool {
        states.values.contains { state in
            if case .failed = state { return true }
            return false
        }
    }

    public mutating func beginCurrentStage() {
        guard let currentStage else { return }
        states[currentStage] = .running
    }

    public mutating func passCurrentStage(summary: String?) {
        guard let currentStage else { return }
        states[currentStage] = .passed(summary: summary)
    }

    public mutating func skipCurrentStage(reason: String) {
        guard let currentStage else { return }
        states[currentStage] = .skipped(reason: reason)
    }

    public mutating func failCurrentStage(_ failure: ConnectionPreflightFailure) {
        guard let currentStage,
            let failedIndex = ConnectionPreflightStage.allCases.firstIndex(of: currentStage)
        else { return }
        states[currentStage] = .failed(failure)
        for stage in ConnectionPreflightStage.allCases.dropFirst(failedIndex + 1) {
            if states[stage] == .pending { states[stage] = .blocked }
        }
    }
}
