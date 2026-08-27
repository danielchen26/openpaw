import Foundation
import Observation
import OpenPawProtocol
import OpenPawTerminalCore

public struct ProposalExecutionContext: Sendable, Hashable {
    public var hostID: HostID?
    public var connectionGeneration: Int
    public var graphSnapshotID: UUID
    public var selectedSessionID: String?
    public var selectedTabID: String?
    public var isConnected: Bool

    public init(
        hostID: HostID?,
        connectionGeneration: Int,
        graphSnapshotID: UUID,
        selectedSessionID: String? = nil,
        selectedTabID: String? = nil,
        isConnected: Bool = true
    ) {
        self.hostID = hostID
        self.connectionGeneration = connectionGeneration
        self.graphSnapshotID = graphSnapshotID
        self.selectedSessionID = selectedSessionID
        self.selectedTabID = selectedTabID
        self.isConnected = isConnected
    }
}

public enum ProposalExecutionStage: String, Sendable, Hashable {
    case routing
    case executing
}

public enum ProposalExecutionPhase: Sendable, Hashable {
    case routing
    case executing
    case completed
    case reconnectNeeded
    case failed(stage: ProposalExecutionStage, message: String)
}

@MainActor
@Observable
public final class ProposalExecutionCoordinator {
    public private(set) var phase: ProposalExecutionPhase?
    public private(set) var previewProposal: ProactiveProposal?

    private let expectedHostID: HostID
    private let expectedGeneration: Int
    private let expectedGraphSnapshotID: UUID
    private let context: @MainActor () -> ProposalExecutionContext
    private let executor: any SessionSpaceCommandExecuting
    private let terminal: any TerminalBackend
    private var completedOperationIDs: Set<String> = []
    private var inFlightOperationIDs: Set<String> = []

    public init(
        expectedHostID: HostID,
        expectedGeneration: Int,
        expectedGraphSnapshotID: UUID,
        context: @escaping @MainActor () -> ProposalExecutionContext,
        executor: any SessionSpaceCommandExecuting,
        terminal: any TerminalBackend
    ) {
        self.expectedHostID = expectedHostID
        self.expectedGeneration = expectedGeneration
        self.expectedGraphSnapshotID = expectedGraphSnapshotID
        self.context = context
        self.executor = executor
        self.terminal = terminal
    }

    @discardableResult
    public func execute(_ proposal: ProactiveProposal, operationID: String) async -> ProposalExecutionPhase {
        guard !completedOperationIDs.contains(operationID) else {
            phase = .completed
            return .completed
        }
        guard !inFlightOperationIDs.contains(operationID) else {
            return phase ?? .routing
        }
        previewProposal = proposal
        guard owns(proposal.target) else { return set(.reconnectNeeded) }
        inFlightOperationIDs.insert(operationID)
        defer { inFlightOperationIDs.remove(operationID) }

        let routeCommand: MultiplexerCommand
        do {
            routeCommand = try Self.routeCommand(for: proposal.target)
        } catch {
            return set(.failed(stage: .routing, message: String(describing: error)))
        }

        phase = .routing
        do {
            _ = try await SessionSpaceActionCoordinator.run(
                SessionSpaceActionPlan(
                    command: routeCommand,
                    refreshAfterCommand: false,
                    navigation: .opensTerminal),
                expectedHostID: expectedHostID,
                expectedGeneration: expectedGeneration,
                context: { [expectedHostID, expectedGeneration] in
                    SessionSpaceActionContext(
                        snapshot: SessionSpaceSnapshot(
                            hostID: expectedHostID,
                            connectionGeneration: expectedGeneration,
                            remoteSessions: Self.remoteSessions(for: proposal.target)),
                        hostID: self.context().hostID,
                        connectionGeneration: self.context().connectionGeneration,
                        isConnected: self.context().isConnected)
                },
                executor: executor)
        } catch {
            guard owns(proposal.target) else { return set(.reconnectNeeded) }
            return set(.failed(stage: .routing, message: String(describing: error)))
        }
        guard owns(proposal.target) else { return set(.reconnectNeeded) }

        guard let text = Self.dispatchText(for: proposal) else {
            return set(.failed(stage: .executing, message: "Proposal payload cannot be executed in a terminal"))
        }
        phase = .executing
        do {
            try await terminal.send(text: text)
        } catch {
            guard owns(proposal.target) else { return set(.reconnectNeeded) }
            return set(.failed(stage: .executing, message: String(describing: error)))
        }
        guard owns(proposal.target) else { return set(.reconnectNeeded) }

        completedOperationIDs.insert(operationID)
        return set(.completed)
    }

    private func set(_ value: ProposalExecutionPhase) -> ProposalExecutionPhase {
        phase = value
        return value
    }

    private func owns(_ target: WorkspaceContextTarget) -> Bool {
        let current = context()
        guard current.isConnected,
              current.hostID == expectedHostID,
              current.connectionGeneration == expectedGeneration,
              current.graphSnapshotID == expectedGraphSnapshotID,
              target.hostID == expectedHostID else {
            return false
        }
        if let targetSession = target.sessionID, current.selectedSessionID != targetSession { return false }
        if let targetTab = target.tabID, current.selectedTabID != targetTab { return false }
        return true
    }

    private static func remoteSessions(for target: WorkspaceContextTarget) -> [RemoteSession] {
        guard let kind = target.multiplexerKind else { return [] }
        if kind == .herdr, let paneID = target.paneID ?? target.multiplexerSessionID {
            return [RemoteSession(
                id: paneID,
                name: paneID,
                kind: .herdr,
                terminalID: target.terminalID,
                workspaceID: target.workspaceID,
                tabID: target.tabID)]
        }
        guard let sessionID = target.multiplexerSessionID else { return [] }
        return [RemoteSession.target(sessionID, kind: kind)]
    }

    private static func dispatchText(for proposal: ProactiveProposal) -> String? {
        switch proposal.payload {
        case .agentMessage(let message):
            return proposal.risk == .destructive ? message : message + "\n"
        case .terminalCommand(let command):
            return proposal.risk == .destructive ? command : command + "\n"
        case .navigate, .tool:
            return nil
        }
    }

    private static func routeCommand(for target: WorkspaceContextTarget) throws -> MultiplexerCommand {
        guard let kind = target.multiplexerKind else {
            throw ProposalExecutionError.missingMultiplexerTarget
        }
        if kind == .herdr {
            guard let paneID = target.paneID ?? target.multiplexerSessionID else { throw ProposalExecutionError.missingPaneID }
            guard let terminalID = target.terminalID else { throw ProposalExecutionError.missingTerminalID }
            let session = RemoteSession(
                id: paneID,
                name: paneID,
                kind: .herdr,
                terminalID: terminalID,
                workspaceID: target.workspaceID,
                tabID: target.tabID)
            _ = try MultiplexerCommand.attach(session).rendered()
            return .attach(session)
        }
        guard let sessionID = target.multiplexerSessionID else { throw ProposalExecutionError.missingSessionID }
        let session = RemoteSession.target(sessionID, kind: kind)
        _ = try MultiplexerCommand.attach(session).rendered()
        return .attach(session)
    }
}

public enum ProposalExecutionError: Error, Sendable, Hashable, CustomStringConvertible {
    case missingMultiplexerTarget
    case missingSessionID
    case missingPaneID
    case missingTerminalID

    public var description: String {
        switch self {
        case .missingMultiplexerTarget: "Missing multiplexer target"
        case .missingSessionID: "Missing session id"
        case .missingPaneID: "Missing Herdr pane id"
        case .missingTerminalID: "Missing Herdr terminal id"
        }
    }
}
