import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI
import UniformTypeIdentifiers

/// The host list, which is also the app's allowlist: OpenPaw only ever dials something on this screen.
///
/// That is why the rows are plain and complete rather than pretty — every fact the connection depends on is visible
/// without tapping in, so a wrong port or a stale username is caught by reading rather than by failing.
@MainActor
public struct HostListView: View {
    private let model: OpenPawModel
    private let settings: OpenPawSettings

    @State private var editing: HostRecord?
    @State private var isAdding = false
    @State private var pendingDeletion: HostRecord?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument = ShellJSONDocument(data: Data())
    @State private var transferError: String?

    public init(model: OpenPawModel, settings: OpenPawSettings) {
        self.model = model
        self.settings = settings
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
                if model.hostStore.hosts.isEmpty {
                    empty
                } else {
                    ForEach(model.hostStore.hosts) { host in
                        row(host)
                    }
                    transfer
                }
            }
            .padding(OpenPawTheme.Space.large)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(OpenPawTheme.ink)
        .navigationTitle("Hosts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add host")
            }
        }
        .sheet(isPresented: $isAdding) {
            NavigationStack {
                HostEditorView(model: model, settings: settings) { isAdding = false }
            }
        }
        .sheet(item: $editing) { record in
            NavigationStack {
                HostEditorView(model: model, settings: settings, record: record) { editing = nil }
            }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: deletionBinding,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { host in
            Button("Delete \(host.nickname)", role: .destructive) { delete(host) }
            Button("Keep", role: .cancel) {}
        } message: { host in
            Text(deletionMessage(host))
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "openpaw-hosts"
        ) { result in
            if case .failure(let error) = result { transferError = String(describing: error) }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            importStore(from: result)
        }
    }

    private var empty: some View {
        EmptyStateView(
            glyph: "desktopcomputer",
            title: "No hosts yet",
            message: emptyMessage,
            actionTitle: "Add host",
            action: { isAdding = true }
        )
    }

    private var emptyMessage: String {
        """
        Add the machine your agents run on. OpenPaw dials it over SSH from this device, so nothing leaves your own \
        network.
        """
    }

    // MARK: Row

    private func row(_ host: HostRecord) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                rowHeader(host)
                Text(verbatim: "\(host.username)@\(host.hostname):\(host.port)")
                    .font(OpenPawTheme.Machine.code)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .textSelection(.enabled)
                rowDetail(host)
                rowFacts(host)
                rowTags(host)
                rowActions(host)
            }
        }
    }

    private func rowHeader(_ host: HostRecord) -> some View {
        let status = presentation(for: host)
        return HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
            Circle()
                .fill(status.tone)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(host.nickname)
                .font(OpenPawTheme.Machine.title)
                .foregroundStyle(OpenPawTheme.textPrimary)
            Spacer(minLength: OpenPawTheme.Space.small)
            // The dot never carries the state on its own.
            Text(status.label).microLabel(status.tone)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(host.nickname), \(status.label)")
    }

    @ViewBuilder
    private func rowDetail(_ host: HostRecord) -> some View {
        if let detail = presentation(for: host).detail {
            Text(detail)
                .font(OpenPawTheme.Human.caption)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rowFacts(_ host: HostRecord) -> some View {
        ShellWrap(spacing: OpenPawTheme.Space.large) {
            fact("transport", transportLabel(host))
            fact("mux", host.multiplexerPreference?.displayName ?? "none")
            fact("keys pinned", String(host.knownHosts.count))
            factView("last reached") {
                if let last = settings.profile(for: host.id).lastConnectedAt {
                    RelativeTime(date: last)
                        .font(OpenPawTheme.Machine.codeSmall)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                } else {
                    Text("never")
                        .font(OpenPawTheme.Machine.codeSmall)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func rowTags(_ host: HostRecord) -> some View {
        if !host.tags.isEmpty {
            ShellWrap(spacing: OpenPawTheme.Space.small) {
                ForEach(host.tags, id: \.self) { tag in
                    Text(tag)
                        .font(OpenPawTheme.Machine.codeSmall)
                        .padding(.horizontal, OpenPawTheme.Space.small)
                        .padding(.vertical, OpenPawTheme.Space.hair)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                        .background(OpenPawTheme.well)
                        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.chip))
                }
            }
        }
    }

    private func rowActions(_ host: HostRecord) -> some View {
        let isLive = host.id == model.selectedHostID && model.connection.isConnected
        return HStack(spacing: OpenPawTheme.Space.small) {
            // A connected host is not offered a Connect button. Two filled primaries on one screen, one of them a
            // no-op, is worse than no hierarchy at all.
            if isLive {
                Button {
                    Task { await model.disconnect() }
                } label: {
                    Text("Disconnect")
                        .font(OpenPawTheme.Machine.headline)
                        .padding(.horizontal, OpenPawTheme.Space.medium)
                        .frame(minHeight: 44)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                        .overlay(
                            RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                                .stroke(OpenPawTheme.lineStrong, lineWidth: OpenPawTheme.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Disconnect from \(host.nickname)")
            } else {
                Button {
                    connect(host)
                } label: {
                    Text("Connect")
                        .font(OpenPawTheme.Machine.headline)
                        .padding(.horizontal, OpenPawTheme.Space.medium)
                        .frame(minHeight: 44)
                        .foregroundStyle(OpenPawTheme.ink)
                        .background(OpenPawTheme.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Connect to \(host.nickname)")
            }

            Button {
                editing = host
            } label: {
                Text("Edit")
                    .font(OpenPawTheme.Machine.headline)
                    .padding(.horizontal, OpenPawTheme.Space.medium)
                    .frame(minHeight: 44)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .overlay(
                        RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                            .stroke(OpenPawTheme.lineStrong, lineWidth: OpenPawTheme.hairline))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(host.nickname)")

            Spacer(minLength: 0)

            Menu {
                Button("Duplicate") { duplicate(host) }
                Button("Delete", role: .destructive) { pendingDeletion = host }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More actions for \(host.nickname)")
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        factView(label) {
            Text(value)
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(OpenPawTheme.textSecondary)
        }
    }

    private func factView<Content: View>(
        _ label: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
            Text(label).microLabel()
            content()
        }
        .accessibilityElement(children: .combine)
    }

    private func transportLabel(_ host: HostRecord) -> String {
        guard let kind = host.preferredTransport else {
            guard let known = host.lastSuccessfulTransport else { return "auto" }
            return "auto, last \(known.rawValue)"
        }
        guard TransportAvailability.isBuilt(kind) else { return "\(kind.rawValue), not built" }
        return kind.rawValue
    }

    /// Only the selected host has a live connection state; the rest are simply not connected, and saying so is more
    /// useful than leaving a grey dot to be interpreted.
    private func presentation(for host: HostRecord) -> ConnectionPresentation {
        guard host.id == model.selectedHostID else {
            return ConnectionPresentation(
                label: "not connected", detail: nil, tone: OpenPawTheme.textTertiary, glyph: "circle")
        }
        return ConnectionPresentation.make(model.connection)
    }

    // MARK: Transfer

    private var transfer: some View {
        Panel(label: "Host list") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Text(
                    """
                    An export carries nicknames, hostnames, ports, usernames, pinned host keys and the names of \
                    keychain entries. It never carries a private key, a password or a device token: those stay in \
                    the keychain on this device and are not part of the file.
                    """
                )
                .font(OpenPawTheme.Human.prose)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: OpenPawTheme.Space.small) {
                    Button("Export JSON", action: startExport)
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                    Spacer(minLength: OpenPawTheme.Space.large)
                    Button("Import JSON") { isImporting = true }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                }

                if let transferError {
                    ShellIssueText(transferError)
                }
            }
        }
    }

    private func startExport() {
        transferError = nil
        do {
            exportDocument = ShellJSONDocument(data: try model.hostStore.export())
            isExporting = true
        } catch {
            transferError = "The host list could not be written: \(error)"
        }
    }

    private func importStore(from result: Result<URL, any Error>) {
        transferError = nil
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            model.hostStore = try HostStore.import(from: try Data(contentsOf: url))
            if model.selectedHostID == nil || model.hostStore[model.selectedHostID ?? UUID()] == nil {
                let hostID = model.hostStore.hosts.first?.id
                Task { await model.selectHost(hostID) }
            }
        } catch {
            transferError = "That file is not an OpenPaw host list: \(error)"
        }
    }

    // MARK: Actions

    private var deletionTitle: String {
        pendingDeletion.map { "Delete \($0.nickname)?" } ?? "Delete host?"
    }

    private func deletionMessage(_ host: HostRecord) -> String {
        """
        Removes \(host.username)@\(host.hostname) from this device, along with its pinned host keys and terminal \
        profile. The keychain entries it points to stay where they are.
        """
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private func connect(_ host: HostRecord) {
        Task {
            await model.selectHost(host.id)
            await model.connectSelectedHost()
            if model.connection.isConnected {
                settings.recordConnection(to: host.id)
            }
        }
    }

    private func duplicate(_ host: HostRecord) {
        var copy = host
        copy.id = UUID()
        copy.nickname = "\(host.nickname) copy"
        // A duplicate has not connected and has pinned nothing: carrying either over would be a lie about a host
        // this device has never spoken to under that entry.
        copy.knownHosts = []
        copy.lastSuccessfulTransport = nil
        model.hostStore.upsert(copy)
        settings.setProfile(settings.profile(for: host.id), for: copy.id)
    }

    private func delete(_ host: HostRecord) {
        model.hostStore.remove(id: host.id)
        settings.forgetProfile(for: host.id)
        if model.selectedHostID == host.id {
            let hostID = model.hostStore.hosts.first?.id
            Task { await model.selectHost(hostID) }
        }
        pendingDeletion = nil
    }
}

// MARK: - JSON transfer document

/// Carries an already-encoded JSON payload in and out of the document browser. It deliberately holds `Data` and not
/// a decoded value: `HostStore` owns that schema, and re-encoding here would create a second one.
struct ShellJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#Preview("Hosts") {
    NavigationStack {
        HostListView(model: PreviewBackend.model(.populated), settings: OpenPawSettings.preview())
    }
    .preferredColorScheme(.dark)
}

#Preview("No hosts") {
    NavigationStack {
        HostListView(model: PreviewBackend.model(.empty), settings: OpenPawSettings.preview())
    }
    .preferredColorScheme(.dark)
}
