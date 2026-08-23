import Foundation
import OpenPawProtocol
import OpenPawTerminalCore

/// An in-memory `OpenPawBackend` seeded with one coherent afternoon of work.
///
/// This is not a mock that answers every call with an empty array. It is a *fixture host*: a real event stream
/// whose inbox is derived from that stream by the same `InboxProjection` the daemon uses, so the list a screen
/// renders here is the list the daemon would have served. Screens, `#Preview`s, the headless snapshot renderer
/// and the tests all read from this one scenario, which means a layout that looks right in a preview is right for
/// real data — the usual failure of preview fixtures (three-word strings, one-file diffs, no failure states) is
/// exactly what makes UI collapse in production.
///
/// Every timestamp derives from ``PreviewBackend/now``, a fixed instant, so snapshots are byte-stable.
public struct PreviewBackend: OpenPawBackend {

    /// The scenarios worth designing against. Not a difficulty dial — four genuinely different screens.
    public enum Scenario: String, Sendable, Hashable, CaseIterable {
        /// Three live sessions, a full inbox, a dirty repo. The default.
        case populated
        /// A paired host with nothing running. Exercises every empty state.
        case empty
        /// The tunnel is down. Every call throws, so error surfaces are real rather than imagined.
        case disconnected
        /// `populated`, narrowed to the one decision that matters: the destructive command awaiting approval.
        case reviewingDestructiveCommand
    }

    // MARK: - Fixed clock

    /// 2026-08-16T21:33:20Z. Fixed so a snapshot diff never fails on a clock tick.
    public static let now = Date(timeIntervalSince1970: 1_787_000_000)

    // MARK: - Session identity

    public static let claudeSession = SessionID(agent: .claudeCode, raw: "01JB7Q2ZK9TDW")
    public static let codexSession = SessionID(agent: .codex, raw: "cx-8842")
    public static let openCodeSession = SessionID(agent: .openCode, raw: "oc-local-3")
    /// A second Claude Code session whose only story is that it is *working*: one tool open, nothing waiting on
    /// a human. It exists because a pending decision outranks a running tool in the header, so the three other
    /// sessions can never show the working scanline.
    public static let workingSession = SessionID(agent: .claudeCode, raw: "01JB8M4RQ2VXP")

    public static var claudeSessionID: String { claudeSession.rawValue }
    public static var codexSessionID: String { codexSession.rawValue }
    public static var openCodeSessionID: String { openCodeSession.rawValue }
    public static var workingSessionID: String { workingSession.rawValue }

    // MARK: - Stored scenario

    public let scenario: Scenario
    public let healthInfo: HealthInfo
    public let sessionList: [SessionSummary]
    public let inboxItems: [InboxItem]
    public let repoList: [RepoSummary]
    public let statusByRepo: [String: RepoStatus]
    public let diffByRepo: [String: Diff]
    public let treeByPath: [String: [TreeEntry]]
    public let blobByPath: [String: Blob]
    public let searchHits: [ContentMatch]
    public let auditTrail: [AuditEntry]
    public let tailscaleDeviceResponse: TailscaleDevicesResponse
    public let transcripts: [String: [Event]]
    /// Set for `.disconnected`: every call throws this instead of answering.
    public let failure: HostClientError?
    /// Records what the UI actually sent, so a screen test can assert on the decision rather than on a redraw.
    public let journal = ResolveJournal()

    // MARK: - Construction

    public static func scenario(_ kind: Scenario) -> PreviewBackend {
        PreviewBackend(kind)
    }

    public init(_ kind: Scenario = .populated) {
        scenario = kind
        healthInfo = PreviewFixtures.health

        switch kind {
        case .populated:
            sessionList = PreviewFixtures.sessions
            inboxItems = PreviewFixtures.inboxItems
            transcripts = PreviewFixtures.transcripts
            repoList = PreviewFixtures.repos
            statusByRepo = PreviewFixtures.statuses
            diffByRepo = PreviewFixtures.diffs
            treeByPath = PreviewFixtures.tree
            blobByPath = PreviewFixtures.blobs
            searchHits = PreviewFixtures.searchHits
            auditTrail = PreviewFixtures.audit
            failure = nil
            tailscaleDeviceResponse = PreviewFixtures.tailscaleDevices

        case .reviewingDestructiveCommand:
            sessionList = PreviewFixtures.sessions
            // Narrowed to the two permission requests and nothing else. Keeping the read-only request pending
            // beside the destructive one is the point: side by side they show that the gate is conditional, not
            // a modal the app throws at every command.
            inboxItems = PreviewFixtures.inboxItems.map { item in
                guard item.status == .pending, item.category != .permission else { return item }
                var settled = item
                settled.status = .dismissed
                return settled
            }
            transcripts = PreviewFixtures.transcripts
            repoList = PreviewFixtures.repos
            statusByRepo = PreviewFixtures.statuses
            diffByRepo = PreviewFixtures.diffs
            treeByPath = PreviewFixtures.tree
            blobByPath = PreviewFixtures.blobs
            searchHits = PreviewFixtures.searchHits
            auditTrail = PreviewFixtures.audit
            failure = nil
            tailscaleDeviceResponse = PreviewFixtures.tailscaleDevices

        case .empty:
            sessionList = []
            inboxItems = []
            transcripts = [:]
            repoList = []
            statusByRepo = [:]
            diffByRepo = [:]
            treeByPath = [:]
            blobByPath = [:]
            searchHits = []
            auditTrail = []
            failure = nil
            tailscaleDeviceResponse = TailscaleDevicesResponse(version: 1, candidates: [])

        case .disconnected:
            sessionList = []
            inboxItems = []
            transcripts = [:]
            repoList = []
            statusByRepo = [:]
            diffByRepo = [:]
            treeByPath = [:]
            blobByPath = [:]
            searchHits = []
            auditTrail = []
            failure = .transport(TunnelClosed())
            tailscaleDeviceResponse = TailscaleDevicesResponse(version: 1, candidates: [])
        }
    }

    /// The error behind `.disconnected`: a forwarded port that has gone away. Named so the sentence the user
    /// reads is the sentence a real dropped tunnel produces.
    public struct TunnelClosed: Error, CustomStringConvertible, Sendable {
        public init() {}
        public var description: String { "could not connect to 127.0.0.1:8787" }
    }

    // MARK: - Fixture access

    public static func events(for sessionID: String) -> [Event] {
        PreviewFixtures.transcripts[sessionID] ?? []
    }

    public func events(for sessionID: String) -> [Event] {
        transcripts[sessionID] ?? []
    }

    // MARK: - A wired model

    /// A fully populated `OpenPawModel` whose transcripts are built by pushing the fixture events through
    /// `ingest(_:)`, exactly as the live SSE stream does. Synchronous, so it works in a `#Preview` body.
    @MainActor
    public static func model(_ kind: Scenario = .populated) -> OpenPawModel {
        let backend = PreviewBackend(kind)
        // Every scenario is a *paired* device, including `.empty` and `.disconnected`: you cannot be
        // disconnected from a host you do not have, and a header that reads "no host" beside a live connection
        // state is a contradiction rather than an empty state.
        let model = OpenPawModel(hostStore: HostStore(hosts: PreviewFixtures.hosts), backend: backend)
        model.health = backend.healthInfo
        model.sessions = backend.sessionList
        model.repos = backend.repoList
        // Seed the host's inbox first: `ingest` merges its projections onto this and keeps the action tokens,
        // which a locally derived item never has.
        model.inbox = backend.inboxItems

        for sessionID in [claudeSessionID, codexSessionID, openCodeSessionID, workingSessionID] {
            for event in backend.events(for: sessionID) {
                model.ingest(event)
            }
        }

        model.selectedSessionID = backend.sessionList.first?.sessionID
        model.selectedRepo = backend.repoList.first?.name

        switch kind {
        case .populated, .reviewingDestructiveCommand:
            // Matches the selected host's `lastSuccessfulTransport`, so the terminal header and the host row
            // agree about how this connection was made.
            model.connection = .connected(.mosh)
        case .empty:
            model.connection = .connected(.ssh)
        case .disconnected:
            model.connection = .disconnected(reason: "the forwarded port closed")
            model.present(HostClientError.transport(TunnelClosed()), while: "loading host state")
        }
        return model
    }

    // MARK: - OpenPawBackend

    private func requireTunnel() throws {
        if let failure { throw failure }
    }

    public func health() async throws -> HealthInfo {
        try requireTunnel()
        return healthInfo
    }

    public func sessions() async throws -> [SessionSummary] {
        try requireTunnel()
        return sessionList
    }

    public func inbox(status: InboxStatus?) async throws -> [InboxItem] {
        try requireTunnel()
        guard let status else { return inboxItems }
        return inboxItems.filter { $0.status == status }
    }

    /// Enforces the safety gate the way the daemon does — approving an item that demands the expanded command
    /// without acknowledging it is a 400, not a warning. A mis-wired screen therefore fails loudly in preview.
    public func resolve(
        item: InboxItem,
        action: ActionID,
        answer: String?,
        detailAcknowledged: Bool
    ) async throws -> ResolveResult {
        try requireTunnel()
        if action.isApproval, item.risk?.requiresDetailExpansion == true, !detailAcknowledged {
            throw HostClientError.badRequest(
                "detail_acknowledged must be true before approving \(item.id.rawValue)"
            )
        }
        guard item.actions.contains(action) else {
            throw HostClientError.badRequest("\(item.id.rawValue) does not offer \(action.rawValue)")
        }
        await journal.record(Decision(itemID: item.id.rawValue, action: action, answer: answer))
        return ResolveResult(status: "accepted", eventID: item.sourceEventID.rawValue)
    }

    /// Replays the fixture stream from `afterSeq`, then finishes. It does not hold the stream open: a preview
    /// whose stream never ends is a preview that never settles for the snapshot renderer.
    public func events(session: String?, afterSeq: UInt64?) -> AsyncThrowingStream<Event, any Error> {
        let ordered: [Event]
        if let session {
            ordered = events(for: session).sorted { $0.seq < $1.seq }
        } else {
            ordered = transcripts.values.flatMap { $0 }.sorted { $0.seq < $1.seq }
        }
        let pending = afterSeq.map { seq in ordered.filter { $0.seq > seq } } ?? ordered
        let error = failure
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            for event in pending { continuation.yield(event) }
            continuation.finish()
        }
    }

    public func repos() async throws -> [RepoSummary] {
        try requireTunnel()
        return repoList
    }

    public func repoStatus(_ repo: String) async throws -> RepoStatus {
        try requireTunnel()
        guard let status = statusByRepo[repo] else { throw HostClientError.notFound }
        return status
    }

    public func diff(repo: String, mode: DiffMode, path: String?) async throws -> Diff {
        try requireTunnel()
        guard let whole = diffByRepo[repo] else { throw HostClientError.notFound }
        guard let path else { return whole }
        let matching = whole.files.filter { $0.path == path }
        guard !matching.isEmpty else { throw HostClientError.notFound }
        return Diff(
            files: matching,
            additions: matching.reduce(0) { $0 + $1.additions },
            deletions: matching.reduce(0) { $0 + $1.deletions }
        )
    }

    public func tree(repo: String, ref: String, path: String) async throws -> [TreeEntry] {
        try requireTunnel()
        guard let entries = treeByPath[path] else { throw HostClientError.notFound }
        return entries
    }

    public func blob(repo: String, ref: String, path: String) async throws -> Blob {
        try requireTunnel()
        guard let blob = blobByPath[path] else { throw HostClientError.notFound }
        return blob
    }

    public func search(repo: String, query: String, path: String?) async throws -> [ContentMatch] {
        try requireTunnel()
        let needle = query.lowercased()
        return searchHits.filter { hit in
            guard needle.isEmpty || hit.text.lowercased().contains(needle) else { return false }
            guard let path, !path.isEmpty else { return true }
            return hit.path.hasPrefix(path)
        }
    }

    public func upload(data: Data, filename: String) async throws -> UploadResult {
        try requireTunnel()
        return UploadResult(
            path: "\(PreviewFixtures.repoPath)/.openpaw/uploads/\(filename)",
            bytes: UInt64(data.count),
            sha256: Hashing.sha256Hex(data)
        )
    }

    public func previewURL(port: Int, path: String) throws -> URL {
        try requireTunnel()
        guard healthInfo.previewPorts.contains(port) else {
            throw HostClientError.forbidden(capability: "preview:\(port)")
        }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: "http://127.0.0.1:\(port)\(suffix)") else {
            throw HostClientError.badRequest("cannot build a preview URL for \(path)")
        }
        return url
    }

    public func tailscaleDevices() async throws -> TailscaleDevicesResponse {
        try requireTunnel()
        return tailscaleDeviceResponse
    }

    public func audit(limit: Int) async throws -> [AuditEntry] {
        try requireTunnel()
        return Array(auditTrail.prefix(max(0, limit)))
    }
}

// MARK: - Resolve journal

/// One decision the UI sent to the host.
public struct Decision: Sendable, Hashable {
    public let itemID: String
    public let action: ActionID
    public let answer: String?

    public init(itemID: String, action: ActionID, answer: String?) {
        self.itemID = itemID
        self.action = action
        self.answer = answer
    }
}

/// What the UI sent, in order. An actor rather than a lock because `resolve` is already async, and because a
/// `Sendable` struct hiding a mutex is a puzzle for whoever reads it next.
public actor ResolveJournal {
    private var decisions: [Decision] = []

    public init() {}

    public func record(_ decision: Decision) { decisions.append(decision) }
    public func all() -> [Decision] { decisions }
    public func last() -> Decision? { decisions.last }
}

// MARK: - The scenario itself

/// The seeded afternoon, built once. Kept out of `PreviewBackend` so the data reads as data.
enum PreviewFixtures {
    static let tailscaleDevices = TailscaleDevicesResponse(version: 1, candidates: [
        TailscaleDeviceCandidate(id: "node-studio", displayName: "Studio", dnsName: "studio.tail123.ts.net", tailscaleIPs: ["100.64.0.10"], os: "macOS", online: true, lastSeen: PreviewBackend.now),
        TailscaleDeviceCandidate(id: "node-lab", displayName: "Lab mini", dnsName: nil, tailscaleIPs: ["100.64.0.11"], os: "linux", online: false, lastSeen: PreviewBackend.now.addingTimeInterval(-3600))
    ])


    static let repoPath = "/Users/dana/src/openpaw"

    // MARK: Hosts

    /// Two paired hosts, deliberately unalike: one on the LAN reached with a forwarded agent and a trusted key,
    /// one on a non-standard port using a keychain-referenced private key and pinning mosh. Between them the
    /// host list, the host editor and the terminal header all have something real to render.
    ///
    /// `id` is left to default. It is never displayed and list identity follows array order, so it cannot move a
    /// pixel in a snapshot.
    static let hosts: [HostRecord] = [
        HostRecord(
            nickname: "workshop",
            hostname: "10.0.0.4",
            port: 22,
            username: "dana",
            auth: .agentForwarding,
            // `lastSuccessfulTransport` rather than a pin: this host negotiated mosh once and `auto` now leads
            // with it, which is what `.connected(.mosh)` in the wired model reflects.
            lastSuccessfulTransport: .mosh,
            multiplexerPreference: .tmux,
            knownHosts: [
                KnownHostEntry(
                    keyType: "ssh-ed25519",
                    fingerprint: "SHA256:1nQ8xW4kGQ9tzB6pR2mYvL7dK0sFjH3cX5aE8uT1oZk",
                    addedAt: PreviewBackend.now.addingTimeInterval(-86_400 * 40)
                )
            ],
            tags: ["home"]
        ),
        HostRecord(
            nickname: "builder",
            hostname: "builder.internal",
            port: 2222,
            username: "ci",
            auth: builderAuth,
            preferredTransport: .mosh,
            multiplexerPreference: .zellij,
            // No pin yet, so connecting raises the unknown-host prompt — the path that must never be skippable.
            knownHosts: [],
            tags: ["ci", "linux"]
        ),
    ]

    /// `id_ed25519` is a literal keychain *identifier*: short, single-line and not key material, so the
    /// validating initialiser has nothing to reject. The fallback keeps the fixture a valid host rather than
    /// trapping, and is unreachable.
    static let builderAuth: AuthMethod = {
        guard let reference = try? KeychainReference(identifier: "id_ed25519") else {
            return .agentForwarding
        }
        return .privateKey(reference: reference, passphraseRef: nil)
    }()

    // MARK: Health

    static let health = HealthInfo(
        version: "0.4.1",
        protocolVersion: "1.0",
        agents: [.claudeCode, .codex, .openCode],
        capabilities: ["inbox.resolve", "repos.read", "repos.search", "uploads", "preview", "audit"],
        previewPorts: [3000, 5173, 8080],
        adapterVersions: [
            "claude-code": "claude-code/transcript-v1",
            "codex": "codex/jsonl-v2",
            "opencode": "opencode/events-v1",
        ]
    )

    // MARK: Sessions

    static let sessions: [SessionSummary] = [
        SessionSummary(
            sessionID: PreviewBackend.claudeSessionID,
            agent: .claudeCode,
            title: "Fix the flaking auth tests",
            cwd: repoPath,
            gitBranch: "feat/inbox-gate",
            multiplexerTarget: "tmux:openpaw:0.1",
            state: .waiting,
            lastEventAt: PreviewBackend.now.addingTimeInterval(-8),
            lastSeq: 18,
            pendingInbox: 4
        ),
        SessionSummary(
            sessionID: PreviewBackend.codexSessionID,
            agent: .codex,
            title: "Rebase onto main",
            cwd: repoPath,
            gitBranch: "chore/rebase",
            multiplexerTarget: "tmux:openpaw:1.0",
            state: .failed,
            lastEventAt: PreviewBackend.now.addingTimeInterval(-96),
            lastSeq: 7,
            pendingInbox: 1
        ),
        SessionSummary(
            sessionID: PreviewBackend.openCodeSessionID,
            agent: .openCode,
            title: "Draft the README rewrite",
            cwd: "/Users/dana/src/scratch",
            gitBranch: "main",
            multiplexerTarget: nil,
            state: .idle,
            lastEventAt: PreviewBackend.now.addingTimeInterval(-2_400),
            lastSeq: 4,
            pendingInbox: 1
        ),
        SessionSummary(
            sessionID: PreviewBackend.workingSessionID,
            agent: .claudeCode,
            title: "Rebuild the host workspace",
            cwd: repoPath,
            gitBranch: "main",
            multiplexerTarget: "tmux:openpaw:2.0",
            state: .working,
            lastEventAt: PreviewBackend.now.addingTimeInterval(-19),
            lastSeq: 6,
            pendingInbox: 0
        ),
    ]

    // MARK: Risk fixtures

    static let destructiveRisk = Risk(
        riskClass: .destructiveShell,
        requiresDetailExpansion: true,
        reasons: [
            "recursive force removal (rm -rf)",
            "runs as root via sudo",
            "one path resolves outside the repository",
        ]
    )

    static let readOnlyRisk = Risk(
        riskClass: .readOnly,
        requiresDetailExpansion: false,
        reasons: ["reads tracked files only"]
    )

    static let gitRisk = Risk(
        riskClass: .gitOperation,
        requiresDetailExpansion: true,
        reasons: ["rewrites published history (--force-with-lease)", "targets the default branch"]
    )

    static let testRisk = Risk(
        riskClass: .localWrite,
        requiresDetailExpansion: false,
        reasons: ["writes .pytest_cache inside the repository"]
    )

    /// Long, multi-argument, and one argument is outside the repo. The command the seal exists for.
    static let destructiveCommand =
        "sudo rm -rf /Users/dana/src/openpaw/.pytest_cache "
        + "/Users/dana/Library/Caches/pytest "
        + "/var/folders/9y/T/pytest-of-dana"

    // MARK: Transcripts

    static let transcripts: [String: [Event]] = [
        PreviewBackend.claudeSessionID: claudeEvents,
        PreviewBackend.codexSessionID: codexEvents,
        PreviewBackend.openCodeSessionID: openCodeEvents,
        PreviewBackend.workingSessionID: workingEvents,
    ]

    /// A Claude Code session mid-`pytest`: a plan underway, a file already edited, a test run still streaming,
    /// and three things waiting on the user.
    static let claudeEvents: [Event] = {
        var builder = EventBuilder(
            session: PreviewBackend.claudeSession,
            agent: .claudeCode,
            cwd: repoPath,
            branch: "feat/inbox-gate",
            target: "tmux:openpaw:0.1"
        )

        return [
            builder.next(742, "cc-start", .agentStarted(AgentLifecycle(
                reason: "resumed from tmux", title: "Fix the flaking auth tests"
            ))),
            builder.next(740, "cc-turn-user", .turnCompleted(TurnCompleted(
                turnID: "t1",
                role: .user,
                text: "The auth tests flake on CI about one run in four. Find the cause and fix it — "
                    + "don't just add a retry."
            ))),
            builder.next(736, "cc-think-1", .turnDelta(TurnDelta(
                turnID: "t2",
                delta: "One run in four smells like ordering, not timing. ",
                kind: .thinking
            ))),
            builder.next(735, "cc-think-2", .turnDelta(TurnDelta(
                turnID: "t2",
                delta: "If the token fixture is module-scoped it leaks between tests, and whichever test "
                    + "runs first decides what the rest see.",
                kind: .thinking
            ))),
            builder.next(731, "cc-plan", .planCreated(Plan(
                planID: "plan-auth",
                title: "Fix the flaking auth tests",
                steps: [
                    PlanStep(id: "s1", title: "Reproduce the flake with a fixed random seed", status: .completed),
                    PlanStep(id: "s2", title: "Read tests/conftest.py and test_auth.py", status: .completed),
                    PlanStep(
                        id: "s3",
                        title: "Narrow the token fixture from module to function scope",
                        status: .inProgress
                    ),
                    PlanStep(id: "s4", title: "Run the suite twenty times to confirm", status: .pending),
                    PlanStep(id: "s5", title: "Delete the retry decorator added in #418", status: .cancelled),
                ]
            ))),
            builder.next(724, "cc-turn-assistant", .turnCompleted(TurnCompleted(
                turnID: "t2",
                role: .assistant,
                text: "Reproduced it. `auth_token` is a module-scoped fixture, so the first test to mutate the "
                    + "claims dictionary changes what every later test sees. Under `-p no:randomly` it passes "
                    + "every time, which is why CI is the only place it shows up.\n\nI am narrowing the fixture "
                    + "to function scope and dropping the retry decorator that was hiding it.",
                thinking: "Module-scoped mutable fixture. Classic."
            ))),
            builder.next(700, "cc-tool-read", .toolStarted(ToolStarted(
                callID: "call-read-conftest",
                tool: "Read",
                summary: "Read tests/conftest.py",
                command: nil,
                paths: ["tests/conftest.py"],
                risk: readOnlyRisk
            ))),
            builder.next(699, "cc-tool-read-out", .toolOutput(ToolOutput(
                callID: "call-read-conftest",
                chunk: """
                    @pytest.fixture(scope="module")
                    def auth_token(app):
                        return issue_token(app, claims={"sub": "dana", "scope": "admin"})
                    """,
                stream: .stdout,
                truncated: false
            ))),
            builder.next(698, "cc-tool-read-done", .toolCompleted(ToolCompleted(
                callID: "call-read-conftest",
                exitCode: 0,
                durationMs: 41,
                summary: "42 lines"
            ))),
            builder.next(661, "cc-file-mod", .fileModified(FileChange(
                path: "tests/conftest.py",
                additions: 3,
                deletions: 2,
                bytes: 1_284,
                unifiedDiff: """
                    @@ -17,8 +17,9 @@ def app():
                    -@pytest.fixture(scope="module")
                    -def auth_token(app):
                    -    return issue_token(app, claims={"sub": "dana", "scope": "admin"})
                    +@pytest.fixture
                    +def auth_token(app):
                    +    # Function scope: each test mutates its own claims dict.
                    +    return issue_token(app, claims={"sub": "dana", "scope": "admin"})
                    """
            ))),
            builder.next(640, "cc-tool-pytest", .toolStarted(ToolStarted(
                callID: "call-pytest",
                tool: "Bash",
                summary: "Run the auth suite twenty times",
                command: "pytest -q tests/test_auth.py -p randomly --count 20",
                paths: ["tests/test_auth.py"],
                risk: testRisk
            ))),
            builder.next(636, "cc-tool-pytest-out-1", .toolOutput(ToolOutput(
                callID: "call-pytest",
                chunk: "........................................\n",
                stream: .stdout,
                truncated: false
            ))),
            builder.next(612, "cc-tool-pytest-out-2", .toolOutput(ToolOutput(
                callID: "call-pytest",
                chunk: """
                    ........................................
                    tests/test_auth.py::test_refresh_rotates_token PASSED
                    tests/test_auth.py::test_expired_token_is_rejected PASSED
                    """,
                stream: .stdout,
                truncated: false
            ))),
            builder.next(64, "cc-usage", .usageUpdated(UsageUpdated(
                inputTokens: 148_233,
                outputTokens: 9_818,
                cachedInputTokens: 121_004,
                costUSD: 2.41,
                rateLimitPercent: 62,
                rateLimitResetsAt: PreviewBackend.now.addingTimeInterval(4_140)
            ))),
            // 78% sits below InboxProjection.contextWarningPercent, so the header meter fills without the
            // inbox gaining a row. Meters and decisions are different jobs.
            builder.next(62, "cc-context", .contextUpdated(ContextUpdated(
                usedTokens: 156_000, maxTokens: 200_000, percentUsed: 78
            ))),
            builder.next(48, "cc-perm-readonly", .permissionRequested(PermissionRequested(
                requestID: "req-grep-secrets",
                tool: "Grep",
                summary: "Search the repository for hard-coded JWT secrets",
                command: "rg --files-with-matches 'JWT_SECRET' .",
                paths: ["."],
                risk: readOnlyRisk,
                actions: [.approveOnce, .approveAlways, .deny],
                expiresAt: PreviewBackend.now.addingTimeInterval(560)
            ))),
            builder.next(31, "cc-question", .questionRequested(QuestionRequested(
                requestID: "req-scope",
                question: "The retry decorator is also used by the billing tests. What should I do with those?",
                choices: [
                    "Leave the billing tests alone",
                    "Fix the billing fixtures the same way",
                    "Open a follow-up issue and stop here",
                ],
                allowsFreeText: true
            ))),
            builder.next(8, "cc-perm-destructive", .permissionRequested(PermissionRequested(
                requestID: "req-clear-cache",
                tool: "Bash",
                summary: "Clear the pytest caches before the confirmation run",
                command: destructiveCommand,
                paths: [
                    ".pytest_cache",
                    "/Users/dana/Library/Caches/pytest",
                    "/var/folders/9y/T/pytest-of-dana",
                ],
                risk: destructiveRisk,
                actions: [.approveOnce, .deny, .denyAlways, .stop],
                expiresAt: PreviewBackend.now.addingTimeInterval(880)
            ))),
        ]
    }()

    /// A Codex session whose force-push was denied and which then failed anyway. The denial is *history*: the
    /// inbox shows the failure, not the decision already taken.
    static let codexEvents: [Event] = {
        var builder = EventBuilder(
            session: PreviewBackend.codexSession,
            agent: .codex,
            cwd: repoPath,
            branch: "chore/rebase",
            target: "tmux:openpaw:1.0"
        )

        return [
            builder.next(420, "cx-start", .agentStarted(AgentLifecycle(
                reason: "started by hook", title: "Rebase onto main"
            ))),
            builder.next(415, "cx-turn-user", .turnCompleted(TurnCompleted(
                turnID: "t1", role: .user, text: "Rebase this branch onto main and push it."
            ))),
            builder.next(300, "cx-turn-assistant", .turnCompleted(TurnCompleted(
                turnID: "t2",
                role: .assistant,
                text: "The rebase applied cleanly across four commits. Pushing rewrites the remote branch, so "
                    + "I am asking before I do it."
            ))),
            builder.next(240, "cx-perm-push", .permissionRequested(PermissionRequested(
                requestID: "req-force-push",
                tool: "Bash",
                summary: "Force-push the rebased branch",
                command: "git push --force-with-lease origin main",
                paths: [],
                risk: gitRisk,
                actions: [.approveOnce, .deny, .stop],
                expiresAt: nil
            ))),
            builder.next(196, "cx-perm-resolved", .permissionResolved(PermissionResolved(
                requestID: "req-force-push",
                decision: .deny,
                decidedBy: .device,
                deviceID: "dev_dana_iphone"
            ))),
            builder.next(120, "cx-tool-push", .toolStarted(ToolStarted(
                callID: "call-push",
                tool: "Bash",
                summary: "Push the rebased branch without rewriting history",
                command: "git push origin chore/rebase",
                paths: [],
                risk: gitRisk
            ))),
            builder.next(96, "cx-tool-push-failed", .toolFailed(ToolFailed(
                callID: "call-push",
                error: "! [rejected] chore/rebase -> chore/rebase (non-fast-forward)\n"
                    + "hint: Updates were rejected because the tip of your current branch is behind.",
                exitCode: 1
            ))),
        ]
    }()

    /// An OpenCode session that finished cleanly a while ago. Its only inbox row is the completion notice — the
    /// lowest-priority thing in the queue, which is how the ordering gets exercised.
    static let openCodeEvents: [Event] = {
        var builder = EventBuilder(
            session: PreviewBackend.openCodeSession,
            agent: .openCode,
            cwd: "/Users/dana/src/scratch",
            branch: "main",
            target: nil
        )

        return [
            builder.next(2_900, "oc-start", .agentStarted(AgentLifecycle(
                title: "Draft the README rewrite"
            ))),
            builder.next(2_880, "oc-turn-user", .turnCompleted(TurnCompleted(
                turnID: "t1",
                role: .user,
                text: "Rewrite the README intro so it explains the local-first part properly."
            ))),
            builder.next(2_520, "oc-turn-assistant", .turnCompleted(TurnCompleted(
                turnID: "t2",
                role: .assistant,
                text: "Rewritten. The intro now leads with the fact that nothing leaves your machine, and the "
                    + "install section comes before the feature list."
            ))),
            builder.next(2_400, "oc-done", .agentCompleted(AgentLifecycle(
                reason: "README.md rewritten, 1 file changed", exitCode: 0, title: "README rewrite ready"
            ))),
        ]
    }()

    /// The plainly-working session: a `cargo build` left open, no decision outstanding.
    ///
    /// Both meters sit well clear of their inbox thresholds on purpose — `InboxProjection` raises a context
    /// warning at 85% and a rate-limit warning at 90%, and either one would put a pending item on a session whose
    /// entire job is to have none.
    static let workingEvents: [Event] = {
        var builder = EventBuilder(
            session: PreviewBackend.workingSession,
            agent: .claudeCode,
            cwd: repoPath,
            branch: "main",
            target: "tmux:openpaw:2.0"
        )

        return [
            builder.next(96, "wk-start", .agentStarted(AgentLifecycle(
                reason: "started from the composer", title: "Rebuild the host workspace"
            ))),
            builder.next(94, "wk-turn-user", .turnCompleted(TurnCompleted(
                turnID: "t1",
                role: .user,
                text: "The host crate stopped compiling after the reqwest feature change. Rebuild the workspace "
                    + "and tell me what broke."
            ))),
            builder.next(61, "wk-turn-assistant", .turnCompleted(TurnCompleted(
                turnID: "t2",
                role: .assistant,
                text: "Building the whole workspace now. A clean pass takes about two minutes here, so I will "
                    + "report the first real error rather than the cascade after it."
            ))),
            // Left open deliberately: no completion, no failure. This is the row the scanline belongs to.
            builder.next(43, "wk-tool-cargo", .toolStarted(ToolStarted(
                callID: "call-cargo-build",
                tool: "Bash",
                summary: "Rebuild every crate in the workspace",
                command: "cargo build --workspace --locked",
                paths: ["host/Cargo.toml"],
                risk: testRisk
            ))),
            builder.next(28, "wk-usage", .usageUpdated(UsageUpdated(
                inputTokens: 21_408,
                outputTokens: 1_902,
                cachedInputTokens: 14_220,
                costUSD: 0.34,
                rateLimitPercent: 12.5,
                rateLimitResetsAt: PreviewBackend.now.addingTimeInterval(5_600)
            ))),
            builder.next(19, "wk-context", .contextUpdated(ContextUpdated(
                usedTokens: 43_030, maxTokens: 272_000, percentUsed: 15.8
            ))),
        ]
    }()

    /// Assigns dense, ascending `seq` values and the content-addressed `event_id` the host would derive.
    private struct EventBuilder {
        let session: SessionID
        let agent: AgentKind
        let cwd: String
        let branch: String
        let target: String?
        private var seq: UInt64 = 0

        init(session: SessionID, agent: AgentKind, cwd: String, branch: String, target: String?) {
            self.session = session
            self.agent = agent
            self.cwd = cwd
            self.branch = branch
            self.target = target
        }

        mutating func next(_ secondsAgo: TimeInterval, _ sourceKey: String, _ body: Body) -> Event {
            seq += 1
            return Event(
                version: "1.0",
                eventID: EventID(session: session, sourceKey: sourceKey),
                sessionID: session,
                agent: agent,
                seq: seq,
                timestamp: PreviewBackend.now.addingTimeInterval(-secondsAgo),
                cwd: cwd,
                gitBranch: branch,
                multiplexerTarget: target,
                body: body
            )
        }
    }

    // MARK: Inbox

    static let inboxItems: [InboxItem] = projectedInbox(from: transcripts)

    /// Derives the inbox from the transcripts with the daemon's own projection, then applies the two things a
    /// projection cannot know: the one-time action tokens, and decisions already taken.
    static func projectedInbox(from transcripts: [String: [Event]]) -> [InboxItem] {
        let ordered = transcripts.values.flatMap { $0 }.sorted {
            ($0.timestamp, $0.seq) < ($1.timestamp, $1.seq)
        }

        var settled: [String: ActionID] = [:]
        for event in ordered {
            switch event.body {
            case .permissionResolved(let resolution):
                settled[resolution.requestID] = resolution.decision
            case .questionAnswered(let answered):
                settled[answered.requestID] = .answer
            default:
                break
            }
        }

        return ordered.compactMap { event in
            guard var item = InboxProjection.from(event: event) else { return nil }
            item.actionToken = "tok_" + item.id.rawValue.suffix(12)
            if let requestID = item.requestID, let decision = settled[requestID] {
                item.status = .resolved
                item.resolution = decision.rawValue
            }
            return item
        }
    }

    // MARK: Repositories

    static let repos: [RepoSummary] = [
        RepoSummary(
            name: "openpaw", path: repoPath, branch: "feat/inbox-gate",
            dirty: true, ahead: 2, behind: 0
        ),
        RepoSummary(
            name: "scratch", path: "/Users/dana/src/scratch", branch: "main",
            dirty: false, ahead: 0, behind: 3
        ),
    ]

    static let statuses: [String: RepoStatus] = [
        "openpaw": RepoStatus(
            branch: "feat/inbox-gate",
            ahead: 2,
            behind: 0,
            staged: [
                StatusEntry(path: "tests/conftest.py", change: .modified),
                StatusEntry(path: "docs/testing.md", oldPath: "docs/tests.md", change: .renamed),
            ],
            unstaged: [
                StatusEntry(path: "src/openpaw/auth.py", change: .modified),
                StatusEntry(path: "tests/fixtures/token.bin", change: .modified),
            ],
            untracked: [
                StatusEntry(path: "tests/test_auth_regression.py", change: .added)
            ]
        ),
        "scratch": RepoStatus(branch: "main", ahead: 0, behind: 3),
    ]

    // MARK: Diff

    static let diffs: [String: Diff] = [
        "openpaw": workingTreeDiff,
        "scratch": Diff(files: [], additions: 0, deletions: 0),
    ]

    /// Two hunks in one modified file, a rename, and a binary file: the three cases a diff viewer gets wrong.
    static let workingTreeDiff: Diff = {
        let firstHunk = Hunk(
            header: "@@ -14,10 +14,11 @@ def app():",
            oldStart: 14,
            oldLines: 10,
            newStart: 14,
            newLines: 11,
            lines: [
                DiffLine(kind: .context, text: "    app.config[\"TESTING\"] = True", oldLine: 14, newLine: 14),
                DiffLine(kind: .context, text: "    return app", oldLine: 15, newLine: 15),
                DiffLine(kind: .context, text: "", oldLine: 16, newLine: 16),
                DiffLine(kind: .removed, text: "@pytest.fixture(scope=\"module\")", oldLine: 17),
                DiffLine(kind: .removed, text: "def auth_token(app):", oldLine: 18),
                DiffLine(kind: .added, text: "@pytest.fixture", newLine: 17),
                DiffLine(kind: .added, text: "def auth_token(app):", newLine: 18),
                DiffLine(
                    kind: .added,
                    text: "    # Function scope: each test mutates its own claims dict.",
                    newLine: 19
                ),
                DiffLine(
                    kind: .context,
                    text: "    return issue_token(app, claims={\"sub\": \"dana\"})",
                    oldLine: 19,
                    newLine: 20
                ),
            ]
        )
        let secondHunk = Hunk(
            header: "@@ -48,7 +49,6 @@ def client(app):",
            oldStart: 48,
            oldLines: 7,
            newStart: 49,
            newLines: 6,
            lines: [
                DiffLine(kind: .context, text: "def client(app):", oldLine: 48, newLine: 49),
                DiffLine(kind: .context, text: "    with app.test_client() as c:", oldLine: 49, newLine: 50),
                DiffLine(kind: .removed, text: "        # flaky: retry up to three times", oldLine: 50),
                DiffLine(kind: .removed, text: "        @flaky(max_runs=3)", oldLine: 51),
                DiffLine(kind: .context, text: "        yield c", oldLine: 52, newLine: 51),
                DiffLine(kind: .noNewline, text: "\\ No newline at end of file", oldLine: 53, newLine: 52),
            ]
        )
        let renameHunk = Hunk(
            header: "@@ -1,4 +1,4 @@",
            oldStart: 1,
            oldLines: 4,
            newStart: 1,
            newLines: 4,
            lines: [
                DiffLine(kind: .removed, text: "# Running the tests", oldLine: 1),
                DiffLine(kind: .added, text: "# Testing", newLine: 1),
                DiffLine(kind: .context, text: "", oldLine: 2, newLine: 2),
                DiffLine(
                    kind: .context,
                    text: "Run `pytest -q`. The suite is deterministic under `-p randomly`.",
                    oldLine: 3,
                    newLine: 3
                ),
            ]
        )

        let files = [
            FileDiff(
                path: "tests/conftest.py",
                change: .modified,
                additions: 4,
                deletions: 4,
                hunks: [firstHunk, secondHunk]
            ),
            FileDiff(
                path: "docs/testing.md",
                oldPath: "docs/tests.md",
                change: .renamed,
                additions: 1,
                deletions: 1,
                hunks: [renameHunk]
            ),
            FileDiff(
                path: "tests/fixtures/token.bin",
                change: .modified,
                additions: 0,
                deletions: 0,
                binary: true
            ),
        ]
        return Diff(
            files: files,
            additions: files.reduce(0) { $0 + $1.additions },
            deletions: files.reduce(0) { $0 + $1.deletions }
        )
    }()

    // MARK: Tree — three levels deep, keyed by the directory that was listed

    static let tree: [String: [TreeEntry]] = [
        "": [
            TreeEntry(name: "src", path: "src", kind: .directory),
            TreeEntry(name: "tests", path: "tests", kind: .directory),
            TreeEntry(name: "docs", path: "docs", kind: .directory),
            TreeEntry(name: "README.md", path: "README.md", kind: .file, size: 4_812),
            TreeEntry(name: "pyproject.toml", path: "pyproject.toml", kind: .file, size: 1_106),
            TreeEntry(name: "latest", path: "latest", kind: .symlink, size: nil, isSymlink: true),
        ],
        "src": [
            TreeEntry(name: "openpaw", path: "src/openpaw", kind: .directory)
        ],
        "src/openpaw": [
            TreeEntry(name: "auth.py", path: "src/openpaw/auth.py", kind: .file, size: 6_204),
            TreeEntry(name: "cli.py", path: "src/openpaw/cli.py", kind: .file, size: 2_940),
            TreeEntry(name: "__init__.py", path: "src/openpaw/__init__.py", kind: .file, size: 118),
        ],
        "tests": [
            TreeEntry(name: "fixtures", path: "tests/fixtures", kind: .directory),
            TreeEntry(name: "conftest.py", path: "tests/conftest.py", kind: .file, size: 1_284),
            TreeEntry(name: "test_auth.py", path: "tests/test_auth.py", kind: .file, size: 3_402),
        ],
        "tests/fixtures": [
            TreeEntry(name: "token.bin", path: "tests/fixtures/token.bin", kind: .file, size: 512)
        ],
        "docs": [
            TreeEntry(name: "testing.md", path: "docs/testing.md", kind: .file, size: 902)
        ],
    ]

    // MARK: Blobs

    static let blobs: [String: Blob] = [
        "src/openpaw/auth.py": Blob(
            path: "src/openpaw/auth.py",
            bytes: 6_204,
            mime: "text/x-python",
            truncated: false,
            content: .text(pythonBlob)
        ),
        "tests/fixtures/token.bin": Blob(
            path: "tests/fixtures/token.bin",
            bytes: 512,
            mime: "application/octet-stream",
            truncated: false,
            content: .binary(sha256: "9f2c41e0b8a5d37c6e1f04b9a7d258e3c0b6f14a8d92e5730fb1c48a6d20e9f5")
        ),
    ]

    static let pythonBlob = """
        \"\"\"Token issue and verification.\"\"\"

        import time
        from dataclasses import dataclass

        DEFAULT_TTL = 900  # seconds


        @dataclass(frozen=True)
        class Claims:
            sub: str
            scope: str = "user"
            issued_at: float = 0.0


        def issue_token(app, claims: dict) -> str:
            # The secret comes from the environment, never from the repository.
            secret = app.config["JWT_SECRET"]
            payload = Claims(**claims, issued_at=time.time())
            return _sign(payload, secret)
        """

    // MARK: Search

    static let searchHits: [ContentMatch] = [
        ContentMatch(
            path: "src/openpaw/auth.py",
            line: 18,
            text: "    secret = app.config[\"JWT_SECRET\"]"
        ),
        ContentMatch(
            path: "tests/conftest.py",
            line: 9,
            text: "    app.config[\"JWT_SECRET\"] = \"test-only-secret\""
        ),
        ContentMatch(
            path: "docs/testing.md",
            line: 24,
            text: "Set `JWT_SECRET` before running the suite locally."
        ),
        ContentMatch(
            path: ".github/workflows/ci.yml",
            line: 41,
            text: "          JWT_SECRET: ${{ secrets.JWT_SECRET }}"
        ),
    ]

    // MARK: Audit

    static let audit: [AuditEntry] = [
        AuditEntry(
            at: PreviewBackend.now.addingTimeInterval(-196),
            deviceID: "dev_dana_iphone",
            action: "inbox.resolve",
            target: "req-force-push",
            result: "deny"
        ),
        AuditEntry(
            at: PreviewBackend.now.addingTimeInterval(-1_180),
            deviceID: "dev_dana_iphone",
            action: "inbox.resolve",
            target: "req-read-conftest",
            result: "approve_once"
        ),
        AuditEntry(
            at: PreviewBackend.now.addingTimeInterval(-3_600),
            deviceID: "dev_dana_ipad",
            action: "repos.search",
            target: "openpaw:JWT_SECRET",
            result: "ok"
        ),
        AuditEntry(
            at: PreviewBackend.now.addingTimeInterval(-7_200),
            deviceID: nil,
            action: "pairing.complete",
            target: "dev_dana_ipad",
            result: "ok"
        ),
    ]
}
