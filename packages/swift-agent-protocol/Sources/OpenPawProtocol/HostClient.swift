import Foundation

// MARK: - Errors

public enum HostClientError: Error, Sendable {
    case unauthorized
    case forbidden(capability: String?)
    case notFound
    case badRequest(String)
    case server(status: Int, body: String)
    case transport(any Error)
    case decoding(any Error)
}

extension HostClientError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unauthorized:
            "unauthorized: the device token or request signature was rejected"
        case .forbidden(let capability):
            capability.map { "forbidden: missing capability \($0)" } ?? "forbidden"
        case .notFound:
            "not found"
        case .badRequest(let message):
            "bad request: \(message)"
        case .server(let status, let body):
            "host error \(status): \(body)"
        case .transport(let error):
            "transport failure: \(error)"
        case .decoding(let error):
            "malformed response: \(error)"
        }
    }
}

// MARK: - Client

/// Talks to `openpaw-host` over the SSH-forwarded loopback port.
///
/// Every route except `/v1/health` and `/v1/pair` carries the bearer token *and* an
/// HMAC signature bound to method, path, query, timestamp, nonce and body.
public actor HostClient {
    /// Header carrying the upload filename for `POST /v1/uploads`.
    public static let filenameHeader = "X-OpenPaw-Filename"
    /// Header the host may use to name the capability a 403 was missing.
    public static let requiredCapabilityHeader = "X-OpenPaw-Required-Capability"

    public let baseURL: URL
    private let session: URLSession
    private var signer: RequestSigner?

    public init(baseURL: URL, signer: RequestSigner? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.signer = signer
        self.session = session
    }

    /// Installs (or clears) the credentials produced by pairing.
    public func setSigner(_ signer: RequestSigner?) {
        self.signer = signer
    }

    public var isPaired: Bool { signer != nil }

    // MARK: Unauthenticated routes

    public func health() async throws -> HealthInfo {
        let request = try makeRequest(method: "GET", path: "/v1/health", signed: false)
        return try decode(HealthInfo.self, from: try await send(request))
    }

    public func pair(
        pairingCode: String, deviceName: String, platform: String
    ) async throws -> PairingResult {
        let body = try encode(
            PairRequest(pairingCode: pairingCode, deviceName: deviceName, platform: platform)
        )
        let request = try makeRequest(
            method: "POST", path: "/v1/pair", body: body, signed: false
        )
        return try decode(PairingResult.self, from: try await send(request))
    }

    // MARK: Sessions, inbox

    public func sessions() async throws -> [SessionSummary] {
        let request = try makeRequest(method: "GET", path: "/v1/sessions")
        return try decode([SessionSummary].self, from: try await send(request))
    }

    public func inbox(status: InboxStatus? = nil) async throws -> [InboxItem] {
        let query = status.map { [URLQueryItem(name: "status", value: $0.rawValue)] } ?? []
        let request = try makeRequest(method: "GET", path: "/v1/inbox", query: query)
        return try decode([InboxItem].self, from: try await send(request))
    }

    /// Resolves one inbox item. `detailAcknowledged` records that the operator expanded
    /// the full command detail before approving, which the host writes to its audit log.
    public func resolve(
        itemID: InboxID,
        action: ActionID,
        actionToken: String?,
        answer: String? = nil,
        detailAcknowledged: Bool = false
    ) async throws -> ResolveResult {
        let body = try encode(
            ResolveRequest(
                action: action,
                actionToken: actionToken,
                answer: answer,
                detailAcknowledged: detailAcknowledged
            )
        )
        let request = try makeRequest(
            method: "POST",
            path: "/v1/inbox/\(escape(itemID.rawValue))/resolve",
            body: body
        )
        return try decode(ResolveResult.self, from: try await send(request))
    }

    // MARK: Repositories

    public func repos() async throws -> [RepoSummary] {
        let request = try makeRequest(method: "GET", path: "/v1/repos")
        return try decode([RepoSummary].self, from: try await send(request))
    }

    public func repoStatus(_ repo: String) async throws -> RepoStatus {
        let request = try makeRequest(
            method: "GET", path: "/v1/repos/\(escape(repo))/status"
        )
        return try decode(RepoStatus.self, from: try await send(request))
    }

    public func diff(
        repo: String, mode: DiffMode = .workingTree, path: String? = nil
    ) async throws -> Diff {
        var query = mode.queryItems
        if let path { query.append(URLQueryItem(name: "path", value: path)) }
        let request = try makeRequest(
            method: "GET", path: "/v1/repos/\(escape(repo))/diff", query: query
        )
        return try decode(Diff.self, from: try await send(request))
    }

    public func tree(
        repo: String, ref: String? = nil, path: String? = nil
    ) async throws -> [TreeEntry] {
        var query: [URLQueryItem] = []
        if let ref { query.append(URLQueryItem(name: "ref", value: ref)) }
        if let path { query.append(URLQueryItem(name: "path", value: path)) }
        let request = try makeRequest(
            method: "GET", path: "/v1/repos/\(escape(repo))/tree", query: query
        )
        return try decode([TreeEntry].self, from: try await send(request))
    }

    public func blob(repo: String, ref: String? = nil, path: String) async throws -> Blob {
        var query: [URLQueryItem] = []
        if let ref { query.append(URLQueryItem(name: "ref", value: ref)) }
        query.append(URLQueryItem(name: "path", value: path))
        let request = try makeRequest(
            method: "GET", path: "/v1/repos/\(escape(repo))/blob", query: query
        )
        return try decode(Blob.self, from: try await send(request))
    }

    public func search(
        repo: String, query searchQuery: String, path: String? = nil
    ) async throws -> [ContentMatch] {
        var query = [URLQueryItem(name: "q", value: searchQuery)]
        if let path { query.append(URLQueryItem(name: "path", value: path)) }
        let request = try makeRequest(
            method: "GET", path: "/v1/repos/\(escape(repo))/search", query: query
        )
        return try decode([ContentMatch].self, from: try await send(request))
    }

    // MARK: Uploads, audit

    public func upload(data: Data, filename: String) async throws -> UploadResult {
        let request = try makeRequest(
            method: "POST",
            path: "/v1/uploads",
            body: data,
            headers: [
                Self.filenameHeader: filename,
                "Content-Type": "application/octet-stream",
            ]
        )
        return try decode(UploadResult.self, from: try await send(request))
    }

    public func audit(limit: Int? = nil) async throws -> [AuditEntry] {
        let query = limit.map { [URLQueryItem(name: "limit", value: String($0))] } ?? []
        let request = try makeRequest(method: "GET", path: "/v1/audit", query: query)
        return try decode([AuditEntry].self, from: try await send(request))
    }

    // MARK: Event stream

    /// Subscribes to `GET /v1/events`. The host replays the backlog after `afterSeq`
    /// before switching to live frames, so a reconnecting client loses nothing.
    public func events(
        session sessionID: String? = nil, afterSeq: UInt64? = nil
    ) async throws -> AsyncThrowingStream<Event, any Error> {
        var query: [URLQueryItem] = []
        if let sessionID { query.append(URLQueryItem(name: "session", value: sessionID)) }
        if let afterSeq { query.append(URLQueryItem(name: "after_seq", value: String(afterSeq))) }
        var request = try makeRequest(method: "GET", path: "/v1/events", query: query)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = .greatestFiniteMagnitude

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw HostClientError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HostClientError.server(status: 0, body: "response was not HTTP")
        }
        if !(200..<300).contains(http.statusCode) {
            var body = Data()
            // Error responses are small; drain them so the message is useful.
            do {
                for try await byte in bytes {
                    body.append(byte)
                    if body.count > 8192 { break }
                }
            } catch {
                throw HostClientError.transport(error)
            }
            throw Self.error(for: http, body: body)
        }
        return SSE.events(from: bytes)
    }

    // MARK: Request plumbing

    private func makeRequest(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        headers: [String: String] = [:],
        signed: Bool = true
    ) throws -> URLRequest {
        guard
            var components = URLComponents(
                url: baseURL.appending(path: path), resolvingAgainstBaseURL: false
            )
        else {
            throw HostClientError.badRequest("cannot build a URL for \(path)")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw HostClientError.badRequest("cannot build a URL for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil, headers["Content-Type"] == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        guard signed else { return request }
        guard let signer else {
            throw HostClientError.unauthorized
        }
        // Sign exactly the path and query the host will see on the request line.
        let pathAndQuery =
            components.percentEncodedPath
            + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        let signatureHeaders = signer.headers(
            method: method, pathAndQuery: pathAndQuery, body: body ?? Data()
        )
        for (name, value) in signatureHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HostClientError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HostClientError.server(status: 0, body: "response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(for: http, body: data)
        }
        return data
    }

    static func error(for response: HTTPURLResponse, body: Data) -> HostClientError {
        let text = String(decoding: body, as: UTF8.self)
        switch response.statusCode {
        case 401:
            return .unauthorized
        case 403:
            let fromBody = (try? JSONValue(data: body))?["capability"]?.stringValue
            let fromHeader = response.value(
                forHTTPHeaderField: HostClient.requiredCapabilityHeader
            )
            return .forbidden(capability: fromBody ?? fromHeader)
        case 404:
            return .notFound
        case 400:
            let message = (try? JSONValue(data: body))?["error"]?.stringValue ?? text
            return .badRequest(message)
        default:
            return .server(status: response.statusCode, body: text)
        }
    }

    private func encode(_ value: some Encodable) throws -> Data {
        do {
            return try OpenPawCoding.encoder.encode(value)
        } catch {
            throw HostClientError.decoding(error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try OpenPawCoding.decoder.decode(type, from: data)
        } catch {
            throw HostClientError.decoding(error)
        }
    }

    /// Percent-encodes one path component, including `/`.
    private func escape(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }
}

// MARK: - Request bodies

struct PairRequest: Encodable {
    let pairingCode: String
    let deviceName: String
    let platform: String

    enum CodingKeys: String, CodingKey {
        case pairingCode = "pairing_code"
        case deviceName = "device_name"
        case platform
    }
}

struct ResolveRequest: Encodable {
    let action: ActionID
    let actionToken: String?
    let answer: String?
    let detailAcknowledged: Bool

    enum CodingKeys: String, CodingKey {
        case action
        case actionToken = "action_token"
        case answer
        case detailAcknowledged = "detail_acknowledged"
    }
}
