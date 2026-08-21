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
        XCTAssertTrue(await backend.isReady)
        XCTAssertNoThrow(try backend.previewURL(port: 3000, path: "/"))

        await backend.disconnect()
        XCTAssertFalse(await backend.isReady)
        XCTAssertEqual(await forwarder.stopCount, 2)
        XCTAssertThrowsError(try backend.previewURL(port: 3000, path: "/"))
    }

    func testPairAndUnpairScopeCredentialsToActiveHost() async throws {
        let hostA = HostRecord.ID()
        let hostB = HostRecord.ID()
        let credentials = FakeCredentialStore()
        let backend = HostAPIBackend(forwarder: FakeForwarder(port: 49_322), credentials: credentials, urlSession: Self.stubSession())
        let key = Data((1...32).map { UInt8($0) }).base64EncodedString()
        StubURLProtocol.response = (200, Data(#"{"device_id":"dev_a","token":"tok_a","hmac_key_b64":"\#(key)","capabilities":[]}"#.utf8))

        try await backend.connect(hostID: hostA)
        _ = try await backend.pair(pairingCode: "123456", deviceName: "iPhone")
        XCTAssertEqual(credentials.savedHostIDs, [hostA])
        XCTAssertTrue(backend.isPaired)

        await backend.disconnect()
        try await backend.connect(hostID: hostB)
        XCTAssertFalse(backend.isPaired)
        try await backend.unpair()
        XCTAssertEqual(credentials.clearedHostIDs, [hostB])
        XCTAssertNotNil(credentials.signers[hostA])
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

    init(port: UInt16) { self.port = port }

    func start(remotePort: UInt16) async throws -> UInt16 {
        startedRemotePorts.append(remotePort)
        return port
    }

    func stop() async { stopCount += 1 }
}

private final class FakeCredentialStore: DeviceCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    var signers: [HostRecord.ID: RequestSigner]
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
        lock.unlock()
    }

    func loadSigner(hostID: HostRecord.ID) -> RequestSigner? {
        lock.lock()
        defer { lock.unlock() }
        loadedHostIDs.append(hostID)
        return signers[hostID]
    }

    func clear(hostID: HostRecord.ID) throws {
        lock.lock()
        clearedHostIDs.append(hostID)
        signers.removeValue(forKey: hostID)
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
