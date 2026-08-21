import Foundation

public enum NotificationPayloadError: Error, Equatable, Sendable {
    case forbiddenField(String)
    case malformed
    case invalidSchemaVersion
    case emptyIdentifier
    case invalidTimeRange
    case oversized
    case duplicate
    case expired
    case futureSkew
    case stale
}

public struct SafeNotificationTitle: Hashable, Codable, Sendable {
    public static let defaultMaxUTF8Bytes = 96
    public static let defaultMaxScalars = 64
    public let value: String

    public init(_ raw: String, maxUTF8Bytes: Int = Self.defaultMaxUTF8Bytes, maxScalars: Int = Self.defaultMaxScalars) throws {
        var sanitized = raw.replacingOccurrences(of: #"(?i)(action[_-]?token|command|credentials|raw[_-]?detail|secret|token|password|credential)\s*[:=]\s*\S+"#, with: "[redacted]", options: .regularExpression)
        sanitized = sanitized.replacingOccurrences(of: #"(?i)(action[_-]?token|command|credentials|raw[_-]?detail|secret|token|password|credential)"#, with: "[redacted]", options: .regularExpression)
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty { sanitized = "OpenPaw notification" }
        var result = ""
        for scalar in sanitized.unicodeScalars {
            let candidate = result + String(scalar)
            if candidate.unicodeScalars.count > maxScalars || candidate.utf8.count > maxUTF8Bytes { break }
            result = candidate
        }
        self.value = result.isEmpty ? "OpenPaw" : result
    }
}

public enum NotificationCategory: String, Codable, Hashable, Sendable {
    case message
    case decisionRequired = "decision_required"
    case riskAlert = "risk_alert"
}

public enum NotificationRisk: String, Codable, Hashable, Sendable {
    case low, medium, high, critical
}

public enum NotificationActionIntent: Hashable, Sendable {
    case openInbox
    case openDetail(inboxID: String)
    case decisionReview(inboxID: String, decisionID: String)

    public var requiresForegroundAuthenticatedRefresh: Bool {
        if case .decisionReview = self { return true }
        return false
    }

    public var carriesAuthorizationMaterial: Bool { false }
}

extension NotificationActionIntent: Codable {
    private enum CodingKeys: String, CodingKey { case type, inboxID = "inbox_id", decisionID = "decision_id" }
    private enum Kind: String, Codable { case openInbox = "open_inbox", openDetail = "open_detail", decisionReview = "decision_review" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .openInbox: self = .openInbox
        case .openDetail: self = .openDetail(inboxID: try c.decode(String.self, forKey: .inboxID))
        case .decisionReview: self = .decisionReview(inboxID: try c.decode(String.self, forKey: .inboxID), decisionID: try c.decode(String.self, forKey: .decisionID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .openInbox:
            try c.encode(Kind.openInbox, forKey: .type)
        case .openDetail(let inboxID):
            try c.encode(Kind.openDetail, forKey: .type)
            try c.encode(inboxID, forKey: .inboxID)
        case .decisionReview(let inboxID, let decisionID):
            try c.encode(Kind.decisionReview, forKey: .type)
            try c.encode(inboxID, forKey: .inboxID)
            try c.encode(decisionID, forKey: .decisionID)
        }
    }
}

public struct NotificationHint: Hashable, Codable, Sendable {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    public let id: String
    public let hostID: String
    public let deviceID: String
    public let sessionID: String
    public let inboxID: String
    public let category: NotificationCategory
    public let risk: NotificationRisk
    public let createdAt: Int64
    public let expiresAt: Int64
    public let nonce: String
    public let title: SafeNotificationTitle
    public let actionIntent: NotificationActionIntent

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", id, hostID = "host_id", deviceID = "device_id", sessionID = "session_id", inboxID = "inbox_id", category, risk, createdAt = "created_at", expiresAt = "expires_at", nonce, title, actionIntent = "action_intent"
    }

    public init(id: String, hostID: String, deviceID: String, sessionID: String, inboxID: String, category: NotificationCategory, risk: NotificationRisk, createdAt: Int64, expiresAt: Int64, nonce: String, title: String, actionIntent: NotificationActionIntent) throws {
        guard ![id, hostID, deviceID, sessionID, inboxID, nonce].contains(where: { $0.isEmpty }) else { throw NotificationPayloadError.emptyIdentifier }
        guard expiresAt > createdAt else { throw NotificationPayloadError.invalidTimeRange }
        self.schemaVersion = Self.schemaVersion
        self.id = id; self.hostID = hostID; self.deviceID = deviceID; self.sessionID = sessionID; self.inboxID = inboxID
        self.category = category; self.risk = risk; self.createdAt = createdAt; self.expiresAt = expiresAt; self.nonce = nonce
        self.title = try SafeNotificationTitle(title)
        self.actionIntent = actionIntent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else { throw NotificationPayloadError.invalidSchemaVersion }
        let titleString = try c.decode(String.self, forKey: .title)
        try self.init(id: c.decode(String.self, forKey: .id), hostID: c.decode(String.self, forKey: .hostID), deviceID: c.decode(String.self, forKey: .deviceID), sessionID: c.decode(String.self, forKey: .sessionID), inboxID: c.decode(String.self, forKey: .inboxID), category: c.decode(NotificationCategory.self, forKey: .category), risk: c.decode(NotificationRisk.self, forKey: .risk), createdAt: c.decode(Int64.self, forKey: .createdAt), expiresAt: c.decode(Int64.self, forKey: .expiresAt), nonce: c.decode(String.self, forKey: .nonce), title: titleString, actionIntent: c.decode(NotificationActionIntent.self, forKey: .actionIntent))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(id, forKey: .id); try c.encode(hostID, forKey: .hostID); try c.encode(deviceID, forKey: .deviceID); try c.encode(sessionID, forKey: .sessionID); try c.encode(inboxID, forKey: .inboxID); try c.encode(category, forKey: .category); try c.encode(risk, forKey: .risk); try c.encode(createdAt, forKey: .createdAt); try c.encode(expiresAt, forKey: .expiresAt); try c.encode(nonce, forKey: .nonce); try c.encode(title.value, forKey: .title); try c.encode(actionIntent, forKey: .actionIntent)
    }
}

public extension JSONEncoder {
    static var openPawNotifications: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

public enum NotificationPayloadValidator {
    public static let forbiddenFields: Set<String> = ["action_token", "command", "credentials", "raw_detail", "secret"]
    public static func decode(_ data: Data, now: Int64, gate: inout NotificationReplayExpiryGate) throws -> NotificationHint {
        let hint = try decode(data, now: now)
        try gate.accept(hint, payloadByteCount: data.count, now: now)
        return hint
    }
    public static func decode(_ data: Data, now: Int64) throws -> NotificationHint {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NotificationPayloadError.malformed }
        for field in forbiddenFields where object.keys.contains(field) { throw NotificationPayloadError.forbiddenField(field) }
        return try JSONDecoder().decode(NotificationHint.self, from: data)
    }
}

public struct NotificationReplayExpiryGate: Sendable {
    public let capacity: Int
    public let maxPayloadBytes: Int
    public let maxClockSkewSeconds: Int64
    public let maxAgeSeconds: Int64
    private var seen: [String: Int64] = [:]
    private var order: [String] = []

    public init(capacity: Int = 256, maxPayloadBytes: Int = 4096, maxClockSkewSeconds: Int64 = 300, maxAgeSeconds: Int64 = 86_400) {
        self.capacity = max(1, capacity); self.maxPayloadBytes = maxPayloadBytes; self.maxClockSkewSeconds = maxClockSkewSeconds; self.maxAgeSeconds = maxAgeSeconds
    }
    public mutating func accept(_ hint: NotificationHint, payloadByteCount: Int, now: Int64) throws {
        guard payloadByteCount <= maxPayloadBytes else { throw NotificationPayloadError.oversized }
        guard hint.createdAt <= now + maxClockSkewSeconds else { throw NotificationPayloadError.futureSkew }
        guard now - hint.createdAt <= maxAgeSeconds else { throw NotificationPayloadError.stale }
        guard now < hint.expiresAt else { throw NotificationPayloadError.expired }
        let key = hint.id + "|" + hint.nonce
        guard seen[key] == nil else { throw NotificationPayloadError.duplicate }
        seen[key] = now; order.append(key)
        while order.count > capacity { seen.removeValue(forKey: order.removeFirst()) }
    }
}

public struct LocalNotificationPresentation: Hashable, Sendable {
    public let title: String
    public let body: String
    public let categoryIdentifier: String
    public let threadIdentifier: String
}

public enum LocalNotificationPresentationMapper {
    public static func map(_ hint: NotificationHint) -> LocalNotificationPresentation {
        let body = hint.category == .decisionRequired || hint.actionIntent.requiresForegroundAuthenticatedRefresh ? "Open OpenPaw to review" : "Open OpenPaw"
        return LocalNotificationPresentation(title: hint.title.value, body: body, categoryIdentifier: "openpaw.\(hint.category.rawValue)", threadIdentifier: "host:\(hint.hostID)/session:\(hint.sessionID)/inbox:\(hint.inboxID)")
    }
}

public enum RoutedNotificationAction: Hashable, Sendable {
    case openInbox
    case openDetail(inboxID: String, requiresAuthenticatedRefresh: Bool)
}

public enum ActionRouter {
    public static func route(_ intent: NotificationActionIntent) -> RoutedNotificationAction {
        switch intent {
        case .openInbox: return .openInbox
        case .openDetail(let inboxID): return .openDetail(inboxID: inboxID, requiresAuthenticatedRefresh: false)
        case .decisionReview(let inboxID, _): return .openDetail(inboxID: inboxID, requiresAuthenticatedRefresh: true)
        }
    }
    public static func directAuthorizationIntent(for intent: NotificationActionIntent) -> Never? { nil }
}
