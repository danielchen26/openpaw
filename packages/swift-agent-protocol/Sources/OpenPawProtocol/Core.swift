import CryptoKit
import Foundation

// MARK: - Identifiers

/// `sess_<agent short code>-<sanitized raw id>`.
public struct SessionID: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// Wraps an already-formed identifier without validation. Used when decoding
    /// values produced by the host.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Derives the identifier the host would derive for the same agent and raw id:
    /// every character outside `[A-Za-z0-9._:-]` collapses to `-`.
    public init(agent: AgentKind, raw: String) {
        var sanitized = ""
        sanitized.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", ":", "-":
                sanitized.unicodeScalars.append(scalar)
            default:
                sanitized.append("-")
            }
        }
        self.rawValue = "sess_\(agent.short)-\(sanitized)"
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// `evt_` plus the first 24 hex characters of `sha256(session_id 0x1F source_key)`.
public struct EventID: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(session: SessionID, sourceKey: String) {
        var input = Data(session.rawValue.utf8)
        input.append(0x1F)
        input.append(contentsOf: sourceKey.utf8)
        rawValue = "evt_" + Hashing.sha256Hex(input).prefix(24)
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// `inb_` plus the first 24 hex characters of `sha256(event_id)`.
public struct InboxID: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(event: EventID) {
        rawValue = "inb_" + Hashing.sha256Hex(Data(event.rawValue.utf8)).prefix(24)
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Hashing

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    public static func hex(_ bytes: some Sequence<UInt8>) -> String {
        let table: [Character] = [
            "0", "1", "2", "3", "4", "5", "6", "7",
            "8", "9", "a", "b", "c", "d", "e", "f",
        ]
        var out = ""
        for byte in bytes {
            out.append(table[Int(byte >> 4)])
            out.append(table[Int(byte & 0x0F)])
        }
        return out
    }
}

// MARK: - Agent kind

public enum AgentKind: String, Codable, Sendable, Hashable, CaseIterable {
    case claudeCode = "claude-code"
    case codex
    case openCode = "opencode"
    case geminiCLI = "gemini-cli"
    case cursorCLI = "cursor-cli"
    case kimiCLI = "kimi-cli"
    case qwenCode = "qwen-code"
    case generic

    /// Two letter code embedded in `SessionID`.
    public var short: String {
        switch self {
        case .claudeCode: "cc"
        case .codex: "cx"
        case .openCode: "oc"
        case .geminiCLI: "gm"
        case .cursorCLI: "cu"
        case .kimiCLI: "km"
        case .qwenCode: "qw"
        case .generic: "gn"
        }
    }

    /// Name suitable for a UI label.
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .openCode: "OpenCode"
        case .geminiCLI: "Gemini CLI"
        case .cursorCLI: "Cursor CLI"
        case .kimiCLI: "Kimi CLI"
        case .qwenCode: "Qwen Code"
        case .generic: "Agent"
        }
    }
}

// MARK: - Event type

public enum EventType: String, Codable, Sendable, Hashable, CaseIterable {
    case agentStarted = "agent.started"
    case agentWorking = "agent.working"
    case agentCompleted = "agent.completed"
    case agentFailed = "agent.failed"
    case turnStarted = "turn.started"
    case turnDelta = "turn.delta"
    case turnCompleted = "turn.completed"
    case toolStarted = "tool.started"
    case toolOutput = "tool.output"
    case toolCompleted = "tool.completed"
    case toolFailed = "tool.failed"
    case permissionRequested = "permission.requested"
    case permissionResolved = "permission.resolved"
    case questionRequested = "question.requested"
    case questionAnswered = "question.answered"
    case planCreated = "plan.created"
    case planUpdated = "plan.updated"
    case fileRead = "file.read"
    case fileCreated = "file.created"
    case fileModified = "file.modified"
    case fileDeleted = "file.deleted"
    case usageUpdated = "usage.updated"
    case contextUpdated = "context.updated"
}

// MARK: - Actions

public enum ActionID: String, Codable, Sendable, Hashable, CaseIterable {
    case approveOnce = "approve_once"
    case approveAlways = "approve_always"
    case deny
    case denyAlways = "deny_always"
    case answer
    case stop
    case acknowledge

    /// True when taking this action lets the agent proceed with the requested work.
    public var isApproval: Bool {
        self == .approveOnce || self == .approveAlways
    }

    public var displayName: String {
        switch self {
        case .approveOnce: "Approve once"
        case .approveAlways: "Always approve"
        case .deny: "Deny"
        case .denyAlways: "Always deny"
        case .answer: "Answer"
        case .stop: "Stop"
        case .acknowledge: "Acknowledge"
        }
    }
}

public enum DecidedBy: String, Codable, Sendable, Hashable, CaseIterable {
    case device
    case terminal
    case policy
    case timeout
}

public enum TurnRole: String, Codable, Sendable, Hashable, CaseIterable {
    case user
    case assistant
}

public enum DeltaKind: String, Codable, Sendable, Hashable, CaseIterable {
    case text
    case thinking
}

public enum StdStream: String, Codable, Sendable, Hashable, CaseIterable {
    case stdout
    case stderr
}

public enum PlanStepStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case completed
    case cancelled

    /// Prefix marker used in rendered plan detail text.
    public var marker: String {
        switch self {
        case .pending: "[ ]"
        case .inProgress: "[~]"
        case .completed: "[x]"
        case .cancelled: "[-]"
        }
    }
}
