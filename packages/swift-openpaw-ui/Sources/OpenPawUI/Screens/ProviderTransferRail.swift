import SwiftUI

public struct ProviderTransferRail: View {
    public let presentation: ProviderTransferRailPresentation
    public init(presentation: ProviderTransferRailPresentation) { self.presentation = presentation }
    public var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
            Text("remote catalog / host transfer / local workspace").font(OpenPawTheme.Machine.label).foregroundStyle(OpenPawTheme.signal)
            Text("Import through \(presentation.hostName)").font(OpenPawTheme.Human.title).foregroundStyle(OpenPawTheme.textPrimary)
            HStack(alignment: .top, spacing: OpenPawTheme.Space.small) {
                ForEach(presentation.stations, id: \.title) { station in
                    VStack(alignment: .leading) {
                        Text(station.title).font(OpenPawTheme.Machine.label).foregroundStyle(OpenPawTheme.textPrimary)
                        Text(station.subtitle).font(OpenPawTheme.Human.caption).foregroundStyle(OpenPawTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    .padding()
                    .background(OpenPawTheme.graphite, in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(station.title)
                    .accessibilityValue(station.subtitle)
                }
            }
        }
        .padding()
        .background(OpenPawTheme.ember, in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.sheet))
        .accessibilityElement(children: .contain)
        .accessibilityValue(presentation.phaseAccessibilityValue)
    }
}
