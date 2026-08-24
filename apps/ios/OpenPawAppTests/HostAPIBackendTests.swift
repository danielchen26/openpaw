import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import OpenPawUI
import XCTest

@testable import OpenPawApp

final class HostAPIBackendTests: XCTestCase {
    override func tearDown() async throws {
        StubURLProtocol.reset()
        try await super.tearDown()
    }

    func testConnectLoadsOnlySelectedHostSignerAndDisconnectClearsClientAndPort() async throws {
        let hostA = HostRecord.ID()
        let hostB = HostRecord.ID()
        let credentials = FakeCredentialStore(signers: [hostA: signer(deviceID: "a")])
        let forwarder = FakeForwarder(port: 49_321)
        let backend = HostAPIBackend(forwarder: forwarder, credentials: credentials, urlSession: Self.stubSession())

        try await backend.connect(hostID: hostB)
        XCTAssertEqual(credentials.loadedHostIDs, [hostB])
        let isReadyAfterConnect = await backend.isReady
        XCTAssertTrue(isReadyAfterConnect)
        XCTAssertNoThrow(try backend.previewURL(port: 3000, path: "/"))

        await backend.disconnect()
        let isReadyAfterDisconnect = await backend.isReady
        let stopCount = await forwarder.stopCount
        XCTAssertFalse(isReadyAfterDisconnect)
        XCTAssertEqual(stopCount, 2)
        XCTAssertThrowsError(try backend.previewURL(port: 3000, path: "/"))
    }

    func testPairAndUnpairScopeCredentialsToActiveHost() async throws {
        let hostA = HostRecord.ID()
        let hostB = HostRecord.ID()
        let credentials = FakeCredentialStore()
        let backend = HostAPIBackend(forwarder: FakeForwarder(port: 49_322), credentials: credentials, urlSession: Self.stubSession())
        let key = Data((1...32).map { UInt8($0) }).base64EncodedString()
        StubURLProtocol.response = (200, Data(#"{"device_id":"dev_a","token":"tok_a","hmac_key_b64":"\#(key)","capabilities":["devices.read"]}"#.utf8))

        try await backend.connect(hostID: hostA)
        _ = try await backend.pair(pairingCode: "123456", deviceName: "iPhone")
        XCTAssertEqual(credentials.savedHostIDs, [hostA])
        XCTAssertTrue(backend.isPaired)
        XCTAssertEqual(backend.pairedCapabilityStatus("devices.read", hostID: hostA), .granted)

        await backend.disconnect()
        try await backend.connect(hostID: hostB)
        XCTAssertFalse(backend.isPaired)
        try await backend.unpair()
        XCTAssertEqual(credentials.clearedHostIDs, [hostB])
        XCTAssertNotNil(credentials.signers[hostA])
    }

    func testPairSacrificesAHealthWarmupBeforeSendingTheSingleUseCode() async throws {
        let hostID = HostRecord.ID()
        let credentials = FakeCredentialStore()
        let backend = HostAPIBackend(
            forwarder: FakeForwarder(port: 49_326),
            credentials: credentials,
            urlSession: Self.stubSession())
        let key = Data((1...32).map { UInt8($0) }).base64EncodedString()
        StubURLProtocol.outcomes = [
            .failure(URLError(.networkConnectionLost)),
            .response(200, Data(#"{"device_id":"dev_warm","token":"tok_warm","hmac_key_b64":"\#(key)","capabilities":["devices.read"]}"#.utf8)),
        ]

        try await backend.connect(hostID: hostID)
        let result = try await backend.pair(pairingCode: "single-use", deviceName: "iPhone")

        XCTAssertEqual(result.deviceID, "dev_warm")
        XCTAssertEqual(credentials.savedHostIDs, [hostID])
        XCTAssertEqual(StubURLProtocol.recordedRequestPaths, ["/v1/health", "/v1/pair"])
    }

    func testPairCancellationDuringHealthWarmupNeverSendsTheSingleUseCode() async throws {
        let hostID = HostRecord.ID()
        let gate = DispatchSemaphore(value: 0)
        let backend = HostAPIBackend(
            forwarder: FakeForwarder(port: 49_327),
            credentials: FakeCredentialStore(),
            urlSession: Self.stubSession())
        StubURLProtocol.outcomes = [
            .responseAfter(gate, 200, Data(#"{"version":"fixture","protocol_version":"1.0","agents":[],"capabilities":[],"preview_ports":[],"adapter_versions":{}}"#.utf8)),
            .response(500, Data()),
        ]

        try await backend.connect(hostID: hostID)
        let pairing = Task {
            try await backend.pair(pairingCode: "must-not-leave", deviceName: "iPhone")
        }
        for _ in 0..<10_000 where StubURLProtocol.recordedRequestPaths != ["/v1/health"] {
            await Task.yield()
        }
        XCTAssertEqual(StubURLProtocol.recordedRequestPaths, ["/v1/health"])

        pairing.cancel()
        gate.signal()
        do {
            _ = try await pairing.value
            XCTFail("cancelled pairing unexpectedly completed")
        } catch is CancellationError {
            // Expected: cancellation is observed before the single-use code is sent.
        } catch {
            XCTFail("expected CancellationError, got \(type(of: error))")
        }

        XCTAssertEqual(StubURLProtocol.recordedRequestPaths, ["/v1/health"])
    }

    func testConcurrentPairCallsRedeemTheSingleUseCodeAtMostOnce() async throws {
        let hostID = HostRecord.ID()
        let healthGate = DispatchSemaphore(value: 0)
        let firstRequestStarted = DispatchSemaphore(value: 0)
        let secondRequestStarted = DispatchSemaphore(value: 0)
        let backend = HostAPIBackend(
            forwarder: FakeForwarder(port: 49_328),
            credentials: FakeCredentialStore(),
            urlSession: Self.stubSession())
        let health = Data(#"{"version":"fixture","protocol_version":"1.0","agents":[],"capabilities":[],"preview_ports":[],"adapter_versions":{}}"#.utf8)
        let key = Data((1...32).map { UInt8($0) }).base64EncodedString()
        let paired = Data(#"{"device_id":"dev_once","token":"tok_once","hmac_key_b64":"\#(key)","capabilities":[]}"#.utf8)
        StubURLProtocol.outcomes = [
            .responseAfter(healthGate, 200, health),
            .response(200, paired),
        ]
        StubURLProtocol.requestStartSignals = [firstRequestStarted, secondRequestStarted]

        try await backend.connect(hostID: hostID)
        let first = Task { try await backend.pair(pairingCode: "single-use", deviceName: "First") }
        XCTAssertEqual(firstRequestStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(StubURLProtocol.recordedRequestPaths, ["/v1/health"])
        let second = Task { try await backend.pair(pairingCode: "single-use", deviceName: "Second") }
        XCTAssertEqual(secondRequestStarted.wait(timeout: .now() + 0.5), .timedOut)

        healthGate.signal()
        var successes = 0
        for operation in [first, second] {
            do {
                _ = try await operation.value
                successes += 1
            } catch {}
        }

        XCTAssertEqual(successes, 1)
        XCTAssertEqual(StubURLProtocol.recordedRequestPaths, ["/v1/health", "/v1/pair"])
    }

    func testDeviceCredentialStoreRoundTripsRealPairingResultInKeychain() throws {
        let hostID = HostRecord.ID()
        let store = DeviceCredentialStore(service: "dev.openpaw.tests.pairing.\(UUID().uuidString)")
        let key = Data((1...32).map { UInt8($0) }).base64EncodedString()
        let result = PairingResult(
            deviceID: "dev_keychain",
            token: "token-keychain",
            hmacKeyB64: key,
            capabilities: ["devices.read"])
        defer { try? store.clear(hostID: hostID) }

        try store.save(result, hostID: hostID)

        XCTAssertEqual(store.loadSigner(hostID: hostID), result.signer)
        XCTAssertEqual(store.loadCapabilities(hostID: hostID), ["devices.read"])
    }

    func testConnectFailureClearsActiveHostClientAndTunnel() async throws {
        let host = HostRecord.ID()
        let credentials = FakeCredentialStore(signers: [host: signer(deviceID: "a")])
        let forwarder = FakeForwarder(port: 49_323)
        await forwarder.setFailStart(true)
        let backend = HostAPIBackend(forwarder: forwarder, credentials: credentials, urlSession: Self.stubSession())

        do {
            try await backend.connect(hostID: host)
            XCTFail("connect should fail")
        } catch {}

        let isReadyAfterFailure = await backend.isReady
        let stopCountAfterFailure = await forwarder.stopCount
        XCTAssertFalse(isReadyAfterFailure)
        XCTAssertFalse(backend.isPaired)
        XCTAssertEqual(stopCountAfterFailure, 2)
        XCTAssertThrowsError(try backend.previewURL(port: 3000, path: "/"))
    }

    func testStructuredConnectOptionAppliesOnlyToOwnedAttempt() async throws {
        let forwarder = FakeForwarder(port: 49_324)
        let backend = HostAPIBackend(forwarder: forwarder, remotePort: 9_999, urlSession: Self.stubSession())

        try await backend.connect(hostID: HostRecord.ID(), options: .init(hostAPIPort: 4_317))
        try await backend.connect(hostID: HostRecord.ID())

        let ports = await forwarder.startedRemotePorts
        XCTAssertEqual(ports, [4_317, 9_999])
    }

    func testNilStructuredConnectOptionUsesDefaultRemotePort() async throws {
        let forwarder = FakeForwarder(port: 49_325)
        let backend = HostAPIBackend(forwarder: forwarder, urlSession: Self.stubSession())

        try await backend.connect(hostID: HostRecord.ID(), options: .init(hostAPIPort: nil))

        let ports = await forwarder.startedRemotePorts
        XCTAssertEqual(ports, [HostAPIBackend.defaultRemotePort])
    }

    func testConnectOptionUsesAttemptPortWithoutMutatingDefault() async throws {
        let hostA = HostRecord.ID()
        let hostB = HostRecord.ID()
        let forwarder = FakeForwarder(port: 49_324)
        let backend = HostAPIBackend(forwarder: forwarder, credentials: FakeCredentialStore(), remotePort: 8_787, urlSession: Self.stubSession())

        try await backend.connect(hostID: hostA, options: StructuredBackendConnectOptions(hostAPIPort: 4_317))
        try await backend.connect(hostID: hostB)

        let ports = await forwarder.startedRemotePorts
        XCTAssertEqual(ports, [4_317, 8_787])
    }

    private static func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func signer(deviceID: String) -> RequestSigner {
        let key = Data((1...32).map { UInt8($0) }).base64EncodedString()
        return RequestSigner(deviceID: deviceID, token: "tok_\(deviceID)", hmacKeyBase64: key)!
    }
}

private actor FakeForwarder: LoopbackForwarder {
    let port: UInt16
    var startedRemotePorts: [UInt16] = []
    var stopCount = 0
    private var failStart = false

    init(port: UInt16) { self.port = port }

    func setFailStart(_ value: Bool) {
        failStart = value
    }

    func start(remotePort: UInt16) async throws -> UInt16 {
        startedRemotePorts.append(remotePort)
        if failStart { throw URLError(.cannotConnectToHost) }
        return port
    }

    func stop() async { stopCount += 1 }
}

private final class FakeCredentialStore: DeviceCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    var signers: [HostRecord.ID: RequestSigner]
    var capabilities: [HostRecord.ID: Set<String>] = [:]
    private(set) var loadedHostIDs: [HostRecord.ID] = []
    private(set) var savedHostIDs: [HostRecord.ID] = []
    private(set) var clearedHostIDs: [HostRecord.ID] = []

    init(signers: [HostRecord.ID: RequestSigner] = [:]) { self.signers = signers }

    func save(_ result: PairingResult, hostID: HostRecord.ID) throws {
        lock.lock()
        savedHostIDs.append(hostID)
        if let signer = result.signer {
            signers[hostID] = signer
        }
        capabilities[hostID] = Set(result.capabilities)
        lock.unlock()
    }

    func loadSigner(hostID: HostRecord.ID) -> RequestSigner? {
        lock.lock()
        defer { lock.unlock() }
        loadedHostIDs.append(hostID)
        return signers[hostID]
    }

    func loadCapabilities(hostID: HostRecord.ID) -> Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        return capabilities[hostID]
    }

    func clear(hostID: HostRecord.ID) throws {
        lock.lock()
        clearedHostIDs.append(hostID)
        signers.removeValue(forKey: hostID)
        capabilities.removeValue(forKey: hostID)
        lock.unlock()
    }
}

private final class StubURLProtocol: URLProtocol {
    enum Outcome {
        case response(Int, Data)
        case responseAfter(DispatchSemaphore, Int, Data)
        case failure(any Error)
    }

    static let lock = NSLock()
    static var response: (status: Int, body: Data) = (200, Data())
    static var outcomes: [Outcome] = []
    static var requestPaths: [String] = []
    static var requestStartSignals: [DispatchSemaphore] = []

    static var recordedRequestPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestPaths
    }

    static func reset() {
        lock.lock()
        response = (200, Data())
        outcomes = []
        requestPaths = []
        requestStartSignals = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestPaths.append(request.url?.path ?? "")
        let requestStartSignal = Self.requestStartSignals.isEmpty ? nil : Self.requestStartSignals.removeFirst()
        let outcome = Self.outcomes.isEmpty
            ? Outcome.response(Self.response.status, Self.response.body)
            : Self.outcomes.removeFirst()
        Self.lock.unlock()
        requestStartSignal?.signal()
        switch outcome {
        case .response(let status, let body):
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .responseAfter(let gate, let status, let body):
            gate.wait()
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

#if DEBUG && targetEnvironment(simulator)
    final class DebugSSHTargetTests: XCTestCase {
        func testParsesUsernameHostnameAndNonstandardPort() throws {
            let target = try XCTUnwrap(DebugSSHTarget("developer@127.0.0.1:22222"))

            XCTAssertEqual(target.username, "developer")
            XCTAssertEqual(target.hostname, "127.0.0.1")
            XCTAssertEqual(target.port, 22_222)
        }

        func testDefaultsToTheStandardSSHPort() throws {
            let target = try XCTUnwrap(DebugSSHTarget("developer@localhost"))

            XCTAssertEqual(target.username, "developer")
            XCTAssertEqual(target.hostname, "localhost")
            XCTAssertEqual(target.port, 22)
        }

        func testRejectsURLsAndInvalidPortsInsteadOfPartiallyParsingThem() {
            for value in [
                "developer@host:0",
                "developer@host:65536",
                "developer@host:22/path",
                "developer@host:22?query",
                "developer@host:22#fragment",
                "developer:password@host",
                "developer@host:",
                " developer@host",
                "developer@host%2Fbad",
            ] {
                XCTAssertNil(DebugSSHTarget(value), "unexpectedly accepted \(value)")
            }
        }
    }
#endif
