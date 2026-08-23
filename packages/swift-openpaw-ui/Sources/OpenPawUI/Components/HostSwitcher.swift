import OpenPawTerminalCore
import SwiftUI

public enum HostSwitcherAction: String, Sendable, Hashable, CaseIterable {
    case connect
    case reconnect
    case disconnect
}

/// One vocabulary for the compact Terminal header and the regular sidebar.
///
/// Keeping this value independent of layout prevents the phone from saying “idle” while the sidebar says
/// “disconnected”, and gives tests a public contract for the actions a state exposes.
public struct HostSwitcherPresentation: Sendable, Hashable {
    public let title: String
    public let status: String
    public let transport: String?
    public let glyph: String
    public let connectionActions: [HostSwitcherAction]

    public init(host: HostRecord?, connection: ConnectionState) {
        guard let host else {
            title = "No host"
            status = "Add a device"
            transport = nil
            glyph = "circle.dashed"
            connectionActions = []
            return
        }

        let connectionPresentation = ConnectionPresentation.make(connection)
        title = host.nickname
        status = connectionPresentation.label
        glyph = connectionPresentation.glyph
        transport = Self.transportLabel(host: host, connection: connection)
        switch connection {
        case .connected:
            connectionActions = [.reconnect, .disconnect]
        case .resolving, .connecting, .authenticating, .reconnecting:
            connectionActions = [.disconnect]
        case .idle, .disconnected, .failed:
            connectionActions = [.connect]
        }
    }

    public var value: String {
        guard let transport else { return status }
        return "\(status) · \(transport)"
    }

    private static func transportLabel(host: HostRecord, connection: ConnectionState) -> String {
        if case .connected(let kind) = connection { return kind.displayName }
        guard let preferred = host.preferredTransport ?? host.lastSuccessfulTransport else { return "Automatic" }
        guard TransportAvailability.isBuilt(preferred) else { return "\(preferred.displayName) unavailable" }
        return preferred.displayName
    }
}

/// The single host chooser used everywhere the shell exposes connection identity.
///
/// Selection only changes the host. Connect is a second, explicit action. This is both safer and easier to understand
/// than a menu row that begins dialing as soon as it is highlighted.
@MainActor
public struct HostSwitcher: View {
    private let model: OpenPawModel
    private let onAddDevice: () -> Void
    private let onManageHosts: () -> Void
    private let onConnected: (HostRecord.ID) -> Void

    public init(
        model: OpenPawModel,
        onAddDevice: @escaping () -> Void,
        onManageHosts: @escaping () -> Void,
        onConnected: @escaping (HostRecord.ID) -> Void = { _ in }
    ) {
        self.model = model
        self.onAddDevice = onAddDevice
        self.onManageHosts = onManageHosts
        self.onConnected = onConnected
    }

    public var body: some View {
        Group {
            if model.hostStore.hosts.isEmpty {
                Button(action: onAddDevice) { label(presentation) }
                    .accessibilityValue("Add a device")
            } else {
                Menu {
                    hostChoices
                    Divider()
                    connectionActions
                    Divider()
                    Button("Add Device…", action: onAddDevice)
                        .accessibilityIdentifier("host.switcher.add-device")
                    Button("Manage Hosts…", action: onManageHosts)
                        .accessibilityIdentifier("host.switcher.manage-hosts")
                } label: {
                    label(presentation)
                }
                .accessibilityValue(presentation.value)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("host.switcher")
        .accessibilityLabel(presentation.title)
    }

    private var presentation: HostSwitcherPresentation {
        HostSwitcherPresentation(host: model.selectedHost, connection: model.connection)
    }

    @ViewBuilder
    private var hostChoices: some View {
        ForEach(model.hostStore.hosts) { host in
            Button {
                Task { await model.selectHost(host.id) }
            } label: {
                if host.id == model.selectedHostID {
                    Label(host.nickname, systemImage: "checkmark")
                } else {
                    Text(host.nickname)
                }
            }
            .disabled(model.isSwitchingHost)
            .accessibilityLabel("Select \(host.nickname)")
            .accessibilityIdentifier("host.switcher.host.\(Self.identifier(host.nickname))")
        }
    }

    @ViewBuilder
    private var connectionActions: some View {
        switch model.connection {
        case .connected:
            Button("Reconnect") { reconnect() }
                .accessibilityIdentifier("host.switcher.reconnect")
            Button("Disconnect") { disconnect() }
                .accessibilityIdentifier("host.switcher.disconnect")
        case .resolving, .connecting, .authenticating, .reconnecting:
            Button("Cancel connection") { disconnect() }
                .accessibilityIdentifier("host.switcher.disconnect")
        case .idle, .disconnected, .failed:
            Button("Connect") { connect() }
                .disabled(model.selectedHost == nil || model.isSwitchingHost)
                .accessibilityIdentifier("host.switcher.connect")
        }
    }

    private func label(_ presentation: HostSwitcherPresentation) -> some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            Image(systemName: presentation.glyph)
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(ConnectionPresentation.make(model.connection).tone)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
                Text(presentation.title)
                    .font(OpenPawTheme.Machine.body)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .lineLimit(1)
                Text(presentation.value)
                    .microLabel(ConnectionPresentation.make(model.connection).tone)
                    .lineLimit(1)
            }
            Spacer(minLength: OpenPawTheme.Space.small)
            Image(systemName: model.hostStore.hosts.isEmpty ? "plus" : "chevron.down")
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(OpenPawTheme.textTertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func connect() {
        Task {
            await model.connectSelectedHost()
            if model.connection.isConnected, let hostID = model.selectedHostID { onConnected(hostID) }
        }
    }

    private func reconnect() {
        Task {
            await model.disconnect()
            await model.connectSelectedHost()
            if model.connection.isConnected, let hostID = model.selectedHostID { onConnected(hostID) }
        }
    }

    private func disconnect() {
        Task { await model.disconnect() }
    }

    private static func identifier(_ title: String) -> String {
        let scalars = title.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        return String(scalars).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    }
}
