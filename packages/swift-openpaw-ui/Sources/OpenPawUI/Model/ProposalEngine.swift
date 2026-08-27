import Foundation
import OpenPawProtocol

/// A pure projection from an immutable workspace snapshot to deterministic, local next-step proposals.
/// It never calls a backend or writes an event, so populating the launcher cannot create a hidden Agent turn.
public struct ProposalEngine: Sendable {
    public init() {}

    public func proposals(for input: WorkspaceContextInput) -> [ProactiveProposal] {
        let proposals = localProposals(for: input) + agentProposals(for: input)
        return proposals.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id < $1.id
        }
    }

    private func localProposals(for input: WorkspaceContextInput) -> [ProactiveProposal] {
        var proposals: [ProactiveProposal] = []
        let hostID = input.host?.id

        if !input.isConnected {
            let target = WorkspaceContextTarget(hostID: hostID, destination: .home)
            proposals.append(makeProposal(
                namespace: "reconnect",
                components: [hostID?.uuidString.lowercased()],
                title: "Reconnect to \(input.host?.title.nonEmpty ?? "Host")",
                detail: "Restore the authenticated workspace before continuing remote work.",
                source: .local,
                risk: .safe,
                baseScore: 1_000,
                target: target,
                payload: .navigate(target),
                input: input
            ))
        }

        for item in input.inbox where item.status == .pending {
            let sessionID = item.sessionID.rawValue
            let target = WorkspaceContextTarget(
                hostID: hostID,
                destination: .inbox,
                sessionID: sessionID
            )
            let risk = proposalRisk(item.risk ?? .unknown, text: [item.title, item.detail, item.command].compactMap { $0 }.joined(separator: "\n"))
            proposals.append(makeProposal(
                namespace: "inbox",
                components: [item.id.rawValue],
                title: "Resolve \(item.title)",
                detail: item.detail ?? "A pending request needs your decision.",
                source: .local,
                risk: risk,
                baseScore: 860,
                target: target,
                payload: .navigate(target),
                input: input
            ))
        }

        for repository in input.repositories where repository.dirty {
            let target = WorkspaceContextTarget(
                hostID: hostID,
                destination: .repository,
                repositoryPath: repository.path
            )
            proposals.append(makeProposal(
                namespace: "dirty-repository",
                components: [repository.path],
                title: "Review \(repository.name) changes",
                detail: "Inspect the dirty \(repository.branch ?? "detached HEAD") working tree before the next operation.",
                source: .local,
                risk: .safe,
                baseScore: 700,
                target: target,
                payload: .navigate(target),
                input: input
            ))
        }

        let selectedSession = input.selectedSessionID.flatMap { selected in
            input.agentSessions.first { $0.sessionID == selected && $0.state != .exited }
        }
        let activeSession = selectedSession ?? input.agentSessions
            .filter { $0.state != .exited && ($0.state == .working || $0.state == .waiting || $0.state == .failed) }
            .sorted(by: mostRecentSessionFirst)
            .first
        if let activeSession {
            let target = agentTarget(sessionID: activeSession.sessionID, input: input)
            proposals.append(makeProposal(
                namespace: "continue-session",
                components: [activeSession.sessionID],
                title: "Continue \(activeSession.title?.nonEmpty ?? activeSession.agent.displayName)",
                detail: "Return to the active Agent session and continue its current workflow.",
                source: .local,
                risk: .safe,
                baseScore: 650,
                freshness: 50,
                target: target,
                payload: .navigate(target),
                input: input
            ))
        }

        let terminalTarget = WorkspaceContextTarget(
            hostID: hostID,
            destination: .terminal,
            sessionID: input.selectedSessionID.flatMap { selected in
                input.agentSessions.contains { $0.sessionID == selected && $0.state != .exited } ? selected : nil
            },
            tabID: input.selectedTabID,
            paneID: input.selectedPaneID,
            repositoryPath: input.selectedRepositoryPath
        )
        proposals.append(makeProposal(
            namespace: "open-terminal",
            components: [hostID?.uuidString.lowercased()],
            title: "Open Terminal",
            detail: "Return to the current host terminal without starting a new Agent turn.",
            source: .local,
            risk: .safe,
            baseScore: 500,
            target: terminalTarget,
            payload: .navigate(terminalTarget),
            input: input
        ))

        return proposals
    }

    private func agentProposals(for input: WorkspaceContextInput) -> [ProactiveProposal] {
        let eligibleSessionIDs = eligibleAgentSessionIDs(input)
        guard !eligibleSessionIDs.isEmpty else { return [] }
        var plans: [PlanKey: PlanRecord] = [:]
        var tools: [ToolKey: ToolRecord] = [:]
        var questions: [QuestionKey: QuestionRecord] = [:]
        var answeredQuestions: Set<QuestionKey> = []
        var latestAssistantTurns: [String: TurnRecord] = [:]

        let events = input.transcripts.values.flatMap { $0.sorted(by: Self.eventsAreOrdered) }
        let newestEligibleTimestamp = events
            .filter { eligibleSessionIDs.contains($0.sessionID.rawValue) }
            .map(\.timestamp)
            .max() ?? Date(timeIntervalSince1970: 0)
        for event in events {
            let sessionID = event.sessionID.rawValue
            guard eligibleSessionIDs.contains(sessionID) else { continue }
            switch event.body {
            case .planCreated(let plan), .planUpdated(let plan):
                plans[PlanKey(sessionID: sessionID, planID: plan.planID)] = PlanRecord(plan: plan, timestamp: event.timestamp)

            case .toolStarted(let started):
                let key = ToolKey(sessionID: sessionID, callID: started.callID)
                var record = tools[key] ?? ToolRecord()
                record.started = started
                record.lastTimestamp = event.timestamp
                tools[key] = record

            case .toolOutput(let output):
                let key = ToolKey(sessionID: sessionID, callID: output.callID)
                var record = tools[key] ?? ToolRecord()
                record.appendOutput(output.chunk, truncated: output.truncated)
                record.lastTimestamp = event.timestamp
                tools[key] = record

            case .toolFailed(let failure):
                let key = ToolKey(sessionID: sessionID, callID: failure.callID)
                var record = tools[key] ?? ToolRecord()
                record.failure = failure
                record.completed = false
                record.lastTimestamp = event.timestamp
                tools[key] = record

            case .toolCompleted(let completed):
                let key = ToolKey(sessionID: sessionID, callID: completed.callID)
                var record = tools[key] ?? ToolRecord()
                record.failure = nil
                record.completed = true
                record.lastTimestamp = event.timestamp
                tools[key] = record

            case .questionRequested(let question):
                let key = QuestionKey(sessionID: sessionID, requestID: question.requestID)
                if !answeredQuestions.contains(key) {
                    questions[key] = QuestionRecord(question: question, timestamp: event.timestamp)
                }

            case .questionAnswered(let answer):
                let key = QuestionKey(sessionID: sessionID, requestID: answer.requestID)
                answeredQuestions.insert(key)
                questions.removeValue(forKey: key)

            case .turnCompleted(let turn) where turn.role == .assistant:
                latestAssistantTurns[sessionID] = TurnRecord(turn: turn, timestamp: event.timestamp)

            default:
                break
            }
        }

        var proposals: [ProactiveProposal] = []
        let newestPlanKeys = Dictionary(grouping: plans) { $0.key.sessionID }.compactMapValues { entries in
            entries.max { lhs, rhs in
                if lhs.value.timestamp != rhs.value.timestamp { return lhs.value.timestamp < rhs.value.timestamp }
                return lhs.key.planID < rhs.key.planID
            }?.key
        }
        for (key, record) in plans where newestPlanKeys[key.sessionID] == key {
            guard let step = record.plan.steps.first(where: { $0.status == .inProgress })
                    ?? record.plan.steps.first(where: { $0.status == .pending }) else { continue }
            let target = agentTarget(sessionID: key.sessionID, input: input)
            let instruction = "Continue with plan step: \(step.title)"
            proposals.append(makeProposal(
                namespace: "plan-step",
                components: [key.sessionID, key.planID, step.id],
                title: step.title,
                detail: record.plan.title.map { "\($0): \(instruction)" } ?? instruction,
                source: .agentDerived,
                risk: proposalRisk(.unknown, text: instruction),
                baseScore: step.status == .inProgress ? 920 : 820,
                freshness: freshness(record.timestamp, newest: newestEligibleTimestamp),
                target: target,
                payload: .agentMessage(instruction),
                input: input
            ))
        }

        for (key, record) in tools where record.failure != nil && !record.completed {
            guard let failure = record.failure else { continue }
            let target = agentTarget(sessionID: key.sessionID, input: input, destination: .terminal)
            let label = record.started?.summary.flatMap { $0.nonEmpty } ?? record.started?.tool.nonEmpty ?? "failed tool"
            let command = record.started?.command.flatMap { $0.nonEmpty }
            let output = record.output
            let detailParts = [failure.error.nonEmpty, output.nonEmpty].compactMap { $0 }
            let detail = detailParts.isEmpty ? "The previous tool invocation failed." : detailParts.joined(separator: "\n")
            let payload: ProactiveProposal.Payload = command.map(ProactiveProposal.Payload.terminalCommand)
                ?? .agentMessage("Retry \(label)")
            let protocolRisk = record.started?.risk ?? .unknown
            proposals.append(makeProposal(
                namespace: "failed-tool",
                components: [key.sessionID, key.callID],
                title: "Retry \(label)",
                detail: detail,
                source: .agentDerived,
                risk: proposalRisk(protocolRisk, text: [label, command, detail].compactMap { $0 }.joined(separator: "\n")),
                baseScore: 880,
                freshness: freshness(record.lastTimestamp, newest: newestEligibleTimestamp),
                target: target,
                payload: payload,
                input: input
            ))
        }

        for (key, record) in questions {
            let target = agentTarget(sessionID: key.sessionID, input: input)
            proposals.append(makeProposal(
                namespace: "pending-question",
                components: [key.sessionID, key.requestID],
                title: "Answer pending question",
                detail: record.question.question,
                source: .agentDerived,
                risk: proposalRisk(.unknown, text: record.question.question),
                baseScore: 900,
                freshness: freshness(record.timestamp, newest: newestEligibleTimestamp),
                target: target,
                payload: .navigate(target),
                input: input
            ))
        }

        for (sessionID, record) in latestAssistantTurns {
            let target = agentTarget(sessionID: sessionID, input: input)
            proposals.append(makeProposal(
                namespace: "latest-turn",
                components: [sessionID, record.turn.turnID],
                title: "Review latest Agent update",
                detail: record.turn.text,
                source: .agentDerived,
                risk: proposalRisk(.unknown, text: record.turn.text),
                baseScore: 560,
                freshness: freshness(record.timestamp, newest: newestEligibleTimestamp),
                target: target,
                payload: .navigate(target),
                input: input
            ))
        }

        return proposals
    }

    private func makeProposal(
        namespace: String,
        components: [String?],
        title: String,
        detail: String,
        source: ProactiveProposal.Source,
        risk: ProactiveProposal.Risk,
        baseScore: Int,
        freshness: Int = 0,
        target: WorkspaceContextTarget,
        payload: ProactiveProposal.Payload,
        input: WorkspaceContextInput
    ) -> ProactiveProposal {
        let redactedPayload: ProactiveProposal.Payload
        switch payload {
        case .agentMessage(let text): redactedPayload = .agentMessage(Self.redact(text, limit: 512))
        case .terminalCommand(let text): redactedPayload = .terminalCommand(Self.redact(text, limit: 512))
        case .navigate, .tool: redactedPayload = payload
        }
        var score = baseScore + freshness
        if target.destination == input.destination { score += 30 }
        if let selected = input.selectedSessionID, target.sessionID == selected { score += 60 }
        if let selected = input.selectedTabID, target.tabID == selected { score += 25 }
        if let selected = input.selectedPaneID, target.paneID == selected { score += 35 }
        if let selected = input.selectedRepositoryPath, target.repositoryPath == selected { score += 30 }
        return ProactiveProposal(
            id: Self.stableID(namespace: namespace, components: components),
            title: Self.redact(title, limit: 120),
            detail: Self.redact(detail, limit: 512),
            source: source,
            risk: risk,
            score: score,
            target: target,
            payload: redactedPayload
        )
    }

    private func agentTarget(
        sessionID: String,
        input: WorkspaceContextInput,
        destination: WorkspaceContextDestination = .sessions
    ) -> WorkspaceContextTarget {
        let cwd = input.agentSessions.first { $0.sessionID == sessionID }?.cwd
        let session = input.agentSessions.first { $0.sessionID == sessionID }
        let selectedHerdr = sessionID == input.selectedSessionID ? input.sessionSpace.remoteSessions.first {
            $0.kind == .herdr &&
            (input.selectedPaneID == nil || $0.id == input.selectedPaneID) &&
            (input.selectedTabID == nil || $0.tabID == input.selectedTabID)
        } : nil
        let matchedHerdr = selectedHerdr ?? session?.multiplexerTarget.flatMap { target in
            input.sessionSpace.remoteSessions.first { $0.kind == .herdr && ($0.id == target || $0.terminalID == target) }
        }
        return WorkspaceContextTarget(
            hostID: input.host?.id,
            destination: destination,
            sessionID: sessionID,
            workspaceID: matchedHerdr?.workspaceID,
            tabID: matchedHerdr?.tabID ?? (sessionID == input.selectedSessionID ? input.selectedTabID : nil),
            paneID: matchedHerdr?.id ?? (sessionID == input.selectedSessionID ? input.selectedPaneID : nil),
            terminalID: matchedHerdr?.terminalID,
            repositoryPath: repositoryRoot(matching: cwd, repositories: input.repositories)
        )
    }

    private func eligibleAgentSessionIDs(_ input: WorkspaceContextInput) -> Set<String> {
        let sessions = input.agentSessions.filter { $0.state != .exited }
        var ids = Set<String>()
        if let selected = input.selectedSessionID, sessions.contains(where: { $0.sessionID == selected }) {
            ids.insert(selected)
        }
        ids.formUnion(sessions.filter { $0.state == .working || $0.state == .waiting || $0.state == .failed }.map(\.sessionID))
        if ids.isEmpty, let fallback = sessions.sorted(by: mostRecentSessionFirst).first {
            ids.insert(fallback.sessionID)
        }
        return ids
    }

    private func mostRecentSessionFirst(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Bool {
        let lhsDate = lhs.lastEventAt ?? Date(timeIntervalSince1970: 0)
        let rhsDate = rhs.lastEventAt ?? Date(timeIntervalSince1970: 0)
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        if lhs.lastSeq != rhs.lastSeq { return lhs.lastSeq > rhs.lastSeq }
        return lhs.sessionID < rhs.sessionID
    }

    private func repositoryRoot(matching cwd: String?, repositories: [RepoSummary]) -> String? {
        guard let cwd = cwd?.nonEmpty else { return nil }
        let directory = URL(fileURLWithPath: cwd).standardizedFileURL.path
        return repositories
            .map(\.path)
            .filter {
                let root = URL(fileURLWithPath: $0).standardizedFileURL.path
                return directory == root || directory.hasPrefix(root + "/")
            }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0 < $1
            }
            .first
    }

    private func proposalRisk(_ protocolRisk: OpenPawProtocol.Risk, text: String) -> ProactiveProposal.Risk {
        let protocolMapped: ProactiveProposal.Risk
        switch protocolRisk.riskClass {
        case .readOnly: protocolMapped = .safe
        case .destructiveShell, .credentialAccess: protocolMapped = .destructive
        case .localWrite, .gitOperation, .networkAccess, .packageInstallation, .unknown: protocolMapped = .caution
        }

        let commandRisk = OpenPawProtocol.Risk.classifyCommand(text)
        let commandMapped: ProactiveProposal.Risk
        switch commandRisk.riskClass {
        case .destructiveShell, .credentialAccess: commandMapped = .destructive
        case .localWrite, .gitOperation, .networkAccess, .packageInstallation: commandMapped = .caution
        case .readOnly, .unknown: commandMapped = .safe
        }

        let lowered = text.lowercased()
        let destructiveKeyword = [
            "delete all", "delete the", "delete production data", "drop database", "drop table", "wipe ", "erase ",
            "format disk", "reset --hard", "force push", "force-push", "remove all",
            "private key", "bearer ", "password=", "token=", "api_key=", "secret=",
        ].contains { lowered.contains($0) }
        let destructiveLanguage = destructiveKeyword || Self.matches(
            #"(?i)\b(delete|remove|destroy|wipe|erase|purge|drop)\b\s+(?:\w+\s+){0,3}\b(production|customer|user|database|records|backups?|data|tables?|repository|repo|codebase|project|environment|cluster)\b"#,
            in: text
        )
        return max(protocolMapped, commandMapped, destructiveLanguage ? .destructive : .safe)
    }

    private func freshness(_ timestamp: Date, newest: Date) -> Int {
        let age = max(0, newest.timeIntervalSince(timestamp))
        return max(0, 50 - Int(min(50, age.rounded(.down))))
    }

    private static func eventsAreOrdered(_ lhs: Event, _ rhs: Event) -> Bool {
        if lhs.seq != rhs.seq { return lhs.seq < rhs.seq }
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.eventID.rawValue < rhs.eventID.rawValue
    }

    private static func stableID(namespace: String, components: [String?]) -> String {
        let semantic = ([namespace] + components.map { component in
            guard let component else { return "n" }
            return "s\(component.utf8.count):\(component)"
        }).joined(separator: "|")
        return "proposal.\(namespace).\(Hashing.sha256Hex(Data(semantic.utf8)).prefix(24))"
    }

    private static func redact(_ raw: String, limit: Int) -> String {
        var text = raw
        text = replacing(
            #"-----BEGIN [^-\n]*PRIVATE KEY-----[\s\S]*?-----END [^-\n]*PRIVATE KEY-----"#,
            in: text,
            with: "[REDACTED PRIVATE KEY]",
            options: [.caseInsensitive]
        )
        text = replacing(#"-----BEGIN [^-\n]*PRIVATE KEY-----[\s\S]*"#, in: text, with: "[REDACTED PRIVATE KEY]")
        text = replacing(#"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"#, in: text, with: "Bearer [REDACTED]")
        text = replacing(
            #"(?i)(Authorization\s*:\s*Basic)\s+[A-Za-z0-9+/=]+"#,
            in: text,
            with: "$1 [REDACTED]"
        )
        text = replacing(
            #"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s@]+@"#,
            in: text,
            with: "$1[REDACTED]@"
        )
        text = replacing(
            #"(?i)\b([A-Z0-9_]*(?:password|passwd|pwd|token|api[_-]?key|secret|credential|access[_-]?key)[A-Z0-9_]*)\s*[:=]\s*(?:"[^"\n]*(?:"|(?=\n|$))|'[^'\n]*(?:'|(?=\n|$))|[^\s,;]+)"#,
            in: text,
            with: "$1=[REDACTED]"
        )
        text = replacing(#"(?i)(-u|--user)\s+[^\s]+"#, in: text, with: "$1 [REDACTED]")
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    private static func replacing(
        _ pattern: String,
        in text: String,
        with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }
}

private struct PlanKey: Hashable {
    var sessionID: String
    var planID: String
}

private struct PlanRecord {
    var plan: Plan
    var timestamp: Date
}

private struct ToolKey: Hashable {
    var sessionID: String
    var callID: String
}

private struct ToolRecord {
    var started: ToolStarted?
    var output = ""
    var failure: ToolFailed?
    var completed = false
    var lastTimestamp = Date(timeIntervalSince1970: 0)

    mutating func appendOutput(_ chunk: String, truncated: Bool) {
        let budget = 2_048
        guard output.count < budget else {
            if truncated, !output.contains("[truncated") { output.append("\n[truncated output]") }
            return
        }
        if truncated, !output.contains("[truncated") { output.append("[truncated output]\n") }
        if !output.isEmpty { output.append("\n") }
        let remaining = max(0, budget - output.count)
        output.append(contentsOf: chunk.prefix(remaining))
    }
}

private struct QuestionKey: Hashable {
    var sessionID: String
    var requestID: String
}

private struct QuestionRecord {
    var question: QuestionRequested
    var timestamp: Date
}

private struct TurnRecord {
    var turn: TurnCompleted
    var timestamp: Date
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value
    }
}
