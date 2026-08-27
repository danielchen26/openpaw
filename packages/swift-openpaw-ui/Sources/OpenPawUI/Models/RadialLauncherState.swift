import CoreGraphics
import Foundation

public enum RadialLauncherLayout {
    public static let orbVisualDiameter: CGFloat = 56
    public static let orbHitDiameter: CGFloat = 64
    public static let nodeVisualDiameter: CGFloat = 52
    public static let nodeHitDiameter: CGFloat = 64
}

public enum RadialLauncherPhase: Sendable, Hashable {
    case idle
    case tracking
    case frozenPreview
    case confirmed
}

public struct RadialSelection: Sendable, Hashable {
    public var node: WorkspaceContextNode
    public var path: [WorkspaceContextNode]
    public var proposal: ProactiveProposal?

    public init(node: WorkspaceContextNode, path: [WorkspaceContextNode], proposal: ProactiveProposal?) {
        self.node = node
        self.path = path
        self.proposal = proposal
    }
}

public enum RadialLauncherInvalidation: Sendable, Hashable {
    case backgrounded
    case hostChanged
    case pageInvalidated
}

public enum RadialLauncherEffect: Sendable, Hashable {
    case freeze
    case confirm(UUID, ProactiveProposal)
    case cancel
}

public struct RadialGeometry: Sendable, Hashable {
    public var originCancelRadius: CGFloat
    public var depthStep: CGFloat
    public var confirmationDistance: CGFloat

    public init(originCancelRadius: CGFloat = 8, depthStep: CGFloat = 64, confirmationDistance: CGFloat = 56) {
        self.originCancelRadius = originCancelRadius
        self.depthStep = depthStep
        self.confirmationDistance = confirmationDistance
    }

    public func distance(from origin: CGPoint, to point: CGPoint) -> CGFloat {
        hypot(point.x - origin.x, point.y - origin.y)
    }

    public func depth(from origin: CGPoint, to point: CGPoint) -> Int {
        max(1, Int(distance(from: origin, to: point) / depthStep) + 1)
    }

    public func siblingIndex(from origin: CGPoint, to point: CGPoint, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1 else { return 0 }

        let dx = point.x - origin.x
        let dy = origin.y - point.y
        let angle = atan2(dy, dx)
        let halfCircleSlots = CGFloat(count - 1)
        let normalized = max(0, min(CGFloat.pi, angle))
        let slot = Int((normalized / CGFloat.pi * halfCircleSlots).rounded())
        return min(count - 1, max(0, slot))
    }

    public func isAtOrigin(_ point: CGPoint, origin: CGPoint) -> Bool {
        distance(from: origin, to: point) <= originCancelRadius
    }

    public func isUpwardConfirmation(_ point: CGPoint, origin: CGPoint) -> Bool {
        origin.y - point.y >= confirmationDistance && abs(point.x - origin.x) <= confirmationDistance
    }
}

public struct RadialLauncherState: Sendable, Hashable {
    public private(set) var phase: RadialLauncherPhase
    public private(set) var origin: CGPoint?
    public private(set) var snapshotGraph: WorkspaceContextGraph?
    public private(set) var pendingGraph: WorkspaceContextGraph?
    public private(set) var selection: RadialSelection?
    public private(set) var frozenProposal: ProactiveProposal?
    public private(set) var operationID: UUID?

    public var geometry: RadialGeometry

    public init(geometry: RadialGeometry = RadialGeometry()) {
        self.phase = .idle
        self.origin = nil
        self.snapshotGraph = nil
        self.pendingGraph = nil
        self.selection = nil
        self.frozenProposal = nil
        self.operationID = nil
        self.geometry = geometry
    }

    public mutating func begin(graph: WorkspaceContextGraph, at point: CGPoint) {
        let startingGraph = snapshotGraph ?? graph
        phase = .tracking
        origin = point
        snapshotGraph = startingGraph
        pendingGraph = nil
        frozenProposal = nil
        operationID = nil
        selection = selection(in: startingGraph, from: point, to: point)
    }

    @discardableResult
    public mutating func move(to point: CGPoint) -> RadialLauncherEffect? {
        guard phase == .tracking, let origin, let graph = snapshotGraph else { return nil }
        if geometry.isAtOrigin(point, origin: origin) {
            return cancel()
        }
        selection = selection(in: graph, from: origin, to: point)
        return nil
    }

    @discardableResult
    public mutating func end() -> RadialLauncherEffect? {
        guard phase == .tracking else { return nil }
        frozenProposal = selection?.proposal
        phase = .frozenPreview
        return .freeze
    }

    @discardableResult
    public mutating func confirmGesture(to point: CGPoint) -> RadialLauncherEffect? {
        guard phase == .frozenPreview, operationID == nil, let origin, let proposal = frozenProposal else { return nil }
        guard geometry.isUpwardConfirmation(point, origin: origin) else { return nil }
        guard proposal.risk != .destructive else { return nil }

        let id = UUID()
        operationID = id
        phase = .confirmed
        return .confirm(id, proposal)
    }

    public mutating func updateGraph(_ graph: WorkspaceContextGraph) {
        switch phase {
        case .idle:
            snapshotGraph = graph
        case .tracking, .frozenPreview, .confirmed:
            pendingGraph = graph
        }
    }

    @discardableResult
    public mutating func invalidate(_ invalidation: RadialLauncherInvalidation) -> RadialLauncherEffect? {
        guard phase != .confirmed || operationID == nil else { return nil }
        return cancel()
    }

    @discardableResult
    public mutating func cancel() -> RadialLauncherEffect? {
        let hadActiveState = phase != .idle || origin != nil || selection != nil || frozenProposal != nil || operationID != nil
        guard hadActiveState else { return nil }
        let promotedGraph = pendingGraph
        phase = .idle
        origin = nil
        snapshotGraph = promotedGraph
        pendingGraph = nil
        selection = nil
        frozenProposal = nil
        operationID = nil
        return .cancel
    }

    private func selection(in graph: WorkspaceContextGraph, from origin: CGPoint, to point: CGPoint) -> RadialSelection? {
        var siblings = graph.root.children
        guard let initialIndex = geometry.siblingIndex(from: origin, to: point, count: siblings.count) else { return nil }
        var node = siblings[initialIndex]
        var path = [node]
        let targetDepth = geometry.depth(from: origin, to: point)

        if targetDepth > 1 {
            for _ in 1..<targetDepth {
                siblings = node.children
                guard !siblings.isEmpty else { break }
                guard let nextIndex = geometry.siblingIndex(from: origin, to: point, count: siblings.count) else { break }
                node = siblings[nextIndex]
                path.append(node)
            }
        }

        return RadialSelection(node: node, path: path, proposal: node.proposal)
    }
}

private extension WorkspaceContextNode {
    var proposal: ProactiveProposal? {
        if case .openProposal(let proposal) = action {
            return proposal
        }
        return nil
    }
}
