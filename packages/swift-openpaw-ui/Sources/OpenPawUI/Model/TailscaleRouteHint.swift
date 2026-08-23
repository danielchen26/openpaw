import Foundation
#if canImport(Network)
import Network
#endif

/// A local route is only a connectivity hint. It never identifies a Tailscale account and never carries devices.
public enum TailscaleRouteHint: String, Sendable, Hashable {
    case notDetected
    case likelyAvailable
}

/// A SwiftUI flow owns its discovery request for its whole presentation lifetime.
/// Re-rendering the same flow does not issue another host request, while a new flow receives a new identifier.
public struct TailscaleDiscoveryFlowID: Sendable, Hashable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum TailscaleDiscoverySource: Sendable, Hashable {
    case pairedHost(id: UUID, displayName: String)
    case tailnetAdministrator

    public var displayName: String {
        switch self {
        case .pairedHost(_, let displayName): displayName
        case .tailnetAdministrator: "Tailnet administrator connector"
        }
    }
}

/// Metadata shown beside candidates so the UI never implies that the installed Tailscale app supplied an account.
public struct TailscaleDiscoveryMetadata: Sendable, Hashable {
    public var source: TailscaleDiscoverySource
    public var routeHint: TailscaleRouteHint
    public var refreshedAt: Date?

    public init(
        source: TailscaleDiscoverySource,
        routeHint: TailscaleRouteHint,
        refreshedAt: Date?
    ) {
        self.source = source
        self.routeHint = routeHint
        self.refreshedAt = refreshedAt
    }
}

/// The minimum local path metadata needed to recognize a likely Tailscale route.
public struct TailscaleRoutePathSnapshot: Sendable, Hashable {
    public var isSatisfied: Bool
    public var interfaceNames: [String]
    public var addresses: [String]

    public init(isSatisfied: Bool, interfaceNames: [String], addresses: [String] = []) {
        self.isSatisfied = isSatisfied
        self.interfaceNames = interfaceNames
        self.addresses = addresses
    }
}

/// Injectable seam for the system route reader. Tests provide snapshots and the app provides the live path source.
public protocol TailscaleRoutePathSourcing: Sendable {
    func currentSnapshot() async -> TailscaleRoutePathSnapshot
}

/// Safe default for previews, tests, and platforms without a live Network-framework source.
public struct UnavailableTailscaleRoutePathSource: TailscaleRoutePathSourcing {
    public init() {}

    public func currentSnapshot() async -> TailscaleRoutePathSnapshot {
        TailscaleRoutePathSnapshot(isSatisfied: false, interfaceNames: [])
    }
}

/// Production route reader. `NWPathMonitor` exposes reachability and interface names, not the installed Tailscale
/// account or peer list. Waiting briefly for its first path update is acceptable because this result is only a hint.
public struct SystemTailscaleRoutePathSource: TailscaleRoutePathSourcing {
    public init() {}

    public func currentSnapshot() async -> TailscaleRoutePathSnapshot {
        #if canImport(Network)
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "dev.openpaw.tailscale-route-hint")
        monitor.start(queue: queue)
        defer { monitor.cancel() }
        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            return TailscaleRoutePathSnapshot(isSatisfied: false, interfaceNames: [])
        }
        let path = monitor.currentPath
        return TailscaleRoutePathSnapshot(
            isSatisfied: path.status == .satisfied,
            interfaceNames: path.availableInterfaces.map(\.name)
        )
        #else
        return TailscaleRoutePathSnapshot(isSatisfied: false, interfaceNames: [])
        #endif
    }
}

public struct TailscaleRouteHintResolver: Sendable {
    private let source: any TailscaleRoutePathSourcing

    public init(source: any TailscaleRoutePathSourcing) {
        self.source = source
    }

    public func currentHint() async -> TailscaleRouteHint {
        let snapshot = await source.currentSnapshot()
        guard snapshot.isSatisfied else { return .notDetected }
        if snapshot.interfaceNames.contains(where: Self.isTailscaleLookingInterface) {
            return .likelyAvailable
        }
        if snapshot.addresses.contains(where: Self.isTailscaleAddress) {
            return .likelyAvailable
        }
        return .notDetected
    }

    private static func isTailscaleLookingInterface(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("utun") || normalized.contains("tailscale")
    }

    private static func isTailscaleAddress(_ address: String) -> Bool {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("fd7a:115c:a1e0:") { return true }
        let octets = normalized.split(separator: ".").compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }
}
