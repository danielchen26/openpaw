import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
import OpenPawUI

protocol TailscaleAdminCredentialStore: Sendable {
    func save(_ credentials: TailscaleAdminCredentials) async throws
    func load() async throws -> TailscaleAdminCredentials?
    func delete() async throws
}

typealias TailscaleAdminConnectorError = TailscaleAdminConnectionError

final class TailscaleAdminConnector: TailscaleAdminConnecting, Sendable {
    fileprivate struct Token: Sendable {
        var value: String
        var expiresAt: Date
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var expiresIn: TimeInterval

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    private struct DevicesResponse: Decodable {
        var devices: [TailscaleAdminDeviceCandidate]
    }

    private let session: URLSession
    private let credentialStore: any TailscaleAdminCredentialStore
    private let baseURL: URL
    private let now: @Sendable () -> Date
    private let decoder: JSONDecoder
    private let state = ConnectorState()

    init(
        session: URLSession = .shared,
        credentialStore: any TailscaleAdminCredentialStore = KeychainTailscaleAdminCredentialStore(),
        baseURL: URL = URL(string: "https://api.tailscale.com")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.credentialStore = credentialStore
        self.baseURL = baseURL
        self.now = now
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func connect(_ credentials: TailscaleAdminCredentials) async throws {
        try Task.checkCancellation()
        let credentials = try validated(credentials)
        try await credentialStore.save(credentials)
        await state.clearToken()
    }

    func savedCredentials() async throws -> TailscaleAdminCredentials? {
        try Task.checkCancellation()
        return try await credentialStore.load()
    }

    func disconnectAndDeleteCredentials() async throws {
        try Task.checkCancellation()
        try await credentialStore.delete()
        await state.clearToken()
    }

    func fetchSavedDevices() async throws -> [TailscaleAdminDeviceCandidate] {
        guard let credentials = try await savedCredentials() else { throw TailscaleAdminConnectorError.missingCredentials }
        return try await fetchDevices(using: credentials)
    }

    /// Fetches the current Devices API collection. Tailscale's Devices API has no pagination today, so this intentionally
    /// sends exactly one read-only request and does not fabricate page or cursor parameters.
    func fetchDevices(using credentials: TailscaleAdminCredentials) async throws -> [TailscaleAdminDeviceCandidate] {
        try Task.checkCancellation()
        let credentials = try validated(credentials)
        let token = try await validToken(for: credentials)
        do {
            return try await fetchDevices(credentials: credentials, bearerToken: token.value)
        } catch TailscaleAdminConnectorError.unauthorized {
            await state.clearToken()
            let refreshed = try await mintToken(credentials)
            await state.setToken(refreshed)
            return try await fetchDevices(credentials: credentials, bearerToken: refreshed.value)
        }
    }

    private func validToken(for credentials: TailscaleAdminCredentials) async throws -> Token {
        if let cached = await state.token(), cached.expiresAt > now().addingTimeInterval(5) {
            return cached
        }
        let token = try await mintToken(credentials)
        await state.setToken(token)
        return token
    }

    private func mintToken(_ credentials: TailscaleAdminCredentials) async throws -> Token {
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v2")
            .appendingPathComponent("oauth")
            .appendingPathComponent("token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \(basicAuth(credentials))", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("grant_type=client_credentials".utf8)
        let data = try await data(for: request, allowing: [200])
        do {
            let response = try decoder.decode(TokenResponse.self, from: data)
            return Token(value: response.accessToken, expiresAt: now().addingTimeInterval(response.expiresIn))
        } catch {
            throw TailscaleAdminConnectorError.malformedJSON
        }
    }

    private func fetchDevices(credentials: TailscaleAdminCredentials, bearerToken: String) async throws -> [TailscaleAdminDeviceCandidate] {
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v2")
            .appendingPathComponent("tailnet")
            .appendingPathComponent(credentials.tailnet)
            .appendingPathComponent("devices"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let data = try await data(for: request, allowing: [200])
        do {
            return try decoder.decode(DevicesResponse.self, from: data).devices
        } catch {
            throw TailscaleAdminConnectorError.malformedJSON
        }
    }

    private func data(for request: URLRequest, allowing allowedStatuses: Set<Int>) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TailscaleAdminConnectorError.networkUnavailable
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw TailscaleAdminConnectorError.malformedJSON }
        guard allowedStatuses.contains(http.statusCode) else { throw mapStatus(http.statusCode) }
        return data
    }

    private func mapStatus(_ status: Int) -> TailscaleAdminConnectorError {
        switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 429: .rateLimited
        default: .httpStatus(status)
        }
    }

    private func basicAuth(_ credentials: TailscaleAdminCredentials) -> String {
        Data("\(credentials.clientID):\(credentials.clientSecret)".utf8).base64EncodedString()
    }

    private func validated(_ credentials: TailscaleAdminCredentials) throws -> TailscaleAdminCredentials {
        guard credentials.validationIssues.isEmpty else {
            throw TailscaleAdminConnectorError.invalidCredentials
        }
        return credentials.normalized
    }
}

private actor ConnectorState {
    private var cachedToken: TailscaleAdminConnector.Token?

    func token() -> TailscaleAdminConnector.Token? { cachedToken }
    func setToken(_ token: TailscaleAdminConnector.Token) { cachedToken = token }
    func clearToken() { cachedToken = nil }
}

struct KeychainTailscaleAdminCredentialStore: TailscaleAdminCredentialStore {
    private let service = "OpenPaw.TailscaleAdminConnection"
    private let account = "admin-oauth"

    func save(_ credentials: TailscaleAdminCredentials) async throws {
        #if canImport(Security)
        let data = try JSONEncoder().encode(KeychainPayload(credentials))
        let query = baseQuery() as CFDictionary
        SecItemDelete(query)
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw TailscaleAdminConnectorError.keychainFailure }
        #else
        throw TailscaleAdminConnectorError.keychainUnavailable
        #endif
    }

    func load() async throws -> TailscaleAdminCredentials? {
        #if canImport(Security)
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw TailscaleAdminConnectorError.keychainFailure }
        do {
            return try JSONDecoder().decode(KeychainPayload.self, from: data).credentials
        } catch {
            throw TailscaleAdminConnectorError.malformedJSON
        }
        #else
        throw TailscaleAdminConnectorError.keychainUnavailable
        #endif
    }

    func delete() async throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TailscaleAdminConnectorError.keychainFailure }
        #else
        throw TailscaleAdminConnectorError.keychainUnavailable
        #endif
    }

    private func baseQuery() -> [String: Any] {
        #if canImport(Security)
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        #else
        [:]
        #endif
    }

    private struct KeychainPayload: Codable {
        var clientID: String
        var clientSecret: String
        var tailnet: String

        init(_ credentials: TailscaleAdminCredentials) {
            clientID = credentials.clientID
            clientSecret = credentials.clientSecret
            tailnet = credentials.tailnet
        }

        var credentials: TailscaleAdminCredentials {
            TailscaleAdminCredentials(clientID: clientID, clientSecret: clientSecret, tailnet: tailnet)
        }
    }
}
