import XCTest

@testable import OpenPawTerminalCore

final class ShellQuotingTests: XCTestCase {
    func testLeavesPlainWordsAlone() {
        XCTAssertEqual(shellQuoted("main"), "main")
        XCTAssertEqual(shellQuoted("/srv/api-2.0"), "/srv/api-2.0")
        XCTAssertEqual(shellQuoted("user@host:22"), "user@host:22")
    }

    func testNeutralisesCommandInjection() {
        XCTAssertEqual(shellQuoted("; rm -rf /"), "'; rm -rf /'")
        XCTAssertEqual(shellQuoted("$(id)"), "'$(id)'")
        XCTAssertEqual(shellQuoted("`id`"), "'`id`'")
        XCTAssertEqual(shellQuoted("a && b || c"), "'a && b || c'")
        XCTAssertEqual(shellQuoted("*"), "'*'")
        XCTAssertEqual(shellQuoted("~/secrets"), "'~/secrets'")
    }

    func testQuotesEmbeddedSingleQuotes() {
        // The only safe encoding: close, escape, reopen.
        XCTAssertEqual(shellQuoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(shellQuoted("'"), #"''\'''"#)
        XCTAssertEqual(shellQuoted("a'; rm -rf /"), #"'a'\''; rm -rf /'"#)
    }

    func testPreservesNewlinesAndEmptyString() {
        XCTAssertEqual(shellQuoted("line1\nline2"), "'line1\nline2'")
        XCTAssertEqual(shellQuoted(""), "''")
    }

    func testAdapterCommandsQuoteHostileSessionNames() {
        let hostile = RemoteSession.target("a'; rm -rf /", kind: .tmux)
        XCTAssertEqual(
            TmuxAdapter().attach(hostile),
            #"tmux attach-session -t 'a'\''; rm -rf /'"#)
        XCTAssertEqual(
            TmuxAdapter().rename(hostile, to: "$(id)"),
            #"tmux rename-session -t 'a'\''; rm -rf /' '$(id)'"#)
        XCTAssertEqual(
            ZellijAdapter().kill(.target("`id`", kind: .zellij)),
            "zellij kill-session '`id`'")
        XCTAssertEqual(
            ScreenAdapter().attach(.target("1.a b", kind: .screen)),
            "screen -x '1.a b'")
        XCTAssertEqual(
            HerdrAdapter().create(name: "api", directory: "/srv/a b"),
            "herdr workspace create --cwd '/srv/a b' --label api --focus")
        let herdr = RemoteSession(
            id: "w3:p9; close all",
            name: "agent",
            kind: .herdr,
            terminalID: "term_9; cat secrets")
        XCTAssertEqual(
            HerdrAdapter().attach(herdr),
            "herdr terminal attach 'term_9; cat secrets'")
        XCTAssertEqual(
            HerdrAdapter().kill(herdr),
            "herdr pane close 'w3:p9; close all'")
    }
}
