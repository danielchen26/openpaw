import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI
import Testing

@testable import OpenPawUI

// MARK: - Host draft validation

/// The editor's validation is the one piece of the shell that is worth testing without a screen: it decides whether
/// a host can be saved at all, and every rule below corresponds to a mistake a person actually makes.
@Suite("Host draft validation")
struct HostDraftValidationTests {

    /// A host that should save without complaint. Every rejection test below is this value with one field spoiled,
    /// so a failure names the rule that broke rather than a fixture that drifted.
    private func draft(
        hostname: String = "10.0.0.4",
        port: Int = 22,
        username: String = "chet"
    ) -> HostDraft {
        HostDraft(nickname: "workshop", hostname: hostname, port: port, username: username)
    }

    @Test("A complete draft has nothing to report")
    func acceptsANormalRecord() {
        #expect(draft().validate().isEmpty)
        #expect(draft().isValid)
    }

    @Test("Port zero is rejected, and the message names the range")
    func rejectsPortZero() {
        let issues = draft(port: 0).validate()
        #expect(issues.contains { $0.field == .port })
        #expect(issues.first { $0.field == .port }?.message.contains("1 and 65535") == true)
    }

    @Test("A port above the 16-bit range is rejected")
    func rejectsPortAbove65535() {
        #expect(draft(port: 70_000).validate().contains { $0.field == .port })
        // The boundary itself is legal: 65535 is a port, 65536 is not.
        #expect(draft(port: 65_535).validate().isEmpty)
        #expect(draft(port: 65_536).validate().contains { $0.field == .port })
        #expect(draft(port: 1).validate().isEmpty)
    }

    @Test("An empty hostname is rejected")
    func rejectsAnEmptyHostname() {
        #expect(draft(hostname: "").validate().contains { $0.field == .hostname })
        // Whitespace is not a hostname either, which is the mistake a paste makes.
        #expect(draft(hostname: "   ").validate().contains { $0.field == .hostname })
    }

    @Test("A username containing a space is rejected")
    func rejectsAUsernameWithASpace() {
        let issues = draft(username: "chet ian").validate()
        #expect(issues.contains { $0.field == .username })
        #expect(issues.first { $0.field == .username }?.message.contains("cannot contain spaces") == true)
    }

    @Test("An empty username is rejected separately from a spaced one")
    func rejectsAnEmptyUsername() {
        #expect(draft(username: "").validate().contains { $0.field == .username })
    }

    @Test("Every complaint is reported at once, not one per save")
    func reportsEveryProblemTogether() {
        let issues = draft(hostname: "", port: 0, username: "no one").validate()
        #expect(issues.filter { $0.field == .hostname }.count == 1)
        #expect(issues.filter { $0.field == .port }.count == 1)
        #expect(issues.filter { $0.field == .username }.count == 1)
    }

    @Test("Geometry and keepalive are bounded")
    func rejectsImpossibleSessionMechanics() {
        var wide = draft()
        wide.profile.columns = 5_000
        #expect(wide.validate().contains { $0.field == .geometry })

        var negative = draft()
        negative.profile.keepaliveSeconds = -1
        #expect(negative.validate().contains { $0.field == .keepalive })

        var off = draft()
        off.profile.keepaliveSeconds = 0
        #expect(off.validate().isEmpty)
    }

    @Test("A jump hop is held to the same rules as the host")
    func rejectsABrokenJumpHop() {
        var withHop = draft()
        withHop.jumpHosts = [JumpHop(hostname: "", port: 0, username: "bad name")]
        let issues = withHop.validate().filter { $0.field == .jumpHost }
        #expect(issues.count == 3)
        #expect(issues.allSatisfy { $0.hopIndex == 0 })
        #expect(issues.contains { $0.message.contains("Hop 1") })
    }

    @Test("A credential kind that needs a keychain name says so")
    func rejectsAMissingKeychainReference() {
        var key = draft()
        key.authKind = .privateKey
        #expect(key.validate().contains { $0.field == .credential })
        key.keyReference = "id_ed25519"
        #expect(key.validate().isEmpty)
    }

    @Test("A blank nickname falls back to the hostname instead of failing")
    func nicknameIsOptional() {
        var anonymous = draft()
        anonymous.nickname = ""
        #expect(anonymous.validate().isEmpty)
        #expect(anonymous.resolvedNickname == "10.0.0.4")
    }

    @Test("A draft survives the trip through a record and back")
    func roundTripsThroughARecord() throws {
        var original = draft()
        original.tags = ["work"]
        original.multiplexer = .tmux
        original.preferredTransport = .ssh
        original.profile.columns = 120
        original.profile.rows = 40

        let record = try original.record()
        let reread = HostDraft(record: record, profile: original.profile)

        #expect(reread.hostname == original.hostname)
        #expect(reread.port == original.port)
        #expect(reread.username == original.username)
        #expect(reread.nickname == original.resolvedNickname)
        #expect(reread.tags == original.tags)
        #expect(reread.multiplexer == .tmux)
        #expect(reread.preferredTransport == .ssh)
        #expect(reread.profile.columns == 120)
        #expect(reread.profile.rows == 40)
    }

    @Test("Editing an existing host keeps its pinned keys")
    func editingPreservesPinnedKeys() throws {
        let pin = KnownHostEntry(keyType: "ssh-ed25519", fingerprint: "SHA256:abc", addedAt: Date())
        let existing = HostRecord(
            nickname: "workshop", hostname: "10.0.0.4", username: "chet", auth: .agentForwarding,
            knownHosts: [pin])
        var edited = HostDraft(record: existing)
        edited.nickname = "workshop mk2"

        let saved = try edited.record(id: existing.id, existing: existing)
        #expect(saved.id == existing.id)
        #expect(saved.knownHosts == [pin])
        #expect(saved.nickname == "workshop mk2")
    }

    @Test("The session profile reaches the connection configuration")
    func configurationCarriesTheProfile() throws {
        var source = draft()
        source.profile.terminalType = "xterm-kitty"
        source.profile.columns = 200
        source.profile.rows = 50
        source.profile.keepaliveSeconds = 45
        source.jumpHosts = [JumpHop(hostname: "bastion.example.com", port: 2_222, username: "")]

        let configuration = try source.configuration()
        #expect(configuration.terminalType == "xterm-kitty")
        #expect(configuration.initialSize.columns == 200)
        #expect(configuration.initialSize.rows == 50)
        #expect(configuration.keepaliveInterval == .seconds(45))
        #expect(configuration.jumpHosts.count == 1)
        #expect(configuration.jumpHosts[0].host == "bastion.example.com")
        #expect(configuration.jumpHosts[0].port == 2_222)
        // A hop with no username of its own inherits the host's, rather than dialling as root by accident.
        #expect(configuration.jumpHosts[0].username == "chet")
    }

    @Test("Keepalive off means no interval at all, not a zero one")
    func keepaliveOffProducesNoInterval() throws {
        var source = draft()
        source.profile.keepaliveSeconds = 0
        #expect(try source.configuration().keepaliveInterval == nil)
    }

    @Test("A pasted private key is refused rather than persisted")
    func refusesInlinedKeyMaterial() {
        var pasted = draft()
        pasted.authKind = .privateKey
        pasted.keyReference = "-----BEGIN OPENSSH PRIVATE KEY-----"
        // Validation passes: the field is non-empty. The keychain reference is what refuses it.
        #expect(pasted.validate().isEmpty)
        #expect(throws: (any Error).self) { try pasted.record() }
    }
}

// MARK: - Host key gate

@Suite("Host key prompt")
struct HostKeyPromptTests {

    @Test("An unknown key can be trusted after the user compares it")
    func unknownAllowsTrust() {
        let prompt = HostKeyPrompt(host: "workshop:22", verdict: .unknown(fingerprint: "SHA256:abc"))
        #expect(prompt.allowsTrust)
    }

    @Test("A changed key can never be trusted from inside the app")
    func changedNeverAllowsTrust() {
        let prompt = HostKeyPrompt(
            host: "workshop:22", verdict: .changed(expected: "SHA256:abc", actual: "SHA256:def"))
        #expect(prompt.allowsTrust == false)
        // The transport agrees: this is a block, not a warning.
        #expect(prompt.verdict.isBlocking)
    }

    @Test("An already trusted key has nothing to accept")
    func trustedOffersNoDecision() {
        #expect(HostKeyPrompt(host: "workshop:22", verdict: .trusted).allowsTrust == false)
    }
}

// MARK: - Navigation

@Suite("Root navigation")
struct RootNavigationTests {

    @Test("A compact width gets a tab bar")
    func compactUsesTabs() {
        #expect(RootNavigationStyle.style(for: .compact) == .tabs)
    }

    @Test("A regular width gets a sidebar and a detail pane")
    func regularUsesSplit() {
        #expect(RootNavigationStyle.style(for: .regular) == .split)
    }

    @Test("The six destinations are stable and complete, with Home first")
    func destinationsAreComplete() {
        #expect(ShellDestination.allCases.count == 6)
        #expect(ShellDestination.allCases.map(\.rawValue) == ["home", "terminal", "sessions", "inbox", "repo", "settings"])
        let home = ShellDestination.allCases[0]
        #expect(home.title == "Home")
        #expect(home.glyph == "house")
        #expect(home.pushesDetail)
        #expect(RepoPane.allCases.map(\.rawValue) == ["diff", "files", "preview", "status"])
    }

    @MainActor
    @Test("The shell starts on Home instead of opening a remote terminal")
    func routerDefaultsToHome() {
        let router = ShellRouter()
        #expect(router.destination.rawValue == "home")
    }

    @MainActor
    @Test("Remote refresh needs a selected host and a backend")
    func remoteRefreshRequiresHostAndBackend() {
        let host = hostRecord()
        let backend = RecordingBackend()

        let empty = OpenPawModel(hostStore: HostStore(), backend: backend)
        #expect(empty.canRefreshRemoteState == false)

        let missingBackend = OpenPawModel(hostStore: HostStore(hosts: [host]))
        #expect(missingBackend.canRefreshRemoteState == false)

        let ready = OpenPawModel(hostStore: HostStore(hosts: [host]), backend: backend)
        ready.connection = .connected(.ssh)
        #expect(ready.canRefreshRemoteState)

        ready.selectedHostID = UUID()
        #expect(ready.canRefreshRemoteState == false)
    }

    @MainActor
    @Test("Host switch and same-host reconnect advance the connection generation")
    func connectionGenerationInvalidatesSessionRows() {
        let first = hostRecord()
        let second = HostRecord(nickname: "bench", hostname: "10.0.0.5", username: "chet", auth: .agentForwarding)
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, second]))
        let initial = model.connectionGeneration

        model.connection = .connected(.ssh)
        #expect(model.connectionGeneration == initial + 1)

        model.connection = .idle
        model.connection = .connected(.ssh)
        #expect(model.connectionGeneration == initial + 3)

        model.selectedHostID = second.id
        #expect(model.connectionGeneration > initial + 3)
    }

    @MainActor
    @Test("Selecting a saved host is a disconnecting transaction, not an implicit connection")
    func selectingHostClearsEveryHostScopedModelValueBeforeAnExplicitConnect() async throws {
        let model = PreviewBackend.model(.populated)
        let terminal = RecordingTerminalBackend()
        model.attach(backend: model.backend, terminal: terminal)
        let second = HostRecord(
            nickname: "Build server",
            hostname: "build.tailnet.example",
            username: "openpaw",
            auth: .agentForwarding,
            preferredTransport: .ssh
        )
        model.hostStore.upsert(second)
        let generation = model.connectionGeneration

        #expect(model.health != nil)
        #expect(!model.sessions.isEmpty)
        #expect(!model.inbox.isEmpty)
        #expect(!model.repos.isEmpty)
        #expect(model.selectedSessionID != nil)
        #expect(model.selectedRepo != nil)

        await model.selectHost(second.id)

        #expect(model.selectedHostID == second.id)
        #expect(model.connectionGeneration > generation)
        #expect(model.connection == .disconnected(reason: "Host selection changed"))
        #expect(model.health == nil)
        #expect(model.sessions.isEmpty)
        #expect(model.selectedSessionID == nil)
        #expect(model.inbox.isEmpty)
        #expect(model.repos.isEmpty)
        #expect(model.selectedRepo == nil)
        #expect(terminal.connectedHosts.isEmpty)
        #expect(terminal.disconnectCount == 1)

        await model.connectSelectedHost()
        #expect(terminal.connectedHosts == [second.id])
    }

    @MainActor
    @Test("A host change rejects a refresh that belonged to the previous host")
    func hostSelectionStalesAnInflightRefresh() async throws {
        let first = hostRecord()
        let second = HostRecord(
            nickname: "Build server", hostname: "build", username: "openpaw", auth: .agentForwarding)
        let backend = RecordingBackend()
        backend.refreshDelayNanoseconds = 50_000_000
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, second]), backend: backend)
        model.connection = .connected(.ssh)

        let refresh = Task { await model.refresh() }
        while backend.callCount("health") == 0 { await Task.yield() }
        await model.selectHost(second.id)
        await refresh.value

        #expect(model.selectedHostID == second.id)
        #expect(model.health == nil)
        #expect(model.sessions.isEmpty)
        #expect(model.inbox.isEmpty)
        #expect(model.repos.isEmpty)
    }

    @MainActor
    @Test("A newer host selection waits for an older suspended teardown")
    func newerHostSelectionCannotBeDisconnectedByAnOlderTeardown() async {
        let initial = HostRecord(nickname: "Initial", hostname: "initial", username: "dev", auth: .agentForwarding)
        let first = HostRecord(nickname: "First", hostname: "first", username: "dev", auth: .agentForwarding)
        let second = HostRecord(nickname: "Second", hostname: "second", username: "dev", auth: .agentForwarding)
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(
            hostStore: HostStore(hosts: [initial, first, second]),
            backend: RecordingBackend(),
            terminal: terminal)
        await model.connectSelectedHost()
        #expect(terminal.activeHostID == initial.id)

        let gate = SuspendedLifecycleGate()
        terminal.suspendedDisconnectNumber = terminal.disconnectCount + 1
        terminal.disconnectGate = gate
        let staleSelection = Task { @MainActor in await model.selectHost(first.id) }
        await gate.waitUntilStarted()

        let currentSelection = Task { @MainActor in await model.selectHost(second.id) }
        for _ in 0..<100 where terminal.disconnectCount < 3 {
            await Task.yield()
        }

        #expect(model.selectedHostID == second.id)
        #expect(model.isSwitchingHost, "the current selection must wait for the older teardown to finish")
        #expect(
            terminal.disconnectCount == 2,
            "a newer selection must not start a second teardown while the older one is suspended")

        await gate.release()
        await staleSelection.value
        await currentSelection.value
        let lease = await model.connectSelectedHost()

        #expect(lease?.hostID == second.id)
        #expect(terminal.activeHostID == second.id)
        #expect(model.selectedHostID == second.id)
        #expect(model.isSwitchingHost == false)
    }

    @MainActor
    @Test("Host changes clear every host-scoped shell route while keeping the root destination")
    func routerInvalidatesHostScopedRoutes() {
        let router = ShellRouter()
        router.destination = .repo
        router.sessionID = "session-old"
        router.approvalItemID = "inbox-old"
        router.repoPane = .preview
        router.repoFocusPath = "Sources/Old.swift"
        router.diffMode = .staged

        router.invalidateHostScopedState()

        #expect(router.destination == .repo)
        #expect(router.sessionID == nil)
        #expect(router.approvalItemID == nil)
        #expect(router.repoPane == .diff)
        #expect(router.repoFocusPath == nil)
        #expect(router.diffMode == .workingTree)
    }

    @MainActor
    @Test("A same-host connection generation change clears the attached multiplexer route")
    func routerInvalidatesConnectionScopedRoutes() {
        let router = ShellRouter()
        router.destination = .terminal
        router.attachedMultiplexerSession = .target("$old", kind: .tmux)

        router.invalidateConnectionScopedState()

        #expect(router.destination == .terminal)
        #expect(router.attachedMultiplexerSession == nil)
    }

    @MainActor
    @Test("Session root intents centralize transcript, terminal, and workspace resume routing")
    func sessionRootIntentsOwnTheirRouteMutations() {
        let model = PreviewBackend.model(.populated)
        let router = ShellRouter()

        router.perform(.openSessionTranscript("session-next"), model: model)
        #expect(router.destination == .sessions)
        #expect(router.sessionID == "session-next")
        #expect(model.selectedSessionID == "session-next")

        router.perform(.openTerminalSession, model: model)
        #expect(router.destination == .terminal)
        #expect(router.sessionID == nil)

        let remote = RemoteSession.target("$9", kind: .tmux)
        router.perform(.attachSession(remote), model: model)
        #expect(router.destination == .terminal)
        #expect(router.attachedMultiplexerSession == remote)

        router.perform(.resumeWorkspace(.repository("openpaw")), model: model)
        #expect(router.destination == .repo)
        #expect(model.selectedRepo == "openpaw")

        router.perform(.resumeWorkspace(.agentSession("session-restored")), model: model)
        #expect(router.destination == .sessions)
        #expect(router.sessionID == "session-restored")
        #expect(model.selectedSessionID == "session-restored")

        router.invalidateHostScopedState()
        #expect(router.attachedMultiplexerSession == nil)
    }

    @MainActor
    @Test("A disconnected Home resume connects and preserves the requested repository intent")
    func disconnectedHomeResumePreservesItsIntentAfterConnection() async {
        let first = hostRecord()
        let host = HostRecord(nickname: "Build", hostname: "build", username: "dev", auth: .agentForwarding)
        let backend = RecordingBackend()
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, host]), backend: backend, terminal: terminal)

        let resolution = await HomeResumeCoordinator.resolve(
            host: host,
            intent: .repository("openpaw"),
            model: model)

        #expect(resolution?.intent == .repository("openpaw"))
        #expect(resolution.map { model.ownsConnection($0.connection) } == true)
        #expect(model.selectedHostID == host.id)
        #expect(model.connection.isConnected)
        #expect(terminal.connectedHosts == [host.id])
    }

    @MainActor
    @Test("A Home resume whose host changes while connecting is discarded")
    func staleHomeResumeDoesNotRouteAfterConnection() async {
        let first = HostRecord(nickname: "One", hostname: "one", username: "dev", auth: .agentForwarding)
        let second = HostRecord(nickname: "Two", hostname: "two", username: "dev", auth: .agentForwarding)
        let gate = SuspendedLifecycleGate()
        let backend = LifecycleRecordingBackend()
        backend.suspendedHostID = first.id
        backend.connectGate = gate
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, second]), backend: backend, terminal: terminal)

        let resume = Task { @MainActor in
            await HomeResumeCoordinator.resolve(
                host: first,
                intent: .agentSession("session-first"),
                model: model)
        }
        await gate.waitUntilStarted()
        await model.selectHost(second.id)
        await gate.release()

        #expect(await resume.value == nil)
        #expect(model.selectedHostID == second.id)
    }

    @MainActor
    @Test("Disconnected Home resumes preserve agent, repository, and terminal intent")
    func disconnectedHomeResumePreservesEveryIntentAfterConnection() async {
        let intents: [WorkspaceResumeIntent] = [
            .agentSession("session-restored"),
            .repository("openpaw"),
            .terminal,
        ]

        for intent in intents {
            let first = hostRecord()
            let host = HostRecord(nickname: "Build", hostname: "build", username: "dev", auth: .agentForwarding)
            let terminal = RecordingTerminalBackend()
            let model = OpenPawModel(
                hostStore: HostStore(hosts: [first, host]),
                backend: RecordingBackend(),
                terminal: terminal)

            let resolved = await HomeResumeCoordinator.resolve(host: host, intent: intent, model: model)

            #expect(resolved?.intent == intent)
            #expect(resolved.map { model.ownsConnection($0.connection) } == true)
            #expect(model.selectedHostID == host.id)
            #expect(model.connection.isConnected)
        }
    }

    @MainActor
    @Test("A Home resume is discarded after an ABA host switch and newer reconnect")
    func homeResumeRejectsABASwitchBackToTheSameHost() async {
        let first = HostRecord(nickname: "One", hostname: "one", username: "dev", auth: .agentForwarding)
        let second = HostRecord(nickname: "Two", hostname: "two", username: "dev", auth: .agentForwarding)
        let gate = SuspendedLifecycleGate()
        let terminal = RecordingTerminalBackend()
        terminal.firstConnectGate = gate
        let model = OpenPawModel(
            hostStore: HostStore(hosts: [first, second]),
            backend: RecordingBackend(),
            terminal: terminal)

        let staleResume = Task { @MainActor in
            await HomeResumeCoordinator.resolve(
                host: first,
                intent: .agentSession("stale-agent"),
                model: model)
        }
        await gate.waitUntilStarted()
        await model.selectHost(second.id)
        await model.selectHost(first.id)
        await model.connectSelectedHost()
        await gate.release()

        #expect(await staleResume.value == nil)
        #expect(model.selectedHostID == first.id)
        #expect(model.connection.isConnected)
    }

    @MainActor
    @Test("A Home resume is discarded when a newer same-host reconnect takes ownership")
    func homeResumeRejectsNewerSameHostReconnect() async {
        let host = HostRecord(nickname: "One", hostname: "one", username: "dev", auth: .agentForwarding)
        let gate = SuspendedLifecycleGate()
        let terminal = RecordingTerminalBackend()
        terminal.firstConnectGate = gate
        let model = OpenPawModel(
            hostStore: HostStore(hosts: [host]),
            backend: RecordingBackend(),
            terminal: terminal)

        let staleResume = Task { @MainActor in
            await HomeResumeCoordinator.resolve(
                host: host,
                intent: .terminal,
                model: model)
        }
        await gate.waitUntilStarted()
        await model.connectSelectedHost()
        await gate.release()

        #expect(await staleResume.value == nil)
        #expect(model.selectedHostID == host.id)
        #expect(model.connection.isConnected)
    }

    @Test("The shared host switcher exposes one status, transport, and action vocabulary")
    func sharedHostSwitcherPresentationIsLayoutIndependent() {
        let host = HostRecord(
            nickname: "Build server", hostname: "build", username: "openpaw",
            auth: .agentForwarding, preferredTransport: .ssh)

        let disconnected = HostSwitcherPresentation(host: host, connection: .disconnected(reason: nil))
        #expect(disconnected.title == "Build server")
        #expect(disconnected.value == "disconnected · SSH")
        #expect(disconnected.connectionActions == [.connect])

        let connected = HostSwitcherPresentation(host: host, connection: .connected(.ssh))
        #expect(connected.value == "connected · SSH")
        #expect(connected.connectionActions == [.reconnect, .disconnect])

        let empty = HostSwitcherPresentation(host: nil, connection: .idle)
        #expect(empty.title == "No host")
        #expect(empty.value == "Add a device")
        #expect(empty.connectionActions.isEmpty)
    }

    @MainActor
    @Test("An empty first-run host store never calls the host API")
    func emptyHostStoreRefreshIsLocalOnly() async {
        let backend = RecordingBackend()
        let model = OpenPawModel(hostStore: HostStore(), backend: backend)

        await model.refresh()
        model.startFollowing(session: model.selectedSessionID)

        #expect(backend.callNames.isEmpty)
        #expect(model.lastError == nil)
    }

    @Test("Layout follows the measured width, because a size class alone lies on macOS")
    func widthResolvesFromMeasurement() {
        // An iPhone, portrait and landscape.
        #expect(RootWidth.resolve(width: 393) == .compact)
        #expect(RootWidth.resolve(width: 440) == .compact)
        // An iPad portrait, an iPad landscape, a Mac window.
        #expect(RootWidth.resolve(width: 1_024) == .regular)
        #expect(RootWidth.resolve(width: 1_366) == .regular)
        #expect(RootWidth.resolve(width: 900) == .regular)
        // The boundary is exact, so a frame at the threshold cannot flip between renders.
        #expect(RootWidth.resolve(width: RootWidth.twoPaneThreshold) == .regular)
        #expect(RootWidth.resolve(width: RootWidth.twoPaneThreshold - 1) == .compact)
    }

    @Test("A compact size class wins over a wide frame, which is what Slide Over looks like")
    func compactSizeClassOverridesWidth() {
        #expect(RootWidth.resolve(width: 1_024, isCompactSizeClass: true) == .compact)
        #expect(RootWidth.resolve(width: 393, isCompactSizeClass: false) == .compact)
    }

    @Test("The two rules compose into the layout the app draws")
    func widthAndStyleCompose() {
        #expect(RootNavigationStyle.style(for: RootWidth.resolve(width: 393)) == .tabs)
        #expect(RootNavigationStyle.style(for: RootWidth.resolve(width: 1_024)) == .split)
    }

    @Test("The compact tab bar stays bounded and becomes icon-only at accessibility sizes")
    func compactTabBarAdaptsToAccessibilityType() {
        #expect(RootNavigationLayout.compactTabBarHeight(isAccessibilitySize: false) == 64)
        #expect(RootNavigationLayout.compactTabBarHeight(isAccessibilitySize: true) == 72)
        #expect(RootNavigationLayout.showsVisualTabTitles(isAccessibilitySize: false))
        #expect(RootNavigationLayout.showsVisualTabTitles(isAccessibilitySize: true) == false)
    }

    @MainActor
    @Test("A deep link selects the inbox and remembers the item")
    func deepLinkOpensTheInbox() {
        let router = ShellRouter()
        router.destination = .terminal
        router.openApproval(itemID: "inb_abc")
        #expect(router.destination == .inbox)
        #expect(router.approvalItemID == "inb_abc")
    }

    @MainActor
    @Test("An Inbox URL round-trips one exact paired host and item")
    func inboxRouteRoundTripsStrictly() throws {
        let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let route = InboxRoute(hostID: hostID, itemID: InboxID(rawValue: "inb_0123456789abcdef01234567"))

        #expect(InboxRoute(url: route.url) == route)
        #expect(InboxRoute(url: URL(string: "https://inbox?host=\(hostID)&item=inb_0123456789abcdef01234567")!) == nil)
        #expect(InboxRoute(url: URL(string: "openpaw://inbox?host=not-a-uuid&item=inb_0123456789abcdef01234567")!) == nil)
        #expect(InboxRoute(url: URL(string: "openpaw://inbox?host=\(hostID)&item=")!) == nil)
        #expect(
            InboxRoute(
                url: URL(string: "openpaw://inbox?host=\(hostID)&host=\(hostID)&item=inb_0123456789abcdef01234567")!)
                == nil
        )
        #expect(InboxRoute(url: URL(string: "openpaw://inbox?host=\(hostID)&item=inb_0123456789ABCDEF01234567")!) == nil)
        #expect(InboxRoute(url: URL(string: "openpaw://inbox?host=\(hostID)&item=inb_01234567-9abcdef01234567")!) == nil)
        #expect(InboxRoute(url: URL(string: "openpaw://inbox?host=\(hostID)&item=inb_01234567_9abcdef01234567")!) == nil)
        #expect(InboxRoute(url: URL(string: "openpaw://inbox?host=\(hostID)&item=inb_0123456789abcdef0123456")!) == nil)
        #expect(InboxRoute(url: URL(string: "openpaw://inbox?host=\(hostID)&item=inb_0123456789abcdef012345678")!) == nil)
    }

    @MainActor
    @Test("An Inbox route selects, connects, refreshes, and resolves the requested host item")
    func inboxRouteConnectsTheRequestedHostBeforePresenting() async throws {
        let first = hostRecord()
        let target = HostRecord(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            nickname: "Target",
            hostname: "target",
            username: "dev",
            auth: .agentForwarding
        )
        let item = inboxRouteItem(id: "inb_aaaaaaaaaaaaaaaaaaaaaaaa")
        let backend = RecordingBackend()
        backend.inboxItems = [item]
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(
            hostStore: HostStore(hosts: [first, target]), backend: backend, terminal: terminal)

        let resolution = await InboxRouteCoordinator.resolve(
            InboxRoute(hostID: target.id, itemID: item.id), model: model)

        #expect(resolution == .present(item))
        #expect(model.selectedHostID == target.id)
        #expect(terminal.connectedHosts == [target.id])
        #expect(backend.callCount("inbox") == 1)
    }

    @MainActor
    @Test("Inbox routes distinguish missing hosts, stale items, and completed decisions")
    func inboxRouteReportsTypedTerminalStates() async throws {
        let host = hostRecord()
        let backend = RecordingBackend()
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]), backend: backend)
        model.connection = .connected(.ssh)

        let missingHost = await InboxRouteCoordinator.resolve(
            InboxRoute(hostID: UUID(), itemID: InboxID(rawValue: "inb_bbbbbbbbbbbbbbbbbbbbbbbb")), model: model)
        #expect(missingHost == .unknownHost)

        let stale = await InboxRouteCoordinator.resolve(
            InboxRoute(hostID: host.id, itemID: InboxID(rawValue: "inb_bbbbbbbbbbbbbbbbbbbbbbbb")), model: model)
        #expect(stale == .stale)

        var dismissed = inboxRouteItem(id: "inb_cccccccccccccccccccccccc")
        dismissed.status = .dismissed
        backend.inboxItems = [dismissed]
        let resolved = await InboxRouteCoordinator.resolve(
            InboxRoute(hostID: host.id, itemID: dismissed.id), model: model)
        #expect(resolved == .resolved(.dismissed))
    }

    @MainActor
    @Test("Changing hosts clears a presented host-scoped Inbox route")
    func routerInvalidatesTheHostScopedInboxRoute() {
        let router = ShellRouter()
        let route = InboxRoute(hostID: UUID(), itemID: InboxID(rawValue: "inb_dddddddddddddddddddddddd"))
        router.openInboxRoute(route)

        router.invalidateHostScopedState()

        #expect(router.approvalRoute == nil)
        #expect(router.approvalItemID == nil)
        #expect(router.inboxRoutePresentation == nil)
    }

    @MainActor
    @Test("Informational Inbox routes open detail without an approval sheet")
    func informationalInboxRouteUsesDetailPresentation() {
        let router = ShellRouter()
        let route = InboxRoute(hostID: UUID(), itemID: InboxID(rawValue: "inb_abababababababababababab"))

        router.openInboxRoute(route, presentation: .detail)

        #expect(router.destination == .inbox)
        #expect(router.approvalRoute == route)
        #expect(router.inboxRoutePresentation == .detail)
        #expect(router.approvalItemID == nil)
        #expect(router.inboxDetailItemID == route.itemID.rawValue)
    }

    @MainActor
    @Test("Actionable Inbox routes still open approval")
    func actionableInboxRouteUsesApprovalPresentation() {
        let router = ShellRouter()
        let route = InboxRoute(hostID: UUID(), itemID: InboxID(rawValue: "inb_acacacacacacacacacacacac"))

        router.openInboxRoute(route, presentation: .approvalSheet)

        #expect(router.destination == .inbox)
        #expect(router.inboxRoutePresentation == .approvalSheet)
        #expect(router.approvalItemID == route.itemID.rawValue)
    }

    @MainActor
    @Test("A late same-host Inbox route cannot replace a newer completed route")
    func competingInboxRouteKeepsOnlyNewestPresentation() async throws {
        let host = hostRecord()
        let firstItem = actionableInboxItem(id: "inb_010101010101010101010101", token: "tok_first")
        let secondItem = inboxRouteItem(id: "inb_020202020202020202020202")
        let firstGate = SuspendedLifecycleGate()
        let backend = RecordingBackend()
        backend.inboxGates = [firstGate]
        backend.inboxItems = [firstItem]
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]), backend: backend)
        model.connection = .connected(.ssh)
        let root = RootView(model: model, terminalSurface: { AnyView(EmptyView()) })
        let router = try shellRouter(from: root)
        let firstRoute = InboxRoute(hostID: host.id, itemID: firstItem.id)
        let secondRoute = InboxRoute(hostID: host.id, itemID: secondItem.id)

        root.openInboxRoute(firstRoute)
        await firstGate.waitUntilStarted()
        backend.inboxItems = [secondItem]
        root.openInboxRoute(secondRoute)
        while router.approvalRoute != secondRoute { await Task.yield() }
        await firstGate.release()
        for _ in 0..<10 { await Task.yield() }

        #expect(router.approvalRoute == secondRoute)
        #expect(router.inboxRoutePresentation == .detail)
        #expect(router.approvalItemID == nil)
        #expect(router.inboxDetailItemID == secondRoute.itemID.rawValue)
        #expect(model.lastError == nil)
    }

    @MainActor
    @Test("Stale Inbox route errors cannot overwrite a newer route or host invalidation")
    func staleInboxRouteErrorsAreIgnoredAfterNewerOwnership() async throws {
        let host = hostRecord()
        let firstGate = SuspendedLifecycleGate()
        let backend = RecordingBackend()
        backend.inboxGates = [firstGate]
        backend.inboxItems = []
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]), backend: backend)
        model.connection = .connected(.ssh)
        let root = RootView(model: model, terminalSurface: { AnyView(EmptyView()) })
        let router = try shellRouter(from: root)
        let staleRoute = InboxRoute(hostID: host.id, itemID: InboxID(rawValue: "inb_030303030303030303030303"))
        let currentItem = actionableInboxItem(id: "inb_040404040404040404040404", token: "tok_current")
        let currentRoute = InboxRoute(hostID: host.id, itemID: currentItem.id)

        root.openInboxRoute(staleRoute)
        await firstGate.waitUntilStarted()
        backend.inboxItems = [currentItem]
        root.openInboxRoute(currentRoute)
        while router.approvalRoute != currentRoute { await Task.yield() }
        await firstGate.release()
        for _ in 0..<10 { await Task.yield() }

        #expect(router.approvalRoute == currentRoute)
        #expect(router.inboxRoutePresentation == .approvalSheet)
        #expect(router.approvalItemID == currentRoute.itemID.rawValue)
        #expect(model.lastError == nil)

        router.invalidateHostScopedState()
        let unknownRoute = InboxRoute(hostID: UUID(), itemID: InboxID(rawValue: "inb_050505050505050505050505"))
        root.openInboxRoute(unknownRoute)
        router.invalidateHostScopedState()
        for _ in 0..<10 { await Task.yield() }
        #expect(model.lastError == nil)

        var resolvedItem = actionableInboxItem(id: "inb_060606060606060606060606", token: "tok_done")
        resolvedItem.status = .resolved
        backend.inboxItems = [resolvedItem]
        let resolvedRoute = InboxRoute(hostID: host.id, itemID: resolvedItem.id)
        root.openInboxRoute(resolvedRoute)
        router.invalidateHostScopedState()
        for _ in 0..<10 { await Task.yield() }
        #expect(model.lastError == nil)
    }

    @MainActor
    @Test("A suspended cross-host Inbox route cannot retake host or presentation from a newer route")
    func crossHostSuspendedInboxRouteCannotMutateAfterNewerRoute() async throws {
        let first = HostRecord(nickname: "first", hostname: "first", username: "dev", auth: .agentForwarding)
        let second = HostRecord(nickname: "second", hostname: "second", username: "dev", auth: .agentForwarding)
        let firstItem = actionableInboxItem(id: "inb_070707070707070707070707", token: "tok_first")
        let secondItem = inboxRouteItem(id: "inb_080808080808080808080808")
        let firstGate = SuspendedLifecycleGate()
        let backend = RecordingBackend()
        backend.inboxGates = [firstGate]
        backend.inboxItems = [firstItem]
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, second]), backend: backend, terminal: terminal)
        model.selectedHostID = first.id
        model.connection = .connected(.ssh)
        let root = RootView(model: model, terminalSurface: { AnyView(EmptyView()) })
        let router = try shellRouter(from: root)
        let firstRoute = InboxRoute(hostID: first.id, itemID: firstItem.id)
        let secondRoute = InboxRoute(hostID: second.id, itemID: secondItem.id)

        root.openInboxRoute(firstRoute)
        await firstGate.waitUntilStarted()
        backend.inboxItems = [secondItem]
        root.openInboxRoute(secondRoute)
        while router.approvalRoute != secondRoute { await Task.yield() }
        await firstGate.release()
        for _ in 0..<10 { await Task.yield() }

        #expect(model.selectedHostID == second.id)
        #expect(terminal.connectedHosts == [second.id])
        #expect(router.approvalRoute == secondRoute)
        #expect(router.inboxRoutePresentation == .detail)
        #expect(router.approvalItemID == nil)
        #expect(model.lastError == nil)
    }

    @MainActor
    @Test("Locking URL access cancels a suspended Inbox route before it can present or error")
    func lockedURLAccessCancelsSuspendedInboxRoute() async throws {
        let host = hostRecord()
        let item = actionableInboxItem(id: "inb_090909090909090909090909", token: "tok_locked")
        let gate = SuspendedLifecycleGate()
        let backend = RecordingBackend()
        backend.inboxGates = [gate]
        backend.inboxItems = [item]
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]), backend: backend)
        model.connection = .connected(.ssh)
        let root = RootView(model: model, terminalSurface: { AnyView(EmptyView()) })
        let router = try shellRouter(from: root)
        let route = InboxRoute(hostID: host.id, itemID: item.id)

        root.openInboxRoute(route)
        await gate.waitUntilStarted()
        root.cancelInboxRouteRequest()
        await gate.release()
        for _ in 0..<10 { await Task.yield() }

        #expect(router.approvalRoute == nil)
        #expect(router.inboxRoutePresentation == nil)
        #expect(router.approvalItemID == nil)
        #expect(model.lastError == nil)
    }

    @MainActor
    @Test("Locking during a cross-host Inbox route removes the route connection and restores the prior selection")
    func lockedCrossHostInboxRouteRollsBackItsHostMutation() async throws {
        let first = HostRecord(nickname: "first", hostname: "first", username: "dev", auth: .agentForwarding)
        let second = HostRecord(nickname: "second", hostname: "second", username: "dev", auth: .agentForwarding)
        let item = actionableInboxItem(id: "inb_101010101010101010101010", token: "tok_locked")
        let gate = SuspendedLifecycleGate()
        let backend = RecordingBackend()
        backend.inboxItems = [item]
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(
            hostStore: HostStore(hosts: [first, second]),
            backend: backend,
            terminal: terminal)
        await model.connectSelectedHost()
        #expect(terminal.activeHostID == first.id)
        backend.inboxGates = [gate]
        let root = RootView(model: model, terminalSurface: { AnyView(EmptyView()) })
        let router = try shellRouter(from: root)
        let route = InboxRoute(hostID: second.id, itemID: item.id)

        root.openInboxRoute(route)
        await gate.waitUntilStarted()
        #expect(model.selectedHostID == second.id)
        #expect(terminal.activeHostID == second.id)
        root.cancelInboxRouteRequest()
        await gate.release()
        for _ in 0..<1_000 where model.selectedHostID != first.id || model.isSwitchingHost || terminal.activeHostID != nil {
            await Task.yield()
        }

        #expect(model.selectedHostID == first.id)
        #expect(terminal.activeHostID == nil)
        #expect(model.connection.isConnected == false)
        #expect(router.approvalRoute == nil)
        #expect(router.inboxRoutePresentation == nil)
        #expect(model.lastError == nil)
    }

    @MainActor
    @Test("A route-owned host selection preserves only that exact Inbox request")
    func routeOwnedHostSelectionPreservesOnlyItsRequest() {
        let router = ShellRouter()
        let target = UUID()
        let other = UUID()
        let generation = router.beginInboxRouteRequest(targetHostID: target)

        router.invalidateHostScopedState(preservingInboxRouteFor: target)
        #expect(router.ownsInboxRouteRequest(generation))

        router.invalidateHostScopedState(preservingInboxRouteFor: other)
        #expect(!router.ownsInboxRouteRequest(generation))
    }

    @MainActor
    @Test("Actionable SSE items hydrate their host token before resolving")
    func actionableItemHydratesBeforeResolve() async throws {
        let host = hostRecord()
        let stale = actionableInboxItem(id: "inb_eeeeeeeeeeeeeeeeeeeeeeee", token: nil)
        var fresh = stale
        fresh.actionToken = "tok_fresh"
        let backend = RecordingBackend()
        backend.inboxItems = [fresh]
        backend.resolveSucceeds = true
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]), backend: backend)
        model.connection = .connected(.ssh)
        model.inbox = [stale]

        let sent = await model.resolve(stale, action: .deny)

        #expect(sent)
        #expect(backend.callNames == ["inbox", "resolve"])
        #expect(backend.resolvedActionToken == "tok_fresh")
    }

    @MainActor
    @Test("Actionable hydration failure does not resolve")
    func actionableHydrationFailureBlocksResolve() async throws {
        let host = hostRecord()
        let item = actionableInboxItem(id: "inb_ffffffffffffffffffffffff", token: nil)
        let backend = RecordingBackend()
        backend.inboxItems = []
        backend.resolveSucceeds = true
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]), backend: backend)
        model.connection = .connected(.ssh)

        let sent = await model.resolve(item, action: .deny)

        #expect(!sent)
        #expect(backend.callNames == ["inbox"])
        #expect(model.lastError?.title == "Refresh this request first")
    }

    @MainActor
    @Test("A committed decision warning resolves once and tells the operator not to retry")
    func committedDecisionWarningIsPresentedAfterResolution() async {
        let host = hostRecord()
        let item = actionableInboxItem(id: "inb_787878787878787878787878", token: "tok_once")
        let backend = RecordingBackend()
        backend.resolveSucceeds = true
        backend.resolveWarning = "decision_durability_not_confirmed"
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]), backend: backend)
        model.connection = .connected(.ssh)
        model.inbox = [item]

        let sent = await model.resolve(item, action: .deny)

        #expect(sent)
        #expect(model.inbox.first?.status == .resolved)
        #expect(model.lastError?.title == "Decision sent with a storage warning")
        #expect(model.lastError?.detail.contains("Do not retry") == true)
        #expect(model.lastError?.isRecoverable == false)
    }

    @MainActor
    @Test("A host switch during action-token hydration cannot report or resolve stale work")
    func actionableHydrationHostSwitchIsIgnored() async throws {
        let first = HostRecord(
            nickname: "first", hostname: "10.0.0.4", username: "chet", auth: .agentForwarding)
        let second = HostRecord(
            nickname: "second", hostname: "10.0.0.5", username: "chet", auth: .agentForwarding)
        let item = actionableInboxItem(id: "inb_121212121212121212121212", token: nil)
        var fresh = item
        fresh.actionToken = "tok_first"
        let backend = RecordingBackend()
        backend.inboxItems = [fresh]
        backend.resolveSucceeds = true
        backend.refreshDelayNanoseconds = 50_000_000
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, second]), backend: backend)
        model.connection = .connected(.ssh)
        model.inbox = [item]

        let resolving = Task { await model.resolve(item, action: .deny) }
        try await Task.sleep(nanoseconds: 5_000_000)
        await model.selectHost(second.id)
        let sent = await resolving.value

        #expect(!sent)
        #expect(backend.callCount("resolve") == 0)
        #expect(model.lastError?.title == nil)
    }

    @MainActor
    @Test("A same-host reconnect during action-token hydration invalidates the old request")
    func actionableHydrationSameHostReconnectIsIgnored() async throws {
        let host = hostRecord()
        let item = actionableInboxItem(id: "inb_343434343434343434343434", token: nil)
        var fresh = item
        fresh.actionToken = "tok_old_generation"
        let backend = RecordingBackend()
        backend.inboxItems = [fresh]
        backend.resolveSucceeds = true
        backend.refreshDelayNanoseconds = 50_000_000
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]), backend: backend)
        model.connection = .connected(.ssh)
        model.inbox = [item]

        let resolving = Task { await model.resolve(item, action: .deny) }
        try await Task.sleep(nanoseconds: 5_000_000)
        model.connection = .disconnected(reason: "network changed")
        model.connection = .connected(.ssh)
        let sent = await resolving.value

        #expect(!sent)
        #expect(backend.callCount("resolve") == 0)
        #expect(model.lastError?.title == nil)
    }

    @MainActor
    @Test("A resolve failure after switching hosts cannot present a stale error")
    func actionableResolveFailureAfterHostSwitchIsIgnored() async throws {
        let first = HostRecord(
            nickname: "first", hostname: "10.0.0.4", username: "chet", auth: .agentForwarding)
        let second = HostRecord(
            nickname: "second", hostname: "10.0.0.5", username: "chet", auth: .agentForwarding)
        let item = actionableInboxItem(id: "inb_565656565656565656565656", token: "tok_first")
        let gate = SuspendedLifecycleGate()
        let backend = RecordingBackend()
        backend.resolveGate = gate
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, second]), backend: backend)
        model.connection = .connected(.ssh)
        model.inbox = [item]

        let resolving = Task { await model.resolve(item, action: .deny) }
        await gate.waitUntilStarted()
        await model.selectHost(second.id)
        await gate.release()
        let sent = await resolving.value

        #expect(!sent)
        #expect(model.lastError == nil)
    }
}

private func hostRecord() -> HostRecord {
    HostRecord(nickname: "workshop", hostname: "10.0.0.4", username: "chet", auth: .agentForwarding)
}

private func inboxRouteItem(id: String) -> InboxItem {
    InboxItem(
        id: InboxID(rawValue: id),
        sessionID: SessionID(rawValue: "sess_route"),
        agent: .claudeCode,
        category: .completion,
        title: "Finished",
        actions: [.acknowledge],
        createdAt: Date(timeIntervalSince1970: 1_780_000_000),
        status: .pending,
        sourceEventID: EventID(rawValue: "evt_\(id)")
    )
}

private func actionableInboxItem(id: String, token: String?) -> InboxItem {
    InboxItem(
        id: InboxID(rawValue: id),
        sessionID: SessionID(rawValue: "sess_action"),
        agent: .claudeCode,
        category: .permission,
        title: "Run command?",
        detail: "rm -rf build",
        command: "rm -rf build",
        risk: Risk(riskClass: .localWrite, requiresDetailExpansion: true, reasons: ["modifies workspace"]),
        actions: [.approveOnce, .deny],
        requestID: "req_\(id)",
        actionToken: token,
        createdAt: Date(timeIntervalSince1970: 1_780_000_010),
        status: .pending,
        sourceEventID: EventID(rawValue: "evt_\(id)")
    )
}

private func shellRouter(from root: RootView) throws -> ShellRouter {
    for child in Mirror(reflecting: root).children where child.label == "router" {
        if let router = child.value as? ShellRouter { return router }
    }
    throw RecordingBackendError.unexpectedCall
}

private enum RecordingBackendError: Error {
    case unexpectedCall
}

private class RecordingBackend: OpenPawBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    var callNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func callCount(_ name: String) -> Int {
        callNames.filter { $0 == name }.count
    }

    var tailscaleResponse = TailscaleDevicesResponse(version: 1, candidates: [])
    var tailscaleError: (any Error)?
    var tailscaleDelayNanoseconds: UInt64 = 0
    var refreshDelayNanoseconds: UInt64 = 0
    var inboxGates: [SuspendedLifecycleGate] = []
    var inboxItems: [InboxItem] = []
    var resolveSucceeds = false
    var resolveWarning: String?
    var resolveGate: SuspendedLifecycleGate?
    private(set) var resolvedActionToken: String?

    private func record(_ name: String) {
        lock.lock()
        calls.append(name)
        lock.unlock()
    }

    func health() async throws -> HealthInfo {
        record("health")
        if refreshDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: refreshDelayNanoseconds) }
        return HealthInfo(
            version: "test", protocolVersion: "1.0", agents: [.claudeCode], capabilities: [], previewPorts: [],
            adapterVersions: [:])
    }

    func sessions() async throws -> [SessionSummary] {
        record("sessions")
        if refreshDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: refreshDelayNanoseconds) }
        return []
    }

    func inbox(status: InboxStatus?) async throws -> [InboxItem] {
        record("inbox")
        let gate = lock.withLock { inboxGates.isEmpty ? nil : inboxGates.removeFirst() }
        if let gate { await gate.suspend() }
        if refreshDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: refreshDelayNanoseconds) }
        guard let status else { return inboxItems }
        return inboxItems.filter { $0.status == status }
    }

    func resolve(item: InboxItem, action: ActionID, answer: String?, detailAcknowledged: Bool) async throws -> ResolveResult {
        record("resolve")
        resolvedActionToken = item.actionToken
        if let resolveGate { await resolveGate.suspend() }
        if resolveSucceeds {
            return ResolveResult(status: "resolved", eventID: nil, warning: resolveWarning)
        }
        throw RecordingBackendError.unexpectedCall
    }

    func events(session: String?, afterSeq: UInt64?) -> AsyncThrowingStream<Event, any Error> {
        record("events")
        return AsyncThrowingStream { continuation in continuation.finish() }
    }

    func repos() async throws -> [RepoSummary] {
        record("repos")
        if refreshDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: refreshDelayNanoseconds) }
        return []
    }

    func repoStatus(_ repo: String) async throws -> RepoStatus {
        record("repoStatus")
        throw RecordingBackendError.unexpectedCall
    }

    func diff(repo: String, mode: DiffMode, path: String?) async throws -> Diff {
        record("diff")
        throw RecordingBackendError.unexpectedCall
    }

    func tree(repo: String, ref: String, path: String) async throws -> [TreeEntry] {
        record("tree")
        throw RecordingBackendError.unexpectedCall
    }

    func blob(repo: String, ref: String, path: String) async throws -> Blob {
        record("blob")
        throw RecordingBackendError.unexpectedCall
    }

    func search(repo: String, query: String, path: String?) async throws -> [ContentMatch] {
        record("search")
        throw RecordingBackendError.unexpectedCall
    }

    func upload(data: Data, filename: String) async throws -> UploadResult {
        record("upload")
        throw RecordingBackendError.unexpectedCall
    }

    func previewURL(port: Int, path: String) throws -> URL {
        record("previewURL")
        return URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func tailscaleDevices() async throws -> TailscaleDevicesResponse {
        record("tailscaleDevices")
        if tailscaleDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: tailscaleDelayNanoseconds) }
        if let tailscaleError { throw tailscaleError }
        return tailscaleResponse
    }

    func audit(limit: Int) async throws -> [AuditEntry] {
        record("audit")
        throw RecordingBackendError.unexpectedCall
    }
}


private actor SuspendedLifecycleGate {
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class LifecycleRecordingBackend: RecordingBackend, StructuredBackendLifecycle, @unchecked Sendable {
    private let lock2 = NSLock()
    private var ready = false
    private var recordedConnectIDs: [HostRecord.ID] = []
    private var recordedDisconnectCount = 0
    private var recordedActiveHostID: HostRecord.ID?
    var failConnect = false
    var suspendedHostID: HostRecord.ID?
    var connectGate: SuspendedLifecycleGate?
    var suspendedDisconnectNumber: Int?
    var disconnectGate: SuspendedLifecycleGate?

    var connectIDs: [HostRecord.ID] { locked { recordedConnectIDs } }
    var disconnectCount: Int { locked { recordedDisconnectCount } }
    var activeHostID: HostRecord.ID? { locked { recordedActiveHostID } }
    var isReady: Bool { get async { locked { ready } } }

    func connect(hostID: HostRecord.ID) async throws {
        let gate = locked {
            recordedConnectIDs.append(hostID)
            return suspendedHostID == hostID ? connectGate : nil
        }
        if let gate { await gate.suspend() }
        if failConnect { throw RecordingBackendError.unexpectedCall }
        locked {
            ready = true
            recordedActiveHostID = hostID
        }
    }

    func disconnect() async {
        let gate = locked {
            recordedDisconnectCount += 1
            return recordedDisconnectCount == suspendedDisconnectNumber ? disconnectGate : nil
        }
        if let gate { await gate.suspend() }
        locked {
            ready = false
            recordedActiveHostID = nil
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock2.lock()
        defer { lock2.unlock() }
        return body()
    }
}

private final class RecordingTerminalBackend: TerminalBackend, @unchecked Sendable {
    private let continuation: AsyncStream<ConnectionState>.Continuation
    let stateStream: AsyncStream<ConnectionState>
    let outputStream = AsyncStream<Data> { $0.finish() }
    private(set) var connectedHosts: [HostRecord.ID] = []
    private(set) var activeHostID: HostRecord.ID?
    private(set) var disconnectCount = 0
    private(set) var sentTexts: [String] = []
    private(set) var runCommands: [String] = []
    var runResponses: [String: String] = [:]
    var failConnect = false
    var firstConnectGate: SuspendedLifecycleGate?
    var disconnectGate: SuspendedLifecycleGate?
    var suspendedDisconnectNumber = 1
    init() {
        var cont: AsyncStream<ConnectionState>.Continuation!
        stateStream = AsyncStream { cont = $0 }
        continuation = cont
    }
    /// When set, `connect` reports the failure through the state stream and then throws *that same error*, the way
    /// `SSHTerminalBackend` does. Throwing a different error would let a test pass while the real app still raised
    /// an alert for the thrown one.
    var failConnectWith: TransportError?
    func connect(host: HostRecord) async throws {
        connectedHosts.append(host.id)
        if connectedHosts.count == 1, let firstConnectGate { await firstConnectGate.suspend() }
        if let failConnectWith {
            continuation.yield(.failed(failConnectWith))
            throw failConnectWith
        }
        if failConnect { throw RecordingBackendError.unexpectedCall }
        activeHostID = host.id
        continuation.yield(.connected(.ssh))
    }
    func disconnect() async {
        disconnectCount += 1
        if disconnectCount == suspendedDisconnectNumber, let disconnectGate { await disconnectGate.suspend() }
        activeHostID = nil
        continuation.yield(.disconnected(reason: nil))
    }
    func send(text: String) async throws { sentTexts.append(text) }
    func send(chord: KeyChord, applicationCursorKeys: Bool) async throws {}
    func resize(columns: Int, rows: Int) async throws {}
    func run(command: String) async throws -> String {
        runCommands.append(command)
        return runResponses[command] ?? ""
    }
}

private actor RecordingSessionCommandRunner: CommandRunner {
    private var recordedCommands: [String] = []
    private let responses: [String: String]

    init(responses: [String: String]) {
        self.responses = responses
    }

    func run(_ command: String) async throws -> String {
        recordedCommands.append(command)
        return responses[command] ?? ""
    }

    func commands() -> [String] { recordedCommands }
}

@Suite("Typed session command execution")
struct TypedSessionCommandExecutionTests {
    @MainActor
    @Test("Attach preflights the real target before entering the interactive PTY")
    func acknowledgedManagementAndInteractiveAttachUseTheRightChannels() async throws {
        let terminal = RecordingTerminalBackend()
        let executor = TerminalSessionCommandExecutor(terminal: terminal)
        let session = RemoteSession.target("agent main", kind: .tmux)
        terminal.runResponses[TmuxAdapter().discoverCommand] = [
            "$9", "agent main", "0", "1", "1755697800", "1755701400", "/srv/api",
        ].joined(separator: Multiplexer.fieldSeparator)

        _ = try await executor.executeSessionCommand(.kill(session))
        #expect(terminal.runCommands == ["tmux kill-session -t 'agent main'"])
        #expect(terminal.sentTexts.isEmpty)

        _ = try await executor.executeSessionCommand(.attach(session))
        #expect(terminal.sentTexts == ["tmux attach-session -t '$9'\n"])
        #expect(terminal.runCommands == [
            "tmux kill-session -t 'agent main'",
            TmuxAdapter().discoverCommand,
        ])
    }

    @MainActor
    @Test("Create is acknowledged in the background before attaching the actual remote session")
    func createWaitsForRemoteAcknowledgementBeforeInteractiveAttach() async throws {
        let terminal = RecordingTerminalBackend()
        let executor = TerminalSessionCommandExecutor(terminal: terminal)
        let preparation = TmuxAdapter().createDetached(name: "release", directory: "/srv/release")
        terminal.runResponses[TmuxAdapter().discoverCommand] = [
            "$3", "release", "0", "1", "1755697800", "1755701400", "/srv/release",
        ].joined(separator: Multiplexer.fieldSeparator)

        _ = try await executor.executeSessionCommand(
            .create(kind: .tmux, name: "release", directory: "/srv/release"))

        #expect(terminal.runCommands == [preparation, TmuxAdapter().discoverCommand])
        #expect(terminal.sentTexts == ["tmux attach-session -t '$3'\n"])
    }

    @MainActor
    @Test("Create uses an independent control runner after the interactive terminal enters tmux")
    func createDoesNotProbeThroughTheInteractiveTerminal() async throws {
        let terminal = RecordingTerminalBackend()
        let preparation = TmuxAdapter().createDetached(name: "release", directory: nil)
        let control = RecordingSessionCommandRunner(responses: [
            preparation: "",
            TmuxAdapter().discoverCommand: [
                "$3", "release", "0", "1", "1755697800", "1755701400", "/srv/release",
            ].joined(separator: Multiplexer.fieldSeparator),
        ])
        let executor = TerminalSessionCommandExecutor(terminal: terminal, runner: control)

        _ = try await executor.executeSessionCommand(.create(kind: .tmux, name: "release", directory: nil))

        #expect(terminal.runCommands.isEmpty)
        #expect(await control.commands() == [preparation, TmuxAdapter().discoverCommand])
        #expect(terminal.sentTexts == ["tmux attach-session -t '$3'\n"])
    }

    @MainActor
    @Test("An unacknowledged create never enters or persists an invented session")
    func unacknowledgedCreateDoesNotAttach() async {
        let terminal = RecordingTerminalBackend()
        let executor = TerminalSessionCommandExecutor(terminal: terminal)
        let preparation = TmuxAdapter().createDetached(name: "missing", directory: nil)

        do {
            _ = try await executor.executeSessionCommand(
                .create(kind: .tmux, name: "missing", directory: nil))
            Issue.record("expected acknowledgement failure")
        } catch let error as SessionSpaceCommandExecutionError {
            #expect(error == .creationNotAcknowledged(kind: .tmux, name: "missing"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(terminal.runCommands == [preparation, TmuxAdapter().discoverCommand])
        #expect(terminal.sentTexts.isEmpty)
    }

    @MainActor
    @Test("Focus and directory readiness are acknowledged before terminal navigation")
    func focusAndDirectoryUseAcknowledgedFixedTemplates() async throws {
        let terminal = RecordingTerminalBackend()
        let executor = TerminalSessionCommandExecutor(terminal: terminal)
        let window = RemoteWindow(id: "@2", sessionID: "$1", index: 2, name: "logs")

        _ = try await executor.executeSessionCommand(.focus(kind: .tmux, window: window))
        _ = try await executor.executeSessionCommand(.changeDirectory("/srv/api rocks"))

        #expect(terminal.runCommands == [
            "tmux select-window -t @2",
            "test -d '/srv/api rocks'",
        ])
        #expect(terminal.sentTexts == ["cd '/srv/api rocks'\n"])
    }

    @MainActor
    @Test("Herdr creation manages the root pane but attaches its terminal ID")
    func herdrCreateUsesAcknowledgedRootPaneReceipt() async throws {
        let terminal = RecordingTerminalBackend()
        let executor = TerminalSessionCommandExecutor(terminal: terminal)
        let preparation = HerdrAdapter().createDetached(name: "api", directory: "/srv/api")
        terminal.runResponses[preparation] = #"{"id":"cli:workspace:create","result":{"workspace":{"workspace_id":"w9"},"tab":{"tab_id":"w9:t1"},"root_pane":{"pane_id":"w9:p1","terminal_id":"term_root_9"}}}"#

        let acknowledgement = try await executor.executeSessionCommand(
            .create(kind: .herdr, name: "api", directory: "/srv/api"))

        #expect(acknowledgement.session?.id == "w9:p1")
        #expect(acknowledgement.session?.terminalID == "term_root_9")
        #expect(terminal.runCommands == [preparation])
        #expect(terminal.sentTexts == ["herdr terminal attach term_root_9\n"])
    }

    @MainActor
    @Test("Herdr attach probes the exact pane before opening its terminal stream")
    func herdrAttachUsesPaneProbeAndTerminalAttach() async throws {
        let terminal = RecordingTerminalBackend()
        let executor = TerminalSessionCommandExecutor(terminal: terminal)
        let session = RemoteSession(
            id: "w3:p9",
            name: "fix the build",
            kind: .herdr,
            terminalID: "term_65909b7e020c13")
        terminal.runResponses["herdr pane get w3:p9"] = #"{"id":"cli:pane:get","result":{"pane_id":"w3:p9","terminal_id":"term_65909b7e020c13"}}"#

        let acknowledgement = try await executor.executeSessionCommand(.attach(session))

        #expect(acknowledgement.session == session)
        #expect(terminal.runCommands == ["herdr pane get w3:p9"])
        #expect(terminal.sentTexts == ["herdr terminal attach term_65909b7e020c13\n"])
    }

    @MainActor
    @Test("Herdr attach rejects an exit-zero error envelope before opening the terminal")
    func herdrAttachRejectsPaneProbeErrorEnvelope() async {
        let terminal = RecordingTerminalBackend()
        let executor = TerminalSessionCommandExecutor(terminal: terminal)
        let session = RemoteSession(
            id: "w3:p9",
            name: "missing pane",
            kind: .herdr,
            terminalID: "term_65909b7e020c13")
        terminal.runResponses["herdr pane get w3:p9"] = #"{"error":{"code":"pane_not_found","message":"nope"},"id":"cli:pane:get"}"#

        do {
            _ = try await executor.executeSessionCommand(.attach(session))
            Issue.record("expected the pane probe error envelope to stop attachment")
        } catch let error as MultiplexerError {
            if case .malformedOutput(let kind, _) = error {
                #expect(kind == .herdr)
            } else {
                Issue.record("unexpected multiplexer error: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(terminal.runCommands == ["herdr pane get w3:p9"])
        #expect(terminal.sentTexts.isEmpty)
    }
}

@Suite("Structured backend lifecycle")
struct StructuredBackendLifecycleTests {
    @MainActor
    @Test("Lifecycle backend gates refresh until terminal host connection opens it")
    func lifecycleReadinessGatesRefresh() async {
        let host = hostRecord()
        let backend = LifecycleRecordingBackend()
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]), backend: backend, terminal: terminal)
        #expect(model.canRefreshRemoteState == false)
        await model.refresh()
        #expect(backend.callCount("health") == 0)
        await model.connectSelectedHost()
        #expect(model.structuredBackendReady)
        #expect(backend.connectIDs == [host.id])
        #expect(backend.callCount("health") == 1)
    }

    @MainActor
    @Test("Structured backend failure keeps terminal connected but features unavailable")
    func terminalOnlyFallbackWhenStructuredConnectFails() async {
        let host = hostRecord()
        let backend = LifecycleRecordingBackend()
        backend.failConnect = true
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]), backend: backend, terminal: terminal)
        await model.connectSelectedHost()
        #expect(model.connection.isConnected)
        #expect(model.structuredBackendReady == false)
        #expect(model.canRefreshRemoteState == false)
        #expect(model.lastError?.title == "Structured host features are unavailable")
    }

    @MainActor
    @Test("Selecting a different host immediately invalidates structured readiness before reconnect")
    func selectingDifferentHostInvalidatesReadinessBeforeReconnect() async {
        let first = HostRecord(nickname: "One", hostname: "one", username: "dev", auth: .agentForwarding)
        let second = HostRecord(nickname: "Two", hostname: "two", username: "dev", auth: .agentForwarding)
        let backend = LifecycleRecordingBackend()
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, second]), backend: backend, terminal: terminal)
        await model.connectSelectedHost()
        await Task.yield()
        #expect(model.structuredBackendReady)
        #expect(model.connection.isConnected)

        terminal.failConnect = true
        let healthCalls = backend.callCount("health")
        await model.selectHost(second.id)

        #expect(model.structuredBackendReady == false)
        #expect(model.canRefreshRemoteState == false)
        await model.refresh()
        model.refreshTailscaleDevices()
        #expect(backend.callCount("health") == healthCalls)
        #expect(model.tailscaleDiscovery == .noConnectedHost)

        await model.connectSelectedHost()
        #expect(model.structuredBackendReady == false)
        #expect(model.canRefreshRemoteState == false)
        #expect(backend.connectIDs == [first.id])
    }

    @MainActor
    @Test("Switching hosts disconnects stale backend and suppresses Tailscale results")
    func hostSwitchDisconnectsAndScopesTailscale() async throws {
        let first = HostRecord(nickname: "One", hostname: "one", username: "dev", auth: .agentForwarding)
        let second = HostRecord(nickname: "Two", hostname: "two", username: "dev", auth: .agentForwarding)
        let backend = LifecycleRecordingBackend()
        backend.tailscaleDelayNanoseconds = 50_000_000
        backend.tailscaleResponse = TailscaleDevicesResponse(version: 1, candidates: [TailscaleDeviceCandidate(id: "late", displayName: "Late", tailscaleIPs: ["100.64.0.1"], online: true)])
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, second]), backend: backend, terminal: terminal)
        await model.connectSelectedHost()
        model.refreshTailscaleDevices()
        await model.selectHost(second.id)
        await model.connectSelectedHost()
        try await Task.sleep(nanoseconds: 90_000_000)
        #expect(backend.disconnectCount >= 2)
        #expect(backend.connectIDs.suffix(2) == [first.id, second.id])
        #expect(model.tailscaleDiscovery.candidates.isEmpty)
    }

    @MainActor
    @Test("A delayed structured connect is cleaned up after selecting another host")
    func delayedConnectCannotReattachTheOldHost() async {
        let first = HostRecord(nickname: "One", hostname: "one", username: "dev", auth: .agentForwarding)
        let second = HostRecord(nickname: "Two", hostname: "two", username: "dev", auth: .agentForwarding)
        let gate = SuspendedLifecycleGate()
        let backend = LifecycleRecordingBackend()
        backend.suspendedHostID = first.id
        backend.connectGate = gate
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, second]), backend: backend, terminal: terminal)

        let staleConnect = Task { await model.connectSelectedHost() }
        await gate.waitUntilStarted()
        await model.selectHost(second.id)
        await gate.release()
        await staleConnect.value

        #expect(model.selectedHostID == second.id)
        #expect(model.structuredBackendReady == false)
        #expect(backend.activeHostID == nil)
    }

    @MainActor
    @Test("A newer host connect owns the lifecycle after a delayed stale connect finishes")
    func newerConnectWinsAfterDelayedStaleConnect() async {
        let first = HostRecord(nickname: "One", hostname: "one", username: "dev", auth: .agentForwarding)
        let second = HostRecord(nickname: "Two", hostname: "two", username: "dev", auth: .agentForwarding)
        let gate = SuspendedLifecycleGate()
        let backend = LifecycleRecordingBackend()
        backend.suspendedHostID = first.id
        backend.connectGate = gate
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, second]), backend: backend, terminal: terminal)

        let staleConnect = Task { await model.connectSelectedHost() }
        await gate.waitUntilStarted()
        await model.selectHost(second.id)
        let currentConnect = Task { await model.connectSelectedHost() }

        // Give the unsafe implementation a deterministic opportunity to finish the newer lifecycle connect first.
        for _ in 0..<100 where backend.activeHostID != second.id {
            await Task.yield()
        }
        await gate.release()
        await staleConnect.value
        await currentConnect.value

        #expect(backend.connectIDs == [first.id, second.id])
        #expect(backend.activeHostID == second.id)
        #expect(model.selectedHostID == second.id)
        #expect(model.structuredBackendReady)
    }

    @MainActor
    @Test("Stale cleanup cannot overtake and disconnect a newer host")
    func staleCleanupCannotDisconnectNewerHost() async {
        let first = HostRecord(nickname: "One", hostname: "one", username: "dev", auth: .agentForwarding)
        let second = HostRecord(nickname: "Two", hostname: "two", username: "dev", auth: .agentForwarding)
        let connectGate = SuspendedLifecycleGate()
        let cleanupGate = SuspendedLifecycleGate()
        let backend = LifecycleRecordingBackend()
        backend.suspendedHostID = first.id
        backend.connectGate = connectGate
        // A connect performs two initial teardowns and host selection performs the third. The fourth is stale cleanup.
        backend.suspendedDisconnectNumber = 4
        backend.disconnectGate = cleanupGate
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, second]), backend: backend, terminal: terminal)

        let staleConnect = Task { await model.connectSelectedHost() }
        await connectGate.waitUntilStarted()
        await model.selectHost(second.id)
        await connectGate.release()
        await cleanupGate.waitUntilStarted()

        let currentConnect = Task { await model.connectSelectedHost() }
        // The unsafe implementation can finish B while A's cleanup is suspended. The safe implementation queues B.
        for _ in 0..<100 where backend.activeHostID != second.id {
            await Task.yield()
        }
        await cleanupGate.release()
        await staleConnect.value
        await currentConnect.value

        #expect(backend.activeHostID == second.id)
        #expect(model.selectedHostID == second.id)
        #expect(model.structuredBackendReady)
    }
}

// MARK: - Shortcut bar

@Suite("Shortcut bar")
struct ShortcutBarTests {

    @Test("The shipped set carries the keys a touch keyboard cannot produce")
    func defaultSetCarriesTheEssentialKeys() {
        for id in ["esc", "ctrl", "alt", "tab", "pipe", "slash"] {
            #expect(ShortcutSet.default[id] != nil, "\(id) is missing from the default set")
        }
        #expect(ShortcutSet.default["esc"]?.label == "esc")
        #expect(ShortcutSet.default["pipe"]?.label == "|")
        #expect(ShortcutSet.default["slash"]?.label == "/")
        // ctrl and alt arm, they do not send.
        if case .modifierLatch(let modifiers) = ShortcutSet.default["ctrl"]?.payload {
            #expect(modifiers == .control)
        } else {
            Issue.record("ctrl should be a modifier latch")
        }
        if case .modifierLatch(let modifiers) = ShortcutSet.default["alt"]?.payload {
            #expect(modifiers == .alt)
        } else {
            Issue.record("alt should be a modifier latch")
        }
    }

    @Test("ctrl+c is the interrupt byte")
    func controlCProducesTheInterruptByte() {
        let chord = KeyChord(.text("c"), modifiers: .control)
        #expect(Array(OpenPawTerminalCore.bytes(for: chord)) == [0x03])
        #expect(Array(ShortcutSet.default.bytes(for: "ctrl-c") ?? []) == [0x03])
        // Round-trips through the chord's own string form, which is what the shortcut JSON stores.
        #expect(chord.description == "ctrl+c")
        #expect(KeyChord(parsing: "ctrl+c") == chord)
    }

    @Test("A latched modifier folds into the next chord and nothing else")
    func latchedControlFoldsIntoTheNextChord() throws {
        let tab = try #require(ShortcutSet.default["tab"])
        guard case .send(let plain) = ShortcutBarLayout.action(for: tab, latched: []) else {
            Issue.record("tab should send a chord")
            return
        }
        #expect(plain.modifiers.isEmpty)

        guard case .send(let modified) = ShortcutBarLayout.action(for: tab, latched: .control) else {
            Issue.record("tab should still send a chord when control is armed")
            return
        }
        #expect(modified.modifiers.contains(.control))
        #expect(modified.key == .tab)
    }

    @Test("Command is never transmitted to a PTY")
    func commandIsNeverFoldedIn() throws {
        let tab = try #require(ShortcutSet.default["tab"])
        guard case .send(let chord) = ShortcutBarLayout.action(for: tab, latched: [.command]) else {
            Issue.record("tab should send a chord")
            return
        }
        #expect(chord.modifiers.isEmpty)
    }

    @Test("Tapping a modifier arms it rather than sending anything")
    func modifierTapsLatch() throws {
        let control = try #require(ShortcutSet.default["ctrl"])
        guard case .latch(let modifiers) = ShortcutBarLayout.action(for: control, latched: []) else {
            Issue.record("ctrl should latch")
            return
        }
        #expect(modifiers == .control)
        #expect(ShortcutBarLayout.isLatched(control, in: .control))
        #expect(ShortcutBarLayout.isLatched(control, in: []) == false)
        #expect(ShortcutBarLayout.isLatched(control, in: .alt) == false)
    }

    @Test("A user shortcut types its text verbatim")
    func literalShortcutsType() {
        let shortcut = Shortcut(id: "gst", label: "gst", payload: .literal("git status\n"), order: 100)
        guard case .type(let text) = ShortcutBarLayout.action(for: shortcut, latched: .control) else {
            Issue.record("a literal shortcut should type text")
            return
        }
        // Arming ctrl does not turn a macro into a control sequence.
        #expect(text == "git status\n")
    }

    @Test("Arrows are drawn as one cluster and never also as loose keys")
    func arrowsCollapseIntoACluster() {
        let items = ShortcutBarLayout.items(for: .default)
        let clusters = items.compactMap { item -> [Shortcut]? in
            if case .cluster(let arrows) = item { return arrows }
            return nil
        }
        #expect(clusters.count == 1)
        #expect(clusters.first?.map(\.id) == ["left", "up", "down", "right"])

        let looseArrows = items.compactMap { item -> String? in
            guard case .key(let shortcut) = item else { return nil }
            return ShortcutBarLayout.arrowIDs.contains(shortcut.id) ? shortcut.id : nil
        }
        #expect(looseArrows.isEmpty)
    }

    @Test("One row keeps everything; two rows break after the arrows")
    func rowSplitFollowsTheCluster() {
        let single = ShortcutBarLayout.rows(for: .default, count: 1)
        #expect(single.count == 1)
        #expect(single[0].count == ShortcutBarLayout.items(for: .default).count)

        let double = ShortcutBarLayout.rows(for: .default, count: 2)
        #expect(double.count == 2)
        if case .cluster = double[0].last {
            // Expected: the arrow cluster closes the first row.
        } else {
            Issue.record("the first row should end with the arrow cluster")
        }
        #expect(double[1].contains { $0.id == "home" })
        #expect(double.reduce(0) { $0 + $1.count } == single[0].count)
    }

    @Test("An empty set produces an empty bar rather than a crash")
    func emptySetIsHandled() {
        let empty = ShortcutSet(shortcuts: [])
        #expect(ShortcutBarLayout.items(for: empty).isEmpty)
        #expect(ShortcutBarLayout.rows(for: empty, count: 2) == [[]])
    }
}

// MARK: - Diagnostics

@Suite("Diagnostics")
struct DiagnosticsTests {

    private func health() -> HealthInfo {
        HealthInfo(
            version: "0.4.1",
            protocolVersion: "1.0",
            agents: [.claudeCode, .codex],
            capabilities: ["approve", "read"],
            previewPorts: [3_000, 5_173],
            adapterVersions: ["claude-code": "claude-code/transcript-v1"]
        )
    }

    private func sessions() -> [SessionSummary] {
        [
            SessionSummary(
                sessionID: "sess_cc-alpha", agent: .claudeCode, state: .working,
                lastEventAt: Date(timeIntervalSince1970: 100), lastSeq: 42),
            SessionSummary(
                sessionID: "sess_cc-beta", agent: .claudeCode, state: .idle,
                lastEventAt: Date(timeIntervalSince1970: 200), lastSeq: 17),
        ]
    }

    @Test("Adapter rows merge what the host reports with what this device has read")
    func adapterRowsMergeHealthAndSessions() {
        let rows = AdapterDiagnostic.rows(health: health(), sessions: sessions())
        #expect(rows.map(\.name) == ["claude-code", "codex"])

        let claude = rows[0]
        #expect(claude.agent == .claudeCode)
        #expect(claude.formatVersion == "claude-code/transcript-v1")
        // Highest sequence across that adapter's sessions, not the first one found.
        #expect(claude.lastSeq == 42)
        #expect(claude.lastEventAt == Date(timeIntervalSince1970: 200))

        // An enabled adapter with no reported version is still listed, and says so rather than vanishing.
        #expect(rows[1].formatVersion == nil)
        #expect(rows[1].lastSeq == nil)
    }

    @Test("An adapter this build predates is still shown")
    func unknownAdaptersSurvive() {
        let future = HealthInfo(
            version: "9.0", protocolVersion: "2.0", agents: [], capabilities: [],
            adapterVersions: ["hypothetical-cli": "hypothetical/v3"])
        let rows = AdapterDiagnostic.rows(health: future, sessions: [])
        #expect(rows.count == 1)
        #expect(rows[0].agent == nil)
        #expect(rows[0].displayName == "hypothetical-cli")
        #expect(rows[0].formatVersion == "hypothetical/v3")
    }

    @Test("No health means no adapter rows rather than invented ones")
    func missingHealthProducesNoRows() {
        #expect(AdapterDiagnostic.rows(health: nil, sessions: sessions()).isEmpty)
    }

    @Test("The bug report carries the values a maintainer asks for first")
    func reportCarriesTheEssentials() {
        let text = DiagnosticsReport.text(
            health: health(),
            connection: .connected(.ssh),
            sessions: sessions(),
            repos: [RepoSummary(name: "openpaw", path: "/src/openpaw", branch: "main", dirty: true, ahead: 1, behind: 0)],
            forwardedPort: 8_787,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(text.contains("host version: 0.4.1"))
        #expect(text.contains("protocol: 1.0"))
        #expect(text.contains("connection: connected"))
        #expect(text.contains("transport: SSH"))
        #expect(text.contains("forwarded port: 8787"))
        #expect(text.contains("preview ports: 3000,5173"))
        #expect(text.contains("adapter claude-code: format_version=claude-code/transcript-v1 last_seq=42"))
        #expect(text.contains("session sess_cc-alpha: agent=claude-code state=working last_seq=42 pending=0"))
        #expect(text.contains("repo openpaw: branch=main dirty=true ahead=1 behind=0"))
    }

    @Test("A report with nothing connected still says what is missing")
    func reportHandlesAnEmptyDevice() {
        let text = DiagnosticsReport.text(
            health: nil, connection: .idle, sessions: [], repos: [], forwardedPort: nil,
            generatedAt: Date(timeIntervalSince1970: 0))
        #expect(text.contains("host version: unknown"))
        #expect(text.contains("forwarded port: not forwarded"))
        #expect(text.contains("preview ports: none"))
        #expect(text.contains("transport: none"))
    }

    @Test("A reconnecting state carries its reason into the report")
    func reportExplainsAFallback() {
        let text = DiagnosticsReport.text(
            health: nil,
            connection: .reconnecting(attempt: 2, reason: "mosh-server is not installed on the host"),
            sessions: [], repos: [], forwardedPort: nil)
        #expect(text.contains("connection: reconnecting"))
        #expect(text.contains("Attempt 2. mosh-server is not installed on the host"))
    }
}

// MARK: - Paired devices

@Suite("Paired devices")
struct PairedDeviceTests {

    @Test("Audit entries collapse into one row per device, most recent first")
    func devicesCollapseFromAudit() {
        let entries = [
            AuditEntry(
                at: Date(timeIntervalSince1970: 10), deviceID: "dev_phone", action: "resolve",
                target: "inb_1", result: "ok"),
            AuditEntry(
                at: Date(timeIntervalSince1970: 30), deviceID: "dev_phone", action: "resolve",
                target: "inb_2", result: "ok"),
            AuditEntry(
                at: Date(timeIntervalSince1970: 20), deviceID: "dev_pad", action: "pair", target: nil,
                result: "ok"),
            // Host-side actions have no device and must not invent one.
            AuditEntry(
                at: Date(timeIntervalSince1970: 40), deviceID: nil, action: "policy", target: nil, result: "ok"),
        ]

        let devices = PairedDevice.derive(from: entries)
        #expect(devices.map(\.id) == ["dev_phone", "dev_pad"])
        #expect(devices[0].actions == 2)
        #expect(devices[0].lastSeen == Date(timeIntervalSince1970: 30))
        #expect(devices[1].actions == 1)
    }

    @Test("An empty audit log names no devices")
    func emptyAuditProducesNoDevices() {
        #expect(PairedDevice.derive(from: []).isEmpty)
    }
}

// MARK: - Connection presentation

@Suite("Connection presentation")
struct ConnectionPresentationTests {

    @Test("Reconnecting always explains itself")
    func reconnectingCarriesTheReason() {
        let status = ConnectionPresentation.make(
            .reconnecting(attempt: 3, reason: "the link dropped"))
        #expect(status.label == "reconnecting")
        #expect(status.detail == "Attempt 3. the link dropped")
    }

    @Test("A recoverable failure says what happens next")
    func recoverableFailureNamesTheFallback() {
        let status = ConnectionPresentation.make(.failed(.remoteBinaryMissing(.mosh, command: "mosh-server")))
        #expect(status.label == "failed")
        #expect(status.detail?.contains("try the next transport") == true)
    }

    @Test("An unrecoverable failure promises nothing")
    func unrecoverableFailureDoesNotPromiseARetry() {
        let status = ConnectionPresentation.make(.failed(.authenticationFailed(reason: "no such user")))
        #expect(status.detail?.contains("try the next transport") == false)
    }

    @Test("The transport is only named once there is one")
    func transportLabelFollowsTheConnection() {
        #expect(ConnectionPresentation.transportLabel(.connected(.mosh)) == "Mosh")
        #expect(ConnectionPresentation.transportLabel(.connecting) == nil)
    }
}

// MARK: - Session state

@Suite("Session state presentation")
struct SessionStatePresentationTests {

    @Test("Every state has a word, a glyph and a tone")
    func everyStateIsNamed() {
        for state in SessionState.allCases {
            let presentation = SessionStatePresentation.make(state)
            #expect(presentation.label.isEmpty == false)
            #expect(presentation.glyph.isEmpty == false)
        }
    }

    @Test("Waiting says who it is waiting for")
    func waitingIsUnambiguous() {
        #expect(SessionStatePresentation.make(.waiting).label == "waiting for you")
    }
}

// MARK: - Transport availability

@Suite("Transport availability")
struct TransportAvailabilityTests {

    @Test("Automatic is always offerable")
    func automaticIsAlwaysAvailable() {
        #expect(TransportAvailability.isBuilt(nil))
        #expect(TransportAvailability.note(for: nil) == nil)
    }

    @Test("Transports that are not written yet are marked, not silently offered")
    func unbuiltTransportsAreMarked() {
        #expect(TransportAvailability.isBuilt(.ssh))
        #expect(TransportAvailability.note(for: .ssh) == nil)
        #expect(TransportAvailability.isBuilt(.mosh) == false)
        #expect(TransportAvailability.note(for: .mosh) == "not built yet")
        #expect(TransportAvailability.isBuilt(.eternalTerminal) == false)
        #expect(TransportAvailability.note(for: .eternalTerminal) == "not built yet")
    }
}

// MARK: - Settings round trip

@Suite("Settings")
struct SettingsTests {

    private func volatileDefaults(_ name: String) -> UserDefaults {
        let suite = "openpaw.tests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    @Test("Preferences survive a relaunch")
    func settingsPersist() {
        let defaults = volatileDefaults("persist")
        let first = OpenPawSettings(defaults: defaults)
        first.terminalFontSize = 17
        first.terminalTheme = .warm
        first.dictationMode = .terminal
        first.scrollbackLines = 25_000
        first.isShortcutBarVisible = false

        let second = OpenPawSettings(defaults: defaults)
        #expect(second.terminalFontSize == 17)
        #expect(second.terminalTheme == .warm)
        #expect(second.dictationMode == .terminal)
        #expect(second.scrollbackLines == 25_000)
        #expect(second.isShortcutBarVisible == false)
    }

    @MainActor
    @Test("A fresh device gets the shipped shortcut set, not an empty bar")
    func freshDeviceHasDefaultShortcuts() {
        let settings = OpenPawSettings(defaults: volatileDefaults("fresh"))
        #expect(settings.shortcuts.shortcuts.isEmpty == false)
        #expect(settings.shortcuts["esc"] != nil)
        #expect(settings.isShortcutBarVisible)
    }

    @MainActor
    @Test("Session profiles are per host and survive a relaunch")
    func profilesAreKeyedByHost() {
        let defaults = volatileDefaults("profiles")
        let host = UUID()
        let other = UUID()
        let first = OpenPawSettings(defaults: defaults)
        first.setProfile(SessionProfile(terminalType: "xterm-kitty", columns: 200, rows: 50), for: host)
        first.recordConnection(to: host, at: Date(timeIntervalSince1970: 500))

        let second = OpenPawSettings(defaults: defaults)
        #expect(second.profile(for: host).columns == 200)
        #expect(second.profile(for: host).terminalType == "xterm-kitty")
        #expect(second.profile(for: host).lastConnectedAt == Date(timeIntervalSince1970: 500))
        // An unknown host gets defaults rather than another host's geometry.
        #expect(second.profile(for: other).columns == 80)
        #expect(second.profile(for: other).lastConnectedAt == nil)

        second.forgetProfile(for: host)
        #expect(second.profile(for: host).columns == 80)
    }

    @MainActor
    @Test("An exported snapshot restores everything it carried")
    func snapshotRoundTrips() throws {
        let source = OpenPawSettings(defaults: volatileDefaults("export"))
        let host = UUID()
        source.terminalFontSize = 21
        source.terminalTheme = .well
        source.previewPort = 5_173
        source.applicationCursorKeys = true
        source.setProfile(SessionProfile(columns: 132, rows: 43), for: host)

        let data = try JSONEncoder().encode(source.snapshot(eventBudget: 5_000))
        let decoded = try JSONDecoder().decode(SettingsSnapshot.self, from: data)

        let target = OpenPawSettings(defaults: volatileDefaults("import"))
        let budget = target.apply(decoded)
        #expect(budget == 5_000)
        #expect(target.terminalFontSize == 21)
        #expect(target.terminalTheme == .well)
        #expect(target.previewPort == 5_173)
        #expect(target.applicationCursorKeys)
        #expect(target.profile(for: host).columns == 132)
        #expect(target.profile(for: host).rows == 43)
    }

    @MainActor
    @Test("An import with an absurd cell size is clamped rather than trusted")
    func importClampsFontSize() {
        let settings = OpenPawSettings(defaults: volatileDefaults("clamp"))
        var snapshot = settings.snapshot(eventBudget: 2_000)
        snapshot.terminalFontSize = 400
        settings.apply(snapshot)
        #expect(settings.terminalFontSize == OpenPawSettings.fontSizeRange.upperBound)
    }
}

// MARK: - Add device flow

@Suite("Add device flow")
struct AddDeviceFlowTests {
    private static let candidateID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let candidate = AddDeviceCandidate(id: candidateID, nickname: "Studio", hostname: "studio.tail123.ts.net")

    @Test("An empty store starts at the welcome step")
    func emptyStartsWelcome() {
        #expect(AddDeviceFlowState(hosts: []).step == .welcome)
    }

    @Test("A populated store still starts at the neutral welcome step")
    func populatedStoreStartsWelcome() {
        let host = HostRecord(nickname: "Studio", hostname: "studio.local", username: "dev", auth: .agentForwarding)
        #expect(AddDeviceFlowState(hosts: [host]).step == .welcome)
    }

    @Test("Finding Tailscale with no candidates opens the honest candidates step")
    func noCandidateTailscaleTransition() {
        var state = AddDeviceFlowState(hosts: [], discovered: [])
        state.startTailscaleDiscovery()
        #expect(state.step == .tailscaleCandidates)
        #expect(state.discovered.isEmpty)
        #expect(state.selectedCandidate == nil)
        #expect(AddDeviceFlowCopy.noCandidates == "No Tailscale devices were reported by the connected discovery host. Add SSH details to enter a device manually.")
    }

    @Test("Selecting a discovered candidate requires confirmation and does not save")
    @MainActor
    func candidateNeedsConfirmationWithoutSaving() {
        let store = HostStore()
        var state = AddDeviceFlowState(hosts: store.hosts)
        state.discovered = [Self.candidate]
        state.selectCandidate(id: Self.candidateID)
        #expect(state.step == .confirmCandidate)
        #expect(store.hosts.isEmpty)
    }

    @Test("Confirmation advances to editable SSH details with limited prefill")
    func confirmCandidateCreatesReviewPrefill() {
        var state = AddDeviceFlowState(hosts: [])
        state.discovered = [Self.candidate]
        state.selectCandidate(id: Self.candidateID)
        let prefill = state.confirmSelectedCandidate()
        #expect(state.step == .editDetails)
        #expect(prefill?.hostname == "studio.tail123.ts.net")
        #expect(prefill?.nickname == "Studio")
        #expect(prefill?.username == "")
        #expect(prefill?.tags.isEmpty == true)
    }

    @Test("Exact empty Home action copy is stable")
    func emptyHomeActionCopy() {
        #expect(WorkspaceHomeCopy.emptyPrimaryAction == "Add a Tailscale or SSH device")
    }

    @Test("No empty or onboarding copy says tunnel down")
    func noTunnelDownCopy() {
        for line in WorkspaceHomeCopy.emptyAndOnboardingCopy + AddDeviceFlowCopy.onboardingCopy {
            #expect(!line.localizedCaseInsensitiveContains("tunnel down"))
        }
    }

    @Test("Manual SSH opens editable details without prefill")
    func manualSSHOpensBlankDetails() {
        var state = AddDeviceFlowState(hosts: [])
        let draft = state.startManualSSH()
        #expect(state.step == .editDetails)
        #expect(draft.hostname == "")
        #expect(draft.nickname == "")
    }

    @Test("Back navigation reverses candidate and edit detail steps")
    func backNavigationReversesSteps() {
        var state = AddDeviceFlowState(hosts: [], discovered: [Self.candidate])
        state.startTailscaleDiscovery()
        state.back()
        #expect(state.step == .welcome)

        state.startTailscaleDiscovery()
        state.selectCandidate(id: Self.candidateID)
        state.back()
        #expect(state.step == .tailscaleCandidates)

        state.selectCandidate(id: Self.candidateID)
        _ = state.confirmSelectedCandidate()
        state.back()
        #expect(state.step == .confirmCandidate)

        state.back()
        state.back()
        _ = state.startManualSSH()
        state.back()
        #expect(state.step == .welcome)

        state.startTailscaleDiscovery()
        _ = state.startManualSSH()
        state.back()
        #expect(state.step == .tailscaleCandidates)
    }

    @Test("Host editor cancel route can be represented by flow state")
    func hostEditorCancelCanRouteBackThroughState() {
        var state = AddDeviceFlowState(hosts: [], discovered: [Self.candidate])
        state.startTailscaleDiscovery()
        state.selectCandidate(id: Self.candidateID)
        _ = state.confirmSelectedCandidate()
        let cancel = { state.back() }
        cancel()
        #expect(state.step == .confirmCandidate)
    }



    @Test("Selecting a live model candidate snapshots it into flow state for confirmation")
    func selectingLiveCandidateUsesStableModelIdentity() {
        let live = AddDeviceCandidate(id: "node-live", nickname: "Live Studio", hostname: "live.tail.ts.net")
        var state = AddDeviceFlowState(hosts: [], discovered: [])
        state.startTailscaleDiscovery()
        state.selectCandidate(id: live.id, from: [live])
        #expect(state.step == .confirmCandidate)
        #expect(state.selectedCandidate?.id == "node-live")
        #expect(state.selectedCandidate?.hostname == "live.tail.ts.net")
    }

    @MainActor
    @Test("Tailscale discovery is gated on a selected connected host")
    func discoveryRequiresConnectedSelectedHost() async {
        let backend = RecordingBackend()
        let model = OpenPawModel(hostStore: HostStore(), backend: backend)
        model.refreshTailscaleDevices()
        #expect(model.tailscaleDiscovery == .noConnectedHost)
        #expect(backend.callCount("tailscaleDevices") == 0)
    }

    @MainActor
    @Test("Tailscale discovery loads candidates and suppresses stale cancelled responses")
    func discoveryLoadsAndCancelsStaleResponses() async throws {
        let host = HostRecord(nickname: "Studio", hostname: "studio.local", username: "dev", auth: .agentForwarding)
        let backend = RecordingBackend()
        backend.tailscaleDelayNanoseconds = 50_000_000
        backend.tailscaleResponse = TailscaleDevicesResponse(version: 1, candidates: [
            TailscaleDeviceCandidate(id: "node-late", displayName: "Late", dnsName: "late.tail.ts.net", tailscaleIPs: ["100.64.0.9"], online: true)
        ])
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]), backend: backend)
        model.connection = .connected(.ssh)
        model.refreshTailscaleDevices()
        #expect(model.tailscaleDiscovery == .loading)
        model.cancelTailscaleDiscovery()
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(model.tailscaleDiscovery == .idle)

        backend.tailscaleDelayNanoseconds = 0
        model.refreshTailscaleDevices()
        for _ in 0..<100 where model.tailscaleDiscovery.candidates.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.tailscaleDiscovery.candidates.map(\.id) == ["node-late"])
    }

    @Test("Candidate accessibility label includes exact safety semantics")
    func candidateAccessibilityLabelIncludesSafetySemantics() {
        #expect(Self.candidate.accessibilityLabel == "Studio, studio.tail123.ts.net, candidate from paired host Tailscale discovery, not trusted or saved")
    }
}

@Suite("A connection that fails before it is ever established")
struct FailedFirstConnectionTests {

    /// The defect a user sees as a card stuck on "Connecting" with a spinner that never stops: an unknown host key
    /// fails the attempt immediately, but the failure never reaches `connection`, so the UI keeps claiming the
    /// connection is still in progress and offers nothing to act on.
    @MainActor
    @Test("a failure on the first attempt is shown instead of leaving the card spinning")
    func firstAttemptFailureReachesTheUI() async {
        let host = HostRecord(nickname: "One", hostname: "one", username: "dev", auth: .agentForwarding)
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]), backend: nil, terminal: terminal)
        let failure = TransportError.hostKeyUnknown(fingerprint: "SHA256:whatever")
        terminal.failConnectWith = failure

        await model.connectSelectedHost()
        // The state task drains `stateStream` independently, so a single yield is not enough to guarantee it ran
        // under parallel test load. A bounded wait still catches the defect: without the fix the state is dropped
        // and the connection never becomes terminal no matter how long the wait.
        for _ in 0..<100 where !model.connection.isTerminal {
            await Task.yield()
        }

        #expect(
            model.connection.isTerminal,
            "the card is still showing \(model.connection), so the spinner never resolves"
        )
    }

    /// An unknown host key is a decision the trust sheet exists to take, not a failure to report. Raising an error
    /// alert for it too puts two presentations on screen at once, and the alert wins: SwiftUI dismisses the sheet
    /// by writing `nil` back through its binding, so the user never sees the fingerprint and can never connect.
    @MainActor
    @Test("an unknown host key does not also raise an error alert that would displace the trust sheet")
    func unknownHostKeyDoesNotRaiseAnAlert() async {
        let host = HostRecord(nickname: "One", hostname: "one", username: "dev", auth: .agentForwarding)
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(hostStore: HostStore(hosts: [host]), backend: nil, terminal: terminal)
        terminal.failConnectWith = .hostKeyUnknown(fingerprint: "SHA256:whatever")

        await model.connectSelectedHost()
        for _ in 0..<100 where !model.connection.isTerminal {
            await Task.yield()
        }

        #expect(
            model.lastError == nil,
            "an alert (\(String(describing: model.lastError?.title))) would displace the host key sheet"
        )
    }
}
