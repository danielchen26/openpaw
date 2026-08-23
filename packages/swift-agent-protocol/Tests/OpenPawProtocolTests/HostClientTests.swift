import Foundation
import XCTest

@testable import OpenPawProtocol

// MARK: - URLProtocol stub

/// Thread safe holder for the stub's response builder. `URLProtocol` subclasses are
/// instantiated by Foundation on arbitrary threads, so the handler needs a lock.
final class StubResponder: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (HTTPURLResponse, Data)

    static let shared = StubResponder()

    private let lock = NSLock()
    private var handler: Handler?
    private var requests: [URLRequest] = []

    func install(_ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
        requests.removeAll()
    }

    func respond(to request: URLRequest) -> (HTTPURLResponse, Data) {
        lock.lock()
        let handler = self.handler
        requests.append(request)
        lock.unlock()
        guard let handler else {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("no stub installed".utf8))
        }
        return handler(request)
    }

    var recorded: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (response, data) = StubResponder.shared.respond(to: request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Tests

final class HostClientTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:8787")!
    private let signer = RequestSigner(
        deviceID: "dev_1", token: "tok_secret", hmacKey: Data((1...32).map { UInt8($0) })
    )

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeClient() -> HostClient {
        HostClient(baseURL: baseURL, signer: signer, session: makeSession())
    }

    private func respond(
        status: Int, body: String, headers: [String: String] = [:]
    ) {
        StubResponder.shared.install { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (response, Data(body.utf8))
        }
    }

    // MARK: Error mapping

    func testUnauthorizedMapping() async {
        respond(status: 401, body: #"{"error":"bad signature"}"#)
        await assertThrows(try await makeClient().sessions()) { error in
            guard case .unauthorized = error else {
                return XCTFail("expected .unauthorized, got \(error)")
            }
        }
    }

    func testForbiddenCarriesTheMissingCapabilityFromTheBody() async {
        respond(status: 403, body: #"{"error":"forbidden","capability":"approvals.write"}"#)
        await assertThrows(try await makeClient().repos()) { error in
            guard case .forbidden(let capability) = error else {
                return XCTFail("expected .forbidden, got \(error)")
            }
            XCTAssertEqual(capability, "approvals.write")
        }
    }

    func testForbiddenFallsBackToTheHeader() async {
        respond(
            status: 403, body: "forbidden",
            headers: [HostClient.requiredCapabilityHeader: "repos.read"]
        )
        await assertThrows(try await makeClient().repos()) { error in
            guard case .forbidden(let capability) = error else {
                return XCTFail("expected .forbidden, got \(error)")
            }
            XCTAssertEqual(capability, "repos.read")
        }
    }

    func testNotFoundMapping() async {
        respond(status: 404, body: "no such repo")
        await assertThrows(try await makeClient().repoStatus("ghost")) { error in
            guard case .notFound = error else {
                return XCTFail("expected .notFound, got \(error)")
            }
        }
    }

    func testBadRequestUsesTheErrorFieldWhenPresent() async {
        respond(status: 400, body: #"{"error":"path escapes the repository root"}"#)
        await assertThrows(try await makeClient().blob(repo: "proj", path: "../../etc/passwd")) { error in
            guard case .badRequest(let message) = error else {
                return XCTFail("expected .badRequest, got \(error)")
            }
            XCTAssertEqual(message, "path escapes the repository root")
        }
    }

    func testBadRequestFallsBackToTheRawBody() async {
        respond(status: 400, body: "missing q")
        await assertThrows(try await makeClient().search(repo: "proj", query: "")) { error in
            guard case .badRequest(let message) = error else {
                return XCTFail("expected .badRequest, got \(error)")
            }
            XCTAssertEqual(message, "missing q")
        }
    }

    func testServerErrorMapping() async {
        respond(status: 500, body: "adapter panicked")
        await assertThrows(try await makeClient().sessions()) { error in
            guard case .server(let status, let body) = error else {
                return XCTFail("expected .server, got \(error)")
            }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(body, "adapter panicked")
        }
    }

    func testMalformedSuccessBodyMapsToDecoding() async {
        respond(status: 200, body: "[{\"unexpected\":true}]")
        await assertThrows(try await makeClient().sessions()) { error in
            guard case .decoding = error else {
                return XCTFail("expected .decoding, got \(error)")
            }
        }
    }

    func testSignedRouteWithoutASignerIsUnauthorizedBeforeSending() async {
        respond(status: 200, body: "[]")
        let client = HostClient(baseURL: baseURL, signer: nil, session: makeSession())
        await assertThrows(try await client.sessions()) { error in
            guard case .unauthorized = error else {
                return XCTFail("expected .unauthorized, got \(error)")
            }
        }
        let paired = await client.isPaired
        XCTAssertFalse(paired)
    }

    // MARK: Successful routes

    func testHealthIsUnauthenticatedAndCarriesTypedPreviewPorts() async throws {
        respond(
            status: 200,
            body: """
                {"version":"0.1.0","protocol":"1","agents":["claude-code","codex"],\
                "capabilities":["sessions.read","events.read","preview.proxy"],\
                "preview_ports":[3000,5173],\
                "adapter_versions":{"claude-code":"claude-code/transcript-v1",\
                "codex":"codex/rollout-v1"}}
                """
        )
        let client = HostClient(baseURL: baseURL, signer: nil, session: makeSession())
        let health = try await client.health()
        XCTAssertEqual(health.version, "0.1.0")
        XCTAssertEqual(health.protocolVersion, "1")
        XCTAssertEqual(health.agents, [.claudeCode, .codex])
        XCTAssertEqual(
            health.capabilities, ["sessions.read", "events.read", "preview.proxy"]
        )
        XCTAssertEqual(health.previewPorts, [3000, 5173])
        XCTAssertEqual(
            health.adapterVersions,
            [
                "claude-code": "claude-code/transcript-v1",
                "codex": "codex/rollout-v1",
            ]
        )

        let request = try XCTUnwrap(StubResponder.shared.recorded.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: RequestSigner.Header.signature))
    }

    func testHealthFromAnOlderHostDefaultsTheNewFieldsToEmpty() async throws {
        // A host predating preview ports and adapter versions must still parse, and an
        // empty `preview_ports` means "this host proxies nothing" rather than "unknown".
        respond(
            status: 200,
            body: #"{"version":"0.0.9","protocol":"1","agents":["generic"],"capabilities":[]}"#
        )
        let client = HostClient(baseURL: baseURL, signer: nil, session: makeSession())
        let health = try await client.health()
        XCTAssertEqual(health.agents, [.generic])
        XCTAssertTrue(health.previewPorts.isEmpty)
        XCTAssertTrue(health.adapterVersions.isEmpty)
    }

    func testPairSendsSnakeCaseBodyAndInstallsASigner() async throws {
        let key = Data((1...32).map { UInt8($0) }).base64EncodedString()
        respond(
            status: 200,
            body: """
                {"device_id":"dev_9","token":"tok_9","hmac_key_b64":"\(key)",\
                "capabilities":["sessions.read"]}
                """
        )
        let client = HostClient(baseURL: baseURL, signer: nil, session: makeSession())
        let pairing = try await client.pair(
            pairingCode: "123456", deviceName: "iPhone", platform: "ios"
        )
        XCTAssertEqual(pairing.deviceID, "dev_9")
        await client.setSigner(pairing.signer)
        let paired = await client.isPaired
        XCTAssertTrue(paired)

        let request = try XCTUnwrap(StubResponder.shared.recorded.first)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBodyData)
        XCTAssertEqual(
            try JSONValue(data: body),
            [
                "pairing_code": "123456",
                "device_name": "iPhone",
                "platform": "ios",
            ]
        )
    }

    func testSignedRequestSignsExactlyThePathAndQueryTheHostSees() async throws {
        respond(status: 200, body: "[]")
        _ = try await makeClient().inbox(status: .pending)

        let request = try XCTUnwrap(StubResponder.shared.recorded.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok_secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: RequestSigner.Header.device), "dev_1")
        let timestamp = try XCTUnwrap(
            Int64(try XCTUnwrap(request.value(forHTTPHeaderField: RequestSigner.Header.timestamp)))
        )
        let nonce = try XCTUnwrap(request.value(forHTTPHeaderField: RequestSigner.Header.nonce))
        let signature = try XCTUnwrap(
            request.value(forHTTPHeaderField: RequestSigner.Header.signature)
        )

        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        let pathAndQuery =
            components.percentEncodedPath
            + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        XCTAssertEqual(pathAndQuery, "/v1/inbox?status=pending")
        let canonical = RequestSigner.canonicalString(
            method: "GET", pathAndQuery: pathAndQuery, timestamp: timestamp, nonce: nonce,
            body: Data()
        )
        XCTAssertTrue(
            RequestSigner.verify(key: signer.hmacKey, canonical: canonical, signature: signature),
            "the signature must cover the request line the host will parse"
        )
    }


    func testTailscaleDevicesDecodesSuccessAndSignsExactReadOnlyRoute() async throws {
        respond(status: 200, body: #"{"version":1,"candidates":[{"id":"node-1","display_name":"Studio","dns_name":"studio.tail.ts.net","tailscale_ips":["100.64.0.10"],"os":"macOS","online":true,"last_seen":"2026-08-21T07:00:00Z"}]}"#)
        let response = try await makeClient().tailscaleDevices()
        XCTAssertEqual(response.version, 1)
        XCTAssertEqual(response.candidates.first?.id, "node-1")
        XCTAssertEqual(response.candidates.first?.displayName, "Studio")
        let request = try XCTUnwrap(StubResponder.shared.recorded.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/tailscale/devices")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok_secret")
        XCTAssertNotNil(request.value(forHTTPHeaderField: RequestSigner.Header.signature))
    }

    func testTailscaleBusyAndUnknownCodesDecodeWithoutRawBodyLeak() async {
        respond(status: 503, body: #"{"error":{"code":"busy","message":"Tailscale status is already running"},"debug":"raw secret"}"#)
        await assertThrows(try await makeClient().tailscaleDevices()) { error in
            guard case .tailscaleDiscovery(let code, let message) = error else { return XCTFail("expected discovery error, got \(error)") }
            XCTAssertEqual(code, .busy)
            XCTAssertEqual(message, "Tailscale status is already running")
            XCTAssertFalse(String(describing: error).contains("raw secret"))
        }

        respond(status: 500, body: #"{"error":{"code":"future_code","message":"Future safe message"},"stderr":"secret"}"#)
        await assertThrows(try await makeClient().tailscaleDevices()) { error in
            guard case .tailscaleDiscovery(let code, let message) = error else { return XCTFail("expected discovery error, got \(error)") }
            XCTAssertEqual(code, .unknown("future_code"))
            XCTAssertEqual(message, "Future safe message")
            XCTAssertFalse(String(describing: error).contains("secret"))
        }
    }

    func testTailscaleDiscoveryTaxonomyCodesDecodeEndToEnd() async {
        let cases: [(String, TailscaleDiscoveryErrorCode)] = [
            ("missing_cli", .missingCLI),
            ("logged_out", .loggedOut),
            ("timeout", .timeout),
            ("output_limit", .outputLimit),
            ("busy", .busy),
            ("unavailable_state", .unavailableState),
            ("malformed_response", .malformedResponse),
            ("command_failed", .commandFailed),
        ]
        for (raw, expected) in cases {
            respond(status: 502, body: #"{"error":{"code":"\#(raw)","message":"Safe message"},"stderr":"secret"}"#)
            await assertThrows(try await makeClient().tailscaleDevices()) { error in
                guard case .tailscaleDiscovery(let code, let message) = error else {
                    return XCTFail("expected discovery error for \(raw), got \(error)")
                }
                XCTAssertEqual(code, expected)
                XCTAssertEqual(message, "Safe message")
                XCTAssertFalse(String(describing: error).contains("secret"))
            }
        }
    }

    func testTailscaleDiscoveryPreservesAuthErrors() async {
        respond(status: 401, body: #"{"error":{"code":"missing_cli","message":"safe"}}"#)
        await assertThrows(try await makeClient().tailscaleDevices()) { error in
            guard case .unauthorized = error else { return XCTFail("expected unauthorized, got \(error)") }
        }

        respond(status: 403, body: #"{"capability":"devices.read","error":{"code":"missing_cli","message":"safe"}}"#)
        await assertThrows(try await makeClient().tailscaleDevices()) { error in
            guard case .forbidden(let capability) = error else { return XCTFail("expected forbidden, got \(error)") }
            XCTAssertEqual(capability, "devices.read")
        }
    }

    func testTailscaleUnsupportedVersionAndMalformedBodyAreSafe() async {
        respond(status: 200, body: #"{"version":2,"candidates":[]}"#)
        await assertThrows(try await makeClient().tailscaleDevices()) { error in
            guard case .tailscaleDiscovery(let code, let message) = error else { return XCTFail("expected discovery error, got \(error)") }
            XCTAssertEqual(code, .unsupportedVersion)
            XCTAssertFalse(message.contains("version"))
        }

        respond(status: 500, body: "raw panic with token")
        await assertThrows(try await makeClient().tailscaleDevices()) { error in
            guard case .tailscaleDiscovery(let code, let message) = error else { return XCTFail("expected discovery error, got \(error)") }
            XCTAssertEqual(code, .malformedResponse)
            XCTAssertFalse(message.contains("token"))
        }
        respond(status: 400, body: "raw bad request with token")
        await assertThrows(try await makeClient().tailscaleDevices()) { error in
            guard case .tailscaleDiscovery(let code, let message) = error else { return XCTFail("expected discovery error, got \(error)") }
            XCTAssertEqual(code, .malformedResponse)
            XCTAssertFalse(message.contains("token"))
        }
    }

    func testResolveSendsTheActionTokenAndAcknowledgement() async throws {
        respond(status: 200, body: #"{"status":"resolved","event_id":"evt_abc"}"#)
        let result = try await makeClient().resolve(
            itemID: InboxID(rawValue: "inb_0123456789abcdef01234567"),
            action: .approveOnce,
            actionToken: "tok_once",
            detailAcknowledged: true
        )
        XCTAssertEqual(result.status, "resolved")
        XCTAssertEqual(result.eventID, "evt_abc")

        let request = try XCTUnwrap(StubResponder.shared.recorded.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.path, "/v1/inbox/inb_0123456789abcdef01234567/resolve"
        )
        XCTAssertEqual(
            try JSONValue(data: try XCTUnwrap(request.httpBodyData)),
            [
                "action": "approve_once",
                "action_token": "tok_once",
                "detail_acknowledged": true,
            ]
        )
    }

    func testUploadSendsRawBytesAndTheFilenameHeader() async throws {
        respond(status: 200, body: #"{"path":"uploads/a.png","bytes":4,"sha256":"ab"}"#)
        let payload = Data([1, 2, 3, 4])
        let result = try await makeClient().upload(data: payload, filename: "a.png")
        XCTAssertEqual(result.path, "uploads/a.png")
        XCTAssertEqual(result.bytes, 4)

        let request = try XCTUnwrap(StubResponder.shared.recorded.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: HostClient.filenameHeader), "a.png")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(request.httpBodyData, payload)
    }

    func testDiffModeQueryItems() async throws {
        respond(status: 200, body: #"{"files":[],"additions":0,"deletions":0}"#)
        _ = try await makeClient().diff(repo: "proj", mode: .staged, path: "src/lib.rs")
        var query = try XCTUnwrap(StubResponder.shared.recorded.first?.url?.query)
        XCTAssertEqual(query, "staged=true&path=src/lib.rs")

        respond(status: 200, body: #"{"files":[],"additions":0,"deletions":0}"#)
        _ = try await makeClient().diff(repo: "proj", mode: .range(base: "main", head: "topic"))
        query = try XCTUnwrap(StubResponder.shared.recorded.first?.url?.query)
        XCTAssertEqual(query, "base=main&head=topic")

        respond(status: 200, body: #"{"files":[],"additions":0,"deletions":0}"#)
        _ = try await makeClient().diff(repo: "proj", mode: .commit("abc123"))
        query = try XCTUnwrap(StubResponder.shared.recorded.first?.url?.query)
        XCTAssertEqual(query, "commit=abc123")

        respond(status: 200, body: #"{"files":[],"additions":0,"deletions":0}"#)
        _ = try await makeClient().diff(repo: "proj")
        XCTAssertNil(StubResponder.shared.recorded.first?.url?.query)
    }

    func testEventsRejectsANonSuccessStatusBeforeStreaming() async {
        respond(status: 403, body: #"{"capability":"events.read"}"#)
        let client = makeClient()
        do {
            _ = try await client.events(session: "sess_cc-1", afterSeq: 3)
            XCTFail("expected the subscription to fail")
        } catch let error as HostClientError {
            guard case .forbidden(let capability) = error else {
                return XCTFail("expected .forbidden, got \(error)")
            }
            XCTAssertEqual(capability, "events.read")
        } catch {
            XCTFail("expected HostClientError, got \(error)")
        }
    }

    func testSessionSummaryDecoding() async throws {
        respond(
            status: 200,
            body: """
                [{"session_id":"sess_cc-6f7b","agent":"claude-code","title":"Fix the flake",\
                "cwd":"/Users/x/proj","git_branch":"main","multiplexer_target":"work:2.0",\
                "state":"waiting","last_event_at":"2026-08-20T17:00:00Z","last_seq":12,\
                "pending_inbox":2}]
                """
        )
        let sessions = try await makeClient().sessions()
        XCTAssertEqual(sessions.count, 1)
        let summary = sessions[0]
        XCTAssertEqual(summary.id, "sess_cc-6f7b")
        XCTAssertEqual(summary.agent, .claudeCode)
        XCTAssertEqual(summary.state, .waiting)
        XCTAssertEqual(summary.multiplexerTarget, "work:2.0")
        XCTAssertEqual(summary.lastSeq, 12)
        XCTAssertEqual(summary.pendingInbox, 2)
        XCTAssertEqual(summary.lastEventAt, Date(timeIntervalSince1970: 1_787_245_200))
    }

    func testAuditDecodingAndLimitQuery() async throws {
        respond(
            status: 200,
            body: """
                [{"at":"2026-08-20T17:00:00Z","device_id":"dev_1","action":"approve_once",\
                "target":"inb_0123456789abcdef01234567","result":"ok"}]
                """
        )
        let entries = try await makeClient().audit(limit: 50)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].action, "approve_once")
        XCTAssertEqual(entries[0].deviceID, "dev_1")
        XCTAssertEqual(StubResponder.shared.recorded.first?.url?.query, "limit=50")
    }

    // MARK: Helpers

    private func assertThrows(
        _ expression: @autoclosure () async throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ verify: (HostClientError) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected a HostClientError", file: file, line: line)
        } catch let error as HostClientError {
            verify(error)
        } catch {
            XCTFail("expected HostClientError, got \(error)", file: file, line: line)
        }
    }
}

extension URLRequest {
    /// `URLProtocol` stubs receive the body through `httpBodyStream` when the session
    /// was configured with a protocol class, so read whichever is populated.
    var httpBodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
