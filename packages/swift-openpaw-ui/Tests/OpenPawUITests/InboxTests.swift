import Foundation
import OpenPawProtocol
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
            requestID: nil,
            actionToken: "tok_test",
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
        #expect(InboxCopy.decision(for: dismissed) == "Dismissed on this device. The agent was not answered.")
    }
}
