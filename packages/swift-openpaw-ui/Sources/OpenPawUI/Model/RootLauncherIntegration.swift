import Foundation
import OpenPawProtocol
import OpenPawTerminalCore

/// Builds the launcher's context-graph input from root-owned state, and decides what a confirmed launcher
/// action means for the app.
///
/// Pure and value-typed so the mapping from "what the app knows" to "what the Orb shows" is testable without
/// a view hierarchy. `RootView` owns the live objects; this type only ever sees copies.
public enum RootLauncherIntegration {

    /// One immutable capture of everything the graph builder needs, taken on the main actor.
    @MainActor
    public static func graphInput(
        model: OpenPawModel,
        sessionSpace: SessionSpaceSnapshot,
        destination: ShellDestination,
        selectedRepositoryPath: String?,
        snapshotID: UUID = UUID()
    ) -> WorkspaceContextInput {
        WorkspaceContextInput(
            snapshotID: snapshotID,
            host: model.selectedHost.map { WorkspaceContextHost(id: $0.id, title: $0.nickname) },
            connectionGeneration: model.connectionGeneration,
            destination: contextDestination(for: destination),
            structuredSessions: [],
            agentSessions: model.sessions,
            transcripts: model.transcripts,
            sessionSpace: sessionSpace,
            selectedSessionID: model.selectedSessionID,
            selectedRepositoryPath: selectedRepositoryPath,
            repositories: model.repos,
            inbox: model.inbox,
            authenticatedDestinations: authenticatedDestinations(isConnected: model.connection.isConnected),
            isConnected: model.connection.isConnected
        )
    }

    /// Which context destinations the launcher may offer. Everything requires a connected host except the
    /// screens that exist to get one.
    public static func authenticatedDestinations(isConnected: Bool) -> Set<WorkspaceContextDestination> {
        isConnected
            ? [.home, .sessions, .repository, .terminal, .inbox, .settings]
            : [.home, .settings]
    }

    public static func contextDestination(for destination: ShellDestination) -> WorkspaceContextDestination {
        switch destination {
        case .home: .home
        case .terminal: .terminal
        case .sessions: .sessions
        case .inbox: .inbox
        case .repo: .repository
        case .settings: .settings
        }
    }

    public static func shellDestination(for destination: WorkspaceContextDestination) -> ShellDestination {
        switch destination {
        case .home: .home
        case .terminal: .terminal
        case .sessions: .sessions
        case .inbox: .inbox
        case .repository: .repo
        case .settings: .settings
        }
    }

    /// What a confirmed non-proposal launcher action asks the app to do. Kept as data so the decision can be
    /// asserted in tests; `RootView` translates each case into router/model mutations.
    public enum ConfirmedActionRoute: Sendable, Hashable {
        case navigate(ShellDestination)
        case openAgentSession(String)
        case attach(RemoteSession)
        case focusWindow(kind: MultiplexerKind, sessionID: String, windowID: String)
        case openRepository(path: String)
        case tool(WorkspaceToolAction)
        case switchHost
        case executeProposal(ProactiveProposal, operationID: UUID)
        case none
    }

    /// Maps a confirmed launcher effect onto an app route.
    ///
    /// Pane focus routes re-use the attach path: the multiplexer adapters attach commands land the user in the
    /// session, and per-pane focus is a follow-up the terminal owns. Herdr panes carry their terminal ID so the
    /// attach is exact.
    public static func route(for action: WorkspaceContextAction, operationID: UUID) -> ConfirmedActionRoute {
        switch action {
        case .switchHost:
            return .switchHost
        case .openDestination(let destination):
            return .navigate(shellDestination(for: destination))
        case .openAgentSession(let sessionID):
            return .openAgentSession(sessionID)
        case .attachMultiplexer(let kind, let sessionID):
            return .attach(.target(sessionID, kind: kind))
        case .focusMultiplexerWindow(let kind, let sessionID, let windowID):
            return .focusWindow(kind: kind, sessionID: sessionID, windowID: windowID)
        case .focusMultiplexerPane(let kind, let sessionID, _, let paneID):
            // Pane-level focus enters through the same session attach; the multiplexer restores its own
            // last-active pane and the user is one native gesture from the exact pane. Never a dead end.
            _ = paneID
            return .attach(.target(sessionID, kind: kind))
        case .focusHerdrPane(let workspaceID, let tabID, let paneID, let terminalID):
            return .attach(RemoteSession(
                id: paneID,
                name: paneID,
                kind: .herdr,
                terminalID: terminalID,
                workspaceID: workspaceID,
                tabID: tabID))
        case .openRepository(let path):
            return .openRepository(path: path)
        case .tool(let tool):
            return .tool(tool)
        case .openProposal(let proposal):
            return .executeProposal(proposal, operationID: operationID)
        case .showMoreProposals(let proposals):
            // The frozen preview shows the ranked list; confirming "more" without a specific pick executes the
            // best remaining proposal rather than doing nothing.
            guard let best = proposals.first else { return .none }
            return .executeProposal(best, operationID: operationID)
        }
    }

    /// Proposal target context for the execution coordinator's ownership checks.
    ///
    /// `selectedSessionID`/`selectedTabID` mirror the *target* rather than a UI selection: the launcher
    /// dispatches into the pane the frozen graph named, so the ownership check must fail only when the world
    /// (host, generation, connection) moved, not when the user happens to be reading another screen.
    @MainActor
    public static func executionContext(
        model: OpenPawModel,
        graph: WorkspaceContextGraph,
        target: WorkspaceContextTarget
    ) -> ProposalExecutionContext {
        ProposalExecutionContext(
            hostID: model.selectedHostID,
            connectionGeneration: model.connectionGeneration,
            graphSnapshotID: graph.snapshotID,
            selectedSessionID: target.sessionID,
            selectedTabID: target.tabID,
            isConnected: model.connection.isConnected
        )
    }
}
