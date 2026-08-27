import XCTest
import OpenPawProtocol
import OpenPawTerminalCore
@testable import OpenPawUI

final class WorkspaceContextGraphTests: XCTestCase {
    private let hostID = UUID(uuidString: "12345678-1234-1234-1234-1234567890ab")!
    private let snapshotID = UUID(uuidString: "abcdefab-cdef-abcd-efab-cdefabcdefab")!

    func testHerdrBuildsHostWorkspaceTabPaneRepoHierarchyAndSwitchHostEdge() throws {
        let pane = RemoteSession(
            id: "pane-7",
            name: "implementation",
            kind: .herdr,
            terminalID: "terminal-7",
            workspaceID: "workspace-openpaw",
            tabID: "tab-code",
            tabLabel: "Code",
            workingDirectory: "/Users/dev/openpaw/packages/swift-openpaw-ui"
        )
        let input = makeInput(
            sessionSpace: .init(hostID: hostID, connectionGeneration: 4, remoteSessions: [pane]),
            repositories: [repo(name: "openpaw", path: "/Users/dev/openpaw")]
        )

        let graph = WorkspaceContextGraphBuilder().build(input)

        XCTAssertEqual(graph.hostID, hostID)
        XCTAssertEqual(graph.connectionGeneration, 4)
        XCTAssertEqual(graph.root.kind, .host)
        XCTAssertEqual(graph.root.title, "Work Mac")

        let workspace = try XCTUnwrap(graph.root.children.first { $0.kind == .session && $0.title == "workspace-openpaw" })
        XCTAssertEqual(workspace.kind, .session)
        let tab = try XCTUnwrap(workspace.children.first { $0.kind == .tab && $0.title == "Code" })
        XCTAssertEqual(tab.kind, .tab)
        XCTAssertEqual(tab.title, "Code")
        let paneNode = try XCTUnwrap(tab.children.first { $0.kind == .pane && $0.title == "implementation" })
        XCTAssertEqual(paneNode.kind, .pane)
        XCTAssertEqual(paneNode.action, .focusHerdrPane(workspaceID: "workspace-openpaw", tabID: "tab-code", paneID: "pane-7", terminalID: "terminal-7"))
        let repository = try XCTUnwrap(paneNode.children.first { $0.kind == .repository })
        XCTAssertEqual(repository.title, "openpaw")
        XCTAssertEqual(repository.action, .openRepository(path: "/Users/dev/openpaw"))
        XCTAssertEqual(graph.root.children.last?.kind, .switchHost)
        XCTAssertEqual(graph.root.children.last?.action, .switchHost)
    }

    func testTmuxZellijAndScreenGroupUnderSessionAndWindowWithSyntheticFallback() throws {
        let tmux = RemoteSession(id: "$1", name: "api", kind: .tmux, windowCount: 1)
        let tmuxWindow = RemoteWindow(id: "@8", sessionID: "$1", index: 0, name: "server", currentCommand: "swift", currentPath: "/work/openpaw")
        let tmuxPane = RemotePane(id: "%3", windowID: "@8", index: 0, isActive: true, width: 100, height: 30, currentCommand: "swift", currentPath: "/work/openpaw")
        let zellij = RemoteSession(id: "z-1", name: "docs", kind: .zellij, windowCount: 0, workingDirectory: "/work/docs")
        let screen = RemoteSession(id: "31183.agent", name: "agent", kind: .screen, windowCount: 0)
        let input = makeInput(
            structuredSessions: [
                .init(session: tmux, windows: [.init(window: tmuxWindow, panes: [tmuxPane])]),
                .init(session: zellij),
                .init(session: screen),
            ],
            sessionSpace: .init(hostID: hostID, connectionGeneration: 4, remoteSessions: [tmux, zellij, screen]),
            repositories: [repo(name: "openpaw", path: "/work/openpaw"), repo(name: "docs", path: "/work/docs")]
        )

        let graph = WorkspaceContextGraphBuilder().build(input)

        let tmuxSession = try XCTUnwrap(graph.root.children.first { $0.kind == .session && $0.title == "api" })
        let realWindow = try XCTUnwrap(tmuxSession.children.first { $0.kind == .tab && $0.title == "server" })
        XCTAssertFalse(realWindow.isPartial)
        let realPane = try XCTUnwrap(realWindow.children.first { $0.kind == .pane })
        XCTAssertTrue(realPane.children.contains { $0.kind == .repository && $0.title == "openpaw" })

        for (kind, id) in [(MultiplexerKind.zellij, "z-1"), (.screen, "31183.agent")] {
            let session = try XCTUnwrap(graph.root.children.first {
                $0.action == .attachMultiplexer(kind: kind, sessionID: id)
            })
            let syntheticTab = try XCTUnwrap(session.children.first)
            XCTAssertEqual(syntheticTab.kind, .tab)
            XCTAssertTrue(syntheticTab.isPartial)
            XCTAssertEqual(syntheticTab.title, "Window details unavailable")
        }
    }

    func testWorkingDirectoryAssociatesOnlyWithAllowlistedRepositoryAtPathBoundary() throws {
        let exact = RemoteSession(id: "pane-exact", name: "exact", kind: .herdr, workspaceID: "w", tabID: "t", workingDirectory: "/work/openpaw")
        let child = RemoteSession(id: "pane-child", name: "child", kind: .herdr, workspaceID: "w", tabID: "t", workingDirectory: "/work/openpaw/Sources")
        let lookalike = RemoteSession(id: "pane-lookalike", name: "lookalike", kind: .herdr, workspaceID: "w", tabID: "t", workingDirectory: "/work/openpaw-private")
        let unknown = RemoteSession(id: "pane-unknown", name: "unknown", kind: .herdr, workspaceID: "w", tabID: "t", workingDirectory: "/private/tmp/openpaw")
        let input = makeInput(
            sessionSpace: .init(hostID: hostID, connectionGeneration: 4, remoteSessions: [exact, child, lookalike, unknown]),
            repositories: [repo(name: "openpaw", path: "/work/openpaw")]
        )

        let panes = WorkspaceContextGraphBuilder().build(input).root.descendants.filter { $0.kind == .pane }

        XCTAssertEqual(
            Set(panes.filter { $0.children.contains(where: { $0.kind == .repository }) }.map(\.title)),
            ["exact", "child"]
        )
    }

    func testStableIDsAndOrderingDoNotDependOnSourceArrayOrder() {
        let first = RemoteSession(id: "pane-a", name: "A", kind: .herdr, workspaceID: "workspace-b", tabID: "tab-2")
        let second = RemoteSession(id: "pane-b", name: "B", kind: .herdr, workspaceID: "workspace-a", tabID: "tab-1")
        let repos = [repo(name: "z", path: "/work/z"), repo(name: "a", path: "/work/a")]
        let forward = makeInput(
            sessionSpace: .init(hostID: hostID, connectionGeneration: 4, remoteSessions: [first, second]),
            repositories: repos
        )
        let reversed = makeInput(
            sessionSpace: .init(hostID: hostID, connectionGeneration: 4, remoteSessions: [second, first]),
            repositories: repos.reversed()
        )

        let lhs = WorkspaceContextGraphBuilder().build(forward)
        let rhs = WorkspaceContextGraphBuilder().build(reversed)

        XCTAssertEqual(lhs.root, rhs.root)
        XCTAssertEqual(lhs.root.descendants.map(\.id), rhs.root.descendants.map(\.id))
    }

    func testMissingHerdrMetadataCreatesPartialSyntheticNodesWithoutInventingLabels() throws {
        let incomplete = RemoteSession(id: "pane-orphan", name: "shell", kind: .herdr, terminalID: "terminal-orphan")
        let graph = WorkspaceContextGraphBuilder().build(
            makeInput(sessionSpace: .init(hostID: hostID, connectionGeneration: 4, remoteSessions: [incomplete]))
        )

        let workspace = try XCTUnwrap(graph.root.children.first { $0.kind == .session })
        XCTAssertTrue(workspace.isPartial)
        XCTAssertEqual(workspace.title, "Unknown Herdr workspace")
        let tab = try XCTUnwrap(workspace.children.first { $0.kind == .tab })
        XCTAssertTrue(tab.isPartial)
        XCTAssertEqual(tab.title, "Unknown Herdr tab")
        XCTAssertFalse(workspace.title.contains("pane-orphan"))
        XCTAssertFalse(tab.title.contains("pane-orphan"))
    }

    func testEveryAuthenticatedDestinationContributesContextualToolsUnderThePane() throws {
        let pane = RemoteSession(id: "pane-tools", name: "shell", kind: .herdr, workspaceID: "workspace", tabID: "tab")
        let graph = WorkspaceContextGraphBuilder().build(
            makeInput(
                sessionSpace: .init(hostID: hostID, connectionGeneration: 4, remoteSessions: [pane]),
                authenticatedDestinations: [.sessions, .repository, .terminal, .inbox]
            )
        )
        let paneNode = try XCTUnwrap(graph.root.descendants.first { $0.kind == .pane })
        let tools = try XCTUnwrap(paneNode.children.first { $0.kind == .tool && $0.title == "Tools" })
        let actions = Set(tools.descendants.compactMap { node -> WorkspaceToolAction? in
            guard case .tool(let action) = node.action else { return nil }
            return action
        })

        let destinations = Set(actions.compactMap { action -> WorkspaceContextDestination? in
            guard case .navigate(let destination) = action else { return nil }
            return destination
        })
        XCTAssertEqual(destinations, [.sessions, .repository, .terminal, .inbox])
        XCTAssertTrue(actions.isSuperset(of: [.terminalKeys, .dictate, .search, .copyAll, .fontSmaller, .fontLarger]))
        XCTAssertFalse(graph.root.children.contains { $0.kind == .tool })
    }

    func testStaleSessionSpaceDoesNotCreateCurrentRemoteActions() {
        let staleHostID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let stalePane = RemoteSession(id: "stale-pane", name: "stale", kind: .herdr, workspaceID: "old", tabID: "old")
        let graph = WorkspaceContextGraphBuilder().build(
            makeInput(sessionSpace: .init(hostID: staleHostID, connectionGeneration: 3, remoteSessions: [stalePane]))
        )

        XCTAssertEqual(graph.hostID, hostID)
        XCTAssertEqual(graph.connectionGeneration, 4)
        XCTAssertFalse(graph.root.descendants.contains { node in
            if case .focusHerdrPane = node.action { return true }
            if case .attachMultiplexer = node.action { return true }
            return false
        })
        XCTAssertFalse(graph.root.children.contains { $0.kind == .session })
    }

    func testStableIDsCannotCollideWithSeparatorsOrFormerPartialSentinelValues() {
        let sessions = [
            RemoteSession(id: "pane:one", name: "one", kind: .herdr, workspaceID: "a:b", tabID: "c"),
            RemoteSession(id: "pane", name: "two", kind: .herdr, workspaceID: "a", tabID: "b:c"),
            RemoteSession(id: "literal", name: "literal", kind: .herdr, workspaceID: "__partial__", tabID: "__partial__"),
            RemoteSession(id: "missing", name: "missing", kind: .herdr),
        ]
        let input = makeInput(sessionSpace: .init(hostID: hostID, connectionGeneration: 4, remoteSessions: sessions))

        let forward = WorkspaceContextGraphBuilder().build(input)
        var reversedInput = input
        reversedInput.sessionSpace.remoteSessions.reverse()
        let reversed = WorkspaceContextGraphBuilder().build(reversedInput)
        let ids = forward.root.descendants.map(\.id)

        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(forward.root, reversed.root)
        XCTAssertEqual(forward.root.children.filter { $0.kind == .session }.count, 4)
        XCTAssertTrue(forward.root.children.contains { $0.title == "__partial__" && !$0.isPartial })
        XCTAssertTrue(forward.root.children.contains { $0.title == "Unknown Herdr workspace" && $0.isPartial })
    }

    private func makeInput(
        structuredSessions: [WorkspaceStructuredSession] = [],
        sessionSpace: SessionSpaceSnapshot? = nil,
        repositories: [RepoSummary] = [],
        authenticatedDestinations: Set<WorkspaceContextDestination> = []
    ) -> WorkspaceContextInput {
        WorkspaceContextInput(
            snapshotID: snapshotID,
            host: .init(id: hostID, title: "Work Mac"),
            connectionGeneration: 4,
            destination: .terminal,
            structuredSessions: structuredSessions,
            sessionSpace: sessionSpace ?? .init(hostID: hostID, connectionGeneration: 4),
            repositories: repositories,
            authenticatedDestinations: authenticatedDestinations
        )
    }

    private func repo(name: String, path: String) -> RepoSummary {
        RepoSummary(name: name, path: path, branch: "main", dirty: false, ahead: 0, behind: 0)
    }
}
