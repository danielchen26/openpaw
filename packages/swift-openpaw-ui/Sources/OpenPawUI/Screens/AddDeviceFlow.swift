import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI

public struct AddDeviceCandidate: Identifiable, Sendable, Hashable {
    public enum Source: String, Sendable, Hashable { case tailscale }
    public let id: String
    public var nickname: String
    public var hostname: String
    public var dnsName: String?
    public var tailscaleIPs: [String]
    public var os: String?
    public var online: Bool
    public var source: Source

    public init(id: String, nickname: String, hostname: String, dnsName: String? = nil, tailscaleIPs: [String] = [], os: String? = nil, online: Bool = false, source: Source = .tailscale) {
        self.id = id
        self.nickname = nickname
        self.hostname = hostname
        self.dnsName = dnsName
        self.tailscaleIPs = tailscaleIPs
        self.os = os
        self.online = online
        self.source = source
    }

    public init(id: UUID = UUID(), nickname: String, hostname: String, source: Source = .tailscale) {
        self.init(id: id.uuidString, nickname: nickname, hostname: hostname, source: source)
    }

    public func prefillDraft() -> HostDraft {
        HostDraft(nickname: nickname, hostname: hostname)
    }

    public var accessibilityLabel: String { "\(nickname), \(hostname), Tailscale discovery candidate, not trusted or saved" }

    public static func from(_ candidate: TailscaleDeviceCandidate) -> AddDeviceCandidate {
        AddDeviceCandidate(id: candidate.id, nickname: candidate.displayName, hostname: candidate.dnsName ?? candidate.tailscaleIPs.first ?? candidate.displayName, dnsName: candidate.dnsName, tailscaleIPs: candidate.tailscaleIPs, os: candidate.os, online: candidate.online)
    }
}

public enum AddDeviceFlowStep: String, Sendable, Hashable {
    case welcome
    case tailscaleCandidates
    case confirmCandidate
    case editDetails
}

public struct AddDeviceFlowState: Sendable, Hashable {
    public private(set) var step: AddDeviceFlowStep
    public var discovered: [AddDeviceCandidate]
    public private(set) var selectedCandidate: AddDeviceCandidate?
    private var editDetailsReturnStep: AddDeviceFlowStep = .welcome

    public init(hosts: [HostRecord], discovered: [AddDeviceCandidate] = []) {
        self.step = .welcome
        self.discovered = discovered
    }

    public mutating func startTailscaleDiscovery() {
        selectedCandidate = nil
        step = .tailscaleCandidates
    }

    public mutating func selectCandidate(id: AddDeviceCandidate.ID) {
        guard let candidate = discovered.first(where: { $0.id == id }) else { return }
        selectedCandidate = candidate
        step = .confirmCandidate
    }

    public mutating func selectCandidate(id: AddDeviceCandidate.ID, from candidates: [AddDeviceCandidate]) {
        discovered = candidates
        selectCandidate(id: id)
    }

    public mutating func selectCandidate(id: UUID) {
        selectCandidate(id: id.uuidString)
    }

    public mutating func confirmSelectedCandidate() -> HostDraft? {
        guard let candidate = selectedCandidate else { return nil }
        editDetailsReturnStep = .confirmCandidate
        step = .editDetails
        return candidate.prefillDraft()
    }

    public mutating func startManualSSH() -> HostDraft {
        selectedCandidate = nil
        editDetailsReturnStep = step
        step = .editDetails
        return HostDraft()
    }

    public mutating func back() {
        switch step {
        case .welcome:
            break
        case .tailscaleCandidates:
            selectedCandidate = nil
            step = .welcome
        case .confirmCandidate:
            step = .tailscaleCandidates
        case .editDetails:
            step = editDetailsReturnStep
        }
    }
}

public enum AddDeviceFlowCopy {
    public static let title = "Add a device"
    public static let tailscaleAction = "Find with Tailscale"
    public static let sshAction = "Add SSH details"
    public static let honestDiscovery = "Find other tailnet devices from a connected OpenPaw host. Candidates are not trusted, saved, SSH-ready, or connected."
    public static let noCandidates = "No Tailscale devices were reported by the connected discovery host. Add SSH details to enter a device manually."
    public static let confirmation = "This is only a discovery candidate. OpenPaw will not trust it, save it, or connect until you review and save SSH details yourself."
    public static let onboardingCopy = [title, tailscaleAction, sshAction, honestDiscovery, noCandidates, confirmation]
}

@MainActor
public struct AddDeviceFlow: View {
    private let model: OpenPawModel
    private let settings: OpenPawSettings
    private let candidates: [AddDeviceCandidate]
    private let onDismiss: () -> Void

    @State private var state: AddDeviceFlowState
    @State private var draft: HostDraft?

    public init(
        model: OpenPawModel,
        settings: OpenPawSettings,
        candidates: [AddDeviceCandidate] = [],
        onDismiss: @escaping () -> Void
    ) {
        self.model = model
        self.settings = settings
        self.candidates = candidates
        self.onDismiss = onDismiss
        _state = State(initialValue: AddDeviceFlowState(hosts: model.hostStore.hosts, discovered: candidates))
    }

    @_spi(SnapshotTesting) public init(
        model: OpenPawModel,
        settings: OpenPawSettings,
        state: AddDeviceFlowState,
        draft: HostDraft? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.model = model
        self.settings = settings
        self.candidates = state.discovered
        self.onDismiss = onDismiss
        _state = State(initialValue: state)
        _draft = State(initialValue: draft)
    }

    public var body: some View {
        Group {
            switch state.step {
            case .welcome:
                welcome
            case .tailscaleCandidates:
                tailscaleCandidates
            case .confirmCandidate:
                confirmCandidate
            case .editDetails:
                HostEditorView(
                    model: model,
                    settings: settings,
                    initialDraft: draft ?? HostDraft(),
                    onDismiss: {
                        model.cancelTailscaleDiscovery()
                        onDismiss()
                    },
                    onCancel: {
                        model.cancelTailscaleDiscovery()
                        state.back()
                    }
                )
            }
        }
        .background(OpenPawTheme.ink)
        .navigationTitle(AddDeviceFlowCopy.title)
        .toolbar {
            if state.step == .welcome {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        model.cancelTailscaleDiscovery()
                        onDismiss()
                    }
                }
            } else if state.step != .editDetails {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") {
                        model.cancelTailscaleDiscovery()
                        state.back()
                    }
                }
            }
        }
        .onDisappear { model.cancelTailscaleDiscovery() }
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
                SignalOrb(.discovering, size: 72)
                    .accessibilityLabel("Device setup signal")
                Text("Connect a Mac or server you control")
                    .font(OpenPawTheme.Human.display)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                Text(AddDeviceFlowCopy.honestDiscovery)
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: OpenPawTheme.Space.medium) {
                        actionButton(AddDeviceFlowCopy.tailscaleAction, glyph: "point.3.connected.trianglepath.dotted") {
                            state.startTailscaleDiscovery()
                            model.refreshTailscaleDevices()
                        }
                        actionButton(AddDeviceFlowCopy.sshAction, glyph: "terminal") {
                            model.cancelTailscaleDiscovery()
                            draft = state.startManualSSH()
                        }
                    }
                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                        actionButton(AddDeviceFlowCopy.tailscaleAction, glyph: "point.3.connected.trianglepath.dotted") {
                            state.startTailscaleDiscovery()
                            model.refreshTailscaleDevices()
                        }
                        actionButton(AddDeviceFlowCopy.sshAction, glyph: "terminal") {
                            model.cancelTailscaleDiscovery()
                            draft = state.startManualSSH()
                        }
                    }
                }
            }
            .padding(OpenPawTheme.Space.xl)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    private var tailscaleCandidates: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
                Text(AddDeviceFlowCopy.tailscaleAction)
                    .font(OpenPawTheme.Human.title)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                Text(AddDeviceFlowCopy.honestDiscovery)
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                let discovered = liveCandidates
                if discovered.isEmpty {
                    discoveryStatusView
                        .font(OpenPawTheme.Human.prose)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                    actionButton(AddDeviceFlowCopy.sshAction, glyph: "terminal") {
                        model.cancelTailscaleDiscovery()
                        draft = state.startManualSSH()
                    }
                } else {
                    ForEach(discovered) { candidate in
                        Button { state.selectCandidate(id: candidate.id, from: discovered) } label: {
                            candidateRow(candidate)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(candidate.accessibilityLabel)
                    }
                }
            }
            .padding(OpenPawTheme.Space.xl)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    private var confirmCandidate: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
                Text("Review before this becomes a host")
                    .font(OpenPawTheme.Human.title)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                Text(AddDeviceFlowCopy.confirmation)
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                if let candidate = state.selectedCandidate { candidateRow(candidate) }
                Button("Review SSH details") { draft = state.confirmSelectedCandidate() }
                    .font(OpenPawTheme.Machine.headline)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Confirm candidate and review SSH details")
            }
            .padding(OpenPawTheme.Space.xl)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    private func actionButton(_ title: String, glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: glyph)
                .font(OpenPawTheme.Machine.headline)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .padding(.horizontal, OpenPawTheme.Space.medium)
                .frame(minHeight: 44)
                .background(OpenPawTheme.graphite)
                .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card).stroke(OpenPawTheme.lineStrong))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var liveCandidates: [AddDeviceCandidate] {
        let mapped = model.tailscaleDiscovery.candidates.map(AddDeviceCandidate.from)
        return mapped.isEmpty ? state.discovered : mapped
    }

    @ViewBuilder private var discoveryStatusView: some View {
        switch model.tailscaleDiscovery {
        case .idle, .loading:
            Text(model.tailscaleDiscovery == .loading ? "Looking for Tailscale devices from the connected host…" : AddDeviceFlowCopy.honestDiscovery)
                .font(OpenPawTheme.Human.prose).foregroundStyle(OpenPawTheme.textSecondary)
        case .noConnectedHost:
            Text("No connected discovery host. Connect a saved OpenPaw host first, or add SSH details manually.")
                .font(OpenPawTheme.Human.prose).foregroundStyle(OpenPawTheme.textSecondary)
        case .empty:
            Text(AddDeviceFlowCopy.noCandidates).font(OpenPawTheme.Human.prose).foregroundStyle(OpenPawTheme.textSecondary)
            Button("Retry") { model.refreshTailscaleDevices() }
        case .unavailable(_, let message), .failure(let message):
            Text(message).font(OpenPawTheme.Human.prose).foregroundStyle(OpenPawTheme.textSecondary)
            Button("Retry") { model.refreshTailscaleDevices() }
        case .candidates:
            EmptyView()
        }
    }

    private func candidateRow(_ candidate: AddDeviceCandidate) -> some View {
        Panel(label: "Tailscale candidate") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                Text(candidate.nickname).font(OpenPawTheme.Machine.title).foregroundStyle(OpenPawTheme.textPrimary)
                Text(candidate.hostname).font(OpenPawTheme.Machine.code).foregroundStyle(OpenPawTheme.textSecondary)
                Text("Discovered only. Not trusted, not saved.").font(OpenPawTheme.Human.caption).foregroundStyle(OpenPawTheme.caution)
            }
        }
    }
}
