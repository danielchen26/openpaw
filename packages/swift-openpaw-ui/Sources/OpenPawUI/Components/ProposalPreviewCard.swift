import SwiftUI

public struct LauncherEdgeInsets: Sendable, Hashable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}

public enum ProposalPreviewCardPresentation {
    public nonisolated static func frame(
        in container: CGSize,
        safeAreaInsets: LauncherEdgeInsets,
        keyboardHeight: CGFloat,
        cardSize: CGSize
    ) -> CGRect {
        let margin: CGFloat = 16
        let minY = safeAreaInsets.top + margin
        let maxY = max(minY, container.height - max(keyboardHeight, safeAreaInsets.bottom) - margin)
        let height = min(cardSize.height, maxY - minY)
        let preferredY = container.height * 0.21
        let y = min(max(preferredY, minY), maxY - height)
        let availableWidth = max(0, container.width - safeAreaInsets.leading - safeAreaInsets.trailing - margin * 2)
        let width = min(cardSize.width, availableWidth)
        let x = safeAreaInsets.leading + (container.width - safeAreaInsets.leading - safeAreaInsets.trailing - width) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// When the preview card is on screen. It is not only the frozen confirmation surface: as soon as a drag
/// reaches the second layer, the card appears live in the upper middle of the screen showing what releasing
/// would line up. First-layer browsing stays card-free so the arc remains the whole interface.
public enum LauncherLivePreviewPolicy {
    public nonisolated static func content(for state: RadialLauncherState) -> LauncherPreviewContent? {
        switch state.phase {
        case .frozenPreview, .confirmed:
            return LauncherPreviewContent(state: state)
        case .tracking:
            guard let selection = state.selection, selection.path.count >= 2 else { return nil }
            return LauncherPreviewContent(selection: selection)
        case .idle, .accessibleBrowsing:
            return nil
        }
    }
}

/// The unified data a frozen preview renders, whether the selection was a proactive proposal or an ordinary typed
/// action. Every frozen selection gets a complete preview: title, detail, risk framing, and a named confirmation.
public struct LauncherPreviewContent: Sendable, Hashable {
    public let title: String
    public let detail: String
    public let risk: ProactiveProposal.Risk
    public let sourceLabel: String?
    public let repositoryPath: String?
    public let actionTitle: String
    public let confirmGlyph: String
    public let allowsGestureConfirmation: Bool
    public let confirmAccessibilityIdentifier: String

    public init(proposal: ProactiveProposal) {
        let confirmation = ProposalConfirmationPresentation(proposal: proposal)
        title = proposal.title
        detail = proposal.detail
        risk = proposal.risk
        sourceLabel = proposal.source == .local ? "LOCAL" : "AGENT-DERIVED"
        repositoryPath = proposal.target.repositoryPath
        actionTitle = confirmation.actionTitle
        confirmGlyph = proposal.risk == .destructive ? "terminal.fill" : "arrow.up.circle.fill"
        allowsGestureConfirmation = confirmation.allowsGestureConfirmation
        confirmAccessibilityIdentifier = confirmation.accessibilityIdentifier
    }

    public init(action: WorkspaceContextAction, node: WorkspaceContextNode? = nil) {
        title = node?.title ?? action.summaryTitle
        detail = node?.subtitle ?? action.summaryTitle
        risk = .safe
        sourceLabel = nil
        if case .openRepository(let path) = action {
            repositoryPath = path
        } else {
            repositoryPath = nil
        }
        actionTitle = "Confirm action"
        confirmGlyph = "arrow.up.circle.fill"
        allowsGestureConfirmation = true
        confirmAccessibilityIdentifier = "root.proactive-launcher.confirm"
    }

    public init?(selection: RadialSelection) {
        if let proposal = selection.proposal ?? selection.node.proposal {
            self.init(proposal: proposal)
        } else if let action = selection.node.action {
            self.init(action: action, node: selection.node)
        } else {
            return nil
        }
    }

    public init?(state: RadialLauncherState) {
        if let proposal = state.frozenProposal ?? state.selection?.proposal {
            self.init(proposal: proposal)
        } else if let action = state.frozenAction {
            self.init(action: action, node: state.selection?.node)
        } else {
            return nil
        }
    }
}

public struct ProposalConfirmationPresentation: Sendable, Hashable {
    public let allowsGestureConfirmation: Bool
    public let actionTitle: String
    public let accessibilityIdentifier: String

    public init(proposal: ProactiveProposal) {
        allowsGestureConfirmation = proposal.risk != .destructive
        if proposal.risk == .destructive {
            actionTitle = "Open Terminal to confirm destructive command"
            accessibilityIdentifier = "root.proactive-launcher.destructive-confirm"
        } else {
            actionTitle = "Confirm action"
            accessibilityIdentifier = "root.proactive-launcher.confirm"
        }
    }
}

public struct ProposalPreviewCard: View {
    private let content: LauncherPreviewContent
    private let breadcrumb: [WorkspaceContextNode]
    private let onConfirm: () -> Void
    private let onCancel: () -> Void

    public init(
        proposal: ProactiveProposal,
        breadcrumb: [WorkspaceContextNode] = [],
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.content = LauncherPreviewContent(proposal: proposal)
        self.breadcrumb = breadcrumb
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public init(
        content: LauncherPreviewContent,
        breadcrumb: [WorkspaceContextNode] = [],
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.content = content
        self.breadcrumb = breadcrumb
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !breadcrumb.isEmpty {
                        Text(breadcrumb.map(\.title).joined(separator: "  ›  "))
                            .font(.caption.monospaced())
                            .foregroundStyle(OpenPawTheme.textSecondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: riskGlyph)
                        Text(riskLabel)
                        Spacer()
                        if let source = content.sourceLabel {
                            Text(source)
                                .font(.caption2.monospaced().weight(.semibold))
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(riskColor)

                    Text(content.title)
                        .font(.headline)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                    Text(content.detail)
                        .font(.body)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let repository = content.repositoryPath {
                        Label(repository, systemImage: "folder")
                            .font(.caption.monospaced())
                            .foregroundStyle(OpenPawTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("root.proactive-launcher.cancel")
                Spacer()
                Button(action: onConfirm) {
                    Label(content.actionTitle, systemImage: content.confirmGlyph)
                        .lineLimit(2)
                }
                .buttonStyle(.borderedProminent)
                .tint(content.risk == .destructive ? OpenPawTheme.bad : OpenPawTheme.signal)
                .accessibilityIdentifier(content.confirmAccessibilityIdentifier)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OpenPawTheme.graphite.opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(riskColor.opacity(0.52), lineWidth: 1))
                .shadow(color: .black.opacity(0.42), radius: 24, y: 10)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("root.proactive-launcher.preview")
    }

    private var riskLabel: String {
        switch content.risk {
        case .safe: "Safe"
        case .caution: "Caution"
        case .destructive: "Destructive"
        }
    }

    private var riskGlyph: String {
        switch content.risk {
        case .safe: "checkmark.shield.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .destructive: "flame.fill"
        }
    }

    private var riskColor: Color {
        switch content.risk {
        case .safe: OpenPawTheme.pulse
        case .caution: OpenPawTheme.caution
        case .destructive: OpenPawTheme.bad
        }
    }
}
