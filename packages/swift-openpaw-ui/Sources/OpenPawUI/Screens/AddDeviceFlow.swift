import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI

public struct AddDeviceCandidate: Identifiable, Sendable, Hashable {
    public enum Source: String, Sendable, Hashable { case tailscale }
    public let id: UUID
    public var nickname: String
    public var hostname: String
    public var source: Source

    public init(id: UUID = UUID(), nickname: String, hostname: String, source: Source = .tailscale) {
        self.id = id
        self.nickname = nickname
        self.hostname = hostname
        self.source = source
    }

    public func prefillDraft() -> HostDraft {
        HostDraft(nickname: nickname, hostname: hostname)
    }

    public var accessibilityLabel: String {
        "\(nickname), \(hostname), discovery candidate, not trusted or saved"
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
    public static let honestDiscovery = "Automatic Tailscale discovery is not connected yet. If a candidate appears here, review it before adding SSH details."
    public static let noCandidates = "No Tailscale candidates are available from this build. Automatic discovery is not connected. Add SSH details to enter a device manually."
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
                    onDismiss: onDismiss,
                    onCancel: { state.back() }
                )
            }
        }
        .background(OpenPawTheme.ink)
        .navigationTitle(AddDeviceFlowCopy.title)
        .toolbar {
            if state.step == .welcome {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: onDismiss) }
            } else if state.step != .editDetails {
                ToolbarItem(placement: .cancellationAction) { Button("Back") { state.back() } }
            }
        }
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
                        }
                        actionButton(AddDeviceFlowCopy.sshAction, glyph: "terminal") {
                            draft = state.startManualSSH()
                        }
                    }
                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                        actionButton(AddDeviceFlowCopy.tailscaleAction, glyph: "point.3.connected.trianglepath.dotted") {
                            state.startTailscaleDiscovery()
                        }
                        actionButton(AddDeviceFlowCopy.sshAction, glyph: "terminal") {
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
                if state.discovered.isEmpty {
                    Text(AddDeviceFlowCopy.noCandidates)
                        .font(OpenPawTheme.Human.prose)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                    actionButton(AddDeviceFlowCopy.sshAction, glyph: "terminal") {
                        draft = state.startManualSSH()
                    }
                } else {
                    ForEach(state.discovered) { candidate in
                        Button { state.selectCandidate(id: candidate.id) } label: {
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
