import Foundation

public struct TailscaleLocalProfile: Sendable, Hashable, Codable {
    public var loginName: String?
    public var displayName: String?
    public init(loginName: String? = nil, displayName: String? = nil) { self.loginName = loginName; self.displayName = displayName }
}

public struct TailscaleLocalIdentity: Sendable, Hashable, Codable {
    public var profile: TailscaleLocalProfile?
    public var status: String?
    public var deviceName: String?
    public var os: String?
    public var ipv4: String?
    public var ipv6: String?
    public var id: String?
    public var domainName: String?
    public var tailnetName: String?

    public init(profile: TailscaleLocalProfile? = nil, status: String? = nil, deviceName: String? = nil, os: String? = nil, ipv4: String? = nil, ipv6: String? = nil, id: String? = nil, domainName: String? = nil, tailnetName: String? = nil) {
        self.profile = profile; self.status = status; self.deviceName = deviceName; self.os = os; self.ipv4 = ipv4; self.ipv6 = ipv6; self.id = id; self.domainName = domainName; self.tailnetName = tailnetName
    }
}

public enum TailscaleLocalIdentityError: Error, Sendable, Hashable, CustomStringConvertible {
    case unavailable
    case responseTooLarge
    case redirectRefused
    case malformedJSON
    case networkUnavailable

    public var description: String {
        switch self {
        case .unavailable: "Quad100 local identity is unavailable on this client."
        case .responseTooLarge: "Quad100 returned more data than OpenPaw accepts."
        case .redirectRefused: "Quad100 local identity redirected unexpectedly."
        case .malformedJSON: "Quad100 returned unsupported identity JSON."
        case .networkUnavailable: "Quad100 local identity could not be reached."
        }
    }
}

public protocol TailscaleLocalIdentityConnecting: Sendable {
    func localIdentity() async throws -> TailscaleLocalIdentity
}

public struct FixtureTailscaleLocalIdentityConnector: TailscaleLocalIdentityConnecting {
    private let result: Result<TailscaleLocalIdentity, any Error>
    public init(identity: TailscaleLocalIdentity) { self.result = .success(identity) }
    public init(error: any Error = TailscaleLocalIdentityError.unavailable) { self.result = .failure(error) }
    public func localIdentity() async throws -> TailscaleLocalIdentity { try result.get() }
}

public struct HomeTailnetBootstrapState: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable { case none, localIdentity, savedAdministrator, pairedHost, merged }
    public enum Phase: Sendable, Hashable { case idle, loading, loaded, unavailable, failed(String) }
    public var phase: Phase = .idle
    public var localIdentity: TailscaleLocalIdentity?
    public var candidates: [AddDeviceCandidate] = []
    public var source: Source = .none
    public var routeHint: TailscaleRouteHint = .notDetected
    public var refreshedAt: Date?
    public var candidateCount: Int { candidates.count }
    public init() {}
}
