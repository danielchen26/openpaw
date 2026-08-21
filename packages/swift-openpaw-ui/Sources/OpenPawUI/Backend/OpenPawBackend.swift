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
    func events(session: String?, afterSeq: UInt64?) -> AsyncThrowingStream<Event, any Error>
    func repos() async throws -> [RepoSummary]
    func repoStatus(_ repo: String) async throws -> RepoStatus
    func diff(repo: String, mode: DiffMode, path: String?) async throws -> Diff
    func tree(repo: String, ref: String, path: String) async throws -> [TreeEntry]
    func blob(repo: String, ref: String, path: String) async throws -> Blob
    func search(repo: String, query: String, path: String?) async throws -> [ContentMatch]
    func upload(data: Data, filename: String) async throws -> UploadResult
    /// URL on the local forwarded port that proxies the remote dev server. Never a public address.
    func previewURL(port: Int, path: String) throws -> URL
    func tailscaleDevices() async throws -> TailscaleDevicesResponse
    func audit(limit: Int) async throws -> [AuditEntry]
}

/// The PTY side. Kept separate from `OpenPawBackend` because the terminal is authoritative for execution and
/// remains usable even when the structured daemon is absent — a plain SSH host with no `openpaw-host` installed
/// is a first-class configuration, not a degraded one.
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

/// Speech-to-text, injected so `OpenPawUI` stays free of `Speech.framework` and stays buildable on any platform.
public protocol DictationEngine: Sendable {
    var isAvailable: Bool { get }
    /// Emits progressively refined transcripts until the returned stream finishes.
    func transcribe(locale: Locale, mode: DictationMode) -> AsyncThrowingStream<DictationUpdate, any Error>
    func stop() async
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
    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}
