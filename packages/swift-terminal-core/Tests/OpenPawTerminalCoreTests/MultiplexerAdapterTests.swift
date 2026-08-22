import XCTest

@testable import OpenPawTerminalCore

final class MultiplexerAdapterTests: XCTestCase {

    // MARK: tmux

    private var tmuxSessionOutput: String {
        [
            Fixtures.tmuxRow([
                "$0", "agent main", "1", "3", "1755697800", "1755701400", "/Users/dev/openpaw",
            ]),
            Fixtures.tmuxRow(["$1", "codex", "0", "1", "1755690000", "1755690600", ""]),
        ].joined(separator: "\n")
    }

    func testTmuxDiscoversSessionsIncludingNameWithSpace() async throws {
        let runner = StubRunner([("tmux list-sessions", .output(tmuxSessionOutput))])
        let sessions = try await TmuxAdapter().discoverSessions(runner: runner)

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].id, "$0")
        XCTAssertEqual(sessions[0].name, "agent main")
        XCTAssertTrue(sessions[0].isAttached)
        XCTAssertTrue(sessions[0].isAlive)
        XCTAssertEqual(sessions[0].windowCount, 3)
        XCTAssertEqual(sessions[0].createdAt, Date(timeIntervalSince1970: 1_755_697_800))
        XCTAssertEqual(sessions[0].lastActivityAt, Date(timeIntervalSince1970: 1_755_701_400))
        XCTAssertEqual(sessions[0].workingDirectory, "/Users/dev/openpaw")
        XCTAssertEqual(sessions[0].kind, .tmux)

        XCTAssertEqual(sessions[1].name, "codex")
        XCTAssertFalse(sessions[1].isAttached)
        XCTAssertNil(sessions[1].workingDirectory)

        let commands = await runner.commands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].hasPrefix("tmux list-sessions -F '#{session_id}"))
        XCTAssertTrue(commands[0].contains("#{session_activity}"))
    }

    func testTmuxReturnsEmptyListWhenNoServerRunning() async throws {
        let runner = StubRunner([
            ("tmux list-sessions", .failing("no server running on /private/tmp/tmux-501/default"))
        ])
        let sessions = try await TmuxAdapter().discoverSessions(runner: runner)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testTmuxPropagatesRealFailures() async {
        let runner = StubRunner([("tmux list-sessions", .failing("Killed", exitCode: 137))])
        do {
            _ = try await TmuxAdapter().discoverSessions(runner: runner)
            XCTFail("expected the command failure to propagate")
        } catch let failure as CommandFailure {
            XCTAssertEqual(failure.exitCode, 137)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testTmuxParsesWindowsAndPanes() async throws {
        let windows = [
            Fixtures.tmuxRow(["@0", "0", "editor", "1", "2", "nvim", "/Users/dev/openpaw"]),
            Fixtures.tmuxRow(["@1", "1", "my window", "0", "1", "zsh", "/Users/dev"]),
        ].joined(separator: "\n")
        let panes = [
            Fixtures.tmuxRow([
                "%0", "0", "1", "120", "40", "nvim", "/Users/dev/openpaw", "openpaw — nvim",
            ]),
            Fixtures.tmuxRow(["%1", "1", "0", "120", "9", "zsh", "/Users/dev/openpaw", ""]),
        ].joined(separator: "\n")
        let runner = StubRunner([
            ("tmux list-windows", .output(windows)),
            ("tmux list-panes", .output(panes)),
        ])

        let adapter = TmuxAdapter()
        let session = RemoteSession.target("$0", kind: .tmux)
        let parsedWindows = try await adapter.listWindows(session: session, runner: runner)
        XCTAssertEqual(parsedWindows.map(\.name), ["editor", "my window"])
        XCTAssertEqual(parsedWindows.map(\.index), [0, 1])
        XCTAssertEqual(parsedWindows.map(\.isActive), [true, false])
        XCTAssertEqual(parsedWindows[0].paneCount, 2)
        XCTAssertEqual(parsedWindows[0].currentCommand, "nvim")
        XCTAssertEqual(parsedWindows[0].sessionID, "$0")

        let parsedPanes = try await adapter.listPanes(window: parsedWindows[0], runner: runner)
        XCTAssertEqual(parsedPanes.map(\.id), ["%0", "%1"])
        XCTAssertEqual(parsedPanes.map(\.isActive), [true, false])
        XCTAssertEqual(parsedPanes[0].width, 120)
        XCTAssertEqual(parsedPanes[0].height, 40)
        XCTAssertEqual(parsedPanes[0].title, "openpaw — nvim")
        XCTAssertNil(parsedPanes[1].title)
        XCTAssertEqual(parsedPanes[1].windowID, "@0")

        let commands = await runner.commands()
        XCTAssertEqual(commands[0], "tmux list-windows -t '$0' -F \(shellQuoted(TmuxAdapter.windowFormat))")
        XCTAssertEqual(commands[1], "tmux list-panes -t @0 -F \(shellQuoted(TmuxAdapter.paneFormat))")
    }

    func testTmuxRejectsTruncatedRows() {
        XCTAssertThrowsError(try TmuxAdapter().parseSession("$0\u{1F}only-two")) { error in
            guard case MultiplexerError.malformedOutput(let kind, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(kind, .tmux)
        }
    }

    func testTmuxCommandStrings() {
        let adapter = TmuxAdapter()
        let session = RemoteSession.target("agent main", kind: .tmux)
        XCTAssertEqual(adapter.attach(session), "tmux attach-session -t 'agent main'")
        XCTAssertEqual(adapter.kill(session), "tmux kill-session -t 'agent main'")
        XCTAssertEqual(
            adapter.create(name: "api", directory: "/srv/api"),
            "tmux new-session -A -s api -c /srv/api")
        XCTAssertEqual(adapter.create(name: "api", directory: nil), "tmux new-session -A -s api")
        XCTAssertEqual(
            adapter.focus(window: RemoteWindow(id: "@2", sessionID: "$0", index: 2, name: "logs")),
            "tmux select-window -t @2")
        XCTAssertEqual(adapter.kind, .tmux)
    }

    // MARK: Zellij

    func testZellijParsesSessionsIncludingExited() async throws {
        let output = """
            agent-main [Created 2h 14m 3s ago] (current)
            codex-run [Created 12m 5s ago]
            stale [Created 3d 1h 0s ago] (EXITED - attach to resurrect)
            """
        let runner = StubRunner([("zellij list-sessions", .output(output))])
        let sessions = try await ZellijAdapter().discoverSessions(runner: runner)

        XCTAssertEqual(sessions.map(\.name), ["agent-main", "codex-run", "stale"])
        XCTAssertEqual(sessions.map(\.isAttached), [true, false, false])
        XCTAssertEqual(sessions.map(\.isAlive), [true, true, false])
        XCTAssertEqual(sessions[0].uptime, 2 * 3600 + 14 * 60 + 3)
        XCTAssertEqual(sessions[1].uptime, 12 * 60 + 5)
        XCTAssertEqual(sessions[2].uptime, 3 * 86400 + 3600)
        XCTAssertEqual(sessions[0].kind, .zellij)

        let commands = await runner.commands()
        XCTAssertEqual(commands, ["zellij list-sessions --no-formatting"])
    }

    func testZellijEmptyListing() async throws {
        let runner = StubRunner([
            ("zellij list-sessions", .output("No active zellij sessions found.\n"))
        ])
        let sessions = try await ZellijAdapter().discoverSessions(runner: runner)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testZellijTabsAndCommandStrings() async throws {
        let runner = StubRunner([("query-tab-names", .output("Tab #1\nlogs\n"))])
        let adapter = ZellijAdapter()
        let session = RemoteSession.target("agent-main", kind: .zellij)
        let tabs = try await adapter.listWindows(session: session, runner: runner)
        XCTAssertEqual(tabs.map(\.name), ["Tab #1", "logs"])
        XCTAssertEqual(tabs.map(\.index), [0, 1])
        XCTAssertEqual(tabs[1].id, "agent-main:1")

        XCTAssertEqual(adapter.attach(session), "zellij attach agent-main")
        XCTAssertEqual(
            adapter.create(name: "api", directory: "/srv/a b"),
            "cd '/srv/a b' && zellij --session api")
        XCTAssertEqual(adapter.create(name: "api", directory: nil), "zellij --session api")
        XCTAssertEqual(
            adapter.focus(window: tabs[1]),
            "zellij --session agent-main action go-to-tab-name logs")
        XCTAssertEqual(
            adapter.rename(session, to: "renamed"),
            "zellij --session agent-main action rename-session renamed")
    }

    // MARK: screen

    func testScreenParsesListingIncludingDeadSession() async throws {
        let output = """
            There are screens on:
            \t31183.agent-main\t(Detached)
            \t31200.pts-0.host\t(Attached)
            \t28763.stale\t(Dead ???)
            3 Sockets in /run/screen/S-dev.
            """
        let runner = StubRunner([("screen -ls", .failing(output))])
        let sessions = try await ScreenAdapter().discoverSessions(runner: runner)

        XCTAssertEqual(sessions.map(\.id), ["31183.agent-main", "31200.pts-0.host", "28763.stale"])
        XCTAssertEqual(sessions.map(\.name), ["agent-main", "pts-0.host", "stale"])
        XCTAssertEqual(sessions.map(\.isAttached), [false, true, false])
        XCTAssertEqual(sessions.map(\.isAlive), [true, true, false])
        XCTAssertEqual(sessions[0].kind, .screen)
    }

    func testScreenEmptyListing() async throws {
        let runner = StubRunner([
            ("screen -ls", .failing("No Sockets found in /run/screen/S-dev.\n"))
        ])
        let sessions = try await ScreenAdapter().discoverSessions(runner: runner)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testScreenWindowsAndCommandStrings() async throws {
        let runner = StubRunner([("-Q windows", .output("0*$ zsh  1-$ nvim  2 tail -f log\n"))])
        let adapter = ScreenAdapter()
        let session = RemoteSession.target("31183.agent-main", kind: .screen)
        let windows = try await adapter.listWindows(session: session, runner: runner)

        XCTAssertEqual(windows.map(\.index), [0, 1, 2])
        XCTAssertEqual(windows.map(\.name), ["zsh", "nvim", "tail -f log"])
        XCTAssertEqual(windows.map(\.isActive), [true, false, false])
        XCTAssertEqual(windows[0].id, "31183.agent-main:0")

        XCTAssertEqual(adapter.attach(session), "screen -x 31183.agent-main")
        XCTAssertEqual(adapter.kill(session), "screen -S 31183.agent-main -X quit")
        XCTAssertEqual(
            adapter.focus(window: windows[1]), "screen -S 31183.agent-main -X select 1")
        XCTAssertEqual(
            adapter.rename(session, to: "new name"),
            "screen -S 31183.agent-main -X sessionname 'new name'")
        XCTAssertEqual(
            adapter.create(name: "api", directory: "/srv/api"),
            "cd /srv/api && screen -S api")
    }

    // MARK: Herdr







    func testHerdrRejectsNonJSON() {
        XCTAssertThrowsError(try HerdrAdapter().parseSessions("<html>nope</html>"))
    }


    // MARK: Herdr — against the real CLI

    /// Verbatim `herdr agent list` output from a real host. The app previously invoked `herdr list --json`, a
    /// subcommand that does not exist, so every agent on the host was invisible in Chat.
    private static let realPaneListingJSON = """
        {"id":"cli:pane:list","result":{"panes":[\
        {"agent":"pi","agent_session":{"agent":"pi","kind":"path","source":"herdr:pi",\
        "value":"/Users/tianchichen/.pi/agent/sessions/x.jsonl"},"agent_status":"idle",\
        "cwd":"/Users/tianchichen","focused":false,"foreground_cwd":"/Users/tianchichen",\
        "pane_id":"w3:p1","revision":1,"screen_detection_skipped":true,"state_change_seq":137,\
        "tab_id":"w3:t1","terminal_id":"term_65909b7e01df01","terminal_title":"π - tianchichen",\
        "terminal_title_stripped":"π - tianchichen","workspace_id":"w3"},\
        {"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude",\
        "value":"51d4bacb-b04e-484d-9a90-eabb22cd488e"},"agent_status":"working",\
        "cwd":"/Users/tianchichen","focused":true,"foreground_cwd":"/Users/tianchichen",\
        "pane_id":"w3:p9","revision":1149,"state_change_seq":145,"tab_id":"w3:t1",\
        "terminal_id":"term_65909b7e020c13","terminal_title":"✳ 修复Codex和Claude不可用的问题",\
        "terminal_title_stripped":"修复Codex和Claude不可用的问题","workspace_id":"w3"}],\
        "type":"pane_list"}}
        """

    func testHerdrDiscoversAgentsFromTheRealCLI() async throws {
        let runner = StubRunner([("herdr pane list", .output(Self.realPaneListingJSON))])
        let sessions = try await HerdrAdapter().discoverSessions(runner: runner)

        XCTAssertEqual(sessions.map(\.id), ["w3:p1", "w3:p9"])
        // The pane title is what the user recognises the agent by, not the agent binary name.
        XCTAssertEqual(sessions.map(\.name), ["π - tianchichen", "修复Codex和Claude不可用的问题"])
        XCTAssertEqual(sessions.map(\.isAttached), [false, true])
        XCTAssertEqual(sessions.allSatisfy { $0.kind == .herdr }, true)
        XCTAssertEqual(sessions.first?.workingDirectory, "/Users/tianchichen")
    }

    func testHerdrUsesTheSubcommandsTheCLIActuallyHas() async throws {
        let runner = StubRunner([("herdr pane list", .output(Self.realPaneListingJSON))])
        let adapter = HerdrAdapter()
        _ = try await adapter.discoverSessions(runner: runner)
        let executed = await runner.commands()
        // `herdr list` does not exist, and `herdr agent list` omits the bare shells the phone creates.
        XCTAssertEqual(executed, ["herdr pane list", "herdr tab list"])

        let session = RemoteSession.target("w3:p9", kind: .herdr)
        XCTAssertEqual(adapter.attach(session), "herdr agent attach w3:p9")
        XCTAssertEqual(adapter.kill(session), "herdr pane close w3:p9")
        XCTAssertEqual(adapter.rename(session, to: "api 2"), "herdr agent rename w3:p9 'api 2'")
        XCTAssertEqual(adapter.create(name: "api", directory: "/srv/a b"), "herdr tab create --cwd '/srv/a b' --label api --focus")
        XCTAssertEqual(adapter.create(name: "api", directory: nil), "herdr tab create --label api --focus")
    }

    func testHerdrWithNoServerRunningIsAnEmptyListNotAnError() async throws {
        // A host where Herdr is installed but not started must not raise a banner over Chat.
        for message in [
            "error: could not connect to server",
            "herdr: command not found",
            "unknown command: list",
            "usage: herdr agent list",
        ] {
            let failing = StubRunner([("herdr pane list", .failing(message, exitCode: 1))])
            let viaFailure = try await HerdrAdapter().discoverSessions(runner: failing)
            XCTAssertTrue(viaFailure.isEmpty, "failed \(message)")

            // Herdr reports most of these on stdout with exit 0, so the success path needs the same handling.
            let succeeding = StubRunner([("herdr pane list", .output(message))])
            let viaOutput = try await HerdrAdapter().discoverSessions(runner: succeeding)
            XCTAssertTrue(viaOutput.isEmpty, "output \(message)")
        }
    }

    func testHerdrReportsTheSocketAPIErrorEnvelopeAsMalformed() {
        // `{"error":{...}}` carries no agents; decoding it as a listing would silently show an empty Chat.
        let json = #"{"error":{"code":"pane_not_found","message":"nope"},"id":"cli:pane:list"}"#
        XCTAssertThrowsError(try HerdrAdapter().parseSessions(json)) { error in
            guard case MultiplexerError.malformedOutput(let kind, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(kind, .herdr)
        }
    }

    func testHerdrFallsBackToTheAgentNameWhenThePaneHasNoTitle() throws {
        let json = #"{"result":{"panes":[{"pane_id":"w1:p1","agent":"codex","terminal_title_stripped":"  "}]}}"#
        let sessions = try HerdrAdapter().parseSessions(json)
        XCTAssertEqual(sessions.map(\.name), ["codex"])
    }

    func testHerdrTreatsAnAgentPaneAsItsOwnSingleWindow() async throws {
        let runner = StubRunner([("herdr pane list", .output(Self.realPaneListingJSON))])
        let adapter = HerdrAdapter()
        let sessions = try await adapter.discoverSessions(runner: runner)
        let claude = try XCTUnwrap(sessions.first { $0.id == "w3:p9" })
        let windows = try await adapter.listWindows(session: claude, runner: runner)
        XCTAssertEqual(windows.map(\.id), ["w3:p9"])
        XCTAssertEqual(windows.first?.name, "修复Codex和Claude不可用的问题")
        XCTAssertEqual(windows.first.map(adapter.focus(window:)), "herdr agent focus w3:p9")
    }

    /// Verbatim `herdr pane list` output: one agent pane, and one bare shell created from the phone. A shell pane has
    /// no agent and no title, so it is named by its tab's label.
    private static let realPaneListJSON = """
        {"id":"cli:pane:list","result":{"panes":[\
        {"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude",\
        "value":"51d4bacb"},"agent_status":"idle","cwd":"/Users/tianchichen","focused":false,\
        "foreground_cwd":"/Users/tianchichen","pane_id":"w3:p9","revision":1149,\
        "scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":51},\
        "tab_id":"w3:t1","terminal_id":"term_65909b7e020c13",\
        "terminal_title":"✳ 修复Codex和Claude不可用的问题",\
        "terminal_title_stripped":"修复Codex和Claude不可用的问题","workspace_id":"w3"},\
        {"agent_status":"unknown","cwd":"/Users/tianchichen/tmp","focused":false,\
        "foreground_cwd":"/Users/tianchichen/tmp","pane_id":"w4:p6","revision":0,\
        "scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":53},\
        "tab_id":"w4:t4","terminal_id":"term_659a4f2c68d8513","workspace_id":"w4"}],\
        "type":"pane_list"}}
        """

    private static let realTabListJSON = """
        {"id":"cli:tab:list","result":{"tabs":[\
        {"agent_status":"idle","focused":false,"label":"1","number":1,"pane_count":2,\
        "tab_id":"w3:t1","workspace_id":"w3"},\
        {"agent_status":"unknown","focused":false,"label":"openpaw-uitest","number":4,\
        "pane_count":1,"tab_id":"w4:t4","workspace_id":"w4"}],"type":"tab_list"}}
        """

    func testHerdrListsShellPanesNotJustAgents() async throws {
        // A session created from the phone is a bare shell with no agent in it yet. Listing only agents made every
        // freshly created session invisible, so creation looked like it had done nothing.
        let runner = StubRunner([
            ("herdr pane list", .output(Self.realPaneListJSON)),
            ("herdr tab list", .output(Self.realTabListJSON)),
        ])
        let sessions = try await HerdrAdapter().discoverSessions(runner: runner)

        XCTAssertEqual(sessions.map(\.id), ["w3:p9", "w4:p6"])
        // The shell pane has no title of its own, so it is named by the tab label the user typed.
        XCTAssertEqual(sessions.map(\.name), ["修复Codex和Claude不可用的问题", "openpaw-uitest"])
        XCTAssertEqual(sessions.map(\.workingDirectory), ["/Users/tianchichen", "/Users/tianchichen/tmp"])
    }

    func testHerdrStillListsPanesWhenTabLabelsAreUnavailable() async throws {
        // Tab labels are a nicety; losing them must not lose the sessions themselves.
        let runner = StubRunner([
            ("herdr pane list", .output(Self.realPaneListJSON)),
            ("herdr tab list", .failing("error: could not connect to server", exitCode: 1)),
        ])
        let sessions = try await HerdrAdapter().discoverSessions(runner: runner)
        XCTAssertEqual(sessions.map(\.id), ["w3:p9", "w4:p6"])
        XCTAssertEqual(sessions.last?.name, "w4:p6")
    }

    // MARK: factory

    func testAdapterFactoryCoversEveryKind() {
        for kind in MultiplexerKind.allCases {
            XCTAssertEqual(MultiplexerAdapters.adapter(for: kind).kind, kind)
        }
        XCTAssertEqual(MultiplexerAdapters.all.map(\.kind), [.tmux, .zellij, .screen, .herdr])
    }
}
