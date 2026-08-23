import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import Testing

@testable import OpenPawUI

/// The gate these tests defend is the reason the app exists: an agent asking to run `rm -rf` must not be
/// approvable by anyone who has not read the command. The host enforces it with a 400 and `OpenPawModel` refuses
/// locally, so what is asserted here is the local refusal and the ordering that puts the dangerous request in front
/// of the reader in the first place.
@MainActor
@Suite("Inbox and the approval gate")
struct InboxTests {

    // MARK: - Fixtures

    /// `refresh()` is idempotent — it replaces `inbox` with what the backend serves — so calling it makes these
    /// tests independent of whether the preview factory pre-populates the model.
    private func destructiveScenario() async -> OpenPawModel {
        let model = PreviewBackend.model(.reviewingDestructiveCommand)
        await model.refresh()
        return model
    }

    private static let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private static func item(
        id: String,
        category: InboxCategory,
        title: String,
        detail: String? = nil,
        command: String? = nil,
        risk: Risk? = nil,
        actions: [ActionID] = [.acknowledge],
        requestID: String? = nil,
        actionToken: String? = "tok_test",
        createdAt: Date = epoch,
        status: InboxStatus = .pending
    ) -> InboxItem {
        InboxItem(
            id: InboxID(rawValue: id),
            sessionID: SessionID(rawValue: "sess_cc-inboxtests"),
            agent: .claudeCode,
            category: category,
            title: title,
            detail: detail,
            command: command,
            risk: risk,
            actions: actions,
            requestID: requestID,
            actionToken: actionToken,
            createdAt: createdAt,
            expiresAt: nil,
            status: status,
            resolution: nil,
            sourceEventID: EventID(rawValue: "evt_\(id)")
        )
    }

    private static let destructive = Risk(
        riskClass: .destructiveShell,
        requiresDetailExpansion: true,
        reasons: ["rm removes files recursively", "the path is outside the repository"]
    )

    // MARK: - The queue

    @Test("The destructive request leads the queue")
    func destructiveRequestLeadsTheQueue() async throws {
        let model = await destructiveScenario()
        let first = try #require(model.pendingInbox.first, "the scenario must hold a pending item")
        #expect(first.category == .permission)
        #expect(first.risk?.riskClass == .destructiveShell)
        #expect(first.risk?.requiresDetailExpansion == true)
    }

    /// The queue is a work list, not a feed. A destructive request that arrived ten minutes ago outranks a
    /// completion notice that arrived since, and the row order the list renders is exactly that.
    @Test("A destructive permission outranks a completion that arrived later")
    func destructivePermissionOutranksALaterCompletion() {
        let model = PreviewBackend.model(.empty)
        let permission = Self.item(
            id: "inb_permission",
            category: .permission,
            title: "rm -rf build",
            command: "rm -rf build",
            risk: Self.destructive,
            actions: [.approveOnce, .deny, .stop],
            createdAt: Self.epoch
        )
        let completion = Self.item(
            id: "inb_completion",
            category: .completion,
            title: "Parser test fixed and the suite is green",
            createdAt: Self.epoch.addingTimeInterval(600)
        )

        model.inbox = [completion, permission]

        #expect(model.pendingInbox.map(\.id.rawValue) == ["inb_permission", "inb_completion"])
    }

    // MARK: - The gate

    @Test("An approval is refused until the full command has been shown")
    func approvalIsRefusedUntilTheCommandIsShown() async throws {
        let model = await destructiveScenario()
        let item = try #require(
            model.pendingInbox.first { $0.risk?.requiresDetailExpansion == true },
            "the scenario must hold a request that demands the full command"
        )

        #expect(model.isDetailAcknowledged(item) == false)

        let refused = await model.resolve(item, action: .approveOnce)
        #expect(refused == false)
        #expect(model.lastError != nil)
        #expect(model.inbox.first { $0.id == item.id }?.status == .pending)

        model.lastError = nil
        model.acknowledgeDetail(item)
        #expect(model.isDetailAcknowledged(item))

        let sent = await model.resolve(item, action: .approveOnce)
        #expect(sent)
        #expect(model.lastError == nil)
        let settled = try #require(model.inbox.first { $0.id == item.id })
        #expect(settled.status == .resolved)
        #expect(settled.resolution == ActionID.approveOnce.rawValue)
    }

    @Test("A request that does not demand the full command needs no acknowledgement")
    func ungatedRequestNeedsNoAcknowledgement() async throws {
        let model = await destructiveScenario()
        let ungated = try #require(
            model.pendingInbox.first { $0.risk?.requiresDetailExpansion != true },
            "the scenario must hold an item that is not gated"
        )

        #expect(model.isDetailAcknowledged(ungated))

        let action = try #require(ungated.actions.first, "every item the host serves offers an action")
        let sent = await model.resolve(ungated, action: action)
        #expect(sent)
        #expect(model.lastError == nil)
    }

    /// The same rule stated against a read-only classification directly, so it holds whatever the fixtures contain.
    @Test("A read-only request is acknowledged from the start")
    func readOnlyRequestIsAcknowledgedFromTheStart() {
        let model = PreviewBackend.model(.empty)
        let readOnly = Self.item(
            id: "inb_readonly",
            category: .permission,
            title: "Run the test suite",
            command: "swift test",
            risk: Risk(riskClass: .readOnly, requiresDetailExpansion: false, reasons: []),
            actions: [.approveOnce, .deny]
        )

        #expect(model.isDetailAcknowledged(readOnly))
    }

    /// `approve_always` is scoped by the host to one tool at one risk class. A label reading "Always approve"
    /// would describe a capability the product deliberately does not have.
    @Test("The always-approve control never claims to be global")
    func alwaysApproveNamesItsScope() {
        #expect(InboxCopy.title(for: .approveAlways) == "Always approve this tool at this risk level")
        #expect(InboxCopy.title(for: .approveOnce) == "Approve once")
        #expect(InboxCopy.title(for: .deny) == "Deny")
        #expect(InboxCopy.title(for: .stop) == "Stop the agent")
    }

    // MARK: - Facts a decision screen needs

    @Test("Facts come from the source event when the transcript holds it")
    func factsComeFromTheSourceEvent() {
        let sourceEventID = EventID(rawValue: "evt_inb_permission")
        let event = Event(
            eventID: sourceEventID,
            sessionID: SessionID(rawValue: "sess_cc-inboxtests"),
            agent: .claudeCode,
            seq: 12,
            timestamp: Self.epoch,
            cwd: "/Users/dev/src/openpaw",
            gitBranch: "main",
            body: .permissionRequested(
                PermissionRequested(
                    requestID: "req_1",
                    tool: "Bash",
                    summary: "Delete the build directory",
                    command: "rm -rf build",
                    paths: ["/Users/dev/src/openpaw/build"],
                    risk: Self.destructive,
                    actions: [.approveOnce, .deny, .stop]
                )
            )
        )
        let item = Self.item(
            id: "inb_permission",
            category: .permission,
            title: "Delete the build directory",
            command: "rm -rf build",
            risk: Self.destructive,
            actions: [.approveOnce, .deny, .stop]
        )

        let facts = InboxItemFacts(item: item, events: [event])

        #expect(facts.tool == "Bash")
        #expect(facts.cwd == "/Users/dev/src/openpaw")
        #expect(facts.paths == ["/Users/dev/src/openpaw/build"])
    }

    /// An inbox fetched over REST after a cold start has no transcript behind it, so the choices have to come back
    /// out of the string `InboxProjection` wrote into `detail`.
    @Test("A question recovers its choices from the projected detail")
    func questionRecoversChoicesFromDetail() {
        let item = Self.item(
            id: "inb_question",
            category: .question,
            title: "Which branch should I push to?",
            detail: "main, release/2.0, do not push",
            actions: [.answer]
        )

        let facts = InboxItemFacts(item: item, events: [])

        #expect(facts.choices == ["main", "release/2.0", "do not push"])
        #expect(facts.allowsFreeText == false)
    }

    @Test("A plan recovers its steps and their statuses from the projected detail")
    func planRecoversStepsFromDetail() {
        let item = Self.item(
            id: "inb_plan",
            category: .plan,
            title: "Fix the parser (1/4 steps complete)",
            detail: """
                [x] Read the failing test
                [~] Fix the range check
                [ ] Run the suite
                [-] Refactor the tokenizer
                """,
            actions: [.acknowledge]
        )

        let facts = InboxItemFacts(item: item, events: [])

        #expect(facts.planSteps.map(\.status) == [.completed, .inProgress, .pending, .cancelled])
        #expect(
            facts.planSteps.map(\.title) == [
                "Read the failing test",
                "Fix the range check",
                "Run the suite",
                "Refactor the tokenizer",
            ]
        )
    }

    /// The gate is meaningless if there is nothing to reveal, so a permission always resolves to some text: the
    /// projection copies the command into `detail`, and falls back to the summary when there is no command.
    @Test("A permission always has something for the gate to reveal")
    func permissionAlwaysHasRevealableText() {
        let withCommand = Self.item(
            id: "inb_with_command",
            category: .permission,
            title: "Delete the build directory",
            detail: "rm -rf build",
            command: "rm -rf build",
            risk: Self.destructive,
            actions: [.approveOnce, .deny]
        )
        let withoutCommand = Self.item(
            id: "inb_without_command",
            category: .permission,
            title: "Read the repository",
            detail: "Read the repository",
            risk: Risk(riskClass: .readOnly, requiresDetailExpansion: false, reasons: []),
            actions: [.approveOnce, .deny]
        )
        let notARequest = Self.item(
            id: "inb_notice",
            category: .completion,
            title: "Suite is green",
            detail: "40 passed in 3.11s"
        )

        #expect(InboxItemFacts.command(for: withCommand) == "rm -rf build")
        #expect(InboxItemFacts.command(for: withoutCommand) == "Read the repository")
        #expect(InboxItemFacts.command(for: notARequest) == nil)
    }

    // MARK: - Outcome copy

    @Test("A decided item states its outcome in words")
    func decidedItemStatesItsOutcome() {
        var resolved = Self.item(id: "inb_resolved", category: .permission, title: "rm -rf build")
        resolved.status = .resolved
        resolved.resolution = ActionID.deny.rawValue
        var dismissed = Self.item(id: "inb_dismissed", category: .completion, title: "Suite is green")
        dismissed.status = .dismissed

        #expect(InboxCopy.decision(for: resolved) == "Resolved: deny.")
        #expect(InboxCopy.outcome(for: resolved) == "resolved · deny")
        #expect(InboxCopy.decision(for: dismissed) == "Dismissed on the host. The agent was not answered.")
    }

    // MARK: - Durable dismissal

    @Test("An informational item is archived remotely before local state changes")
    func informationalDismissPersistsAcrossRefresh() async throws {
        let item = Self.item(
            id: "inb_notice_remote",
            category: .completion,
            title: "Suite is green",
            actionToken: nil
        )
        let backend = InboxDismissBackend(items: [item])
        let model = connectedModel(backend: backend)
        model.inbox = [item]

        let sent = await model.dismiss(item)

        #expect(sent)
        #expect(backend.dismissedIDs == [item.id])
        #expect(model.inbox.first?.status == .dismissed)
        await model.refresh()
        #expect(model.inbox.first?.status == .dismissed)
    }

    @Test("A failed remote dismiss leaves the item pending and explains the failure")
    func failedDismissDoesNotArchiveLocally() async throws {
        let item = Self.item(
            id: "inb_notice_failure",
            category: .toolFailure,
            title: "Tests failed",
            actionToken: nil
        )
        let backend = InboxDismissBackend(items: [item])
        backend.dismissError = InboxDismissTestError.refused
        let model = connectedModel(backend: backend)
        model.inbox = [item]

        let sent = await model.dismiss(item)

        #expect(!sent)
        #expect(model.inbox.first?.status == .pending)
        #expect(model.lastError?.title == "Failed while dismissing the inbox item")
    }

    @Test("A dismiss response owned by an old host cannot archive the new host's item")
    func staleDismissCannotMutateANewerHost() async throws {
        let first = HostRecord(
            nickname: "One", hostname: "one", username: "dev", auth: .agentForwarding)
        let second = HostRecord(
            nickname: "Two", hostname: "two", username: "dev", auth: .agentForwarding)
        let item = Self.item(
            id: "inb_shared_id",
            category: .completion,
            title: "Old host finished",
            actionToken: nil
        )
        let backend = InboxDismissBackend(items: [item])
        backend.dismissDelayNanoseconds = 50_000_000
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, second]), backend: backend)
        model.connection = .connected(.ssh)
        model.inbox = [item]

        let dismiss = Task { await model.dismiss(item) }
        try await Task.sleep(nanoseconds: 5_000_000)
        await model.selectHost(second.id)
        model.connection = .connected(.ssh)
        model.inbox = [item]
        let sent = await dismiss.value

        #expect(!sent)
        #expect(model.selectedHostID == second.id)
        #expect(model.inbox.first?.status == .pending)
        #expect(model.lastError == nil)
    }

    @Test("Only informational items expose the archive action")
    func onlyInformationalItemsCanBeDismissed() {
        let notice = Self.item(
            id: "inb_notice_policy",
            category: .completion,
            title: "Finished",
            actionToken: nil
        )
        let permission = Self.item(
            id: "inb_permission_policy",
            category: .permission,
            title: "Delete build output",
            actions: [.approveOnce, .deny],
            requestID: "req_permission_policy"
        )

        #expect(notice.isDismissible)
        #expect(!permission.isDismissible)
    }

    @Test("Informational detail uses durable dismiss instead of legacy acknowledgement")
    func informationalDetailUsesDurableDismiss() {
        let notice = Self.item(
            id: "inb_notice_detail",
            category: .completion,
            title: "Finished",
            actions: [.acknowledge],
            actionToken: nil
        )

        let plan = InboxDetailControlPlan(item: notice, detailAcknowledged: true)

        #expect(plan.offersDurableDismiss)
        #expect(plan.closingActions.isEmpty)
        #expect(plan.preRevealActions.isEmpty)
    }

    @Test("A gated request keeps denial available before reveal")
    func gatedRequestKeepsDenialBeforeReveal() {
        let permission = Self.item(
            id: "inb_permission_detail",
            category: .permission,
            title: "Delete build output",
            risk: Self.destructive,
            actions: [.approveOnce, .deny],
            requestID: "req_permission_detail"
        )

        let plan = InboxDetailControlPlan(item: permission, detailAcknowledged: false)

        #expect(!plan.offersDurableDismiss)
        #expect(plan.preRevealActions == [.deny])
    }

    private func connectedModel(backend: InboxDismissBackend) -> OpenPawModel {
        let host = HostRecord(
            nickname: "Host", hostname: "host", username: "dev", auth: .agentForwarding)
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]), backend: backend)
        model.connection = .connected(.ssh)
        return model
    }
}

private enum InboxDismissTestError: Error {
    case refused
}

private final class InboxDismissBackend: OpenPawBackend, @unchecked Sendable {
    private let base = PreviewBackend(.empty)
    var items: [InboxItem]
    var dismissedIDs: [InboxID] = []
    var dismissDelayNanoseconds: UInt64 = 0
    var dismissError: (any Error)?

    init(items: [InboxItem]) {
        self.items = items
    }

    func health() async throws -> HealthInfo { try await base.health() }
    func sessions() async throws -> [SessionSummary] { try await base.sessions() }
    func inbox(status: InboxStatus?) async throws -> [InboxItem] {
        guard let status else { return items }
        return items.filter { $0.status == status }
    }
    func resolve(
        item: InboxItem,
        action: ActionID,
        answer: String?,
        detailAcknowledged: Bool
    ) async throws -> ResolveResult {
        try await base.resolve(
            item: item,
            action: action,
            answer: answer,
            detailAcknowledged: detailAcknowledged
        )
    }
    func dismiss(item: InboxItem) async throws -> InboxDismissResult {
        if dismissDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: dismissDelayNanoseconds)
        }
        if let dismissError { throw dismissError }
        dismissedIDs.append(item.id)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].status = .dismissed
            items[index].actionToken = nil
            return InboxDismissResult(status: .dismissed, item: items[index])
        }
        var dismissed = item
        dismissed.status = .dismissed
        dismissed.actionToken = nil
        return InboxDismissResult(status: .dismissed, item: dismissed)
    }
    func events(session: String?, afterSeq: UInt64?) -> AsyncThrowingStream<Event, any Error> {
        base.events(session: session, afterSeq: afterSeq)
    }
    func repos() async throws -> [RepoSummary] { try await base.repos() }
    func repoStatus(_ repo: String) async throws -> RepoStatus { try await base.repoStatus(repo) }
    func diff(repo: String, mode: DiffMode, path: String?) async throws -> Diff {
        try await base.diff(repo: repo, mode: mode, path: path)
    }
    func tree(repo: String, ref: String, path: String) async throws -> [TreeEntry] {
        try await base.tree(repo: repo, ref: ref, path: path)
    }
    func blob(repo: String, ref: String, path: String) async throws -> Blob {
        try await base.blob(repo: repo, ref: ref, path: path)
    }
    func search(repo: String, query: String, path: String?) async throws -> [ContentMatch] {
        try await base.search(repo: repo, query: query, path: path)
    }
    func upload(data: Data, filename: String) async throws -> UploadResult {
        try await base.upload(data: data, filename: filename)
    }
    func previewURL(port: Int, path: String) throws -> URL {
        try base.previewURL(port: port, path: path)
    }
    func tailscaleDevices() async throws -> TailscaleDevicesResponse {
        try await base.tailscaleDevices()
    }
    func audit(limit: Int) async throws -> [AuditEntry] { try await base.audit(limit: limit) }
}
