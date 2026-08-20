import Foundation

// MARK: - Inbox vocabulary

public enum InboxCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case permission
    case question
    case plan
    case toolFailure = "tool_failure"
    case completion
    case contextWarning = "context_warning"
    case rateLimit = "rate_limit"
    case backgroundJob = "background_job"
}

public enum InboxStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case pending
    case resolved
    case dismissed
    case expired
}

/// Whether a client may render a single tap approval, or must first expand the full
/// detail. `.requiresDetailExpansion` carries the specific triggers so the UI can name
/// them instead of showing a generic warning.
public enum ApprovalGate: Sendable, Hashable {
    case oneTap
    case requiresDetailExpansion(reasons: [String])

    public var isOneTap: Bool {
        if case .oneTap = self { return true }
        return false
    }

    public var reasons: [String] {
        if case .requiresDetailExpansion(let reasons) = self { return reasons }
        return []
    }
}

// MARK: - Inbox item

public struct InboxItem: Codable, Sendable, Hashable, Identifiable {
    public let id: InboxID
    public let sessionID: SessionID
    public let agent: AgentKind
    public let category: InboxCategory
    public let title: String
    public let detail: String?
    public let command: String?
    public let risk: Risk?
    public let actions: [ActionID]
    /// Underlying `permission.requested` / `question.requested` request id, used to
    /// correlate a later `permission.resolved` back to this item.
    public let requestID: String?
    /// One-time bearer required by `POST /v1/inbox/{id}/resolve`. Never present in a
    /// push payload; only fetched over the authenticated tunnel.
    public var actionToken: String?
    public let createdAt: Date
    public let expiresAt: Date?
    public var status: InboxStatus
    public var resolution: String?
    public let sourceEventID: EventID

    public init(
        id: InboxID,
        sessionID: SessionID,
        agent: AgentKind,
        category: InboxCategory,
        title: String,
        detail: String? = nil,
        command: String? = nil,
        risk: Risk? = nil,
        actions: [ActionID],
        requestID: String? = nil,
        actionToken: String? = nil,
        createdAt: Date,
        expiresAt: Date? = nil,
        status: InboxStatus,
        resolution: String? = nil,
        sourceEventID: EventID
    ) {
        self.id = id
        self.sessionID = sessionID
        self.agent = agent
        self.category = category
        self.title = title
        self.detail = detail
        self.command = command
        self.risk = risk
        self.actions = actions
        self.requestID = requestID
        self.actionToken = actionToken
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.status = status
        self.resolution = resolution
        self.sourceEventID = sourceEventID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case agent
        case category
        case title
        case detail
        case command
        case risk
        case actions
        case requestID = "request_id"
        case actionToken = "action_token"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case status
        case resolution
        case sourceEventID = "source_event_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(InboxID.self, forKey: .id)
        sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        agent = try container.decode(AgentKind.self, forKey: .agent)
        category = try container.decode(InboxCategory.self, forKey: .category)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        risk = try container.decodeIfPresent(Risk.self, forKey: .risk)
        actions = try container.decodeIfPresent([ActionID].self, forKey: .actions) ?? []
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        actionToken = try container.decodeIfPresent(String.self, forKey: .actionToken)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        status = try container.decode(InboxStatus.self, forKey: .status)
        resolution = try container.decodeIfPresent(String.self, forKey: .resolution)
        sourceEventID = try container.decode(EventID.self, forKey: .sourceEventID)
    }

    /// Gate a client MUST honour before offering an approval action.
    public var approvalGate: ApprovalGate {
        guard let risk, risk.requiresDetailExpansion else { return .oneTap }
        return .requiresDetailExpansion(reasons: risk.reasons)
    }

    /// True once `expiresAt` has passed relative to `now`.
    public func hasExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }
}

// MARK: - Projection

/// Projects normalized events into actionable inbox items. Mirrors the host's
/// `InboxItem::from_event` so an offline client derives the same list from a replayed
/// event stream that the host would have served.
public struct InboxProjection: Sendable {
    /// Threshold above which a context update becomes a warning the user must see.
    public static let contextWarningPercent = 85.0
    /// Threshold above which a usage update becomes a rate limit warning.
    public static let rateLimitWarningPercent = 90.0

    public init() {}

    /// Returns `nil` for events that carry no decision or notification.
    public static func from(event: Event) -> InboxItem? {
        let id = InboxID(event: event.eventID)

        func item(
            category: InboxCategory,
            title: String,
            detail: String? = nil,
            command: String? = nil,
            risk: Risk? = nil,
            actions: [ActionID],
            requestID: String? = nil,
            expiresAt: Date? = nil
        ) -> InboxItem {
            InboxItem(
                id: id,
                sessionID: event.sessionID,
                agent: event.agent,
                category: category,
                title: title,
                detail: detail,
                command: command,
                risk: risk,
                actions: actions,
                requestID: requestID,
                actionToken: nil,
                createdAt: event.timestamp,
                expiresAt: expiresAt,
                status: .pending,
                resolution: nil,
                sourceEventID: event.eventID
            )
        }

        switch event.body {
        case .permissionRequested(let payload):
            return item(
                category: .permission,
                title: payload.summary,
                detail: payload.command ?? payload.summary,
                command: payload.command,
                risk: payload.risk,
                actions: payload.actions,
                requestID: payload.requestID,
                expiresAt: payload.expiresAt
            )

        case .questionRequested(let payload):
            return item(
                category: .question,
                title: payload.question,
                detail: payload.choices.isEmpty ? nil : payload.choices.joined(separator: ", "),
                actions: [.answer],
                requestID: payload.requestID
            )

        case .planCreated(let payload), .planUpdated(let payload):
            let base = payload.title ?? "Plan"
            let title = "\(base) (\(payload.completedCount)/\(payload.steps.count) steps complete)"
            let detail =
                payload.steps.isEmpty
                ? nil
                : payload.steps.map { "\($0.status.marker) \($0.title)" }.joined(separator: "\n")
            return item(category: .plan, title: title, detail: detail, actions: [.acknowledge])

        case .toolFailed(let payload):
            return item(
                category: .toolFailure,
                title: "Tool call \(payload.callID) failed",
                detail: payload.error,
                actions: [.acknowledge]
            )

        case .agentCompleted(let payload):
            return item(
                category: .completion,
                title: payload.title ?? "Agent completed",
                detail: payload.reason,
                actions: [.acknowledge]
            )

        case .agentFailed(let payload):
            return item(
                category: .toolFailure,
                title: payload.title ?? "Agent failed",
                detail: payload.reason,
                actions: [.acknowledge]
            )

        case .contextUpdated(let payload):
            guard payload.percentUsed >= contextWarningPercent else { return nil }
            return item(
                category: .contextWarning,
                title: "Context window \(rounded(payload.percentUsed))% used",
                detail: "\(payload.usedTokens) of \(payload.maxTokens) tokens used",
                actions: [.acknowledge]
            )

        case .usageUpdated(let payload):
            guard let percent = payload.rateLimitPercent, percent >= rateLimitWarningPercent else {
                return nil
            }
            return item(
                category: .rateLimit,
                title: "Rate limit \(rounded(percent))% consumed",
                detail: payload.rateLimitResetsAt.map { "resets at \(RFC3339.string(from: $0))" },
                actions: [.acknowledge]
            )

        case .agentStarted, .agentWorking, .turnStarted, .turnDelta, .turnCompleted,
            .toolStarted, .toolOutput, .toolCompleted, .permissionResolved, .questionAnswered,
            .fileRead, .fileCreated, .fileModified, .fileDeleted, .unsupported:
            return nil
        }
    }

    /// Half away from zero rounding, matching Rust's `f64::round`.
    private static func rounded(_ value: Double) -> Int64 {
        Int64(value.rounded(.toNearestOrAwayFromZero))
    }
}
