import Foundation
import OpenPawSSH
import OpenPawTerminalCore
import OpenPawUI

/// `TerminalBackend` over a `RemoteTransport`.
///
/// The transport is injected rather than constructed here, because which transport to use is a *policy* decision —
/// Mosh if the host has `mosh-server`, Eternal Terminal if it has `etserver`, plain SSH otherwise — and policy
/// belongs to `TransportSelector`, not to the object that pumps bytes. The app supplies the selector's output as a
/// factory; this type stays a pump plus a state machine and can therefore be exercised with `MockTransport`.
///
/// The PTY is authoritative for execution. A host with no `openpaw-host` daemon still gives a fully working terminal
/// through this object alone, which is why it holds no reference to `OpenPawBackend` and never waits on one.
actor SSHTerminalBackend: TerminalBackend {

    /// Builds a transport for a configuration. In the app this is `TransportSelector`'s decision; in tests it is a
    /// closure returning a mock.
    typealias TransportFactory = @Sendable (ConnectionConfiguration) async throws -> any RemoteTransport

    /// Maps a `HostRecord` onto the dial parameters. Injected for the same reason: the record is owned by
    /// `HostStore`, and this object should not decide what a nickname means.
    typealias ConfigurationBuilder = @Sendable (HostRecord) throws -> ConnectionConfiguration

    private let makeTransport: TransportFactory
    private let makeConfiguration: ConfigurationBuilder
    /// Called with the transport error that carries a host-key problem. The app turns it into a `HostKeyPrompt`,
    /// because the verdict's presentation — and the rule that a *changed* key has no continue path — is a UI
    /// contract, not a transport one.
    private let onHostKeyProblem: @Sendable (TransportError) -> Void

    private var transport: (any RemoteTransport)?
    private var host: HostRecord?
    private var configuration: ConnectionConfiguration?
    private var pumps: [Task<Void, Never>] = []

    private let stateRelay = Relay<ConnectionState>()
    private let outputRelay = Relay<Data>()

    /// Scrollback survives a reconnect, so a dropped connection does not erase what the agent just printed.
    private let scrollback = ScrollbackStore()

    /// Output that `run(command:)` is currently collecting. While non-nil the same bytes still reach `outputRelay`,
    /// because hiding a probe's output would leave the user staring at a terminal that silently ran something.
    private var capture: Capture?

    private var lastState: ConnectionState = .idle
    private var reconnectAttempt = 0

    init(
        makeTransport: @escaping TransportFactory,
        makeConfiguration: @escaping ConfigurationBuilder,
        onHostKeyProblem: @escaping @Sendable (TransportError) -> Void
    ) {
        self.makeTransport = makeTransport
        self.makeConfiguration = makeConfiguration
        self.onHostKeyProblem = onHostKeyProblem
    }

    // MARK: TerminalBackend

    nonisolated var stateStream: AsyncStream<ConnectionState> { stateRelay.stream() }
    nonisolated var outputStream: AsyncStream<Data> { outputRelay.stream() }

    func connect(host: HostRecord) async throws {
        await teardown(reason: nil)
        self.host = host
        let configuration = try makeConfiguration(host)
        self.configuration = configuration
        try await dial(configuration)
    }

    func disconnect() async {
        await teardown(reason: "you disconnected")
        publish(.disconnected(reason: "you disconnected"))
    }

    func send(text: String) async throws {
        guard let transport else { throw TransportError.notConnected }
        try await transport.write(Data(text.utf8))
    }

    func send(chord: KeyChord, applicationCursorKeys: Bool) async throws {
        guard let transport else { throw TransportError.notConnected }
        // Encoding lives in OpenPawTerminalCore's free `bytes(for:applicationCursorKeys:)`, not here: the
        // SS3-versus-CSI choice for cursor keys is terminal knowledge, and the mosh and Eternal Terminal transports
        // must not each re-derive it.
        try await transport.write(Data(bytes(for: chord, applicationCursorKeys: applicationCursorKeys)))
    }

    func resize(columns: Int, rows: Int) async throws {
        guard let transport else { return }
        try await transport.resize(columns: columns, rows: rows)
    }

    /// Runs one command and returns its stdout.
    ///
    /// This goes down the interactive PTY behind a nonce marker rather than opening a second exec channel, because
    /// `RemoteTransport` deliberately exposes one channel: mosh and Eternal Terminal have no second one to open. The
    /// marker is a random hex string, so no plausible command output can terminate the capture early, and the exit
    /// status rides back on the same line.
    func run(command: String) async throws -> String {
        guard transport != nil else { throw TransportError.notConnected }
        let marker = "__openpaw_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "__"
        let capture = Capture(marker: marker)
        self.capture = capture
        defer { self.capture = nil }

        // `printf` rather than `echo` because `echo` is a builtin with three incompatible dialects for escapes.
        try await send(text: "\(command); printf '%s%s\\n' \(shellQuoted(marker)) \"$?\"\n")

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { await capture.wait() }
            group.addTask {
                // A probe that never returns must not hold the caller forever; a capability check is not worth a
                // hung UI.
                try await Task.sleep(for: .seconds(15))
                throw TransportError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: Reconnect

    /// Called when the app returns to the foreground. Reconnects only when the connection actually ended, so a
    /// backgrounded-and-resumed app with a live channel is left alone.
    func reconnectIfNeeded() async {
        guard let configuration, lastState.isTerminal else { return }
        reconnectAttempt += 1
        publish(.reconnecting(attempt: reconnectAttempt, reason: "the app returned to the foreground"))
        do {
            try await dial(configuration)
        } catch {
            publish(.failed(error as? TransportError ?? .connectionFailed(String(describing: error))))
        }
    }

    // MARK: Internals

    private func dial(_ configuration: ConnectionConfiguration) async throws {
        publish(.resolving)
        let transport = try await makeTransport(configuration)
        self.transport = transport

        pumps.append(
            Task { [weak self] in
                for await state in transport.state {
                    await self?.handle(state: state)
                }
            }
        )
        pumps.append(
            Task { [weak self] in
                for await chunk in transport.output {
                    await self?.handle(output: chunk)
                }
            }
        )

        do {
            try await transport.connect(configuration: configuration)
            reconnectAttempt = 0
        } catch let error as TransportError {
            switch error {
            case .hostKeyUnknown, .hostKeyChanged:
                // Not a failure to retry: the user has to make a trust decision first, and a changed key must stop
                // the connection dead.
                onHostKeyProblem(error)
            default:
                break
            }
            publish(.failed(error))
            throw error
        }
    }

    private func handle(state: ConnectionState) {
        publish(state)
    }

    private func handle(output chunk: Data) async {
        // The view is fed from `outputRelay` first: a keystroke echo that waits on the scrollback actor is a
        // keystroke the user sees late, and latency is the whole experience of a terminal.
        outputRelay.yield(chunk)
        capture?.ingest(chunk)
        await scrollback.append(chunk)
    }

    private func publish(_ state: ConnectionState) {
        lastState = state
        stateRelay.yield(state)
    }

    private func teardown(reason: String?) async {
        for pump in pumps { pump.cancel() }
        pumps.removeAll()
        capture = nil
        if let transport {
            await transport.disconnect()
        }
        transport = nil
        if let reason { lastState = .disconnected(reason: reason) }
    }

    /// Everything the terminal has printed on this host, kept so a reconnect redraws rather than clearing.
    nonisolated var scrollbackStore: ScrollbackStore { scrollback }
}

// MARK: - Capture

/// Collects PTY output until the nonce marker arrives, then hands back everything before it.
private final class Capture: @unchecked Sendable {

    private let marker: String
    private var buffer = Data()
    private var continuation: CheckedContinuation<String, Never>?
    private let lock = NSLock()

    init(marker: String) {
        self.marker = marker
    }

    func ingest(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        guard let text = String(data: buffer, encoding: .utf8),
            let markerRange = text.range(of: marker)
        else {
            lock.unlock()
            return
        }
        // Everything before the marker is the command's own output. The echoed command line itself is the first
        // line, so it is dropped: the caller asked for output, not for a transcript.
        var output = String(text[text.startIndex..<markerRange.lowerBound])
        if let firstNewline = output.firstIndex(of: "\n") {
            output = String(output[output.index(after: firstNewline)...])
        }
        let resumed = continuation
        continuation = nil
        lock.unlock()
        resumed?.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func wait() async -> String {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }
}

// MARK: - Relay

/// A multi-consumer broadcast of a single upstream sequence.
///
/// `AsyncStream` is single-consumer, and both `stateStream` and `outputStream` are read by whoever is on screen —
/// the terminal view, the connection banner, and diagnostics can all be watching at once. Handing each caller its own
/// continuation and fanning out is the whole implementation.
final class Relay<Element: Sendable>: @unchecked Sendable {

    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private let lock = NSLock()

    func stream() -> AsyncStream<Element> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.lock()
                continuations[id] = nil
                lock.unlock()
            }
        }
    }

    func yield(_ element: Element) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for target in targets { target.yield(element) }
    }

    func finish() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for target in targets { target.finish() }
    }
}
