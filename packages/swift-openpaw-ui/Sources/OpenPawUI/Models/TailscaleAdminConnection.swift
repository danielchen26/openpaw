import Foundation

/// Admin-created Tailscale OAuth credentials for a single tailnet.
///
/// These values are secrets or security-sensitive identifiers. App code must store them in Keychain only, never in
/// UserDefaults, logs, exported diagnostics, or host persistence.
public struct TailscaleAdminCredentials: Sendable, Hashable {
    public var clientID: String
    public var clientSecret: String
    public var tailnet: String

    public init(clientID: String, clientSecret: String, tailnet: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.tailnet = tailnet
    }

    public var validationIssues: [TailscaleAdminCredentialValidationIssue] {
        var issues: [TailscaleAdminCredentialValidationIssue] = []
        let normalizedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTailnet = tailnet.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedClientID.isEmpty {
            issues.append(.missingClientID)
        } else if normalizedClientID.contains(":") || normalizedClientID.contains(where: \.isNewline) {
            issues.append(.invalidClientID)
        }
        if normalizedSecret.isEmpty { issues.append(.missingClientSecret) }
        if normalizedTailnet.isEmpty {
            issues.append(.missingTailnet)
        } else if normalizedTailnet.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" || $0.isWhitespace }) {
            issues.append(.invalidTailnet)
        }
        return issues
    }

    public var normalized: TailscaleAdminCredentials {
        TailscaleAdminCredentials(
            clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: clientSecret,
            tailnet: tailnet.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

public enum TailscaleAdminCredentialValidationIssue: String, Sendable, Hashable {
    case missingClientID
    case missingClientSecret
    case missingTailnet
    case invalidClientID
    case invalidTailnet
}

public enum TailscaleAdminConnectionState: Sendable, Hashable {
    case disconnected
    case connecting
    case refreshing
    case candidates([TailscaleAdminDeviceCandidate])
    case failure(message: String)
}

public enum TailscaleAdminConnectionError: Error, CustomStringConvertible, Sendable, Hashable {
    case unauthorized
    case forbidden
    case rateLimited
    case httpStatus(Int)
    case malformedJSON
    case missingCredentials
    case invalidCredentials
    case networkUnavailable
    case keychainUnavailable
    case keychainFailure

    public var description: String {
        switch self {
        case .unauthorized: "TailscaleAdminConnectionError.unauthorized"
        case .forbidden: "TailscaleAdminConnectionError.forbidden"
        case .rateLimited: "TailscaleAdminConnectionError.rateLimited"
        case .httpStatus(let status): "TailscaleAdminConnectionError.httpStatus(\(status))"
        case .malformedJSON: "TailscaleAdminConnectionError.malformedJSON"
        case .missingCredentials: "TailscaleAdminConnectionError.missingCredentials"
        case .invalidCredentials: "TailscaleAdminConnectionError.invalidCredentials"
        case .networkUnavailable: "TailscaleAdminConnectionError.networkUnavailable"
        case .keychainUnavailable: "TailscaleAdminConnectionError.keychainUnavailable"
        case .keychainFailure: "TailscaleAdminConnectionError.keychainFailure"
        }
    }
}

/// App-owned implementation seam. The SwiftUI package never handles URLSession or Keychain details itself.
public protocol TailscaleAdminConnecting: Sendable {
    func connect(_ credentials: TailscaleAdminCredentials) async throws
    func fetchSavedDevices() async throws -> [TailscaleAdminDeviceCandidate]
    func disconnectAndDeleteCredentials() async throws
}

/// A read-only device candidate returned by the Tailscale Devices API.
///
/// Candidates are metadata only. They are intentionally not OpenPaw hosts and must not be saved as hosts by this
/// connector. The official Devices API response is not paginated today; callers should fetch this single collection and
/// tolerate unknown JSON fields for forward compatibility.
public struct TailscaleAdminDeviceCandidate: Sendable, Hashable, Decodable {
    public var id: String
    public var name: String
    public var hostname: String?
    public var addresses: [String]
    public var os: String?
    public var user: String?
    public var lastSeen: Date?
    public var isOnline: Bool?

    public init(
        id: String,
        name: String,
        hostname: String? = nil,
        addresses: [String] = [],
        os: String? = nil,
        user: String? = nil,
        lastSeen: Date? = nil,
        isOnline: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.addresses = addresses
        self.os = os
        self.user = user
        self.lastSeen = lastSeen
        self.isOnline = isOnline
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case hostname
        case addresses
        case os
        case user
        case lastSeen
        case connectedToControl
        case legacyOnline = "online"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        addresses = try container.decode([String].self, forKey: .addresses)
        os = try container.decodeIfPresent(String.self, forKey: .os)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen)
        isOnline = try container.decodeIfPresent(Bool.self, forKey: .connectedToControl)
            ?? container.decodeIfPresent(Bool.self, forKey: .legacyOnline)
    }
}
