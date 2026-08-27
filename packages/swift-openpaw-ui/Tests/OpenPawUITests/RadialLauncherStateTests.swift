import XCTest
@testable import OpenPawUI

final class RadialLauncherStateTests: XCTestCase {
    func testBeginSnapshotsGraphAndEntersTracking() {
        var state = RadialLauncherState()
        let graph = makeGraph(snapshot: "00000000-0000-0000-0000-000000000001")

        state.begin(graph: graph, at: .zero)

        XCTAssertEqual(state.phase, .tracking)
        XCTAssertEqual(state.snapshotGraph?.snapshotID, graph.snapshotID)
        XCTAssertEqual(state.origin, .zero)
        XCTAssertEqual(state.selection?.path.map(\.id), ["safe"])
    }

    func testDistanceChangesDepthAndAngleChangesSiblingSelection() {
        var state = RadialLauncherState()
        state.begin(graph: makeGraph(), at: .zero)

        state.move(to: CGPoint(x: 90, y: 0))
        XCTAssertEqual(state.selection?.path.map(\.id), ["safe", "safe-child"])

        state.move(to: CGPoint(x: -64, y: -64))
        XCTAssertEqual(state.selection?.path.map(\.id), ["caution", "caution-child"])

        state.move(to: CGPoint(x: 0, y: 90))
        XCTAssertEqual(state.selection?.path.map(\.id), ["safe", "safe-child"])
    }

    func testNestedSelectionRecomputesSiblingIndexForEachLevel() {
        var state = RadialLauncherState()
        state.begin(graph: makeUnevenNestedGraph(), at: .zero)

        state.move(to: CGPoint(x: -99, y: -99))

        XCTAssertEqual(state.selection?.path.map(\.id), ["middle", "middle-b", "middle-b-center"])
    }

    func testMovingInwardBacksUpOneLevel() {
        var state = RadialLauncherState()
        state.begin(graph: makeGraph(), at: .zero)
        state.move(to: CGPoint(x: 90, y: 0))
        XCTAssertEqual(state.selection?.path.map(\.id), ["safe", "safe-child"])

        state.move(to: CGPoint(x: 45, y: 0))

        XCTAssertEqual(state.selection?.path.map(\.id), ["safe"])
    }

    func testReturningToOriginCancels() {
        var state = RadialLauncherState()
        state.begin(graph: makeGraph(), at: .zero)
        state.move(to: CGPoint(x: 45, y: 0))

        let effect = state.move(to: CGPoint(x: 2, y: 2))

        XCTAssertEqual(effect, .cancel)
        XCTAssertEqual(state.phase, .idle)
    }

    func testFirstReleaseOnlyFreezesPreviewAndNeverDispatches() {
        var state = RadialLauncherState()
        state.begin(graph: makeGraph(), at: .zero)
        state.move(to: CGPoint(x: 45, y: 0))

        let effect = state.end()

        XCTAssertEqual(effect, .freeze)
        XCTAssertEqual(state.phase, .frozenPreview)
        XCTAssertNotNil(state.frozenProposal)
    }

    func testSecondUpwardGestureConfirmsSafeAndCautionProposals() throws {
        var safe = RadialLauncherState()
        safe.begin(graph: makeGraph(), at: .zero)
        safe.move(to: CGPoint(x: 45, y: 0))
        XCTAssertEqual(safe.end(), .freeze)

        let safeEffect = safe.confirmGesture(to: CGPoint(x: 0, y: -80))

        guard case .confirm(let safeOperationID, let safeProposal) = safeEffect else {
            return XCTFail("Expected safe confirmation")
        }
        XCTAssertEqual(safeProposal.id, "safe-proposal")
        XCTAssertFalse(safeOperationID.uuidString.isEmpty)

        var caution = RadialLauncherState()
        caution.begin(graph: makeGraph(), at: .zero)
        caution.move(to: CGPoint(x: -32, y: -32))
        XCTAssertEqual(caution.end(), .freeze)

        let cautionEffect = caution.confirmGesture(to: CGPoint(x: 0, y: -80))

        guard case .confirm(_, let cautionProposal) = cautionEffect else {
            return XCTFail("Expected caution confirmation")
        }
        XCTAssertEqual(cautionProposal.id, "caution-proposal")
    }

    func testDestructiveProposalsRejectGestureConfirmationWithoutDismissingPreview() {
        var state = RadialLauncherState()
        state.begin(graph: makeGraph(), at: .zero)
        state.move(to: CGPoint(x: -45, y: 0))
        XCTAssertEqual(state.end(), .freeze)
        XCTAssertEqual(state.frozenProposal?.risk, .destructive)

        let effect = state.confirmGesture(to: CGPoint(x: 0, y: -80))

        XCTAssertNil(effect)
        XCTAssertEqual(state.phase, .frozenPreview)
        XCTAssertEqual(state.frozenProposal?.id, "destructive-proposal")
    }

    func testExplicitButtonConfirmsDestructiveProposalExactlyOnce() {
        var state = RadialLauncherState()
        state.begin(graph: makeGraph(), at: .zero)
        state.move(to: CGPoint(x: -45, y: 0))
        XCTAssertEqual(state.end(), .freeze)
        XCTAssertEqual(state.frozenProposal?.risk, .destructive)

        let first = state.confirmExplicitly()
        let second = state.confirmExplicitly()

        guard case .confirm(let operationID, let proposal) = first else {
            return XCTFail("Expected explicit destructive confirmation")
        }
        XCTAssertEqual(proposal.id, "destructive-proposal")
        XCTAssertEqual(state.operationID, operationID)
        XCTAssertEqual(state.phase, .confirmed)
        XCTAssertNil(second)
    }

    func testAccessibleProposalSelectionFreezesPreviewBeforeExecution() {
        var state = RadialLauncherState()
        guard case .openProposal(let proposal) = makeGraph().root.children[0].action else {
            return XCTFail("Expected proposal fixture")
        }

        let effect = state.activate(.openProposal(proposal))

        XCTAssertEqual(effect, .freeze)
        XCTAssertEqual(state.phase, .frozenPreview)
        XCTAssertEqual(state.frozenProposal?.id, proposal.id)
        XCTAssertNil(state.operationID)
    }

    func testToolLeafFirstReleaseFreezesAndExplicitConfirmationPerformsExactlyOnce() {
        let action = WorkspaceContextAction.tool(.search)
        let graph = WorkspaceContextGraph(
            snapshotID: UUID(),
            hostID: nil,
            connectionGeneration: 1,
            root: WorkspaceContextNode(
                id: "root",
                kind: .host,
                title: "Root",
                children: [WorkspaceContextNode(id: "search", kind: .tool, title: "Search", action: action)]))
        var state = RadialLauncherState()
        state.begin(graph: graph, at: .zero)
        state.move(to: CGPoint(x: 45, y: 0))

        let effect = state.end()

        XCTAssertEqual(effect, .freeze)
        XCTAssertEqual(state.phase, .frozenPreview)
        XCTAssertEqual(state.frozenAction, action)
        XCTAssertNil(state.operationID)

        let firstConfirmation = state.confirmExplicitly()
        let secondConfirmation = state.confirmExplicitly()
        guard case .confirmAction(let operationID, let confirmedAction) = firstConfirmation else {
            return XCTFail("Expected typed action confirmation")
        }
        XCTAssertEqual(confirmedAction, action)
        XCTAssertEqual(state.operationID, operationID)
        XCTAssertNil(secondConfirmation)
    }

    func testAccessibleToolSelectionUsesFrozenGraphAndTheSamePreviewBoundary() {
        let action = WorkspaceContextAction.tool(.dictate)
        let node = WorkspaceContextNode(id: "dictate", kind: .tool, title: "Dictate", action: action)
        let original = WorkspaceContextGraph(
            snapshotID: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            hostID: nil,
            connectionGeneration: 1,
            root: WorkspaceContextNode(id: "root", kind: .host, title: "Root", children: [node]))
        let updated = WorkspaceContextGraph(
            snapshotID: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
            hostID: nil,
            connectionGeneration: 1,
            root: WorkspaceContextNode(id: "root", kind: .host, title: "Updated"))
        var state = RadialLauncherState()
        state.beginAccessible(graph: original)
        state.updateGraph(updated)

        let effect = state.activate(RadialSelection(node: node, path: [node], proposal: nil))

        XCTAssertEqual(effect, .freeze)
        XCTAssertEqual(state.phase, .frozenPreview)
        XCTAssertEqual(state.frozenAction, action)
        XCTAssertEqual(state.snapshotGraph?.snapshotID, original.snapshotID)
        XCTAssertEqual(state.pendingGraph?.snapshotID, updated.snapshotID)
    }

    func testBottomTrailingQuadrantMapsUpToFirstSiblingAndLeftToLastSibling() {
        let geometry = RadialGeometry()
        let origin = CGPoint(x: 350, y: 808)

        XCTAssertEqual(geometry.siblingIndex(from: origin, to: CGPoint(x: 350, y: 744), count: 3), 0)
        XCTAssertEqual(geometry.siblingIndex(from: origin, to: CGPoint(x: 305, y: 763), count: 3), 1)
        XCTAssertEqual(geometry.siblingIndex(from: origin, to: CGPoint(x: 286, y: 808), count: 3), 2)
    }

    func testGraphUpdatesDuringTrackingAreHeldForNextGesture() {
        var state = RadialLauncherState()
        let original = makeGraph(snapshot: "00000000-0000-0000-0000-000000000001", safeTitle: "Original")
        let updated = makeGraph(snapshot: "00000000-0000-0000-0000-000000000002", safeTitle: "Updated")
        state.begin(graph: original, at: .zero)

        state.updateGraph(updated)
        state.move(to: CGPoint(x: 45, y: 0))

        XCTAssertEqual(state.selection?.node.title, "Original")
        XCTAssertEqual(state.snapshotGraph?.snapshotID, original.snapshotID)
        XCTAssertEqual(state.pendingGraph?.snapshotID, updated.snapshotID)

        XCTAssertEqual(state.cancel(), .cancel)
        XCTAssertNil(state.pendingGraph)
        XCTAssertNil(state.cancel())
        state.begin(graph: original, at: .zero)
        state.move(to: CGPoint(x: 45, y: 0))
        XCTAssertEqual(state.selection?.node.title, "Updated")
    }

    func testInvalidationsCancelSafely() {
        for invalidation in [RadialLauncherInvalidation.backgrounded, .hostChanged, .pageInvalidated] {
            var state = RadialLauncherState()
            state.begin(graph: makeGraph(), at: .zero)
            state.move(to: CGPoint(x: 45, y: 0))

            let effect = state.invalidate(invalidation)

            XCTAssertEqual(effect, .cancel)
            XCTAssertEqual(state.phase, .idle)
        }
    }

    func testInvalidationDoesNotCancelAnAlreadyConfirmedOperation() {
        for invalidation in [RadialLauncherInvalidation.backgrounded, .hostChanged, .pageInvalidated] {
            var state = RadialLauncherState()
            state.begin(graph: makeGraph(), at: .zero)
            state.move(to: CGPoint(x: 45, y: 0))
            XCTAssertEqual(state.end(), .freeze)
            guard case .confirm(let operationID, _) = state.confirmGesture(to: CGPoint(x: 0, y: -80)) else {
                return XCTFail("Expected confirmed operation")
            }

            XCTAssertNil(state.invalidate(invalidation))
            XCTAssertEqual(state.phase, .confirmed)
            XCTAssertEqual(state.operationID, operationID)
            XCTAssertNotNil(state.frozenProposal)
        }
    }

    func testOperationIDsAreUniqueAndConfirmationIsIdempotent() throws {
        var first = RadialLauncherState()
        first.begin(graph: makeGraph(), at: .zero)
        first.move(to: CGPoint(x: 45, y: 0))
        XCTAssertEqual(first.end(), .freeze)

        var second = RadialLauncherState()
        second.begin(graph: makeGraph(), at: .zero)
        second.move(to: CGPoint(x: 0, y: 45))
        XCTAssertEqual(second.end(), .freeze)

        guard case .confirm(let firstID, _) = first.confirmGesture(to: CGPoint(x: 0, y: -80)) else {
            return XCTFail("Expected first confirmation")
        }
        XCTAssertNil(first.confirmGesture(to: CGPoint(x: 0, y: -80)))

        guard case .confirm(let secondID, _) = second.confirmGesture(to: CGPoint(x: 0, y: -80)) else {
            return XCTFail("Expected second confirmation")
        }
        XCTAssertNotEqual(firstID, secondID)
    }

    func testLayoutUsesFixedPublicSizes() {
        XCTAssertEqual(RadialLauncherLayout.orbVisualDiameter, 56)
        XCTAssertEqual(RadialLauncherLayout.orbHitDiameter, 64)
        XCTAssertEqual(RadialLauncherLayout.nodeVisualDiameter, 52)
        XCTAssertEqual(RadialLauncherLayout.nodeHitDiameter, 64)
    }

    private func makeGraph(
        snapshot: String = "00000000-0000-0000-0000-000000000010",
        safeTitle: String = "Safe"
    ) -> WorkspaceContextGraph {
        WorkspaceContextGraph(
            snapshotID: UUID(uuidString: snapshot)!,
            hostID: nil,
            connectionGeneration: 1,
            root: WorkspaceContextNode(
                id: "root",
                kind: .host,
                title: "Root",
                children: [
                    proposalNode(id: "safe", title: safeTitle, risk: .safe, childID: "safe-child"),
                    proposalNode(id: "caution", title: "Caution", risk: .caution, childID: "caution-child"),
                    proposalNode(id: "destructive", title: "Destructive", risk: .destructive, childID: "destructive-child"),
                ]
            )
        )
    }

    private func proposalNode(id: String, title: String, risk: ProactiveProposal.Risk, childID: String) -> WorkspaceContextNode {
        let target = WorkspaceContextTarget(destination: .home)
        let proposal = ProactiveProposal(
            id: "\(id)-proposal",
            title: title,
            detail: "Detail",
            source: .local,
            risk: risk,
            score: 100,
            target: target,
            payload: .navigate(target)
        )
        let childProposal = ProactiveProposal(
            id: "\(childID)-proposal",
            title: "\(title) Child",
            detail: "Detail",
            source: .local,
            risk: risk,
            score: 90,
            target: target,
            payload: .navigate(target)
        )
        return WorkspaceContextNode(
            id: id,
            kind: .proposal,
            title: title,
            children: [
                WorkspaceContextNode(
                    id: childID,
                    kind: .proposal,
                    title: "\(title) Child",
                    action: .openProposal(childProposal)
                )
            ],
            action: .openProposal(proposal)
        )
    }

    private func makeUnevenNestedGraph() -> WorkspaceContextGraph {
        let leaf: (String) -> WorkspaceContextNode = { id in
            WorkspaceContextNode(id: id, kind: .tool, title: id)
        }
        return WorkspaceContextGraph(
            snapshotID: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            hostID: nil,
            connectionGeneration: 1,
            root: WorkspaceContextNode(
                id: "root",
                kind: .host,
                title: "Root",
                children: [
                    WorkspaceContextNode(id: "right", kind: .session, title: "Right"),
                    WorkspaceContextNode(
                        id: "middle",
                        kind: .session,
                        title: "Middle",
                        children: [
                            WorkspaceContextNode(id: "middle-a", kind: .tab, title: "A"),
                            WorkspaceContextNode(
                                id: "middle-b",
                                kind: .tab,
                                title: "B",
                                children: [leaf("middle-b-right"), leaf("middle-b-center"), leaf("middle-b-left")]
                            ),
                        ]
                    ),
                    WorkspaceContextNode(id: "left", kind: .session, title: "Left"),
                ]
            )
        )
    }
}
