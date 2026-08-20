import Foundation

// MARK: - Risk class

public enum RiskClass: String, Codable, Sendable, Hashable, CaseIterable {
    case readOnly = "read_only"
    case localWrite = "local_write"
    case gitOperation = "git_operation"
    case networkAccess = "network_access"
    case packageInstallation = "package_installation"
    case destructiveShell = "destructive_shell"
    case credentialAccess = "credential_access"
    case unknown

    /// Severity ordering used when a command line contains several segments:
    /// `destructive_shell` > `credential_access` > `package_installation`
    /// > `network_access` > `git_operation` > `local_write` > `read_only` > `unknown`.
    public var severity: Int {
        switch self {
        case .unknown: 0
        case .readOnly: 1
        case .localWrite: 2
        case .gitOperation: 3
        case .networkAccess: 4
        case .packageInstallation: 5
        case .credentialAccess: 6
        case .destructiveShell: 7
        }
    }

    public var displayName: String {
        switch self {
        case .readOnly: "Read only"
        case .localWrite: "Local write"
        case .gitOperation: "Git operation"
        case .networkAccess: "Network access"
        case .packageInstallation: "Package installation"
        case .destructiveShell: "Destructive shell"
        case .credentialAccess: "Credential access"
        case .unknown: "Unclassified"
        }
    }
}

// MARK: - Risk

public struct Risk: Codable, Sendable, Hashable {
    public let riskClass: RiskClass
    /// When true a client MUST show the full command detail before offering approval.
    public let requiresDetailExpansion: Bool
    /// Human readable triggers, most significant first.
    public let reasons: [String]

    public init(riskClass: RiskClass, requiresDetailExpansion: Bool, reasons: [String]) {
        self.riskClass = riskClass
        self.requiresDetailExpansion = requiresDetailExpansion
        self.reasons = reasons
    }

    enum CodingKeys: String, CodingKey {
        case riskClass = "class"
        case requiresDetailExpansion = "requires_detail_expansion"
        case reasons
    }

    public static let unknown = Risk(
        riskClass: .unknown, requiresDetailExpansion: false, reasons: []
    )
}

// MARK: - Classification

/// The reason strings below are byte-identical to `openpaw-protocol`'s `src/risk.rs`.
/// The app classifies locally when it only has terminal text, and cross-checks what the
/// host claims; divergent wording would surface as a false disagreement.
extension Risk {
    /// Emitted when no rule matched and no review trigger fired, so `reasons` is never
    /// empty.
    public static let noRuleMatchedReason = "no classification rule matched"

    /// Classifies a whole shell command line, including every `&&`, `||`, `;`, `|` and
    /// newline separated segment. The highest severity finding wins; the reasons of every
    /// finding at that severity are kept, then every review trigger, de-duplicated.
    public static func classifyCommand(_ command: String) -> Risk {
        var collected: [Finding] = []
        for segment in shellSegments(of: command) {
            collected.append(contentsOf: findings(in: segment))
        }
        let winner =
            collected.map(\.riskClass).max(by: { $0.severity < $1.severity }) ?? .unknown

        var reasons: [String] = []
        for finding in collected where finding.riskClass == winner {
            reasons.append(finding.reason)
        }
        let triggers = detailExpansionTriggers(command)
        reasons.append(contentsOf: triggers)

        let deduplicated = deduplicated(reasons)
        return Risk(
            riskClass: winner,
            requiresDetailExpansion: !triggers.isEmpty,
            reasons: deduplicated.isEmpty ? [noRuleMatchedReason] : deduplicated
        )
    }

    // MARK: Findings

    struct Finding {
        let riskClass: RiskClass
        let reason: String
    }

    /// Every rule that matches this segment, in severity-descending declaration order.
    static func findings(in raw: String) -> [Finding] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var found: [Finding] = []
        let lowered = trimmed.lowercased()
        var tokens = shellTokens(of: trimmed)
        stripWrappers(&tokens)

        let argv0 = tokens.first.map { basename($0) } ?? ""
        let arguments = Array(tokens.dropFirst())
        let flags = arguments.filter { $0.hasPrefix("-") }
        let subcommand = arguments.first(where: { !$0.hasPrefix("-") })?.lowercased()
        let bases = tokens.map { basename($0) }

        // destructive_shell
        for reason in redirectionReasons(in: trimmed) {
            found.append(Finding(riskClass: .destructiveShell, reason: reason))
        }
        if bases.contains("rm") {
            found.append(Finding(riskClass: .destructiveShell, reason: "deletes files: rm"))
        }
        if bases.contains("rmdir") {
            found.append(
                Finding(riskClass: .destructiveShell, reason: "deletes directories: rmdir")
            )
        }
        if argv0.hasPrefix("mkfs") {
            found.append(
                Finding(riskClass: .destructiveShell, reason: "formats a filesystem: \(argv0)")
            )
        }
        if irreversibleCommands.contains(argv0) {
            found.append(
                Finding(riskClass: .destructiveShell, reason: "irreversible operation: \(argv0)")
            )
        }
        let isRecursive = flags.contains { $0 == "-R" || $0 == "-r" || $0 == "--recursive" }
        if permissionCommands.contains(argv0), isRecursive {
            found.append(
                Finding(
                    riskClass: .destructiveShell,
                    reason: "recursive permission change: \(argv0) -R"
                )
            )
        }
        if killCommands.contains(argv0),
            flags.contains(where: { $0 == "-9" || $0 == "-KILL" || $0 == "-SIGKILL" })
        {
            found.append(
                Finding(
                    riskClass: .destructiveShell, reason: "force kills processes: \(argv0) -9"
                )
            )
        }
        if argv0 == "git", subcommand == "clean" {
            found.append(
                Finding(
                    riskClass: .destructiveShell, reason: "deletes untracked files: git clean"
                )
            )
        }
        if argv0 == "git", subcommand == "reset", arguments.contains("--hard") {
            found.append(
                Finding(
                    riskClass: .destructiveShell,
                    reason: "discards local commits: git reset --hard"
                )
            )
        }

        // credential_access. Markers are substrings of the whole segment, so a path
        // buried in a flag value is still caught.
        let mutating = !isReadOnlySegment(argv0: argv0, subcommand: subcommand, flags: flags)
        for marker in credentialMarkers where lowered.contains(marker) {
            found.append(
                Finding(
                    riskClass: .credentialAccess,
                    reason: mutating
                        ? "modifies credential material: \(marker)"
                        : "reads credential material: \(marker)"
                )
            )
        }

        // package_installation
        if let reason = packageInstallReason(argv0: argv0, arguments: arguments) {
            found.append(Finding(riskClass: .packageInstallation, reason: reason))
        }

        // network_access
        if networkCommands.contains(argv0) {
            found.append(
                Finding(riskClass: .networkAccess, reason: "contacts the network: \(argv0)")
            )
        }
        if argv0 == "git", let subcommand, gitNetworkSubcommands.contains(subcommand) {
            found.append(
                Finding(
                    riskClass: .networkAccess, reason: "contacts the network: git \(subcommand)"
                )
            )
        }

        // git_operation
        if argv0 == "git", let subcommand, gitWriteSubcommands.contains(subcommand) {
            found.append(
                Finding(riskClass: .gitOperation, reason: "mutates git state: git \(subcommand)")
            )
        }

        // local_write
        if localWriteCommands.contains(argv0) {
            found.append(
                Finding(riskClass: .localWrite, reason: "writes to the filesystem: \(argv0)")
            )
        }
        if argv0 == "sed", flags.contains(where: { $0.hasPrefix("-i") }) {
            found.append(Finding(riskClass: .localWrite, reason: "edits files in place: sed -i"))
        }
        if permissionCommands.contains(argv0), !isRecursive {
            found.append(
                Finding(riskClass: .localWrite, reason: "changes file metadata: \(argv0)")
            )
        }

        // read_only
        if readOnlyCommands.contains(argv0) {
            found.append(
                Finding(riskClass: .readOnly, reason: "reads without modifying: \(argv0)")
            )
        }
        if argv0 == "git" {
            if let subcommand {
                if gitReadSubcommands.contains(subcommand) {
                    found.append(
                        Finding(
                            riskClass: .readOnly,
                            reason: "reads without modifying: git \(subcommand)"
                        )
                    )
                }
            } else {
                found.append(
                    Finding(riskClass: .readOnly, reason: "reads without modifying: git")
                )
            }
        }
        return found
    }

    /// Drops leading privilege wrappers and environment assignments so that
    /// `sudo -E FOO=1 rm -rf /x` classifies as `rm`.
    static func stripWrappers(_ tokens: inout [String]) {
        while let first = tokens.first {
            if isEnvironmentAssignment(first) {
                tokens.removeFirst()
                continue
            }
            let base = basename(first)
            guard wrapperCommands.contains(base) else { break }
            tokens.removeFirst()

            // Skip the wrapper's own flags. A handful of them take a separate value, which
            // must be consumed too: `nice -n 10 curl` has to land on `curl`, not on `10`.
            let valueFlags = valueTakingFlags(forWrapper: base)
            while let next = tokens.first {
                if isEnvironmentAssignment(next) {
                    tokens.removeFirst()
                    continue
                }
                // A lone `-` is not a flag; it stops the scan.
                guard next.hasPrefix("-"), next != "-" else { break }
                tokens.removeFirst()
                if valueFlags.contains(next), !tokens.isEmpty {
                    tokens.removeFirst()
                }
            }
        }
    }

    /// Flags that consume the following token as their value, per wrapper.
    ///
    /// A single global list does not work: `ionice -c 3 npm install` needs `-c` to take a
    /// value or argv0 resolves to `3`, while `sudo -n` is non-interactive and takes none,
    /// so a global `-n` would make `sudo -n npm install` resolve to `install`. Both land on
    /// `unknown`, the severity floor, which is the permissive direction.
    static func valueTakingFlags(forWrapper wrapper: String) -> Set<String> {
        switch wrapper {
        case "sudo":
            [
                "-u", "--user", "-g", "--group", "-p", "--prompt", "-C", "--close-from",
                "-r", "--role", "-t", "--type", "-h", "--host",
            ]
        case "doas":
            ["-u", "-C"]
        case "env":
            ["-u", "--unset", "-C", "--chdir", "-S", "--split-string"]
        case "nice":
            ["-n", "--adjustment"]
        case "ionice":
            ["-c", "--class", "-n", "--classdata", "-p", "--pid"]
        case "stdbuf":
            ["-i", "--input", "-o", "--output", "-e", "--error"]
        case "time":
            ["-f", "--format", "-o", "--output"]
        default:
            []
        }
    }

    /// Whether this segment only reads. Drives the credential reason wording: `git` is
    /// read-only for its inspection subcommands, `sed` is read-only unless `-i`.
    static func isReadOnlySegment(argv0: String, subcommand: String?, flags: [String]) -> Bool {
        if argv0 == "git" {
            guard let subcommand else { return true }
            return gitReadSubcommands.contains(subcommand)
        }
        if argv0 == "sed" {
            return !flags.contains { $0.hasPrefix("-i") }
        }
        return readOnlyCommands.contains(argv0)
    }

    // MARK: Rule tables

    /// Transparent prefixes the rules look through, pinned with the Rust command parser.
    /// `sudo` and `doas` are also elevation triggers; the rest are pure pass-throughs.
    /// Without them a command's whole risk can hide behind one word: `stdbuf -o0 curl x`
    /// resolves to `stdbuf` and drops to `unknown`, the severity floor, which would render
    /// a network call as an unclassified one-tap approval.
    static let wrapperCommands: Set<String> = [
        "sudo", "doas", "env", "nohup", "command", "builtin", "exec", "time", "stdbuf",
        "setsid", "nice", "ionice",
    ]

    static let irreversibleCommands: Set<String> = [
        "shred", "truncate", "dd", "mkswap", "shutdown", "reboot", "halt", "poweroff",
    ]

    static let permissionCommands: Set<String> = ["chmod", "chown", "chgrp"]

    static let killCommands: Set<String> = ["kill", "pkill", "killall"]

    static let networkCommands: Set<String> = [
        "curl", "wget", "ssh", "scp", "rsync", "sftp", "nc", "ncat", "netcat", "telnet",
        "ftp", "http", "https", "httpie",
    ]

    static let gitNetworkSubcommands: Set<String> = ["push", "pull", "fetch", "clone"]

    static let gitWriteSubcommands: Set<String> = [
        "commit", "add", "checkout", "branch", "merge", "rebase", "stash", "push", "pull",
        "reset", "tag", "cherry-pick", "revert", "apply", "am", "restore", "switch",
        "worktree", "submodule",
    ]

    static let gitReadSubcommands: Set<String> = [
        "status", "log", "diff", "show", "blame", "describe",
    ]

    /// Pinned union of the Swift and Rust lists. This set decides both the `read_only`
    /// finding and the read-versus-modify wording of credential reasons, so it must match
    /// `openpaw-protocol`'s `READ_ONLY_COMMANDS` verbatim. `sed` counts as read-only only
    /// without `-i`; `git` only for its inspection subcommands.
    static let readOnlyCommands: Set<String> = [
        "cat", "bat", "less", "more", "head", "tail", "ls", "tree", "grep", "egrep",
        "fgrep", "rg", "ag", "ack", "find", "fd", "wc", "stat", "file", "which",
        "whereis", "pwd", "whoami", "hostname", "uname", "date", "printenv", "echo",
        "printf", "sort", "uniq", "cut", "tr", "nl", "seq", "nproc", "awk", "jq", "yq",
        "diff", "basename", "dirname", "realpath", "readlink", "du", "df", "ps",
        "column", "xxd", "od", "md5sum", "shasum", "sha256sum", "cmp", "sed",
    ]

    static let localWriteCommands: Set<String> = [
        "mkdir", "touch", "mv", "cp", "ln", "tee", "install",
    ]

    static let credentialMarkers: [String] = [
        ".env", ".ssh", "id_ed25519", "id_rsa", ".aws", ".netrc", "keychain",
        "secrets", "credentials", "token", "password", ".pem", ".p12",
    ]

    static func packageInstallReason(argv0: String, arguments: [String]) -> String? {
        let positional = arguments.filter { !$0.hasPrefix("-") }.map { $0.lowercased() }
        let first = positional.first
        switch argv0 {
        case "npm", "pnpm", "yarn", "bun":
            if let first, ["install", "add", "i", "ci"].contains(first) {
                return "installs packages: \(argv0) \(first)"
            }
        case "apt", "apt-get", "dnf", "yum", "apk", "zypper":
            if let first, ["install", "add"].contains(first) {
                return "installs packages: \(argv0) \(first)"
            }
        case "pip", "pip3", "cargo", "gem", "go", "brew":
            if first == "install" { return "installs packages: \(argv0) install" }
        case "python", "python3":
            if arguments.contains("-m"), positional.first == "pip",
                positional.dropFirst().first == "install"
            {
                return "installs packages: \(argv0) -m pip install"
            }
        case "uv":
            if first == "add" { return "installs packages: uv add" }
            if first == "pip", positional.dropFirst().first == "install" {
                return "installs packages: uv pip install"
            }
        case "pacman":
            if arguments.contains("-S") || arguments.contains("-Sy")
                || arguments.contains("-Syu")
            {
                return "installs packages: pacman -S"
            }
        default:
            return nil
        }
        return nil
    }

    /// One reason per output redirection that writes to a file. `>&` is a file descriptor
    /// duplication and yields nothing.
    static func redirectionReasons(in segment: String) -> [String] {
        var reasons: [String] = []
        let characters = Array(segment)
        var singleQuoted = false
        var doubleQuoted = false
        var escaped = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if character == "\\", !singleQuoted {
                escaped = true
            } else if character == "'", !doubleQuoted {
                singleQuoted.toggle()
            } else if character == "\"", !singleQuoted {
                doubleQuoted.toggle()
            } else if character == ">", !singleQuoted, !doubleQuoted {
                var cursor = index + 1
                var appends = false
                if cursor < characters.count, characters[cursor] == ">" {
                    appends = true
                    cursor += 1
                }
                if cursor < characters.count, characters[cursor] == "&" {
                    index = cursor + 1  // descriptor duplication, e.g. 2>&1
                    continue
                }
                while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
                var target = ""
                while cursor < characters.count, !characters[cursor].isWhitespace {
                    target.append(characters[cursor])
                    cursor += 1
                }
                let cleaned = target.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                let name = cleaned.isEmpty ? "a file" : cleaned
                reasons.append(
                    appends
                        ? "shell redirection appends to \(name)"
                        : "shell redirection overwrites \(name)"
                )
                index = cursor
                continue
            }
            index += 1
        }
        return reasons
    }

    // MARK: Detail expansion

    /// Review triggers, each prefixed `requires review: `.
    static func detailExpansionTriggers(_ command: String) -> [String] {
        var reasons: [String] = []
        for segment in shellSegments(of: command) {
            let lowered = segment.lowercased()
            var tokens = shellTokens(of: segment)
            let rawBases = tokens.map { basename($0) }
            stripWrappers(&tokens)
            let bases = tokens.map { basename($0) }
            let argv0 = bases.first ?? ""
            let flags = tokens.filter { $0.hasPrefix("-") }
            let subcommand = tokens.dropFirst().first(where: { !$0.hasPrefix("-") })?.lowercased()

            if bases.contains("rm") {
                reasons.append("requires review: rm deletes files")
            }
            if rawBases.contains("sudo") {
                reasons.append("requires review: elevated privileges via sudo")
            }
            if rawBases.contains("doas") {
                reasons.append("requires review: elevated privileges via doas")
            }

            let mutating = !isReadOnlySegment(argv0: argv0, subcommand: subcommand, flags: flags)
            for marker in credentialMarkers where lowered.contains(marker) {
                reasons.append(
                    mutating
                        ? "requires review: modifies credential material (\(marker))"
                        : "requires review: credential material (\(marker))"
                )
            }

            if argv0 == "git", tokens.contains("push"),
                let flag = ["--force-with-lease", "--force", "-f"].first(where: {
                    candidate in tokens.contains { $0 == candidate || $0.hasPrefix(candidate + "=") }
                })
            {
                reasons.append("requires review: force push (\(flag))")
            }
            reasons.append(contentsOf: deployTriggers(argv0: argv0, tokens: tokens))

            for phrase in databaseMutationPhrases {
                if collapsedWhitespace(lowered).contains(phrase) {
                    reasons.append("requires review: database mutation (\(phrase))")
                }
            }
            if argv0 == "psql", tokens.contains("-c") {
                reasons.append("requires review: database mutation (psql -c)")
            }
            if argv0 == "mysql", tokens.contains("-e") {
                reasons.append("requires review: database mutation (mysql -e)")
            }
        }
        return deduplicated(reasons)
    }

    static let databaseMutationPhrases = [
        "drop table", "truncate table", "delete from", "alter table",
        "prisma migrate deploy", "flyway migrate",
    ]

    private static func deployTriggers(argv0: String, tokens: [String]) -> [String] {
        var reasons: [String] = []
        switch argv0 {
        case "kubectl":
            for namespace in namespaceArguments(tokens)
            where namespace.lowercased().contains("prod") {
                reasons.append("requires review: production deploy (kubectl -n \(namespace))")
            }
        case "terraform":
            let rest = tokens.dropFirst()
            if rest.contains("apply") {
                reasons.append("requires review: production deploy (terraform apply)")
            }
            if rest.contains("destroy") {
                reasons.append("requires review: production deploy (terraform destroy)")
            }
        case "vercel":
            if tokens.contains("--prod") {
                reasons.append("requires review: production deploy (vercel --prod)")
            }
        case "fly", "flyctl":
            if tokens.dropFirst().contains("deploy") {
                reasons.append("requires review: production deploy (fly deploy)")
            }
        case "helm":
            if tokens.dropFirst().contains("upgrade") {
                reasons.append("requires review: production deploy (helm upgrade)")
            }
        default:
            break
        }
        return reasons
    }

    /// Namespace values from `-n X`, `--namespace X`, `--namespace=X` and `-nX`.
    static func namespaceArguments(_ tokens: [String]) -> [String] {
        var namespaces: [String] = []
        for (index, token) in tokens.enumerated() {
            if token == "-n" || token == "--namespace" {
                if index + 1 < tokens.count { namespaces.append(tokens[index + 1]) }
            } else if token.hasPrefix("--namespace=") {
                namespaces.append(String(token.dropFirst("--namespace=".count)))
            } else if token.hasPrefix("-n"), token.count > 2 {
                namespaces.append(String(token.dropFirst(2)))
            }
        }
        return namespaces
    }

    // MARK: Tool classification

    /// Classifies a structured tool call. `input` is the agent's raw tool input object.
    public static func classifyTool(_ tool: String, input: JSONValue) -> Risk {
        let normalized = tool.lowercased()

        if shellToolNames.contains(normalized) {
            guard let command = shellCommand(in: input) else {
                return Risk(
                    riskClass: .unknown,
                    requiresDetailExpansion: false,
                    reasons: ["shell tool invocation without a resolvable command"]
                )
            }
            return classifyCommand(command)
        }

        let paths = toolPaths(in: input)
        let joined = paths.joined(separator: ", ")
        let base: (riskClass: RiskClass, reason: String, mutating: Bool)

        if readOnlyToolNames.contains(normalized) {
            base = (
                .readOnly,
                paths.isEmpty
                    ? "reads without modifying: \(normalized)" : "reads files: \(joined)",
                false
            )
        } else if searchToolNames.contains(normalized) {
            base = (.readOnly, "searches the workspace: \(tool)", false)
        } else if writeToolNames.contains(normalized) {
            base = (
                .localWrite,
                paths.isEmpty
                    ? "writes to the filesystem: \(normalized)" : "writes files: \(joined)",
                true
            )
        } else if patchToolNames.contains(normalized) {
            base = (
                .localWrite,
                paths.isEmpty ? "applies a patch to the workspace" : "patches files: \(joined)",
                true
            )
        } else if networkToolNames.contains(normalized) {
            base = (.networkAccess, "contacts the network: \(tool)", false)
        } else if planToolNames.contains(normalized) {
            base = (
                .readOnly, "updates the agent's plan without touching the workspace", false
            )
        } else if subagentToolNames.contains(normalized) {
            base = (
                .unknown,
                "delegates to a subagent whose actions are not yet known: \(tool)",
                false
            )
        } else {
            base = (.unknown, "unrecognized tool: \(tool)", false)
        }

        // Credential material named anywhere in the tool input outranks the tool's own
        // bucket and always forces review.
        var credentialReasons: [String] = []
        var reviewReasons: [String] = []
        let haystacks = paths.isEmpty ? input.stringLeaves : paths
        for haystack in haystacks {
            let lowered = haystack.lowercased()
            for marker in credentialMarkers where lowered.contains(marker) {
                credentialReasons.append(
                    base.mutating
                        ? "modifies credential material: \(marker)"
                        : "reads credential material: \(marker)"
                )
                reviewReasons.append(
                    base.mutating
                        ? "requires review: modifies credential material (\(marker))"
                        : "requires review: credential material (\(marker))"
                )
            }
        }

        guard !credentialReasons.isEmpty else {
            return Risk(
                riskClass: base.riskClass, requiresDetailExpansion: false, reasons: [base.reason]
            )
        }
        if RiskClass.credentialAccess.severity > base.riskClass.severity {
            return Risk(
                riskClass: .credentialAccess,
                requiresDetailExpansion: true,
                reasons: deduplicated(credentialReasons + reviewReasons)
            )
        }
        return Risk(
            riskClass: base.riskClass,
            requiresDetailExpansion: true,
            reasons: deduplicated([base.reason] + credentialReasons + reviewReasons)
        )
    }

    // Alias sets pinned with `openpaw-protocol`'s `src/risk.rs`. They pick the reason
    // literal, so a name in the wrong group produces a different string for the same call.
    /// Pinned with the Rust side. `local_shell_call` is a real Codex on-disk item type, so
    /// forwarding the raw item type as the tool name resolves. `exec`/`execute` are
    /// deliberately absent: no adapter emits them, and `exec` is already a transparent
    /// wrapper in the command parser.
    static let shellToolNames: Set<String> = [
        "bash", "shell", "sh", "zsh", "run_command", "local_shell", "local_shell_call",
        "terminal",
    ]

    /// The command text a shell tool call carries, as a string, an argv array, or a
    /// `["bash", "-lc", "<script>"]` wrapper.
    static func shellCommand(in input: JSONValue) -> String? {
        for key in ["command", "cmd", "script", "shell_command"] {
            guard let value = input[key] else { continue }
            if let command = resolvedCommand(from: value) { return command }
        }
        return resolvedCommand(from: input)
    }

    private static func resolvedCommand(from value: JSONValue) -> String? {
        if let text = value.stringValue {
            return text.isEmpty ? nil : text
        }
        guard let items = value.arrayValue else { return nil }
        let argv = items.compactMap(\.stringValue)
        if let script = unwrappedShellScript(argv) { return script }
        let joined = argv.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// Looks through `["bash", "-lc", "<script>"]` to the script itself, so the rules see
    /// the real command instead of classifying `bash`.
    static func unwrappedShellScript(_ argv: [String]) -> String? {
        guard argv.count >= 3, ["bash", "sh", "zsh", "dash", "ksh"].contains(basename(argv[0])),
            ["-lc", "-c", "-ic", "-lic"].contains(argv[1])
        else { return nil }
        return argv[2].isEmpty ? nil : argv[2]
    }

    static let readOnlyToolNames: Set<String> = [
        "read", "read_file", "notebookread", "view", "cat",
    ]

    static let searchToolNames: Set<String> = [
        "glob", "grep", "ls", "list", "list_dir", "search", "codebase_search", "file_search",
    ]

    static let writeToolNames: Set<String> = [
        "write", "write_file", "edit", "multiedit", "str_replace", "str_replace_editor",
        "notebookedit", "create", "create_file",
    ]

    static let patchToolNames: Set<String> = ["apply_patch", "applypatch", "patch"]

    static let networkToolNames: Set<String> = [
        "webfetch", "websearch", "web_search", "fetch", "browser",
    ]

    /// `todoread` belongs here, not with the file readers: the class is `read_only` either
    /// way, but the reason literal differs.
    static let planToolNames: Set<String> = [
        "todowrite", "todoread", "update_plan", "exitplanmode", "plan",
    ]

    static let subagentToolNames: Set<String> = ["task", "agent", "dispatch_agent", "subagent"]

    static let stringPathKeys = [
        "file_path", "filePath", "notebook_path", "notebookPath", "path", "file",
        "filename", "target_file",
    ]

    static let arrayPathKeys = ["paths", "files"]

    /// Path-like strings from a tool input. Key order is pinned because the paths are
    /// joined into the reason string.
    static func toolPaths(in input: JSONValue) -> [String] {
        var paths: [String] = []
        for key in stringPathKeys {
            if let single = input[key]?.stringValue { paths.append(single) }
        }
        for key in arrayPathKeys {
            if let items = input[key]?.arrayValue {
                paths.append(contentsOf: items.compactMap(\.stringValue))
            }
        }
        return paths
    }

    // MARK: Shell lexing

    /// Splits a command line on `&&`, `||`, `;`, `|`, `&` and newlines, ignoring
    /// separators inside quotes.
    static func shellSegments(of command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var singleQuoted = false
        var doubleQuoted = false
        var escaped = false
        let characters = Array(command)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if escaped {
                current.append(character)
                escaped = false
                index += 1
                continue
            }
            if character == "\\", !singleQuoted {
                current.append(character)
                escaped = true
            } else if character == "'", !doubleQuoted {
                singleQuoted.toggle()
                current.append(character)
            } else if character == "\"", !singleQuoted {
                doubleQuoted.toggle()
                current.append(character)
            } else if !singleQuoted, !doubleQuoted,
                character == "&" || character == "|" || character == ";" || character == "\n"
            {
                // `2>&1` and `>&2` are file descriptor duplications, not a background
                // operator: the `&` belongs to the redirect and must not split the segment,
                // otherwise the redirection detector sees a bare `>` and reports a truncation.
                if character == "&", current.last == ">" {
                    current.append(character)
                    index += 1
                    continue
                }
                segments.append(current)
                current = ""
                if index + 1 < characters.count, characters[index + 1] == character {
                    index += 1
                }
            } else {
                current.append(character)
            }
            index += 1
        }
        segments.append(current)
        return segments.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Splits one segment into tokens, stripping quoting.
    static func shellTokens(of segment: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var singleQuoted = false
        var doubleQuoted = false
        var escaped = false
        for character in segment {
            if escaped {
                current.append(character)
                hasCurrent = true
                escaped = false
                continue
            }
            if character == "\\", !singleQuoted {
                escaped = true
                hasCurrent = true
            } else if character == "'", !doubleQuoted {
                singleQuoted.toggle()
                hasCurrent = true
            } else if character == "\"", !singleQuoted {
                doubleQuoted.toggle()
                hasCurrent = true
            } else if character.isWhitespace, !singleQuoted, !doubleQuoted {
                if hasCurrent {
                    tokens.append(current)
                    current = ""
                    hasCurrent = false
                }
            } else {
                current.append(character)
                hasCurrent = true
            }
        }
        if hasCurrent { tokens.append(current) }
        return tokens
    }

    static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A leading `VAR=VAL` assignment. The name must match `[A-Za-z_][A-Za-z0-9_]*`, so
    /// `FOO=1 npm install` is looked through but `./x=y` is a real argv0.
    static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else {
            return false
        }
        let name = token[token.startIndex..<equals]
        guard let leading = name.first, leading.isLetter || leading == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func basename(_ token: String) -> String {
        let component = token.split(separator: "/").last.map(String.init) ?? token
        return component.lowercased()
    }

    static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values where seen.insert(value).inserted {
            out.append(value)
        }
        return out
    }
}
