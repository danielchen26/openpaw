import Foundation
import OpenPawProtocol
import OpenPawTerminalCore

/// One host-scoped Inbox destination carried by a notification or custom URL.
///
/// Both identifiers are required. An Inbox id alone is ambiguous because every paired host owns its own event bus.
public struct InboxRoute: Sendable, Hashable {
    public static let scheme = "openpaw"
    public static let host = "inbox"

    public let hostID: HostID
    public let itemID: InboxID

    public init(hostID: HostID, itemID: InboxID) {
        self.hostID = hostID
        self.itemID = itemID
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme,
              components.host?.lowercased() == Self.host,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { return nil }

        let queryItems = components.queryItems ?? []
        guard queryItems.count == 2,
              queryItems.filter({ $0.name == "host" }).count == 1,
              queryItems.filter({ $0.name == "item" }).count == 1,
              let hostText = queryItems.first(where: { $0.name == "host" })?.value,
              let itemText = queryItems.first(where: { $0.name == "item" })?.value,
              let hostID = UUID(uuidString: hostText),
              Self.validItemID(itemText)
        else { return nil }

        self.init(hostID: hostID, itemID: InboxID(rawValue: itemText))
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "host", value: hostID.uuidString),
            URLQueryItem(name: "item", value: itemID.rawValue),
        ]
        return components.url!
    }

    private static func validItemID(_ value: String) -> Bool {
        guard value.hasPrefix("inb_") else { return false }
        let suffix = value.utf8.dropFirst(4)
        guard suffix.count == 24 else { return false }
        return suffix.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

public enum InboxRouteResolution: Sendable, Hashable {
    case present(InboxItem)
    case unknownHost
    case stale
    case resolved(InboxStatus)
    case unavailable
}

/// Selects and connects the route's paired host before reading the item from that host's authenticated Inbox.
/// Every await is followed by a connection-lease check so a late route cannot present data over a newer host.
@MainActor
public enum InboxRouteCoordinator {
    public static func resolve(
        _ route: InboxRoute,
        model: OpenPawModel,
        ownsRoute: @MainActor @Sendable () -> Bool = { true },
        mayRollback: @MainActor @Sendable () -> Bool = { false }
    ) async -> InboxRouteResolution {
        guard ownsRoute(), !Task.isCancelled else { return .unavailable }
        guard let host = model.hostStore.hosts.first(where: { $0.id == route.hostID }) else {
            return .unknownHost
        }

        let originalHostID = model.selectedHostID
        let originalWasConnected = model.connection.isConnected
        let alreadyReady = model.selectedHostID == host.id && model.connection.isConnected
        var routeLease: HostConnectionLease?

        func unavailableAfterRollingBackIfOwned() async -> InboxRouteResolution {
            guard mayRollback() else { return .unavailable }
            guard model.selectedHostID == host.id else { return .unavailable }
            if let routeLease, !model.ownsConnection(routeLease) {
                return .unavailable
            }

            if originalHostID == host.id {
                if !originalWasConnected {
                    await model.disconnect()
                }
            } else {
                await model.selectHost(originalHostID)
            }
            return .unavailable
        }

        if model.selectedHostID != host.id {
            guard ownsRoute(), !Task.isCancelled else { return .unavailable }
            await model.selectHost(host.id)
        }
        guard ownsRoute(), !Task.isCancelled else {
            return await unavailableAfterRollingBackIfOwned()
        }
        guard model.selectedHostID == host.id else { return .unavailable }

        let lease: HostConnectionLease?
        if alreadyReady {
            lease = model.currentConnectionLease
            guard ownsRoute(), !Task.isCancelled else { return .unavailable }
            await model.refresh()
        } else {
            // `connectSelectedHost()` owns the initial structured-host refresh. Running another here would issue the
            // same four authenticated reads twice for every notification tap.
            guard ownsRoute(), !Task.isCancelled else { return .unavailable }
            lease = await model.connectSelectedHost()
        }
        routeLease = lease
        guard ownsRoute(), !Task.isCancelled else {
            return await unavailableAfterRollingBackIfOwned()
        }
        guard let lease, model.ownsConnection(lease) else { return .unavailable }
        guard model.ownsConnection(lease), model.selectedHostID == route.hostID else {
            return .unavailable
        }
        guard ownsRoute(), !Task.isCancelled else { return .unavailable }
        guard let item = model.inbox.first(where: { $0.id == route.itemID }) else {
            return .stale
        }
        guard item.status == .pending else { return .resolved(item.status) }
        return .present(item)
    }
}
