import Foundation
import OpenPawProtocol

/// One row in Chat View. Chat View is a *projection* of the agent's own transcript, never a second chat bot and
/// never a scrape of the terminal's ANSI output — so this reducer is the only place events become conversation.
public enum ChatItem: Identifiable, Sendable, Equatable {
    case prose(ProseRow)
    case thinking(ThinkingRow)
    case tool(ToolRow)
    case plan(PlanRow)
    case permission(PermissionRow)
    case question(QuestionRow)
    case fileEdit(FileEditRow)
    case lifecycle(LifecycleRow)

    public var id: String {
        switch self {
        case .prose(let row): "prose:" + row.id
        case .thinking(let row): "think:" + row.id
        case .tool(let row): "tool:" + row.id
        case .plan(let row): "plan:" + row.id
        case .permission(let row): "perm:" + row.id
        case .question(let row): "ques:" + row.id
        case .fileEdit(let row): "file:" + row.id
        case .lifecycle(let row): "life:" + row.id
        }
    }

    /// The event sequence number this row starts at. Chat View shows it in the left spine: it is a real resume
    /// point for `GET /v1/events?after_seq=`, which is why it earns screen space that decoration would not.
    public var seq: UInt64 {
        switch self {
        case .prose(let row): row.seq
        case .thinking(let row): row.seq
        case .tool(let row): row.seq
        case .plan(let row): row.seq
        case .permission(let row): row.seq
        case .question(let row): row.seq
        case .fileEdit(let row): row.seq
        case .lifecycle(let row): row.seq
        }
    }

    public var timestamp: Date {
        switch self {
        case .prose(let row): row.timestamp
        case .thinking(let row): row.timestamp
        case .tool(let row): row.timestamp
        case .plan(let row): row.timestamp
        case .permission(let row): row.timestamp
        case .question(let row): row.timestamp
        case .fileEdit(let row): row.timestamp
        case .lifecycle(let row): row.timestamp
        }
    }
}

public struct ProseRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let seq: UInt64
    public let timestamp: Date
    public let role: TurnRole
    public var text: String
}

public struct ThinkingRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let seq: UInt64
    public let timestamp: Date
    public var text: String
}

public struct ToolRow: Identifiable, Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case running
        case succeeded(exitCode: Int32?, durationMS: UInt64?)
        case failed(error: String, exitCode: Int32?)
    }

    public let id: String
    public let seq: UInt64
    public let timestamp: Date
    public let tool: String
    public var summary: String?
    public var command: String?
    public var paths: [String]
    public var risk: Risk?
    public var status: Status
    /// Accumulated stdout/stderr, byte-capped by the reducer so a `yes`-loop cannot pin the UI.
    public var output: String
    public var outputTruncated: Bool
}

public struct PlanRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let seq: UInt64
    public let timestamp: Date
    public var title: String?
    public var steps: [PlanStep]
}

public struct PermissionRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let seq: UInt64
    public let timestamp: Date
    public let request: PermissionRequested
    /// Filled in when the matching `permission.resolved` arrives, so history reads as a decision, not a question.
    public var decision: ActionID?
    public var decidedBy: DecidedBy?
}

public struct QuestionRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let seq: UInt64
    public let timestamp: Date
    public let question: QuestionRequested
    public var answer: String?
}

public struct FileEditRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let seq: UInt64
    public let timestamp: Date
    public let path: String
    public let change: FileChangeKind
    public var additions: UInt32?
    public var deletions: UInt32?
    /// Present when the agent handed us a patch; renders as the mini diff without a host round trip.
    public var unifiedDiff: String?
}

public enum FileChangeKind: String, Sendable, Equatable {
    case read, created, modified, deleted
}

public struct LifecycleRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let seq: UInt64
    public let timestamp: Date
    public let kind: EventType
    public var reason: String?
    public var exitCode: Int32?
}

/// Folds an event stream into Chat View rows.
///
/// The interesting work is *merging*: a single tool call arrives as `tool.started`, zero or more `tool.output`
/// chunks and a terminal `tool.completed`/`tool.failed`, and it must render as one card that mutates in place
/// rather than four rows. Same for a permission and its resolution, a question and its answer, and a plan that is
/// updated repeatedly — a plan that appended a row per update would bury the conversation.
public struct TranscriptReducer: Sendable {
    /// Per-tool output cap. Beyond this the card keeps the head, marks itself truncated, and points at the
    /// terminal, which is the authority for full output anyway.
    public var maxToolOutputBytes: Int
    /// Consecutive thinking deltas are joined instead of stacking one row per token.
    public var joinsThinkingDeltas: Bool

    public init(maxToolOutputBytes: Int = 16 * 1024, joinsThinkingDeltas: Bool = true) {
        self.maxToolOutputBytes = maxToolOutputBytes
        self.joinsThinkingDeltas = joinsThinkingDeltas
    }

    public func reduce(_ events: [Event]) -> [ChatItem] {
        var rows: [ChatItem] = []
        // Index of a row inside `rows`, keyed by the identity the agent gave it.
        var toolIndex: [String: Int] = [:]
        var permissionIndex: [String: Int] = [:]
        var questionIndex: [String: Int] = [:]
        var planIndex: [String: Int] = [:]
        var openThinking: Int?

        for event in events.sorted(by: { $0.seq < $1.seq }) {
            let base = event.eventID.rawValue
            switch event.body {
            case .turnCompleted(let turn):
                openThinking = nil
                guard !turn.text.isEmpty else { break }
                rows.append(.prose(ProseRow(
                    id: base, seq: event.seq, timestamp: event.timestamp,
                    role: turn.role, text: turn.text
                )))

            case .turnStarted(let turn):
                openThinking = nil
                guard let text = turn.text, !text.isEmpty else { break }
                rows.append(.prose(ProseRow(
                    id: base, seq: event.seq, timestamp: event.timestamp,
                    role: turn.role, text: text
                )))

            case .turnDelta(let delta):
                switch delta.kind {
                case .thinking:
                    if joinsThinkingDeltas, let index = openThinking,
                       case .thinking(var row) = rows[index] {
                        row.text += delta.delta
                        rows[index] = .thinking(row)
                    } else {
                        rows.append(.thinking(ThinkingRow(
                            id: base, seq: event.seq, timestamp: event.timestamp, text: delta.delta
                        )))
                        openThinking = rows.count - 1
                    }
                case .text:
                    // A text delta belongs to a turn that will be completed; showing partial assistant prose as
                    // its own row would duplicate it once `turn.completed` lands.
                    break
                }

            case .toolStarted(let tool):
                openThinking = nil
                let row = ToolRow(
                    id: tool.callID, seq: event.seq, timestamp: event.timestamp, tool: tool.tool,
                    summary: tool.summary, command: tool.command, paths: tool.paths, risk: tool.risk,
                    status: .running, output: "", outputTruncated: false
                )
                toolIndex[tool.callID] = rows.count
                rows.append(.tool(row))

            case .toolOutput(let chunk):
                guard let index = toolIndex[chunk.callID], case .tool(var row) = rows[index] else { break }
                if row.output.utf8.count < maxToolOutputBytes {
                    row.output += chunk.chunk
                    if row.output.utf8.count >= maxToolOutputBytes {
                        row.outputTruncated = true
                    }
                } else {
                    row.outputTruncated = true
                }
                if chunk.truncated { row.outputTruncated = true }
                rows[index] = .tool(row)

            case .toolCompleted(let done):
                guard let index = toolIndex[done.callID], case .tool(var row) = rows[index] else { break }
                row.status = .succeeded(exitCode: done.exitCode, durationMS: done.durationMs)
                if let summary = done.summary, row.summary == nil { row.summary = summary }
                rows[index] = .tool(row)

            case .toolFailed(let failure):
                guard let index = toolIndex[failure.callID], case .tool(var row) = rows[index] else {
                    // A failure with no preceding start still deserves to be visible.
                    rows.append(.tool(ToolRow(
                        id: failure.callID, seq: event.seq, timestamp: event.timestamp, tool: "unknown",
                        summary: nil, command: nil, paths: [], risk: nil,
                        status: .failed(error: failure.error, exitCode: failure.exitCode),
                        output: "", outputTruncated: false
                    )))
                    break
                }
                row.status = .failed(error: failure.error, exitCode: failure.exitCode)
                rows[index] = .tool(row)

            case .permissionRequested(let request):
                openThinking = nil
                permissionIndex[request.requestID] = rows.count
                rows.append(.permission(PermissionRow(
                    id: request.requestID, seq: event.seq, timestamp: event.timestamp,
                    request: request, decision: nil, decidedBy: nil
                )))

            case .permissionResolved(let resolution):
                guard let index = permissionIndex[resolution.requestID],
                      case .permission(var row) = rows[index] else { break }
                row.decision = resolution.decision
                row.decidedBy = resolution.decidedBy
                rows[index] = .permission(row)

            case .questionRequested(let question):
                openThinking = nil
                questionIndex[question.requestID] = rows.count
                rows.append(.question(QuestionRow(
                    id: question.requestID, seq: event.seq, timestamp: event.timestamp,
                    question: question, answer: nil
                )))

            case .questionAnswered(let answered):
                guard let index = questionIndex[answered.requestID],
                      case .question(var row) = rows[index] else { break }
                row.answer = answered.answer
                rows[index] = .question(row)

            case .planCreated(let plan), .planUpdated(let plan):
                if let index = planIndex[plan.planID], case .plan(var row) = rows[index] {
                    row.title = plan.title
                    row.steps = plan.steps
                    rows[index] = .plan(row)
                } else {
                    planIndex[plan.planID] = rows.count
                    rows.append(.plan(PlanRow(
                        id: plan.planID, seq: event.seq, timestamp: event.timestamp,
                        title: plan.title, steps: plan.steps
                    )))
                }

            case .fileRead:
                // Reads are noise in a conversation; they stay in the event stream and the diagnostics view.
                break

            case .fileCreated(let change):
                rows.append(.fileEdit(fileRow(base, event, change, .created)))
            case .fileModified(let change):
                rows.append(.fileEdit(fileRow(base, event, change, .modified)))
            case .fileDeleted(let change):
                rows.append(.fileEdit(fileRow(base, event, change, .deleted)))

            case .agentStarted(let life):
                rows.append(.lifecycle(LifecycleRow(
                    id: base, seq: event.seq, timestamp: event.timestamp,
                    kind: .agentStarted, reason: life.reason, exitCode: life.exitCode
                )))
            case .agentCompleted(let life):
                rows.append(.lifecycle(LifecycleRow(
                    id: base, seq: event.seq, timestamp: event.timestamp,
                    kind: .agentCompleted, reason: life.reason, exitCode: life.exitCode
                )))
            case .agentFailed(let life):
                rows.append(.lifecycle(LifecycleRow(
                    id: base, seq: event.seq, timestamp: event.timestamp,
                    kind: .agentFailed, reason: life.reason, exitCode: life.exitCode
                )))

            case .agentWorking, .usageUpdated, .contextUpdated, .unsupported:
                // Status, not conversation. These drive the header meters and the inbox instead.
                break
            }
        }
        return rows
    }

    private func fileRow(
        _ base: String, _ event: Event, _ change: FileChange, _ kind: FileChangeKind
    ) -> FileEditRow {
        FileEditRow(
            id: base, seq: event.seq, timestamp: event.timestamp, path: change.path, change: kind,
            additions: change.additions, deletions: change.deletions, unifiedDiff: change.unifiedDiff
        )
    }
}

/// Header state derived from the same stream: what the agent is doing right now, how much context is left, and
/// how close the account is to a rate limit.
public struct SessionVitals: Sendable, Equatable {
    public var activity: Activity = .idle
    public var contextPercent: Double?
    public var contextUsedTokens: UInt64?
    public var contextMaxTokens: UInt64?
    public var inputTokens: UInt64 = 0
    public var outputTokens: UInt64 = 0
    public var costUSD: Double?
    public var rateLimitPercent: Double?
    public var lastSeq: UInt64 = 0

    public enum Activity: Sendable, Equatable {
        case idle
        case working(tool: String?)
        case waiting(reason: String)
        case failed(reason: String?)
        case completed
    }

    public init() {}

    public static func derive(from events: [Event]) -> SessionVitals {
        var vitals = SessionVitals()
        var openTools: [String: String] = [:]
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            vitals.lastSeq = max(vitals.lastSeq, event.seq)
            switch event.body {
            case .agentWorking, .turnStarted:
                vitals.activity = .working(tool: openTools.values.first)
            case .agentCompleted:
                vitals.activity = .completed
            case .agentFailed(let life):
                vitals.activity = .failed(reason: life.reason)
            case .toolStarted(let tool):
                openTools[tool.callID] = tool.tool
                vitals.activity = .working(tool: tool.tool)
            case .toolCompleted(let done):
                openTools.removeValue(forKey: done.callID)
                vitals.activity = openTools.isEmpty ? .working(tool: nil) : .working(tool: openTools.values.first)
            case .toolFailed(let failure):
                openTools.removeValue(forKey: failure.callID)
                vitals.activity = .failed(reason: failure.error)
            case .permissionRequested(let request):
                vitals.activity = .waiting(reason: request.summary)
            case .questionRequested(let question):
                vitals.activity = .waiting(reason: question.question)
            case .permissionResolved, .questionAnswered:
                vitals.activity = .working(tool: openTools.values.first)
            case .usageUpdated(let usage):
                vitals.inputTokens = usage.inputTokens
                vitals.outputTokens = usage.outputTokens
                if let cost = usage.costUSD { vitals.costUSD = cost }
                if let limit = usage.rateLimitPercent { vitals.rateLimitPercent = limit }
            case .contextUpdated(let context):
                vitals.contextPercent = context.percentUsed
                vitals.contextUsedTokens = context.usedTokens
                vitals.contextMaxTokens = context.maxTokens
            case .turnCompleted(let turn):
                if turn.role == .assistant, case .working = vitals.activity {
                    vitals.activity = .working(tool: openTools.values.first)
                }
            default:
                break
            }
        }
        return vitals
    }
}
