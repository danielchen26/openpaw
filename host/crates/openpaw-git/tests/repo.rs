//! Integration tests against real temporary git repositories.
//!
//! Every case shells out to `git` to build an actual work tree, then drives
//! `openpaw_git` over it. Nothing is mocked: if the assertions hold, they hold
//! against the git binary installed on this machine.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use openpaw_files::{BlobContent, EntryKind, FileError, ReadOptions, Roots};
use openpaw_git::{
    ChangeKind, Diff, DiffMode, DiffRequest, GitError, LineKind, Repo, open_named, summaries,
};
use tempfile::TempDir;

/// Bytes with a NUL and an invalid UTF-8 tail; sha256 verified with `shasum -a 256`.
const BINARY_BYTES: &[u8] = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xff\xfe";
const BINARY_SHA256: &str = "044dbe64b84ec81c26e4b498bed689fadef7c13d77b7394fd658e17783cd184a";

const MAX_BYTES: u64 = 1024 * 1024;

/// A temporary repository with two commits of history.
struct Fixture {
    _dir: TempDir,
    home: PathBuf,
    workspace: PathBuf,
    outside: PathBuf,
    roots: Roots,
    repo: Repo,
    first_commit: String,
}

impl Fixture {
    fn git(&self, args: &[&str]) -> String {
        run_git(&self.home, &self.workspace, args)
    }

    fn write(&self, relative: &str, content: &str) {
        let path = self.workspace.join(relative);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create parent");
        }
        fs::write(path, content).expect("write file");
    }

    fn diff(&self, mode: DiffMode, path: Option<&str>) -> Diff {
        self.repo
            .diff(&DiffRequest {
                mode,
                path: path.map(str::to_owned),
            })
            .expect("diff")
    }
}

fn git_available() -> bool {
    Command::new("git")
        .arg("--version")
        .output()
        .is_ok_and(|out| out.status.success())
}

/// Run git with a throwaway HOME so the developer's own `~/.gitconfig` cannot
/// change the outcome of a test.
fn run_git(home: &Path, cwd: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .current_dir(cwd)
        .args([
            "-c",
            "user.email=test@openpaw.invalid",
            "-c",
            "user.name=OpenPaw Test",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "advice.detachedHead=false",
        ])
        .args(args)
        .env("HOME", home)
        .env("XDG_CONFIG_HOME", home)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .expect("spawn git");
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

fn lines_to_string(lines: &[&str]) -> String {
    let mut out = String::new();
    for line in lines {
        out.push_str(line);
        out.push('\n');
    }
    out
}

/// `src/lib.rs` as committed in the first commit.
fn lib_initial() -> Vec<&'static str> {
    vec![
        "line 1", "line 2", "line 3", "line 4", "line 5", "line 6", "line 7", "line 8", "line 9",
        "line 10",
    ]
}

/// `src/lib.rs` as committed in the second commit: line 5 rewritten.
fn lib_at_head() -> Vec<&'static str> {
    let mut lines = lib_initial();
    lines[4] = "line five (changed)";
    lines
}

/// Two commits of history:
///
/// * commit 1 adds `README.md`, `src/lib.rs`, `docs/guide.md`, `logo.png`, `old/name.txt`
/// * commit 2 rewrites line 5 of `src/lib.rs`, adds `src/new.rs`, deletes `docs/guide.md`
fn fixture() -> Fixture {
    let dir = TempDir::new().expect("tempdir");
    let home = fs::canonicalize(dir.path()).expect("canonicalize tempdir");
    let workspace = home.join("workspace");
    let outside = home.join("outside");
    fs::create_dir_all(&workspace).expect("workspace");
    fs::create_dir_all(&outside).expect("outside");
    fs::write(outside.join("secret.txt"), "top secret\n").expect("secret");

    run_git(&home, &home, &["init", "-b", "main", "workspace"]);

    let write = |relative: &str, content: &str| {
        let path = workspace.join(relative);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("parent");
        }
        fs::write(path, content).expect("write");
    };
    write("README.md", "# Fixture\n\nline two\nline three\n");
    write("src/lib.rs", &lines_to_string(&lib_initial()));
    write("docs/guide.md", "guide\n");
    write("old/name.txt", "renamed content one\nrenamed content two\n");
    fs::write(workspace.join("logo.png"), BINARY_BYTES).expect("binary");

    run_git(&home, &workspace, &["add", "-A"]);
    run_git(&home, &workspace, &["commit", "-m", "initial commit"]);
    let first_commit = run_git(&home, &workspace, &["rev-parse", "HEAD"]);

    write("src/lib.rs", &lines_to_string(&lib_at_head()));
    write("src/new.rs", "// added in the second commit\n");
    run_git(&home, &workspace, &["rm", "-q", "docs/guide.md"]);
    run_git(&home, &workspace, &["add", "-A"]);
    run_git(&home, &workspace, &["commit", "-m", "second commit"]);

    let roots = Roots::new([workspace.clone(), outside.clone()]).expect("roots");
    let repo = Repo::open(roots.root("workspace").expect("root").clone()).expect("open repo");

    Fixture {
        _dir: dir,
        home,
        workspace,
        outside,
        roots,
        repo,
        first_commit,
    }
}

/// Every hunk must account for exactly as many lines as its `@@` range claims.
/// This is the invariant that catches off-by-one errors in the parser.
fn assert_hunk_math(diff: &Diff) {
    for file in &diff.files {
        for hunk in &file.hunks {
            let old_count = hunk
                .lines
                .iter()
                .filter(|line| matches!(line.kind, LineKind::Context | LineKind::Removed))
                .count();
            let new_count = hunk
                .lines
                .iter()
                .filter(|line| matches!(line.kind, LineKind::Context | LineKind::Added))
                .count();
            assert_eq!(
                old_count as u32, hunk.old_lines,
                "old line count mismatch in {} {}",
                file.path, hunk.header
            );
            assert_eq!(
                new_count as u32, hunk.new_lines,
                "new line count mismatch in {} {}",
                file.path, hunk.header
            );
            // Line numbers must be contiguous and start where the header says.
            let mut old_next = hunk.old_start;
            let mut new_next = hunk.new_start;
            for line in &hunk.lines {
                if let Some(old) = line.old_line {
                    assert_eq!(old, old_next, "old numbering broke in {}", file.path);
                    old_next += 1;
                }
                if let Some(new) = line.new_line {
                    assert_eq!(new, new_next, "new numbering broke in {}", file.path);
                    new_next += 1;
                }
            }
        }
    }
}

fn changed(diff: &Diff) -> Vec<(String, ChangeKind)> {
    let mut out: Vec<(String, ChangeKind)> = diff
        .files
        .iter()
        .map(|file| (file.path.clone(), file.change))
        .collect();
    out.sort_by(|left, right| left.0.cmp(&right.0));
    out
}

#[test]
fn summary_reports_clean_then_dirty() {
    if !git_available() {
        return;
    }
    let fx = fixture();

    let clean = fx.repo.summary().expect("summary");
    assert_eq!(clean.name, "workspace");
    assert_eq!(clean.path, fx.workspace.to_string_lossy());
    assert_eq!(clean.branch.as_deref(), Some("main"));
    assert!(!clean.dirty, "a freshly committed repo is clean");
    assert_eq!((clean.ahead, clean.behind), (0, 0));

    fx.write("scratch.txt", "untracked\n");
    assert!(
        fx.repo.summary().expect("summary").dirty,
        "an untracked file makes the repo dirty"
    );

    fx.git(&["add", "scratch.txt"]);
    assert!(
        fx.repo.summary().expect("summary").dirty,
        "a staged file makes the repo dirty"
    );

    fx.git(&["commit", "-m", "third commit"]);
    assert!(!fx.repo.summary().expect("summary").dirty);
}

#[test]
fn status_parses_added_modified_deleted_renamed_and_untracked() {
    if !git_available() {
        return;
    }
    let fx = fixture();

    fs::create_dir_all(fx.workspace.join("new")).expect("rename target dir");
    fx.git(&["mv", "old/name.txt", "new/name.txt"]);
    fx.write("added.txt", "brand new\n");
    fx.git(&["add", "added.txt"]);
    fx.git(&["rm", "-q", "README.md"]);
    let mut edited = lib_at_head();
    edited[0] = "line one (edited in the work tree)";
    fx.write("src/lib.rs", &lines_to_string(&edited));
    fx.write("scratch.txt", "untracked\n");

    let status = fx.repo.status().expect("status");
    assert_eq!(status.branch, "main");
    assert!(!status.detached);
    assert!(status.is_dirty());
    assert_eq!(status.conflicted, Vec::<String>::new());

    let staged: Vec<(&str, ChangeKind, Option<&str>)> = status
        .staged
        .iter()
        .map(|entry| (entry.path.as_str(), entry.change, entry.old_path.as_deref()))
        .collect();
    assert!(
        staged.contains(&("added.txt", ChangeKind::Added, None)),
        "staged add missing: {staged:?}"
    );
    assert!(
        staged.contains(&("README.md", ChangeKind::Deleted, None)),
        "staged delete missing: {staged:?}"
    );
    assert!(
        staged.contains(&("new/name.txt", ChangeKind::Renamed, Some("old/name.txt"))),
        "staged rename missing: {staged:?}"
    );

    let unstaged: Vec<(&str, ChangeKind)> = status
        .unstaged
        .iter()
        .map(|entry| (entry.path.as_str(), entry.change))
        .collect();
    assert_eq!(unstaged, vec![("src/lib.rs", ChangeKind::Modified)]);

    let untracked: Vec<&str> = status
        .untracked
        .iter()
        .map(|entry| entry.path.as_str())
        .collect();
    assert_eq!(untracked, vec!["scratch.txt"]);
    assert!(
        status
            .untracked
            .iter()
            .all(|entry| entry.change == ChangeKind::Added)
    );
}

#[test]
fn detached_head_is_reported_as_a_commit() {
    if !git_available() {
        return;
    }
    let fx = fixture();
    fx.git(&["checkout", &fx.first_commit]);

    let status = fx.repo.status().expect("status");
    assert!(status.detached);
    assert_eq!(status.branch, fx.first_commit[..7]);
    assert_eq!(fx.repo.summary().expect("summary").branch, None);
}

#[test]
fn working_tree_diff_numbers_every_line() {
    if !git_available() {
        return;
    }
    let fx = fixture();
    // head: line 1..4, "line five (changed)", line 6..10
    // work: insert INSERTED after line 2, rewrite line 5, delete line 8
    let edited = [
        "line 1", "line 2", "INSERTED", "line 3", "line 4", "EDITED 5", "line 6", "line 7",
        "line 9", "line 10",
    ];
    fx.write("src/lib.rs", &lines_to_string(&edited));

    let diff = fx.diff(DiffMode::WorkingTree, None);
    assert_hunk_math(&diff);
    assert_eq!(diff.files.len(), 1, "only one file changed: {diff:?}");
    assert_eq!(diff.additions, 2);
    assert_eq!(diff.deletions, 2);

    let file = &diff.files[0];
    assert_eq!(file.path, "src/lib.rs");
    assert_eq!(file.change, ChangeKind::Modified);
    assert_eq!(file.old_path, None);
    assert!(!file.binary);
    assert_eq!((file.additions, file.deletions), (2, 2));

    let all: Vec<&openpaw_git::DiffLine> = file
        .hunks
        .iter()
        .flat_map(|hunk| hunk.lines.iter())
        .collect();
    let find = |kind: LineKind, text: &str| {
        all.iter()
            .find(|line| line.kind == kind && line.text == text)
            .unwrap_or_else(|| panic!("no {kind:?} line {text:?} in {all:?}"))
    };

    // An inserted line only exists on the new side.
    let inserted = find(LineKind::Added, "INSERTED");
    assert_eq!(inserted.new_line, Some(3));
    assert_eq!(inserted.old_line, None);

    // A deleted line only exists on the old side.
    let deleted = find(LineKind::Removed, "line 8");
    assert_eq!(deleted.old_line, Some(8));
    assert_eq!(deleted.new_line, None);

    // Context after the insertion is offset by one: the whole point of tracking
    // both sides.
    let shifted = find(LineKind::Context, "line 3");
    assert_eq!((shifted.old_line, shifted.new_line), (Some(3), Some(4)));

    // After the deletion the sides line up again.
    let realigned = find(LineKind::Context, "line 9");
    assert_eq!((realigned.old_line, realigned.new_line), (Some(9), Some(9)));

    // The rewritten line is a delete plus an add, not a magic "changed" line.
    assert_eq!(
        find(LineKind::Removed, "line five (changed)").old_line,
        Some(5)
    );
    assert_eq!(find(LineKind::Added, "EDITED 5").new_line, Some(6));
}

#[test]
fn staged_and_unstaged_diffs_are_separate() {
    if !git_available() {
        return;
    }
    let fx = fixture();
    let mut staged_edit = lib_at_head();
    staged_edit[1] = "line 2 (staged)";
    fx.write("src/lib.rs", &lines_to_string(&staged_edit));
    fx.git(&["add", "src/lib.rs"]);
    fx.write(
        "README.md",
        "# Fixture\n\nline two\nline three\nunstaged tail\n",
    );

    let staged = fx.diff(DiffMode::Staged, None);
    assert_hunk_math(&staged);
    assert_eq!(
        changed(&staged),
        vec![("src/lib.rs".to_owned(), ChangeKind::Modified)]
    );
    assert_eq!((staged.additions, staged.deletions), (1, 1));

    let unstaged = fx.diff(DiffMode::WorkingTree, None);
    assert_hunk_math(&unstaged);
    assert_eq!(
        changed(&unstaged),
        vec![("README.md".to_owned(), ChangeKind::Modified)]
    );
    assert_eq!((unstaged.additions, unstaged.deletions), (1, 0));

    // A path filter narrows the diff and does not invent files.
    let filtered = fx.diff(DiffMode::WorkingTree, Some("src"));
    assert!(filtered.files.is_empty(), "src is clean: {filtered:?}");
    let filtered = fx.diff(DiffMode::WorkingTree, Some("README.md"));
    assert_eq!(filtered.files.len(), 1);
}

#[test]
fn commit_diff_shows_only_that_commit() {
    if !git_available() {
        return;
    }
    let fx = fixture();

    let head = fx.diff(DiffMode::Commit("HEAD".to_owned()), None);
    assert_hunk_math(&head);
    assert_eq!(
        changed(&head),
        vec![
            ("docs/guide.md".to_owned(), ChangeKind::Deleted),
            ("src/lib.rs".to_owned(), ChangeKind::Modified),
            ("src/new.rs".to_owned(), ChangeKind::Added),
        ]
    );

    let deleted = head
        .files
        .iter()
        .find(|file| file.path == "docs/guide.md")
        .expect("deletion");
    assert_eq!(deleted.deletions, 1);
    assert_eq!(deleted.additions, 0);
    let added = head
        .files
        .iter()
        .find(|file| file.path == "src/new.rs")
        .expect("addition");
    assert_eq!(added.additions, 1);
    assert_eq!(added.hunks[0].old_start, 0, "new files start at old line 0");
    assert_eq!(added.hunks[0].old_lines, 0);

    // The root commit has no parent; every file must still be reported as added.
    let root = fx.diff(DiffMode::Commit(fx.first_commit.clone()), None);
    assert_hunk_math(&root);
    assert_eq!(
        changed(&root),
        vec![
            ("README.md".to_owned(), ChangeKind::Added),
            ("docs/guide.md".to_owned(), ChangeKind::Added),
            ("logo.png".to_owned(), ChangeKind::Added),
            ("old/name.txt".to_owned(), ChangeKind::Added),
            ("src/lib.rs".to_owned(), ChangeKind::Added),
        ]
    );
    let binary = root
        .files
        .iter()
        .find(|file| file.path == "logo.png")
        .expect("binary file");
    assert!(binary.binary, "a new binary file is flagged binary");
    assert!(binary.hunks.is_empty());
}

#[test]
fn range_diff_spans_two_commits() {
    if !git_available() {
        return;
    }
    let fx = fixture();
    fx.write(
        "README.md",
        "# Fixture\n\nline two\nline three\nthird commit\n",
    );
    fx.git(&["add", "README.md"]);
    fx.git(&["commit", "-m", "third commit"]);

    // One commit sees one file...
    let single = fx.diff(DiffMode::Commit("HEAD".to_owned()), None);
    assert_eq!(
        changed(&single),
        vec![("README.md".to_owned(), ChangeKind::Modified)]
    );

    // ...the whole range sees everything since the root commit.
    let range = fx.diff(
        DiffMode::Range {
            base: fx.first_commit.clone(),
            head: "HEAD".to_owned(),
        },
        None,
    );
    assert_hunk_math(&range);
    assert_eq!(
        changed(&range),
        vec![
            ("README.md".to_owned(), ChangeKind::Modified),
            ("docs/guide.md".to_owned(), ChangeKind::Deleted),
            ("src/lib.rs".to_owned(), ChangeKind::Modified),
            ("src/new.rs".to_owned(), ChangeKind::Added),
        ]
    );
    assert!(range.additions >= 3 && range.deletions >= 2, "{range:?}");

    // Symbolic endpoints work too.
    let symbolic = fx.diff(
        DiffMode::Range {
            base: "HEAD~1".to_owned(),
            head: "HEAD".to_owned(),
        },
        None,
    );
    assert_eq!(
        changed(&symbolic),
        vec![("README.md".to_owned(), ChangeKind::Modified)]
    );
}

#[test]
fn renames_are_detected_with_and_without_edits() {
    if !git_available() {
        return;
    }
    let fx = fixture();
    fs::create_dir_all(fx.workspace.join("new")).expect("rename target dir");
    fx.git(&["mv", "old/name.txt", "new/name.txt"]);

    let pure = fx.diff(DiffMode::Staged, None);
    assert_eq!(pure.files.len(), 1, "{pure:?}");
    let file = &pure.files[0];
    assert_eq!(file.change, ChangeKind::Renamed);
    assert_eq!(file.path, "new/name.txt");
    assert_eq!(file.old_path.as_deref(), Some("old/name.txt"));
    assert!(file.hunks.is_empty(), "a pure rename has no hunks");
    assert_eq!((file.additions, file.deletions), (0, 0));

    fx.write(
        "new/name.txt",
        "renamed content one\nrenamed content two\nappended after the move\n",
    );
    fx.git(&["add", "new/name.txt"]);
    let edited = fx.diff(DiffMode::Staged, None);
    assert_hunk_math(&edited);
    let file = &edited.files[0];
    assert_eq!(file.change, ChangeKind::Renamed);
    assert_eq!(file.old_path.as_deref(), Some("old/name.txt"));
    assert_eq!(file.additions, 1);
    assert_eq!(file.hunks.len(), 1);
    assert_eq!(
        file.hunks[0]
            .lines
            .iter()
            .filter(|line| line.kind == LineKind::Added)
            .map(|line| line.text.as_str())
            .collect::<Vec<&str>>(),
        vec!["appended after the move"]
    );
}

#[test]
fn binary_changes_and_missing_newlines_are_reported() {
    if !git_available() {
        return;
    }
    let fx = fixture();
    fs::write(
        fx.workspace.join("logo.png"),
        b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0eIHDR\xfe\xff\x01",
    )
    .expect("rewrite binary");
    fs::write(fx.workspace.join("nonl.txt"), "one\ntwo").expect("no trailing newline");
    fx.git(&["add", "-A"]);
    fx.git(&["commit", "-m", "binary and nonl"]);
    fs::write(fx.workspace.join("nonl.txt"), "one\nTWO").expect("edit");

    let staged = fx.diff(DiffMode::Commit("HEAD".to_owned()), None);
    let binary = staged
        .files
        .iter()
        .find(|file| file.path == "logo.png")
        .expect("binary diff");
    assert!(binary.binary);
    assert!(binary.hunks.is_empty());
    assert_eq!((binary.additions, binary.deletions), (0, 0));

    let work = fx.diff(DiffMode::WorkingTree, Some("nonl.txt"));
    assert_hunk_math(&work);
    let file = &work.files[0];
    assert_eq!((file.additions, file.deletions), (1, 1));
    let markers: Vec<&openpaw_git::DiffLine> = file.hunks[0]
        .lines
        .iter()
        .filter(|line| line.kind == LineKind::NoNewline)
        .collect();
    assert_eq!(markers.len(), 2, "both sides lack a trailing newline");
    for marker in markers {
        assert_eq!(marker.old_line, None);
        assert_eq!(marker.new_line, None);
        assert!(marker.text.starts_with("No newline"), "{marker:?}");
    }
}

#[test]
fn tree_lists_entries_at_a_ref() {
    if !git_available() {
        return;
    }
    let fx = fixture();

    let root = fx.repo.tree("HEAD", "").expect("tree");
    let names: Vec<&str> = root.iter().map(|entry| entry.name.as_str()).collect();
    assert_eq!(
        names,
        vec!["old", "src", "README.md", "logo.png"],
        "directories first, then files, each alphabetical"
    );
    let src = root.iter().find(|entry| entry.name == "src").expect("src");
    assert_eq!(src.kind, EntryKind::Directory);
    assert_eq!(src.size, None);
    assert!(!src.is_symlink);

    let inside = fx.repo.tree("HEAD", "src").expect("tree src");
    assert_eq!(
        inside
            .iter()
            .map(|entry| entry.path.as_str())
            .collect::<Vec<&str>>(),
        vec!["src/lib.rs", "src/new.rs"]
    );
    assert_eq!(inside[0].kind, EntryKind::File);
    assert_eq!(
        inside[0].size,
        Some(lines_to_string(&lib_at_head()).len() as u64)
    );

    // The ref selects history: docs/ exists in the first commit only.
    let historic = fx.repo.tree(&fx.first_commit, "docs").expect("tree docs");
    assert_eq!(
        historic
            .iter()
            .map(|entry| entry.path.as_str())
            .collect::<Vec<&str>>(),
        vec!["docs/guide.md"]
    );
    assert!(matches!(
        fx.repo.tree("HEAD", "docs"),
        Err(GitError::NotFound)
    ));
    assert!(matches!(
        fx.repo.tree("HEAD", "README.md"),
        Err(GitError::Path(FileError::NotADirectory))
    ));
    assert!(matches!(
        fx.repo.tree("no-such-ref", ""),
        Err(GitError::NotFound)
    ));

    // An empty ref means HEAD.
    assert_eq!(fx.repo.tree("", "").expect("default ref"), root);
}

#[test]
fn blob_reads_content_at_a_ref() {
    if !git_available() {
        return;
    }
    let fx = fixture();

    let blob = fx.repo.blob("HEAD", "src/lib.rs", MAX_BYTES).expect("blob");
    let expected = lines_to_string(&lib_at_head());
    assert_eq!(blob.path, "src/lib.rs");
    assert_eq!(blob.bytes, expected.len() as u64);
    assert!(!blob.truncated);
    assert_eq!(blob.content, BlobContent::Text(expected.clone()));

    // The ref, not the work tree, decides what we see.
    fs::write(fx.workspace.join("src/lib.rs"), "work tree only\n").expect("dirty");
    let committed = fx.repo.blob("HEAD", "src/lib.rs", MAX_BYTES).expect("blob");
    assert_eq!(committed.content, BlobContent::Text(expected));
    let historic = fx
        .repo
        .blob(&fx.first_commit, "src/lib.rs", MAX_BYTES)
        .expect("blob");
    assert_eq!(
        historic.content,
        BlobContent::Text(lines_to_string(&lib_initial()))
    );

    // Binary blobs are hashed, never shipped.
    let binary = fx.repo.blob("HEAD", "logo.png", MAX_BYTES).expect("blob");
    assert_eq!(binary.bytes, BINARY_BYTES.len() as u64);
    assert_eq!(
        binary.content,
        BlobContent::Binary {
            sha256: BINARY_SHA256.to_owned()
        }
    );
    assert_eq!(binary.mime, "image/png");

    // Oversized text is cut; oversized binary is refused.
    let cut = fx.repo.blob("HEAD", "src/lib.rs", 10).expect("blob");
    assert!(cut.truncated);
    assert_eq!(cut.bytes, lines_to_string(&lib_at_head()).len() as u64);
    assert_eq!(cut.content, BlobContent::Text("line 1\nlin".to_owned()));
    match fx.repo.blob("HEAD", "logo.png", 5) {
        Err(GitError::Path(FileError::TooLarge { bytes, limit })) => {
            assert_eq!(bytes, BINARY_BYTES.len() as u64);
            assert_eq!(limit, 5);
        }
        other => panic!("expected TooLarge, got {other:?}"),
    }

    assert!(matches!(
        fx.repo.blob("HEAD", "src", MAX_BYTES),
        Err(GitError::NotAFile)
    ));
    assert!(matches!(
        fx.repo.blob("HEAD", "", MAX_BYTES),
        Err(GitError::NotAFile)
    ));
    assert!(matches!(
        fx.repo.blob("HEAD", "missing.txt", MAX_BYTES),
        Err(GitError::NotFound)
    ));
    assert!(matches!(
        fx.repo.blob("HEAD", "docs/guide.md", MAX_BYTES),
        Err(GitError::NotFound)
    ));
}

#[test]
fn hostile_paths_and_revisions_never_reach_git() {
    if !git_available() {
        return;
    }
    let fx = fixture();

    for path in [
        "../outside",
        "../outside/secret.txt",
        "/etc/passwd",
        "%2e%2e/outside/secret.txt",
        "src/../../outside",
        "src\0/lib.rs",
        "C:\\windows",
    ] {
        assert!(
            matches!(
                fx.repo.diff(&DiffRequest {
                    mode: DiffMode::WorkingTree,
                    path: Some(path.to_owned()),
                }),
                Err(GitError::Path(FileError::Escape))
            ),
            "diff path {path:?} must be refused"
        );
        assert!(
            matches!(
                fx.repo.tree("HEAD", path),
                Err(GitError::Path(FileError::Escape))
            ),
            "tree path {path:?} must be refused"
        );
        assert!(
            matches!(
                fx.repo.blob("HEAD", path, MAX_BYTES),
                Err(GitError::Path(FileError::Escape))
            ),
            "blob path {path:?} must be refused"
        );
    }

    for rev in [
        "--upload-pack=evil",
        "-f",
        "--output=/tmp/openpaw-pwned",
        "HEAD:../../etc/passwd",
        "main;id",
        "HEAD --all",
    ] {
        assert!(
            matches!(
                fx.repo.diff(&DiffRequest {
                    mode: DiffMode::Commit(rev.to_owned()),
                    path: None,
                }),
                Err(GitError::InvalidRef(_))
            ),
            "commit rev {rev:?} must be refused"
        );
        assert!(
            matches!(
                fx.repo.diff(&DiffRequest {
                    mode: DiffMode::Range {
                        base: rev.to_owned(),
                        head: "HEAD".to_owned(),
                    },
                    path: None,
                }),
                Err(GitError::InvalidRef(_))
            ),
            "range base {rev:?} must be refused"
        );
        assert!(
            matches!(
                fx.repo.diff(&DiffRequest {
                    mode: DiffMode::Range {
                        base: "HEAD".to_owned(),
                        head: rev.to_owned(),
                    },
                    path: None,
                }),
                Err(GitError::InvalidRef(_))
            ),
            "range head {rev:?} must be refused"
        );
        assert!(
            matches!(fx.repo.tree(rev, ""), Err(GitError::InvalidRef(_))),
            "tree rev {rev:?} must be refused"
        );
        assert!(
            matches!(
                fx.repo.blob(rev, "README.md", MAX_BYTES),
                Err(GitError::InvalidRef(_))
            ),
            "blob rev {rev:?} must be refused"
        );
    }

    assert!(
        !Path::new("/tmp/openpaw-pwned").exists(),
        "a rejected revision must not have run"
    );
    // The escape target really is readable through its own root, so the refusals
    // above are about containment rather than a missing file.
    let outside = fx.roots.root("outside").expect("outside root");
    assert!(
        openpaw_files::read_blob(outside, "secret.txt", &ReadOptions::default()).is_ok(),
        "outside root itself is readable: {:?}",
        fx.outside
    );
}

#[test]
fn open_requires_the_top_level_of_a_work_tree() {
    if !git_available() {
        return;
    }
    let fx = fixture();

    // A plain directory is not a repository.
    let roots = Roots::new([fx.outside.clone()]).expect("roots");
    assert!(matches!(
        Repo::open(roots.root("outside").expect("root").clone()),
        Err(GitError::NotARepository)
    ));

    // A subdirectory of a repository is not its top level: accepting it would let
    // git report paths that live outside the allowlisted root.
    let sub = Roots::new([fx.workspace.join("src")]).expect("roots");
    assert!(matches!(
        Repo::open(sub.root("src").expect("root").clone()),
        Err(GitError::NotARepository)
    ));

    assert!(matches!(
        open_named(&fx.roots, "nope"),
        Err(GitError::Path(FileError::UnknownRoot))
    ));
    assert!(open_named(&fx.roots, "workspace").is_ok());

    // The registry skips non-repositories instead of failing.
    let found = summaries(&fx.roots);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].name, "workspace");
    assert_eq!(found[0].branch.as_deref(), Some("main"));
}

#[test]
fn log_returns_commits_newest_first() {
    if !git_available() {
        return;
    }
    let fx = fixture();

    let commits = fx.repo.log(10).expect("log");
    assert_eq!(commits.len(), 2);
    assert_eq!(commits[0].subject, "second commit");
    assert_eq!(commits[1].subject, "initial commit");
    assert_eq!(commits[1].oid, fx.first_commit);
    assert!(fx.first_commit.starts_with(&commits[1].short_oid));
    assert_eq!(commits[0].author_name, "OpenPaw Test");
    assert_eq!(commits[0].author_email, "test@openpaw.invalid");
    assert!(
        commits[0].authored_at >= commits[1].authored_at,
        "newest first"
    );

    assert_eq!(fx.repo.log(1).expect("log").len(), 1);
    assert!(fx.repo.log(0).expect("log").is_empty());
}

#[test]
fn a_repository_without_commits_still_answers() {
    if !git_available() {
        return;
    }
    let dir = TempDir::new().expect("tempdir");
    let home = fs::canonicalize(dir.path()).expect("canonicalize");
    let workspace = home.join("fresh");
    fs::create_dir_all(&workspace).expect("workspace");
    run_git(&home, &home, &["init", "-b", "main", "fresh"]);

    let roots = Roots::new([workspace]).expect("roots");
    let repo = Repo::open(roots.root("fresh").expect("root").clone()).expect("open");

    let status = repo.status().expect("status");
    assert_eq!(
        status.branch, "main",
        "branch is known before the first commit"
    );
    assert!(!status.detached);
    assert!(!status.is_dirty());
    assert!(repo.log(5).expect("log").is_empty());
    assert!(matches!(repo.tree("HEAD", ""), Err(GitError::NotFound)));

    let summary = repo.summary().expect("summary");
    assert_eq!(summary.branch.as_deref(), Some("main"));
    assert!(!summary.dirty);
}

#[test]
fn json_shapes_match_the_repo_routes() {
    if !git_available() {
        return;
    }
    let fx = fixture();
    fx.write("scratch.txt", "untracked\n");

    let summary = serde_json::to_value(fx.repo.summary().expect("summary")).expect("json");
    assert_eq!(summary["name"], "workspace");
    assert_eq!(summary["branch"], "main");
    assert_eq!(summary["dirty"], true);
    assert_eq!(summary["ahead"], 0);
    assert_eq!(summary["behind"], 0);

    let status = serde_json::to_value(fx.repo.status().expect("status")).expect("json");
    assert_eq!(status["branch"], "main");
    assert_eq!(status["untracked"][0]["path"], "scratch.txt");
    assert_eq!(status["untracked"][0]["change"], "added");
    assert!(status["staged"].as_array().expect("array").is_empty());

    let diff =
        serde_json::to_value(fx.diff(DiffMode::Commit("HEAD".to_owned()), None)).expect("json");
    let files = diff["files"].as_array().expect("files");
    let added = files
        .iter()
        .find(|file| file["path"] == "src/new.rs")
        .expect("added file");
    assert_eq!(added["change"], "added");
    assert_eq!(added["binary"], false);
    assert!(
        added.get("old_path").is_none(),
        "absent old_path is omitted"
    );
    let line = &added["hunks"][0]["lines"][0];
    assert_eq!(line["kind"], "added");
    assert_eq!(line["text"], "// added in the second commit");
    assert_eq!(line["new_line"], 1);
    assert!(line.get("old_line").is_none());

    let tree = serde_json::to_value(fx.repo.tree("HEAD", "src").expect("tree")).expect("json");
    assert_eq!(tree[0]["kind"], "file");
    assert_eq!(tree[0]["name"], "lib.rs");
    assert_eq!(tree[0]["is_symlink"], false);

    let blob = serde_json::to_value(fx.repo.blob("HEAD", "logo.png", MAX_BYTES).expect("blob"))
        .expect("json");
    assert_eq!(blob["content"]["encoding"], "binary");
    assert_eq!(blob["content"]["value"]["sha256"], BINARY_SHA256);
}
