import Foundation

public enum ProviderRepoContractError: Error, Sendable, Equatable {
    case invalidIdentifier(String)
    case invalidMessageLength(Int)
    case invalidPercent(UInt8)
}

private func validateWireIdentifier(_ value: String) throws {
    let lower = value.lowercased()
    guard !value.isEmpty, value.utf8.count <= 128,
          !value.hasPrefix("-"), !value.contains(".."),
          !lower.contains("%2f"), !lower.contains("%5c"),
          value.rangeOfCharacter(from: CharacterSet.controlCharacters) == nil,
          !value.contains("/"), !value.contains("\\"),
          value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") })
    else { throw ProviderRepoContractError.invalidIdentifier(value) }
}

private func validateMessage(_ value: String?) throws {
    if let value, value.count > 500 { throw ProviderRepoContractError.invalidMessageLength(value.count) }
}

private func validatePercent(_ value: UInt8?) throws {
    if let value, value > 100 { throw ProviderRepoContractError.invalidPercent(value) }
}

public enum ProviderID: String, Codable, Sendable, Hashable, CaseIterable {
    case github
    case huggingFace = "huggingface"
}

public enum ProviderConnectionState: Codable, Sendable, Hashable {
    case disconnected, authorizing, connected, reauthorizationRequired, outage, error
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "disconnected": self = .disconnected
        case "authorizing": self = .authorizing
        case "connected": self = .connected
        case "reauthorization_required": self = .reauthorizationRequired
        case "outage": self = .outage
        case "error": self = .error
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .disconnected: try container.encode("disconnected")
        case .authorizing: try container.encode("authorizing")
        case .connected: try container.encode("connected")
        case .reauthorizationRequired: try container.encode("reauthorization_required")
        case .outage: try container.encode("outage")
        case .error: try container.encode("error")
        case .unknown(let value): try container.encode(value)
        }
    }
}

public enum ProviderRemoteRevokeResult: Codable, Sendable, Hashable {
    case revoked, unsupported, failed
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "revoked": self = .revoked
        case "unsupported": self = .unsupported
        case "failed": self = .failed
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .revoked: try container.encode("revoked")
        case .unsupported: try container.encode("unsupported")
        case .failed: try container.encode("failed")
        case .unknown(let value): try container.encode(value)
        }
    }
}

public struct ProviderStatus: Codable, Sendable, Hashable, Identifiable {
    public var id: ProviderID
    public var displayName: String
    public var state: ProviderConnectionState
    public var accountLabel: String?
    public var scopes: [String]
    public var repoListingSupported: Bool
    public var remoteRevokeResult: ProviderRemoteRevokeResult?

    public init(id: ProviderID, displayName: String, state: ProviderConnectionState, accountLabel: String? = nil, scopes: [String] = [], repoListingSupported: Bool, remoteRevokeResult: ProviderRemoteRevokeResult? = nil) {
        self.id = id; self.displayName = displayName; self.state = state; self.accountLabel = accountLabel; self.scopes = scopes; self.repoListingSupported = repoListingSupported; self.remoteRevokeResult = remoteRevokeResult
    }

    enum CodingKeys: String, CodingKey { case id, displayName = "display_name", state, accountLabel = "account_label", scopes, repoListingSupported = "repo_listing_supported", remoteRevokeResult = "remote_revoke_result" }
}

public struct ProviderAuthorizationStart: Codable, Sendable, Hashable {
    public var authorizationID: String
    public var verificationURL: URL
    public var userCode: String
    public var expiresAt: Date
    public var intervalSeconds: UInt32

    public init(authorizationID: String, verificationURL: URL, userCode: String, expiresAt: Date, intervalSeconds: UInt32) {
        self.authorizationID = authorizationID; self.verificationURL = verificationURL; self.userCode = userCode; self.expiresAt = expiresAt; self.intervalSeconds = intervalSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let authorizationID = try container.decode(String.self, forKey: .authorizationID)
        try validateWireIdentifier(authorizationID)
        self.authorizationID = authorizationID
        self.verificationURL = try container.decode(URL.self, forKey: .verificationURL)
        self.userCode = try container.decode(String.self, forKey: .userCode)
        self.expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        self.intervalSeconds = try container.decode(UInt32.self, forKey: .intervalSeconds)
    }

    enum CodingKeys: String, CodingKey { case authorizationID = "authorization_id", verificationURL = "verification_url", userCode = "user_code", expiresAt = "expires_at", intervalSeconds = "interval_seconds" }
}

public enum ProviderAuthorizationState: Codable, Sendable, Hashable {
    case pending, slowDown, authorized, denied, expired, cancelled, reauthorizationRequired, outage
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "pending": self = .pending
        case "slow_down": self = .slowDown
        case "authorized": self = .authorized
        case "denied": self = .denied
        case "expired": self = .expired
        case "cancelled": self = .cancelled
        case "reauthorization_required": self = .reauthorizationRequired
        case "outage": self = .outage
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .pending: try container.encode("pending")
        case .slowDown: try container.encode("slow_down")
        case .authorized: try container.encode("authorized")
        case .denied: try container.encode("denied")
        case .expired: try container.encode("expired")
        case .cancelled: try container.encode("cancelled")
        case .reauthorizationRequired: try container.encode("reauthorization_required")
        case .outage: try container.encode("outage")
        case .unknown(let value): try container.encode(value)
        }
    }
}

public struct ProviderAuthorizationStatus: Codable, Sendable, Hashable {
    public var authorizationID: String
    public var state: ProviderAuthorizationState
    public var provider: ProviderID
    public var accountLabel: String?

    public init(authorizationID: String, state: ProviderAuthorizationState, provider: ProviderID, accountLabel: String? = nil) {
        self.authorizationID = authorizationID; self.state = state; self.provider = provider; self.accountLabel = accountLabel
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let authorizationID = try container.decode(String.self, forKey: .authorizationID)
        try validateWireIdentifier(authorizationID)
        self.authorizationID = authorizationID
        self.state = try container.decode(ProviderAuthorizationState.self, forKey: .state)
        self.provider = try container.decode(ProviderID.self, forKey: .provider)
        self.accountLabel = try container.decodeIfPresent(String.self, forKey: .accountLabel)
    }
    enum CodingKeys: String, CodingKey { case authorizationID = "authorization_id", state, provider, accountLabel = "account_label" }
}

public struct ProviderRepo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var provider: ProviderID
    public var owner: String
    public var name: String
    public var displayName: String
    public var isPrivate: Bool
    public var sourceURLRedacted: String?

    public init(id: String, provider: ProviderID, owner: String, name: String, displayName: String, isPrivate: Bool, sourceURLRedacted: String? = nil) throws {
        try validateWireIdentifier(id)
        self.id = id; self.provider = provider; self.owner = owner; self.name = name; self.displayName = displayName; self.isPrivate = isPrivate; self.sourceURLRedacted = sourceURLRedacted
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            provider: container.decode(ProviderID.self, forKey: .provider),
            owner: container.decode(String.self, forKey: .owner),
            name: container.decode(String.self, forKey: .name),
            displayName: container.decode(String.self, forKey: .displayName),
            isPrivate: container.decode(Bool.self, forKey: .isPrivate),
            sourceURLRedacted: container.decodeIfPresent(String.self, forKey: .sourceURLRedacted)
        )
    }
    enum CodingKeys: String, CodingKey { case id, provider, owner, name, displayName = "display_name", isPrivate = "is_private", sourceURLRedacted = "source_url_redacted" }
}

public struct ProviderRepoPage: Codable, Sendable, Hashable {
    public var repos: [ProviderRepo]
    public var nextCursor: String?
    public init(repos: [ProviderRepo], nextCursor: String? = nil) { self.repos = repos; self.nextCursor = nextCursor }
    enum CodingKeys: String, CodingKey { case repos, nextCursor = "next_cursor" }
}

public struct RepoImportRequest: Codable, Sendable, Hashable {
    public var provider: ProviderID
    public var repoID: String
    public var requestedName: String?
    public init(provider: ProviderID, repoID: String, requestedName: String? = nil) throws { try validateWireIdentifier(repoID); if let requestedName { try validateWireIdentifier(requestedName) }; self.provider = provider; self.repoID = repoID; self.requestedName = requestedName }
    public init(from decoder: Decoder) throws { let container = try decoder.container(keyedBy: CodingKeys.self); try self.init(provider: container.decode(ProviderID.self, forKey: .provider), repoID: container.decode(String.self, forKey: .repoID), requestedName: container.decodeIfPresent(String.self, forKey: .requestedName)) }
    enum CodingKeys: String, CodingKey { case provider, repoID = "repo_id", requestedName = "requested_name" }
}

public struct RepoRegisterRequest: Codable, Sendable, Hashable {
    public var rootID: String
    public var requestedName: String?
    public init(rootID: String, requestedName: String? = nil) throws { try validateWireIdentifier(rootID); if let requestedName { try validateWireIdentifier(requestedName) }; self.rootID = rootID; self.requestedName = requestedName }
    public init(from decoder: Decoder) throws { let container = try decoder.container(keyedBy: CodingKeys.self); try self.init(rootID: container.decode(String.self, forKey: .rootID), requestedName: container.decodeIfPresent(String.self, forKey: .requestedName)) }
    enum CodingKeys: String, CodingKey { case rootID = "root_id", requestedName = "requested_name" }
}

public enum RepoImportState: Codable, Sendable, Hashable {
    case queued, authorizing, cloning, validating, registering, completed, failed, cancelled, recoveryRequired
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "queued": self = .queued
        case "authorizing": self = .authorizing
        case "cloning": self = .cloning
        case "validating": self = .validating
        case "registering": self = .registering
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        case "recovery_required": self = .recoveryRequired
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .queued: try container.encode("queued")
        case .authorizing: try container.encode("authorizing")
        case .cloning: try container.encode("cloning")
        case .validating: try container.encode("validating")
        case .registering: try container.encode("registering")
        case .completed: try container.encode("completed")
        case .failed: try container.encode("failed")
        case .cancelled: try container.encode("cancelled")
        case .recoveryRequired: try container.encode("recovery_required")
        case .unknown(let value): try container.encode(value)
        }
    }
}

public struct RepoImportProgress: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var state: RepoImportState
    public var repoName: String
    public var destinationName: String
    public var percent: UInt8?
    public var message: String?
    public var sourceURLRedacted: String?

    public init(id: String, state: RepoImportState, repoName: String, destinationName: String, percent: UInt8? = nil, message: String? = nil, sourceURLRedacted: String? = nil) throws {
        try validateWireIdentifier(id); try validatePercent(percent); try validateMessage(message)
        self.id = id; self.state = state; self.repoName = repoName; self.destinationName = destinationName; self.percent = percent; self.message = message; self.sourceURLRedacted = sourceURLRedacted
    }
    public init(from decoder: Decoder) throws { let container = try decoder.container(keyedBy: CodingKeys.self); try self.init(id: container.decode(String.self, forKey: .id), state: container.decode(RepoImportState.self, forKey: .state), repoName: container.decode(String.self, forKey: .repoName), destinationName: container.decode(String.self, forKey: .destinationName), percent: container.decodeIfPresent(UInt8.self, forKey: .percent), message: container.decodeIfPresent(String.self, forKey: .message), sourceURLRedacted: container.decodeIfPresent(String.self, forKey: .sourceURLRedacted)) }
    enum CodingKeys: String, CodingKey { case id, state, repoName = "repo_name", destinationName = "destination_name", percent, message, sourceURLRedacted = "source_url_redacted" }
}
