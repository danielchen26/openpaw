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

    func testHerdrParsesJSONListing() async throws {
        let json = """
            {"sessions":[
              {"id":"hd_01","name":"api","attached":true,"windows":2,
               "created_at":"2026-08-20T14:00:00Z","last_activity_at":"2026-08-20T14:29:00Z",
               "cwd":"/srv/api","alive":true},
              {"id":"hd_02","name":"worker","attached":false,"windows":1,"alive":false}
            ]}
            """
        let runner = StubRunner([("herdr list --json", .output(json))])
        let sessions = try await HerdrAdapter().discoverSessions(runner: runner)

        XCTAssertEqual(sessions.map(\.id), ["hd_01", "hd_02"])
        XCTAssertEqual(sessions.map(\.name), ["api", "worker"])
        XCTAssertEqual(sessions.map(\.isAttached), [true, false])
        XCTAssertEqual(sessions.map(\.isAlive), [true, false])
        XCTAssertEqual(sessions[0].windowCount, 2)
        XCTAssertEqual(sessions[0].workingDirectory, "/srv/api")
        XCTAssertEqual(
            sessions[0].createdAt,
            ISO8601DateFormatter().date(from: "2026-08-20T14:00:00Z"))
        XCTAssertNil(sessions[1].createdAt)
    }

    func testHerdrDegradesToEmptyOnUnknownSubcommand() async throws {
        let runner = StubRunner([
            ("herdr list --json", .failing("error: unrecognized subcommand 'list'", exitCode: 2))
        ])
        let sessions = try await HerdrAdapter().discoverSessions(runner: runner)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testHerdrWindowsAndCommandStrings() async throws {
        let json = """
            {"windows":[{"id":"w1","index":0,"name":"api","active":true,"panes":2,
                         "command":"cargo","cwd":"/srv/api"}]}
            """
        let runner = StubRunner([("herdr windows", .output(json))])
        let adapter = HerdrAdapter()
        let session = RemoteSession.target("hd_01", kind: .herdr)
        let windows = try await adapter.listWindows(session: session, runner: runner)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].currentCommand, "cargo")
        XCTAssertTrue(windows[0].isActive)

        XCTAssertEqual(adapter.attach(session), "herdr attach hd_01")
        XCTAssertEqual(adapter.kill(session), "herdr kill hd_01")
        XCTAssertEqual(adapter.rename(session, to: "api 2"), "herdr rename hd_01 'api 2'")
        XCTAssertEqual(
            adapter.focus(window: windows[0]), "herdr focus --session hd_01 --window w1")
    }

    func testHerdrRejectsNonJSON() {
        XCTAssertThrowsError(try HerdrAdapter().parseSessions("<html>nope</html>"))
    }

    // MARK: factory

    func testAdapterFactoryCoversEveryKind() {
        for kind in MultiplexerKind.allCases {
            XCTAssertEqual(MultiplexerAdapters.adapter(for: kind).kind, kind)
        }
        XCTAssertEqual(MultiplexerAdapters.all.map(\.kind), [.tmux, .zellij, .screen, .herdr])
    }
}
