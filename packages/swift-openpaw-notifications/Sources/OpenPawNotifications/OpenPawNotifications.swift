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
    case invalidIdentifier
    case invalidGateConfiguration
    case invalidTitleConfiguration
    case replayStorePressure
}

public struct SafeNotificationTitle: Hashable, Codable, Sendable {
    public static let defaultMaxUTF8Bytes = 96
    public static let defaultMaxScalars = 64
    private static let fallback = "OpenPaw notification"
    public let value: String

    public init(_ raw: String, maxUTF8Bytes: Int = Self.defaultMaxUTF8Bytes, maxScalars: Int = Self.defaultMaxScalars) throws {
        guard maxUTF8Bytes > 0, maxScalars > 0 else { throw NotificationPayloadError.invalidTitleConfiguration }
        var sanitized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let usingFallback = Self.looksUnsafe(raw) || Self.looksUnsafe(sanitized) || sanitized.isEmpty
        if usingFallback { sanitized = Self.fallback }
        guard !usingFallback || Self.fits(Self.fallback, maxUTF8Bytes: maxUTF8Bytes, maxScalars: maxScalars) else { throw NotificationPayloadError.invalidTitleConfiguration }
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var scalarCount = 0
        for character in sanitized {
            let candidate = result + String(character)
            if scalarCount + String(character).unicodeScalars.count > maxScalars || candidate.utf8.count > maxUTF8Bytes { break }
            scalarCount += String(character).unicodeScalars.count
            result = candidate
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            guard Self.fits(Self.fallback, maxUTF8Bytes: maxUTF8Bytes, maxScalars: maxScalars) else { throw NotificationPayloadError.invalidTitleConfiguration }
            self.value = Self.fallback
            return
        }
        self.value = trimmed
    }

    private static func fits(_ value: String, maxUTF8Bytes: Int, maxScalars: Int) -> Bool {
        value.utf8.count <= maxUTF8Bytes && value.unicodeScalars.count <= maxScalars
    }

    private enum CodingKeys: String, CodingKey { case value }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            try self.init(raw)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(c.decode(String.self, forKey: .value))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value)
    }

    private static func looksUnsafe(_ raw: String) -> Bool {
        let patterns = [
            #"(?i)(action[_-]?token|command|credentials|raw[_-]?detail|secret|token|password|credential)"#,
            #"(?i)(ssh|https?)://\S+"#,
            #"(?i)(^|\s)(/[\w. -]+){2,}"#,
            #"(?i)\b[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\b"#,
            #"(?i)\b[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)+\b"#,
            #"(?i)\bgit@[^\s:]+:[^\s]+\b"#,
            #"(?i)\b[\w.-]+/[\w.-]+\.git\b"#
        ]
        return patterns.contains { raw.range(of: $0, options: .regularExpression) != nil }
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
        try NotificationOpaqueIDValidator.validateEnvelope(id: id, hostID: hostID, deviceID: deviceID, sessionID: sessionID, inboxID: inboxID, nonce: nonce, actionIntent: actionIntent)
        self.schemaVersion = Self.schemaVersion
        self.id = id; self.hostID = hostID; self.deviceID = deviceID; self.sessionID = sessionID; self.inboxID = inboxID
        self.category = category; self.risk = risk; self.createdAt = createdAt; self.expiresAt = expiresAt; self.nonce = nonce
        self.title = try SafeNotificationTitle(title)
        self.actionIntent = actionIntent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(c.allKeys.map(\.stringValue)) == Self.allowedKeys else { throw NotificationPayloadError.malformed }
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else { throw NotificationPayloadError.invalidSchemaVersion }
        let titleString = try c.decode(String.self, forKey: .title)
        try self.init(id: c.decode(String.self, forKey: .id), hostID: c.decode(String.self, forKey: .hostID), deviceID: c.decode(String.self, forKey: .deviceID), sessionID: c.decode(String.self, forKey: .sessionID), inboxID: c.decode(String.self, forKey: .inboxID), category: c.decode(NotificationCategory.self, forKey: .category), risk: c.decode(NotificationRisk.self, forKey: .risk), createdAt: c.decode(Int64.self, forKey: .createdAt), expiresAt: c.decode(Int64.self, forKey: .expiresAt), nonce: c.decode(String.self, forKey: .nonce), title: titleString, actionIntent: c.decode(NotificationActionIntent.self, forKey: .actionIntent))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(id, forKey: .id); try c.encode(hostID, forKey: .hostID); try c.encode(deviceID, forKey: .deviceID); try c.encode(sessionID, forKey: .sessionID); try c.encode(inboxID, forKey: .inboxID); try c.encode(category, forKey: .category); try c.encode(risk, forKey: .risk); try c.encode(createdAt, forKey: .createdAt); try c.encode(expiresAt, forKey: .expiresAt); try c.encode(nonce, forKey: .nonce); try c.encode(title.value, forKey: .title); try c.encode(actionIntent, forKey: .actionIntent)
    }

    private static let allowedKeys: Set<String> = ["schema_version", "id", "host_id", "device_id", "session_id", "inbox_id", "category", "risk", "created_at", "expires_at", "nonce", "title", "action_intent"]
}

private enum NotificationOpaqueIDValidator {
    static func validateEnvelope(id: String, hostID: String, deviceID: String, sessionID: String, inboxID: String, nonce: String, actionIntent: NotificationActionIntent) throws {
        for value in [id, hostID, deviceID, sessionID, inboxID, nonce] { try validate(value) }
        switch actionIntent {
        case .openInbox:
            break
        case .openDetail(let actionInboxID):
            try validate(actionInboxID)
            guard actionInboxID == inboxID else { throw NotificationPayloadError.invalidIdentifier }
        case .decisionReview(let actionInboxID, let decisionID):
            try validate(actionInboxID)
            try validate(decisionID)
            guard actionInboxID == inboxID else { throw NotificationPayloadError.invalidIdentifier }
        }
    }

    static func validate(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 128, id.range(of: #"^[A-Za-z0-9._:|-]+$"#, options: .regularExpression) != nil else { throw NotificationPayloadError.invalidIdentifier }
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
    public static let forbiddenFields: Set<String> = ["action_token", "command", "credentials", "raw_detail", "secret", "actiontoken", "auth", "token", "password", "credential"]
    public static func decode(_ data: Data, now: Int64, gate: inout NotificationReplayExpiryGate) throws -> NotificationHint {
        try gate.validateConfiguration()
        guard data.count <= gate.maxPayloadBytes else { throw NotificationPayloadError.oversized }
        try validateSchema(data)
        let hint = try JSONDecoder().decode(NotificationHint.self, from: data)
        try gate.accept(hint, payloadByteCount: data.count, now: now)
        return hint
    }
    @available(*, unavailable, message: "Use decode(_:now:gate:) so payload size, replay, expiry, and age checks cannot be bypassed.")
    public static func decode(_ data: Data, now: Int64) throws -> NotificationHint {
        throw NotificationPayloadError.malformed
    }

    private static func validateSchema(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NotificationPayloadError.malformed }
        try validateObject(object, allowed: ["schema_version", "id", "host_id", "device_id", "session_id", "inbox_id", "category", "risk", "created_at", "expires_at", "nonce", "title", "action_intent"])
        guard let action = object["action_intent"] as? [String: Any], let type = action["type"] as? String else { throw NotificationPayloadError.malformed }
        switch type {
        case "open_inbox": try validateObject(action, allowed: ["type"])
        case "open_detail": try validateObject(action, allowed: ["type", "inbox_id"])
        case "decision_review": try validateObject(action, allowed: ["type", "inbox_id", "decision_id"])
        default: throw NotificationPayloadError.malformed
        }
    }

    private static func validateObject(_ object: [String: Any], allowed: Set<String>) throws {
        for (key, value) in object {
            let normalized = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
            if forbiddenFields.contains(key) || forbiddenFields.contains(normalized) { throw NotificationPayloadError.forbiddenField(key) }
            guard allowed.contains(key) else { throw NotificationPayloadError.malformed }
            if let nested = value as? [String: Any], key != "action_intent" { try validateObject(nested, allowed: []) }
            if let nestedArray = value as? [Any] { try validateArray(nestedArray) }
        }
    }

    private static func validateArray(_ array: [Any]) throws {
        for value in array {
            if let nested = value as? [String: Any] { try validateObject(nested, allowed: []) }
            else if let nestedArray = value as? [Any] { try validateArray(nestedArray) }
        }
    }
}

public struct NotificationReplayExpiryGate: Sendable {
    private typealias ReplayIdentity = [String]
    public let capacity: Int
    public let maxPayloadBytes: Int
    public let maxClockSkewSeconds: Int64
    public let maxAgeSeconds: Int64
    private var seen: [ReplayIdentity: Int64] = [:]
    private var order: [ReplayIdentity] = []

    public init(capacity: Int = 256, maxPayloadBytes: Int = 4096, maxClockSkewSeconds: Int64 = 300, maxAgeSeconds: Int64 = 86_400) {
        self.capacity = capacity; self.maxPayloadBytes = maxPayloadBytes; self.maxClockSkewSeconds = maxClockSkewSeconds; self.maxAgeSeconds = maxAgeSeconds
    }
    public func validateConfiguration() throws {
        guard capacity > 0, maxPayloadBytes > 0, maxClockSkewSeconds >= 0, maxAgeSeconds > 0 else { throw NotificationPayloadError.invalidGateConfiguration }
    }
    public mutating func accept(_ hint: NotificationHint, payloadByteCount: Int, now: Int64) throws {
        try validateConfiguration()
        try validateIdentifiers(hint)
        guard payloadByteCount <= maxPayloadBytes else { throw NotificationPayloadError.oversized }
        let maxExpiry = hint.createdAt.addingReportingOverflow(maxAgeSeconds)
        guard !maxExpiry.overflow, hint.expiresAt <= maxExpiry.partialValue else { throw NotificationPayloadError.invalidTimeRange }
        let futureLimit = now.addingReportingOverflow(maxClockSkewSeconds)
        guard !futureLimit.overflow, hint.createdAt <= futureLimit.partialValue else { throw NotificationPayloadError.futureSkew }
        let staleLimit = now.addingReportingOverflow(-maxAgeSeconds)
        guard staleLimit.overflow || hint.createdAt >= staleLimit.partialValue else { throw NotificationPayloadError.stale }
        guard now < hint.expiresAt else { throw NotificationPayloadError.expired }
        let key = ReplayIdentity([hint.id, hint.nonce])
        guard seen[key] == nil else { throw NotificationPayloadError.duplicate }
        pruneExpired(now: now)
        guard seen.count < capacity else { throw NotificationPayloadError.replayStorePressure }
        seen[key] = hint.expiresAt; order.append(key)
    }

    private mutating func pruneExpired(now: Int64) {
        order.removeAll { key in
            guard let expiresAt = seen[key] else { return true }
            if now >= expiresAt { seen.removeValue(forKey: key); return true }
            return false
        }
    }

    private func validateIdentifiers(_ hint: NotificationHint) throws {
        try NotificationOpaqueIDValidator.validateEnvelope(id: hint.id, hostID: hint.hostID, deviceID: hint.deviceID, sessionID: hint.sessionID, inboxID: hint.inboxID, nonce: hint.nonce, actionIntent: hint.actionIntent)
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
        return LocalNotificationPresentation(title: hint.title.value, body: body, categoryIdentifier: "openpaw.\(hint.category.rawValue)", threadIdentifier: [hint.hostID, hint.sessionID, hint.inboxID].map(lengthPrefixed).joined(separator: "|"))
    }

    private static func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
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
