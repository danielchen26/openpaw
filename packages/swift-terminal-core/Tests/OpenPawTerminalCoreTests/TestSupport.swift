import Foundation
import OpenPawTerminalCore

/// A ``CommandRunner`` that answers from a rule table and records what ran.
actor StubRunner: CommandRunner {
    private struct Rule {
        let needle: String
        let result: Result<String, CommandFailure>
    }

    private let rules: [Rule]
    private var executed: [String] = []

    init(_ rules: [(String, Result<String, CommandFailure>)]) {
        self.rules = rules.map { Rule(needle: $0.0, result: $0.1) }
    }

    func run(_ command: String) async throws -> String {
        executed.append(command)
        for rule in rules where command.contains(rule.needle) {
            switch rule.result {
            case .success(let output): return output
            case .failure(let failure): throw failure
            }
        }
        throw CommandFailure(command: command, exitCode: 127, output: "sh: command not found")
    }

    func commands() -> [String] { executed }
}

extension Result where Success == String, Failure == CommandFailure {
    static func output(_ text: String) -> Self { .success(text) }

    static func failing(_ text: String, exitCode: Int32 = 1) -> Self {
        .failure(CommandFailure(command: "", exitCode: exitCode, output: text))
    }
}

enum Fixtures {
    static let separator = Multiplexer.fieldSeparator

    static func tmuxRow(_ fields: [String]) -> String {
        fields.joined(separator: separator)
    }

    static func keychain(_ identifier: String) -> KeychainReference {
        // Test-only: identifiers here are always valid, so a trap on failure is
        // the right signal.
        try! KeychainReference(identifier: identifier)
    }

    static func host(
        nickname: String = "beta",
        hostname: String = "beta.local",
        preferred: TransportKind? = nil,
        lastSuccessful: TransportKind? = nil,
        knownHosts: [KnownHostEntry] = []
    ) -> HostRecord {
        HostRecord(
            id: UUID(uuidString: "1E1D6A8C-0000-4000-8000-00000000BEEF")!,
            nickname: nickname,
            hostname: hostname,
            port: 2022,
            username: "dev",
            auth: .privateKey(
                reference: keychain("kc://openpaw/beta/key"),
                passphraseRef: keychain("kc://openpaw/beta/passphrase")),
            preferredTransport: preferred,
            lastSuccessfulTransport: lastSuccessful,
            multiplexerPreference: .tmux,
            knownHosts: knownHosts,
            tags: ["work", "arm64"]
        )
    }

    static func configuration() -> ConnectionConfiguration {
        ConnectionConfiguration(
            host: "beta.local",
            port: 2022,
            username: "dev",
            auth: .password(reference: keychain("kc://openpaw/beta/password")),
            initialSize: PTYSize(columns: 80, rows: 24)
        )
    }
}
