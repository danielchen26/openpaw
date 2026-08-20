//! The risk table: one test per class, the full detail-expansion trigger table,
//! compound-command precedence, and the tool-shape mapping for all three agents.

use openpaw_protocol::{Risk, RiskClass};
use serde_json::json;

fn class_of(command: &str) -> RiskClass {
    Risk::classify_command(command).class
}

fn assert_reason_mentions(risk: &Risk, needle: &str) {
    assert!(
        risk.reasons.iter().any(|reason| reason.contains(needle)),
        "expected a reason mentioning {needle:?}, got {:?}",
        risk.reasons
    );
}

// ---------------------------------------------------------------------------
// one test per class
// ---------------------------------------------------------------------------

#[test]
fn read_only_commands() {
    for command in [
        "cat README.md",
        "less src/lib.rs",
        "head -n 20 Cargo.toml",
        "tail -f log",
        "ls -la",
        "grep -rn needle src",
        "rg needle",
        "find . -name '*.rs'",
        "git status",
        "git log --oneline -5",
        "git diff HEAD~1",
        "git show HEAD",
        "/usr/bin/wc -l src/lib.rs",
    ] {
        assert_eq!(
            class_of(command),
            RiskClass::ReadOnly,
            "{command} should be read_only"
        );
        assert!(
            !Risk::classify_command(command).requires_detail_expansion,
            "{command} should not force detail expansion"
        );
    }
}

#[test]
fn local_write_commands() {
    for command in [
        "mkdir -p target/tmp",
        "touch src/new.rs",
        "mv a.rs b.rs",
        "cp a.rs b.rs",
        "ln -s a b",
        "sed -i '' 's/a/b/' src/lib.rs",
        "chmod 644 src/lib.rs",
    ] {
        assert_eq!(
            class_of(command),
            RiskClass::LocalWrite,
            "{command} should be local_write"
        );
    }
}

#[test]
fn git_operations() {
    for command in [
        "git commit -m 'wip'",
        "git add -A",
        "git checkout main",
        "git branch feature",
        "git merge feature",
        "git rebase -i main",
        "git stash",
    ] {
        assert_eq!(
            class_of(command),
            RiskClass::GitOperation,
            "{command} should be git_operation"
        );
    }
    assert_reason_mentions(
        &Risk::classify_command("git commit -m wip"),
        "mutates git state: git commit",
    );
}

#[test]
fn network_access_commands() {
    for command in [
        "curl https://example.com",
        "wget https://example.com/x.tgz",
        "ssh host",
        "scp a host:b",
        "rsync -a a host:b",
        "nc -l 8080",
        // git push/pull are also git operations; network outranks git.
        "git push origin main",
        "git pull --rebase",
        "git fetch --all",
        "git clone https://example.com/r.git",
    ] {
        assert_eq!(
            class_of(command),
            RiskClass::NetworkAccess,
            "{command} should be network_access"
        );
    }
}

#[test]
fn package_installation_commands() {
    for command in [
        "npm install",
        "npm i lodash",
        "npm ci",
        "pnpm add -D vitest",
        "yarn add react",
        "bun install",
        "pip install requests",
        "pip3 install -r requirements.txt",
        "python3 -m pip install ruff",
        "cargo install cargo-nextest",
        "brew install jq",
        "apt install curl",
        "apt-get install -y curl",
        "dnf install git",
        "apk add curl",
        "pacman -Syu",
        "gem install bundler",
        "go install golang.org/x/tools/cmd/goimports@latest",
        "uv add httpx",
        "uv pip install httpx",
    ] {
        assert_eq!(
            class_of(command),
            RiskClass::PackageInstallation,
            "{command} should be package_installation"
        );
    }
}

#[test]
fn destructive_shell_commands() {
    for command in [
        "rm -rf build",
        "rmdir target",
        "dd if=/dev/zero of=/dev/disk2",
        "mkfs.ext4 /dev/sda1",
        "chmod -R 777 .",
        "chown -R root .",
        "kill -9 4242",
        "shutdown -h now",
        "truncate -s 0 log",
        "git reset --hard origin/main",
        "git clean -fdx",
        "cargo build > build.log",
        "echo hi >> notes.txt",
    ] {
        assert_eq!(
            class_of(command),
            RiskClass::DestructiveShell,
            "{command} should be destructive_shell"
        );
    }
}

#[test]
fn credential_access_commands() {
    let read = Risk::classify_command("cat .env");
    assert_eq!(read.class, RiskClass::CredentialAccess);
    assert_reason_mentions(&read, "reads credential material: .env");
    assert!(read.requires_detail_expansion);

    for command in [
        "cat ~/.ssh/id_ed25519",
        "cat ~/.ssh/id_rsa",
        "cat ~/.aws/credentials",
        "cat ~/.netrc",
        "security find-generic-password -s keychain",
        "cat secrets/api.yaml",
        "cat deploy/token",
        "cat password.txt",
        "cat certs/server.pem",
        "cat certs/client.p12",
    ] {
        assert_eq!(
            class_of(command),
            RiskClass::CredentialAccess,
            "{command} should be credential_access"
        );
    }

    // A mutating command reports modification rather than a read.
    let write = Risk::classify_command("mv new.env .env");
    assert_eq!(write.class, RiskClass::CredentialAccess);
    assert_reason_mentions(&write, "modifies credential material: .env");
}

#[test]
fn unknown_commands() {
    let risk = Risk::classify_command("cargo build --workspace");
    assert_eq!(risk.class, RiskClass::Unknown);
    assert!(!risk.requires_detail_expansion);
    assert_eq!(risk.reasons, vec!["no classification rule matched"]);

    assert_eq!(class_of("make -j8"), RiskClass::Unknown);
    assert_eq!(class_of(""), RiskClass::Unknown);
}

// ---------------------------------------------------------------------------
// detail expansion trigger table
// ---------------------------------------------------------------------------

#[test]
fn every_detail_expansion_trigger_fires_with_a_specific_reason() {
    let table: &[(&str, &str)] = &[
        ("rm -rf build", "rm deletes files"),
        (
            "sudo systemctl restart nginx",
            "elevated privileges via sudo",
        ),
        ("doas pkg_add curl", "elevated privileges via doas"),
        (
            "env FOO=1 sudo make install",
            "elevated privileges via sudo",
        ),
        ("cat .env", "credential material (.env)"),
        ("cp new .ssh/config", "modifies credential material (.ssh)"),
        ("git push --force origin main", "force push (--force)"),
        ("git push -f origin main", "force push (-f)"),
        (
            "git push --force-with-lease origin main",
            "force push (--force-with-lease)",
        ),
        (
            "kubectl apply -f k8s.yaml -n prod",
            "production deploy (kubectl -n prod)",
        ),
        (
            "kubectl --namespace=production apply -f k8s.yaml",
            "production deploy (kubectl -n production)",
        ),
        (
            "terraform apply -auto-approve",
            "production deploy (terraform apply)",
        ),
        ("vercel --prod", "production deploy (vercel --prod)"),
        ("fly deploy", "production deploy (fly deploy)"),
        (
            "helm upgrade openpaw ./chart",
            "production deploy (helm upgrade)",
        ),
        (
            "psql -c \"drop table sessions\"",
            "database mutation (drop table)",
        ),
        (
            "psql -c \"truncate table events\"",
            "database mutation (truncate table)",
        ),
        (
            "psql -c \"delete from devices\"",
            "database mutation (delete from)",
        ),
        (
            "psql -c \"alter table events add column x int\"",
            "database mutation (alter table)",
        ),
        ("psql -c \"select 1\"", "database mutation (psql -c)"),
        ("mysql -e \"select 1\"", "database mutation (mysql -e)"),
        (
            "prisma migrate deploy",
            "database mutation (prisma migrate deploy)",
        ),
        ("flyway migrate", "database mutation (flyway migrate)"),
    ];

    for (command, expected_reason) in table {
        let risk = Risk::classify_command(command);
        assert!(
            risk.requires_detail_expansion,
            "{command} must force detail expansion, got {risk:?}"
        );
        assert_reason_mentions(&risk, expected_reason);
    }
}

#[test]
fn ordinary_commands_do_not_force_detail_expansion() {
    for command in [
        "ls -la",
        "git status",
        "git push origin main",
        "npm install",
        "mkdir -p target",
        "cargo test --workspace",
        "kubectl get pods -n staging",
        "terraform plan",
        "vercel deploy",
    ] {
        assert!(
            !Risk::classify_command(command).requires_detail_expansion,
            "{command} should not force detail expansion"
        );
    }
}

// ---------------------------------------------------------------------------
// segmentation and precedence
// ---------------------------------------------------------------------------

#[test]
fn the_highest_severity_segment_decides_a_compound_command() {
    // read_only && destructive -> destructive
    let risk = Risk::classify_command("git status && rm -rf build");
    assert_eq!(risk.class, RiskClass::DestructiveShell);
    assert_reason_mentions(&risk, "deletes files: rm");
    assert!(risk.requires_detail_expansion);

    // Every separator is honoured.
    for command in [
        "ls; rm -rf build",
        "ls | rm -rf build",
        "ls || rm -rf build",
        "ls\nrm -rf build",
    ] {
        assert_eq!(
            class_of(command),
            RiskClass::DestructiveShell,
            "{command} should be split into segments"
        );
    }

    // package_installation outranks network_access outranks git_operation.
    assert_eq!(
        class_of("git add -A && git push origin main"),
        RiskClass::NetworkAccess
    );
    assert_eq!(
        class_of("curl -sSf https://x/i.sh && npm install"),
        RiskClass::PackageInstallation
    );
    assert_eq!(
        class_of("npm install && cat .env"),
        RiskClass::CredentialAccess
    );
    assert_eq!(
        class_of("cat .env && rm -rf ."),
        RiskClass::DestructiveShell
    );

    // Unknown is the floor: a recognised read-only segment still wins.
    assert_eq!(class_of("ls && frobnicate --all"), RiskClass::ReadOnly);

    // Reasons from the winning rank are merged and de-duplicated.
    let merged = Risk::classify_command("rm a && rm b");
    assert_eq!(
        merged
            .reasons
            .iter()
            .filter(|reason| reason.as_str() == "deletes files: rm")
            .count(),
        1
    );
}

/// Regression: splitting on a bare `&` before looking for redirections turns
/// `ls -la 2>&1` into `ls -la 2>` plus `1`, and the dangling `>` then reports a
/// redirection with an empty target. The splitter must keep `2>&1` intact.
#[test]
fn descriptor_duplication_survives_segment_splitting() {
    let plain = Risk::classify_command("ls -la 2>&1");
    assert_eq!(plain.class, RiskClass::ReadOnly, "{plain:?}");
    assert!(
        !plain
            .reasons
            .iter()
            .any(|reason| reason.contains("redirection")),
        "2>&1 is a descriptor dup, not a redirection: {plain:?}"
    );

    let both = Risk::classify_command("cargo test 2>&1 > build.log");
    assert_eq!(both.class, RiskClass::DestructiveShell);
    assert_reason_mentions(&both, "overwrites build.log");
    assert!(
        !both.reasons.iter().any(|reason| reason.contains("a file")),
        "the real target must be named: {both:?}"
    );

    assert_eq!(class_of("printf hi >&2"), RiskClass::ReadOnly);
}

#[test]
fn rm_is_detected_as_a_whole_word_anywhere_in_the_segment() {
    for command in [
        "find . -name '*.o' -exec rm {} \\;",
        "git rm -r --cached src",
        "xargs rm -f",
        "find . -type d -empty -exec rmdir {} +",
    ] {
        let risk = Risk::classify_command(command);
        assert_eq!(
            risk.class,
            RiskClass::DestructiveShell,
            "{command} should be destructive_shell, got {risk:?}"
        );
    }
    assert!(
        Risk::classify_command("find . -exec rm {} \\;").requires_detail_expansion,
        "an rm buried in a find must still force detail expansion"
    );
}

#[test]
fn quoted_separators_do_not_split_a_segment() {
    // The `;` lives inside a quoted pattern, so this stays a single grep.
    let risk = Risk::classify_command("grep \"a;b\" file.txt");
    assert_eq!(risk.class, RiskClass::ReadOnly);
    assert_reason_mentions(&risk, "reads without modifying: grep");
}

#[test]
fn command_words_are_matched_not_substrings() {
    // `charm` contains "rm" but is not rm.
    let charm = Risk::classify_command("charm install openpaw");
    assert_ne!(charm.class, RiskClass::DestructiveShell);
    assert!(!charm.requires_detail_expansion);
    assert_eq!(charm.class, RiskClass::Unknown);

    // A `--rm` flag is not the rm command either.
    let docker = Risk::classify_command("docker run --rm alpine echo hi");
    assert_ne!(docker.class, RiskClass::DestructiveShell);
    assert!(!docker.requires_detail_expansion);

    // Neither is a path that merely ends in those letters.
    assert_ne!(class_of("./confirm --yes"), RiskClass::DestructiveShell);

    // But a fully qualified rm still is.
    assert_eq!(class_of("/bin/rm -rf build"), RiskClass::DestructiveShell);
}

#[test]
fn wrappers_and_assignments_are_looked_through() {
    assert_eq!(
        class_of("sudo rm -rf /var/tmp/x"),
        RiskClass::DestructiveShell
    );
    assert_eq!(class_of("env FOO=1 BAR=2 ls -la"), RiskClass::ReadOnly);
    assert_eq!(
        class_of("FOO=1 npm install"),
        RiskClass::PackageInstallation
    );
    assert_eq!(class_of("nohup curl https://x &"), RiskClass::NetworkAccess);
    assert_eq!(
        class_of("sudo -u deploy git push --force origin main"),
        RiskClass::NetworkAccess
    );
    // `bash -lc "<script>"` is classified by what the script actually does.
    assert_eq!(
        class_of("bash -lc 'git push --force origin main'"),
        RiskClass::NetworkAccess
    );
    assert!(
        Risk::classify_command("bash -lc 'git push --force origin main'").requires_detail_expansion
    );
    // Wrappers that take a value for a flag must not swallow the real argv0.
    assert_eq!(
        class_of("nice -n 10 curl https://x"),
        RiskClass::NetworkAccess
    );
    assert_eq!(
        class_of("stdbuf -o0 curl https://x"),
        RiskClass::NetworkAccess
    );
    assert_eq!(class_of("setsid nohup ls -la"), RiskClass::ReadOnly);
    assert_eq!(
        class_of("exec sudo rm -rf /var/tmp/x"),
        RiskClass::DestructiveShell
    );
    let exec_sudo = Risk::classify_command("exec sudo rm -rf /var/tmp/x");
    assert_reason_mentions(&exec_sudo, "elevated privileges via sudo");
    assert_reason_mentions(&exec_sudo, "deletes files: rm");
}

/// Value-taking flags are per wrapper, not a global set: `ionice -c 3` consumes
/// the 3 while `sudo -n` (non-interactive) consumes nothing. Getting either
/// direction wrong resolves argv0 to a flag value and drops the command to
/// `unknown`, which is the permissive direction.
#[test]
fn wrapper_value_flags_are_scoped_per_wrapper() {
    // Too narrow would resolve argv0 to "3".
    assert_eq!(
        class_of("ionice -c 3 npm install"),
        RiskClass::PackageInstallation
    );
    assert_eq!(
        class_of("ionice -c 2 -n 7 curl https://x"),
        RiskClass::NetworkAccess
    );
    assert_eq!(
        class_of("nice -n 10 npm install"),
        RiskClass::PackageInstallation
    );
    assert_eq!(
        class_of("time -f '%e' curl https://x"),
        RiskClass::NetworkAccess
    );
    assert_eq!(
        class_of("env -u NODE_ENV npm install"),
        RiskClass::PackageInstallation
    );
    assert_eq!(
        class_of("stdbuf -o L -e L curl https://x"),
        RiskClass::NetworkAccess
    );

    // Too wide would resolve argv0 to "install": sudo's -n takes no value.
    assert_eq!(
        class_of("sudo -n npm install"),
        RiskClass::PackageInstallation
    );
    assert_eq!(
        class_of("sudo -u deploy npm install"),
        RiskClass::PackageInstallation
    );
    assert_eq!(
        class_of("doas -u deploy curl https://x"),
        RiskClass::NetworkAccess
    );

    // Attached values and --flag=value consume nothing extra.
    assert_eq!(
        class_of("stdbuf -o0 curl https://x"),
        RiskClass::NetworkAccess
    );
    assert_eq!(
        class_of("env --unset=NODE_ENV npm install"),
        RiskClass::PackageInstallation
    );

    // Wrappers with no value flags never consume an argument.
    assert_eq!(class_of("setsid nohup ls -la"), RiskClass::ReadOnly);
    assert_eq!(class_of("nohup curl https://x"), RiskClass::NetworkAccess);
}

#[test]
fn environment_assignment_prefixes_are_recognised_precisely() {
    assert_eq!(
        class_of("FOO=1 npm install"),
        RiskClass::PackageInstallation
    );
    assert_eq!(
        class_of("_FOO_2=a=b npm install"),
        RiskClass::PackageInstallation
    );
    // Not assignments: these are the command itself, so argv0 must stay put.
    assert_eq!(class_of("./x=y"), RiskClass::Unknown);
    assert_eq!(class_of("1FOO=1 ls"), RiskClass::Unknown);
}

/// Codex names its sandboxed shell item type `local_shell_call` on disk, so it
/// must classify the command inside rather than reporting an unknown tool.
#[test]
fn every_shell_tool_alias_classifies_its_command() {
    for tool in [
        "Bash",
        "bash",
        "shell",
        "sh",
        "zsh",
        "run_command",
        "local_shell",
        "local_shell_call",
        "terminal",
    ] {
        let risk = Risk::classify_tool(tool, &json!({"command": ["bash", "-lc", "rm -rf build"]}));
        assert_eq!(
            risk.class,
            RiskClass::DestructiveShell,
            "{tool} should resolve to the shell rule, got {risk:?}"
        );
        assert!(risk.requires_detail_expansion, "{tool}");
        assert_eq!(
            openpaw_protocol::extract_tool_command(tool, &json!({"command": "ls -la"})).as_deref(),
            Some("ls -la"),
            "{tool} must expose its command to the adapters"
        );
    }
}

#[test]
fn descriptor_duplication_is_not_a_truncating_redirect() {
    let risk = Risk::classify_command("cargo build 2>&1");
    assert_eq!(risk.class, RiskClass::Unknown);

    let redirect = Risk::classify_command("cargo build > build.log");
    assert_eq!(redirect.class, RiskClass::DestructiveShell);
    assert_reason_mentions(&redirect, "overwrites build.log");

    let append = Risk::classify_command("echo hi >> notes.txt");
    assert_reason_mentions(&append, "appends to notes.txt");
}

// ---------------------------------------------------------------------------
// tool shapes
// ---------------------------------------------------------------------------

#[test]
fn claude_code_tool_shapes() {
    let bash = Risk::classify_tool(
        "Bash",
        &json!({"command": "sudo rm -rf /Users/dev/src/openpaw/build", "description": "Clean build directory"}),
    );
    assert_eq!(bash.class, RiskClass::DestructiveShell);
    assert!(bash.requires_detail_expansion);
    assert_reason_mentions(&bash, "elevated privileges via sudo");

    let read = Risk::classify_tool(
        "Read",
        &json!({"file_path": "/Users/dev/src/openpaw/README.md"}),
    );
    assert_eq!(read.class, RiskClass::ReadOnly);
    assert_reason_mentions(&read, "/Users/dev/src/openpaw/README.md");

    let secret = Risk::classify_tool("Read", &json!({"file_path": "/Users/dev/src/openpaw/.env"}));
    assert_eq!(secret.class, RiskClass::CredentialAccess);
    assert!(secret.requires_detail_expansion);

    assert_eq!(
        Risk::classify_tool("Glob", &json!({"pattern": "**/*.rs"})).class,
        RiskClass::ReadOnly
    );
    assert_eq!(
        Risk::classify_tool("Grep", &json!({"pattern": "needle"})).class,
        RiskClass::ReadOnly
    );

    let write = Risk::classify_tool(
        "Write",
        &json!({"file_path": "/Users/dev/src/openpaw/src/ws.rs", "content": "fn main() {}"}),
    );
    assert_eq!(write.class, RiskClass::LocalWrite);

    let edit_secret = Risk::classify_tool("Edit", &json!({"file_path": "/srv/app/.env"}));
    assert_eq!(edit_secret.class, RiskClass::CredentialAccess);
    assert_reason_mentions(&edit_secret, "modifies credential material (.env)");

    assert_eq!(
        Risk::classify_tool("MultiEdit", &json!({"file_path": "/a/b.rs"})).class,
        RiskClass::LocalWrite
    );
    assert_eq!(
        Risk::classify_tool("NotebookEdit", &json!({"notebook_path": "/a/b.ipynb"})).class,
        RiskClass::LocalWrite
    );
    assert_eq!(
        Risk::classify_tool("WebFetch", &json!({"url": "https://example.com"})).class,
        RiskClass::NetworkAccess
    );
    assert_eq!(
        Risk::classify_tool("WebSearch", &json!({"query": "openpaw"})).class,
        RiskClass::NetworkAccess
    );
    assert_eq!(
        Risk::classify_tool("TodoWrite", &json!({"todos": []})).class,
        RiskClass::ReadOnly
    );

    let task = Risk::classify_tool("Task", &json!({"prompt": "investigate"}));
    assert_eq!(task.class, RiskClass::Unknown);
    assert_reason_mentions(&task, "delegates to a subagent");
}

#[test]
fn codex_tool_shapes() {
    // Codex sends argv arrays; the `bash -lc` wrapper is unwrapped.
    let shell = Risk::classify_tool(
        "shell",
        &json!({"command": ["bash", "-lc", "cargo build --workspace"], "workdir": "/Users/dev/src/openpaw/host"}),
    );
    assert_eq!(shell.class, RiskClass::Unknown);

    let force_push = Risk::classify_tool(
        "shell",
        &json!({"command": ["bash", "-lc", "git push --force origin main"]}),
    );
    assert_eq!(force_push.class, RiskClass::NetworkAccess);
    assert!(force_push.requires_detail_expansion);
    assert_reason_mentions(&force_push, "force push (--force)");

    // A plain argv array is joined rather than unwrapped.
    let argv = Risk::classify_tool("shell", &json!({"command": ["rm", "-rf", "build"]}));
    assert_eq!(argv.class, RiskClass::DestructiveShell);

    let patch = Risk::classify_tool(
        "apply_patch",
        &json!({"input": "*** Begin Patch\n*** Update File: host/crates/openpaw-git/src/diff.rs\n@@\n-    Ok(out)\n+    Ok(out.into())\n*** End Patch"}),
    );
    assert_eq!(patch.class, RiskClass::LocalWrite);
    assert_reason_mentions(&patch, "host/crates/openpaw-git/src/diff.rs");

    // The patch text may also arrive as a bare JSON string.
    let bare = Risk::classify_tool(
        "apply_patch",
        &json!("*** Begin Patch\n*** Add File: .env.production\n+SECRET=1\n*** End Patch"),
    );
    assert_eq!(bare.class, RiskClass::CredentialAccess);
    assert!(bare.requires_detail_expansion);

    let empty = Risk::classify_tool("shell", &json!({"workdir": "/tmp"}));
    assert_eq!(empty.class, RiskClass::Unknown);
    assert_reason_mentions(&empty, "without a resolvable command");
}

#[test]
fn opencode_tool_shapes() {
    let bash = Risk::classify_tool(
        "bash",
        &json!({"command": "npm install tungstenite", "description": "install dep"}),
    );
    assert_eq!(bash.class, RiskClass::PackageInstallation);
    assert_reason_mentions(&bash, "installs packages: npm install");

    let edit = Risk::classify_tool(
        "edit",
        &json!({"filePath": "/Users/dev/src/openpaw/host/crates/openpaw-preview/src/ws.rs"}),
    );
    assert_eq!(edit.class, RiskClass::LocalWrite);
    assert_reason_mentions(&edit, "openpaw-preview/src/ws.rs");

    assert_eq!(
        Risk::classify_tool("read", &json!({"filePath": "/a/b.rs"})).class,
        RiskClass::ReadOnly
    );
    assert_eq!(
        Risk::classify_tool("write", &json!({"filePath": "/a/b.rs"})).class,
        RiskClass::LocalWrite
    );
    assert_eq!(
        Risk::classify_tool("webfetch", &json!({"url": "https://example.com"})).class,
        RiskClass::NetworkAccess
    );
}

#[test]
fn unrecognized_tools_are_unknown_and_named() {
    let risk = Risk::classify_tool("SomeMcpTool", &json!({}));
    assert_eq!(risk.class, RiskClass::Unknown);
    assert_reason_mentions(&risk, "unrecognized tool: SomeMcpTool");
}

#[test]
fn extraction_helpers_expose_what_the_adapters_need() {
    use openpaw_protocol::{extract_tool_command, extract_tool_paths};

    assert_eq!(
        extract_tool_command("shell", &json!({"command": ["bash", "-lc", "cargo test"]}))
            .as_deref(),
        Some("cargo test")
    );
    assert_eq!(
        extract_tool_command("Bash", &json!({"command": "ls -la"})).as_deref(),
        Some("ls -la")
    );
    assert_eq!(
        extract_tool_command("Read", &json!({"file_path": "/a"})),
        None
    );

    assert_eq!(
        extract_tool_paths("Read", &json!({"file_path": "/a/b.rs"})),
        vec!["/a/b.rs".to_owned()]
    );
    assert_eq!(
        extract_tool_paths("edit", &json!({"filePath": "/a/b.rs"})),
        vec!["/a/b.rs".to_owned()]
    );
    assert_eq!(
        extract_tool_paths(
            "apply_patch",
            &json!({"input": "*** Begin Patch\n*** Add File: a.rs\n*** Delete File: b.rs\n*** End Patch"})
        ),
        vec!["a.rs".to_owned(), "b.rs".to_owned()]
    );
}

#[test]
fn risk_survives_a_json_round_trip() {
    let risk = Risk::classify_command("sudo rm -rf /");
    let encoded = serde_json::to_value(&risk).unwrap();
    assert_eq!(encoded["class"], "destructive_shell");
    assert_eq!(encoded["requires_detail_expansion"], true);
    assert!(encoded["reasons"].as_array().unwrap().len() >= 2);
    let decoded: Risk = serde_json::from_value(encoded).unwrap();
    assert_eq!(decoded, risk);
}

#[test]
fn severity_order_matches_the_contract() {
    let order = [
        RiskClass::Unknown,
        RiskClass::ReadOnly,
        RiskClass::LocalWrite,
        RiskClass::GitOperation,
        RiskClass::NetworkAccess,
        RiskClass::PackageInstallation,
        RiskClass::CredentialAccess,
        RiskClass::DestructiveShell,
    ];
    for pair in order.windows(2) {
        assert!(
            pair[0].severity() < pair[1].severity(),
            "{:?} must be less severe than {:?}",
            pair[0],
            pair[1]
        );
    }
}
