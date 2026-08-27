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
    case accessibleBrowsing
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
    case confirmAction(UUID, WorkspaceContextAction)
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

    /// Maps a drag point to a sibling slot in the bottom-trailing quadrant. Index 0 sits straight up from the
    /// origin and the last index sits straight left, matching `nodePosition` so the rendered ring and the touch
    /// mapping can never diverge. Drags outside the quadrant clamp to the nearest edge slot.
    public func siblingIndex(from origin: CGPoint, to point: CGPoint, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1 else { return 0 }

        let dx = point.x - origin.x
        let dy = origin.y - point.y
        var angle = atan2(dy, dx)
        if angle < -.pi / 2 { angle = .pi }
        let normalized = min(.pi, max(.pi / 2, angle))
        let fraction = (normalized - .pi / 2) / (.pi / 2)
        let slot = Int((fraction * CGFloat(count - 1)).rounded())
        return min(count - 1, max(0, slot))
    }

    /// The rendered position for a sibling slot, sharing the exact quadrant `siblingIndex` reads. Values are
    /// rounded to hundredths of a point so the quadrant endpoints land exactly on the origin axes.
    public func nodePosition(index: Int, count: Int, origin: CGPoint, radius: CGFloat) -> CGPoint {
        let fraction = count <= 1 ? 0 : CGFloat(index) / CGFloat(count - 1)
        let angle = CGFloat.pi / 2 + fraction * (CGFloat.pi / 2)
        let x = origin.x + cos(angle) * radius
        let y = origin.y - sin(angle) * radius
        return CGPoint(x: (x * 100).rounded() / 100, y: (y * 100).rounded() / 100)
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
    public private(set) var frozenAction: WorkspaceContextAction?
    public private(set) var operationID: UUID?

    public var geometry: RadialGeometry

    public init(geometry: RadialGeometry = RadialGeometry()) {
        self.phase = .idle
        self.origin = nil
        self.snapshotGraph = nil
        self.pendingGraph = nil
        self.selection = nil
        self.frozenProposal = nil
        self.frozenAction = nil
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
        frozenAction = nil
        operationID = nil
        selection = selection(in: startingGraph, from: point, to: point)
    }

    /// Opens a non-gesture browsing session over the same frozen snapshot the radial gesture would use. Graph
    /// updates that arrive while the accessible hierarchy is open are held in `pendingGraph`, exactly like updates
    /// during a drag, so rows never move mid-interaction.
    public mutating func beginAccessible(graph: WorkspaceContextGraph) {
        let startingGraph = snapshotGraph ?? graph
        phase = .accessibleBrowsing
        origin = nil
        snapshotGraph = startingGraph
        pendingGraph = nil
        selection = nil
        frozenProposal = nil
        frozenAction = nil
        operationID = nil
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

    /// The first release never dispatches. Proposals and ordinary typed actions both freeze into the preview,
    /// where a second confirmation gesture or the explicit button is the only dispatch path. Releasing on a node
    /// with no action cancels rather than stranding the launcher.
    @discardableResult
    public mutating func end() -> RadialLauncherEffect? {
        guard phase == .tracking else { return nil }
        if let proposal = selection?.proposal {
            frozenProposal = proposal
            phase = .frozenPreview
            return .freeze
        }
        if let action = selection?.node.action {
            frozenAction = action
            phase = .frozenPreview
            return .freeze
        }
        return cancel()
    }

    /// Freezes a proposal selected through a non-gesture interface, such as the VoiceOver hierarchy. Selection never
    /// executes immediately; the same preview and explicit confirmation boundary remains in force.
    @discardableResult
    public mutating func freezePreview(_ proposal: ProactiveProposal) -> RadialLauncherEffect? {
        guard phase != .confirmed, operationID == nil else { return nil }
        selection = nil
        frozenProposal = proposal
        frozenAction = nil
        phase = .frozenPreview
        return .freeze
    }

    /// Freezes the same preview boundary for a selection made through a non-gesture interface such as the
    /// accessible hierarchy. Nothing executes on activation; confirmation is the only dispatch path, identical to
    /// the gesture flow.
    @discardableResult
    public mutating func activate(_ selection: RadialSelection) -> RadialLauncherEffect? {
        guard phase != .confirmed, operationID == nil else { return nil }
        if let proposal = selection.proposal ?? selection.node.proposal {
            self.selection = selection
            frozenProposal = proposal
            frozenAction = nil
            phase = .frozenPreview
            return .freeze
        }
        if let action = selection.node.action {
            self.selection = selection
            frozenProposal = nil
            frozenAction = action
            phase = .frozenPreview
            return .freeze
        }
        return nil
    }

    /// Convenience for callers that only hold a typed action. The preview boundary is identical: proposals and
    /// ordinary actions freeze, and nothing dispatches until an explicit confirmation.
    @discardableResult
    public mutating func activate(_ action: WorkspaceContextAction) -> RadialLauncherEffect? {
        guard phase != .confirmed, operationID == nil else { return nil }
        if case .openProposal(let proposal) = action {
            return freezePreview(proposal)
        }
        selection = nil
        frozenProposal = nil
        frozenAction = action
        phase = .frozenPreview
        return .freeze
    }

    @discardableResult
    public mutating func confirmGesture(to point: CGPoint) -> RadialLauncherEffect? {
        guard phase == .frozenPreview, operationID == nil, let origin else { return nil }
        guard geometry.isUpwardConfirmation(point, origin: origin) else { return nil }
        if let proposal = frozenProposal {
            guard proposal.risk != .destructive else { return nil }
            return confirm(proposal)
        }
        if let action = frozenAction {
            return confirm(action)
        }
        return nil
    }

    /// Explicit confirmation is required for destructive proposals and is also available as the accessible button path.
    /// The operation ID is stored before returning so repeated taps cannot create multiple dispatches.
    @discardableResult
    public mutating func confirmExplicitly() -> RadialLauncherEffect? {
        guard phase == .frozenPreview, operationID == nil else { return nil }
        if let proposal = frozenProposal {
            return confirm(proposal)
        }
        if let action = frozenAction {
            return confirm(action)
        }
        return nil
    }

    public mutating func updateGraph(_ graph: WorkspaceContextGraph) {
        switch phase {
        case .idle:
            snapshotGraph = graph
        case .tracking, .accessibleBrowsing, .frozenPreview, .confirmed:
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
        let hadActiveState = phase != .idle || origin != nil || selection != nil || frozenProposal != nil
            || frozenAction != nil || operationID != nil
        guard hadActiveState else { return nil }
        resetToIdle()
        return .cancel
    }

    private mutating func resetToIdle() {
        let promotedGraph = pendingGraph
        phase = .idle
        origin = nil
        snapshotGraph = promotedGraph
        pendingGraph = nil
        selection = nil
        frozenProposal = nil
        frozenAction = nil
        operationID = nil
    }

    private mutating func confirm(_ proposal: ProactiveProposal) -> RadialLauncherEffect {
        let id = UUID()
        operationID = id
        phase = .confirmed
        return .confirm(id, proposal)
    }

    private mutating func confirm(_ action: WorkspaceContextAction) -> RadialLauncherEffect {
        let id = UUID()
        operationID = id
        phase = .confirmed
        return .confirmAction(id, action)
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
