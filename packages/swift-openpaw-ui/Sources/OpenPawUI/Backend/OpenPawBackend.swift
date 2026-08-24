import Foundation
import OpenPawProtocol
import OpenPawTerminalCore

/// Everything the UI needs from the structured host, expressed as a protocol so that no screen imports a
/// transport. The app injects an implementation backed by `HostClient` over an SSH port forward; snapshots and
/// tests inject `PreviewBackend`.
public protocol OpenPawBackend: Sendable {
    func health() async throws -> HealthInfo
    func sessions() async throws -> [SessionSummary]
    func inbox(status: InboxStatus?) async throws -> [InboxItem]
    /// `detailAcknowledged` must be true before the host will accept a decision on an item whose risk requires
    /// the full command to be shown. The UI cannot bypass it; the host returns 400.
    func resolve(
        item: InboxItem,
        action: ActionID,
        answer: String?,
        detailAcknowledged: Bool
    ) async throws -> ResolveResult
    func dismiss(item: InboxItem) async throws -> InboxDismissResult
    func events(session: String?, afterSeq: UInt64?) -> AsyncThrowingStream<Event, any Error>
    func repos() async throws -> [RepoSummary]
    func repoStatus(_ repo: String) async throws -> RepoStatus
    func diff(repo: String, mode: DiffMode, path: String?) async throws -> Diff
    func tree(repo: String, ref: String, path: String) async throws -> [TreeEntry]
    func blob(repo: String, ref: String, path: String) async throws -> Blob
    func search(repo: String, query: String, path: String?) async throws -> [ContentMatch]
    func providers() async throws -> [ProviderStatus]
    func beginProviderAuthorization(_ provider: ProviderID) async throws -> ProviderAuthorizationStart
    func providerAuthorizationStatus(provider: ProviderID, authorizationID: String) async throws -> ProviderAuthorizationStatus
    func cancelProviderAuthorization(provider: ProviderID, authorizationID: String) async throws -> ProviderAuthorizationStatus
    func revokeProvider(_ provider: ProviderID) async throws -> ProviderStatus
    func providerRepos(_ provider: ProviderID, cursor: String?) async throws -> ProviderRepoPage
    func importRepo(_ request: RepoImportRequest) async throws -> RepoImportProgress
    func repoImportProgress(_ importID: String) async throws -> RepoImportProgress
    func cancelRepoImport(_ importID: String) async throws -> RepoImportProgress
    func registerRepo(_ request: RepoRegisterRequest) async throws -> RepoImportProgress
    func upload(data: Data, filename: String) async throws -> UploadResult
    /// URL on the local forwarded port that proxies the remote dev server. Never a public address.
    func previewURL(port: Int, path: String) throws -> URL
    func tailscaleDevices() async throws -> TailscaleDevicesResponse
    func audit(limit: Int) async throws -> [AuditEntry]
}

public extension OpenPawBackend {
    /// Keeps specialized test and preview backends source-compatible while making unsupported dismissal fail closed.
    func dismiss(item: InboxItem) async throws -> InboxDismissResult {
        throw HostClientError.badRequest("This backend does not support durable inbox dismissal.")
    }

    func providers() async throws -> [ProviderStatus] { throw HostClientError.badRequest("This backend does not support providers.") }
    func beginProviderAuthorization(_ provider: ProviderID) async throws -> ProviderAuthorizationStart { throw HostClientError.badRequest("This backend does not support provider authorization.") }
    func providerAuthorizationStatus(provider: ProviderID, authorizationID: String) async throws -> ProviderAuthorizationStatus { throw HostClientError.badRequest("This backend does not support provider authorization.") }
    func cancelProviderAuthorization(provider: ProviderID, authorizationID: String) async throws -> ProviderAuthorizationStatus { throw HostClientError.badRequest("This backend does not support provider authorization cancellation.") }
    func revokeProvider(_ provider: ProviderID) async throws -> ProviderStatus { throw HostClientError.badRequest("This backend does not support provider revocation.") }
    func providerRepos(_ provider: ProviderID, cursor: String?) async throws -> ProviderRepoPage { throw HostClientError.badRequest("This backend does not support provider repositories.") }
    func importRepo(_ request: RepoImportRequest) async throws -> RepoImportProgress { throw HostClientError.badRequest("This backend does not support repository import.") }
    func repoImportProgress(_ importID: String) async throws -> RepoImportProgress { throw HostClientError.badRequest("This backend does not support repository import.") }
    func cancelRepoImport(_ importID: String) async throws -> RepoImportProgress { throw HostClientError.badRequest("This backend does not support repository import cancellation.") }
    func registerRepo(_ request: RepoRegisterRequest) async throws -> RepoImportProgress { throw HostClientError.badRequest("This backend does not support repository registration.") }
}

/// The PTY side. Kept separate from `OpenPawBackend` because the terminal is authoritative for execution and
/// remains usable even when the structured daemon is absent — a plain SSH host with no `openpaw-host` installed
/// is a first-class configuration, not a degraded one.
public protocol StructuredBackendLifecycle: Sendable {
    var isReady: Bool { get async }
    func connect(hostID: HostRecord.ID) async throws
    func connect(hostID: HostRecord.ID, options: StructuredBackendConnectOptions) async throws
    func disconnect() async
}

public struct StructuredBackendConnectOptions: Sendable, Hashable {
    public var hostAPIPort: UInt16?
    public init(hostAPIPort: UInt16? = nil) { self.hostAPIPort = hostAPIPort }
}

public extension StructuredBackendLifecycle {
    func connect(hostID: HostRecord.ID, options: StructuredBackendConnectOptions) async throws {
        try await connect(hostID: hostID)
    }
}

public protocol OpenPawHostPairing: Sendable {
    @discardableResult
    func pair(pairingCode: String, deviceName: String) async throws -> PairingResult
}

public enum PairedHostCapabilityStatus: Sendable, Hashable {
    /// Existing installations paired before capability retention was added. The host remains authoritative.
    case unknown
    case granted
    case denied
}

/// Optional local view of the exact grants returned when this phone paired with one host.
public protocol PairedHostCapabilityProviding: Sendable {
    func pairedCapabilityStatus(_ capability: String, hostID: HostRecord.ID) -> PairedHostCapabilityStatus
}

public protocol TerminalBackend: Sendable {
    var stateStream: AsyncStream<ConnectionState> { get }
    var outputStream: AsyncStream<Data> { get }
    func connect(host: HostRecord) async throws
    func disconnect() async
    func send(text: String) async throws
    func send(chord: KeyChord, applicationCursorKeys: Bool) async throws
    func resize(columns: Int, rows: Int) async throws
    func run(command: String) async throws -> String
}

/// One owned recognition turn.
///
/// Stopping belongs to the stream that was started, not to whichever stream happens to be active later. A fast
/// stop-then-start can otherwise let an asynchronous stop from the old gesture tear down the new microphone turn.
public struct DictationTranscription: Sendable {
    public let updates: AsyncThrowingStream<DictationUpdate, any Error>
    private let stopAction: @Sendable () async -> Void

    public init(
        updates: AsyncThrowingStream<DictationUpdate, any Error>,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.updates = updates
        self.stopAction = stop
    }

    public func stop() async {
        await stopAction()
    }

    /// Closes this turn, then lets its consumer drain the final update. The timeout is a dead-engine guard, not a
    /// delay: a healthy stream returns as soon as its final result or error arrives.
    public func stopAndWait(for consumer: Task<Void, Never>?, timeout: Duration) async {
        let completion = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let stopTask = Task {
            await stop()
            await consumer?.value
            completion.continuation.yield()
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            consumer?.cancel()
            completion.continuation.yield()
        }
        defer {
            consumer?.cancel()
            stopTask.cancel()
            timeoutTask.cancel()
            completion.continuation.finish()
        }
        var iterator = completion.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

/// Speech-to-text, injected so `OpenPawUI` stays free of `Speech.framework` and stays buildable on any platform.
public protocol DictationEngine: Sendable {
    var isAvailable: Bool { get }
    /// Emits progressively refined transcripts until the returned stream finishes.
    func transcribe(locale: Locale, mode: DictationMode) -> DictationTranscription
    /// True when the words only arrive after `stop()`, because the engine transcribes a whole recording rather
    /// than a live stream.
    ///
    /// The push-to-talk controller has to know this before the finger comes up. A streaming engine has already
    /// produced text by then and can commit on release; a whole-utterance model has produced nothing, so releasing
    /// would deliver an empty string and the sentence the user just spoke would vanish.
    var deliversFinalAfterStop: Bool { get }
}

extension DictationEngine {
    /// Streaming is the assumption, so an engine written before this existed keeps its behaviour.
    public var deliversFinalAfterStop: Bool { false }
}

public enum DictationMode: String, Sendable, Codable, CaseIterable {
    /// Words land in an editable terminal draft before explicit execution.
    case terminal
    /// Words land in an editable draft that you send when you are ready.
    case composer
}

public struct DictationUpdate: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    /// True only after the engine has installed its input tap and started its audio graph.
    ///
    /// This is separate from an empty partial transcript: silence is valid recognition input, while readiness is a
    /// lifecycle event consumers can use to avoid playing test audio or announcing “Listening” too early.
    public let isReady: Bool

    public init(text: String, isFinal: Bool, isReady: Bool = false) {
        self.text = text
        self.isFinal = isFinal
        self.isReady = isReady
    }
}
