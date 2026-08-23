import Foundation

public enum ProviderID: String, Codable, Sendable, Hashable, CaseIterable {
    case github
    case huggingFace = "huggingface"
}

public enum ProviderConnectionState: String, Codable, Sendable, Hashable {
    case disconnected
    case authorizing
    case connected
    case error
}

public struct ProviderStatus: Codable, Sendable, Hashable, Identifiable {
    public var id: ProviderID
    public var displayName: String
    public var state: ProviderConnectionState
    public var accountLabel: String?
    public var scopes: [String]
    public var repoListingSupported: Bool

    public init(id: ProviderID, displayName: String, state: ProviderConnectionState, accountLabel: String? = nil, scopes: [String] = [], repoListingSupported: Bool) {
        self.id = id; self.displayName = displayName; self.state = state; self.accountLabel = accountLabel; self.scopes = scopes; self.repoListingSupported = repoListingSupported
    }

    enum CodingKeys: String, CodingKey { case id, displayName = "display_name", state, accountLabel = "account_label", scopes, repoListingSupported = "repo_listing_supported" }
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

    enum CodingKeys: String, CodingKey { case authorizationID = "authorization_id", verificationURL = "verification_url", userCode = "user_code", expiresAt = "expires_at", intervalSeconds = "interval_seconds" }
}

public enum ProviderAuthorizationState: String, Codable, Sendable, Hashable { case pending, slowDown = "slow_down", authorized, denied, expired, cancelled }

public struct ProviderAuthorizationStatus: Codable, Sendable, Hashable {
    public var authorizationID: String
    public var state: ProviderAuthorizationState
    public var provider: ProviderID
    public var accountLabel: String?

    public init(authorizationID: String, state: ProviderAuthorizationState, provider: ProviderID, accountLabel: String? = nil) {
        self.authorizationID = authorizationID; self.state = state; self.provider = provider; self.accountLabel = accountLabel
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
    public var cloneURLRedacted: String?

    public init(id: String, provider: ProviderID, owner: String, name: String, displayName: String, isPrivate: Bool, cloneURLRedacted: String? = nil) {
        self.id = id; self.provider = provider; self.owner = owner; self.name = name; self.displayName = displayName; self.isPrivate = isPrivate; self.cloneURLRedacted = cloneURLRedacted
    }
    enum CodingKeys: String, CodingKey { case id, provider, owner, name, displayName = "display_name", isPrivate = "is_private", cloneURLRedacted = "clone_url_redacted" }
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
    public init(provider: ProviderID, repoID: String, requestedName: String? = nil) { self.provider = provider; self.repoID = repoID; self.requestedName = requestedName }
    enum CodingKeys: String, CodingKey { case provider, repoID = "repo_id", requestedName = "requested_name" }
}

public struct RepoRegisterRequest: Codable, Sendable, Hashable {
    public var rootID: String
    public var requestedName: String?
    public init(rootID: String, requestedName: String? = nil) { self.rootID = rootID; self.requestedName = requestedName }
    enum CodingKeys: String, CodingKey { case rootID = "root_id", requestedName = "requested_name" }
}

public enum RepoImportState: String, Codable, Sendable, Hashable { case queued, cloning, indexing, completed, failed, cancelled }

public struct RepoImportProgress: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var state: RepoImportState
    public var repoName: String
    public var destinationName: String
    public var percent: UInt8?
    public var message: String?
    public var sourceURLRedacted: String?

    public init(id: String, state: RepoImportState, repoName: String, destinationName: String, percent: UInt8? = nil, message: String? = nil, sourceURLRedacted: String? = nil) {
        self.id = id; self.state = state; self.repoName = repoName; self.destinationName = destinationName; self.percent = percent; self.message = message; self.sourceURLRedacted = sourceURLRedacted
    }
    enum CodingKeys: String, CodingKey { case id, state, repoName = "repo_name", destinationName = "destination_name", percent, message, sourceURLRedacted = "source_url_redacted" }
}
