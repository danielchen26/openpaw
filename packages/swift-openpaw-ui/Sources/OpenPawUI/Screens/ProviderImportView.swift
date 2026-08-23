import SwiftUI
import OpenPawProtocol

public struct ProviderImportView: View {
    @Bindable var model: OpenPawModel

    public init(model: OpenPawModel) { self.model = model }

    public var body: some View {
        let presentation = ProviderImportPresentation(hostName: model.selectedHost?.nickname ?? "Selected host", provider: model.selectedProvider, providers: model.providers, canList: model.canListProviders, canAuthorize: model.canAuthorizeProviders, canImport: model.canImportRepos, repos: model.providerRepoPages.repos, importState: model.repoImportState, authorizationState: model.providerAuthorizationState)
        ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
                ProviderTransferRail(presentation: presentation.rail)
                capabilityPanel(presentation.capability)
                providerStrip(presentation.providerChips)
                if let authorization = presentation.authorization { ProviderAuthorizationPanel(presentation: authorization, onCheck: { Task { await model.pollProviderAuthorization() } }, onCancel: { Task { await model.cancelProviderAuthorization() } }) }
                ProviderRepositoryCatalogView(presentation: presentation.catalog!, onLoadMore: { Task { await model.loadProviderRepos() } }, onImport: { row in Task { await model.startRepoImport(provider: row.provider, repoID: row.id, requestedName: row.requestedName) } })
                if let importProgress = presentation.importProgress { RepoImportProgressPanel(presentation: importProgress, onCancel: { Task { await model.cancelRepoImport() } }) }
            }
            .padding()
        }
        .background(OpenPawTheme.void.ignoresSafeArea())
        .navigationTitle("Remote catalog transfer")
        .task(id: "\(model.selectedHostID?.uuidString ?? "none")-\(model.connectionGeneration)") {
            guard model.connection.isConnected else { return }
            await model.refreshProviders()
            if model.selectedProvider == nil { model.selectedProvider = .github }
            await model.loadProviderRepos(reset: true)
        }
    }

    private func capabilityPanel(_ capability: ProviderCapabilityPresentation) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            Text(capability.title).font(OpenPawTheme.Human.proseTight).foregroundStyle(OpenPawTheme.textPrimary)
            Text(capability.detail).font(OpenPawTheme.Human.prose).foregroundStyle(OpenPawTheme.textSecondary)
        }.padding().background(OpenPawTheme.graphite, in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.sheet))
    }

    private func providerStrip(_ chips: [ProviderChipPresentation]) -> some View {
        HStack { ForEach(chips, id: \.provider) { chip in Button { model.selectedProvider = chip.provider; Task { await model.loadProviderRepos(reset: true) } } label: { VStack { Text(chip.title); Text(chip.subtitle).font(OpenPawTheme.Machine.label) } }.buttonStyle(.bordered) } }
    }
}
