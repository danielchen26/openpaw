import Foundation
import OpenPawTerminalCore

/// Asks the remote `openpaw-host` for a pairing code over the SSH connection that is already open.
///
/// The pairing code exists because the daemon binds loopback and will not hand a device token to whoever can reach the
/// port. Historically the only way to get one was to walk to the machine and run `openpaw-host pairing-code`. But a
/// user who has already authenticated an SSH session to that machine has proven exactly the thing the code is there to
/// prove: they control the account the daemon runs as. So the phone may mint one for itself through that session.
///
/// What this deliberately does *not* do is lower any bar. The code still comes from the running daemon, still expires,
/// still is single-use, and still carries the profile the daemon decides. If the SSH session does not have the rights
/// to reach the hook token, the command fails on the host and no pairing happens.
public struct RemotePairingCodeRequest: Sendable {
    /// Why a self-service pairing request could not produce a code.
    public enum Failure: Error, Sendable, Hashable, CustomStringConvertible {
        /// No `openpaw-host` executable on the remote PATH.
        case hostBinaryMissing
        /// The binary exists but the daemon is not running, so nothing can mint a code.
        case daemonNotRunning
        /// The command ran but printed nothing that parses as a pairing code.
        case unreadableOutput(String)
        /// The remote refused, e.g. the SSH user cannot read the state directory's hook token.
        case refused(String)

        public var description: String {
            switch self {
            case .hostBinaryMissing:
                return "openpaw-host is not installed on that machine, or it is not on the PATH of this SSH user."
            case .daemonNotRunning:
                return "openpaw-host is installed but not running. Start it with `openpaw-host serve` and try again."
            case .unreadableOutput(let output):
                return "openpaw-host did not return a pairing code. It said: \(output)"
            case .refused(let message):
                return "The host refused to issue a pairing code: \(message)"
            }
        }
    }

    /// The command sent over its own exec channel.
    ///
    /// `pairing-code` without `--qr` prints the code alone on stdout, which is the entire reason this path is
    /// machine-readable at all. Login shells are not assumed: a non-interactive exec channel may have a minimal PATH,
    /// so the usual install locations are tried explicitly before giving up.
    public static let command = """
        for candidate in openpaw-host "$HOME/.cargo/bin/openpaw-host" /usr/local/bin/openpaw-host \
        /opt/homebrew/bin/openpaw-host; do \
        if command -v "$candidate" >/dev/null 2>&1; then exec "$candidate" pairing-code --profile operator; fi; \
        done; echo openpaw-host-missing >&2; exit 127
        """

    private let runner: any CommandRunner

    public init(runner: any CommandRunner) {
        self.runner = runner
    }

    /// Runs the request and returns a normalized pairing code.
    public func requestCode() async throws -> String {
        let output: String
        do {
            output = try await runner.run(Self.command)
        } catch let failure as CommandFailure {
            throw Self.classify(exitCode: failure.exitCode, output: failure.output)
        }
        guard let code = Self.parseCode(output) else {
            throw Failure.unreadableOutput(Self.summarize(output))
        }
        return code
    }

    /// Maps a non-zero exit into a failure the UI can explain without leaking the code.
    static func classify(exitCode: Int32, output: String) -> Failure {
        let lowered = output.lowercased()
        if exitCode == 127 || lowered.contains("openpaw-host-missing") || lowered.contains("command not found") {
            return .hostBinaryMissing
        }
        if lowered.contains("is openpaw-host running")
            || lowered.contains("cannot reach openpaw-host")
            || lowered.contains("connection refused")
            || lowered.contains("no such file or directory") && lowered.contains("hook-token") {
            return .daemonNotRunning
        }
        return .refused(summarize(output))
    }

    /// Recovers the code from stdout.
    ///
    /// The daemon prints `XXXX-XXXX-...` on a line of its own, but a shell profile that writes to stdout would ruin a
    /// naive "read everything" parse, so the shape is matched per line instead: six groups of four base32 characters.
    static func parseCode(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPairingCode(candidate) else { continue }
            return candidate
        }
        return nil
    }

    /// A pairing code is 24 characters, hyphen-grouped by four.
    ///
    /// The daemon mints from a base32 alphabet today, but it normalizes redeemed codes by uppercasing and dropping
    /// non-alphanumerics, so the shape rather than the alphabet is the durable contract. Matching uppercase
    /// alphanumerics keeps a future alphabet change from silently breaking this path, and six hyphen-separated groups
    /// of exactly four is still specific enough that ordinary shell output cannot collide with it.
    static func isPairingCode(_ candidate: String) -> Bool {
        let groups = candidate.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 6 else { return false }
        return groups.allSatisfy { group in
            group.count == 4 && group.allSatisfy(isCodeCharacter)
        }
    }

    private static func isCodeCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isNumber || (character.isLetter && character.isUppercase)
    }

    /// Trims host output to something short enough to show, and never echoes anything code-shaped.
    static func summarize(_ output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isPairingCode($0) }
        let joined = lines.suffix(3).joined(separator: " ")
        if joined.isEmpty { return "nothing" }
        return joined.count > 200 ? String(joined.prefix(200)) + "…" : joined
    }
}
