import Foundation

/// Output the mock emits when the app writes something matching `trigger`.
public struct MockResponse: Sendable, Hashable {
    /// Substring matched against the UTF-8 text of a write.
    public var trigger: String
    public var output: Data

    public init(trigger: String, output: Data) {
        self.trigger = trigger
        self.output = output
    }

    public init(trigger: String, text: String) {
        self.init(trigger: trigger, output: Data(text.utf8))
    }
}

/// A failure to inject at a specific point in the transport's life.
public enum MockFailure: Sendable, Hashable {
    case onConnect(TransportError)
    case onWrite(TransportError)
    case onResize(TransportError)
}

/// The behaviour a ``MockTransport`` performs.
public struct MockScript: Sendable, Hashable {
    /// Emitted immediately after the transport reaches `connected`.
    public var banner: [Data]
    public var responses: [MockResponse]
    public var failure: MockFailure?
    /// Reported by the `connected` state.
    public var connectedKind: TransportKind

    public init(
        banner: [Data] = [],
        responses: [MockResponse] = [],
        failure: MockFailure? = nil,
        connectedKind: TransportKind = .ssh
    ) {
        self.banner = banner
        self.responses = responses
        self.failure = failure
        self.connectedKind = connectedKind
    }

    /// A shell-like script: a prompt banner and canned answers, enough to drive
    /// the terminal UI in previews without a network.
    public static let shellPreview = MockScript(
        banner: [Data("Last login: Thu Aug 20 14:29:11 on ttys004\r\n$ ".utf8)],
        responses: [
            MockResponse(trigger: "ls", text: "README.md  Sources  Tests\r\n$ "),
            MockResponse(trigger: "git status", text: "On branch main\r\nnothing to commit\r\n$ "),
        ]
    )
}

/// An in-memory ``RemoteTransport``.
///
/// Real enough to drive the terminal UI and the reconnection logic: it walks the
/// same state sequence a live SSH connection does, records every write and
/// resize for assertions, replays scripted output and can fail on demand.
public final class MockTransport: RemoteTransport {
    public let state: AsyncStream<ConnectionState>
    public let output: AsyncStream<Data>

    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let journal: Journal

    public init(script: MockScript = MockScript()) {
        let states = AsyncStream<ConnectionState>.makeStream(bufferingPolicy: .unbounded)
        let outputs = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        state = states.stream
        stateContinuation = states.continuation
        output = outputs.stream
        outputContinuation = outputs.continuation
        journal = Journal(script: script)
        stateContinuation.yield(.idle)
    }

    // MARK: RemoteTransport

    public func connect(configuration: ConnectionConfiguration) async throws {
        let script = await journal.recordConnect(configuration)
        stateContinuation.yield(.resolving)
        stateContinuation.yield(.connecting)
        stateContinuation.yield(.authenticating)

        if case .onConnect(let error) = script.failure {
            await journal.setConnected(false)
            stateContinuation.yield(.failed(error))
            finish()
            throw error
        }

        await journal.setConnected(true)
        stateContinuation.yield(.connected(script.connectedKind))
        for chunk in script.banner {
            outputContinuation.yield(chunk)
        }
    }

    public func write(_ data: Data) async throws {
        guard await journal.isConnected else { throw TransportError.notConnected }
        let script = await journal.script
        if case .onWrite(let error) = script.failure { throw error }
        await journal.recordWrite(data)
        let text = String(decoding: data, as: UTF8.self)
        for response in script.responses where text.contains(response.trigger) {
            outputContinuation.yield(response.output)
        }
    }

    public func resize(columns: Int, rows: Int) async throws {
        guard await journal.isConnected else { throw TransportError.notConnected }
        if case .onResize(let error) = await journal.script.failure { throw error }
        await journal.recordResize(PTYSize(columns: columns, rows: rows))
    }

    public func disconnect() async {
        guard await journal.isConnected else { return }
        await journal.setConnected(false)
        stateContinuation.yield(.disconnected(reason: nil))
        finish()
    }

    // MARK: Driving the mock

    /// Pushes output as if the host had produced it.
    public func emit(_ data: Data) {
        outputContinuation.yield(data)
    }

    /// Walks the roaming path: the link drops, the transport retries and lands
    /// back on `connected`.
    public func simulateReconnect(attempt: Int, reason: String) async {
        let script = await journal.script
        stateContinuation.yield(.reconnecting(attempt: attempt, reason: reason))
        await journal.setConnected(true)
        stateContinuation.yield(.connected(script.connectedKind))
    }

    /// Fails the session mid-flight and ends both streams.
    public func simulateFailure(_ error: TransportError) async {
        await journal.setConnected(false)
        stateContinuation.yield(.failed(error))
        finish()
    }

    private func finish() {
        stateContinuation.finish()
        outputContinuation.finish()
    }

    // MARK: Recorded activity

    public func recordedWrites() async -> [Data] { await journal.writes }

    /// Writes decoded as UTF-8, which is what assertions usually want.
    public func recordedWriteText() async -> [String] {
        await journal.writes.map { String(decoding: $0, as: UTF8.self) }
    }

    public func recordedResizes() async -> [PTYSize] { await journal.resizes }

    public func connectAttempts() async -> Int { await journal.connectAttempts }

    public func lastConfiguration() async -> ConnectionConfiguration? {
        await journal.lastConfiguration
    }

    // MARK: Mutable state

    private actor Journal {
        private(set) var script: MockScript
        private(set) var writes: [Data] = []
        private(set) var resizes: [PTYSize] = []
        private(set) var isConnected = false
        private(set) var connectAttempts = 0
        private(set) var lastConfiguration: ConnectionConfiguration?

        init(script: MockScript) {
            self.script = script
        }

        func recordConnect(_ configuration: ConnectionConfiguration) -> MockScript {
            connectAttempts += 1
            lastConfiguration = configuration
            return script
        }

        func setConnected(_ value: Bool) { isConnected = value }
        func recordWrite(_ data: Data) { writes.append(data) }
        func recordResize(_ size: PTYSize) { resizes.append(size) }
    }
}
