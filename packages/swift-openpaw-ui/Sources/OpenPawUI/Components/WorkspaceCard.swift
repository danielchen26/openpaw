import SwiftUI

public struct WorkspaceCard: View {
    public let presentation: WorkspaceDevicePresentation
    private let action: @MainActor () -> Void

    public nonisolated init(presentation: WorkspaceDevicePresentation, action: @escaping @MainActor () -> Void) {
        self.presentation = presentation
        self.action = action
    }

    public var body: some View {
        let signal = ConnectionSignal(availability: presentation.availability)

        VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
            HStack(alignment: .top, spacing: OpenPawTheme.Space.medium) {
                SignalOrb(signal: signal, size: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                    Text(presentation.title)
                        .font(OpenPawTheme.Navigation.headline)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                        .lineLimit(1)
                    Text(presentation.hostname)
                        .font(OpenPawTheme.Machine.body)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                        .lineLimit(1)
                    Text(presentation.network.sourceLabel)
                        .font(OpenPawTheme.Navigation.caption)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                }

                Spacer(minLength: OpenPawTheme.Space.small)
                StatusPill(signal: signal)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: OpenPawTheme.Space.small)], spacing: OpenPawTheme.Space.small) {
                ForEach(presentation.metrics) { metric in
                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                        Text(metric.label)
                            .microLabel()
                        Text(metric.value)
                            .font(OpenPawTheme.Machine.body)
                            .foregroundStyle(OpenPawTheme.textPrimary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(OpenPawTheme.Space.small)
                    .background(OpenPawTheme.void)
                    .overlay(
                        Rectangle()
                            .stroke(OpenPawTheme.line, lineWidth: OpenPawTheme.hairline)
                    )
                }
            }

            Button(action: action) {
                Label(presentation.connectionActionTitle, systemImage: signal.state == .online ? "arrow.forward.circle.fill" : "link")
                    .font(OpenPawTheme.Navigation.label)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(OpenPawTheme.signal)
            .accessibilityLabel(presentation.connectionActionAccessibilityLabel)
        }
        .padding(OpenPawTheme.Space.large)
        .background(OpenPawTheme.graphite)
        .overlay(
            RoundedRectangle(cornerRadius: OpenPawTheme.Radius.sheet, style: .continuous)
                .stroke(signal.tone.color.opacity(0.55), lineWidth: OpenPawTheme.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.sheet, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
