import Foundation
import OpenPawProtocol
import OpenPawSSH
import OpenPawTerminalCore
import OpenPawUI
import Security

/// Establishes the loopback tunnel that the structured host is reached through.
///
/// A protocol rather than a concrete type for two reasons: forwarding belongs to the SSH package, and expressing the
/// dependency this narrowly is what lets the backend be exercised against a local `URLProtocol` stub with no SSH at
/// all.
protocol LoopbackForwarder: Sendable {
    /// Binds a local port on 127.0.0.1 and forwards it to `remotePort` on the far side. Returns the local port.
    func start(remotePort: UInt16) async throws -> UInt16
    func stop() async
}

/// `OpenPawBackend` over `HostClient`, reached through an SSH port forward.
///
/// The daemon never listens on a routable address. It binds loopback on the machine it runs on, and this object talks
/// to it through a `direct-tcpip` channel on the SSH connection the terminal already established. That is the whole
/// security model of the structured side: there is no port to scan, no certificate to get wrong, and no path that
/// works when the SSH connection is down.
final class HostAPIBackend: OpenPawBackend, StructuredBackendLifecycle, OpenPawHostPairing, PairedHostCapabilityProviding {

    /// The port `openpaw-host` binds on the remote machine. Configurable because a user may run two hosts, and
    /// defaulted because almost nobody does.
    static let defaultRemotePort: UInt16 = 8_787

    private let forwarder: any LoopbackForwarder
    private let credentials: any DeviceCredentialStoring
    private let remotePort: UInt16
    private let urlSession: URLSession

    private let state = State()
    /// Read without awaiting by `previewURL`, which the protocol declares synchronous because a URL for a WebView is
    /// not worth an actor hop.
    private let localPort = LockedBox<UInt16?>(nil)
    private let activeHostID = LockedBox<HostRecord.ID?>(nil)
    private let lifecycleEpoch = LockedBox<Int>(0)

    init(
        forwarder: any LoopbackForwarder,
        credentials: any DeviceCredentialStoring = DeviceCredentialStore(),
        remotePort: UInt16 = HostAPIBackend.defaultRemotePort,
        urlSession: URLSession = .shared
    ) {
        self.forwarder = forwarder
        self.credentials = credentials
        self.remotePort = remotePort
        self.urlSession = urlSession
    }

    // MARK: Lifecycle

    /// Opens the tunnel and restores the stored pairing, if there is one. Idempotent: calling it again after the SSH
    /// connection dropped rebuilds the tunnel on a fresh local port.
    var isReady: Bool { get async { await state.client != nil } }

    func connect(hostID: HostRecord.ID) async throws {
        try await connect(hostID: hostID, options: StructuredBackendConnectOptions())
    }

    func connect(hostID: HostRecord.ID, options: StructuredBackendConnectOptions) async throws {
        await disconnect()
        let epoch = lifecycleEpoch.update { $0 += 1; return $0 }
        activeHostID.set(hostID)
        let attemptRemotePort = options.hostAPIPort ?? remotePort
        do {
            let port = try await forwarder.start(remotePort: attemptRemotePort)
            guard activeHostID.get() == hostID, lifecycleEpoch.get() == epoch else {
                await forwarder.stop()
                throw HostClientError.transport(URLError(.cancelled))
            }
            localPort.set(port)
            guard let base = URL(string: "http://127.0.0.1:\(port)") else {
                throw HostClientError.transport(URLError(.badURL))
            }
            let client = HostClient(baseURL: base, session: urlSession)
            if let signer = credentials.loadSigner(hostID: hostID) {
                await client.setSigner(signer)
            }
            guard activeHostID.get() == hostID, lifecycleEpoch.get() == epoch else {
                await forwarder.stop()
                throw HostClientError.transport(URLError(.cancelled))
            }
            await state.install(client: client)
        } catch {
            if activeHostID.get() == hostID, lifecycleEpoch.get() == epoch {
                await state.install(client: nil)
                localPort.set(nil)
                activeHostID.set(nil)
            }
            await forwarder.stop()
            throw error
        }
    }

    func disconnect() async {
        lifecycleEpoch.update { $0 += 1; return $0 }
        await state.install(client: nil)
        localPort.set(nil)
        activeHostID.set(nil)
        await forwarder.stop()
    }

    /// Exchanges a pairing code shown by `openpaw-host pairing-code` for a device token and HMAC key, then persists
    /// both in the keychain so the device stays paired across launches.
    ///
    /// The token alone is not enough to talk to the host: every authenticated route is also HMAC-signed over method,
    /// path, query, timestamp, nonce and body, so a token lifted from a backup is useless without the key, and a
    /// replayed request is rejected on the nonce.
    @discardableResult
    func pair(pairingCode: String, deviceName: String) async throws -> PairingResult {
        guard let hostID = activeHostID.get() else {
            throw HostClientError.transport(URLError(.notConnectedToInternet))
        }
        let epoch = lifecycleEpoch.get()
        let pairing = try await state.beginPairing(
            hostID: hostID,
            lifecycleEpoch: epoch,
            pairingCode: pairingCode,
            deviceName: deviceName
        )
        let client = pairing.client
        do {
            // The simulator can drop the first URLSession request made over a freshly opened loopback tunnel. A pairing
            // code is single-use, so it must never be that sacrificial request. Health is unauthenticated and idempotent;
            // its result is deliberately ignored, then ownership is revalidated before the code leaves this device.
            _ = try? await client.health()
            try Task.checkCancellation()
            guard activeHostID.get() == hostID, lifecycleEpoch.get() == epoch, await state.client === client else {
                throw HostClientError.transport(URLError(.cancelled))
            }
            let result = try await client.pair(
                pairingCode: pairingCode,
                deviceName: deviceName,
                platform: "ios",
                idempotencyKey: pairing.idempotencyKey
            )
            guard let signer = result.signer else {
                throw HostClientError.decoding(
                    DecodingError.dataCorrupted(
                        .init(codingPath: [], debugDescription: "the host sent an HMAC key this build cannot read")
                    )
                )
            }
            guard activeHostID.get() == hostID, lifecycleEpoch.get() == epoch, await state.client === client else {
                throw HostClientError.transport(URLError(.cancelled))
            }
            try credentials.save(result, hostID: hostID)
            await client.setSigner(signer)
            await state.endPairing(client: client, clearIdempotencyKey: true)
            return result
        } catch {
            await state.endPairing(client: client)
            throw error
        }
    }

    /// Forgets the pairing on this device. The host keeps its own record until the user revokes it there, which is
    /// why the copy says "this device" rather than "revoke".
    func unpair() async throws {
        guard let hostID = activeHostID.get() else { return }
        try credentials.clear(hostID: hostID)
        if let client = await state.client {
            await client.setSigner(nil)
        }
    }

    var isPaired: Bool { activeHostID.get().flatMap { credentials.loadSigner(hostID: $0) } != nil }

    func pairedCapabilityStatus(_ capability: String, hostID: HostRecord.ID) -> PairedHostCapabilityStatus {
        guard let capabilities = credentials.loadCapabilities(hostID: hostID) else { return .unknown }
        return capabilities.contains(capability) ? .granted : .denied
    }

    // MARK: OpenPawBackend

    func health() async throws -> HealthInfo {
        try await state.requireClient().health()
    }

    func sessions() async throws -> [SessionSummary] {
        try await state.requireClient().sessions()
    }

    func inbox(status: InboxStatus?) async throws -> [InboxItem] {
        try await state.requireClient().inbox(status: status)
    }

    /// Sends a decision.
    ///
    /// `detailAcknowledged` is forwarded rather than assumed. The host rejects an approval on a
    /// detail-expansion-required item with a 400 when the flag is false, and it writes the flag to its audit log, so
    /// the record of *who saw the full command before approving it* is kept on the machine that ran the command
    /// rather than on the phone that tapped the button.
    func resolve(
        item: InboxItem,
        action: ActionID,
        answer: String?,
        detailAcknowledged: Bool
    ) async throws -> ResolveResult {
        try await state.requireClient().resolve(
            itemID: item.id,
            action: action,
            actionToken: item.actionToken,
            answer: answer,
            detailAcknowledged: detailAcknowledged
        )
    }

    func dismiss(item: InboxItem) async throws -> InboxDismissResult {
        try await state.requireClient().dismiss(itemID: item.id)
    }

    func events(session: String?, afterSeq: UInt64?) -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [state] in
                do {
                    let client = try await state.requireClient()
                    let stream = try await client.events(session: session, afterSeq: afterSeq)
                    for try await event in stream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func repos() async throws -> [RepoSummary] {
        try await state.requireClient().repos()
    }

    func repoStatus(_ repo: String) async throws -> RepoStatus {
        try await state.requireClient().repoStatus(repo)
    }

    func diff(repo: String, mode: DiffMode, path: String?) async throws -> Diff {
        try await state.requireClient().diff(repo: repo, mode: mode, path: path)
    }

    func tree(repo: String, ref: String, path: String) async throws -> [TreeEntry] {
        try await state.requireClient().tree(repo: repo, ref: ref, path: path)
    }

    func blob(repo: String, ref: String, path: String) async throws -> Blob {
        try await state.requireClient().blob(repo: repo, ref: ref, path: path)
    }

    func search(repo: String, query: String, path: String?) async throws -> [ContentMatch] {
        try await state.requireClient().search(repo: repo, query: query, path: path)
    }

    func providers() async throws -> [ProviderStatus] { try await state.requireClient().providers() }
    func beginProviderAuthorization(_ provider: ProviderID) async throws -> ProviderAuthorizationStart { try await state.requireClient().beginProviderAuthorization(provider) }
    func providerAuthorizationStatus(provider: ProviderID, authorizationID: String) async throws -> ProviderAuthorizationStatus { try await state.requireClient().providerAuthorizationStatus(provider: provider, authorizationID: authorizationID) }
    func cancelProviderAuthorization(provider: ProviderID, authorizationID: String) async throws -> ProviderAuthorizationStatus { try await state.requireClient().cancelProviderAuthorization(provider: provider, authorizationID: authorizationID) }
    func revokeProvider(_ provider: ProviderID) async throws -> ProviderStatus { try await state.requireClient().revokeProvider(provider) }
    func providerRepos(_ provider: ProviderID, cursor: String?) async throws -> ProviderRepoPage { try await state.requireClient().providerRepos(provider, cursor: cursor) }
    func importRepo(_ request: RepoImportRequest) async throws -> RepoImportProgress { try await state.requireClient().importRepo(request) }
    func repoImportProgress(_ importID: String) async throws -> RepoImportProgress { try await state.requireClient().repoImportProgress(importID) }
    func cancelRepoImport(_ importID: String) async throws -> RepoImportProgress { try await state.requireClient().cancelRepoImport(importID) }
    func registerRepo(_ request: RepoRegisterRequest) async throws -> RepoImportProgress { try await state.requireClient().registerRepo(request) }

    func upload(data: Data, filename: String) async throws -> UploadResult {
        try await state.requireClient().upload(data: data, filename: filename)
    }

    /// The forwarded proxy URL for a remote dev server.
    ///
    /// Never a public address: the returned URL always points at 127.0.0.1 on this device, and the host proxies from
    /// there to the port the dev server bound on its own loopback. So a preview works over cellular with no exposed
    /// service anywhere, and if the tunnel is down there is simply no URL to hand out.
    func previewURL(port: Int, path: String) throws -> URL {
        guard let localPort = localPort.get() else {
            throw HostClientError.transport(URLError(.notConnectedToInternet))
        }
        guard port > 0, port <= 65_535 else {
            throw HostClientError.badRequest("\(port) is not a port a dev server can listen on")
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(localPort)
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        components.path = "/v1/preview/\(port)/" + trimmed
        guard let url = components.url else {
            throw HostClientError.badRequest("\(path) is not a path that can be previewed")
        }
        return url
    }

    func tailscaleDevices() async throws -> TailscaleDevicesResponse {
        try await state.requireClient().tailscaleDevices()
    }

    func audit(limit: Int) async throws -> [AuditEntry] {
        try await state.requireClient().audit(limit: limit)
    }

    // MARK: State

    /// The client, replaced whenever the tunnel is rebuilt on a new local port.
    private actor State {
        private struct RetainedPairing {
            let client: HostClient
            let hostID: HostRecord.ID
            let lifecycleEpoch: Int
            let pairingCode: String
            let deviceName: String
            let idempotencyKey: String

            func matches(
                client: HostClient,
                hostID: HostRecord.ID,
                lifecycleEpoch: Int,
                pairingCode: String,
                deviceName: String
            ) -> Bool {
                self.client === client
                    && self.hostID == hostID
                    && self.lifecycleEpoch == lifecycleEpoch
                    && self.pairingCode == pairingCode
                    && self.deviceName == deviceName
            }
        }

        var client: HostClient?
        private var pairingClient: HostClient?
        private var retainedPairing: RetainedPairing?

        func install(client: HostClient?) {
            self.client = client
            pairingClient = nil
            retainedPairing = nil
        }

        func requireClient() throws -> HostClient {
            guard let client else { throw HostClientError.transport(URLError(.networkConnectionLost)) }
            return client
        }

        func beginPairing(
            hostID: HostRecord.ID,
            lifecycleEpoch: Int,
            pairingCode: String,
            deviceName: String
        ) throws -> (client: HostClient, idempotencyKey: String) {
            guard let client else { throw HostClientError.transport(URLError(.networkConnectionLost)) }
            guard pairingClient == nil else {
                throw HostClientError.badRequest("Pairing is already in progress")
            }
            pairingClient = client
            if let retainedPairing,
                retainedPairing.matches(
                    client: client,
                    hostID: hostID,
                    lifecycleEpoch: lifecycleEpoch,
                    pairingCode: pairingCode,
                    deviceName: deviceName
                )
            {
                return (client, retainedPairing.idempotencyKey)
            }
            let idempotencyKey = HostClient.makePairingIdempotencyKey()
            retainedPairing = RetainedPairing(
                client: client,
                hostID: hostID,
                lifecycleEpoch: lifecycleEpoch,
                pairingCode: pairingCode,
                deviceName: deviceName,
                idempotencyKey: idempotencyKey
            )
            return (client, idempotencyKey)
        }

        func endPairing(client: HostClient, clearIdempotencyKey: Bool = false) {
            guard pairingClient === client else { return }
            pairingClient = nil
            if clearIdempotencyKey { retainedPairing = nil }
        }
    }
}

// MARK: - SSH forwarder

#if DEBUG && targetEnvironment(simulator)

    /// A `LoopbackForwarder` that forwards nothing, because the daemon is already on this machine's loopback.
    ///
    /// The simulator shares the Mac's network stack, so a real `openpaw-host` bound to 127.0.0.1 is directly
    /// reachable and no SSH channel is required to talk to it. That makes it possible for a UI test to drive the
    /// app against a live daemon, which is the only way to reach `ComposerView` and therefore the only way to
    /// press the microphone that used to abort the process on a local model.
    ///
    /// Fenced to DEBUG *and* the simulator, and only ever constructed from an explicit launch argument, so the
    /// shipping app keeps its property that there is no route to the structured API without SSH.
    actor DirectLoopbackForwarder: LoopbackForwarder {
        private let port: UInt16

        init(port: UInt16) { self.port = port }

        /// Ignores `remotePort`: the daemon is not behind a tunnel, so the caller's local port *is* the real one.
        func start(remotePort: UInt16) async throws -> UInt16 { port }
        func stop() async {}
    }

#endif

/// `LoopbackForwarder` over `OpenPawSSH.PortForwarder`.
///
/// The forwarder rides the SSH connection the terminal already opened rather than dialling its own. That is not an
/// optimisation: a second connection would need a second authentication, a second host-key decision, and would leave
/// the structured side working while the terminal is down, which would let the UI claim a session is live when the
/// user cannot type into it.
actor SSHLoopbackForwarder: LoopbackForwarder {

    /// Supplies the live connection. A closure rather than a stored `SSHConnection`, because the connection is
    /// replaced on every reconnect and a captured stale one would forward into a closed channel.
    private let connection: @Sendable () async -> SSHConnection?
    private var forwarder: PortForwarder?

    init(connection: @escaping @Sendable () async -> SSHConnection?) {
        self.connection = connection
    }

    func start(remotePort: UInt16) async throws -> UInt16 {
        await stop()
        guard let connection = await connection() else { throw TransportError.notConnected }
        let forwarder = PortForwarder(connection: connection)
        self.forwarder = forwarder
        // An ephemeral local port, always. A fixed one collides with whatever else the user is running and, worse,
        // makes the tunnel guessable by any other app on the device that can reach loopback.
        return try await forwarder.start(remotePort: remotePort)
    }

    func stop() async {
        guard let forwarder else { return }
        self.forwarder = nil
        await forwarder.stop()
    }
}

// MARK: - Device credentials

protocol DeviceCredentialStoring: Sendable {
    func save(_ result: PairingResult, hostID: HostRecord.ID) throws
    func loadSigner(hostID: HostRecord.ID) -> RequestSigner?
    func loadCapabilities(hostID: HostRecord.ID) -> Set<String>?
    func clear(hostID: HostRecord.ID) throws
}

/// The device token and HMAC key from pairing, in the keychain.
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` on purpose: these credentials authorise approving a destructive
/// command on someone's workstation, so they must not travel in an iCloud keychain to a device the user has not
/// paired, and they must not be readable while the phone is locked in a stranger's hand.
struct DeviceCredentialStore: DeviceCredentialStoring {

    static let defaultService = "dev.openpaw.app.pairing"

    private let service: String

    init(service: String = DeviceCredentialStore.defaultService) {
        self.service = service
    }

    private enum Account: String {
        case deviceID = "device_id"
        case token = "token"
        case hmacKey = "hmac_key_b64"
        case capabilities
    }

    func save(_ result: PairingResult, hostID: HostRecord.ID) throws {
        try write(result.deviceID, to: .deviceID, hostID: hostID)
        try write(result.token, to: .token, hostID: hostID)
        try write(result.hmacKeyB64, to: .hmacKey, hostID: hostID)
        let capabilities = try JSONEncoder().encode(result.capabilities.sorted())
        guard let capabilityJSON = String(data: capabilities, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode, operation: "encoding capabilities")
        }
        try write(capabilityJSON, to: .capabilities, hostID: hostID)
    }

    func loadSigner(hostID: HostRecord.ID) -> RequestSigner? {
        guard
            let deviceID = read(.deviceID, hostID: hostID),
            let token = read(.token, hostID: hostID),
            let hmacKey = read(.hmacKey, hostID: hostID)
        else { return nil }
        return RequestSigner(deviceID: deviceID, token: token, hmacKeyBase64: hmacKey)
    }

    func loadCapabilities(hostID: HostRecord.ID) -> Set<String>? {
        guard let encoded = read(.capabilities, hostID: hostID), let data = encoded.data(using: .utf8),
            let capabilities = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return Set(capabilities)
    }

    func clear(hostID: HostRecord.ID) throws {
        for account in [Account.deviceID, .token, .hmacKey, .capabilities] {
            let status = SecItemDelete(query(for: account, hostID: hostID) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status, operation: "deleting \(account.rawValue)")
            }
        }
    }

    // MARK: Keychain

    private func query(for account: Account, hostID: HostRecord.ID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "host:\(hostID.uuidString):\(account.rawValue)",
        ]
    }

    private func write(_ value: String, to account: Account, hostID: HostRecord.ID) throws {
        var attributes = query(for: account, hostID: hostID)
        SecItemDelete(attributes as CFDictionary)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status, operation: "storing \(account.rawValue)")
        }
    }

    private func read(_ account: Account, hostID: HostRecord.ID) -> String? {
        var attributes = query(for: account, hostID: hostID)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "The keychain refused \(operation): \(detail). Pair the device again."
    }
}

// MARK: - Locked box

/// One value behind one lock. Used where a `Sendable` type needs a synchronous read of state that an actor would
/// otherwise force every caller to await.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
