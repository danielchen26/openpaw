import Foundation

public struct ProactiveProposal: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, Hashable {
        case local
        case agentDerived
    }

    public enum Risk: Int, Sendable, Hashable, Comparable {
        case safe
        case caution
        case destructive

        public static func < (lhs: Risk, rhs: Risk) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public enum Payload: Sendable, Hashable {
        case navigate(WorkspaceContextTarget)
        case agentMessage(String)
        case terminalCommand(String)
        case tool(WorkspaceToolAction)
    }

    public var id: String
    public var title: String
    public var detail: String
    public var source: Source
    public var risk: Risk
    public var score: Int
    public var target: WorkspaceContextTarget
    public var payload: Payload

    public init(
        id: String,
        title: String,
        detail: String,
        source: Source,
        risk: Risk,
        score: Int,
        target: WorkspaceContextTarget,
        payload: Payload
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.source = source
        self.risk = risk
        self.score = score
        self.target = target
        self.payload = payload
    }
}
