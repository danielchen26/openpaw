//! Behavioural tests for the filesystem boundary: traversal refusal, symlink
//! containment, binary detection, byte budgets, hidden filtering and search.

use std::fs;
use std::path::{Path, PathBuf};

use openpaw_files::{
    Blob, BlobContent, EntryKind, FileError, ListOptions, ReadOptions, ResolvedRoot, Roots,
    list_dir, read_blob, search_content, search_names,
};
use tempfile::TempDir;

/// Bytes with a NUL and an invalid UTF-8 tail; sha256 verified out of band with
/// `shasum -a 256`.
const BINARY_BYTES: &[u8] = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xff\xfe";
const BINARY_SHA256: &str = "044dbe64b84ec81c26e4b498bed689fadef7c13d77b7394fd658e17783cd184a";

struct Fixture {
    _dir: TempDir,
    roots: Roots,
    root: ResolvedRoot,
    outside: PathBuf,
}

/// Layout:
/// ```text
/// <tmp>/outside/secret.txt          (never reachable)
/// <tmp>/workspace/README.md
/// <tmp>/workspace/.env
/// <tmp>/workspace/logo.png          (binary)
/// <tmp>/workspace/big.txt           (5000 ASCII bytes)
/// <tmp>/workspace/src/main.rs
/// <tmp>/workspace/src/util.rs
/// <tmp>/workspace/node_modules/pkg/index.js
/// <tmp>/workspace/inside-link -> src/main.rs
/// <tmp>/workspace/escape-link  -> <tmp>/outside/secret.txt
/// ```
fn fixture() -> Fixture {
    let dir = TempDir::new().expect("tempdir");
    let base = fs::canonicalize(dir.path()).expect("canonicalize tempdir");
    let outside = base.join("outside");
    let workspace = base.join("workspace");

    fs::create_dir_all(outside.join("nested")).expect("outside dir");
    fs::write(outside.join("secret.txt"), "top secret\n").expect("secret");

    fs::create_dir_all(workspace.join("src")).expect("src dir");
    fs::create_dir_all(workspace.join("node_modules/pkg")).expect("node_modules");
    fs::write(workspace.join("README.md"), "# Fixture\nneedle in prose\n").expect("readme");
    fs::write(workspace.join(".env"), "TOKEN=needle\n").expect("dotenv");
    fs::write(workspace.join("logo.png"), BINARY_BYTES).expect("binary");
    fs::write(workspace.join("big.txt"), "x".repeat(5000)).expect("big");
    fs::write(
        workspace.join("src/main.rs"),
        "fn main() {\n    println!(\"NEEDLE\");\n}\n",
    )
    .expect("main.rs");
    fs::write(workspace.join("src/util.rs"), "pub fn helper() {}\n").expect("util.rs");
    fs::write(
        workspace.join("node_modules/pkg/index.js"),
        "// needle should be pruned\n",
    )
    .expect("index.js");

    symlink(Path::new("src/main.rs"), &workspace.join("inside-link"));
    symlink(&outside.join("secret.txt"), &workspace.join("escape-link"));

    let roots = Roots::new([workspace]).expect("roots");
    let root = roots.root("workspace").expect("workspace root").clone();
    Fixture {
        _dir: dir,
        roots,
        root,
        outside,
    }
}

fn symlink(target: &Path, link: &Path) {
    std::os::unix::fs::symlink(target, link).expect("symlink");
}

fn text_of(blob: &Blob) -> &str {
    match &blob.content {
        BlobContent::Text(text) => text.as_str(),
        BlobContent::Binary { sha256 } => panic!("expected text, got binary {sha256}"),
    }
}

#[test]
fn traversal_attempts_are_refused() {
    let fx = fixture();
    let attempts = [
        "../etc/passwd",
        "foo/../../bar",
        "/etc/passwd",
        "%2e%2e/etc/passwd",
        "src/%2E%2E/%2E%2E/outside/secret.txt",
        "src\0/main.rs",
        "..",
        "src/../../workspace/README.md",
        "\\\\server\\share",
        "C:\\Windows\\system32",
        "..\\..\\etc\\passwd",
    ];
    for attempt in attempts {
        let err = fx
            .roots
            .resolve("workspace", attempt)
            .expect_err(&format!("{attempt:?} must be refused"));
        assert!(
            matches!(err, FileError::Escape),
            "{attempt:?} produced {err:?}, expected Escape"
        );
        let err = read_blob(&fx.root, attempt, &ReadOptions::default())
            .expect_err(&format!("read_blob({attempt:?}) must be refused"));
        assert!(matches!(err, FileError::Escape), "read_blob got {err:?}");
    }
}

#[test]
fn legitimate_paths_resolve_inside_the_root() {
    let fx = fixture();
    // `.` and duplicate separators are normalized away; `..` never is, even when
    // it would stay inside the root.
    let resolved = fx
        .roots
        .resolve("workspace", "./src//main.rs")
        .expect("resolves");
    assert_eq!(resolved, fx.root.path.join("src/main.rs"));
    assert!(resolved.starts_with(&fx.root.path));
    assert!(
        matches!(
            fx.roots.resolve("workspace", "src/../src/main.rs"),
            Err(FileError::Escape)
        ),
        "`..` is refused even when it resolves back inside the root"
    );
}

#[test]
fn unknown_root_is_distinct_from_escape() {
    let fx = fixture();
    let err = fx
        .roots
        .resolve("nope", "README.md")
        .expect_err("unknown root");
    assert!(matches!(err, FileError::UnknownRoot), "got {err:?}");
}

#[test]
fn missing_path_reports_not_found() {
    let fx = fixture();
    let err = fx
        .roots
        .resolve("workspace", "src/absent.rs")
        .expect_err("missing");
    assert!(matches!(err, FileError::NotFound), "got {err:?}");
}

#[test]
fn escaping_symlink_is_listed_but_never_read_through() {
    let fx = fixture();
    let entries = list_dir(&fx.root, "", &ListOptions::default()).expect("list");

    let escape = entries
        .iter()
        .find(|entry| entry.name == "escape-link")
        .expect("escaping symlink is listed");
    assert!(escape.is_symlink);
    assert_eq!(escape.kind, EntryKind::Symlink);
    assert_eq!(escape.size, None);

    let inside = entries
        .iter()
        .find(|entry| entry.name == "inside-link")
        .expect("inside symlink is listed");
    assert!(inside.is_symlink);
    assert_eq!(inside.kind, EntryKind::File, "in-root link keeps its kind");

    let err = read_blob(&fx.root, "escape-link", &ReadOptions::default())
        .expect_err("escaping symlink must not be readable");
    assert!(matches!(err, FileError::Escape), "got {err:?}");

    // The link target itself is readable through its own root, proving the
    // refusal above is about containment and not about the file being unreadable.
    let other = Roots::new([fx.outside.clone()]).expect("outside root");
    let blob = read_blob(
        other.root("outside").expect("root"),
        "secret.txt",
        &ReadOptions::default(),
    )
    .expect("readable in its own root");
    assert_eq!(text_of(&blob), "top secret\n");

    // A symlink inside the root is followed normally.
    let blob = read_blob(&fx.root, "inside-link", &ReadOptions::default()).expect("inside link");
    assert!(text_of(&blob).contains("fn main()"));
}

#[test]
fn binary_content_is_hashed_not_returned() {
    let fx = fixture();
    let blob = read_blob(&fx.root, "logo.png", &ReadOptions::default()).expect("binary blob");
    assert_eq!(blob.bytes, BINARY_BYTES.len() as u64);
    assert!(!blob.truncated);
    assert_eq!(blob.mime, "image/png");
    match &blob.content {
        BlobContent::Binary { sha256 } => assert_eq!(sha256, BINARY_SHA256),
        BlobContent::Text(text) => panic!("binary file decoded as text: {text:?}"),
    }
}

#[test]
fn invalid_utf8_without_nul_is_still_binary() {
    let fx = fixture();
    fs::write(fx.root.path.join("latin.txt"), b"caf\xe9 latin1\n").expect("write latin1");
    let blob = read_blob(&fx.root, "latin.txt", &ReadOptions::default()).expect("blob");
    assert!(
        matches!(blob.content, BlobContent::Binary { .. }),
        "got {:?}",
        blob.content
    );
}

#[test]
fn multibyte_text_survives_the_probe_boundary() {
    let fx = fixture();
    // 4 KiB of ASCII then a multi-byte char straddling nothing: still text.
    let mut content = "a".repeat(4096);
    content.push_str("héllo ünïcode\n");
    fs::write(fx.root.path.join("utf8.txt"), &content).expect("write utf8");
    let blob = read_blob(&fx.root, "utf8.txt", &ReadOptions::default()).expect("blob");
    assert_eq!(text_of(&blob), content);
    assert!(!blob.truncated);
}

#[test]
fn text_over_the_budget_is_cut_and_flagged() {
    let fx = fixture();
    let blob = read_blob(&fx.root, "big.txt", &ReadOptions { max_bytes: 1000 }).expect("blob");
    assert_eq!(blob.bytes, 5000, "real size is reported");
    assert!(blob.truncated);
    assert_eq!(text_of(&blob).len(), 1000);

    let whole = read_blob(&fx.root, "big.txt", &ReadOptions { max_bytes: 5000 }).expect("blob");
    assert!(!whole.truncated);
    assert_eq!(text_of(&whole).len(), 5000);
}

#[test]
fn text_cut_never_splits_a_character() {
    let fx = fixture();
    let content = "é".repeat(100); // 200 bytes, 2 bytes per char
    fs::write(fx.root.path.join("accents.txt"), &content).expect("write");
    let blob = read_blob(&fx.root, "accents.txt", &ReadOptions { max_bytes: 51 }).expect("blob");
    assert!(blob.truncated);
    let text = text_of(&blob);
    assert_eq!(text.chars().count(), 25, "cut back to a char boundary");
    assert_eq!(text.len(), 50);
}

#[test]
fn oversized_binary_is_refused_rather_than_hashed() {
    let fx = fixture();
    let mut payload = vec![0u8; 4096];
    payload[10] = 0x41;
    fs::write(fx.root.path.join("blob.bin"), &payload).expect("write");
    let err = read_blob(&fx.root, "blob.bin", &ReadOptions { max_bytes: 1024 })
        .expect_err("oversized binary");
    match err {
        FileError::TooLarge { bytes, limit } => {
            assert_eq!(bytes, 4096);
            assert_eq!(limit, 1024);
        }
        other => panic!("expected TooLarge, got {other:?}"),
    }
}

#[test]
fn directories_are_not_blobs_and_files_are_not_directories() {
    let fx = fixture();
    let err = read_blob(&fx.root, "src", &ReadOptions::default()).expect_err("dir as blob");
    assert!(matches!(err, FileError::NotAFile), "got {err:?}");
    let err = list_dir(&fx.root, "README.md", &ListOptions::default()).expect_err("file as dir");
    assert!(matches!(err, FileError::NotADirectory), "got {err:?}");
}

#[test]
fn hidden_entries_are_filtered_unless_requested() {
    let fx = fixture();
    let visible = list_dir(&fx.root, "", &ListOptions::default()).expect("list");
    assert!(
        !visible.iter().any(|entry| entry.name == ".env"),
        "dotfile leaked: {visible:?}"
    );

    let all = list_dir(
        &fx.root,
        "",
        &ListOptions {
            max_entries: 100,
            include_hidden: true,
        },
    )
    .expect("list hidden");
    assert!(all.iter().any(|entry| entry.name == ".env"));
}

#[test]
fn listing_is_directories_first_then_capped_deterministically() {
    let fx = fixture();
    let entries = list_dir(
        &fx.root,
        "",
        &ListOptions {
            max_entries: 3,
            include_hidden: false,
        },
    )
    .expect("list");
    assert_eq!(entries.len(), 3);
    let names: Vec<&str> = entries.iter().map(|entry| entry.name.as_str()).collect();
    assert_eq!(names, vec!["node_modules", "src", "README.md"]);
    assert_eq!(entries[1].path, "src");
    assert_eq!(entries[1].kind, EntryKind::Directory);
    assert_eq!(entries[1].size, None);
}

#[test]
fn nested_listing_paths_are_root_relative() {
    let fx = fixture();
    let entries = list_dir(&fx.root, "src", &ListOptions::default()).expect("list src");
    let paths: Vec<&str> = entries.iter().map(|entry| entry.path.as_str()).collect();
    assert_eq!(paths, vec!["src/main.rs", "src/util.rs"]);
    assert_eq!(
        entries[0].size,
        Some(
            fs::metadata(fx.root.path.join("src/main.rs"))
                .expect("stat")
                .len()
        )
    );
}

#[test]
fn name_search_matches_case_insensitively_and_caps() {
    let fx = fixture();
    let hits = search_names(&fx.root, "MAIN", 10).expect("search");
    let paths: Vec<&str> = hits.iter().map(|hit| hit.path.as_str()).collect();
    assert_eq!(paths, vec!["src/main.rs"]);

    let links = search_names(&fx.root, "LINK", 10).expect("search");
    let paths: Vec<&str> = links.iter().map(|hit| hit.path.as_str()).collect();
    assert_eq!(paths, vec!["escape-link", "inside-link"]);
    assert!(links.iter().all(|hit| hit.is_symlink));

    let capped = search_names(&fx.root, ".rs", 1).expect("search");
    assert_eq!(capped.len(), 1);
    assert_eq!(capped[0].path, "src/main.rs");

    assert!(
        search_names(&fx.root, "", 10)
            .expect("empty query")
            .is_empty()
    );
    assert!(
        search_names(&fx.root, "main", 0)
            .expect("zero limit")
            .is_empty()
    );
}

#[test]
fn content_search_finds_literal_matches_and_prunes_noise() {
    let fx = fixture();
    let hits = search_content(&fx.root, "needle", 10).expect("search");
    let found: Vec<(&str, u32)> = hits
        .iter()
        .map(|hit| (hit.path.as_str(), hit.line))
        .collect();
    assert!(
        found.contains(&("README.md", 2)),
        "prose hit missing: {found:?}"
    );
    assert!(
        found.contains(&("src/main.rs", 2)),
        "case-insensitive hit missing: {found:?}"
    );
    assert!(
        !found
            .iter()
            .any(|(path, _)| path.starts_with("node_modules")),
        "node_modules was walked: {found:?}"
    );
    assert!(
        !found.iter().any(|(path, _)| *path == "logo.png"),
        "binary file was searched: {found:?}"
    );

    let line = hits
        .iter()
        .find(|hit| hit.path == "src/main.rs")
        .expect("hit");
    assert_eq!(line.text, "    println!(\"NEEDLE\");");
}

#[test]
fn content_search_is_literal_not_regex() {
    let fx = fixture();
    fs::write(fx.root.path.join("pattern.txt"), "a.c\nabc\n").expect("write");
    let hits = search_content(&fx.root, "a.c", 10).expect("search");
    let lines: Vec<&str> = hits.iter().map(|hit| hit.text.as_str()).collect();
    assert_eq!(lines, vec!["a.c"], "`.` must not match any character");
}

#[test]
fn content_search_respects_the_limit() {
    let fx = fixture();
    fs::write(fx.root.path.join("repeat.txt"), "hit\nhit\nhit\nhit\nhit\n").expect("write");
    let hits = search_content(&fx.root, "hit", 2).expect("search");
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[0].line, 1);
    assert_eq!(hits[1].line, 2);
}

#[test]
fn content_search_skips_files_over_the_per_file_cap() {
    let fx = fixture();
    let mut big = "filler\n".repeat(150_000); // > 1 MiB
    big.push_str("bigneedle\n");
    fs::write(fx.root.path.join("huge.txt"), &big).expect("write");
    assert!(big.len() as u64 > openpaw_files::MAX_SEARCH_FILE_BYTES);
    let hits = search_content(&fx.root, "bigneedle", 10).expect("search");
    assert!(hits.is_empty(), "oversized file was read: {hits:?}");
}

#[test]
fn roots_canonicalize_reject_files_and_deduplicate_names() {
    let dir = TempDir::new().expect("tempdir");
    let base = fs::canonicalize(dir.path()).expect("canonicalize");
    fs::create_dir_all(base.join("a/project")).expect("a");
    fs::create_dir_all(base.join("b/project")).expect("b");
    fs::create_dir_all(base.join("c/project")).expect("c");
    fs::write(base.join("plain.txt"), "x").expect("file");

    let roots = Roots::new([
        base.join("a/project"),
        base.join("b/project"),
        base.join("c/./project"),
        base.join("a/project"),
    ])
    .expect("roots");
    assert_eq!(roots.names(), vec!["project", "project-2", "project-3"]);
    assert_eq!(
        roots.root("project-2").expect("root").path,
        base.join("b/project")
    );
    assert_eq!(roots.all().len(), 3, "duplicate path is collapsed");

    let err = Roots::new([base.join("plain.txt")]).expect_err("file root");
    assert!(matches!(err, FileError::NotADirectory), "got {err:?}");
    let err = Roots::new([base.join("absent")]).expect_err("missing root");
    assert!(matches!(err, FileError::NotFound), "got {err:?}");
}

#[test]
fn blob_json_shape_is_stable() {
    let fx = fixture();
    let text = read_blob(&fx.root, "src/util.rs", &ReadOptions::default()).expect("blob");
    let json = serde_json::to_value(&text).expect("json");
    assert_eq!(json["path"], "src/util.rs");
    assert_eq!(json["bytes"], 19);
    assert_eq!(json["truncated"], false);
    assert_eq!(json["content"]["encoding"], "text");
    assert_eq!(json["content"]["value"], "pub fn helper() {}\n");

    let binary = read_blob(&fx.root, "logo.png", &ReadOptions::default()).expect("blob");
    let json = serde_json::to_value(&binary).expect("json");
    assert_eq!(json["content"]["encoding"], "binary");
    assert_eq!(json["content"]["value"]["sha256"], BINARY_SHA256);

    let entries = list_dir(&fx.root, "src", &ListOptions::default()).expect("list");
    let json = serde_json::to_value(&entries[0]).expect("json");
    assert_eq!(json["kind"], "file");
    assert_eq!(json["is_symlink"], false);
    assert_eq!(json["name"], "main.rs");
}
