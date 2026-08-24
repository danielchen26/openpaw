import Foundation
import XCTest

@testable import OpenPawProtocol

// MARK: - URLProtocol stub

/// Thread safe holder for the stub's response builder. `URLProtocol` subclasses are
/// instantiated by Foundation on arbitrary threads, so the handler needs a lock.
final class StubResponder: @unchecked Sendable {
    enum Response {
        case success(HTTPURLResponse, Data)
        case failure(any Error)
        case pending
    }

    typealias Handler = @Sendable (URLRequest) -> Response

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

    func respond(to request: URLRequest) -> Response {
        lock.lock()
        let handler = self.handler
        requests.append(request)
        lock.unlock()
        guard let handler else {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
            )!
            return .success(response, Data("no stub installed".utf8))
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
        switch StubResponder.shared.respond(to: request) {
        case .success(let response, let data):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .pending:
            break
        }
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
            return .success(response, Data(body.utf8))
        }
    }

    private var successfulPairingBody: String {
        let key = Data((1...32).map { UInt8($0) }).base64EncodedString()
        return """
            {"device_id":"dev_9","token":"tok_9","hmac_key_b64":"\(key)",\
            "capabilities":["sessions.read"]}
            """
    }

    func testProviderAndRepoImportContractsRoundTripWithoutSecretsOrPaths() async throws {
        respond(status: 200, body: #"[{"id":"github","display_name":"GitHub","state":"connected","account_label":"octocat","scopes":["repo:read"],"repo_listing_supported":true}]"#)
        let providers = try await makeClient().providers()
        XCTAssertEqual(providers.first?.id, .github)
        XCTAssertEqual(providers.first?.accountLabel, "octocat")
        XCTAssertNil(providers.first?.remoteRevokeResult)
        let providerData = try OpenPawCoding.encoder.encode(providers)
        assertNoProviderRepoSecrets(providerData)

        respond(status: 200, body: #"{"repos":[{"id":"repo_1","provider":"github","owner":"openpaw","name":"openpaw","display_name":"openpaw/openpaw","is_private":true,"source_url_redacted":"https://<redacted>@github.com/openpaw/openpaw.git"}],"next_cursor":"next"}"#)
        let page = try await makeClient().providerRepos(.github, cursor: "first")
        XCTAssertEqual(page.repos.first?.sourceURLRedacted, "https://<redacted>@github.com/openpaw/openpaw.git")
        assertNoProviderRepoSecrets(try OpenPawCoding.encoder.encode(page))

        respond(status: 200, body: #"{"id":"imp_1","state":"cloning","repo_name":"openpaw","destination_name":"openpaw-2","percent":50,"source_url_redacted":"https://<redacted>@github.com/openpaw/openpaw.git"}"#)
        let progress = try await makeClient().importRepo(try .init(provider: .github, repoID: "repo_1", requestedName: "openpaw"))
        XCTAssertEqual(progress.destinationName, "openpaw-2")
        assertNoProviderRepoSecrets(try OpenPawCoding.encoder.encode(progress))
        let body = try OpenPawCoding.encoder.encode(try RepoImportRequest(provider: .github, repoID: "repo_1", requestedName: "openpaw"))
        assertNoProviderRepoSecrets(body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertNil(json?["destination_path"])
    }

    func testProviderStatusRemoteRevokeResultDecodesForDeleteSemantics() throws {
        for (wire, expected) in [("revoked", ProviderRemoteRevokeResult.revoked), ("unsupported", .unsupported), ("failed", .failed)] {
            let status = try OpenPawCoding.decoder.decode(ProviderStatus.self, from: Data(#"{"id":"github","display_name":"GitHub","state":"disconnected","scopes":[],"repo_listing_supported":true,"remote_revoke_result":"\#(wire)"}"#.utf8))
            XCTAssertEqual(status.remoteRevokeResult, expected)
            assertNoProviderRepoSecrets(try OpenPawCoding.encoder.encode(status))
        }
        let future = try OpenPawCoding.decoder.decode(ProviderStatus.self, from: Data(#"{"id":"github","display_name":"GitHub","state":"disconnected","scopes":[],"repo_listing_supported":true,"remote_revoke_result":"host_future_result"}"#.utf8))
        XCTAssertEqual(future.remoteRevokeResult, .unknown("host_future_result"))

        let normal = try OpenPawCoding.decoder.decode(ProviderStatus.self, from: Data(#"{"id":"github","display_name":"GitHub","state":"connected","scopes":[],"repo_listing_supported":true}"#.utf8))
        XCTAssertNil(normal.remoteRevokeResult)
    }

    func testProviderRepoIdentifiersRejectTraversalPathsControlsAndEncodedSeparators() throws {
        for bad in ["", "-repo", "../repo", "repo/name", "repo\\name", "repo%2fname", "repo%5Cname", "repo\nname"] {
            XCTAssertThrowsError(try OpenPawCoding.decoder.decode(RepoImportRequest.self, from: Data(#"{"provider":"github","repo_id":"\#(bad)"}"#.utf8)), "repoID accepted \(bad)")
            XCTAssertThrowsError(try RepoImportRequest(provider: .github, repoID: bad))
            XCTAssertThrowsError(try RepoRegisterRequest(rootID: bad))
            XCTAssertThrowsError(try OpenPawCoding.decoder.decode(RepoImportProgress.self, from: Data(#"{"id":"\#(bad)","state":"queued","repo_name":"openpaw","destination_name":"openpaw"}"#.utf8)), "import id accepted \(bad)")
        }
    }

    func testRepoImportProgressRejectsOutOfRangePercentAndLongMessages() throws {
        XCTAssertThrowsError(try OpenPawCoding.decoder.decode(RepoImportProgress.self, from: Data(#"{"id":"imp_123","state":"cloning","repo_name":"openpaw","destination_name":"openpaw","percent":101}"#.utf8)))
        XCTAssertThrowsError(try RepoImportProgress(id: "imp_123", state: .cloning, repoName: "openpaw", destinationName: "openpaw", percent: 101))
        XCTAssertThrowsError(try RepoImportProgress(id: "imp_123", state: .cloning, repoName: "openpaw", destinationName: "openpaw", message: String(repeating: "x", count: 501)))
    }

    func testSharedCleanProviderRepoFixturesDecodeInSwift() throws {
        for fixture in ["provider-status.clean", "provider-auth-start.clean", "provider-auth-status.clean", "provider-remote-revoke.clean", "provider-repo-list.clean", "repo-import-progress.clean"] {
            assertNoProviderRepoSecrets(try fixtureData(fixture))
        }
        _ = try OpenPawCoding.decoder.decode([ProviderStatus].self, from: fixtureData("provider-status.clean"))
        _ = try OpenPawCoding.decoder.decode(ProviderAuthorizationStart.self, from: fixtureData("provider-auth-start.clean"))
        _ = try OpenPawCoding.decoder.decode(ProviderAuthorizationStatus.self, from: fixtureData("provider-auth-status.clean"))
        let revoke = try OpenPawCoding.decoder.decode(ProviderStatus.self, from: fixtureData("provider-remote-revoke.clean"))
        XCTAssertEqual(revoke.remoteRevokeResult, .revoked)
        _ = try OpenPawCoding.decoder.decode(ProviderRepoPage.self, from: fixtureData("provider-repo-list.clean"))
        let progress = try OpenPawCoding.decoder.decode(RepoImportProgress.self, from: fixtureData("repo-import-progress.clean"))
        XCTAssertEqual(progress.state, .cloning)

        let unknown = try OpenPawCoding.decoder.decode(RepoImportProgress.self, from: Data(#"{"id":"imp_123","state":"host_future_state","repo_name":"openpaw","destination_name":"openpaw"}"#.utf8))
        XCTAssertEqual(unknown.state, .unknown("host_future_state"))
    }

    func testRepoImportStateWirePhasesMatchIntegrationContractWithUnknownFallback() throws {
        let accepted: [(String, RepoImportState)] = [
            ("queued", .queued),
            ("authorizing", .authorizing),
            ("cloning", .cloning),
            ("validating", .validating),
            ("registering", .registering),
            ("completed", .completed),
            ("failed", .failed),
            ("cancelled", .cancelled),
            ("recovery_required", .recoveryRequired),
        ]
        for (wire, expected) in accepted {
            let progress = try OpenPawCoding.decoder.decode(RepoImportProgress.self, from: Data(#"{"id":"imp_123","state":"\#(wire)","repo_name":"openpaw","destination_name":"openpaw"}"#.utf8))
            XCTAssertEqual(progress.state, expected)
        }
        for legacyOrFuture in ["indexing", "outage", "host_future_state"] {
            let progress = try OpenPawCoding.decoder.decode(RepoImportProgress.self, from: Data(#"{"id":"imp_123","state":"\#(legacyOrFuture)","repo_name":"openpaw","destination_name":"openpaw"}"#.utf8))
            XCTAssertEqual(progress.state, .unknown(legacyOrFuture))
        }
    }

    private func assertNoProviderRepoSecrets(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        func scan(_ value: Any) {
            if let object = value as? [String: Any] {
                for key in object.keys {
                    let lower = key.lowercased()
                    if lower != "authorization_id", lower != "state" {
                        for forbidden in ["token", "secret", "credential", "password", "env", "access_token", "refresh_token", "device_code", "client_secret", "clone_url", "header", "local_path", "filesystem_path", "destination_path", "credential_path", "authorization_header", "authorization_url", "authorization_map"] {
                            XCTAssertFalse(lower.contains(forbidden), "contract leaked forbidden field \(forbidden) in key \(key)", file: file, line: line)
                        }
                    }
                    scan(object[key] as Any)
                }
            } else if let array = value as? [Any] {
                array.forEach(scan)
            } else if let string = value as? String {
                let lower = string.lowercased()
                XCTAssertFalse(lower.contains("authorization:") || lower.contains("/users/") || lower.contains("/tmp/") || lower.contains("c:\\"), "contract leaked local path or header value \(string)", file: file, line: line)
            }
        }
        do { scan(try JSONSerialization.jsonObject(with: data)) }
        catch { XCTFail("invalid JSON for secret scan: \(error)", file: file, line: line) }
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
        respond(status: 200, body: successfulPairingBody)
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
        let headerName = "x-openpaw-idempotency-key"
        XCTAssertTrue(request.allHTTPHeaderFields?.keys.contains(headerName) == true)
        let idempotencyKey = try XCTUnwrap(request.value(forHTTPHeaderField: headerName))
        XCTAssertEqual(idempotencyKey.count, 43)
        XCTAssertNotNil(
            idempotencyKey.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression)
        )
        let paddedBase64 = idempotencyKey
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        XCTAssertEqual(Data(base64Encoded: paddedBase64)?.count, 32)
    }

    func testPairRetriesNetworkConnectionLostOnceWithTheIdenticalRequest() async throws {
        let responseBody = successfulPairingBody
        StubResponder.shared.install { request in
            if StubResponder.shared.recorded.count == 1 {
                return .failure(URLError(.networkConnectionLost))
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            return .success(response, Data(responseBody.utf8))
        }

        let client = HostClient(baseURL: baseURL, signer: nil, session: makeSession())
        _ = try await client.pair(
            pairingCode: "123456", deviceName: "iPhone", platform: "ios"
        )

        let requests = StubResponder.shared.recorded
        XCTAssertEqual(requests.count, 2)
        let first = try XCTUnwrap(requests.first)
        let second = try XCTUnwrap(requests.last)
        XCTAssertEqual(second.url, first.url)
        XCTAssertEqual(second.httpMethod, first.httpMethod)
        XCTAssertEqual(second.httpBodyData, first.httpBodyData)
        XCTAssertEqual(second.allHTTPHeaderFields, first.allHTTPHeaderFields)
        let headerName = "x-openpaw-idempotency-key"
        XCTAssertEqual(
            second.value(forHTTPHeaderField: headerName),
            try XCTUnwrap(first.value(forHTTPHeaderField: headerName))
        )
    }

    func testPairStopsAfterOneRetryWhenTransportKeepsFailing() async {
        StubResponder.shared.install { _ in .failure(URLError(.networkConnectionLost)) }
        let client = HostClient(baseURL: baseURL, signer: nil, session: makeSession())

        await assertThrows(
            try await client.pair(
                pairingCode: "123456", deviceName: "iPhone", platform: "ios"
            )
        ) { error in
            guard case .transport = error else {
                return XCTFail("expected transport failure, got \(error)")
            }
        }

        XCTAssertEqual(StubResponder.shared.recorded.count, 2)
        let header = "x-openpaw-idempotency-key"
        XCTAssertEqual(
            StubResponder.shared.recorded.first?.value(forHTTPHeaderField: header),
            StubResponder.shared.recorded.last?.value(forHTTPHeaderField: header)
        )
    }

    func testPairDoesNotRetryCancelledTransport() async {
        StubResponder.shared.install { _ in .failure(URLError(.cancelled)) }
        let client = HostClient(baseURL: baseURL, signer: nil, session: makeSession())

        do {
            _ = try await client.pair(
                pairingCode: "123456", deviceName: "iPhone", platform: "ios"
            )
            XCTFail("expected cancellation")
        } catch let error as HostClientError {
            guard case .transport(let underlying) = error,
                  (underlying as? URLError)?.code == .cancelled
            else {
                return XCTFail("expected cancelled transport error, got \(error)")
            }
        } catch {
            XCTFail("expected HostClientError, got \(error)")
        }

        XCTAssertEqual(StubResponder.shared.recorded.count, 1)
        XCTAssertNotNil(
            StubResponder.shared.recorded.first?.value(
                forHTTPHeaderField: "x-openpaw-idempotency-key"
            )
        )
    }

    func testPairDoesNotRetryWhenTheCallingTaskIsCancelled() async {
        StubResponder.shared.install { _ in .pending }
        let client = HostClient(baseURL: baseURL, signer: nil, session: makeSession())
        let task = Task {
            try await client.pair(
                pairingCode: "123456", deviceName: "iPhone", platform: "ios"
            )
        }

        for _ in 0..<100 where StubResponder.shared.recorded.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(StubResponder.shared.recorded.count, 1)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as HostClientError {
            guard case .transport(let underlying) = error else {
                return XCTFail("expected cancelled transport error, got \(error)")
            }
            XCTAssertTrue(
                underlying is CancellationError
                    || (underlying as? URLError)?.code == .cancelled
            )
        } catch is CancellationError {
            // Actor or URLSession cancellation may surface directly before `send` wraps it.
        } catch {
            XCTFail("expected cancellation, got \(error)")
        }

        XCTAssertEqual(StubResponder.shared.recorded.count, 1)
    }

    func testPairDoesNotRetryForbiddenResponse() async {
        respond(status: 403, body: #"{"capability":"pair"}"#)
        let client = HostClient(baseURL: baseURL, signer: nil, session: makeSession())

        await assertThrows(
            try await client.pair(
                pairingCode: "123456", deviceName: "iPhone", platform: "ios"
            )
        ) { error in
            guard case .forbidden(let capability) = error else {
                return XCTFail("expected forbidden, got \(error)")
            }
            XCTAssertEqual(capability, "pair")
        }

        XCTAssertEqual(StubResponder.shared.recorded.count, 1)
        XCTAssertNotNil(
            StubResponder.shared.recorded.first?.value(
                forHTTPHeaderField: "x-openpaw-idempotency-key"
            )
        )
    }

    func testPairDoesNotRetryServerError() async {
        respond(status: 500, body: "pairing unavailable")
        let client = HostClient(baseURL: baseURL, signer: nil, session: makeSession())

        await assertThrows(
            try await client.pair(
                pairingCode: "123456", deviceName: "iPhone", platform: "ios"
            )
        ) { error in
            guard case .server(let status, _) = error else {
                return XCTFail("expected server error, got \(error)")
            }
            XCTAssertEqual(status, 500)
        }

        XCTAssertEqual(StubResponder.shared.recorded.count, 1)
    }

    func testPairDoesNotRetryMalformedSuccessResponse() async {
        respond(status: 200, body: #"{"unexpected":true}"#)
        let client = HostClient(baseURL: baseURL, signer: nil, session: makeSession())

        await assertThrows(
            try await client.pair(
                pairingCode: "123456", deviceName: "iPhone", platform: "ios"
            )
        ) { error in
            guard case .decoding = error else {
                return XCTFail("expected decoding error, got \(error)")
            }
        }

        XCTAssertEqual(StubResponder.shared.recorded.count, 1)
    }

    func testSeparatePairCallsUseDifferentIdempotencyKeys() async throws {
        respond(status: 200, body: successfulPairingBody)
        let client = HostClient(baseURL: baseURL, signer: nil, session: makeSession())

        _ = try await client.pair(
            pairingCode: "123456", deviceName: "iPhone", platform: "ios"
        )
        _ = try await client.pair(
            pairingCode: "123456", deviceName: "iPhone", platform: "ios"
        )

        let requests = StubResponder.shared.recorded
        XCTAssertEqual(requests.count, 2)
        let headerName = "x-openpaw-idempotency-key"
        let firstKey = try XCTUnwrap(requests.first?.value(forHTTPHeaderField: headerName))
        let secondKey = try XCTUnwrap(requests.last?.value(forHTTPHeaderField: headerName))
        XCTAssertNotEqual(firstKey, secondKey)
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
        respond(
            status: 200,
            body: #"{"status":"resolved","event_id":"evt_abc","warning":"decision_durability_not_confirmed"}"#)
        let result = try await makeClient().resolve(
            itemID: InboxID(rawValue: "inb_0123456789abcdef01234567"),
            action: .approveOnce,
            actionToken: "tok_once",
            detailAcknowledged: true
        )
        XCTAssertEqual(result.status, "resolved")
        XCTAssertEqual(result.eventID, "evt_abc")
        XCTAssertEqual(result.warning, "decision_durability_not_confirmed")

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

    func testDismissUsesTheDedicatedTokenFreeInboxWriteRoute() async throws {
        respond(
            status: 200,
            body: #"{"status":"dismissed","item":{"id":"inb_0123456789abcdef01234567","session_id":"sess_cc-6f7b","agent":"codex","category":"completion","title":"Agent completed","actions":["acknowledge"],"created_at":"2026-08-20T17:00:00Z","status":"dismissed","source_event_id":"evt_0123456789abcdef01234567"}}"#
        )

        let result = try await makeClient().dismiss(
            itemID: InboxID(rawValue: "inb_0123456789abcdef01234567")
        )

        XCTAssertEqual(result.status, .dismissed)
        XCTAssertEqual(result.item.id, InboxID(rawValue: "inb_0123456789abcdef01234567"))
        XCTAssertEqual(result.item.status, .dismissed)
        XCTAssertNil(result.item.actionToken)
        let request = try XCTUnwrap(StubResponder.shared.recorded.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.path, "/v1/inbox/inb_0123456789abcdef01234567/dismiss"
        )
        XCTAssertEqual(request.httpBodyData ?? Data(), Data())
        XCTAssertNil(request.value(forHTTPHeaderField: "X-OpenPaw-Action-Token"))
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
