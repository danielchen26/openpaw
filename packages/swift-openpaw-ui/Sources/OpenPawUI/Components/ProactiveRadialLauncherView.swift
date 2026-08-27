import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public enum VoiceOverRowRole: Sendable, Hashable {
    case action
    case disclosure
}

public struct VoiceOverLauncherNode: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let spokenDetail: String
    public let children: [VoiceOverLauncherNode]
    public let action: WorkspaceContextAction?
    /// Which rows this node contributes to the accessible list. A branch with its own action exposes both an
    /// activate row and a disclosure row so VoiceOver users lose nothing relative to the radial gesture.
    public let rowRoles: [VoiceOverRowRole]

    init(node: WorkspaceContextNode) {
        id = node.id
        title = node.title
        subtitle = node.subtitle
        action = node.action
        children = node.children.map(VoiceOverLauncherNode.init)

        var roles: [VoiceOverRowRole] = []
        if node.action != nil { roles.append(.action) }
        if !node.children.isEmpty { roles.append(.disclosure) }
        rowRoles = roles

        if case .openProposal(let proposal) = node.action {
            let risk: String
            switch proposal.risk {
            case .safe: risk = "Safe"
            case .caution: risk = "Caution"
            case .destructive: risk = "Destructive"
            }
            spokenDetail = "\(risk). \(proposal.detail)"
        } else if node.isPartial {
            spokenDetail = "Partial context. \(node.subtitle ?? "")"
        } else {
            spokenDetail = node.subtitle ?? ""
        }
    }

    /// Rebuilds the selection path for a node id inside the frozen graph so accessible activation can freeze the
    /// same typed selection the radial gesture would.
    public static func selection(for id: String, in graph: WorkspaceContextGraph) -> RadialSelection? {
        func search(_ node: WorkspaceContextNode, path: [WorkspaceContextNode]) -> RadialSelection? {
            let nextPath = path + [node]
            if node.id == id {
                return RadialSelection(node: node, path: nextPath, proposal: node.proposal)
            }
            for child in node.children {
                if let found = search(child, path: nextPath) { return found }
            }
            return nil
        }
        for child in graph.root.children {
            if let found = search(child, path: []) { return found }
        }
        return nil
    }
}

public struct VoiceOverLauncherModel: Sendable, Hashable {
    public let root: VoiceOverLauncherNode

    public init(graph: WorkspaceContextGraph) {
        root = VoiceOverLauncherNode(node: graph.root)
    }
}

public struct ProactiveRadialLauncherView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private let graph: WorkspaceContextGraph
    @Binding private var state: RadialLauncherState
    private let onEffect: (RadialLauncherEffect) -> Void

    @State private var showsAccessibleHierarchy = false
    @State private var didHandleTouchDown = false

    public init(
        graph: WorkspaceContextGraph,
        state: Binding<RadialLauncherState>,
        onEffect: @escaping (RadialLauncherEffect) -> Void
    ) {
        self.graph = graph
        _state = state
        self.onEffect = onEffect
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                if state.phase == .tracking, let selection = state.selection {
                    radialNodes(selection: selection, in: proxy.size)
                        .transition(nodeTransition)
                }

                if let content = LauncherPreviewContent(state: state) {
                    ProposalPreviewCard(
                        content: content,
                        breadcrumb: state.selection?.path ?? [],
                        onConfirm: confirmPreview,
                        onCancel: cancel
                    )
                    .frame(maxWidth: min(360, proxy.size.width - 32))
                    .frame(maxHeight: previewFrame(in: proxy).height)
                    .position(previewPosition(in: proxy))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(2)
                }

                PawOrbView(status: launcherStatus, isActive: state.phase != .idle)
                    .accessibilityIdentifier("root.proactive-launcher.orb")
                    .accessibilityHint("Drag upward to explore. Double tap for an accessible hierarchy.")
                    .accessibilityAction {
                        if voiceOverEnabled { presentAccessibleHierarchy() }
                    }
                    .gesture(orbGesture)
                    .padding(.trailing, 8)
                    .padding(.bottom, 4)
                    .zIndex(3)
            }
            // The ZStack sizes to its children; without this it shrinks to the orb and parks it at the
            // GeometryReader's top-leading origin instead of the bottom-trailing corner.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .animation(.easeOut(duration: reduceMotion ? 0.16 : 0.24), value: state.phase)
            .sheet(isPresented: $showsAccessibleHierarchy, onDismiss: endAccessibleBrowsing) {
                AccessibleLauncherHierarchy(
                    model: VoiceOverLauncherModel(graph: state.snapshotGraph ?? graph),
                    onActivate: handleAccessibleActivation
                )
            }
        }
    }

    private var orbGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !didHandleTouchDown {
                    didHandleTouchDown = true
                    resignSoftwareKeyboard()
                    if voiceOverEnabled {
                        presentAccessibleHierarchy()
                        return
                    }
                }
                guard !voiceOverEnabled else { return }
                if state.phase == .idle {
                    state.begin(graph: graph, at: value.startLocation)
                }
                if state.phase == .tracking, let effect = state.move(to: value.location) {
                    onEffect(effect)
                }
            }
            .onEnded { value in
                defer { didHandleTouchDown = false }
                guard !voiceOverEnabled else { return }
                let effect: RadialLauncherEffect?
                if state.phase == .frozenPreview {
                    effect = state.confirmGesture(to: value.location)
                } else {
                    effect = state.end()
                }
                if let effect { onEffect(effect) }
            }
    }

    @ViewBuilder
    private func radialNodes(selection: RadialSelection, in size: CGSize) -> some View {
        let nodes = visibleNodes(for: selection)
        let origin = state.origin ?? CGPoint(x: size.width - 40, y: size.height - 36)
        let positions = RadialNodePresentation.positions(count: nodes.count, origin: origin, geometry: state.geometry)
        ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
            LauncherNodeView(node: node, selected: node.id == selection.node.id)
                .position(clamped(positions[index], in: size))
                .accessibilityIdentifier(node.kind == .switchHost
                    ? "root.proactive-launcher.switch-host"
                    : "root.proactive-launcher.node.\(node.id)")
        }
    }

    private func visibleNodes(for selection: RadialSelection) -> [WorkspaceContextNode] {
        guard selection.path.count > 1 else { return (state.snapshotGraph ?? graph).root.children }
        return selection.path.dropLast().last?.children ?? []
    }

    /// Keeps a node's hit area inside the container on compact widths without disturbing the shared angle
    /// mapping: the ring radius shrinks only when the container physically cannot fit it.
    private func clamped(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let inset = RadialNodePresentation.hitDiameter / 2
        return CGPoint(
            x: min(max(point.x, inset), size.width - inset),
            y: min(max(point.y, inset), size.height - inset)
        )
    }

    private func previewFrame(in proxy: GeometryProxy) -> CGRect {
        let size = CGSize(width: min(360, proxy.size.width - 32), height: 230)
        return ProposalPreviewCardPresentation.frame(
            in: proxy.size,
            safeAreaInsets: LauncherEdgeInsets(
                top: proxy.safeAreaInsets.top,
                leading: proxy.safeAreaInsets.leading,
                bottom: proxy.safeAreaInsets.bottom,
                trailing: proxy.safeAreaInsets.trailing
            ),
            keyboardHeight: 0,
            cardSize: size
        )
    }

    private func previewPosition(in proxy: GeometryProxy) -> CGPoint {
        let frame = previewFrame(in: proxy)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private var nodeTransition: AnyTransition {
        switch LauncherMotionPolicy.transition(reduceMotion: reduceMotion) {
        case .flyingArc: .asymmetric(insertion: .scale(scale: 0.7).combined(with: .opacity), removal: .opacity)
        case .fadeAndScale: .opacity.combined(with: .scale(scale: 0.94))
        }
    }

    private var launcherStatus: LauncherStatus {
        if graph.root.isPartial || graph.root.descendants.contains(where: \.isPartial) { return .partial }
        return .connected
    }

    private func cancel() {
        if let effect = state.cancel() { onEffect(effect) }
    }

    private func confirmPreview() {
        if let effect = state.confirmExplicitly() { onEffect(effect) }
    }

    private func presentAccessibleHierarchy() {
        state.beginAccessible(graph: graph)
        showsAccessibleHierarchy = true
    }

    private func endAccessibleBrowsing() {
        if state.phase == .accessibleBrowsing, let effect = state.cancel() { onEffect(effect) }
    }

    private func handleAccessibleActivation(_ node: VoiceOverLauncherNode) {
        showsAccessibleHierarchy = false
        let frozen = state.snapshotGraph ?? graph
        let effect: RadialLauncherEffect?
        if let selection = VoiceOverLauncherNode.selection(for: node.id, in: frozen) {
            effect = state.activate(selection)
        } else if let action = node.action {
            effect = state.activate(action)
        } else {
            effect = nil
        }
        if let effect { onEffect(effect) }
    }

    private func resignSoftwareKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

private struct LauncherNodeView: View {
    let node: WorkspaceContextNode
    let selected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(OpenPawTheme.graphite.opacity(0.96))
                .overlay(Circle().stroke(selected ? OpenPawTheme.pulse : OpenPawTheme.signal.opacity(0.65), lineWidth: selected ? 2 : 1))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            Image(systemName: glyph)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(selected ? OpenPawTheme.pulse : OpenPawTheme.textPrimary)
        }
        .frame(width: RadialNodePresentation.visualDiameter, height: RadialNodePresentation.visualDiameter)
        .frame(width: RadialNodePresentation.hitDiameter, height: RadialNodePresentation.hitDiameter)
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.title)
        .accessibilityValue(node.subtitle ?? "")
    }

    private var glyph: String {
        switch node.kind {
        case .host: "desktopcomputer"
        case .session: "rectangle.stack"
        case .tab: "rectangle.on.rectangle"
        case .pane: "rectangle.split.2x1"
        case .repository: "arrow.triangle.branch"
        case .tool: "wrench.and.screwdriver"
        case .proposal: "sparkles"
        case .more: "ellipsis"
        case .switchHost: "arrow.left.arrow.right"
        }
    }
}

private struct AccessibleLauncherHierarchy: View {
    let model: VoiceOverLauncherModel
    let onActivate: (VoiceOverLauncherNode) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                AccessibleNodeRows(node: model.root, onActivate: onActivate)
            }
            .navigationTitle("Paw launcher")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }
}

private struct AccessibleNodeRows: View {
    let node: VoiceOverLauncherNode
    let onActivate: (VoiceOverLauncherNode) -> Void

    var body: some View {
        if node.rowRoles.contains(.action) {
            Button {
                onActivate(node)
            } label: {
                VStack(alignment: .leading) {
                    Text(node.title)
                    if !node.spokenDetail.isEmpty { Text(node.spokenDetail).font(.caption).foregroundStyle(.secondary) }
                }
            }
        } else if node.children.isEmpty {
            VStack(alignment: .leading) {
                Text(node.title)
                if !node.spokenDetail.isEmpty { Text(node.spokenDetail).font(.caption).foregroundStyle(.secondary) }
            }
            .foregroundStyle(.secondary)
        }
        if node.rowRoles.contains(.disclosure) {
            DisclosureGroup(node.rowRoles.contains(.action) ? "\(node.title) contents" : node.title) {
                ForEach(node.children) { child in
                    AccessibleNodeRows(node: child, onActivate: onActivate)
                }
            }
        }
    }
}
