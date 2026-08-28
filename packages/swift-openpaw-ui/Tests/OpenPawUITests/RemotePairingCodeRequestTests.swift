import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import Testing

@testable import OpenPawUI

/// A phone that can already open an SSH session to a machine has proven what a pairing code is there to prove. These
/// tests pin the parsing and failure classification of that self-service path, because the only thing standing between
/// "smooth" and "a code got misread into a mystery failure" is how strictly the output is read.
@Suite("Requesting a pairing code from the connected host")
struct RemotePairingCodeRequestTests {

    private struct StubRunner: CommandRunner {
        let result: @Sendable (String) async throws -> String
        func run(_ command: String) async throws -> String { try await result(command) }
    }

    private static let validCode = "K3F2-9QAM-7XZP-4TWC-6BND-2HRS"

    @Test("A code alone on stdout is read exactly")
    func readsBareCode() async throws {
        let request = RemotePairingCodeRequest(runner: StubRunner { _ in Self.validCode + "\n" })
        #expect(try await request.requestCode() == Self.validCode)
    }

    @Test("A chatty login shell does not hide the code")
    func readsCodeAmongShellNoise() async throws {
        let output = """
            Welcome to Ubuntu 24.04 LTS
            You have mail.
            \(Self.validCode)
            """
        let request = RemotePairingCodeRequest(runner: StubRunner { _ in output })
        #expect(try await request.requestCode() == Self.validCode)
    }

    @Test("Output that is not a code is refused rather than sent to the host as one")
    func refusesNonCodeOutput() async {
        let request = RemotePairingCodeRequest(runner: StubRunner { _ in "usage: openpaw-host [OPTIONS]" })
        await #expect(throws: RemotePairingCodeRequest.Failure.unreadableOutput("usage: openpaw-host [OPTIONS]")) {
            try await request.requestCode()
        }
    }

    @Test("A missing binary is named as such, not reported as a generic failure")
    func classifiesMissingBinary() {
        #expect(RemotePairingCodeRequest.classify(exitCode: 127, output: "openpaw-host-missing") == .hostBinaryMissing)
        #expect(RemotePairingCodeRequest.classify(exitCode: 1, output: "bash: openpaw-host: command not found") == .hostBinaryMissing)
    }

    @Test("A stopped daemon is distinguished from a missing install, because the fix differs")
    func classifiesStoppedDaemon() {
        let message = "Error: reading /home/dev/.openpaw/hook-token — is openpaw-host running?"
        #expect(RemotePairingCodeRequest.classify(exitCode: 1, output: message) == .daemonNotRunning)
        #expect(RemotePairingCodeRequest.classify(exitCode: 1, output: "cannot reach openpaw-host at 127.0.0.1:8787") == .daemonNotRunning)
    }

    @Test("Anything else is reported verbatim enough to act on")
    func classifiesRefusal() {
        let failure = RemotePairingCodeRequest.classify(exitCode: 13, output: "Permission denied (os error 13)")
        #expect(failure == .refused("Permission denied (os error 13)"))
    }

    @Test("A code is never echoed back inside an error message")
    func summariesNeverLeakACode() {
        let summary = RemotePairingCodeRequest.summarize("something failed\n\(Self.validCode)")
        #expect(!summary.contains(Self.validCode))
        #expect(summary.contains("something failed"))
    }

    @Test("Only the daemon's exact code shape is accepted")
    func recognisesOnlyRealCodeShape() {
        #expect(RemotePairingCodeRequest.isPairingCode(Self.validCode))
        #expect(!RemotePairingCodeRequest.isPairingCode("K3F2-9QAM-7XZP"))
        #expect(!RemotePairingCodeRequest.isPairingCode("K3F29QAM7XZP4TWC6BND2HRS"))
        // Prose in the wrong shape must not be mistaken for a code, however many words it has.
        #expect(!RemotePairingCodeRequest.isPairingCode("could-not-open-the-state-dir"))
        #expect(!RemotePairingCodeRequest.isPairingCode("k3f2-9qam-7xzp-4twc-6bnd-2hrs"))
    }

    @Test("The command asks for the operator profile and survives a minimal PATH")
    func commandShape() {
        #expect(RemotePairingCodeRequest.command.contains("pairing-code"))
        #expect(RemotePairingCodeRequest.command.contains("--profile operator"))
        // A non-interactive exec channel may not have the user's login PATH.
        #expect(RemotePairingCodeRequest.command.contains("/opt/homebrew/bin/openpaw-host"))
        #expect(RemotePairingCodeRequest.command.contains("$HOME/.cargo/bin/openpaw-host"))
        // `--qr` writes decoration to stderr and a URL to stdout; the bare form keeps stdout machine-readable.
        #expect(!RemotePairingCodeRequest.command.contains("--qr"))
    }
}

@MainActor
@Suite("Self-service pairing through the model")
struct SelfServicePairingTests {

    private struct StubRunner: CommandRunner {
        let output: String
        func run(_ command: String) async throws -> String { output }
    }

    private struct FailingRunner: CommandRunner {
        func run(_ command: String) async throws -> String {
            throw CommandFailure(command: command, exitCode: 127, output: "openpaw-host-missing")
        }
    }

    private static let code = "K3F2-9QAM-7XZP-4TWC-6BND-2HRS"

    private static func host() -> HostRecord {
        HostRecord(nickname: "Studio", hostname: "studio.local", username: "dev", auth: .agentForwarding)
    }

    @Test("Without an SSH command channel the offer is not made at all")
    func offerRequiresCommandChannel() {
        let backend = SelfServicePairingBackend()
        let model = OpenPawModel(hostStore: HostStore(hosts: [Self.host()]), backend: backend)
        #expect(!model.canRequestPairingFromHost)
    }

    @Test("A connected host with an SSH channel can pair itself")
    func pairsUsingCodeFromTheHost() async {
        let backend = SelfServicePairingBackend()
        let model = OpenPawModel(
            hostStore: HostStore(hosts: [Self.host()]),
            backend: backend,
            terminal: ConnectedTerminalDouble(),
            remoteCommandRunner: StubRunner(output: Self.code))
        _ = await model.connectSelectedHost()
        #expect(model.canRequestPairingFromHost)

        let result = await model.requestPairingFromHost(deviceName: "iPhone")
        #expect(result?.deviceID == "device-1")
        #expect(backend.pairedCode == Self.code)
        #expect(backend.pairedDeviceName == "iPhone")
        #expect(model.selfServicePairing == .paired(PairingResult(
            deviceID: "device-1", token: "t", hmacKeyB64: "a2V5", capabilities: ["sessions.read"])))
    }

    @Test("A host without openpaw-host installed says so instead of failing vaguely")
    func reportsMissingHostBinary() async {
        let backend = SelfServicePairingBackend()
        let model = OpenPawModel(
            hostStore: HostStore(hosts: [Self.host()]),
            backend: backend,
            terminal: ConnectedTerminalDouble(),
            remoteCommandRunner: FailingRunner())
        _ = await model.connectSelectedHost()

        let result = await model.requestPairingFromHost(deviceName: "iPhone")
        #expect(result == nil)
        #expect(backend.pairedCode == nil)
        guard case .failed(let error) = model.selfServicePairing else {
            Issue.record("expected a failed state, got \(model.selfServicePairing)")
            return
        }
        #expect(error.title == "openpaw-host is not installed there")
        #expect(error.detail.contains("not on the PATH"))
    }

    @Test("A disconnected host cannot pair itself, and says why")
    func refusesWhenDisconnected() async {
        let backend = SelfServicePairingBackend()
        let model = OpenPawModel(
            hostStore: HostStore(hosts: [Self.host()]),
            backend: backend,
            remoteCommandRunner: StubRunner(output: Self.code))

        let result = await model.requestPairingFromHost(deviceName: "iPhone")
        #expect(result == nil)
        #expect(backend.pairedCode == nil)
        guard case .failed(let error) = model.selfServicePairing else {
            Issue.record("expected a failed state, got \(model.selfServicePairing)")
            return
        }
        #expect(error.title == "This host cannot pair itself")
    }
}

@MainActor
@Suite("Remembering the transport that worked")
struct SuccessfulTransportRecordingTests {

    private static func host() -> HostRecord {
        HostRecord(nickname: "Studio", hostname: "studio.local", username: "dev", auth: .agentForwarding)
    }

    @Test("A host that has never connected reads as unchecked, not as offline")
    func unconnectedHostIsUnchecked() {
        let host = Self.host()
        #expect(host.lastSuccessfulTransport == nil)
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]))
        #expect(WorkspaceDevicePresentation(host: host, model: model).availability == .unknown)
    }

    /// Home derives "Not checked" from `lastSuccessfulTransport` being nil, so a host that connects and is still
    /// labelled unchecked is not a display bug: the fact was never recorded. It used to be recorded only by Quick
    /// Connect, which left every hand-added and discovered host permanently unchecked however often it connected.
    @Test("Connecting records the transport, so the device stops reading as never checked")
    func connectingRecordsTheTransport() async {
        let host = Self.host()
        let model = OpenPawModel(
            hostStore: HostStore(hosts: [host]),
            terminal: ConnectedTerminalDouble())
        var persisted: [HostStore] = []
        model.persistHostStore = { persisted.append($0) }

        _ = await model.connectSelectedHost()

        #expect(model.hostStore.hosts.first?.lastSuccessfulTransport == .ssh)
        #expect(persisted.last?.hosts.first?.lastSuccessfulTransport == .ssh)
        let connected = try! #require(model.hostStore.hosts.first)
        #expect(WorkspaceDevicePresentation(host: connected, model: model).availability == .online)
    }

    @Test("Recording the same transport twice does not rewrite the store")
    func repeatedConnectDoesNotRewrite() async {
        var host = Self.host()
        host.lastSuccessfulTransport = .ssh
        let model = OpenPawModel(
            hostStore: HostStore(hosts: [host]),
            terminal: ConnectedTerminalDouble())
        var persisted: [HostStore] = []
        model.persistHostStore = { persisted.append($0) }

        _ = await model.connectSelectedHost()

        #expect(persisted.isEmpty)
        #expect(model.hostStore.hosts.first?.lastSuccessfulTransport == .ssh)
    }
}

private final class SelfServicePairingBackend: OpenPawBackend, OpenPawHostPairing, @unchecked Sendable {
    private(set) var pairedCode: String?
    private(set) var pairedDeviceName: String?

    func pair(pairingCode: String, deviceName: String) async throws -> PairingResult {
        pairedCode = pairingCode
        pairedDeviceName = deviceName
        return PairingResult(deviceID: "device-1", token: "t", hmacKeyB64: "a2V5", capabilities: ["sessions.read"])
    }

    func health() async throws -> HealthInfo {
        HealthInfo(
            version: "test", protocolVersion: "1.0", agents: [], capabilities: [], previewPorts: [],
            adapterVersions: [:])
    }
    func sessions() async throws -> [SessionSummary] { [] }
    func inbox(status: InboxStatus?) async throws -> [InboxItem] { [] }
    func resolve(item: InboxItem, action: ActionID, answer: String?, detailAcknowledged: Bool) async throws -> ResolveResult {
        throw SelfServicePairingFixtureError.notUsed
    }
    func events(session: String?, afterSeq: UInt64?) -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func repos() async throws -> [RepoSummary] { [] }
    func repoStatus(_ repo: String) async throws -> RepoStatus { throw SelfServicePairingFixtureError.notUsed }
    func diff(repo: String, mode: DiffMode, path: String?) async throws -> Diff { throw SelfServicePairingFixtureError.notUsed }
    func tree(repo: String, ref: String, path: String) async throws -> [TreeEntry] { throw SelfServicePairingFixtureError.notUsed }
    func blob(repo: String, ref: String, path: String) async throws -> Blob { throw SelfServicePairingFixtureError.notUsed }
    func search(repo: String, query: String, path: String?) async throws -> [ContentMatch] { throw SelfServicePairingFixtureError.notUsed }
    func upload(data: Data, filename: String) async throws -> UploadResult { throw SelfServicePairingFixtureError.notUsed }
    func previewURL(port: Int, path: String) throws -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func tailscaleDevices() async throws -> TailscaleDevicesResponse { TailscaleDevicesResponse(version: 1, candidates: []) }
    func audit(limit: Int) async throws -> [AuditEntry] { [] }
}

private enum SelfServicePairingFixtureError: Error { case notUsed }

/// A terminal that reports itself connected the moment it is dialled, which is all this suite needs from SSH.
private final class ConnectedTerminalDouble: TerminalBackend, @unchecked Sendable {
    let stateStream: AsyncStream<ConnectionState>
    let outputStream: AsyncStream<Data> = AsyncStream { $0.finish() }
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation

    init() {
        var continuation: AsyncStream<ConnectionState>.Continuation?
        stateStream = AsyncStream { continuation = $0 }
        stateContinuation = continuation!
    }

    func connect(host: HostRecord) async throws { stateContinuation.yield(.connected(.ssh)) }
    func disconnect() async {}
    func send(text: String) async throws {}
    func send(chord: KeyChord, applicationCursorKeys: Bool) async throws {}
    func resize(columns: Int, rows: Int) async throws {}
    func run(command: String) async throws -> String { "" }
}
