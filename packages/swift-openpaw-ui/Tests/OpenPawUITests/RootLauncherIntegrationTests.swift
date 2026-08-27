import Foundation
import Testing
import OpenPawProtocol
import OpenPawTerminalCore
@testable import OpenPawUI

/// Task 8: the launcher is wired into the root, so the mapping from root state to graph input and from
/// confirmed launcher actions to app routes is behaviour the root owns and must hold.
@Suite("Root launcher integration")
struct RootLauncherIntegrationTests {

    // MARK: Graph input

    /// A disconnected phone can still reach Home and Settings through the launcher; everything else needs a
    /// live host. Offering the terminal to a phone with no connection is a branch that dead-ends.
    @Test("disconnected state authenticates only home and settings")
    func disconnectedDestinations() {
        #expect(RootLauncherIntegration.authenticatedDestinations(isConnected: false) == [.home, .settings])
        #expect(RootLauncherIntegration.authenticatedDestinations(isConnected: true).contains(.terminal))
        #expect(RootLauncherIntegration.authenticatedDestinations(isConnected: true).count == 6)
    }

    /// Every shell destination round-trips through the context destination and back. A destination that maps
    /// one way but not the other is a launcher branch that navigates somewhere it cannot describe.
    @Test("shell and context destinations round-trip")
    func destinationRoundTrip() {
        for destination in ShellDestination.allCases {
            let context = RootLauncherIntegration.contextDestination(for: destination)
            #expect(RootLauncherIntegration.shellDestination(for: context) == destination)
        }
    }

    // MARK: Confirmed action routing

    @Test("destination confirmation becomes navigation")
    func destinationRoute() {
        let route = RootLauncherIntegration.route(
            for: .openDestination(.terminal), operationID: UUID())
        #expect(route == .navigate(.terminal))
    }

    @Test("switch host confirmation opens host management")
    func switchHostRoute() {
        #expect(RootLauncherIntegration.route(for: .switchHost, operationID: UUID()) == .switchHost)
    }

    @Test("multiplexer session confirmation becomes an attach")
    func attachRoute() {
        let route = RootLauncherIntegration.route(
            for: .attachMultiplexer(kind: .tmux, sessionID: "main"), operationID: UUID())
        #expect(route == .attach(.target("main", kind: .tmux)))
    }

    /// tmux pane focus attaches the session rather than failing: the multiplexer restores its own active pane,
    /// so attaching is the deepest reliable step and never a dead end.
    @Test("pane focus falls back to session attach")
    func paneRoute() {
        let route = RootLauncherIntegration.route(
            for: .focusMultiplexerPane(kind: .tmux, sessionID: "main", windowID: "1", paneID: "%2"),
            operationID: UUID())
        #expect(route == .attach(.target("main", kind: .tmux)))
    }

    /// Herdr panes carry the terminal transport handle; dropping it would make the attach unroutable.
    @Test("herdr pane focus keeps the terminal ID")
    func herdrPaneRoute() {
        let route = RootLauncherIntegration.route(
            for: .focusHerdrPane(workspaceID: "ws", tabID: "tab", paneID: "pane", terminalID: "term-9"),
            operationID: UUID())
        guard case .attach(let session) = route else {
            Issue.record("expected attach, got \(route)")
            return
        }
        #expect(session.kind == .herdr)
        #expect(session.terminalID == "term-9")
        #expect(session.workspaceID == "ws")
        #expect(session.tabID == "tab")
    }

    @Test("tool confirmation carries the tool through")
    func toolRoute() {
        let route = RootLauncherIntegration.route(for: .tool(.fontLarger), operationID: UUID())
        #expect(route == .tool(.fontLarger))
    }

    /// Confirming the "more proposals" node executes the best remaining proposal rather than doing nothing:
    /// a confirmed gesture that has no effect teaches the user the launcher cannot be trusted.
    @Test("more-proposals confirmation executes the best proposal")
    func moreProposalsRoute() {
        let operationID = UUID()
        let best = ProactiveProposal(
            id: "p1", title: "Best", detail: "", source: .local, risk: .safe, score: 90,
            target: WorkspaceContextTarget(), payload: .terminalCommand("ls"))
        let route = RootLauncherIntegration.route(
            for: .showMoreProposals([best]), operationID: operationID)
        #expect(route == .executeProposal(best, operationID: operationID))
        #expect(RootLauncherIntegration.route(for: .showMoreProposals([]), operationID: operationID) == .none)
    }

    // MARK: Window selection

    /// The follow-up command after attaching for a window focus. Only multiplexers with an addressable window
    /// command get one; anything else must stay silent rather than typing garbage into a shell.
    @Test("window selection commands are shaped per multiplexer")
    @MainActor
    func windowSelection() {
        #expect(RootView.windowSelectionCommand(kind: .tmux, windowID: "@3")
            == "tmux select-window -t '@3'\n")
        #expect(RootView.windowSelectionCommand(kind: .zellij, windowID: "editor")
            == "zellij action go-to-tab-name 'editor'\n")
        #expect(RootView.windowSelectionCommand(kind: .herdr, windowID: "x").isEmpty)
        #expect(RootView.windowSelectionCommand(kind: .screen, windowID: "x").isEmpty)
    }

    // MARK: Execution context

    /// The execution context mirrors the proposal's target session, not the UI selection: the ownership check
    /// must fail when the world moved, not when the user is reading a different screen while confirming.
    @Test("execution context tracks the target, not the UI selection")
    @MainActor
    func executionContextTracksTarget() {
        let model = OpenPawModel()
        let graph = WorkspaceContextGraphBuilder().build(
            WorkspaceContextInput(snapshotID: UUID(), host: nil, connectionGeneration: 3, destination: .home))
        var target = WorkspaceContextTarget()
        target.sessionID = "agent-1"
        target.tabID = "tab-2"
        let context = RootLauncherIntegration.executionContext(model: model, graph: graph, target: target)
        #expect(context.selectedSessionID == "agent-1")
        #expect(context.selectedTabID == "tab-2")
        #expect(context.graphSnapshotID == graph.snapshotID)
    }
}
