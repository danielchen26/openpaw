import Foundation
import OpenPawUI
import XCTest

@testable import OpenPawApp

final class TailscaleAdminConnectorTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.routes = []
        URLProtocolStub.requests = []
        super.tearDown()
    }

    func testSuccessMintsClientCredentialsTokenAndFetchesReadOnlyDeviceCandidatesWithoutPagination() async throws {
        let connector = makeConnector()
        let credentials = TailscaleAdminCredentials(clientID: "client-id", clientSecret: "super-secret", tailnet: "example.ts.net")

        URLProtocolStub.routes = [
            .init(status: 200, body: #"{"access_token":"token-one","expires_in":3600,"unknown":"ok"}"#),
            .init(status: 200, body: #"{"devices":[{"id":"dev1","name":"mac.example.ts.net","hostname":"mac","addresses":["100.64.0.1"],"os":"macOS","user":"alice","online":true,"ignored":"field"}],"extra":"ignored"}"#)
        ]

        let devices = try await connector.fetchDevices(using: credentials)

        XCTAssertEqual(devices, [
            TailscaleAdminDeviceCandidate(
                id: "dev1",
                name: "mac.example.ts.net",
                hostname: "mac",
                addresses: ["100.64.0.1"],
                os: "macOS",
                user: "alice",
                isOnline: true
            )
        ])
        XCTAssertEqual(URLProtocolStub.requests.count, 2)
        XCTAssertEqual(URLProtocolStub.requests[0].url?.path, "/api/v2/oauth/token")
        XCTAssertEqual(URLProtocolStub.requests[0].httpMethod, "POST")
        XCTAssertEqual(URLProtocolStub.requests[0].value(forHTTPHeaderField: "Authorization"), "Basic Y2xpZW50LWlkOnN1cGVyLXNlY3JldA==")
        XCTAssertEqual(String(data: URLProtocolStub.requests[0].httpBodyData, encoding: .utf8), "grant_type=client_credentials")
        XCTAssertEqual(URLProtocolStub.requests[1].url?.path, "/api/v2/tailnet/example.ts.net/devices")
        XCTAssertNil(URLProtocolStub.requests[1].url?.query, "Devices API is not paginated today, so connector must not invent page cursors")
        XCTAssertEqual(URLProtocolStub.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer token-one")
    }

    func testMapsOfficialConnectedToControlFieldToOnlineState() async throws {
        let connector = makeConnector()
        let credentials = TailscaleAdminCredentials(clientID: "client-id", clientSecret: "super-secret", tailnet: "example.ts.net")

        URLProtocolStub.routes = [
            .init(status: 200, body: #"{"access_token":"token-one","expires_in":3600}"#),
            .init(
                status: 200,
                body: #"{"devices":[{"id":"dev1","name":"build-node.example.ts.net","hostname":"build-node","addresses":["100.64.0.10"],"connectedToControl":true}]}"#
            )
        ]

        let devices = try await connector.fetchDevices(using: credentials)

        XCTAssertEqual(devices.first?.isOnline, true)
    }

    func testQuad100LocalIdentityUsesOnlyTheFixedEndpointAndDecodesTheSignedInTailnet() async throws {
        URLProtocolStub.routes = [
            .init(
                status: 200,
                body: #"{"Profile":{"LoginName":"alice@example.com","DisplayName":"Alice"},"Status":"Running","DeviceName":"Alice's iPhone","TailnetName":"example.ts.net"}"#
            )
        ]
        let connector = Quad100TailscaleLocalIdentityConnector(configuration: stubConfiguration())

        let identity = try await connector.localIdentity()

        XCTAssertEqual(URLProtocolStub.requests.map(\.url?.absoluteString), ["http://100.100.100.100/api/data"])
        XCTAssertEqual(identity.profile?.loginName, "alice@example.com")
        XCTAssertEqual(identity.tailnetName, "example.ts.net")
    }

    func testQuad100LocalIdentityRejectsAResponseOverItsByteBudget() async {
        URLProtocolStub.routes = [.init(status: 200, body: String(repeating: "x", count: 65))]
        let connector = Quad100TailscaleLocalIdentityConnector(maxBytes: 64, configuration: stubConfiguration())

        await XCTAssertThrowsErrorAsync(try await connector.localIdentity()) { error in
            XCTAssertEqual(error as? TailscaleLocalIdentityError, .responseTooLarge)
        }
    }

    func testQuad100LocalIdentityRefusesRedirectResponses() async {
        URLProtocolStub.routes = [.init(status: 302, body: "")]
        let connector = Quad100TailscaleLocalIdentityConnector(configuration: stubConfiguration())

        await XCTAssertThrowsErrorAsync(try await connector.localIdentity()) { error in
            XCTAssertEqual(error as? TailscaleLocalIdentityError, .redirectRefused)
        }
    }

    func testLiveQuad100IdentityOnSignedInPhysicalDevice() async throws {
        guard ProcessInfo.processInfo.environment["OPENPAW_LIVE_TAILSCALE"] == "1" else {
            throw XCTSkip("Set OPENPAW_LIVE_TAILSCALE=1 on a signed-in physical Tailscale device")
        }

        let identity = try await Quad100TailscaleLocalIdentityConnector().localIdentity()

        XCTAssertFalse(identity.tailnetName?.isEmpty ?? true)
        XCTAssertFalse(identity.deviceName?.isEmpty ?? true)
    }

    func testRefreshesShortLivedInMemoryTokenOnExpiry() async throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 100))
        let now: @Sendable () -> Date = { clock.now() }
        let connector = makeConnector(clock: now)
        let credentials = TailscaleAdminCredentials(clientID: "client", clientSecret: "secret", tailnet: "tailnet")
        URLProtocolStub.routes = [
            .init(status: 200, body: #"{"access_token":"old","expires_in":1}"#),
            .init(status: 200, body: #"{"devices":[]}"#),
            .init(status: 200, body: #"{"access_token":"new","expires_in":60}"#),
            .init(status: 200, body: #"{"devices":[]}"#)
        ]

        _ = try await connector.fetchDevices(using: credentials)
        clock.current = Date(timeIntervalSince1970: 102)
        _ = try await connector.fetchDevices(using: credentials)

        let authHeaders = URLProtocolStub.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(authHeaders, ["Basic Y2xpZW50OnNlY3JldA==", "Bearer old", "Basic Y2xpZW50OnNlY3JldA==", "Bearer new"])
    }

    func testRefreshesTokenOnceAfterDevices401() async throws {
        let connector = makeConnector()
        let credentials = TailscaleAdminCredentials(clientID: "client", clientSecret: "secret", tailnet: "tailnet")
        URLProtocolStub.routes = [
            .init(status: 200, body: #"{"access_token":"stale","expires_in":3600}"#),
            .init(status: 401, body: #"{"message":"expired"}"#),
            .init(status: 200, body: #"{"access_token":"fresh","expires_in":3600}"#),
            .init(status: 200, body: #"{"devices":[]}"#)
        ]

        _ = try await connector.fetchDevices(using: credentials)

        XCTAssertEqual(URLProtocolStub.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, [
            "Basic Y2xpZW50OnNlY3JldA==", "Bearer stale", "Basic Y2xpZW50OnNlY3JldA==", "Bearer fresh"
        ])
    }

    func testHTTPFailuresMalformedJSONAndDescriptionsRedactSecrets() async throws {
        for (status, expected) in [(401, "unauthorized"), (403, "forbidden"), (429, "rateLimited")] {
            URLProtocolStub.routes = [.init(status: status, body: #"{"error":"super-secret"}"#)]
            do {
                _ = try await makeConnector().fetchDevices(using: .init(clientID: "client-id", clientSecret: "super-secret", tailnet: "tailnet"))
                XCTFail("expected failure")
            } catch {
                XCTAssertTrue(String(describing: error).contains(expected))
                XCTAssertFalse(String(describing: error).contains("super-secret"))
                XCTAssertFalse(String(describing: error).contains("client-id"))
            }
        }

        URLProtocolStub.routes = [.init(status: 200, body: #"{"access_token":"token","expires_in":60}"#), .init(status: 200, body: #"{"devices":"nope"}"#)]
        await XCTAssertThrowsErrorAsync(try await makeConnector().fetchDevices(using: .init(clientID: "client", clientSecret: "secret", tailnet: "tailnet"))) { error in
            XCTAssertTrue(String(describing: error).contains("malformedJSON"))
            XCTAssertFalse(String(describing: error).contains("secret"))
        }
    }

    func testCredentialsAreSavedLoadedAndDeletedOnlyThroughInjectedKeychainStore() async throws {
        let store = InMemoryAdminCredentialStore()
        let connector = makeConnector(store: store)
        let credentials = TailscaleAdminCredentials(clientID: "id", clientSecret: "secret", tailnet: "tailnet")

        try await connector.connect(credentials)
        let loaded = try await connector.savedCredentials()
        XCTAssertEqual(loaded, credentials)
        try await connector.disconnectAndDeleteCredentials()
        let deleted = try await connector.savedCredentials()
        XCTAssertNil(deleted)
        XCTAssertEqual(store.operations, ["save", "load", "delete", "load"])
    }

    func testCancellationDoesNotStartNetworkRequest() async throws {
        let connector = makeConnector()
        let credentials = TailscaleAdminCredentials(clientID: "client", clientSecret: "secret", tailnet: "tailnet")
        URLProtocolStub.routes = [.init(status: 200, body: #"{"access_token":"token","expires_in":60}"#)]

        let task = Task { try await connector.fetchDevices(using: credentials) }
        task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testInvalidCredentialsAreRejectedBeforeKeychainOrNetwork() async throws {
        let store = InMemoryAdminCredentialStore()
        let connector = makeConnector(store: store)
        let invalid = TailscaleAdminCredentials(
            clientID: "client:other",
            clientSecret: "super-secret",
            tailnet: "tail/net"
        )

        await XCTAssertThrowsErrorAsync(try await connector.connect(invalid)) { error in
            XCTAssertTrue(String(describing: error).contains("invalidCredentials"))
            XCTAssertFalse(String(describing: error).contains("super-secret"))
        }
        await XCTAssertThrowsErrorAsync(try await connector.fetchDevices(using: invalid)) { error in
            XCTAssertTrue(String(describing: error).contains("invalidCredentials"))
        }

        XCTAssertTrue(store.operations.isEmpty)
        XCTAssertTrue(URLProtocolStub.requests.isEmpty)
    }

    private func makeConnector(
        store: TailscaleAdminCredentialStore = InMemoryAdminCredentialStore(),
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 100) }
    ) -> TailscaleAdminConnector {
        TailscaleAdminConnector(session: URLSession(configuration: stubConfiguration()), credentialStore: store, now: clock)
    }

    private func stubConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return configuration
    }
}

private final class ManualClock: @unchecked Sendable {
    var current: Date
    init(_ current: Date) { self.current = current }
    func now() -> Date { current }
}

private final class InMemoryAdminCredentialStore: TailscaleAdminCredentialStore, @unchecked Sendable {
    var credentials: TailscaleAdminCredentials?
    var operations: [String] = []

    func save(_ credentials: TailscaleAdminCredentials) async throws {
        operations.append("save")
        self.credentials = credentials
    }

    func load() async throws -> TailscaleAdminCredentials? {
        operations.append("load")
        return credentials
    }

    func delete() async throws {
        operations.append("delete")
        credentials = nil
    }
}

private final class URLProtocolStub: URLProtocol {
    struct Route: Sendable {
        var status: Int
        var body: String
    }

    static var routes: [Route] = []
    static var requests: [CapturedRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(CapturedRequest(request))
        let route = Self.routes.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(route.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct CapturedRequest {
    let url: URL?
    let httpMethod: String?
    let headers: [String: String]
    let httpBodyData: Data

    init(_ request: URLRequest) {
        url = request.url
        httpMethod = request.httpMethod
        headers = request.allHTTPHeaderFields ?? [:]
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            httpBodyData = data
        } else {
            httpBodyData = request.httpBody ?? Data()
        }
    }

    func value(forHTTPHeaderField field: String) -> String? { headers[field] }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        handler(error)
    }
}
