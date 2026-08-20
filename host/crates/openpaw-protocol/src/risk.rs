//! Risk classification for shell commands and agent tool calls.
//!
//! Every result carries the reasons that produced it, because the phone UI must
//! never show a single undifferentiated green button. `OpenPawProtocol` (Swift)
//! mirrors this table so a device can classify locally and cross-check.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::wire_enum::wire_enum;

wire_enum! {
    /// Coarse capability bucket used to drive the approval UI.
    pub enum RiskClass {
        /// Inspects the workspace without changing it.
        ReadOnly = "read_only",
        /// Creates or edits files inside the workspace.
        LocalWrite = "local_write",
        /// Mutates git state without leaving the machine.
        GitOperation = "git_operation",
        /// Talks to the network.
        NetworkAccess = "network_access",
        /// Installs third party code.
        PackageInstallation = "package_installation",
        /// Deletes, truncates or otherwise irreversibly changes state.
        DestructiveShell = "destructive_shell",
        /// Touches credentials, keys or secrets.
        CredentialAccess = "credential_access",
        /// Nothing in the table matched.
        Unknown = "unknown",
    }
}

impl RiskClass {
    /// Ordering used when a compound command mixes classes: the highest
    /// severity segment decides the whole command. `Unknown` is the floor, so
    /// `ls && frobnicate` stays `read_only`.
    pub const fn severity(self) -> u8 {
        match self {
            RiskClass::Unknown => 0,
            RiskClass::ReadOnly => 1,
            RiskClass::LocalWrite => 2,
            RiskClass::GitOperation => 3,
            RiskClass::NetworkAccess => 4,
            RiskClass::PackageInstallation => 5,
            RiskClass::CredentialAccess => 6,
            RiskClass::DestructiveShell => 7,
        }
    }
}

/// A classification result.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Risk {
    /// The bucket this operation falls into.
    pub class: RiskClass,
    /// True when the client must show the full detail before allowing approval.
    pub requires_detail_expansion: bool,
    /// Human readable justifications naming the specific triggers.
    #[serde(default)]
    pub reasons: Vec<String>,
}

impl Risk {
    /// A classification with a single reason and no forced detail expansion.
    pub fn simple(class: RiskClass, reason: impl Into<String>) -> Risk {
        Risk {
            class,
            requires_detail_expansion: false,
            reasons: vec![reason.into()],
        }
    }

    /// The classification used when nothing could be determined.
    pub fn unknown() -> Risk {
        Risk::simple(RiskClass::Unknown, NO_RULE_MATCHED)
    }

    /// Classifies a full shell command line.
    ///
    /// The line is split on `&&`, `||`, `;`, `|` and newlines (quote aware);
    /// every segment is classified and the highest severity wins. Reasons from
    /// the winning segments are merged with every detail-expansion trigger
    /// found anywhere in the line.
    pub fn classify_command(command: &str) -> Risk {
        let mut findings = Findings::default();
        for segment in split_segments(command) {
            classify_segment(segment, &mut findings, 0);
        }
        findings.finish()
    }

    /// Classifies an agent tool call from its name and JSON input.
    ///
    /// Tool names are matched case-insensitively, so Claude Code's `Bash`,
    /// OpenCode's `bash` and Codex's `shell` all resolve to the same rule.
    pub fn classify_tool(tool: &str, input: &Value) -> Risk {
        let lowered = tool.to_ascii_lowercase();
        if is_shell_tool(&lowered) {
            return match extract_command_value(input) {
                Some(command) => Risk::classify_command(&command),
                None => Risk::simple(
                    RiskClass::Unknown,
                    "shell tool invocation without a resolvable command",
                ),
            };
        }
        match lowered.as_str() {
            "read" | "read_file" | "notebookread" | "view" | "cat" => {
                path_based_risk(&lowered, input, Access::Read)
            }
            "glob" | "grep" | "list" | "ls" | "list_dir" | "search" | "codebase_search"
            | "file_search" => Risk::simple(
                RiskClass::ReadOnly,
                format!("searches the workspace: {tool}"),
            ),
            "write" | "write_file" | "edit" | "multiedit" | "str_replace"
            | "str_replace_editor" | "notebookedit" | "create" | "create_file" => {
                path_based_risk(&lowered, input, Access::Write)
            }
            "apply_patch" | "applypatch" | "patch" => {
                let paths = patch_paths(input);
                let mut findings = Findings::default();
                if paths.is_empty() {
                    findings.class(RiskClass::LocalWrite, "applies a patch to the workspace");
                } else {
                    findings.class(
                        RiskClass::LocalWrite,
                        format!("patches files: {}", paths.join(", ")),
                    );
                }
                for path in &paths {
                    note_credential_path(path, Access::Write, &mut findings);
                }
                findings.finish()
            }
            "webfetch" | "websearch" | "web_search" | "fetch" | "browser" => Risk::simple(
                RiskClass::NetworkAccess,
                format!("contacts the network: {tool}"),
            ),
            "todowrite" | "todoread" | "update_plan" | "exitplanmode" | "plan" => Risk::simple(
                RiskClass::ReadOnly,
                "updates the agent's plan without touching the workspace",
            ),
            "task" | "agent" | "dispatch_agent" | "subagent" => Risk::simple(
                RiskClass::Unknown,
                format!("delegates to a subagent whose actions are not yet known: {tool}"),
            ),
            _ => Risk::simple(RiskClass::Unknown, format!("unrecognized tool: {tool}")),
        }
    }
}

/// Reason attached to a command that matched no rule at all.
const NO_RULE_MATCHED: &str = "no classification rule matched";

/// Substrings that mark a path or argument as credential material.
const CREDENTIAL_MARKERS: &[&str] = &[
    ".env",
    ".ssh",
    "id_ed25519",
    "id_rsa",
    ".aws",
    ".netrc",
    "keychain",
    "secrets",
    "credentials",
    "token",
    "password",
    ".pem",
    ".p12",
];

/// SQL and migration phrases that force detail expansion.
const DATABASE_MUTATIONS: &[&str] = &[
    "drop table",
    "truncate table",
    "delete from",
    "alter table",
    "prisma migrate deploy",
    "flyway migrate",
];

/// Commands that only inspect state.
///
/// This list is shared verbatim with the Swift mirror: besides driving the
/// `read_only` class it also decides whether credential material is reported as
/// read or as modified, so any divergence changes reason strings on one side.
const READ_ONLY_COMMANDS: &[&str] = &[
    "cat",
    "bat",
    "less",
    "more",
    "head",
    "tail",
    "ls",
    "tree",
    "grep",
    "egrep",
    "fgrep",
    "rg",
    "ag",
    "ack",
    "find",
    "fd",
    "wc",
    "stat",
    "file",
    "which",
    "whereis",
    "pwd",
    "whoami",
    "hostname",
    "uname",
    "date",
    "printenv",
    "echo",
    "printf",
    "sort",
    "uniq",
    "cut",
    "tr",
    "nl",
    "seq",
    "nproc",
    "awk",
    "jq",
    "yq",
    "diff",
    "basename",
    "dirname",
    "realpath",
    "readlink",
    "du",
    "df",
    "ps",
    "column",
    "xxd",
    "od",
    "md5sum",
    "shasum",
    "sha256sum",
    "cmp",
    "sed",
];

/// Commands that create or edit files inside the workspace.
const LOCAL_WRITE_COMMANDS: &[&str] = &["mkdir", "touch", "mv", "cp", "ln", "tee", "install"];

/// Commands that leave the machine.
const NETWORK_COMMANDS: &[&str] = &[
    "curl", "wget", "ssh", "scp", "rsync", "sftp", "nc", "ncat", "netcat", "telnet", "ftp", "http",
    "https", "httpie",
];

/// Commands whose entire purpose is irreversible.
const DESTRUCTIVE_COMMANDS: &[&str] = &[
    "shred", "truncate", "dd", "mkswap", "shutdown", "reboot", "halt", "poweroff",
];

/// Shells whose `-c` argument is itself a command line.
const SHELL_COMMANDS: &[&str] = &["sh", "bash", "zsh", "dash", "ksh", "fish"];

/// Wrappers that can be looked through to find the real argv0.
const TRANSPARENT_WRAPPERS: &[&str] = &[
    "env", "nohup", "command", "builtin", "exec", "time", "stdbuf", "setsid", "nice", "ionice",
];

/// Git subcommands that only read.
const GIT_READ_SUBCOMMANDS: &[&str] = &["status", "log", "diff", "show", "blame", "describe"];

/// Git subcommands that mutate local repository state.
const GIT_MUTATING_SUBCOMMANDS: &[&str] = &[
    "commit",
    "add",
    "checkout",
    "branch",
    "merge",
    "rebase",
    "stash",
    "push",
    "pull",
    "reset",
    "tag",
    "cherry-pick",
    "revert",
    "apply",
    "am",
    "restore",
    "switch",
    "worktree",
    "submodule",
];

/// Git subcommands that contact a remote.
const GIT_NETWORK_SUBCOMMANDS: &[&str] = &["push", "pull", "fetch", "clone"];

/// Maximum depth for looking through `bash -c "..."` wrappers.
const MAX_NESTING_DEPTH: u8 = 3;

/// True for tool names that carry a shell command line.
///
/// `local_shell_call` is the item type Codex writes into its on-disk rollout
/// for sandboxed shell calls, so it must resolve here rather than falling
/// through to "unrecognized tool".
fn is_shell_tool(lowered: &str) -> bool {
    matches!(
        lowered,
        "bash"
            | "shell"
            | "sh"
            | "zsh"
            | "run_command"
            | "local_shell"
            | "local_shell_call"
            | "terminal"
    )
}

/// Extracts the command line a shell-like tool would run.
///
/// Handles a plain `command` string, an argv array, the
/// `["bash", "-lc", "<script>"]` form Codex emits, and a `cmd` fallback key.
pub fn extract_tool_command(tool: &str, input: &Value) -> Option<String> {
    if is_shell_tool(&tool.to_ascii_lowercase()) {
        extract_command_value(input)
    } else {
        None
    }
}

/// Extracts every filesystem path a tool call refers to.
///
/// Covers the path key spellings used by Claude Code (`file_path`,
/// `notebook_path`), OpenCode (`filePath`) and Codex (`apply_patch` headers),
/// plus the `path`/`file`/`target_file`/`paths`/`files` spellings other agents
/// use. Shared verbatim with the Swift mirror.
pub fn extract_tool_paths(tool: &str, input: &Value) -> Vec<String> {
    let lowered = tool.to_ascii_lowercase();
    if matches!(lowered.as_str(), "apply_patch" | "applypatch" | "patch") {
        return patch_paths(input);
    }

    let mut out: Vec<String> = Vec::new();
    for key in [
        "file_path",
        "filePath",
        "notebook_path",
        "notebookPath",
        "path",
        "file",
        "filename",
        "target_file",
    ] {
        if let Some(text) = input.get(key).and_then(Value::as_str) {
            push_unique(&mut out, text);
        }
    }
    for key in ["paths", "files"] {
        if let Some(items) = input.get(key).and_then(Value::as_array) {
            for item in items {
                if let Some(text) = item.as_str() {
                    push_unique(&mut out, text);
                }
            }
        }
    }
    for candidate in patch_paths(input) {
        push_unique(&mut out, &candidate);
    }
    out
}

fn push_unique(out: &mut Vec<String>, candidate: &str) {
    if !candidate.is_empty() && !out.iter().any(|existing| existing == candidate) {
        out.push(candidate.to_owned());
    }
}

// ---------------------------------------------------------------------------
// finding accumulation
// ---------------------------------------------------------------------------

/// Whether an operation reads or writes the paths it names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Access {
    Read,
    Write,
}

#[derive(Debug, Default)]
struct Findings {
    classed: Vec<(RiskClass, String)>,
    expansion: Vec<String>,
}

impl Findings {
    fn class(&mut self, class: RiskClass, reason: impl Into<String>) {
        if class == RiskClass::Unknown {
            return;
        }
        self.classed.push((class, reason.into()));
    }

    fn expand(&mut self, reason: impl Into<String>) {
        self.expansion.push(reason.into());
    }

    fn finish(self) -> Risk {
        let top = self
            .classed
            .iter()
            .map(|(class, _)| class.severity())
            .max()
            .unwrap_or(0);
        let class = self
            .classed
            .iter()
            .find(|(class, _)| class.severity() == top)
            .map(|(class, _)| *class)
            .unwrap_or(RiskClass::Unknown);

        let mut reasons: Vec<String> = Vec::new();
        for (found, reason) in &self.classed {
            if found.severity() == top {
                push_unique(&mut reasons, reason);
            }
        }
        for reason in &self.expansion {
            push_unique(&mut reasons, reason);
        }
        if reasons.is_empty() {
            reasons.push(NO_RULE_MATCHED.to_owned());
        }

        Risk {
            class,
            requires_detail_expansion: !self.expansion.is_empty(),
            reasons,
        }
    }
}

// ---------------------------------------------------------------------------
// shell parsing
// ---------------------------------------------------------------------------

/// Splits a command line into independently classifiable segments.
///
/// Quote and escape aware, so `grep "a;b" f` stays one segment. `>&` is
/// recognised as a file descriptor duplication rather than a separator.
fn split_segments(command: &str) -> Vec<&str> {
    let bytes = command.as_bytes();
    let mut out: Vec<&str> = Vec::new();
    let mut start = 0usize;
    let mut index = 0usize;
    let mut quote: Option<u8> = None;

    while index < bytes.len() {
        let byte = bytes[index];
        match quote {
            Some(delimiter) => {
                if byte == b'\\' && delimiter == b'"' {
                    index += 2;
                    continue;
                }
                if byte == delimiter {
                    quote = None;
                }
                index += 1;
            }
            None => match byte {
                b'\'' | b'"' => {
                    quote = Some(byte);
                    index += 1;
                }
                b'\\' => index += 2,
                b'\n' | b';' => {
                    out.push(&command[start..index]);
                    index += 1;
                    start = index;
                }
                b'&' | b'|' => {
                    if byte == b'&' && index > 0 && bytes[index - 1] == b'>' {
                        index += 1;
                        continue;
                    }
                    let width = if bytes.get(index + 1) == Some(&byte) {
                        2
                    } else {
                        1
                    };
                    out.push(&command[start..index]);
                    index += width;
                    start = index;
                }
                _ => index += 1,
            },
        }
    }
    out.push(&command[start.min(command.len())..]);
    out.into_iter()
        .map(str::trim)
        .filter(|segment| !segment.is_empty())
        .collect()
}

/// Splits a segment into shell words, removing one level of quoting.
fn tokenize(segment: &str) -> Vec<String> {
    let mut tokens: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut has_token = false;
    let mut quote: Option<char> = None;
    let mut chars = segment.chars();

    while let Some(ch) = chars.next() {
        match quote {
            Some('\'') => {
                if ch == '\'' {
                    quote = None;
                } else {
                    current.push(ch);
                }
            }
            Some(_) => match ch {
                '\\' => {
                    if let Some(escaped) = chars.next() {
                        current.push(escaped);
                    }
                }
                '"' => quote = None,
                _ => current.push(ch),
            },
            None => match ch {
                '\'' | '"' => {
                    quote = Some(ch);
                    has_token = true;
                }
                '\\' => {
                    if let Some(escaped) = chars.next() {
                        current.push(escaped);
                        has_token = true;
                    }
                }
                _ if ch.is_whitespace() => {
                    if has_token {
                        tokens.push(std::mem::take(&mut current));
                        has_token = false;
                    }
                }
                _ => {
                    current.push(ch);
                    has_token = true;
                }
            },
        }
    }
    if has_token {
        tokens.push(current);
    }
    tokens
}

/// The command word plus its arguments, after looking through wrappers.
struct Invocation<'a> {
    argv0: String,
    args: &'a [String],
    elevation: Option<&'static str>,
}

fn parse_invocation(tokens: &[String]) -> Option<Invocation<'_>> {
    let mut index = 0usize;
    let mut elevation: Option<&'static str> = None;

    while index < tokens.len() {
        let token = &tokens[index];
        if is_env_assignment(token) {
            index += 1;
            continue;
        }
        let word = basename(token);
        match word {
            "sudo" | "doas" => {
                elevation = Some(if word == "sudo" { "sudo" } else { "doas" });
                index += 1;
                index += skip_wrapper_flags(&tokens[index..], wrapper_value_flags(word));
            }
            _ if TRANSPARENT_WRAPPERS.contains(&word) => {
                index += 1;
                index += skip_wrapper_flags(&tokens[index..], wrapper_value_flags(word));
            }
            _ => {
                return Some(Invocation {
                    argv0: word.to_owned(),
                    args: &tokens[index + 1..],
                    elevation,
                });
            }
        }
    }
    None
}

/// Flags that consume the following token, scoped to the wrapper that owns
/// them.
///
/// A global list is wrong in both directions and both errors resolve argv0 to a
/// flag value, dropping the command to `unknown`: too narrow and
/// `ionice -c 3 npm install` resolves to `3`, too wide and `sudo -n npm install`
/// resolves to `install` because real sudo's `-n` (non-interactive) takes no
/// value. Attached (`-o0`) and `--flag=value` forms match nothing here, which is
/// correct: they carry their own value.
fn wrapper_value_flags(wrapper: &str) -> &'static [&'static str] {
    match wrapper {
        "sudo" => &[
            "-u",
            "--user",
            "-g",
            "--group",
            "-p",
            "--prompt",
            "-C",
            "--close-from",
            "-r",
            "--role",
            "-t",
            "--type",
            "-h",
            "--host",
        ],
        "doas" => &["-u", "-C"],
        "env" => &["-u", "--unset", "-C", "--chdir", "-S", "--split-string"],
        "nice" => &["-n", "--adjustment"],
        "ionice" => &["-c", "--class", "-n", "--classdata", "-p", "--pid"],
        "stdbuf" => &["-i", "--input", "-o", "--output", "-e", "--error"],
        "time" => &["-f", "--format", "-o", "--output"],
        // nohup, command, builtin, exec, setsid take no value flags.
        _ => &[],
    }
}

/// Number of leading flag tokens (and their values) to skip.
fn skip_wrapper_flags(tokens: &[String], flags_with_values: &[&str]) -> usize {
    let mut skipped = 0usize;
    while let Some(token) = tokens.get(skipped) {
        if !token.starts_with('-') || token == "-" {
            break;
        }
        skipped += 1;
        if flags_with_values.contains(&token.as_str()) && tokens.len() > skipped {
            skipped += 1;
        }
    }
    skipped
}

fn is_env_assignment(token: &str) -> bool {
    let Some(equals) = token.find('=') else {
        return false;
    };
    let name = &token[..equals];
    !name.is_empty()
        && !name.starts_with(|ch: char| ch.is_ascii_digit())
        && name
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
}

fn basename(token: &str) -> &str {
    match token.rsplit_once('/') {
        Some((_, tail)) if !tail.is_empty() => tail,
        _ => token,
    }
}

/// First argument that is not a flag, used as a subcommand.
fn subcommand(args: &[String]) -> Option<&str> {
    args.iter()
        .find(|arg| !arg.starts_with('-'))
        .map(String::as_str)
}

fn has_flag(args: &[String], flags: &[&str]) -> bool {
    args.iter().any(|arg| {
        flags.contains(&arg.as_str())
            || flags.iter().any(|flag| {
                flag.starts_with("--")
                    && arg.starts_with(flag)
                    && arg.as_bytes().get(flag.len()) == Some(&b'=')
            })
    })
}

/// Detects unquoted output redirections and reports their targets.
fn redirections(segment: &str) -> Vec<(&'static str, String)> {
    let bytes = segment.as_bytes();
    let mut out = Vec::new();
    let mut index = 0usize;
    let mut quote: Option<u8> = None;

    while index < bytes.len() {
        let byte = bytes[index];
        match quote {
            Some(delimiter) => {
                if byte == b'\\' && delimiter == b'"' {
                    index += 2;
                    continue;
                }
                if byte == delimiter {
                    quote = None;
                }
                index += 1;
            }
            None => match byte {
                b'\'' | b'"' => {
                    quote = Some(byte);
                    index += 1;
                }
                b'\\' => index += 2,
                b'>' => {
                    let append = bytes.get(index + 1) == Some(&b'>');
                    let mut cursor = index + if append { 2 } else { 1 };
                    // `2>&1` and `&>` duplicate descriptors; nothing is truncated.
                    if bytes.get(cursor) == Some(&b'&') {
                        index = cursor + 1;
                        continue;
                    }
                    while bytes.get(cursor) == Some(&b' ') {
                        cursor += 1;
                    }
                    let target_start = cursor;
                    while let Some(next) = bytes.get(cursor) {
                        if next.is_ascii_whitespace() {
                            break;
                        }
                        cursor += 1;
                    }
                    let target = segment[target_start..cursor].trim_matches(['"', '\'']);
                    let target = if target.is_empty() { "a file" } else { target };
                    out.push((
                        if append { "appends to" } else { "overwrites" },
                        target.to_owned(),
                    ));
                    index = cursor;
                }
                _ => index += 1,
            },
        }
    }
    out
}

// ---------------------------------------------------------------------------
// segment classification
// ---------------------------------------------------------------------------

fn classify_segment(segment: &str, findings: &mut Findings, depth: u8) {
    let lowered = segment.to_ascii_lowercase();

    for (verb, target) in redirections(segment) {
        findings.class(
            RiskClass::DestructiveShell,
            format!("shell redirection {verb} {target}"),
        );
    }

    for phrase in DATABASE_MUTATIONS {
        if lowered.contains(phrase) {
            findings.expand(format!("requires review: database mutation ({phrase})"));
        }
    }

    let tokens = tokenize(segment);
    let Some(invocation) = parse_invocation(&tokens) else {
        return;
    };
    let argv0 = invocation.argv0.as_str();
    let args = invocation.args;

    if let Some(elevation) = invocation.elevation {
        findings.expand(format!(
            "requires review: elevated privileges via {elevation}"
        ));
    }

    // Look through `bash -c "..."` so the real command gets classified.
    if SHELL_COMMANDS.contains(&argv0)
        && depth < MAX_NESTING_DEPTH
        && let Some(script) = shell_script_argument(args)
    {
        for inner in split_segments(script) {
            classify_segment(inner, findings, depth + 1);
        }
        return;
    }

    // Credential material named anywhere in the segment.
    let access = if is_mutating_command(argv0, args) {
        Access::Write
    } else {
        Access::Read
    };
    for marker in CREDENTIAL_MARKERS {
        if lowered.contains(marker) {
            note_credential_marker(marker, access, findings);
        }
    }

    // `rm` is matched as a whole word anywhere in the segment, not just as
    // argv0, so `find . -exec rm {} \;` and `git rm -r src` are caught. Whole
    // word matching keeps `charm` and a `--rm` flag out of it.
    for token in &tokens {
        match basename(token) {
            "rm" => {
                findings.class(RiskClass::DestructiveShell, "deletes files: rm");
                findings.expand("requires review: rm deletes files");
            }
            "rmdir" => {
                findings.class(RiskClass::DestructiveShell, "deletes directories: rmdir");
            }
            _ => {}
        }
    }

    if classify_git(argv0, args, findings) {
        return;
    }
    if classify_package_manager(argv0, args, findings) {
        return;
    }
    classify_deploy(argv0, args, findings);
    if classify_database_client(argv0, args, findings) {
        return;
    }

    match argv0 {
        _ if argv0.starts_with("mkfs") => {
            findings.class(
                RiskClass::DestructiveShell,
                format!("formats a filesystem: {argv0}"),
            );
        }
        _ if DESTRUCTIVE_COMMANDS.contains(&argv0) => {
            findings.class(
                RiskClass::DestructiveShell,
                format!("irreversible operation: {argv0}"),
            );
        }
        "chmod" | "chown" | "chgrp" if has_flag(args, &["-R", "-r", "--recursive"]) => {
            findings.class(
                RiskClass::DestructiveShell,
                format!("recursive permission change: {argv0} -R"),
            );
        }
        "chmod" | "chown" | "chgrp" => {
            findings.class(
                RiskClass::LocalWrite,
                format!("changes file metadata: {argv0}"),
            );
        }
        "kill" | "pkill" | "killall" if has_flag(args, &["-9", "-KILL", "-SIGKILL"]) => {
            findings.class(
                RiskClass::DestructiveShell,
                format!("force kills processes: {argv0} -9"),
            );
        }
        "sed" if args.iter().any(|arg| arg.starts_with("-i")) => {
            findings.class(RiskClass::LocalWrite, "edits files in place: sed -i");
        }
        _ if NETWORK_COMMANDS.contains(&argv0) => {
            findings.class(
                RiskClass::NetworkAccess,
                format!("contacts the network: {argv0}"),
            );
        }
        _ if LOCAL_WRITE_COMMANDS.contains(&argv0) => {
            findings.class(
                RiskClass::LocalWrite,
                format!("writes to the filesystem: {argv0}"),
            );
        }
        _ if READ_ONLY_COMMANDS.contains(&argv0) => {
            findings.class(
                RiskClass::ReadOnly,
                format!("reads without modifying: {argv0}"),
            );
        }
        _ => {}
    }
}

/// True when the command is expected to change the paths it names, which
/// decides whether credential material is being read or rewritten.
fn is_mutating_command(argv0: &str, args: &[String]) -> bool {
    if argv0 == "git" {
        return !matches!(subcommand(args), Some(sub) if GIT_READ_SUBCOMMANDS.contains(&sub));
    }
    if argv0 == "sed" {
        return args.iter().any(|arg| arg.starts_with("-i"));
    }
    !READ_ONLY_COMMANDS.contains(&argv0)
}

fn shell_script_argument(args: &[String]) -> Option<&str> {
    for (index, arg) in args.iter().enumerate() {
        if arg.starts_with('-') && arg.len() > 1 && arg[1..].contains('c') {
            return args.get(index + 1).map(String::as_str);
        }
    }
    None
}

fn classify_git(argv0: &str, args: &[String], findings: &mut Findings) -> bool {
    if argv0 != "git" {
        return false;
    }
    let Some(sub) = subcommand(args) else {
        findings.class(RiskClass::ReadOnly, "reads without modifying: git");
        return true;
    };

    if sub == "clean" {
        findings.class(
            RiskClass::DestructiveShell,
            "deletes untracked files: git clean",
        );
        return true;
    }
    if sub == "reset" && has_flag(args, &["--hard"]) {
        findings.class(
            RiskClass::DestructiveShell,
            "discards local commits: git reset --hard",
        );
        return true;
    }

    if GIT_NETWORK_SUBCOMMANDS.contains(&sub) {
        findings.class(
            RiskClass::NetworkAccess,
            format!("contacts the network: git {sub}"),
        );
    }
    if GIT_MUTATING_SUBCOMMANDS.contains(&sub) {
        findings.class(
            RiskClass::GitOperation,
            format!("mutates git state: git {sub}"),
        );
    }
    if GIT_READ_SUBCOMMANDS.contains(&sub) {
        findings.class(
            RiskClass::ReadOnly,
            format!("reads without modifying: git {sub}"),
        );
    }

    if sub == "push" {
        for flag in ["--force-with-lease", "--force", "-f"] {
            if has_flag(args, &[flag]) {
                findings.expand(format!("requires review: force push ({flag})"));
                break;
            }
        }
    }
    true
}

fn classify_package_manager(argv0: &str, args: &[String], findings: &mut Findings) -> bool {
    let sub = subcommand(args);
    match argv0 {
        "npm" | "pnpm" | "yarn" | "bun" => match sub {
            Some(word @ ("install" | "add" | "i" | "ci")) => {
                findings.class(
                    RiskClass::PackageInstallation,
                    format!("installs packages: {argv0} {word}"),
                );
                true
            }
            _ => false,
        },
        "pip" | "pip3" => match sub {
            Some("install") => {
                findings.class(
                    RiskClass::PackageInstallation,
                    format!("installs packages: {argv0} install"),
                );
                true
            }
            _ => false,
        },
        "python" | "python3" => {
            let words: Vec<&str> = args.iter().map(String::as_str).collect();
            if let Some(position) = words.iter().position(|word| *word == "pip")
                && words.get(position + 1) == Some(&"install")
            {
                findings.class(
                    RiskClass::PackageInstallation,
                    format!("installs packages: {argv0} -m pip install"),
                );
                return true;
            }
            false
        }
        "uv" => match sub {
            Some("add") => {
                findings.class(RiskClass::PackageInstallation, "installs packages: uv add");
                true
            }
            Some("pip") if args.iter().any(|arg| arg == "install") => {
                findings.class(
                    RiskClass::PackageInstallation,
                    "installs packages: uv pip install",
                );
                true
            }
            _ => false,
        },
        "cargo" | "gem" | "go" | "brew" => match sub {
            Some("install") => {
                findings.class(
                    RiskClass::PackageInstallation,
                    format!("installs packages: {argv0} install"),
                );
                true
            }
            _ => false,
        },
        "apt" | "apt-get" | "dnf" | "yum" | "apk" | "zypper" => match sub {
            Some(word @ ("install" | "add")) => {
                findings.class(
                    RiskClass::PackageInstallation,
                    format!("installs packages: {argv0} {word}"),
                );
                true
            }
            _ => false,
        },
        "pacman" if args.iter().any(|arg| arg.starts_with("-S")) => {
            findings.class(
                RiskClass::PackageInstallation,
                "installs packages: pacman -S",
            );
            true
        }
        _ => false,
    }
}

/// Records production deploy detail-expansion triggers. Never decides the
/// class: deploy tooling is too varied to bucket reliably.
fn classify_deploy(argv0: &str, args: &[String], findings: &mut Findings) {
    let sub = subcommand(args);
    match argv0 {
        "kubectl" => {
            if let Some(namespace) = kubectl_namespace(args)
                && namespace.to_ascii_lowercase().contains("prod")
            {
                findings.expand(format!(
                    "requires review: production deploy (kubectl -n {namespace})"
                ));
            }
        }
        "terraform" if matches!(sub, Some("apply") | Some("destroy")) => {
            let word = sub.unwrap_or("apply");
            findings.expand(format!(
                "requires review: production deploy (terraform {word})"
            ));
        }
        "vercel" if has_flag(args, &["--prod", "--production"]) => {
            findings.expand("requires review: production deploy (vercel --prod)");
        }
        "fly" | "flyctl" if sub == Some("deploy") => {
            findings.expand("requires review: production deploy (fly deploy)");
        }
        "helm" if sub == Some("upgrade") => {
            findings.expand("requires review: production deploy (helm upgrade)");
        }
        _ => {}
    }
}

fn kubectl_namespace(args: &[String]) -> Option<String> {
    for (index, arg) in args.iter().enumerate() {
        if arg == "-n" || arg == "--namespace" {
            return args.get(index + 1).cloned();
        }
        if let Some(value) = arg.strip_prefix("--namespace=") {
            return Some(value.to_owned());
        }
        if arg.len() > 2 && arg.starts_with("-n") && !arg.starts_with("--") {
            return Some(arg[2..].to_owned());
        }
    }
    None
}

fn classify_database_client(argv0: &str, args: &[String], findings: &mut Findings) -> bool {
    match argv0 {
        "psql" if has_flag(args, &["-c", "--command"]) => {
            findings.expand("requires review: database mutation (psql -c)");
            true
        }
        "mysql" if has_flag(args, &["-e", "--execute"]) => {
            findings.expand("requires review: database mutation (mysql -e)");
            true
        }
        _ => false,
    }
}

// ---------------------------------------------------------------------------
// credential rules
// ---------------------------------------------------------------------------

fn note_credential_marker(marker: &str, access: Access, findings: &mut Findings) {
    match access {
        Access::Read => {
            findings.class(
                RiskClass::CredentialAccess,
                format!("reads credential material: {marker}"),
            );
            findings.expand(format!("requires review: credential material ({marker})"));
        }
        Access::Write => {
            findings.class(
                RiskClass::CredentialAccess,
                format!("modifies credential material: {marker}"),
            );
            findings.expand(format!(
                "requires review: modifies credential material ({marker})"
            ));
        }
    }
}

fn note_credential_path(path: &str, access: Access, findings: &mut Findings) {
    let lowered = path.to_ascii_lowercase();
    for marker in CREDENTIAL_MARKERS {
        if lowered.contains(marker) {
            note_credential_marker(marker, access, findings);
        }
    }
}

// ---------------------------------------------------------------------------
// tool input extraction
// ---------------------------------------------------------------------------

fn path_based_risk(lowered_tool: &str, input: &Value, access: Access) -> Risk {
    let paths = extract_tool_paths(lowered_tool, input);
    let mut findings = Findings::default();

    let described = if paths.is_empty() {
        None
    } else {
        Some(paths.join(", "))
    };
    match (access, described.as_deref()) {
        (Access::Read, Some(list)) => {
            findings.class(RiskClass::ReadOnly, format!("reads files: {list}"));
        }
        (Access::Read, None) => findings.class(
            RiskClass::ReadOnly,
            format!("reads without modifying: {lowered_tool}"),
        ),
        (Access::Write, Some(list)) => {
            findings.class(RiskClass::LocalWrite, format!("writes files: {list}"));
        }
        (Access::Write, None) => findings.class(
            RiskClass::LocalWrite,
            format!("writes to the filesystem: {lowered_tool}"),
        ),
    }
    for path in &paths {
        note_credential_path(path, access, &mut findings);
    }
    findings.finish()
}

fn extract_command_value(input: &Value) -> Option<String> {
    if let Some(text) = input.as_str() {
        return non_empty(text);
    }
    for key in ["command", "cmd", "script", "commandLine"] {
        match input.get(key) {
            Some(Value::String(text)) => {
                if let Some(command) = non_empty(text) {
                    return Some(command);
                }
            }
            Some(Value::Array(items)) => {
                if let Some(command) = command_from_argv(items) {
                    return Some(command);
                }
            }
            _ => {}
        }
    }
    None
}

/// Turns an argv array into a command line.
///
/// `["bash", "-lc", "<script>"]` yields the script itself, because that is the
/// command the operator actually cares about. Anything else is joined with
/// spaces, re-quoting words that contain whitespace.
fn command_from_argv(items: &[Value]) -> Option<String> {
    let words: Vec<&str> = items.iter().filter_map(Value::as_str).collect();
    if words.is_empty() {
        return None;
    }
    if words.len() >= 3
        && SHELL_COMMANDS.contains(&basename(words[0]))
        && words[1].starts_with('-')
        && words[1][1..].contains('c')
    {
        return non_empty(words[2]);
    }
    let joined = words
        .iter()
        .map(|word| {
            if word.contains(char::is_whitespace) {
                format!("'{word}'")
            } else {
                (*word).to_owned()
            }
        })
        .collect::<Vec<String>>()
        .join(" ");
    non_empty(&joined)
}

fn non_empty(text: &str) -> Option<String> {
    if text.trim().is_empty() {
        None
    } else {
        Some(text.to_owned())
    }
}

/// Extracts the files a Codex-style patch touches.
fn patch_paths(input: &Value) -> Vec<String> {
    let text = match input {
        Value::String(text) => Some(text.as_str()),
        _ => ["input", "patch", "diff", "content"]
            .iter()
            .find_map(|key| input.get(*key).and_then(Value::as_str)),
    };
    let Some(text) = text else {
        return Vec::new();
    };

    let mut out: Vec<String> = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim();
        for header in [
            "*** Add File: ",
            "*** Update File: ",
            "*** Delete File: ",
            "*** Move to: ",
        ] {
            if let Some(path) = trimmed.strip_prefix(header) {
                push_unique(&mut out, path.trim());
            }
        }
    }
    out
}
