import Foundation
import XCTest

@testable import OpenPawProtocol

final class RiskClassifierTests: XCTestCase {
    private struct Case {
        let command: String
        let riskClass: RiskClass
        let requiresDetailExpansion: Bool
        /// A reason the classifier must emit *verbatim*. These literals are copied from
        /// `openpaw-protocol`'s `src/risk.rs`, so a drift on either side fails here.
        let reason: String

        init(
            _ command: String,
            _ riskClass: RiskClass,
            _ requiresDetailExpansion: Bool,
            _ reason: String
        ) {
            self.command = command
            self.riskClass = riskClass
            self.requiresDetailExpansion = requiresDetailExpansion
            self.reason = reason
        }
    }

    /// Every `RiskClass` and every review trigger named in the protocol contract, with the
    /// exact reason string the Rust host emits for the same input.
    private static let table: [Case] = [
        // read_only
        Case("cat README.md", .readOnly, false, "reads without modifying: cat"),
        Case("git status", .readOnly, false, "reads without modifying: git status"),
        Case("rg TODO src/", .readOnly, false, "reads without modifying: rg"),
        Case("git", .readOnly, false, "reads without modifying: git"),

        // local_write
        Case("mkdir -p build", .localWrite, false, "writes to the filesystem: mkdir"),
        Case("cp a.txt b.txt", .localWrite, false, "writes to the filesystem: cp"),
        Case("sed -i '' s/a/b/ f.txt", .localWrite, false, "edits files in place: sed -i"),
        Case("chmod 644 notes.md", .localWrite, false, "changes file metadata: chmod"),

        // git_operation
        Case("git commit -m 'wip'", .gitOperation, false, "mutates git state: git commit"),
        Case("git rebase -i HEAD~3", .gitOperation, false, "mutates git state: git rebase"),
        Case("git worktree add ../wt", .gitOperation, false, "mutates git state: git worktree"),

        // network_access
        Case("curl https://example.com", .networkAccess, false, "contacts the network: curl"),
        Case("git push origin main", .networkAccess, false, "contacts the network: git push"),
        Case(
            "rsync -a ./dist deploy@host:/srv", .networkAccess, false,
            "contacts the network: rsync"
        ),

        // package_installation
        Case("npm install", .packageInstallation, false, "installs packages: npm install"),
        Case("pnpm i", .packageInstallation, false, "installs packages: pnpm i"),
        Case("pip install requests", .packageInstallation, false, "installs packages: pip install"),
        Case(
            "cargo install cargo-nextest", .packageInstallation, false,
            "installs packages: cargo install"
        ),
        Case("brew install jq", .packageInstallation, false, "installs packages: brew install"),
        Case("uv add httpx", .packageInstallation, false, "installs packages: uv add"),
        Case(
            "uv pip install httpx", .packageInstallation, false, "installs packages: uv pip install"
        ),
        Case(
            "python3 -m pip install build", .packageInstallation, false,
            "installs packages: python3 -m pip install"
        ),
        Case("pacman -S ripgrep", .packageInstallation, false, "installs packages: pacman -S"),
        Case(
            "apt-get install -y ripgrep", .packageInstallation, false,
            "installs packages: apt-get install"
        ),

        // destructive_shell
        Case("rm -rf build", .destructiveShell, true, "deletes files: rm"),
        Case("rmdir stale", .destructiveShell, false, "deletes directories: rmdir"),
        Case(
            "dd if=/dev/zero of=/dev/disk2", .destructiveShell, false, "irreversible operation: dd"
        ),
        Case("mkfs.ext4 /dev/sdb1", .destructiveShell, false, "formats a filesystem: mkfs.ext4"),
        Case(
            "git reset --hard HEAD~1", .destructiveShell, false,
            "discards local commits: git reset --hard"
        ),
        Case("git clean -fd", .destructiveShell, false, "deletes untracked files: git clean"),
        Case(
            "chmod -R 777 /srv/app", .destructiveShell, false,
            "recursive permission change: chmod -R"
        ),
        Case("kill -9 4321", .destructiveShell, false, "force kills processes: kill -9"),
        Case(
            "echo replaced > tracked.txt", .destructiveShell, false,
            "shell redirection overwrites tracked.txt"
        ),
        Case(
            "cat build.log >> archive.log", .destructiveShell, false,
            "shell redirection appends to archive.log"
        ),
        Case("truncate -s 0 build.log", .destructiveShell, false, "irreversible operation: truncate"),

        // credential_access. Read access versus modification changes the wording.
        Case("cat ~/.ssh/id_ed25519", .credentialAccess, true, "reads credential material: .ssh"),
        Case("grep -r password src/", .credentialAccess, true, "reads credential material: password"),
        Case(
            "openssl x509 -in cert.pem -noout -text", .credentialAccess, true,
            "modifies credential material: .pem"
        ),
        Case("cp .env .env.bak", .credentialAccess, true, "modifies credential material: .env"),

        // unknown: reasons are never empty.
        Case("brew doctor", .unknown, false, Risk.noRuleMatchedReason),
        Case("systemctl status nginx", .unknown, false, Risk.noRuleMatchedReason),

        // Multi segment severity: the highest severity finding wins.
        Case("ls && npm install", .packageInstallation, false, "installs packages: npm install"),
        Case(
            "cat notes.md && curl https://x.test | grep ok", .networkAccess, false,
            "contacts the network: curl"
        ),
        Case("ls; rm -rf /tmp/scratch", .destructiveShell, true, "deletes files: rm"),
        Case(
            "git status && git add -A && git commit -m x", .gitOperation, false,
            "mutates git state: git add"
        ),

        // Review triggers that do not change the class.
        Case(
            "sudo systemctl restart nginx", .unknown, true,
            "requires review: elevated privileges via sudo"
        ),
        Case("doas pkg_add curl", .unknown, true, "requires review: elevated privileges via doas"),
        Case(
            "git push --force origin main", .networkAccess, true,
            "requires review: force push (--force)"
        ),
        Case(
            "git push --force-with-lease origin main", .networkAccess, true,
            "requires review: force push (--force-with-lease)"
        ),
        Case(
            "kubectl apply -f deploy.yaml -n prod-us", .unknown, true,
            "requires review: production deploy (kubectl -n prod-us)"
        ),
        Case(
            "terraform apply -auto-approve", .unknown, true,
            "requires review: production deploy (terraform apply)"
        ),
        Case(
            "terraform destroy", .unknown, true,
            "requires review: production deploy (terraform destroy)"
        ),
        Case(
            "vercel deploy --prod", .unknown, true,
            "requires review: production deploy (vercel --prod)"
        ),
        Case("fly deploy", .unknown, true, "requires review: production deploy (fly deploy)"),
        Case(
            "helm upgrade api ./chart", .unknown, true,
            "requires review: production deploy (helm upgrade)"
        ),
        Case(
            "psql -c 'drop table users'", .unknown, true,
            "requires review: database mutation (drop table)"
        ),
        Case(
            "mysql -e 'truncate table sessions'", .unknown, true,
            "requires review: database mutation (truncate table)"
        ),
        Case(
            "psql -c 'delete from users where id = 1'", .unknown, true,
            "requires review: database mutation (delete from)"
        ),
        Case(
            "psql -c 'alter table users add column x int'", .unknown, true,
            "requires review: database mutation (alter table)"
        ),
        Case(
            "npx prisma migrate deploy", .unknown, true,
            "requires review: database mutation (prisma migrate deploy)"
        ),
        Case(
            "flyway migrate", .unknown, true, "requires review: database mutation (flyway migrate)"
        ),
    ]

    func testTableCoversEveryRiskClassAndBothGates() {
        XCTAssertGreaterThanOrEqual(Self.table.count, 20)
        XCTAssertEqual(
            Set(Self.table.map(\.riskClass)),
            Set(RiskClass.allCases),
            "the table must exercise every risk class"
        )
        XCTAssertTrue(Self.table.contains { $0.requiresDetailExpansion })
        XCTAssertTrue(Self.table.contains { !$0.requiresDetailExpansion })
    }

    func testClassifierAgreesWithTheRuleTable() {
        for entry in Self.table {
            let risk = Risk.classifyCommand(entry.command)
            XCTAssertEqual(
                risk.riskClass, entry.riskClass,
                "class for '\(entry.command)' (reasons: \(risk.reasons))"
            )
            XCTAssertEqual(
                risk.requiresDetailExpansion, entry.requiresDetailExpansion,
                "detail gate for '\(entry.command)' (reasons: \(risk.reasons))"
            )
            XCTAssertTrue(
                risk.reasons.contains(entry.reason),
                """
                '\(entry.command)' must emit the host's reason verbatim.
                expected: \(entry.reason)
                actual:   \(risk.reasons)
                """
            )
            XCTAssertFalse(
                risk.reasons.isEmpty, "'\(entry.command)' must explain its classification"
            )
        }
    }

    func testReasonsAreNeverEmptyAndCarryTheSentinel() {
        let risk = Risk.classifyCommand("someuncatalogedbinary --flag")
        XCTAssertEqual(risk.riskClass, .unknown)
        XCTAssertEqual(risk.reasons, [Risk.noRuleMatchedReason])
        XCTAssertFalse(risk.requiresDetailExpansion)

        let empty = Risk.classifyCommand("   ")
        XCTAssertEqual(empty.riskClass, .unknown)
        XCTAssertEqual(empty.reasons, [Risk.noRuleMatchedReason])
    }

    func testWinningClassReasonsComeFirstThenReviewTriggers() {
        let risk = Risk.classifyCommand("sudo rm -rf /var/tmp/cache")
        XCTAssertEqual(risk.riskClass, .destructiveShell)
        XCTAssertEqual(
            risk.reasons,
            [
                "deletes files: rm",
                "requires review: rm deletes files",
                "requires review: elevated privileges via sudo",
            ]
        )
    }

    func testEveryFindingAtTheWinningSeverityIsReported() {
        // Two destructive rules fire in one command line: both reasons survive, and the
        // read-only `cat` finding is dropped because it loses on severity.
        let risk = Risk.classifyCommand("rm -rf build && cat notes.md > /tmp/out.txt")
        XCTAssertEqual(risk.riskClass, .destructiveShell)
        XCTAssertEqual(
            risk.reasons,
            [
                "deletes files: rm",
                "shell redirection overwrites /tmp/out.txt",
                "requires review: rm deletes files",
            ]
        )
    }

    func testSeverityOrderingIsTotalAndMatchesTheContract() {
        let ordered: [RiskClass] = [
            .unknown, .readOnly, .localWrite, .gitOperation, .networkAccess,
            .packageInstallation, .credentialAccess, .destructiveShell,
        ]
        XCTAssertEqual(ordered.count, RiskClass.allCases.count)
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(lower.severity, higher.severity, "\(lower) must rank below \(higher)")
        }
    }

    func testSeparatorsInsideQuotesDoNotSplitSegments() {
        // The `;` and `&&` live inside a quoted argument, so this is one read-only
        // segment, not a destructive one.
        let risk = Risk.classifyCommand("grep 'rm -rf /; echo done' notes.md")
        XCTAssertEqual(risk.riskClass, .readOnly)
        XCTAssertFalse(risk.requiresDetailExpansion)
    }

    func testFileDescriptorDuplicationIsNotTreatedAsTruncation() {
        // `2>&1` must not be split on the `&`, otherwise the trailing `>` looks like a
        // truncating redirect into an unnamed file.
        XCTAssertEqual(Risk.classifyCommand("ls -la 2>&1").riskClass, .readOnly)
        XCTAssertEqual(Risk.classifyCommand("cargo test 2>&1").riskClass, .unknown)
        XCTAssertEqual(Risk.classifyCommand("make build >&2").riskClass, .unknown)
        // A real redirect in the same command line is still caught.
        let mixed = Risk.classifyCommand("cargo test 2>&1 > build.log")
        XCTAssertEqual(mixed.riskClass, .destructiveShell)
        XCTAssertTrue(mixed.reasons.contains("shell redirection overwrites build.log"))
    }

    func testBackgroundOperatorStillSplitsSegments() {
        let risk = Risk.classifyCommand("npm install & git status")
        XCTAssertEqual(risk.riskClass, .packageInstallation)
    }

    func testPrivilegeWrapperAndEnvAssignmentsAreStripped() {
        let risk = Risk.classifyCommand("sudo -E RUST_LOG=debug rm -rf /var/tmp/cache")
        XCTAssertEqual(risk.riskClass, .destructiveShell)
        XCTAssertTrue(risk.requiresDetailExpansion)
        XCTAssertTrue(risk.reasons.contains("deletes files: rm"))
        XCTAssertTrue(risk.reasons.contains("requires review: elevated privileges via sudo"))
    }

    func testReasonsAreDeduplicated() {
        let risk = Risk.classifyCommand("rm -rf a && rm -rf b")
        XCTAssertEqual(risk.riskClass, .destructiveShell)
        XCTAssertEqual(Set(risk.reasons).count, risk.reasons.count)
        XCTAssertEqual(risk.reasons.filter { $0 == "deletes files: rm" }.count, 1)
    }

    func testCredentialWordingTracksReadVersusWrite() {
        XCTAssertTrue(
            Risk.classifyCommand("cat .env").reasons.contains("reads credential material: .env")
        )
        XCTAssertTrue(
            Risk.classifyCommand("cat .env").reasons
                .contains("requires review: credential material (.env)")
        )
        XCTAssertTrue(
            Risk.classifyCommand("mv .env .env.old").reasons
                .contains("modifies credential material: .env")
        )
        XCTAssertTrue(
            Risk.classifyCommand("mv .env .env.old").reasons
                .contains("requires review: modifies credential material (.env)")
        )
        // `git` counts as read-only only for its inspection subcommands.
        XCTAssertTrue(
            Risk.classifyCommand("git diff .env").reasons
                .contains("reads credential material: .env")
        )
        XCTAssertTrue(
            Risk.classifyCommand("git add .env").reasons
                .contains("modifies credential material: .env")
        )
    }

    func testKubectlNamespaceFlagForms() {
        for command in [
            "kubectl delete pod api -n production",
            "kubectl delete pod api --namespace production",
            "kubectl delete pod api --namespace=production",
            "kubectl delete pod api -nproduction",
        ] {
            let risk = Risk.classifyCommand(command)
            XCTAssertTrue(
                risk.requiresDetailExpansion, "'\(command)' targets production and needs review"
            )
            XCTAssertTrue(
                risk.reasons.contains("requires review: production deploy (kubectl -n production)"),
                "'\(command)' produced \(risk.reasons)"
            )
        }
        // A non-production namespace is not a review trigger.
        XCTAssertFalse(
            Risk.classifyCommand("kubectl get pods -n staging").requiresDetailExpansion
        )
    }

    // MARK: Tool classification

    func testWrappersAndAssignmentsAreLookedThrough() {
        // Each of these hides the whole risk behind one word. Resolving argv0 to the
        // wrapper drops the command to `unknown`, the severity floor, which would render a
        // network or install call as an unclassified one-tap approval.
        let cases: [(String, RiskClass, String)] = [
            ("stdbuf -o0 curl https://x.test", .networkAccess, "contacts the network: curl"),
            ("nice -n 10 curl https://x.test", .networkAccess, "contacts the network: curl"),
            ("ionice -c 3 npm install", .packageInstallation, "installs packages: npm install"),
            ("setsid nohup ls -la", .readOnly, "reads without modifying: ls"),
            ("builtin cd /tmp && git push origin main", .networkAccess, "contacts the network: git push"),
            ("time git push origin main", .networkAccess, "contacts the network: git push"),
            ("FOO=1 npm install", .packageInstallation, "installs packages: npm install"),
            ("env FOO=1 BAR=2 npm install", .packageInstallation, "installs packages: npm install"),
            ("sudo -u deploy npm install", .packageInstallation, "installs packages: npm install"),
        ]
        for (command, expected, reason) in cases {
            let risk = Risk.classifyCommand(command)
            XCTAssertEqual(risk.riskClass, expected, "'\(command)' produced \(risk.reasons)")
            XCTAssertTrue(risk.reasons.contains(reason), "'\(command)' produced \(risk.reasons)")
        }

        // `exec` must not eat the elevation trigger.
        let elevated = Risk.classifyCommand("exec sudo rm -rf /var/tmp/cache")
        XCTAssertEqual(elevated.riskClass, .destructiveShell)
        XCTAssertTrue(elevated.reasons.contains("deletes files: rm"))
        XCTAssertTrue(
            elevated.reasons.contains("requires review: elevated privileges via sudo")
        )
    }

    func testWrapperFlagScanStopsCorrectly() {
        // A lone `-` is not a flag and stops the scan, so argv0 stays `-` rather than
        // swallowing the next word.
        XCTAssertEqual(Risk.classifyCommand("env - curl https://x.test").riskClass, .unknown)

        // An attached value is not a separate token, so nothing extra is consumed.
        XCTAssertEqual(
            Risk.classifyCommand("nice -n10 curl https://x.test").riskClass, .networkAccess
        )
        // `--flag=value` likewise.
        XCTAssertEqual(
            Risk.classifyCommand("sudo --user=deploy npm install").riskClass,
            .packageInstallation
        )

        // `./x=y` is a real argv0, not an assignment.
        XCTAssertFalse(Risk.isEnvironmentAssignment("./x=y"))
        XCTAssertFalse(Risk.isEnvironmentAssignment("1FOO=1"))
        XCTAssertFalse(Risk.isEnvironmentAssignment("=1"))
        XCTAssertTrue(Risk.isEnvironmentAssignment("FOO=1"))
        XCTAssertTrue(Risk.isEnvironmentAssignment("_FOO_2=a=b"))
    }

    func testWrapperSetIsPinned() {
        XCTAssertEqual(
            Risk.wrapperCommands,
            [
                "sudo", "doas", "env", "nohup", "command", "builtin", "exec", "time",
                "stdbuf", "setsid", "nice", "ionice",
            ]
        )
    }

    /// Cases measured on the Rust side after the per-wrapper table was pinned. Kept here so
    /// the two implementations stay diffable by test name as well as by behaviour.
    func testWrapperValueFlagsMatchTheRustTableExactly() {
        XCTAssertEqual(
            Risk.valueTakingFlags(forWrapper: "sudo"),
            [
                "-u", "--user", "-g", "--group", "-p", "--prompt", "-C", "--close-from",
                "-r", "--role", "-t", "--type", "-h", "--host",
            ]
        )
        XCTAssertEqual(Risk.valueTakingFlags(forWrapper: "doas"), ["-u", "-C"])
        XCTAssertEqual(
            Risk.valueTakingFlags(forWrapper: "env"),
            ["-u", "--unset", "-C", "--chdir", "-S", "--split-string"]
        )
        XCTAssertEqual(Risk.valueTakingFlags(forWrapper: "nice"), ["-n", "--adjustment"])
        XCTAssertEqual(
            Risk.valueTakingFlags(forWrapper: "ionice"),
            ["-c", "--class", "-n", "--classdata", "-p", "--pid"]
        )
        XCTAssertEqual(
            Risk.valueTakingFlags(forWrapper: "stdbuf"),
            ["-i", "--input", "-o", "--output", "-e", "--error"]
        )
        XCTAssertEqual(Risk.valueTakingFlags(forWrapper: "time"), ["-f", "--format", "-o", "--output"])
        for wrapper in ["nohup", "command", "builtin", "exec", "setsid"] {
            XCTAssertTrue(Risk.valueTakingFlags(forWrapper: wrapper).isEmpty, wrapper)
        }

        // `time -f '%e' curl` resolved argv0 to `%e` before the table was scoped.
        XCTAssertEqual(
            Risk.classifyCommand("time -f '%e' curl https://x.test").riskClass, .networkAccess
        )
        // Two value flags in a row.
        XCTAssertEqual(
            Risk.classifyCommand("stdbuf -o L -e L npm install").riskClass, .packageInstallation
        )
        // Exact match only: an attached or `=`-joined value carries itself, so nothing extra
        // may be consumed.
        XCTAssertEqual(
            Risk.classifyCommand("env --unset=NODE_ENV npm install").riskClass,
            .packageInstallation
        )
        XCTAssertEqual(
            Risk.classifyCommand("ionice -c3 curl https://x.test").riskClass, .networkAccess
        )
    }

    func testValueTakingFlagsAreScopedPerWrapper() {
        // A single global value-flag list is wrong in both directions, and both errors land
        // on `unknown`, the permissive floor.
        //
        // Too narrow: `ionice -c 3 npm install` resolves argv0 to `3`.
        let ionice = Risk.classifyCommand("ionice -c 3 npm install")
        XCTAssertEqual(ionice.riskClass, .packageInstallation, "\(ionice.reasons)")
        // Too wide: `sudo -n` is non-interactive and takes no value, so a global `-n`
        // would swallow `npm` and resolve argv0 to `install`.
        let sudoNonInteractive = Risk.classifyCommand("sudo -n npm install")
        XCTAssertEqual(sudoNonInteractive.riskClass, .packageInstallation, "\(sudoNonInteractive.reasons)")
        XCTAssertTrue(
            sudoNonInteractive.reasons.contains("requires review: elevated privileges via sudo")
        )

        XCTAssertEqual(
            Risk.classifyCommand("stdbuf -o 0 curl https://x.test").riskClass, .networkAccess
        )
        XCTAssertEqual(
            Risk.classifyCommand("ionice -c 2 -n 7 git push origin main").riskClass,
            .networkAccess
        )
        XCTAssertEqual(
            Risk.classifyCommand("time -o timing.txt git push origin main").riskClass,
            .networkAccess
        )
        XCTAssertEqual(
            Risk.classifyCommand("env -u NODE_ENV npm install").riskClass, .packageInstallation
        )
        // `setsid` has no value-taking flags, so nothing extra may be consumed.
        XCTAssertEqual(Risk.classifyCommand("setsid -f curl https://x.test").riskClass, .networkAccess)

        XCTAssertFalse(Risk.valueTakingFlags(forWrapper: "sudo").contains("-n"))
        XCTAssertTrue(Risk.valueTakingFlags(forWrapper: "nice").contains("-n"))
        XCTAssertTrue(Risk.valueTakingFlags(forWrapper: "ionice").contains("-c"))
        XCTAssertTrue(Risk.valueTakingFlags(forWrapper: "setsid").isEmpty)
    }

    func testEveryShellToolAliasClassifiesItsCommand() {
        // If an alias is ever dropped, its command stops being classified and a dangerous
        // call silently degrades to "unrecognized tool".
        let aliases = [
            "bash", "shell", "sh", "zsh", "run_command", "local_shell", "local_shell_call",
            "terminal",
        ]
        XCTAssertEqual(Set(aliases), Risk.shellToolNames)
        for alias in aliases {
            let risk = Risk.classifyTool(
                alias,
                input: ["command": .array([.string("bash"), .string("-lc"), .string("rm -rf build")])]
            )
            XCTAssertEqual(risk.riskClass, .destructiveShell, alias)
            XCTAssertTrue(risk.reasons.contains("deletes files: rm"), alias)
            XCTAssertTrue(risk.reasons.contains("requires review: rm deletes files"), alias)
        }
    }

    func testShellCommandExtractionHandlesStringArgvAndWrapper() {
        // Codex ships `command` as an argv array; the `["bash", "-lc", …]` form must be
        // looked through so the rules see the script, not `bash`.
        XCTAssertEqual(
            Risk.shellCommand(
                in: ["command": .array([.string("bash"), .string("-lc"), .string("npm install")])]
            ),
            "npm install"
        )
        // A plain argv array joins instead.
        XCTAssertEqual(
            Risk.shellCommand(in: ["command": .array([.string("ls"), .string("-la")])]),
            "ls -la"
        )
        XCTAssertEqual(Risk.shellCommand(in: ["command": "git status"]), "git status")
        XCTAssertEqual(Risk.shellCommand(in: .string("git status")), "git status")
        XCTAssertNil(Risk.shellCommand(in: ["timeout": 5]))
        XCTAssertNil(Risk.shellCommand(in: ["command": ""]))
        XCTAssertNil(Risk.shellCommand(in: ["command": .array([])]))

        // The unwrap only fires for a real shell invocation.
        XCTAssertNil(Risk.unwrappedShellScript(["cargo", "-c", "test"]))
        XCTAssertEqual(Risk.unwrappedShellScript(["/bin/zsh", "-c", "ls"]), "ls")

        let argv = Risk.classifyTool(
            "local_shell_call", input: ["command": .array([.string("ls"), .string("-la")])]
        )
        XCTAssertEqual(argv.riskClass, .readOnly)
        XCTAssertEqual(argv.reasons, ["reads without modifying: ls"])
    }

    func testExecIsATransparentWrapper() {
        let risk = Risk.classifyCommand("exec sudo rm -rf /var/tmp/cache")
        XCTAssertEqual(risk.riskClass, .destructiveShell)
        XCTAssertTrue(risk.reasons.contains("deletes files: rm"))
        XCTAssertTrue(risk.reasons.contains("requires review: elevated privileges via sudo"))
        XCTAssertEqual(
            Risk.classifyCommand("exec ls -la").reasons, ["reads without modifying: ls"]
        )
    }

    func testTodoReadIsAPlanToolNotAFileReader() {
        // Both groups classify as read_only, but the reason literal differs and the two
        // implementations must pick the same one.
        let risk = Risk.classifyTool("TodoRead", input: [:])
        XCTAssertEqual(risk.riskClass, .readOnly)
        XCTAssertEqual(
            risk.reasons, ["updates the agent's plan without touching the workspace"]
        )
    }

    func testRmIsMatchedAsAWholeTokenAnywhereInTheSegment() {
        for command in [
            "find . -name '*.tmp' -exec rm {} \\;",
            "git rm -r --cached src",
            "cat list.txt | xargs rm -f",
            "/usr/bin/rm -rf build",
        ] {
            let risk = Risk.classifyCommand(command)
            XCTAssertEqual(risk.riskClass, .destructiveShell, command)
            XCTAssertTrue(risk.reasons.contains("deletes files: rm"), command)
            XCTAssertTrue(risk.reasons.contains("requires review: rm deletes files"), command)
        }
        // Token equality, not substring: neither of these deletes anything.
        XCTAssertNotEqual(Risk.classifyCommand("charm install").riskClass, .destructiveShell)
        let docker = Risk.classifyCommand("docker run --rm alpine echo hi")
        XCTAssertNotEqual(docker.riskClass, .destructiveShell)
        XCTAssertFalse(docker.requiresDetailExpansion)
    }

    func testPinnedReadOnlyCommandsDriveCredentialWording() {
        // Commands added by the pinned union must read, not modify.
        for reader in ["bat", "nl", "printenv", "xxd", "od", "md5sum", "shasum", "sha256sum"] {
            let risk = Risk.classifyCommand("\(reader) .env")
            XCTAssertEqual(risk.riskClass, .credentialAccess, reader)
            XCTAssertTrue(
                risk.reasons.contains("reads credential material: .env"),
                "\(reader) produced \(risk.reasons)"
            )
        }
        XCTAssertEqual(
            Risk.classifyCommand("nl notes.md").reasons, ["reads without modifying: nl"]
        )
    }

    func testPinnedPathKeyOrderDrivesTheJoinedReason() {
        // String keys precede array keys, in the pinned order, because the paths are
        // joined into the reason literal.
        let risk = Risk.classifyTool(
            "Write",
            input: [
                "paths": .array([.string("c.rs"), .string("d.rs")]),
                "file_path": "a.rs",
                "path": "b.rs",
            ]
        )
        XCTAssertEqual(risk.reasons, ["writes files: a.rs, b.rs, c.rs, d.rs"])

        let notebook = Risk.classifyTool("NotebookEdit", input: ["notebookPath": "a.ipynb"])
        XCTAssertEqual(notebook.reasons, ["writes files: a.ipynb"])

        let named = Risk.classifyTool("Read", input: ["filename": "notes.md"])
        XCTAssertEqual(named.reasons, ["reads files: notes.md"])
    }

    func testToolClassificationTable() {
        let read = Risk.classifyTool("Read", input: ["file_path": "src/main.rs"])
        XCTAssertEqual(read.riskClass, .readOnly)
        XCTAssertEqual(read.reasons, ["reads files: src/main.rs"])

        let glob = Risk.classifyTool("Glob", input: ["pattern": "**/*.swift"])
        XCTAssertEqual(glob.riskClass, .readOnly)
        XCTAssertEqual(glob.reasons, ["searches the workspace: Glob"])

        let grep = Risk.classifyTool("Grep", input: ["pattern": "TODO"])
        XCTAssertEqual(grep.riskClass, .readOnly)
        XCTAssertEqual(grep.reasons, ["searches the workspace: Grep"])

        let write = Risk.classifyTool("Write", input: ["file_path": "src/new.rs"])
        XCTAssertEqual(write.riskClass, .localWrite)
        XCTAssertEqual(write.reasons, ["writes files: src/new.rs"])

        let edit = Risk.classifyTool("Edit", input: ["file_path": "src/lib.rs"])
        XCTAssertEqual(edit.riskClass, .localWrite)
        XCTAssertEqual(edit.reasons, ["writes files: src/lib.rs"])

        let notebook = Risk.classifyTool("NotebookEdit", input: ["notebook_path": "a.ipynb"])
        XCTAssertEqual(notebook.riskClass, .localWrite)
        XCTAssertEqual(notebook.reasons, ["writes files: a.ipynb"])

        let patch = Risk.classifyTool("apply_patch", input: ["paths": .array(["a.rs", "b.rs"])])
        XCTAssertEqual(patch.riskClass, .localWrite)
        XCTAssertEqual(patch.reasons, ["patches files: a.rs, b.rs"])

        let barePatch = Risk.classifyTool("apply_patch", input: ["patch": "@@ ..."])
        XCTAssertEqual(barePatch.reasons, ["applies a patch to the workspace"])

        let fetch = Risk.classifyTool("WebFetch", input: ["url": "https://example.com"])
        XCTAssertEqual(fetch.riskClass, .networkAccess)
        XCTAssertEqual(fetch.reasons, ["contacts the network: WebFetch"])

        let plan = Risk.classifyTool("TodoWrite", input: ["todos": .array([])])
        XCTAssertEqual(plan.riskClass, .readOnly)
        XCTAssertEqual(
            plan.reasons, ["updates the agent's plan without touching the workspace"]
        )

        let task = Risk.classifyTool("Task", input: ["prompt": "investigate"])
        XCTAssertEqual(task.riskClass, .unknown)
        XCTAssertEqual(
            task.reasons,
            ["delegates to a subagent whose actions are not yet known: Task"]
        )

        let mystery = Risk.classifyTool("MysteryTool", input: [:])
        XCTAssertEqual(mystery.riskClass, .unknown)
        XCTAssertEqual(mystery.reasons, ["unrecognized tool: MysteryTool"])
    }

    func testShellToolDelegatesToCommandClassification() {
        let risk = Risk.classifyTool("Bash", input: ["command": "rm -rf node_modules"])
        XCTAssertEqual(risk.riskClass, .destructiveShell)
        XCTAssertTrue(risk.requiresDetailExpansion)
        XCTAssertTrue(risk.reasons.contains("deletes files: rm"))

        let codex = Risk.classifyTool("local_shell", input: ["command": "npm install"])
        XCTAssertEqual(codex.riskClass, .packageInstallation)

        let empty = Risk.classifyTool("Bash", input: ["timeout": 5])
        XCTAssertEqual(empty.riskClass, .unknown)
        XCTAssertEqual(empty.reasons, ["shell tool invocation without a resolvable command"])
    }

    func testCredentialPathsOutrankTheToolBucket() {
        let write = Risk.classifyTool("Write", input: ["file_path": "/Users/x/proj/.env"])
        XCTAssertEqual(write.riskClass, .credentialAccess)
        XCTAssertTrue(write.requiresDetailExpansion)
        XCTAssertEqual(
            write.reasons,
            [
                "modifies credential material: .env",
                "requires review: modifies credential material (.env)",
            ]
        )

        let read = Risk.classifyTool("Read", input: ["path": "~/.aws/credentials"])
        XCTAssertEqual(read.riskClass, .credentialAccess)
        XCTAssertTrue(read.requiresDetailExpansion)
        XCTAssertTrue(read.reasons.contains("reads credential material: .aws"))
        XCTAssertTrue(read.reasons.contains("reads credential material: credentials"))
    }
}
