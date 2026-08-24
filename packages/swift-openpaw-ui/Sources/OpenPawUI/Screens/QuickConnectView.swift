import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS) && canImport(VisionKit)
    import UIKit
    import Vision
    import VisionKit
#endif

public struct OpenPawScannerPolicy: Sendable {
    public enum Outcome: Sendable, Equatable {
        case accepted(URL)
        case rejected
        case ignored
        case cancelled
    }

    public private(set) var isPaused = false
    public private(set) var isCancelled = false
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public mutating func receive(_ payload: String) -> Outcome {
        guard !isPaused, !isCancelled else { return .ignored }
        guard payload == payload.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: payload)
        else { return .rejected }

        if InboxRoute(url: url) != nil {
            isPaused = true
            return .accepted(url)
        }
        guard (try? QuickConnectLinkCodec(now: now).decode(url)) != nil else { return .rejected }
        isPaused = true
        return .accepted(url)
    }

    public mutating func cancel() -> Outcome {
        isPaused = true
        isCancelled = true
        return .cancelled
    }
}

#if os(iOS) && canImport(VisionKit)
    @MainActor
    public struct OpenPawPairingScannerView: View {
        private let onOpenPawURL: (URL) -> Void
        private let onCancel: () -> Void
        @State private var policy = OpenPawScannerPolicy()
        @State private var manualLink = ""
        @State private var message: String?
        @State private var isScanning = true
        @Environment(\.scenePhase) private var scenePhase

        public init(onOpenPawURL: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onOpenPawURL = onOpenPawURL
            self.onCancel = onCancel
        }

        public var body: some View {
            NavigationStack {
                VStack(spacing: OpenPawTheme.Space.large) {
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                        OpenPawDataScanner(isScanning: isScanning, onPayload: receive)
                            .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card).stroke(OpenPawTheme.lineStrong))
                            .accessibilityLabel("Pairing QR camera")
                    } else {
                        ContentUnavailableView(
                            "Camera scanning unavailable",
                            systemImage: "qrcode.viewfinder",
                            description: Text("Paste the pairing link below instead."))
                    }

                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                        Text("Manual pairing link")
                            .font(OpenPawTheme.Machine.headline)
                            .foregroundStyle(OpenPawTheme.textPrimary)
                        SecureField("Paste pairing link", text: $manualLink)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                            .accessibilityLabel("Pairing link")
                        Button("Use pairing link") { _ = receive(manualLink) }
                            .disabled(manualLink.isEmpty || policy.isPaused)
                    }

                    if let message {
                        Text(message)
                            .font(OpenPawTheme.Human.caption)
                            .foregroundStyle(OpenPawTheme.caution)
                            .accessibilityLabel(message)
                    }
                }
                .padding(OpenPawTheme.Space.large)
                .background(OpenPawTheme.ink)
                .navigationTitle("Scan pairing QR")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { cancel() }
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { isScanning = false }
            }
            .onDisappear {
                isScanning = false
                manualLink = ""
            }
        }

        @discardableResult
        private func receive(_ payload: String) -> Bool {
            switch policy.receive(payload) {
            case .accepted(let url):
                isScanning = false
                manualLink = ""
                message = nil
                onOpenPawURL(url)
                return true
            case .rejected:
                message = "That is not a valid OpenPaw pairing link."
                return false
            case .ignored, .cancelled:
                return false
            }
        }

        private func cancel() {
            _ = policy.cancel()
            isScanning = false
            manualLink = ""
            onCancel()
        }
    }

    @available(iOS 16.0, *)
    private struct OpenPawDataScanner: UIViewControllerRepresentable {
        var isScanning: Bool
        var onPayload: (String) -> Bool

        func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: [.qr])],
                qualityLevel: .balanced,
                recognizesMultipleItems: false,
                isHighFrameRateTrackingEnabled: false,
                isPinchToZoomEnabled: true,
                isGuidanceEnabled: true,
                isHighlightingEnabled: true)
            scanner.delegate = context.coordinator
            return scanner
        }

        func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
            context.coordinator.onPayload = onPayload
            if isScanning, !scanner.isScanning {
                try? scanner.startScanning()
            } else if !isScanning, scanner.isScanning {
                scanner.stopScanning()
            }
        }

        static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
            scanner.stopScanning()
        }

        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            var onPayload: (String) -> Bool

            init(onPayload: @escaping (String) -> Bool) {
                self.onPayload = onPayload
            }

            func dataScanner(
                _ dataScanner: DataScannerViewController,
                didAdd addedItems: [RecognizedItem],
                allItems: [RecognizedItem]
            ) {
                for item in addedItems {
                    guard case .barcode(let barcode) = item,
                          let payload = barcode.payloadStringValue
                    else { continue }
                    if onPayload(payload) { dataScanner.stopScanning() }
                    return
                }
            }
        }
    }
#endif

public enum QuickConnectCopy {
    public static let primaryAction = "Confirm SSH credential and connect"
    public static let passwordImport = "Use a password"
    public static let privateKeyImport = "Import a private key"
    public static let verifyFirstConnection = "Verify on first connection"
}

public enum QuickConnectAccessibility {
    public static let proposal = "quick-connect.proposal"
    public static let target = "quick-connect.target"
    public static let username = "quick-connect.username"
    public static let credentialSelector = "quick-connect.credential-selector"
    public static let primaryAction = "quick-connect.confirm"
    public static let progressStage = "quick-connect.progress-stage"
    public static let failureStage = "quick-connect.failure-stage"
    public static let password = "quick-connect.password"
    public static let privateKey = "quick-connect.private-key"
    public static let passphrase = "quick-connect.passphrase"

    public static let all = [
        proposal, target, username, credentialSelector, primaryAction, progressStage, failureStage,
        password, privateKey, passphrase,
    ]
}

public struct QuickConnectCredentialOption: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case existing(AuthMethod)
        case passwordImport
        case privateKeyImport
    }

    public var id: String
    public var label: String
    public var kind: Kind

    public init(id: String, label: String, kind: Kind) {
        self.id = id
        self.label = label
        self.kind = kind
    }

    public var choice: QuickConnectCredentialChoice? {
        guard case .existing(let auth) = kind else { return nil }
        return .existing(auth)
    }
}

public struct QuickConnectPresentation: Sendable, Hashable {
    public var proposal: QuickConnectProposal
    public var selectedTargetIndex: Int
    public var username: String
    public var credentialOptions: [QuickConnectCredentialOption]
    public var selectedCredential: QuickConnectCredentialOption?
    public var now: Date

    public init(proposal: QuickConnectProposal, hostStore: HostStore, now: Date = Date()) {
        self.proposal = proposal
        self.selectedTargetIndex = 0
        self.now = now

        let matching = proposal.username.isEmpty
            ? proposal.canonicalMatchingHosts(in: hostStore)
            : hostStore.hosts.filter { proposal.matches(existing: $0) }
        let canonical = matching.count == 1 ? matching.first : nil
        self.username = proposal.username.isEmpty ? (canonical?.username ?? "") : proposal.username

        let existing = matching.map { host in
            QuickConnectCredentialOption(
                id: "saved-\(host.id.uuidString.lowercased())",
                label: "\(host.nickname) · \(Self.authLabel(host.auth))",
                kind: .existing(host.auth))
        }
        self.credentialOptions = existing + [
            QuickConnectCredentialOption(id: "import-password", label: QuickConnectCopy.passwordImport, kind: .passwordImport),
            QuickConnectCredentialOption(id: "import-private-key", label: QuickConnectCopy.privateKeyImport, kind: .privateKeyImport),
        ]
        self.selectedCredential = canonical.flatMap { host in
            existing.first { option in
                guard case .existing(let auth) = option.kind else { return false }
                return auth == host.auth
            }
        }
    }

    public var target: QuickConnectTarget? {
        proposal.targets.indices.contains(selectedTargetIndex) ? proposal.targets[selectedTargetIndex] : nil
    }

    public var canConfirm: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && target != nil && selectedCredential?.choice != nil
    }

    public var accessibilityIdentifiers: [String] { QuickConnectAccessibility.all }

    private static func authLabel(_ auth: AuthMethod) -> String {
        switch auth {
        case .password: "Saved password"
        case .privateKey: "Saved private key"
        case .agentForwarding: "Saved SSH agent"
        }
    }
}

public enum QuickConnectScreenState: Sendable, Hashable {
    case reviewing
    case connecting(String)
    case awaitingHostTrust
    case expired
    case failed(message: String, allowsPairingRetry: Bool)
    case connected

    public var primaryActionTitle: String? {
        switch self {
        case .reviewing: QuickConnectCopy.primaryAction
        case .connected: "Open Terminal"
        case .connecting, .awaitingHostTrust, .expired, .failed: nil
        }
    }

    public static func from(stage: QuickConnectCoordinator.Stage, proposal: QuickConnectProposal?, now: Date) -> QuickConnectScreenState {
        if case .reviewing = stage, let expiry = proposal?.expiresAt, expiry <= now { return .expired }
        return switch stage {
        case .idle, .reviewing: .reviewing
        case .installingCredential: .connecting("Securing credential")
        case .savingHost: .connecting("Saving host")
        case .connectingSSH: .connecting("Connecting SSH")
        case .awaitingHostTrust: .awaitingHostTrust
        case .openingHostAPI: .connecting("Opening OpenPaw")
        case .pairing: .connecting("Pairing device")
        case .loadingWorkspace: .connecting("Loading workspace")
        case .connected: .connected
        case .failed(let point, let message):
            .failed(message: message, allowsPairingRetry: point == .openingHostAPI || point == .pairing)
        case .cancelled: .failed(message: "Quick Connect was cancelled.", allowsPairingRetry: false)
        }
    }
}

@_spi(SnapshotTesting)
public struct QuickConnectSnapshot: Sendable, Hashable {
    public var presentation: QuickConnectPresentation
    public var state: QuickConnectScreenState

    public init(presentation: QuickConnectPresentation, state: QuickConnectScreenState) {
        self.presentation = presentation
        self.state = state
    }
}

@MainActor
public struct QuickConnectView: View {
    private let coordinator: QuickConnectCoordinator?
    private let proposal: QuickConnectProposal
    private let now: () -> Date
    private let snapshotState: QuickConnectScreenState?
    private let onCancel: () -> Void
    private let onConnected: () -> Void

    @State private var targetIndex: Int
    @State private var username: String
    @State private var credentialOptions: [QuickConnectCredentialOption]
    @State private var selectedCredentialID: String?
    @State private var isChangingCredential = false
    @State private var passwordLabel = ""
    @State private var password = ""
    @State private var privateKeyLabel = ""
    @State private var privateKey = Data()
    @State private var privateKeyFilename: String?
    @State private var passphrase = ""
    @State private var isImportingPrivateKey = false

    public init(
        coordinator: QuickConnectCoordinator,
        hostStore: HostStore,
        now: @escaping () -> Date = Date.init,
        onCancel: @escaping () -> Void,
        onConnected: @escaping () -> Void
    ) {
        let proposal = coordinator.proposal ?? QuickConnectProposal(
            id: "unavailable", version: 1, issuedAt: nil, expiresAt: nil, sessionID: nil,
            hostAPIPort: nil, profile: nil, pairingCode: nil, nickname: "Unavailable", username: "",
            dnsName: nil, tailscaleIPs: [], online: false, targets: [], hostKeys: [], envelope: nil)
        let presentation = QuickConnectPresentation(proposal: proposal, hostStore: hostStore, now: now())
        self.coordinator = coordinator
        self.proposal = proposal
        self.now = now
        self.snapshotState = nil
        self.onCancel = onCancel
        self.onConnected = onConnected
        _targetIndex = State(initialValue: presentation.selectedTargetIndex)
        _username = State(initialValue: presentation.username)
        _credentialOptions = State(initialValue: presentation.credentialOptions)
        _selectedCredentialID = State(initialValue: presentation.selectedCredential?.id)
    }

    @_spi(SnapshotTesting)
    public init(snapshot: QuickConnectSnapshot) {
        let presentation = snapshot.presentation
        self.coordinator = nil
        self.proposal = presentation.proposal
        self.now = { presentation.now }
        self.snapshotState = snapshot.state
        self.onCancel = {}
        self.onConnected = {}
        _targetIndex = State(initialValue: presentation.selectedTargetIndex)
        _username = State(initialValue: presentation.username)
        _credentialOptions = State(initialValue: presentation.credentialOptions)
        _selectedCredentialID = State(initialValue: presentation.selectedCredential?.id)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.xl) {
                    identityHeader
                    endpointPanel
                    credentialPanel
                    statusPanel
                    actions
                }
                .padding(OpenPawTheme.Space.xl)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .background(OpenPawTheme.void)
            .navigationTitle("Quick Connect to \(proposal.nickname)")
            .accessibilityIdentifier(QuickConnectAccessibility.proposal)
        }
        .fileImporter(
            isPresented: $isImportingPrivateKey,
            allowedContentTypes: [.data, .plainText],
            allowsMultipleSelection: false,
            onCompletion: importPrivateKey)
    }

    private var screenState: QuickConnectScreenState {
        snapshotState ?? QuickConnectScreenState.from(stage: coordinator?.stage ?? .reviewing, proposal: proposal, now: now())
    }

    private var selectedOption: QuickConnectCredentialOption? {
        credentialOptions.first { $0.id == selectedCredentialID }
    }

    private var identityHeader: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            Text("quick connect / reviewed SSH handoff")
                .font(OpenPawTheme.Machine.label)
                .foregroundStyle(OpenPawTheme.signal)
            Text("Quick Connect to \(proposal.nickname)")
                .font(OpenPawTheme.Human.title)
                .foregroundStyle(OpenPawTheme.textPrimary)
            Text("Review the endpoint and choose the SSH credential this device may use. Nothing is submitted until you confirm.")
                .font(OpenPawTheme.Human.prose)
                .foregroundStyle(OpenPawTheme.textSecondary)
        }
    }

    private var endpointPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Text("SSH endpoint")
                    .font(OpenPawTheme.Machine.title)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                Picker("Target", selection: $targetIndex) {
                    ForEach(Array(proposal.targets.enumerated()), id: \.offset) { index, target in
                        Text("\(target.hostname) · \(sourceLabel(target.source))").tag(index)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier(QuickConnectAccessibility.target)
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .accessibilityIdentifier(QuickConnectAccessibility.username)
                if let target = selectedTarget {
                    metadataRow("Port", value: String(target.port))
                    metadataRow("Source", value: sourceLabel(target.source))
                }
                metadataRow("Status", value: proposal.online ? "Online" : "Offline")
                metadataRow("Host key", value: proposal.hostKeys.first?.fingerprint ?? QuickConnectCopy.verifyFirstConnection)
                metadataRow("Profile", value: proposal.profile?.rawValue.capitalized ?? "SSH only")
                metadataRow("Pairing expiry", value: expiryLabel)
            }
        }
    }

    private var credentialPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                HStack {
                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                        Text("SSH credential")
                            .font(OpenPawTheme.Machine.title)
                            .foregroundStyle(OpenPawTheme.textPrimary)
                        Text(selectedOption?.label ?? "Choose a credential")
                            .font(OpenPawTheme.Machine.body)
                            .foregroundStyle(OpenPawTheme.textSecondary)
                    }
                    Spacer()
                    Button("Change") { isChangingCredential.toggle() }
                        .buttonStyle(.bordered)
                }
                if isChangingCredential || selectedOption == nil {
                    Picker("Credential", selection: $selectedCredentialID) {
                        Text("Choose a credential").tag(String?.none)
                        ForEach(credentialOptions) { option in
                            Text(option.label).tag(Optional(option.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier(QuickConnectAccessibility.credentialSelector)
                }
                importFields
            }
        }
    }

    @ViewBuilder
    private var importFields: some View {
        switch selectedOption?.kind {
        case .passwordImport:
            TextField("Credential label", text: $passwordLabel)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(QuickConnectAccessibility.password)
        case .privateKeyImport:
            TextField("Credential label", text: $privateKeyLabel)
                .textFieldStyle(.roundedBorder)
            Button(privateKeyFilename.map { "Private key selected: \($0)" } ?? "Choose private key file") {
                isImportingPrivateKey = true
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(QuickConnectAccessibility.privateKey)
            SecureField("Passphrase (optional)", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(QuickConnectAccessibility.passphrase)
        case .existing, nil:
            EmptyView()
        }
    }

    private var statusPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                switch screenState {
                case .reviewing:
                    stage("Ready for credential confirmation", symbol: "checkmark.shield")
                case .connecting(let title):
                    ProgressView()
                    stage(title, symbol: "arrow.triangle.2.circlepath")
                case .awaitingHostTrust:
                    stage("Waiting for host key verification", symbol: "key.horizontal")
                    Text("Review the SSH fingerprint in the host key sheet. Changed keys remain blocked.")
                        .font(OpenPawTheme.Human.prose)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                case .expired:
                    stage("Pairing link expired", symbol: "clock.badge.exclamationmark")
                        .accessibilityIdentifier(QuickConnectAccessibility.failureStage)
                    Text("Generate a new Quick Connect link on the Mac and try again.")
                        .font(OpenPawTheme.Human.prose)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                case .failed(let message, let allowsPairingRetry):
                    stage("Quick Connect failed", symbol: "exclamationmark.triangle")
                        .accessibilityIdentifier(QuickConnectAccessibility.failureStage)
                    Text(message)
                        .font(OpenPawTheme.Human.prose)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                    if allowsPairingRetry {
                        Text("SSH remains connected. Retry repeats pairing only.")
                            .font(OpenPawTheme.Human.caption)
                            .foregroundStyle(OpenPawTheme.textTertiary)
                    }
                case .connected:
                    stage("Connected", symbol: "checkmark.circle.fill")
                    Text("The host is saved and Terminal is ready.")
                        .font(OpenPawTheme.Human.prose)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                }
            }
        }
        .accessibilityIdentifier(QuickConnectAccessibility.progressStage)
    }

    private var actions: some View {
        HStack(spacing: OpenPawTheme.Space.medium) {
            Button("Cancel", role: .cancel) {
                coordinator?.cancel()
                onCancel()
            }
            .buttonStyle(.bordered)
            Spacer()
            switch screenState {
            case .reviewing:
                Button(QuickConnectCopy.primaryAction) { confirm() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConfirm)
                    .accessibilityIdentifier(QuickConnectAccessibility.primaryAction)
            case .failed(_, let allowsPairingRetry) where allowsPairingRetry:
                Button("Retry") { coordinator?.retryPairing() }
                    .buttonStyle(.borderedProminent)
            case .connected:
                Button("Open Terminal") { onConnected() }
                    .buttonStyle(.borderedProminent)
            case .connecting, .awaitingHostTrust, .expired, .failed:
                EmptyView()
            }
        }
    }

    private var selectedTarget: QuickConnectTarget? {
        proposal.targets.indices.contains(targetIndex) ? proposal.targets[targetIndex] : nil
    }

    private var canConfirm: Bool {
        guard selectedTarget != nil, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch selectedOption?.kind {
        case .existing: return true
        case .passwordImport: return !passwordLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
        case .privateKeyImport: return !privateKeyLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !privateKey.isEmpty
        case nil: return false
        }
    }

    private func confirm() {
        guard let target = selectedTarget, let option = selectedOption else { return }
        let choice: QuickConnectCredentialChoice?
        switch option.kind {
        case .existing(let auth):
            choice = .existing(auth)
        case .passwordImport:
            choice = .password(label: passwordLabel, secret: password)
        case .privateKeyImport:
            choice = .privateKey(
                label: privateKeyLabel,
                key: privateKey,
                passphraseLabel: passphrase.isEmpty ? nil : "\(privateKeyLabel) passphrase",
                passphrase: passphrase.isEmpty ? nil : passphrase)
        }
        guard let choice else { return }
        coordinator?.confirm(choice, target: target, username: username)
    }

    private func importPrivateKey(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        privateKey = data
        privateKeyFilename = url.lastPathComponent
        if privateKeyLabel.isEmpty { privateKeyLabel = url.deletingPathExtension().lastPathComponent }
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(OpenPawTheme.Human.caption)
                .foregroundStyle(OpenPawTheme.textTertiary)
            Spacer(minLength: OpenPawTheme.Space.medium)
            Text(value)
                .font(OpenPawTheme.Machine.code)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func stage(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(OpenPawTheme.Machine.body)
            .foregroundStyle(OpenPawTheme.textPrimary)
    }

    private func sourceLabel(_ source: QuickConnectTarget.Source) -> String {
        switch source {
        case .magicDNS: "MagicDNS"
        case .tailnet: "Tailnet address"
        case .explicit: "Explicit host"
        }
    }

    private var expiryLabel: String {
        guard let expiresAt = proposal.expiresAt else { return "Not required for SSH-only connection" }
        let seconds = max(0, Int(expiresAt.timeIntervalSince(now())))
        if seconds == 0 { return "Expired" }
        let minutes = max(1, Int(ceil(Double(seconds) / 60)))
        return "\(minutes) min remaining"
    }
}
