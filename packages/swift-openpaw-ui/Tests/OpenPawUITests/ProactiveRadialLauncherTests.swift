import CoreGraphics
import Foundation
import Testing
@testable import OpenPawUI

@Suite("Proactive radial launcher presentation")
struct ProactiveRadialLauncherTests {
    @Test("Orb and radial nodes keep separate visual and selection sizes")
    func controlSizes() {
        #expect(PawOrbPresentation.visualDiameter == 56)
        #expect(PawOrbPresentation.hitDiameter == 64)
        #expect(RadialNodePresentation.visualDiameter == 52)
        #expect(RadialNodePresentation.hitDiameter == 64)
    }

    @Test("Radial nodes share the bottom-trailing selection quadrant and stay on compact iPhones")
    func radialNodeGeometry() {
        let container = CGSize(width: 320, height: 568)
        let origin = CGPoint(x: 280, y: 532)
        let positions = RadialNodePresentation.positions(count: 6, origin: origin)

        #expect(positions.count == 6)
        for position in positions {
            let frame = CGRect(
                x: position.x - RadialNodePresentation.hitDiameter / 2,
                y: position.y - RadialNodePresentation.hitDiameter / 2,
                width: RadialNodePresentation.hitDiameter,
                height: RadialNodePresentation.hitDiameter)
            #expect(frame.minX >= 0)
            #expect(frame.maxX <= container.width)
            #expect(frame.minY >= 0)
            #expect(frame.maxY <= container.height)
        }
        #expect(positions.first?.x == origin.x)
        #expect(positions.last?.y == origin.y)
    }

    @Test("The second layer renders one ring spacing outside the first, on the same quadrant")
    func secondLayerRingGeometry() {
        let geometry = RadialGeometry()
        let origin = CGPoint(x: 350, y: 800)
        let first = RadialNodePresentation.positions(count: 3, origin: origin, depth: 1, geometry: geometry)
        let second = RadialNodePresentation.positions(count: 3, origin: origin, depth: 2, geometry: geometry)

        #expect(first.first?.y == origin.y - geometry.ringRadius(depth: 1))
        #expect(second.first?.y == origin.y - geometry.ringRadius(depth: 2))
        #expect(geometry.ringRadius(depth: 2) - geometry.ringRadius(depth: 1) == geometry.ringSpacing)
        // Both rings share the quadrant: straight up first, straight left last.
        #expect(second.first?.x == origin.x)
        #expect(second.last?.y == origin.y)
    }

    @Test("Drag distance selects the nearest rendered ring, so pointing at a drawn node selects its layer")
    func depthBandsFollowRenderedRings() {
        let geometry = RadialGeometry()
        let origin = CGPoint.zero

        // On the first ring itself, and anywhere inside the halfway band, the selection stays at depth 1.
        #expect(geometry.depth(from: origin, to: CGPoint(x: 0, y: -geometry.ringRadius(depth: 1))) == 1)
        // On the second ring itself the selection is depth 2.
        #expect(geometry.depth(from: origin, to: CGPoint(x: 0, y: -geometry.ringRadius(depth: 2))) == 2)
        // The band boundary sits halfway between the rings.
        let midpoint = (geometry.ringRadius(depth: 1) + geometry.ringRadius(depth: 2)) / 2
        #expect(geometry.depth(from: origin, to: CGPoint(x: 0, y: -(midpoint - 1))) == 1)
        #expect(geometry.depth(from: origin, to: CGPoint(x: 0, y: -(midpoint + 1))) == 2)
    }

    @Test("The preview card appears live once the drag reaches the second layer, and not on the first")
    func livePreviewFollowsDragDepth() {
        let geometry = RadialGeometry()
        var state = RadialLauncherState()
        state.begin(graph: Self.nestedGraph(), at: .zero)

        // First layer: arc only, no card.
        state.move(to: CGPoint(x: 0, y: -geometry.ringRadius(depth: 1)))
        #expect(state.selection?.path.count == 1)
        #expect(LauncherLivePreviewPolicy.content(for: state) == nil)

        // Second layer: the card previews the selection while the finger is still down.
        state.move(to: CGPoint(x: 0, y: -geometry.ringRadius(depth: 2)))
        #expect(state.selection?.path.count == 2)
        let live = LauncherLivePreviewPolicy.content(for: state)
        #expect(live != nil)
        #expect(live?.title == "Open home")

        // Releasing freezes: the same card remains as the confirmation surface.
        #expect(state.end() == .freeze)
        #expect(LauncherLivePreviewPolicy.content(for: state) != nil)
    }

    private static func nestedGraph() -> WorkspaceContextGraph {
        let child = WorkspaceContextNode(
            id: "child",
            kind: .tool,
            title: "Open home",
            action: .openDestination(.home)
        )
        return WorkspaceContextGraph(
            snapshotID: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
            hostID: nil,
            connectionGeneration: 1,
            root: WorkspaceContextNode(
                id: "root",
                kind: .host,
                title: "Root",
                children: [
                    WorkspaceContextNode(id: "branch", kind: .session, title: "Branch", children: [child])
                ]
            )
        )
    }

    @Test("Proposal card anchors in the upper middle between the island and keyboard")
    func proposalCardAnchor() {
        let frame = ProposalPreviewCardPresentation.frame(
            in: CGSize(width: 390, height: 844),
            safeAreaInsets: LauncherEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
            keyboardHeight: 291,
            cardSize: CGSize(width: 342, height: 220)
        )

        #expect(frame.midX == 195)
        #expect(frame.minY >= 75)
        #expect(frame.maxY <= 537)
        #expect(frame.midY < 844 / 2)
    }

    @Test("Preview card clamps tall Dynamic Type content above a compact keyboard")
    func compactDynamicTypePreview() {
        let frame = ProposalPreviewCardPresentation.frame(
            in: CGSize(width: 320, height: 568),
            safeAreaInsets: LauncherEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
            keyboardHeight: 291,
            cardSize: CGSize(width: 288, height: 360)
        )

        #expect(frame.minY >= 75)
        #expect(frame.maxY <= 261)
        #expect(frame.height <= 186)
    }

    @Test("Every launcher status carries text and a glyph as well as tone")
    func semanticStatuses() {
        let expected: [(LauncherStatus, String, String)] = [
            (.connected, "Connected", "link.circle.fill"),
            (.updating, "Updating proposals", "sparkles"),
            (.partial, "Partial context", "exclamationmark.triangle.fill"),
            (.failed, "Action failed", "xmark.octagon.fill"),
        ]

        #expect(expected.map(\.0) == LauncherStatus.allCases)
        for (status, text, glyph) in expected {
            #expect(status.text == text)
            #expect(status.glyph == glyph)
            #expect(status.tone != .clear)
        }
    }

    @Test("Reduce Motion replaces flying arcs with fade and scale")
    func reduceMotionTransitions() {
        #expect(LauncherMotionPolicy.transition(reduceMotion: false) == .flyingArc)
        #expect(LauncherMotionPolicy.transition(reduceMotion: true) == .fadeAndScale)
    }

    @Test("VoiceOver fallback preserves the frozen graph hierarchy")
    func voiceOverHierarchy() {
        let proposal = fixtureProposal(risk: .safe)
        let graph = WorkspaceContextGraph(
            snapshotID: UUID(),
            hostID: nil,
            connectionGeneration: 3,
            root: WorkspaceContextNode(
                id: "host.studio",
                kind: .host,
                title: "Studio",
                children: [
                    WorkspaceContextNode(
                        id: "session.main",
                        kind: .session,
                        title: "Main session",
                        children: [
                            WorkspaceContextNode(
                                id: "proposal.review",
                                kind: .proposal,
                                title: "Review changes",
                                action: .openProposal(proposal)
                            )
                        ]
                    )
                ]
            )
        )

        let fallback = VoiceOverLauncherModel(graph: graph)
        #expect(fallback.root.id == "host.studio")
        #expect(fallback.root.children.first?.id == "session.main")
        #expect(fallback.root.children.first?.children.first?.id == "proposal.review")
        #expect(fallback.root.children.first?.children.first?.spokenDetail.contains("Safe") == true)
        #expect(fallback.root.children.first?.children.first?.spokenDetail.contains(proposal.detail) == true)
    }

    @Test("VoiceOver exposes both a branch action and its children")
    func voiceOverBranchActions() {
        let branch = WorkspaceContextNode(
            id: "session.main",
            kind: .session,
            title: "Main session",
            children: [WorkspaceContextNode(id: "tab.one", kind: .tab, title: "Tab one")],
            action: .openAgentSession(sessionID: "main"))
        let model = VoiceOverLauncherModel(graph: WorkspaceContextGraph(
            snapshotID: UUID(),
            hostID: nil,
            connectionGeneration: 1,
            root: WorkspaceContextNode(id: "root", kind: .host, title: "Root", children: [branch])))

        #expect(model.root.children.first?.rowRoles == [.action, .disclosure])
    }

    @Test("Ordinary typed actions receive a complete safe preview")
    func typedActionPreview() {
        let node = WorkspaceContextNode(
            id: "tool.search",
            kind: .tool,
            title: "Search scrollback",
            subtitle: "Find terminal output",
            action: .tool(.search))
        let content = LauncherPreviewContent(selection: RadialSelection(node: node, path: [node], proposal: nil))

        #expect(content?.title == "Search scrollback")
        #expect(content?.detail == "Find terminal output")
        #expect(content?.risk == .safe)
        #expect(content?.actionTitle == "Confirm action")
    }

    @Test("Destructive previews disable gesture confirmation and name an explicit destructive action")
    func destructiveConfirmation() {
        let safe = ProposalConfirmationPresentation(proposal: fixtureProposal(risk: .safe))
        #expect(safe.allowsGestureConfirmation)
        #expect(safe.actionTitle == "Confirm action")

        let destructive = ProposalConfirmationPresentation(proposal: fixtureProposal(risk: .destructive))
        #expect(!destructive.allowsGestureConfirmation)
        #expect(destructive.actionTitle == "Open Terminal to confirm destructive command")
        #expect(destructive.accessibilityIdentifier == "root.proactive-launcher.destructive-confirm")
    }
}

private func fixtureProposal(risk: ProactiveProposal.Risk) -> ProactiveProposal {
    ProactiveProposal(
        id: "review",
        title: "Review changes",
        detail: "Review the working tree before continuing.",
        source: .local,
        risk: risk,
        score: 100,
        target: WorkspaceContextTarget(destination: .repository, repositoryPath: "/work/openpaw"),
        payload: .navigate(WorkspaceContextTarget(destination: .repository, repositoryPath: "/work/openpaw"))
    )
}
