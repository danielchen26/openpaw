import Foundation

/// What the app captured about a live terminal so it can pick the session back
/// up after being suspended, killed or moved to another device.
public struct SessionRestorationPlan: Sendable, Hashable, Codable {
    public var hostID: HostID
    /// `nil` when the terminal was a bare login shell.
    public var multiplexer: MultiplexerKind?
    /// The multiplexer session handle to reattach to.
    public var multiplexerTarget: String?
    public var workingDirectory: String?
    /// The agent session the transcript was showing, so the UI can reopen it.
    public var agentSessionID: String?
    public var capturedAt: Date

    public init(
        hostID: HostID,
        multiplexer: MultiplexerKind? = nil,
        multiplexerTarget: String? = nil,
        workingDirectory: String? = nil,
        agentSessionID: String? = nil,
        capturedAt: Date
    ) {
        self.hostID = hostID
        self.multiplexer = multiplexer
        self.multiplexerTarget = multiplexerTarget
        self.workingDirectory = workingDirectory
        self.agentSessionID = agentSessionID
        self.capturedAt = capturedAt
    }

    /// True when there is a multiplexer session to reattach to.
    public var isReattachable: Bool {
        multiplexer != nil && !(multiplexerTarget ?? "").isEmpty
    }

    /// The exact command sequence to type into a fresh PTY to land back where
    /// the user left off.
    ///
    /// Reattaching restores the multiplexer session's own working directory, so
    /// no `cd` is emitted in that case; creating one applies the captured
    /// directory instead.
    public func commands() -> [String] {
        guard let multiplexer else {
            guard let directory = workingDirectory, !directory.isEmpty else { return [] }
            return ["cd \(shellQuoted(directory))"]
        }
        let adapter = MultiplexerAdapters.adapter(for: multiplexer)
        if let target = multiplexerTarget, !target.isEmpty {
            return [adapter.attach(.target(target, kind: multiplexer))]
        }
        return [adapter.create(name: newSessionName, directory: workingDirectory)]
    }

    /// Deterministic name for a session created because the old one is gone:
    /// the working directory's leaf, sanitised for tmux/screen/Zellij.
    public var newSessionName: String {
        let leaf = (workingDirectory?.split(separator: "/").last).map(String.init) ?? ""
        let sanitized = String(
            leaf.map { character in
                character.isLetter || character.isNumber || character == "-" || character == "_"
                    ? character : "-"
            })
        return sanitized.isEmpty ? "openpaw" : sanitized
    }

    private enum CodingKeys: String, CodingKey {
        case hostID = "host_id"
        case multiplexer
        case multiplexerTarget = "multiplexer_target"
        case workingDirectory = "working_directory"
        case agentSessionID = "agent_session_id"
        case capturedAt = "captured_at"
    }
}

public enum RestorationDecision: Sendable, Hashable {
    /// Reattach without asking; the user still has the session in mind.
    case reattach
    /// Enough time passed that silently reattaching could surprise the user.
    case promptUser(reason: String)
    case newSession(reason: String)
}

/// Chooses between reattaching, asking, and starting fresh, based on how long
/// the app was away and whether the target still exists.
public struct RestorationPolicy: Sendable, Hashable, Codable {
    /// Up to this long, reattach silently.
    public var silentReattachWindow: TimeInterval
    /// Up to this long, ask first. Beyond it, start a new session.
    public var promptWindow: TimeInterval

    public init(
        silentReattachWindow: TimeInterval = 15 * 60,
        promptWindow: TimeInterval = 12 * 60 * 60
    ) {
        self.silentReattachWindow = silentReattachWindow
        self.promptWindow = promptWindow
    }

    public static let `default` = RestorationPolicy()

    public func decide(
        suspendedFor interval: TimeInterval,
        plan: SessionRestorationPlan?,
        targetStillExists: Bool
    ) -> RestorationDecision {
        guard let plan else {
            return .newSession(reason: "no previous session was captured")
        }
        guard plan.isReattachable else {
            return .newSession(reason: "the previous terminal was not inside a multiplexer")
        }
        guard targetStillExists else {
            return .newSession(
                reason: "the multiplexer session \(plan.multiplexerTarget ?? "") is gone")
        }
        let elapsed = max(0, interval)
        if elapsed <= silentReattachWindow { return .reattach }
        let formatted = formatApproximateDuration(elapsed)
        if elapsed <= promptWindow {
            return .promptUser(reason: "suspended for \(formatted)")
        }
        return .newSession(reason: "suspended for \(formatted)")
    }

    private enum CodingKeys: String, CodingKey {
        case silentReattachWindow = "silent_reattach_window"
        case promptWindow = "prompt_window"
    }
}
