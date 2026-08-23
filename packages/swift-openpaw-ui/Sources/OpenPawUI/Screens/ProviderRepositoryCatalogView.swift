import SwiftUI

public struct ProviderRepositoryCatalogView: View {
    public let presentation: ProviderCatalogPresentation
    public var onLoadMore: () -> Void
    public var onImport: (ProviderRepoRowPresentation) -> Void
    public init(presentation: ProviderCatalogPresentation, onLoadMore: @escaping () -> Void, onImport: @escaping (ProviderRepoRowPresentation) -> Void) { self.presentation = presentation; self.onLoadMore = onLoadMore; self.onImport = onImport }
    public var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            Text(presentation.title).font(OpenPawTheme.Human.proseTight).foregroundStyle(OpenPawTheme.textPrimary)
            Text(presentation.detail).font(OpenPawTheme.Human.prose).foregroundStyle(OpenPawTheme.textSecondary)
            if presentation.repos.isEmpty { Text(presentation.emptyTitle ?? "No repositories returned by the host.").foregroundStyle(OpenPawTheme.textSecondary) }
            ForEach(presentation.repos) { row in HStack { VStack(alignment: .leading) { Text(row.title); Text(row.privacy).font(OpenPawTheme.Machine.label) }; Spacer(); if presentation.primaryAction != nil { Button("Transfer to host workspace") { onImport(row) }.frame(minHeight: 44) } } }
        }.padding().background(OpenPawTheme.graphite, in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.sheet))
    }
}
