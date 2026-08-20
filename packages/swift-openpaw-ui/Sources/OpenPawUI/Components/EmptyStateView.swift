import SwiftUI

/// An empty state that gives direction.
///
/// "Nothing here" tells a person what they can already see. Every one of these says what this surface is *for* and
/// offers the one thing worth doing next, in the human register, because it is the app talking rather than the host
/// reporting. Left-aligned and set high in its space: centring a headline in a void is the house style of software
/// that has run out of things to say.
public struct EmptyStateView: View {
    private let glyph: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        glyph: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.glyph = glyph
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
            Image(systemName: glyph)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(OpenPawTheme.textTertiary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                Text(title)
                    .font(OpenPawTheme.Human.title)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(OpenPawTheme.Machine.headline)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                        .padding(.horizontal, OpenPawTheme.Space.large)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(OpenPawTheme.panel)
                        .overlay(
                            RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card, style: .continuous)
                                .strokeBorder(OpenPawTheme.lineStrong, lineWidth: OpenPawTheme.hairline * 3)
                        )
                        .clipShape(
                            RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        // A generous but asymmetric frame: the block sits at the top of the space, not floating in the middle.
        .padding(.horizontal, OpenPawTheme.Space.xl)
        .padding(.top, OpenPawTheme.Space.section)
        .padding(.bottom, OpenPawTheme.Space.xl)
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview("Empty states") {
    VStack(spacing: 0) {
        EmptyStateView(
            glyph: "tray",
            title: "Nothing is waiting on you",
            message: "When an agent needs a decision, it lands here with the command it wants to run.",
            actionTitle: "Open a session",
            action: {}
        )
        Divider().overlay(OpenPawTheme.line)
        EmptyStateView(
            glyph: "arrow.triangle.branch",
            title: "This branch is clean",
            message: "Edits the agent makes to tracked files will show up here as a diff you can read before it commits."
        )
    }
    .background(OpenPawTheme.ink)
}
