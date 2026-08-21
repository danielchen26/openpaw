import SwiftUI

public struct StatusPill: View {
    private let signal: ConnectionSignal

    public init(signal: ConnectionSignal) {
        self.signal = signal
    }

    public init(_ state: ConnectionSignalState) {
        self.init(signal: ConnectionSignal(state))
    }

    public var body: some View {
        HStack(spacing: OpenPawTheme.Space.tight) {
            Image(systemName: signal.glyph)
                .imageScale(.small)
            Text(signal.label)
                .font(OpenPawTheme.Navigation.caption)
        }
        .foregroundStyle(signal.tone.color)
        .padding(.horizontal, OpenPawTheme.Space.small)
        .padding(.vertical, OpenPawTheme.Space.tight)
        .background(
            Capsule()
                .fill(OpenPawTheme.void)
                .overlay(Capsule().stroke(signal.tone.color.opacity(0.45), lineWidth: OpenPawTheme.hairline))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(signal.accessibilityLabel))
    }
}
