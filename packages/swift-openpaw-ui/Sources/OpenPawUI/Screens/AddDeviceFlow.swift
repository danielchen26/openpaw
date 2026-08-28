import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI

public struct AddDeviceCandidate: Identifiable, Sendable, Hashable {
    public enum Source: String, Sendable, Hashable {
        case tailscale
        case tailscaleAdministrator
    }
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

    public var accessibilityLabel: String {
        let sourceName = source == .tailscaleAdministrator ? "Tailscale administrator connector" : "paired host Tailscale discovery"
        return "\(nickname), \(hostname), candidate from \(sourceName), not trusted or saved"
    }

    public static func from(_ candidate: TailscaleDeviceCandidate) -> AddDeviceCandidate {
        AddDeviceCandidate(id: candidate.id, nickname: candidate.displayName, hostname: candidate.dnsName ?? candidate.tailscaleIPs.first ?? candidate.displayName, dnsName: candidate.dnsName, tailscaleIPs: candidate.tailscaleIPs, os: candidate.os, online: candidate.online)
    }

    public static func from(_ candidate: TailscaleAdminDeviceCandidate) -> AddDeviceCandidate {
        let name = candidate.name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let hostname = name.isEmpty ? (candidate.hostname ?? candidate.addresses.first ?? "") : name
        return AddDeviceCandidate(
            id: candidate.id,
            nickname: candidate.hostname ?? name,
            hostname: hostname,
            dnsName: name.isEmpty ? nil : name,
            tailscaleIPs: candidate.addresses,
            os: candidate.os,
            online: candidate.isOnline ?? false,
            source: .tailscaleAdministrator
        )
    }
}

public enum AddDeviceFlowStep: String, Sendable, Hashable {
    case welcome
    case tailscaleCandidates
    case tailscaleAdministrator
    case confirmCandidate
    case editDetails
}

public struct AddDeviceFlowState: Sendable, Hashable {
    public private(set) var step: AddDeviceFlowStep
    public var discovered: [AddDeviceCandidate]
    public private(set) var selectedCandidate: AddDeviceCandidate?
    private var editDetailsReturnStep: AddDeviceFlowStep = .welcome
    private var candidateListReturnStep: AddDeviceFlowStep = .tailscaleCandidates

    public init(
        hosts: [HostRecord],
        discovered: [AddDeviceCandidate] = [],
        initiallySelectedCandidateID: AddDeviceCandidate.ID? = nil
    ) {
        self.step = .welcome
        self.discovered = discovered
        if let initiallySelectedCandidateID,
           let candidate = discovered.first(where: { $0.id == initiallySelectedCandidateID }) {
            selectedCandidate = candidate
            candidateListReturnStep = .tailscaleCandidates
            step = .confirmCandidate
        }
    }

    public mutating func startTailscaleDiscovery() {
        selectedCandidate = nil
        step = .tailscaleCandidates
    }

    public mutating func startTailscaleAdministrator() {
        selectedCandidate = nil
        step = .tailscaleAdministrator
    }

    public mutating func selectCandidate(id: AddDeviceCandidate.ID) {
        guard let candidate = discovered.first(where: { $0.id == id }) else { return }
        if step == .tailscaleCandidates || step == .tailscaleAdministrator {
            candidateListReturnStep = step
        }
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
        case .tailscaleAdministrator:
            selectedCandidate = nil
            step = .welcome
        case .confirmCandidate:
            step = candidateListReturnStep
        case .editDetails:
            step = editDetailsReturnStep
        }
    }
}

public enum AddDeviceFlowCopy {
    public static let title = "Add a device"
    public static let tailscaleAction = "Tailscale devices"
    public static let sshAction = "Enter SSH details manually"
    public static let scanPairingAction = "Scan pairing QR"
    public static let adminAction = "Authorize with Tailnet administrator credentials"
    public static let adminRequirement = "Tailnet administrator credentials required. This is not normal Tailscale login."
    public static let honestDiscovery = "Find other tailnet devices from a connected OpenPaw host. Candidates are not trusted, saved, SSH-ready, or connected."
    public static let noCandidates = "No Tailscale devices were reported by the connected discovery host. Add SSH details to enter a device manually."
    public static let activeRouteNoHostTitle = "A Tailscale-compatible route may be active"
    public static let activeRouteNoHostExplanation = "OpenPaw found a VPN-style route that may be Tailscale. iOS does not share the signed-in Tailscale account or device list with OpenPaw. Automatic discovery needs a connected OpenPaw host to report tailnet devices, or you can authorize with Tailnet administrator credentials."
    public static let confirmation = "This is only a discovery candidate. OpenPaw will not trust it, save it, or connect until you review and save SSH details yourself."
    /// The three entries are the three ways a device can actually reach the app, and they do not overlap: find it on
    /// the tailnet, type it in, or let a QR carry everything at once. Tailnet administrator credentials are not a
    /// fourth way in — they are a second *source* for the first one, and they live inside that screen.
    public static let entryActions = [tailscaleAction, sshAction, scanPairingAction]
    public static let adminSourceHint = "Not listed? A read-only Tailnet administrator connector can supply devices when no host is connected."
    public static let requestPairingAction = "Ask this host for a pairing code"
    public static let requestPairingExplanation = "OpenPaw asks the connected host to issue a pairing code over the SSH session that is already open, then redeems it. Nobody has to walk to that machine."
    public static let scanPairingExplanation = "Scan the QR from `openpaw-host pair --qr` when this phone has never reached the machine before."
    public static let onboardingCopy = [title, tailscaleAction, sshAction, scanPairingAction, adminAction, adminRequirement, honestDiscovery, noCandidates, activeRouteNoHostTitle, activeRouteNoHostExplanation, confirmation, adminSourceHint, requestPairingAction, requestPairingExplanation, scanPairingExplanation]
}

@MainActor
public struct AddDeviceFlow: View {
    private let model: OpenPawModel
    private let settings: OpenPawSettings
    private let candidates: [AddDeviceCandidate]
    private let onOpenPawURL: (URL) -> Void
    private let onDismiss: () -> Void

    @State private var state: AddDeviceFlowState
    @State private var draft: HostDraft?
    @State private var discoveryOwner = TailscaleDiscoveryFlowID()
    @State private var adminClientID = ""
    @State private var adminClientSecret = ""
    @State private var adminTailnet = ""
    #if os(iOS) && canImport(VisionKit)
        @State private var isShowingPairingScanner = false
    #endif

    public init(
        model: OpenPawModel,
        settings: OpenPawSettings,
        candidates: [AddDeviceCandidate] = [],
        initiallySelectedCandidateID: AddDeviceCandidate.ID? = nil,
        onOpenPawURL: @escaping (URL) -> Void = { _ in },
        onDismiss: @escaping () -> Void
    ) {
        self.model = model
        self.settings = settings
        self.candidates = candidates
        self.onOpenPawURL = onOpenPawURL
        self.onDismiss = onDismiss
        _state = State(initialValue: AddDeviceFlowState(
            hosts: model.hostStore.hosts,
            discovered: candidates,
            initiallySelectedCandidateID: initiallySelectedCandidateID
        ))
    }

    @_spi(SnapshotTesting) public init(
        model: OpenPawModel,
        settings: OpenPawSettings,
        state: AddDeviceFlowState,
        draft: HostDraft? = nil,
        onOpenPawURL: @escaping (URL) -> Void = { _ in },
        onDismiss: @escaping () -> Void
    ) {
        self.model = model
        self.settings = settings
        self.candidates = state.discovered
        self.onOpenPawURL = onOpenPawURL
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
            case .tailscaleAdministrator:
                tailscaleAdministrator
            case .confirmCandidate:
                confirmCandidate
            case .editDetails:
                HostEditorView(
                    model: model,
                    settings: settings,
                    initialDraft: draft ?? HostDraft(),
                    onDismiss: {
                        model.endTailscaleDiscovery(owner: discoveryOwner)
                        onDismiss()
                    },
                    onCancel: {
                        model.endTailscaleDiscovery(owner: discoveryOwner)
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
                        model.endTailscaleDiscovery(owner: discoveryOwner)
                        onDismiss()
                    }
                }
            } else if state.step != .editDetails {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") {
                        state.back()
                    }
                }
            }
        }
        .task { model.beginTailscaleDiscovery(owner: discoveryOwner) }
        .onDisappear { model.endTailscaleDiscovery(owner: discoveryOwner) }
        #if os(iOS) && canImport(VisionKit)
            .fullScreenCover(isPresented: $isShowingPairingScanner) {
                OpenPawPairingScannerView(
                    onOpenPawURL: { url in
                        isShowingPairingScanner = false
                        Task { @MainActor in
                            await Task.yield()
                            onOpenPawURL(url)
                        }
                    },
                    onCancel: { isShowingPairingScanner = false })
            }
        #endif
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
                        entryActionButtons
                    }
                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                        entryActionButtons
                    }
                }
                pairingSection
            }
            .padding(OpenPawTheme.Space.xl)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    /// The three non-overlapping ways a device gets in. Kept in one builder so the wide and narrow layouts cannot drift.
    @ViewBuilder private var entryActionButtons: some View {
        actionButton(AddDeviceFlowCopy.tailscaleAction, glyph: "point.3.connected.trianglepath.dotted") {
            state.startTailscaleDiscovery()
        }
        actionButton(AddDeviceFlowCopy.sshAction, glyph: "terminal") {
            draft = state.startManualSSH()
        }
        scanPairingAction
    }

    /// Offered only when it can actually work: an SSH session to the host is what stands in for walking to it.
    @ViewBuilder private var pairingSection: some View {
        if model.canRequestPairingFromHost {
            Panel(label: "Pair this phone with the connected host") {
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                    Text(AddDeviceFlowCopy.requestPairingExplanation)
                        .font(OpenPawTheme.Human.prose)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    selfServicePairingContent
                }
            }
        }
    }

    @ViewBuilder private var selfServicePairingContent: some View {
        switch model.selfServicePairing {
        case .requestingCode:
            ProgressView("Asking the host for a pairing code…")
                .accessibilityIdentifier("addDevice.requestPairing.progress")
        case .pairing:
            ProgressView("Redeeming the pairing code…")
                .accessibilityIdentifier("addDevice.requestPairing.progress")
        case .paired(let result):
            Label(
                "Paired as \(result.deviceID). Capabilities: \(result.capabilities.isEmpty ? "none" : result.capabilities.joined(separator: " "))",
                systemImage: "checkmark.seal")
                .font(OpenPawTheme.Human.prose)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .accessibilityIdentifier("addDevice.requestPairing.paired")
        case .failed(let error):
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                Text(error.title)
                    .font(OpenPawTheme.Machine.headline)
                    .foregroundStyle(OpenPawTheme.caution)
                Text(error.detail)
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("addDevice.requestPairing.error")
            requestPairingButton(title: "Try again")
        case .idle:
            requestPairingButton(title: AddDeviceFlowCopy.requestPairingAction)
        }
    }

    private func requestPairingButton(title: String) -> some View {
        Button(title) {
            // Same default Quick Connect uses, so one phone appears under one name however it paired.
            Task { await model.requestPairingFromHost(deviceName: ProcessInfo.processInfo.hostName) }
        }
        .font(OpenPawTheme.Machine.headline)
        .frame(minHeight: 44)
        .accessibilityIdentifier("addDevice.requestPairing.run")
    }

    @ViewBuilder private var scanPairingAction: some View {
        #if os(iOS) && canImport(VisionKit)
            actionButton(AddDeviceFlowCopy.scanPairingAction, glyph: "qrcode.viewfinder") {
                isShowingPairingScanner = true
            }
        #endif
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
                discoveryProvenance
                let discovered = liveCandidates
                if discovered.isEmpty {
                    discoveryStatusView
                        .font(OpenPawTheme.Human.prose)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                    if !(model.tailscaleDiscovery == .noConnectedHost && model.tailscaleRouteHint == .likelyAvailable) {
                        actionButton(AddDeviceFlowCopy.sshAction, glyph: "terminal") {
                            draft = state.startManualSSH()
                        }
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
                administratorSourceEntry
            }
            .padding(OpenPawTheme.Space.xl)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    /// The administrator connector is a *source* of tailnet candidates, so it belongs on the screen that lists them.
    /// It used to sit on the welcome screen beside "Tailscale devices", where it read as a separate way to add a
    /// device and put the same destination behind two doors.
    @ViewBuilder private var administratorSourceEntry: some View {
        if !(model.tailscaleDiscovery == .noConnectedHost && model.tailscaleRouteHint == .likelyAvailable) {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                Text(AddDeviceFlowCopy.adminSourceHint)
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                actionButton(AddDeviceFlowCopy.adminAction, glyph: "person.badge.key") {
                    state.startTailscaleAdministrator()
                }
            }
        }
    }

    private var tailscaleAdministrator: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
                Text(AddDeviceFlowCopy.adminAction)
                    .font(OpenPawTheme.Human.title)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                Text(AddDeviceFlowCopy.adminRequirement)
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.caution)
                Text("Create a read-only OAuth client in the Tailscale administrator console. OpenPaw stores these credentials in this device's Keychain and requests device metadata only. It cannot read the account from the installed Tailscale app.")
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)

                adminCredentialFields
                adminConnectionContent
            }
            .padding(OpenPawTheme.Space.xl)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    private var adminCredentialFields: some View {
        Panel(label: "Tailnet administrator credentials") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                TextField("OAuth client ID", text: $adminClientID)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("addDevice.tailscaleAdmin.clientID")
                SecureField("OAuth client secret", text: $adminClientSecret)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("addDevice.tailscaleAdmin.clientSecret")
                TextField("Tailnet, for example example.ts.net", text: $adminTailnet)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("addDevice.tailscaleAdmin.tailnet")
                    .onAppear { if adminTailnet.isEmpty, let suggested = model.suggestedAdministratorTailnet { adminTailnet = suggested } }
                Button("Connect administrator source") {
                    let credentials = TailscaleAdminCredentials(
                        clientID: adminClientID,
                        clientSecret: adminClientSecret,
                        tailnet: adminTailnet
                    )
                    adminClientSecret = ""
                    Task { await model.connectTailscaleAdministrator(credentials: credentials) }
                }
                .font(OpenPawTheme.Machine.headline)
                .frame(minHeight: 44)
                .disabled(model.tailscaleAdminConnection == .connecting || model.tailscaleAdminConnection == .refreshing)
                .accessibilityIdentifier("addDevice.tailscaleAdmin.connect")
            }
        }
    }

    @ViewBuilder private var adminConnectionContent: some View {
        switch model.tailscaleAdminConnection {
        case .disconnected:
            Button("Use saved administrator connection") {
                Task { await model.refreshTailscaleAdministrator() }
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("addDevice.tailscaleAdmin.useSaved")
        case .connecting:
            ProgressView("Saving credentials securely…")
                .accessibilityIdentifier("addDevice.tailscaleAdmin.progress")
        case .refreshing:
            ProgressView("Loading read-only tailnet devices…")
                .accessibilityIdentifier("addDevice.tailscaleAdmin.progress")
        case .failure(let message):
            Text(message)
                .font(OpenPawTheme.Human.prose)
                .foregroundStyle(OpenPawTheme.caution)
                .accessibilityIdentifier("addDevice.tailscaleAdmin.error")
            Button("Retry saved connection") {
                Task { await model.refreshTailscaleAdministrator() }
            }
            .frame(minHeight: 44)
            disconnectAdministratorButton
        case .candidates(let devices):
            if devices.isEmpty {
                Text("The administrator connection returned no devices. Nothing was saved as an OpenPaw host.")
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)
            } else {
                Text("Choose a device proposal. You will still review SSH details before anything is saved or connected.")
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                ForEach(devices.map(AddDeviceCandidate.from)) { candidate in
                    Button { state.selectCandidate(id: candidate.id, from: devices.map(AddDeviceCandidate.from)) } label: {
                        candidateRow(candidate)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(candidate.accessibilityLabel)
                }
            }
            HStack {
                Button("Refresh") { Task { await model.refreshTailscaleAdministrator() } }
                    .frame(minHeight: 44)
                disconnectAdministratorButton
            }
        }
    }

    private var disconnectAdministratorButton: some View {
        Button("Disconnect and delete credentials", role: .destructive) {
            adminClientSecret = ""
            Task { await model.disconnectTailscaleAdministrator() }
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("addDevice.tailscaleAdmin.disconnect")
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
        switch model.tailscaleDiscovery {
        case .idle:
            return state.discovered
        case .candidates(let candidates):
            return candidates.map(AddDeviceCandidate.from)
        case .loading, .noConnectedHost, .empty, .permissionDenied, .unavailable, .failure:
            return []
        }
    }

    @ViewBuilder private var discoveryStatusView: some View {
        switch model.tailscaleDiscovery {
        case .idle, .loading:
            Text(model.tailscaleDiscovery == .loading ? "Looking for Tailscale devices from the connected host…" : AddDeviceFlowCopy.honestDiscovery)
                .font(OpenPawTheme.Human.prose).foregroundStyle(OpenPawTheme.textSecondary)
        case .noConnectedHost:
            if model.tailscaleRouteHint == .likelyAvailable {
                activeRouteNoHostView
            } else {
                Text("No connected discovery host. Connect a saved OpenPaw host first, authorize with Tailnet administrator credentials, or enter SSH details manually.")
                    .font(OpenPawTheme.Human.prose).foregroundStyle(OpenPawTheme.textSecondary)
            }
        case .empty:
            Text(AddDeviceFlowCopy.noCandidates).font(OpenPawTheme.Human.prose).foregroundStyle(OpenPawTheme.textSecondary)
            Button("Retry") { model.retryTailscaleDiscovery(owner: discoveryOwner) }
        case .permissionDenied(let message), .unavailable(_, let message), .failure(let message):
            Text(message).font(OpenPawTheme.Human.prose).foregroundStyle(OpenPawTheme.textSecondary)
            Button("Retry") { model.retryTailscaleDiscovery(owner: discoveryOwner) }
        case .candidates:
            EmptyView()
        }
    }

    private var activeRouteNoHostView: some View {
        Panel(label: AddDeviceFlowCopy.activeRouteNoHostTitle) {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Text(AddDeviceFlowCopy.activeRouteNoHostExplanation)
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                Text("Automatic discovery will stay host-mediated when a connected OpenPaw host is available. Manual SSH remains available.")
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                    actionButton(AddDeviceFlowCopy.adminAction, glyph: "person.badge.key") {
                        state.startTailscaleAdministrator()
                    }
                    actionButton(AddDeviceFlowCopy.sshAction, glyph: "terminal") {
                        draft = state.startManualSSH()
                    }
                }
            }
        }
    }

    @ViewBuilder private var discoveryProvenance: some View {
        if model.tailscaleRouteHint == .likelyAvailable {
            Label("A VPN route compatible with Tailscale was detected. This is a connectivity hint, not account access.", systemImage: "point.3.connected.trianglepath.dotted")
                .font(OpenPawTheme.Human.caption)
                .foregroundStyle(OpenPawTheme.textSecondary)
        }
        if let metadata = model.tailscaleDiscoveryMetadata {
            let source = metadata.source.displayName
            if let refreshedAt = metadata.refreshedAt {
                Text("Supplied by \(source) · refreshed \(RelativeTime.short(refreshedAt))")
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .accessibilityLabel("Tailscale candidates supplied by \(source)")
                    .accessibilityIdentifier("addDevice.tailscale.provenance")
            } else {
                Text("Requesting candidates from \(source)")
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textTertiary)
            }
        }
    }

    private func candidateRow(_ candidate: AddDeviceCandidate) -> some View {
        Panel(label: candidate.source == .tailscaleAdministrator ? "Administrator connector candidate" : "Tailscale candidate") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                Text(candidate.nickname).font(OpenPawTheme.Machine.title).foregroundStyle(OpenPawTheme.textPrimary)
                Text(candidate.hostname).font(OpenPawTheme.Machine.code).foregroundStyle(OpenPawTheme.textSecondary)
                Text("Proposed SSH target: \(candidate.hostname):22")
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                Text("Discovered only. Not trusted, not saved.").font(OpenPawTheme.Human.caption).foregroundStyle(OpenPawTheme.caution)
            }
        }
    }
}
