import LocalAuthentication
import OpenPawProtocol
import OpenPawSSH
import OpenPawTerminalCore
import OpenPawUI
import SwiftUI
import UIKit

@main
struct OpenPawApp: App {

    @State private var wiring = AppWiring()

    var body: some Scene {
        WindowGroup {
            AppShell(wiring: wiring)
                .preferredColorScheme(.dark)
                .tint(OpenPawTheme.textPrimary)
        }
    }
}

/// The one place the lock, the lifecycle and the root screen meet.
///
/// Separate from `OpenPawApp` because a `Scene` cannot hold `@Bindable` or read `@Environment(\.scenePhase)`, and
/// separate from `RootView` because locking is an app concern that the UI package must not know about.
struct AppShell: View {

    @Bindable var wiring: AppWiring
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch wiring.gate.decision {
            case .unlocked:
                // Built once and cached by `AppWiring`. `RootView` holds a reference-type router behind
                // `openApproval(itemID:)`, so rebuilding it on every body evaluation would reset the router's state
                // and drop a deep link mid-navigation.
                wiring.rootView()
                .sheet(item: $wiring.pastedDraft) { draft in
                    ImageAnnotationEditor(
                        draft: draft,
                        backend: wiring.hostAPI,
                        onAttached: { path in
                            wiring.attachedPaths.append(path)
                            wiring.pastedDraft = nil
                        },
                        onCancel: { wiring.pastedDraft = nil }
                    )
                }
                .confirmationDialog(
                    "Open this link?",
                    isPresented: Binding(
                        get: { wiring.pendingLink != nil },
                        set: { if !$0 { wiring.pendingLink = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    if let link = wiring.pendingLink {
                        // The full URL, in the machine register, before anything opens. Agent output is untrusted
                        // text and an OSC 8 label can say anything at all about where it points.
                        Button(link.absoluteString) {
                            UIApplication.shared.open(link)
                            wiring.pendingLink = nil
                        }
                    }
                    Button("Cancel", role: .cancel) { wiring.pendingLink = nil }
                }

            case .authenticate:
                LockScreen(
                    title: "OpenPaw is locked",
                    message: BiometricGate.prompt(for: wiring.gate.trigger),
                    failure: wiring.gate.failureMessage,
                    primaryTitle: wiring.gate.isEvaluating ? "Unlocking" : "Unlock",
                    primaryAction: { Task { await wiring.gate.authenticate() } },
                    secondary: nil
                )

            case .unavailable(let reason):
                LockScreen(
                    title: "OpenPaw cannot lock itself",
                    message: reason,
                    failure: nil,
                    primaryTitle: "Open Settings",
                    primaryAction: {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    },
                    secondary: ("Continue without the lock", { wiring.gate.disableLock() })
                )
            }
        }
        .task { await wiring.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await wiring.handleForeground() }
            case .background, .inactive:
                wiring.handleBackground()
            @unknown default:
                break
            }
        }
    }
}

// MARK: - Wiring

/// Builds and owns the object graph.
///
/// Nothing here is a singleton and nothing reaches for a global: the model is constructed with its two backends and
/// handed down, which is what lets the same screens render in `openpaw-snapshot` against `PreviewBackend` and in tests
/// against a mock transport.
@MainActor
@Observable
final class AppWiring {

    let model: OpenPawModel
    let terminal: SSHTerminalBackend
    let hostAPI: HostAPIBackend
    let gate: GateController
    let restorationStore = MemorySessionRestorationStore()

    /// A device preference, so it lives in `UserDefaults` rather than in the model, which holds host state.
    var terminalFontSize: CGFloat {
        didSet { UserDefaults.standard.set(Double(terminalFontSize), forKey: Self.fontSizeKey) }
    }

    var terminalTitle = ""
    var remoteDirectory = ""
    var pendingLink: URL?
    var pastedDraft: AttachmentDraft?
    /// Remote paths of uploaded attachments, in the order they were attached, for the composer to reference.
    var attachedPaths: [String] = []

    private static let fontSizeKey = "terminal.fontSize"
    private let hosts: HostStoreFile

    /// `RootView` is built once, not per body evaluation: it holds a reference-type router that `openApproval(itemID:)`
    /// forwards to, and a fresh copy would reset that router. `@ObservationIgnored` because caching it is not a state
    /// change any view should observe.
    @ObservationIgnored private var cachedRoot: RootView?

    func rootView() -> RootView {
        if let cachedRoot { return cachedRoot }
        let created = RootView(
            model: model,
            terminalSurface: { [weak self] in
                guard let self else { return AnyView(EmptyView()) }
                return AnyView(
                    TerminalSurface(
                        backend: terminal,
                        fontSize: fontSizeBinding,
                        onOpenLink: { [weak self] url in self?.pendingLink = url },
                        onPasteImage: { [weak self] image in self?.adoptPastedImage(image) },
                        onChangeTitle: { [weak self] title in self?.terminalTitle = title },
                        onChangeDirectory: { [weak self] directory in self?.remoteDirectory = directory }
                    )
                )
            },
            sessionSpaceProvider: LiveMultiplexerSessionSpaceProvider(runner: terminal, restorationStore: restorationStore),
            sessionCommandExecutor: TerminalSessionCommandExecutor(terminal: terminal)
        )
        cachedRoot = created
        return created
    }

    /// A binding to `terminalFontSize` for code that is not inside a view body. Pinch zoom writes through it, and the
    /// `didSet` above persists it.
    private var fontSizeBinding: Binding<CGFloat> {
        Binding(
            get: { [weak self] in self?.terminalFontSize ?? TerminalSurface.defaultFontSize },
            set: { [weak self] size in self?.terminalFontSize = size }
        )
    }

    init() {
        let hosts = HostStoreFile()
        let keychain = KeychainStore(service: "dev.openpaw.app.ssh")
        // Handed from `makeConfiguration` to `makeTransport`: the pins belong to the `HostRecord`, and only the
        // configuration reaches the factory. `connect(host:)` builds the configuration immediately before dialling, so
        // the ordering is guaranteed by the backend's own control flow.
        let pins = LockedBox<[String]>([])
        let transportBox = LockedBox<SSHTransport?>(nil)
        // The prompt has to reach the model, which does not exist yet, so the sink starts empty and is filled below.
        let promptSink = LockedBox<(@Sendable (TransportError) -> Void)?>(nil)

        let terminal = SSHTerminalBackend(
            makeTransport: { _ in
                // Host-key policy is decided synchronously from the pins the record carries, because NIOSSH asks
                // during key exchange and cannot wait for a UI round trip. An unknown or changed key fails the
                // handshake; the decision to trust happens afterwards in the sheet and is retried as a new
                // connection, so no credential is ever offered to an unverified peer.
                let pinned = pins.get()
                let transport = SSHTransport(
                    secretResolver: keychain,
                    hostKeyVerification: { fingerprint in
                        if pinned.contains(fingerprint) { return .trusted }
                        // Both verdicts carry the offered fingerprint, because the sheet has to show the user both
                        // values side by side — "the key changed" with only one of them is not a decidable statement.
                        if let expected = pinned.first {
                            return .changed(expected: expected, actual: fingerprint)
                        }
                        return .unknown(fingerprint: fingerprint)
                    }
                )
                transportBox.set(transport)
                return transport
            },
            makeConfiguration: { host in
                pins.set(host.pinnedFingerprints)
                return host.connectionConfiguration
            },
            onHostKeyProblem: { error in promptSink.get()?(error) }
        )

        let hostAPI = HostAPIBackend(
            forwarder: SSHLoopbackForwarder(connection: { await transportBox.get()?.connection })
        )
        let model = OpenPawModel(
            hostStore: hosts.load(),
            backend: hostAPI,
            terminal: terminal,
            dictation: SpeechDictation()
        )

        let stored = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        terminalFontSize = stored > 0 ? CGFloat(stored) : TerminalSurface.defaultFontSize
        self.hosts = hosts
        self.terminal = terminal
        self.hostAPI = hostAPI
        self.model = model
        gate = GateController()

        promptSink.set { error in
            Task { @MainActor in
                guard let verdict = error.hostKeyVerdict else { return }
                model.hostKeyPrompt = HostKeyPrompt(
                    host: model.selectedHost?.nickname ?? "this host",
                    verdict: verdict
                )
            }
        }
    }

    func start() async {
        guard gate.decision == .unlocked else { return }
        guard model.canRefreshRemoteState else { return }
        await model.refresh()
        model.startFollowing(session: model.selectedSessionID)
    }

    /// The terminal reports a pasted image rather than handling it, because a bitmap is a prompt attachment and a PTY
    /// has nowhere to put one.
    func adoptPastedImage(_ image: UIImage) {
        pastedDraft = AttachmentDraft(uiImage: image)
    }

    /// Re-lock if the grace period expired, then repair the connection if it died while the app was suspended.
    func handleForeground() async {
        gate.handleForeground()
        guard gate.decision == .unlocked else { return }
        await terminal.reconnectIfNeeded()
        guard model.canRefreshRemoteState else { return }
        await model.refresh()
    }

    func handleBackground() {
        gate.handleBackground()
        persistHosts()
    }

    func persistHosts() {
        hosts.save(model.hostStore)
    }
}

@MainActor
final class TerminalSessionCommandExecutor: SessionSpaceCommandExecuting {
    private let terminal: any TerminalBackend

    init(terminal: any TerminalBackend) {
        self.terminal = terminal
    }

    func executeSessionCommand(_ command: String) async throws {
        try await terminal.send(text: command + "\n")
    }
}

// MARK: - Host record bridging

extension HostRecord {
    /// Dial parameters for this record.
    ///
    /// `requestedTransport` carries the record's own preference so that `TransportSelector`'s `auto` policy runs when
    /// the user has not pinned one — the selector, not this bridge, decides between Mosh, Eternal Terminal and SSH.
    var connectionConfiguration: ConnectionConfiguration {
        ConnectionConfiguration(
            host: hostname,
            port: port,
            username: username,
            auth: auth,
            initialSize: PTYSize(columns: 80, rows: 24),
            requestedTransport: preferredTransport ?? lastSuccessfulTransport
        )
    }

    /// Every pinned fingerprint, regardless of key type. The SSH handshake callback receives only a fingerprint, so
    /// the key type cannot be part of the comparison there; `verdict(forKeyType:fingerprint:)` remains the precise
    /// check wherever the type is known.
    var pinnedFingerprints: [String] { knownHosts.map(\.fingerprint) }
}

extension TransportError {
    /// The UI-facing verdict for a host-key failure, or `nil` when this error is about something else.
    var hostKeyVerdict: OpenPawTerminalCore.HostKeyVerdict? {
        switch self {
        case .hostKeyUnknown(let fingerprint):
            .unknown(fingerprint: fingerprint)
        case .hostKeyChanged(let expected, let actual):
            .changed(expected: expected, actual: actual)
        default:
            nil
        }
    }
}

// MARK: - Host store persistence

/// `HostStore` on disk.
///
/// A file in Application Support rather than `UserDefaults`, because the store is exportable by design
/// (`HostStore.export()`) and a file is the thing a user can hand to another device. It contains no secret material —
/// every credential is a `KeychainReference` — so the app container is protection enough.
struct HostStoreFile: Sendable {

    private var url: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("hosts.json")
    }

    func load() -> HostStore {
        guard let data = try? Data(contentsOf: url) else { return HostStore() }
        return (try? HostStore.import(from: data)) ?? HostStore()
    }

    func save(_ store: HostStore) {
        guard let data = try? store.export() else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - The lock

/// Owns the gate's inputs and the `LAContext` evaluation. The *decision* is `BiometricGate.decide`, which is pure and
/// tested; this type only supplies it with timestamps and carries out what it says.
@MainActor
@Observable
final class GateController {

    private(set) var decision: GateDecision = .unlocked
    private(set) var trigger: GateTrigger = .launch
    private(set) var failureMessage: String?
    private(set) var isEvaluating = false

    var policy: GatePolicy {
        didSet {
            persist()
            refresh(trigger: trigger)
        }
    }

    private var lastUnlockedAt: Date?
    private var leftForegroundAt: Date?

    private static let enabledKey = "lock.requiresBiometrics"
    private static let graceKey = "lock.graceInterval"

    init() {
        let defaults = UserDefaults.standard
        policy = GatePolicy(
            requiresBiometrics: defaults.object(forKey: Self.enabledKey) as? Bool ?? true,
            graceInterval: defaults.object(forKey: Self.graceKey) as? Double
                ?? GatePolicy.default.graceInterval,
            unavailableReason: Self.capabilityFailure()
        )
        refresh(trigger: .launch)
    }

    /// Why this device cannot satisfy the gate, or `nil` when it can.
    ///
    /// The policy is `deviceOwnerAuthentication`, not `deviceOwnerAuthenticationWithBiometrics`, and that is the whole
    /// fallback story: it accepts Face ID, Touch ID *or* the passcode, so a wet thumb, a mask, sunglasses or five
    /// failed attempts do not lock the user out of approving a request. The only genuinely unsatisfiable case is a
    /// device with no passcode at all, and that one is reported rather than silently ignored.
    private static func capabilityFailure() -> String? {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) { return nil }
        switch error.flatMap({ LAError.Code(rawValue: $0.code) }) {
        case .passcodeNotSet:
            return "This device has no passcode. Set one in Settings to keep OpenPaw locked."
        case .biometryNotAvailable:
            return "Biometrics are unavailable on this device. Set a device passcode to keep OpenPaw locked."
        case .biometryNotEnrolled:
            return "No face or fingerprint is enrolled. Enrol one in Settings, or use your passcode."
        default:
            return "This device cannot authenticate you right now. Set a device passcode to keep OpenPaw locked."
        }
    }

    func refresh(trigger: GateTrigger) {
        self.trigger = trigger
        decision = BiometricGate.decide(
            policy: policy,
            lastUnlockedAt: lastUnlockedAt,
            leftForegroundAt: leftForegroundAt,
            now: Date()
        )
    }

    func handleBackground() {
        leftForegroundAt = Date()
    }

    func handleForeground() {
        guard let left = leftForegroundAt else {
            refresh(trigger: .launch)
            return
        }
        refresh(trigger: .returnedFromBackground(awayFor: Date().timeIntervalSince(left)))
    }

    /// Evaluates the policy. A cancellation is not a failure — the user closed the sheet and the app stays locked.
    func authenticate() async {
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }
        failureMessage = nil

        let context = LAContext()
        context.localizedCancelTitle = "Not now"
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: BiometricGate.prompt(for: trigger)
            )
            guard success else { return }
            lastUnlockedAt = Date()
            refresh(trigger: trigger)
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel {
            return
        } catch {
            failureMessage = error.localizedDescription
        }
    }

    /// Turns the lock off, for a device that cannot satisfy it. Explicit, because quietly unlocking would leave the
    /// user believing they are still protected.
    func disableLock() {
        policy.requiresBiometrics = false
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(policy.requiresBiometrics, forKey: Self.enabledKey)
        defaults.set(policy.graceInterval, forKey: Self.graceKey)
    }
}

/// The locked screen. Human register: this is the app talking to a person, not reporting machine state.
///
/// While it is showing, the real hierarchy is not merely covered — it is absent, so the app-switcher snapshot cannot
/// contain a session title or a pending approval.
struct LockScreen: View {

    let title: String
    let message: String
    let failure: String?
    let primaryTitle: String
    let primaryAction: () -> Void
    let secondary: (String, () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
            Spacer()
            Text("locked").microLabel()
            Text(title)
                .font(OpenPawTheme.Human.display)
                .foregroundStyle(OpenPawTheme.textPrimary)
            Text(message)
                .font(OpenPawTheme.Human.prose)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Text(failure)
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Button(action: primaryAction) {
                    Text(primaryTitle)
                        .font(OpenPawTheme.Machine.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .background(OpenPawTheme.panel, in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card))
                if let secondary {
                    Button(secondary.0, action: secondary.1)
                        .font(OpenPawTheme.Machine.body)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
        .padding(OpenPawTheme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OpenPawTheme.panelWarm)
    }
}
