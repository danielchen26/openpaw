import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
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
    static let lock = NSLock()
    static var response: (status: Int, body: Data) = (200, Data())

    static func reset() {
        lock.lock()
        response = (200, Data())
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let response = Self.response
        Self.lock.unlock()
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
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
