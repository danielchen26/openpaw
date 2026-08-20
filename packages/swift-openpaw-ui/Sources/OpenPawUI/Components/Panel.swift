import SwiftUI

// MARK: - Machine register

/// The machine-register container: cool surface, square corners, one hairline.
///
/// Square corners are the whole argument. Everything in this container is something the host or the agent *did* —
/// a command, a path, a sequence number — and rounding those corners would file the edge off the distinction the
/// rest of the design leans on. The optional micro-label header is the eyebrow that names the field; the accessory
/// slot beside it is where a count, a timestamp or a single control goes.
public struct PanelModifier: ViewModifier {
    let label: String?
    let padding: CGFloat

    public init(label: String? = nil, padding: CGFloat = OpenPawTheme.Space.large) {
        self.label = label
        self.padding = padding
    }

    public func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
            if let label {
                Text(label).microLabel()
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenPawTheme.panel)
        .overlay(
            Rectangle()
                .strokeBorder(OpenPawTheme.line, lineWidth: OpenPawTheme.hairline * 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous))
    }
}

/// The human-register container: warm surface, rounded, no border.
///
/// No border on purpose. Prose does not need to be boxed in, and the temperature shift from `panel` to `panelWarm`
/// already tells a reader they have crossed from fact to sentence.
public struct HumanPanelModifier: ViewModifier {
    let padding: CGFloat

    public init(padding: CGFloat = OpenPawTheme.Space.large) {
        self.padding = padding
    }

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OpenPawTheme.panelWarm)
            .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card, style: .continuous))
    }
}

extension View {
    /// Wraps any view in the machine register.
    public func panelStyle(
        label: String? = nil,
        padding: CGFloat = OpenPawTheme.Space.large
    ) -> some View {
        modifier(PanelModifier(label: label, padding: padding))
    }

    /// Wraps any view in the human register.
    public func humanPanelStyle(padding: CGFloat = OpenPawTheme.Space.large) -> some View {
        modifier(HumanPanelModifier(padding: padding))
    }
}

// MARK: - Containers

/// `Panel { … }`, for the common case where the panel *is* the layout rather than a treatment applied to one.
public struct Panel<Content: View, Accessory: View>: View {
    private let label: String?
    private let padding: CGFloat
    private let content: Content
    private let accessory: Accessory

    /// With a trailing accessory beside the header label — a count, an age, a single control.
    public init(
        label: String?,
        padding: CGFloat = OpenPawTheme.Space.large,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.padding = padding
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
            if label != nil || Accessory.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                    if let label {
                        Text(label).microLabel()
                    }
                    Spacer(minLength: OpenPawTheme.Space.small)
                    accessory
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenPawTheme.panel)
        .overlay(
            Rectangle()
                .strokeBorder(OpenPawTheme.line, lineWidth: OpenPawTheme.hairline * 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous))
    }
}

extension Panel where Accessory == EmptyView {
    public init(
        label: String? = nil,
        padding: CGFloat = OpenPawTheme.Space.large,
        @ViewBuilder content: () -> Content
    ) {
        self.init(label: label, padding: padding, accessory: { EmptyView() }, content: content)
    }
}

/// `HumanPanel { … }` — the warm counterpart. No label slot: an eyebrow over prose is a machine-register habit.
public struct HumanPanel<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(
        padding: CGFloat = OpenPawTheme.Space.large,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OpenPawTheme.panelWarm)
            .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card, style: .continuous))
    }
}

#Preview("Both registers") {
    VStack(spacing: OpenPawTheme.Space.large) {
        Panel(label: "session") {
            Text(PreviewBackend.claudeSessionID)
                .font(OpenPawTheme.Machine.code)
                .foregroundStyle(OpenPawTheme.textPrimary)
        }

        Panel(label: "tool", accessory: { RelativeTime(date: PreviewBackend.now.addingTimeInterval(-260)) }) {
            Text("pytest -q tests/test_auth.py -p randomly --count 20")
                .font(OpenPawTheme.Machine.code)
                .foregroundStyle(OpenPawTheme.textPrimary)
        }

        HumanPanel {
            Text(
                "Reproduced it. `auth_token` is a module-scoped fixture, so the first test to mutate the claims "
                    + "dictionary changes what every later test sees."
            )
            .font(OpenPawTheme.Human.prose)
            .foregroundStyle(OpenPawTheme.textPrimary)
        }
    }
    .padding(OpenPawTheme.Space.large)
    .background(OpenPawTheme.ink)
}
