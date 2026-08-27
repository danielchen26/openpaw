import Foundation
import OpenPawProtocol
import OpenPawTerminalCore

public struct WorkspaceContextGraph: Sendable, Hashable {
    public var snapshotID: UUID
    public var hostID: HostID?
    public var connectionGeneration: Int
    public var root: WorkspaceContextNode

    public init(snapshotID: UUID, hostID: HostID?, connectionGeneration: Int, root: WorkspaceContextNode) {
        self.snapshotID = snapshotID
        self.hostID = hostID
        self.connectionGeneration = connectionGeneration
        self.root = root
    }
}

public struct WorkspaceContextNode: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case host
        case session
        case tab
        case pane
        case repository
        case tool
        case proposal
        case more
        case switchHost
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var isPartial: Bool
    public var children: [WorkspaceContextNode]
    public var action: WorkspaceContextAction?

    public init(
        id: String,
        kind: Kind,
        title: String,
        subtitle: String? = nil,
        isPartial: Bool = false,
        children: [WorkspaceContextNode] = [],
        action: WorkspaceContextAction? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.isPartial = isPartial
        self.children = children
        self.action = action
    }

    /// A depth-first view that intentionally excludes the receiver itself.
    public var descendants: [WorkspaceContextNode] {
        children.flatMap { [$0] + $0.descendants }
    }
}

public enum WorkspaceContextDestination: String, Sendable, Hashable, CaseIterable {
    case home
    case sessions
    case repository
    case terminal
    case inbox
    case settings
}

public enum WorkspaceToolAction: Sendable, Hashable {
    case navigate(WorkspaceContextDestination)
    case terminalKeys
    case dictate
    case search
    case copyAll
    case fontSmaller
    case fontLarger

    public var title: String {
        switch self {
        case .navigate(let destination): destination.title
        case .terminalKeys: "Terminal keys"
        case .dictate: "Dictate"
        case .search: "Search scrollback"
        case .copyAll: "Copy all output"
        case .fontSmaller: "Smaller terminal text"
        case .fontLarger: "Larger terminal text"
        }
    }

    fileprivate var stableIDComponent: String {
        switch self {
        case .navigate(let destination): "navigate.\(destination.rawValue)"
        case .terminalKeys: "terminal-keys"
        case .dictate: "dictate"
        case .search: "search"
        case .copyAll: "copy-all"
        case .fontSmaller: "font-smaller"
        case .fontLarger: "font-larger"
        }
    }
}

private extension WorkspaceContextDestination {
    var title: String {
        switch self {
        case .home: "Home"
        case .sessions: "Sessions"
        case .repository: "Repository"
        case .terminal: "Terminal"
        case .inbox: "Inbox"
        case .settings: "Settings"
        }
    }
}

public struct WorkspaceContextTarget: Sendable, Hashable {
    public var hostID: HostID?
    public var destination: WorkspaceContextDestination?
    public var multiplexerKind: MultiplexerKind?
    public var sessionID: String?
    public var workspaceID: String?
    public var tabID: String?
    public var paneID: String?
    public var terminalID: String?
    public var repositoryPath: String?

    public init(
        hostID: HostID? = nil,
        destination: WorkspaceContextDestination? = nil,
        multiplexerKind: MultiplexerKind? = nil,
        sessionID: String? = nil,
        workspaceID: String? = nil,
        tabID: String? = nil,
        paneID: String? = nil,
        terminalID: String? = nil,
        repositoryPath: String? = nil
    ) {
        self.hostID = hostID
        self.destination = destination
        self.multiplexerKind = multiplexerKind
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
        self.terminalID = terminalID
        self.repositoryPath = repositoryPath
    }
}

public enum WorkspaceContextAction: Sendable, Hashable {
    case switchHost
    case openDestination(WorkspaceContextDestination)
    case openAgentSession(sessionID: String)
    case attachMultiplexer(kind: MultiplexerKind, sessionID: String)
    case focusMultiplexerWindow(kind: MultiplexerKind, sessionID: String, windowID: String)
    case focusMultiplexerPane(kind: MultiplexerKind, sessionID: String, windowID: String, paneID: String)
    case focusHerdrPane(workspaceID: String?, tabID: String?, paneID: String, terminalID: String?)
    case openRepository(path: String)
    case tool(WorkspaceToolAction)
    case openProposal(ProactiveProposal)
    case showMoreProposals([ProactiveProposal])
}

public struct WorkspaceContextHost: Sendable, Hashable {
    public var id: HostID
    public var title: String

    public init(id: HostID, title: String) {
        self.id = id
        self.title = title
    }
}

public struct WorkspaceRepositoryPaneContext: Sendable, Hashable {
    public var repositoryPath: String?
    public var workingDirectory: String?

    public init(repositoryPath: String? = nil, workingDirectory: String? = nil) {
        self.repositoryPath = repositoryPath
        self.workingDirectory = workingDirectory
    }
}

public struct WorkspaceStructuredWindow: Sendable, Hashable {
    public var window: RemoteWindow
    public var panes: [RemotePane]

    public init(window: RemoteWindow, panes: [RemotePane] = []) {
        self.window = window
        self.panes = panes
    }
}

public struct WorkspaceStructuredSession: Sendable, Hashable {
    public var session: RemoteSession
    public var windows: [WorkspaceStructuredWindow]

    public init(session: RemoteSession, windows: [WorkspaceStructuredWindow] = []) {
        self.session = session
        self.windows = windows
    }
}

/// One immutable handoff from the model layer into context discovery. The builder never reaches back into
/// `OpenPawModel`, actors, routers, terminals, or the network.
public struct WorkspaceContextInput: Sendable {
    public var snapshotID: UUID
    public var host: WorkspaceContextHost?
    public var connectionGeneration: Int
    public var destination: WorkspaceContextDestination
    public var repositoryPane: WorkspaceRepositoryPaneContext?
    public var structuredSessions: [WorkspaceStructuredSession]
    public var agentSessions: [SessionSummary]
    public var transcripts: [String: [Event]]
    public var sessionSpace: SessionSpaceSnapshot
    public var selectedSessionID: String?
    public var selectedTabID: String?
    public var selectedPaneID: String?
    public var selectedRepositoryPath: String?
    public var repositories: [RepoSummary]
    public var inbox: [InboxItem]
    public var authenticatedDestinations: Set<WorkspaceContextDestination>
    public var isConnected: Bool

    public init(
        snapshotID: UUID,
        host: WorkspaceContextHost?,
        connectionGeneration: Int,
        destination: WorkspaceContextDestination,
        repositoryPane: WorkspaceRepositoryPaneContext? = nil,
        structuredSessions: [WorkspaceStructuredSession] = [],
        agentSessions: [SessionSummary] = [],
        transcripts: [String: [Event]] = [:],
        sessionSpace: SessionSpaceSnapshot = .init(),
        selectedSessionID: String? = nil,
        selectedTabID: String? = nil,
        selectedPaneID: String? = nil,
        selectedRepositoryPath: String? = nil,
        repositories: [RepoSummary] = [],
        inbox: [InboxItem] = [],
        authenticatedDestinations: Set<WorkspaceContextDestination> = [],
        isConnected: Bool = true
    ) {
        self.snapshotID = snapshotID
        self.host = host
        self.connectionGeneration = connectionGeneration
        self.destination = destination
        self.repositoryPane = repositoryPane
        self.structuredSessions = structuredSessions
        self.agentSessions = agentSessions
        self.transcripts = transcripts
        self.sessionSpace = sessionSpace
        self.selectedSessionID = selectedSessionID
        self.selectedTabID = selectedTabID
        self.selectedPaneID = selectedPaneID
        self.selectedRepositoryPath = selectedRepositoryPath
        self.repositories = repositories
        self.inbox = inbox
        self.authenticatedDestinations = authenticatedDestinations
        self.isConnected = isConnected
    }
}

public struct WorkspaceContextGraphBuilder: Sendable {
    public init() {}

    public func build(_ input: WorkspaceContextInput) -> WorkspaceContextGraph {
        let hostID = input.host?.id
        let currentInput = currentRemoteContext(from: input, hostID: hostID)
        var children = herdrNodes(currentInput)
        children.append(contentsOf: multiplexerNodes(currentInput))
        children.append(contentsOf: agentSessionNodes(currentInput))
        if !children.contains(where: { $0.kind == .session }),
           let tools = toolBranch(currentInput.authenticatedDestinations, scopeID: "root") {
            children.append(tools)
        }
        children.append(
            WorkspaceContextNode(
                id: Self.stableID("switch-host"),
                kind: .switchHost,
                title: "Switch Host",
                action: .switchHost
            )
        )

        let root = WorkspaceContextNode(
            id: Self.stableID("host", hostID?.uuidString.lowercased()),
            kind: .host,
            title: input.host?.title.trimmedNonEmpty ?? "No connected host",
            isPartial: input.host == nil,
            children: sorted(children)
        )
        return WorkspaceContextGraph(
            snapshotID: input.snapshotID,
            hostID: hostID,
            connectionGeneration: input.connectionGeneration,
            root: root
        )
    }

    private func currentRemoteContext(from input: WorkspaceContextInput, hostID: HostID?) -> WorkspaceContextInput {
        guard input.sessionSpace.hostID == hostID,
              input.sessionSpace.connectionGeneration == input.connectionGeneration else {
            var current = input
            current.sessionSpace = SessionSpaceSnapshot(
                hostID: hostID,
                connectionGeneration: input.connectionGeneration
            )
            current.structuredSessions = []
            return current
        }
        return input
    }

    private func herdrNodes(_ input: WorkspaceContextInput) -> [WorkspaceContextNode] {
        let sessions = input.sessionSpace.remoteSessions.filter { $0.kind == .herdr }
        let workspaces = Dictionary(grouping: sessions) { MetadataKey($0.workspaceID?.trimmedNonEmpty) }

        return workspaces.map { workspaceKey, workspaceSessions in
            let workspaceID = workspaceKey.value
            let tabs = Dictionary(grouping: workspaceSessions) { MetadataKey($0.tabID?.trimmedNonEmpty) }
            let tabNodes = tabs.map { tabKey, tabSessions in
                let tabID = tabKey.value
                let label = tabSessions.compactMap { $0.tabLabel?.trimmedNonEmpty }.sorted().first
                let paneNodes = tabSessions.map { session in
                    var children: [WorkspaceContextNode] = []
                    let paneID = Self.stableID("herdr-pane", workspaceID, tabID, session.id)
                    if let repository = repository(matching: session.workingDirectory, allowlist: input.repositories) {
                        children.append(repositoryNode(repository, scopeID: paneID))
                    }
                    if let tools = toolBranch(input.authenticatedDestinations, scopeID: paneID) {
                        children.append(tools)
                    }
                    return WorkspaceContextNode(
                        id: paneID,
                        kind: .pane,
                        title: session.name.trimmedNonEmpty ?? "Herdr pane",
                        subtitle: session.workingDirectory,
                        children: sorted(children),
                        action: .focusHerdrPane(
                            workspaceID: workspaceID,
                            tabID: tabID,
                            paneID: session.id,
                            terminalID: session.terminalID
                        )
                    )
                }
                return WorkspaceContextNode(
                    id: Self.stableID("herdr-tab", workspaceID, tabID),
                    kind: .tab,
                    title: label ?? tabID ?? "Unknown Herdr tab",
                    isPartial: tabID == nil,
                    children: sorted(paneNodes)
                )
            }
            return WorkspaceContextNode(
                id: Self.stableID("herdr-workspace", workspaceID),
                kind: .session,
                title: workspaceID ?? "Unknown Herdr workspace",
                subtitle: "Herdr workspace",
                isPartial: workspaceID == nil,
                children: sorted(tabNodes)
            )
        }
    }

    private func multiplexerNodes(_ input: WorkspaceContextInput) -> [WorkspaceContextNode] {
        var sessionsByKey: [MultiplexerSessionKey: WorkspaceStructuredSession] = [:]
        for structured in input.structuredSessions where structured.session.kind != .herdr {
            sessionsByKey[MultiplexerSessionKey(structured.session)] = structured
        }
        for session in input.sessionSpace.remoteSessions where session.kind != .herdr {
            let key = MultiplexerSessionKey(session)
            sessionsByKey[key] = sessionsByKey[key] ?? .init(session: session)
        }

        return sessionsByKey.values.map { structured in
            let session = structured.session
            let sessionNodeID = Self.stableID("mux-session", session.kind.rawValue, session.id)
            let windowNodes: [WorkspaceContextNode]
            if structured.windows.isEmpty {
                var children: [WorkspaceContextNode] = []
                let windowNodeID = Self.stableID("mux-window", session.kind.rawValue, session.id, nil)
                if let repository = repository(matching: session.workingDirectory, allowlist: input.repositories) {
                    children.append(repositoryNode(repository, scopeID: windowNodeID))
                }
                if let tools = toolBranch(input.authenticatedDestinations, scopeID: windowNodeID) {
                    children.append(tools)
                }
                windowNodes = [
                    WorkspaceContextNode(
                        id: windowNodeID,
                        kind: .tab,
                        title: "Window details unavailable",
                        subtitle: session.workingDirectory,
                        isPartial: true,
                        children: sorted(children),
                        action: .attachMultiplexer(kind: session.kind, sessionID: session.id)
                    )
                ]
            } else {
                windowNodes = structured.windows.map { structuredWindow in
                    windowNode(
                        structuredWindow,
                        session: session,
                        repositories: input.repositories,
                        authenticatedDestinations: input.authenticatedDestinations
                    )
                }
            }
            return WorkspaceContextNode(
                id: sessionNodeID,
                kind: .session,
                title: session.name,
                subtitle: session.kind.displayName,
                children: sorted(windowNodes),
                action: .attachMultiplexer(kind: session.kind, sessionID: session.id)
            )
        }
    }

    private func windowNode(
        _ structured: WorkspaceStructuredWindow,
        session: RemoteSession,
        repositories: [RepoSummary],
        authenticatedDestinations: Set<WorkspaceContextDestination>
    ) -> WorkspaceContextNode {
        let window = structured.window
        let windowNodeID = Self.stableID("mux-window", session.kind.rawValue, session.id, window.id)
        var children = structured.panes.map { pane in
            var paneChildren: [WorkspaceContextNode] = []
            let paneNodeID = Self.stableID("mux-pane", session.kind.rawValue, session.id, window.id, pane.id)
            if let repository = repository(matching: pane.currentPath, allowlist: repositories) {
                paneChildren.append(repositoryNode(repository, scopeID: paneNodeID))
            }
            if let tools = toolBranch(authenticatedDestinations, scopeID: paneNodeID) {
                paneChildren.append(tools)
            }
            return WorkspaceContextNode(
                id: paneNodeID,
                kind: .pane,
                title: pane.title?.trimmedNonEmpty ?? pane.currentCommand?.trimmedNonEmpty ?? "Pane \(pane.index)",
                subtitle: pane.currentPath,
                children: sorted(paneChildren),
                action: .focusMultiplexerPane(
                    kind: session.kind,
                    sessionID: session.id,
                    windowID: window.id,
                    paneID: pane.id
                )
            )
        }
        if children.isEmpty {
            if let repository = repository(matching: window.currentPath, allowlist: repositories) {
                children.append(repositoryNode(repository, scopeID: windowNodeID))
            }
            if let tools = toolBranch(authenticatedDestinations, scopeID: windowNodeID) {
                children.append(tools)
            }
        }
        return WorkspaceContextNode(
            id: windowNodeID,
            kind: .tab,
            title: window.name,
            subtitle: window.currentPath,
            children: sorted(children),
            action: .focusMultiplexerWindow(kind: session.kind, sessionID: session.id, windowID: window.id)
        )
    }

    private func agentSessionNodes(_ input: WorkspaceContextInput) -> [WorkspaceContextNode] {
        input.agentSessions.map { session in
            var children: [WorkspaceContextNode] = []
            let sessionNodeID = Self.stableID("agent-session", session.sessionID)
            if let repository = repository(matching: session.cwd, allowlist: input.repositories) {
                children.append(repositoryNode(repository, scopeID: sessionNodeID))
            }
            if let tools = toolBranch(input.authenticatedDestinations, scopeID: sessionNodeID) {
                children.append(tools)
            }
            return WorkspaceContextNode(
                id: sessionNodeID,
                kind: .session,
                title: session.title?.trimmedNonEmpty ?? session.agent.displayName,
                subtitle: session.cwd,
                children: sorted(children),
                action: .openAgentSession(sessionID: session.sessionID)
            )
        }
    }

    private func toolBranch(
        _ destinations: Set<WorkspaceContextDestination>,
        scopeID: String
    ) -> WorkspaceContextNode? {
        let actions = toolActions(destinations)
        guard !actions.isEmpty else { return nil }
        let children = actions.map { action in
            WorkspaceContextNode(
                id: Self.stableID("tool-action", scopeID, action.stableIDComponent),
                kind: .tool,
                title: action.title,
                action: .tool(action)
            )
        }
        return WorkspaceContextNode(
            id: Self.stableID("tools", scopeID),
            kind: .tool,
            title: "Tools",
            children: sorted(children)
        )
    }

    private func toolActions(_ destinations: Set<WorkspaceContextDestination>) -> [WorkspaceToolAction] {
        var actions = destinations.map(WorkspaceToolAction.navigate)
        if destinations.contains(.terminal) {
            actions.append(contentsOf: [.terminalKeys, .dictate, .search, .copyAll, .fontSmaller, .fontLarger])
        }
        return actions.sorted { $0.stableIDComponent < $1.stableIDComponent }
    }

    private func repositoryNode(_ repository: RepoSummary, scopeID: String) -> WorkspaceContextNode {
        WorkspaceContextNode(
            id: Self.stableID("repository", scopeID, Self.standardizedPath(repository.path)),
            kind: .repository,
            title: repository.name,
            subtitle: repository.branch,
            action: .openRepository(path: repository.path)
        )
    }

    private func repository(matching workingDirectory: String?, allowlist: [RepoSummary]) -> RepoSummary? {
        guard let workingDirectory = workingDirectory?.trimmedNonEmpty else { return nil }
        let directory = Self.standardizedPath(workingDirectory)
        return allowlist
            .filter { repository in
                let root = Self.standardizedPath(repository.path)
                return directory == root || directory.hasPrefix(root + "/")
            }
            .sorted { lhs, rhs in
                let lhsPath = Self.standardizedPath(lhs.path)
                let rhsPath = Self.standardizedPath(rhs.path)
                if lhsPath.count != rhsPath.count { return lhsPath.count > rhsPath.count }
                return lhsPath < rhsPath
            }
            .first
    }

    private func sorted(_ nodes: [WorkspaceContextNode]) -> [WorkspaceContextNode] {
        nodes.sorted { lhs, rhs in
            let lhsRank = Self.rank(lhs.kind)
            let rhsRank = Self.rank(rhs.kind)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.id < rhs.id
        }
    }

    private static func rank(_ kind: WorkspaceContextNode.Kind) -> Int {
        switch kind {
        case .host: 0
        case .session: 10
        case .tab: 20
        case .pane: 30
        case .repository: 40
        case .tool: 50
        case .proposal: 60
        case .more: 70
        case .switchHost: 100
        }
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Length prefixes and an explicit nil marker make semantic IDs injective even when host-provided values contain
    /// separators or happen to equal an old sentinel string.
    private static func stableID(_ namespace: String, _ components: String?...) -> String {
        ([namespace] + components.map { component in
            guard let component else { return "n" }
            return "s\(component.utf8.count):\(component)"
        }).joined(separator: "|")
    }
}

private enum MetadataKey: Hashable {
    case value(String)
    case missing

    init(_ value: String?) {
        self = value.map(Self.value) ?? .missing
    }

    var value: String? {
        guard case .value(let value) = self else { return nil }
        return value
    }
}

private struct MultiplexerSessionKey: Hashable {
    var kind: MultiplexerKind
    var id: String

    init(_ session: RemoteSession) {
        kind = session.kind
        id = session.id
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public extension WorkspaceContextGraph {
    /// Returns a new graph with deterministic proposal children. The receiver remains unchanged so a gesture can retain
    /// its frozen snapshot while newer events produce a separately rebuilt graph.
    func attaching(proposals: [ProactiveProposal]) -> WorkspaceContextGraph {
        let ranked = proposals
            .filter { $0.target.hostID == nil || $0.target.hostID == hostID }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.id < $1.id
            }

        var proposalsByNodeID: [String: [ProactiveProposal]] = [:]
        var moreByNodeID: [String: [ProactiveProposal]] = [:]
        for proposal in ranked.prefix(3) {
            let nodeID = root.bestAttachmentNodeID(for: proposal.target) ?? root.id
            proposalsByNodeID[nodeID, default: []].append(proposal)
        }
        if ranked.count > 3 {
            let remaining = Array(ranked.dropFirst(3))
            let moreTarget = ranked.first?.target ?? WorkspaceContextTarget(hostID: hostID, destination: .home)
            let moreNodeID = root.bestAttachmentNodeID(for: moreTarget) ?? root.id
            moreByNodeID[moreNodeID] = remaining
        }

        var copy = self
        copy.root = root.attaching(proposalsByNodeID, moreByNodeID: moreByNodeID)
        return copy
    }
}

private extension WorkspaceContextNode {
    func bestAttachmentNodeID(for target: WorkspaceContextTarget) -> String? {
        bestAttachmentCandidate(for: target, depth: 0, inheritedScore: 0)?.nodeID
    }

    func bestAttachmentCandidate(
        for target: WorkspaceContextTarget,
        depth: Int,
        inheritedScore: Int
    ) -> ProposalAttachmentCandidate? {
        let localScore = attachmentScore(for: target)
        let accumulatedScore = inheritedScore + localScore
        var best: ProposalAttachmentCandidate? = localScore > 0
            ? ProposalAttachmentCandidate(nodeID: id, score: accumulatedScore, depth: depth)
            : nil

        for child in children {
            guard let candidate = child.bestAttachmentCandidate(
                for: target,
                depth: depth + 1,
                inheritedScore: accumulatedScore
            ) else { continue }
            if best == nil || candidate.isPreferred(over: best!) {
                best = candidate
            }
        }
        return best
    }

    func attachmentScore(for target: WorkspaceContextTarget) -> Int {
        guard let action else { return 0 }
        switch action {
        case .openAgentSession(let sessionID):
            return target.sessionID == sessionID ? 120 : 0

        case .attachMultiplexer(_, let sessionID):
            return target.sessionID == sessionID ? 100 : 0

        case .focusMultiplexerWindow(_, let sessionID, let windowID):
            var score = target.sessionID == sessionID ? 100 : 0
            if target.tabID == windowID { score += 50 }
            return score

        case .focusMultiplexerPane(_, let sessionID, let windowID, let paneID):
            var score = target.sessionID == sessionID ? 100 : 0
            if target.tabID == windowID { score += 40 }
            if target.paneID == paneID { score += 100 }
            return score

        case .focusHerdrPane(let workspaceID, let tabID, let paneID, let terminalID):
            var score = 0
            if let targetWorkspace = target.workspaceID, targetWorkspace == workspaceID { score += 40 }
            if let targetTab = target.tabID, targetTab == tabID { score += 50 }
            if target.paneID == paneID { score += 120 }
            if let targetTerminal = target.terminalID, targetTerminal == terminalID { score += 30 }
            return score

        case .openRepository(let path):
            return target.repositoryPath == path ? 90 : 0

        case .switchHost, .openDestination, .tool, .openProposal, .showMoreProposals:
            return 0
        }
    }

    func attaching(_ proposalsByNodeID: [String: [ProactiveProposal]], moreByNodeID: [String: [ProactiveProposal]]) -> WorkspaceContextNode {
        var copy = self
        var existing = children
            .filter { $0.kind != .proposal && $0.kind != .more }
            .map { $0.attaching(proposalsByNodeID, moreByNodeID: moreByNodeID) }

        let proposals = proposalsByNodeID[id] ?? []
        let more = moreByNodeID[id] ?? []
        guard !proposals.isEmpty || !more.isEmpty else {
            copy.children = existing
            return copy
        }

        let switchHostNodes = existing.filter { $0.kind == .switchHost }
        existing.removeAll { $0.kind == .switchHost }
        existing.append(contentsOf: proposals.map { proposal in
            WorkspaceContextNode(
                id: Self.proposalNodeID(parentID: id, proposalID: proposal.id),
                kind: .proposal,
                title: proposal.title,
                subtitle: proposal.detail,
                action: .openProposal(proposal)
            )
        })
        if !more.isEmpty {
            existing.append(
                WorkspaceContextNode(
                    id: Self.moreNodeID(parentID: id),
                    kind: .more,
                    title: "More (\(more.count))",
                    subtitle: "Show remaining proposals",
                    action: .showMoreProposals(more)
                )
            )
        }
        copy.children = existing + switchHostNodes
        return copy
    }

    static func proposalNodeID(parentID: String, proposalID: String) -> String {
        "proposal-node|s\(parentID.utf8.count):\(parentID)|s\(proposalID.utf8.count):\(proposalID)"
    }

    static func moreNodeID(parentID: String) -> String {
        "proposal-more|s\(parentID.utf8.count):\(parentID)"
    }
}

private struct ProposalAttachmentCandidate {
    var nodeID: String
    var score: Int
    var depth: Int

    func isPreferred(over other: ProposalAttachmentCandidate) -> Bool {
        if score != other.score { return score > other.score }
        if depth != other.depth { return depth > other.depth }
        return nodeID < other.nodeID
    }
}
