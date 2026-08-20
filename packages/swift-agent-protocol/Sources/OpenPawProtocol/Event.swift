import Foundation

// MARK: - Body

/// The `type`/`payload` pair of a normalized event, decoded into a typed case.
///
/// A `type` this build does not know decodes into `.unsupported`, which re-encodes
/// byte-for-byte. Forward compatibility is a protocol requirement: a phone running an
/// older build must not drop or corrupt events emitted by a newer host.
public enum Body: Sendable, Hashable {
    case agentStarted(AgentLifecycle)
    case agentWorking(AgentLifecycle)
    case agentCompleted(AgentLifecycle)
    case agentFailed(AgentLifecycle)
    case turnStarted(TurnStarted)
    case turnDelta(TurnDelta)
    case turnCompleted(TurnCompleted)
    case toolStarted(ToolStarted)
    case toolOutput(ToolOutput)
    case toolCompleted(ToolCompleted)
    case toolFailed(ToolFailed)
    case permissionRequested(PermissionRequested)
    case permissionResolved(PermissionResolved)
    case questionRequested(QuestionRequested)
    case questionAnswered(QuestionAnswered)
    case planCreated(Plan)
    case planUpdated(Plan)
    case fileRead(FileChange)
    case fileCreated(FileChange)
    case fileModified(FileChange)
    case fileDeleted(FileChange)
    case usageUpdated(UsageUpdated)
    case contextUpdated(ContextUpdated)
    case unsupported(type: String, payload: JSONValue)

    /// The known event type, or `nil` for `.unsupported`.
    public var kind: EventType? {
        switch self {
        case .agentStarted: .agentStarted
        case .agentWorking: .agentWorking
        case .agentCompleted: .agentCompleted
        case .agentFailed: .agentFailed
        case .turnStarted: .turnStarted
        case .turnDelta: .turnDelta
        case .turnCompleted: .turnCompleted
        case .toolStarted: .toolStarted
        case .toolOutput: .toolOutput
        case .toolCompleted: .toolCompleted
        case .toolFailed: .toolFailed
        case .permissionRequested: .permissionRequested
        case .permissionResolved: .permissionResolved
        case .questionRequested: .questionRequested
        case .questionAnswered: .questionAnswered
        case .planCreated: .planCreated
        case .planUpdated: .planUpdated
        case .fileRead: .fileRead
        case .fileCreated: .fileCreated
        case .fileModified: .fileModified
        case .fileDeleted: .fileDeleted
        case .usageUpdated: .usageUpdated
        case .contextUpdated: .contextUpdated
        case .unsupported: nil
        }
    }

    /// The wire value of `type`, defined for every case including `.unsupported`.
    public var typeName: String {
        if case .unsupported(let type, _) = self { return type }
        // `kind` is non-nil for every case except `.unsupported`.
        return kind!.rawValue
    }
}

// MARK: - Event

public struct Event: Codable, Sendable, Hashable, Identifiable {
    public var version: String
    public var eventID: EventID
    public var sessionID: SessionID
    public var agent: AgentKind
    public var seq: UInt64
    public var timestamp: Date
    public var cwd: String?
    public var gitBranch: String?
    public var multiplexerTarget: String?
    public var body: Body

    public var id: EventID { eventID }

    /// The known event type, or `nil` when the host emitted a type this build predates.
    public var kind: EventType? { body.kind }

    public init(
        version: String = OpenPawCoding.version,
        eventID: EventID,
        sessionID: SessionID,
        agent: AgentKind,
        seq: UInt64 = 0,
        timestamp: Date,
        cwd: String? = nil,
        gitBranch: String? = nil,
        multiplexerTarget: String? = nil,
        body: Body
    ) {
        self.version = version
        self.eventID = eventID
        self.sessionID = sessionID
        self.agent = agent
        self.seq = seq
        self.timestamp = timestamp
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.multiplexerTarget = multiplexerTarget
        self.body = body
    }

    /// Builds an event with the same content addressed identifier the host derives.
    public init(
        session: SessionID,
        agent: AgentKind,
        sourceKey: String,
        timestamp: Date,
        body: Body
    ) {
        self.init(
            eventID: EventID(session: session, sourceKey: sourceKey),
            sessionID: session,
            agent: agent,
            seq: 0,
            timestamp: timestamp,
            body: body
        )
    }

    public func withSeq(_ seq: UInt64) -> Event {
        var copy = self
        copy.seq = seq
        return copy
    }

    public func withContext(cwd: String?, gitBranch: String?) -> Event {
        var copy = self
        copy.cwd = cwd
        copy.gitBranch = gitBranch
        return copy
    }

    // MARK: Coding

    enum CodingKeys: String, CodingKey {
        case version
        case eventID = "event_id"
        case sessionID = "session_id"
        case agent
        case seq
        case timestamp
        case cwd
        case gitBranch = "git_branch"
        case multiplexerTarget = "multiplexer_target"
        case type
        case payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        eventID = try container.decode(EventID.self, forKey: .eventID)
        sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        agent = try container.decode(AgentKind.self, forKey: .agent)
        seq = try container.decode(UInt64.self, forKey: .seq)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        gitBranch = try container.decodeIfPresent(String.self, forKey: .gitBranch)
        multiplexerTarget = try container.decodeIfPresent(String.self, forKey: .multiplexerTarget)

        let type = try container.decode(String.self, forKey: .type)
        func payload<T: Decodable>(_ type: T.Type) throws -> T {
            try container.decode(T.self, forKey: .payload)
        }
        switch EventType(rawValue: type) {
        case .agentStarted: body = .agentStarted(try payload(AgentLifecycle.self))
        case .agentWorking: body = .agentWorking(try payload(AgentLifecycle.self))
        case .agentCompleted: body = .agentCompleted(try payload(AgentLifecycle.self))
        case .agentFailed: body = .agentFailed(try payload(AgentLifecycle.self))
        case .turnStarted: body = .turnStarted(try payload(TurnStarted.self))
        case .turnDelta: body = .turnDelta(try payload(TurnDelta.self))
        case .turnCompleted: body = .turnCompleted(try payload(TurnCompleted.self))
        case .toolStarted: body = .toolStarted(try payload(ToolStarted.self))
        case .toolOutput: body = .toolOutput(try payload(ToolOutput.self))
        case .toolCompleted: body = .toolCompleted(try payload(ToolCompleted.self))
        case .toolFailed: body = .toolFailed(try payload(ToolFailed.self))
        case .permissionRequested: body = .permissionRequested(try payload(PermissionRequested.self))
        case .permissionResolved: body = .permissionResolved(try payload(PermissionResolved.self))
        case .questionRequested: body = .questionRequested(try payload(QuestionRequested.self))
        case .questionAnswered: body = .questionAnswered(try payload(QuestionAnswered.self))
        case .planCreated: body = .planCreated(try payload(Plan.self))
        case .planUpdated: body = .planUpdated(try payload(Plan.self))
        case .fileRead: body = .fileRead(try payload(FileChange.self))
        case .fileCreated: body = .fileCreated(try payload(FileChange.self))
        case .fileModified: body = .fileModified(try payload(FileChange.self))
        case .fileDeleted: body = .fileDeleted(try payload(FileChange.self))
        case .usageUpdated: body = .usageUpdated(try payload(UsageUpdated.self))
        case .contextUpdated: body = .contextUpdated(try payload(ContextUpdated.self))
        case nil:
            let raw = try container.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .object([:])
            body = .unsupported(type: type, payload: raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Key order matches the host: envelope, then type, then payload. The three
        // context keys are always present, encoded as null when absent.
        try container.encode(version, forKey: .version)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(agent, forKey: .agent)
        try container.encode(seq, forKey: .seq)
        try container.encode(timestamp, forKey: .timestamp)
        try encodeNullable(cwd, forKey: .cwd, into: &container)
        try encodeNullable(gitBranch, forKey: .gitBranch, into: &container)
        try encodeNullable(multiplexerTarget, forKey: .multiplexerTarget, into: &container)
        try container.encode(body.typeName, forKey: .type)

        switch body {
        case .agentStarted(let value), .agentWorking(let value), .agentCompleted(let value),
            .agentFailed(let value):
            try container.encode(value, forKey: .payload)
        case .turnStarted(let value): try container.encode(value, forKey: .payload)
        case .turnDelta(let value): try container.encode(value, forKey: .payload)
        case .turnCompleted(let value): try container.encode(value, forKey: .payload)
        case .toolStarted(let value): try container.encode(value, forKey: .payload)
        case .toolOutput(let value): try container.encode(value, forKey: .payload)
        case .toolCompleted(let value): try container.encode(value, forKey: .payload)
        case .toolFailed(let value): try container.encode(value, forKey: .payload)
        case .permissionRequested(let value): try container.encode(value, forKey: .payload)
        case .permissionResolved(let value): try container.encode(value, forKey: .payload)
        case .questionRequested(let value): try container.encode(value, forKey: .payload)
        case .questionAnswered(let value): try container.encode(value, forKey: .payload)
        case .planCreated(let value), .planUpdated(let value):
            try container.encode(value, forKey: .payload)
        case .fileRead(let value), .fileCreated(let value), .fileModified(let value),
            .fileDeleted(let value):
            try container.encode(value, forKey: .payload)
        case .usageUpdated(let value): try container.encode(value, forKey: .payload)
        case .contextUpdated(let value): try container.encode(value, forKey: .payload)
        case .unsupported(_, let payload): try container.encode(payload, forKey: .payload)
        }
    }

    private func encodeNullable(
        _ value: String?,
        forKey key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}
