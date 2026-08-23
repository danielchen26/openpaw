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
        // Loaded speech weights are the largest thing this app holds, and the system asking for memory back is the
        // one moment where keeping them is worse than reloading them.
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
        ) { _ in
            wiring.handleMemoryWarning()
        }
    }
}

// MARK: - Wiring

/// Builds and owns the object graph.
///
/// Nothing here is a singleton and nothing reaches for a global: the model is constructed with its two backends and
/// handed down, which is what lets the same screens render in `openpaw-snapshot` against `PreviewBackend` and in tests
/// against a mock transport.
#if DEBUG && targetEnvironment(simulator)
    /// Parses the opt-in SSH target used by the live simulator harness.
    ///
    /// A nonstandard port lets the harness use its own unprivileged sshd instead of editing the developer's
    /// `~/.ssh/authorized_keys` or depending on Remote Login's port 22 configuration.
    struct DebugSSHTarget: Equatable {
        let username: String?
        let hostname: String
        let port: Int

        init?(_ value: String) {
            let whitespace = CharacterSet.whitespacesAndNewlines
            guard !value.isEmpty,
                value == value.trimmingCharacters(in: whitespace),
                value.unicodeScalars.allSatisfy({ !whitespace.contains($0) }),
                !value.contains(where: { "/?#%".contains($0) })
            else { return nil }

            let userAndAuthority = value.split(separator: "@", omittingEmptySubsequences: false)
            guard userAndAuthority.count <= 2 else { return nil }
            let authority = String(userAndAuthority.last ?? "")
            let username = userAndAuthority.count == 2 ? String(userAndAuthority[0]) : nil
            let usernameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            guard username.map({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(usernameCharacters.contains) }) ?? true
            else { return nil }

            let hostname: String
            let portText: String?
            if authority.hasPrefix("[") {
                guard let close = authority.firstIndex(of: "]") else { return nil }
                hostname = String(authority[authority.index(after: authority.startIndex)..<close])
                let remainder = authority[authority.index(after: close)...]
                if remainder.isEmpty {
                    portText = nil
                } else {
                    guard remainder.first == ":" else { return nil }
                    portText = String(remainder.dropFirst())
                }
                let ipv6Characters = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
                guard !hostname.isEmpty, hostname.unicodeScalars.allSatisfy(ipv6Characters.contains) else { return nil }
            } else {
                let hostAndPort = authority.split(separator: ":", omittingEmptySubsequences: false)
                guard hostAndPort.count <= 2 else { return nil }
                hostname = String(hostAndPort[0])
                portText = hostAndPort.count == 2 ? String(hostAndPort[1]) : nil
                let hostnameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
                guard !hostname.isEmpty, hostname.unicodeScalars.allSatisfy(hostnameCharacters.contains) else {
                    return nil
                }
            }

            guard portText?.isEmpty != true else { return nil }
            let port: Int
            if let portText {
                guard let parsed = Int(portText) else { return nil }
                port = parsed
            } else {
                port = 22
            }
            guard (1...65_535).contains(port) else { return nil }
            self.username = username
            self.hostname = hostname
            self.port = port
        }
    }
#endif

@MainActor
@Observable
final class AppWiring {

    let model: OpenPawModel
    let terminal: SSHTerminalBackend
    let hostAPI: HostAPIBackend
    let gate: GateController
    #if DEBUG && targetEnvironment(simulator)
        let debugScenario: DebugScenario?
    #endif
    let restorationStore = LocalSessionRestorationStore()
    /// Downloaded speech models. Held so the app can hand them back on a memory warning, which the model layer
    /// has no way to hear.
    let asrModels: LocalASRModelStore

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
            sessionCommandExecutor: TerminalSessionCommandExecutor(terminal: terminal),
            restorationStore: restorationStore
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
        #if DEBUG && targetEnvironment(simulator)
            let debugScenario = DebugScenario(arguments: ProcessInfo.processInfo.arguments)
            self.debugScenario = debugScenario
        #endif
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

        // A UI test can point the structured API at a daemon on this machine instead of tunnelling. Fenced so the
        // shipping build has no such path: see `debugDirectForwarder()`.
        var forwarder: any LoopbackForwarder = SSHLoopbackForwarder(
            connection: { await transportBox.get()?.connection })
        #if DEBUG && targetEnvironment(simulator)
            if let direct = Self.debugDirectForwarder() { forwarder = direct }
        #endif
        let hostAPI = HostAPIBackend(forwarder: forwarder)
        let asrModels = LocalASRModelStore()
        let appleSpeech = SpeechDictation()
        let model: OpenPawModel
        #if DEBUG && targetEnvironment(simulator)
            if let debugScenario {
                model = debugScenario.makeModel(terminal: terminal)
            } else {
                model = OpenPawModel(
                    hostStore: hosts.load(),
                    backend: hostAPI,
                    terminal: terminal,
                    dictation: appleSpeech,
                    dictationModels: asrModels,
                    dictationEngineFactory: LocalASREngineFactory(store: asrModels, apple: appleSpeech)
                )
            }
        #else
            model = OpenPawModel(
                hostStore: hosts.load(),
                backend: hostAPI,
                terminal: terminal,
                dictation: appleSpeech,
                dictationModels: asrModels,
                dictationEngineFactory: LocalASREngineFactory(store: asrModels, apple: appleSpeech)
            )
        #endif
        self.asrModels = asrModels

        let stored = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        terminalFontSize = stored > 0 ? CGFloat(stored) : TerminalSurface.defaultFontSize
        self.hosts = hosts
        self.terminal = terminal
        self.hostAPI = hostAPI
        self.model = model
        gate = GateController()

        #if DEBUG && targetEnvironment(simulator)
            Self.seedDebugKeyIfRequested(into: keychain)
        #endif

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
        #if DEBUG && targetEnvironment(simulator)
            if debugScenario == nil { await debugPairIfRequested() }
        #endif
        guard model.canRefreshRemoteState else { return }
        await model.refresh()
        model.startFollowing(session: model.selectedSessionID)
    }

    #if DEBUG && targetEnvironment(simulator)

        /// Adopts a host and a pairing code handed over on the command line, so a UI test starts up already paired.
        ///
        /// Pairing is normally a human reading a code off their workstation and typing it into a sheet, which a UI
        /// test cannot do and should not have to simulate: what the test is about is the composer, and the composer
        /// needs a session, and a session needs a paired host. This walks the app's own `pair(pairingCode:)` rather
        /// than writing credentials into the keychain behind its back, so what the test exercises afterwards is the
        /// real client with a real signer talking to a real daemon.
        ///
        /// The host record points at loopback with a placeholder credential: `DirectLoopbackForwarder` means the
        /// SSH fields are never dialled. Same fence as everything else here, DEBUG and simulator and opt-in.
        private func debugPairIfRequested() async {
            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "-openpaw-debug-pairing-code"),
                arguments.index(after: flag) < arguments.endIndex
            else { return }
            let code = arguments[arguments.index(after: flag)]

            // Where the terminal dials. The structured API does not need this — `DirectLoopbackForwarder` already
            // reaches the daemon — but `OpenPawModel` only marks the structured backend ready once the terminal is
            // connected, on purpose: it must not claim a session is live while the user cannot type into it. So
            // reaching the composer needs a host that really answers SSH, supplied with `--ssh-host`.
            let sshTarget = arguments.firstIndex(of: "-openpaw-debug-ssh-host")
                .flatMap { index -> String? in
                    let next = arguments.index(after: index)
                    return next < arguments.endIndex ? arguments[next] : nil
                }
                .flatMap(DebugSSHTarget.init)
            let seededKey = ProcessInfo.processInfo.environment["OPENPAW_DEBUG_SEED_KEY_IDENTIFIER"]
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? arguments.firstIndex(of: "-openpaw-debug-seed-key")
                    .flatMap { index -> String? in
                        let next = arguments.index(after: index)
                        return next < arguments.endIndex ? arguments[next] : nil
                    }
                    .map { ($0 as NSString).lastPathComponent }
            let auth: AuthMethod =
                seededKey
                .flatMap { try? KeychainReference(identifier: $0) }
                .map { AuthMethod.privateKey(reference: $0, passphraseRef: nil) } ?? .agentForwarding

            // A fixed id, so relaunching reuses one host instead of adding another. With a random UUID every
            // launch appended a new "Debug daemon" — nineteen of them after an afternoon — and, worse, the
            // credential is keyed by host id, so each launch looked unpaired, re-sent a single-use code, and the
            // app auto-connected to a previous run's dead port and reported a transport failure.
            let record = HostRecord(
                id: UUID(uuidString: "0BDEBE00-0000-4000-8000-00000DEBEB00") ?? UUID(),
                nickname: "Debug daemon",
                hostname: sshTarget?.hostname ?? "127.0.0.1",
                port: sshTarget?.port ?? 22,
                username: sshTarget?.username ?? "debug",
                auth: auth
            )
            model.hostStore.upsert(record)
            model.selectedHostID = record.id
            persistHosts()

            // Pair once per daemon, not once per launch and not never.
            //
            // A pairing code is single-use, and one `xcodebuild test` launches the app once per test, so pairing
            // on every launch spends the code and the later launches are told "forbidden". But skipping whenever
            // a credential exists is just as wrong in the other direction: every run starts a *fresh* daemon that
            // has never heard of the device this container is holding, so the app would present a credential the
            // host rejects and never recover. Keying on the port distinguishes the two: same daemon, reuse; new
            // daemon, pair again.
            let pairedPortKey = "openpaw.debug.pairedPort"
            let pairedPort = UserDefaults.standard.string(forKey: pairedPortKey)
            let currentPort =
                arguments.firstIndex(of: "-openpaw-debug-direct-port")
                .flatMap { index -> String? in
                    let next = arguments.index(after: index)
                    return next < arguments.endIndex ? arguments[next] : nil
                }

            // One throwaway request before the one that counts.
            //
            // The first URL request a freshly launched app makes to the simulator's loopback comes back as
            // `NSURLErrorNetworkConnectionLost`, and the daemon's log shows it never arrived, so the connection is
            // being dropped on this side before it reaches the wire. Retrying `pair` cannot repair it, because a
            // pairing code is single-use and the first attempt may have half-spent it; a GET to `/v1/health` is
            // safe to lose. Skipping this cost several runs where the app looked unpaired for no visible reason.
            if let warmUp = URL(string: "http://127.0.0.1:\(currentPort ?? "0")/v1/health") {
                _ = try? await URLSession.shared.data(from: warmUp)
            }

            do {
                try await hostAPI.connect(hostID: record.id)

                if !hostAPI.isPaired || pairedPort != currentPort {
                    try await hostAPI.pair(pairingCode: code, deviceName: "uitest")
                    UserDefaults.standard.set(currentPort, forKey: pairedPortKey)
                }

                // With an SSH target the whole path is real, so walk the same door a user walks: pairing alone
                // leaves `structuredBackendReady` false, because the model refuses to list sessions the user
                // cannot type into until the terminal is connected, and nothing else in the app presses Connect
                // for them. Without this call the sessions list stays empty forever and the composer, which is
                // the entire point of the live harness, is unreachable.
                if sshTarget != nil {
                    await model.connectSelectedHost()
                }
            } catch {
                // Deliberately not fatal. The test asserts on what the screen shows, and a failure here surfaces
                // there as an empty session list with a far more useful message than a crash on launch.
                // `print` goes to stdout, which xcodebuild does not capture from the app under test, so this
                // also leaves the reason in the container, where the runner script reads it back and reports it.
                print("debug pairing failed: \(error)")
                try? "\(error)".write(
                    to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pairing-error.txt"),
                    atomically: true, encoding: .utf8)
            }
        }

    #endif

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
        recordBareShellRestorationPlanIfNeeded()
        persistHosts()
    }

    /// The system is short of memory. A resident speech model is hundreds of megabytes held for a feature the user
    /// may not touch again this session, so it goes first — losing it costs one slow reload, and not losing it
    /// costs the whole app being killed mid-session.
    func handleMemoryWarning() {
        asrModels.releaseLoadedModels()
    }

    private func recordBareShellRestorationPlanIfNeeded() {
        guard let hostID = model.selectedHostID, model.connection.isConnected else { return }
        Task {
            let existing = await restorationStore.loadPlan(for: hostID)
            guard let plan = SessionRestorationRecorder().bareShellPlanIfAppropriate(hostID: hostID, remoteDirectory: remoteDirectory, existingPlan: existing) else { return }
            await restorationStore.save(plan)
        }
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
#if DEBUG && targetEnvironment(simulator)

    extension AppWiring {

        /// Loads a private key handed to the simulator on the command line, so a development build can reach a real
        /// host without a key-import screen the shipping app does not have.
        ///
        /// Deliberately fenced to DEBUG *and* the simulator, and driven by a launch argument rather than a file the
        /// app goes looking for: a device build has no path into this at all, and nothing happens unless someone
        /// explicitly launched with the flag. The key is stored without biometric protection because the simulator
        /// has no enrolled biometry to satisfy the check with.
        /// A forwarder that skips SSH and points the structured API at a port on this machine.
        ///
        /// Exists so a UI test can drive the app against a real `openpaw-host` running on the developer's Mac. The
        /// simulator shares the host's loopback, so a daemon on 127.0.0.1 is directly reachable and no tunnel is
        /// needed; the shipping path still has no route that works without SSH.
        ///
        /// This is what makes `testHoldingDictationAfterChoosingALocalModelDoesNotKillTheApp` able to do what its
        /// name says. The microphone lives in `ComposerView`, which needs an agent session, which needs a live
        /// daemon; without one the app shows an empty state and the crash path cannot be entered at all. That test
        /// skips rather than pretending otherwise, and this flag is how it stops skipping.
        ///
        /// Same fence and same shape as the debug key seed above: DEBUG *and* simulator, opt-in by launch
        /// argument, so a device build contains no path into it and nothing changes unless somebody asks.
        static func debugDirectForwarder() -> (any LoopbackForwarder)? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "-openpaw-debug-direct-port"),
                arguments.index(after: flag) < arguments.endIndex,
                let port = UInt16(arguments[arguments.index(after: flag)])
            else { return nil }
            return DirectLoopbackForwarder(port: port)
        }

        static func seedDebugKeyIfRequested(into keychain: KeychainStore) {
            let environment = ProcessInfo.processInfo.environment
            if let encoded = environment["OPENPAW_DEBUG_SEED_KEY_BASE64"], !encoded.isEmpty {
                guard let data = Data(base64Encoded: encoded), !data.isEmpty else {
                    assertionFailure("debug key seed data was not valid base64")
                    return
                }
                let identifier = environment["OPENPAW_DEBUG_SEED_KEY_IDENTIFIER"]
                    .flatMap { $0.isEmpty ? nil : $0 } ?? "openpaw-ui-test-key"
                storeDebugKey(data, identifier: identifier, into: keychain)
                return
            }

            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "-openpaw-debug-seed-key"),
                arguments.index(after: flag) < arguments.endIndex
            else { return }
            let path = arguments[arguments.index(after: flag)]

            guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
                assertionFailure("debug key seed requested but \(path) could not be read")
                return
            }
            let identifier = (path as NSString).lastPathComponent
            storeDebugKey(data, identifier: identifier, into: keychain)
        }

        private static func storeDebugKey(_ data: Data, identifier: String, into keychain: KeychainStore) {
            do {
                let reference = try KeychainReference(identifier: identifier)
                try keychain.store(secret: data, for: reference, requireBiometry: false)
            } catch {
                assertionFailure("debug key seed failed: \(error)")
            }
        }
    }

#endif

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

    /// The same defaults key `SettingsStore` writes from the "Require Face ID to open OpenPaw" toggle.
    ///
    /// These must not drift apart: a private key here would leave that switch flipping a value nobody reads, and a
    /// lock that silently ignores the setting is worse than no setting at all.
    static let enabledKey = "openpaw.settings.biometricGate"
    private static let graceKey = "lock.graceInterval"

    init() {
        let defaults = UserDefaults.standard
        policy = GatePolicy(
            // Absent means on: a fresh install protects pending approvals before the user has seen the setting.
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
