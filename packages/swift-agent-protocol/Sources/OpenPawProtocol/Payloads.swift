import Foundation

// MARK: - agent.*

public struct AgentLifecycle: Codable, Sendable, Hashable {
    public var reason: String?
    public var exitCode: Int32?
    public var title: String?

    public init(reason: String? = nil, exitCode: Int32? = nil, title: String? = nil) {
        self.reason = reason
        self.exitCode = exitCode
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case reason
        case exitCode = "exit_code"
        case title
    }
}

// MARK: - turn.*

public struct TurnStarted: Codable, Sendable, Hashable {
    public var turnID: String
    public var role: TurnRole
    public var text: String?

    public init(turnID: String, role: TurnRole, text: String? = nil) {
        self.turnID = turnID
        self.role = role
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case role
        case text
    }
}

public struct TurnDelta: Codable, Sendable, Hashable {
    public var turnID: String
    public var delta: String
    public var kind: DeltaKind

    public init(turnID: String, delta: String, kind: DeltaKind) {
        self.turnID = turnID
        self.delta = delta
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case delta
        case kind
    }
}

public struct TurnCompleted: Codable, Sendable, Hashable {
    public var turnID: String
    public var role: TurnRole
    public var text: String
    public var thinking: String?

    public init(turnID: String, role: TurnRole, text: String, thinking: String? = nil) {
        self.turnID = turnID
        self.role = role
        self.text = text
        self.thinking = thinking
    }

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case role
        case text
        case thinking
    }
}

// MARK: - tool.*

public struct ToolStarted: Codable, Sendable, Hashable {
    public var callID: String
    public var tool: String
    public var summary: String?
    public var command: String?
    public var paths: [String]
    public var risk: Risk

    public init(
        callID: String,
        tool: String,
        summary: String? = nil,
        command: String? = nil,
        paths: [String] = [],
        risk: Risk = .unknown
    ) {
        self.callID = callID
        self.tool = tool
        self.summary = summary
        self.command = command
        self.paths = paths
        self.risk = risk
    }

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case tool
        case summary
        case command
        case paths
        case risk
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callID = try container.decode(String.self, forKey: .callID)
        tool = try container.decode(String.self, forKey: .tool)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
        risk = try container.decodeIfPresent(Risk.self, forKey: .risk) ?? .unknown
    }
}

public struct ToolOutput: Codable, Sendable, Hashable {
    public var callID: String
    public var chunk: String
    public var stream: StdStream
    public var truncated: Bool

    public init(callID: String, chunk: String, stream: StdStream, truncated: Bool) {
        self.callID = callID
        self.chunk = chunk
        self.stream = stream
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case chunk
        case stream
        case truncated
    }
}

public struct ToolCompleted: Codable, Sendable, Hashable {
    public var callID: String
    public var exitCode: Int32?
    public var durationMs: UInt64?
    public var summary: String?

    public init(
        callID: String, exitCode: Int32? = nil, durationMs: UInt64? = nil, summary: String? = nil
    ) {
        self.callID = callID
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case exitCode = "exit_code"
        case durationMs = "duration_ms"
        case summary
    }
}

public struct ToolFailed: Codable, Sendable, Hashable {
    public var callID: String
    public var error: String
    public var exitCode: Int32?

    public init(callID: String, error: String, exitCode: Int32? = nil) {
        self.callID = callID
        self.error = error
        self.exitCode = exitCode
    }

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case error
        case exitCode = "exit_code"
    }
}

// MARK: - permission.*

public struct PermissionRequested: Codable, Sendable, Hashable {
    public var requestID: String
    public var tool: String
    public var summary: String
    public var command: String?
    public var paths: [String]
    public var risk: Risk
    public var actions: [ActionID]
    public var expiresAt: Date?

    public init(
        requestID: String,
        tool: String,
        summary: String,
        command: String? = nil,
        paths: [String] = [],
        risk: Risk,
        actions: [ActionID],
        expiresAt: Date? = nil
    ) {
        self.requestID = requestID
        self.tool = tool
        self.summary = summary
        self.command = command
        self.paths = paths
        self.risk = risk
        self.actions = actions
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case tool
        case summary
        case command
        case paths
        case risk
        case actions
        case expiresAt = "expires_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(String.self, forKey: .requestID)
        tool = try container.decode(String.self, forKey: .tool)
        summary = try container.decode(String.self, forKey: .summary)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
        risk = try container.decode(Risk.self, forKey: .risk)
        actions = try container.decode([ActionID].self, forKey: .actions)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
    }
}

public struct PermissionResolved: Codable, Sendable, Hashable {
    public var requestID: String
    public var decision: ActionID
    public var decidedBy: DecidedBy
    public var deviceID: String?

    public init(
        requestID: String, decision: ActionID, decidedBy: DecidedBy, deviceID: String? = nil
    ) {
        self.requestID = requestID
        self.decision = decision
        self.decidedBy = decidedBy
        self.deviceID = deviceID
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case decision
        case decidedBy = "decided_by"
        case deviceID = "device_id"
    }
}

// MARK: - question.*

public struct QuestionRequested: Codable, Sendable, Hashable {
    public var requestID: String
    public var question: String
    public var choices: [String]
    public var allowsFreeText: Bool

    public init(
        requestID: String, question: String, choices: [String] = [], allowsFreeText: Bool
    ) {
        self.requestID = requestID
        self.question = question
        self.choices = choices
        self.allowsFreeText = allowsFreeText
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case question
        case choices
        case allowsFreeText = "allows_free_text"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(String.self, forKey: .requestID)
        question = try container.decode(String.self, forKey: .question)
        choices = try container.decodeIfPresent([String].self, forKey: .choices) ?? []
        allowsFreeText = try container.decode(Bool.self, forKey: .allowsFreeText)
    }
}

public struct QuestionAnswered: Codable, Sendable, Hashable {
    public var requestID: String
    public var answer: String

    public init(requestID: String, answer: String) {
        self.requestID = requestID
        self.answer = answer
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case answer
    }
}

// MARK: - plan.*

public struct PlanStep: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var status: PlanStepStatus

    public init(id: String, title: String, status: PlanStepStatus) {
        self.id = id
        self.title = title
        self.status = status
    }
}

public struct Plan: Codable, Sendable, Hashable {
    public var planID: String
    public var title: String?
    public var steps: [PlanStep]

    public init(planID: String, title: String? = nil, steps: [PlanStep] = []) {
        self.planID = planID
        self.title = title
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey {
        case planID = "plan_id"
        case title
        case steps
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planID = try container.decode(String.self, forKey: .planID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        steps = try container.decodeIfPresent([PlanStep].self, forKey: .steps) ?? []
    }

    /// Number of steps in the `completed` state.
    public var completedCount: Int {
        steps.filter { $0.status == .completed }.count
    }
}

// MARK: - file.*

public struct FileChange: Codable, Sendable, Hashable {
    public var path: String
    public var additions: UInt32?
    public var deletions: UInt32?
    public var bytes: UInt64?
    public var unifiedDiff: String?

    public init(
        path: String,
        additions: UInt32? = nil,
        deletions: UInt32? = nil,
        bytes: UInt64? = nil,
        unifiedDiff: String? = nil
    ) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.bytes = bytes
        self.unifiedDiff = unifiedDiff
    }

    enum CodingKeys: String, CodingKey {
        case path
        case additions
        case deletions
        case bytes
        case unifiedDiff = "unified_diff"
    }
}

// MARK: - usage.updated / context.updated

public struct UsageUpdated: Codable, Sendable, Hashable {
    public var inputTokens: UInt64
    public var outputTokens: UInt64
    public var cachedInputTokens: UInt64?
    public var costUSD: Double?
    public var rateLimitPercent: Double?
    public var rateLimitResetsAt: Date?

    public init(
        inputTokens: UInt64,
        outputTokens: UInt64,
        cachedInputTokens: UInt64? = nil,
        costUSD: Double? = nil,
        rateLimitPercent: Double? = nil,
        rateLimitResetsAt: Date? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.costUSD = costUSD
        self.rateLimitPercent = rateLimitPercent
        self.rateLimitResetsAt = rateLimitResetsAt
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case costUSD = "cost_usd"
        case rateLimitPercent = "rate_limit_percent"
        case rateLimitResetsAt = "rate_limit_resets_at"
    }
}

public struct ContextUpdated: Codable, Sendable, Hashable {
    public var usedTokens: UInt64
    public var maxTokens: UInt64
    public var percentUsed: Double

    public init(usedTokens: UInt64, maxTokens: UInt64, percentUsed: Double) {
        self.usedTokens = usedTokens
        self.maxTokens = maxTokens
        self.percentUsed = percentUsed
    }

    enum CodingKeys: String, CodingKey {
        case usedTokens = "used_tokens"
        case maxTokens = "max_tokens"
        case percentUsed = "percent_used"
    }
}
