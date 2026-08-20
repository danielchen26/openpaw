//! Unified diff parser.
//!
//! `git diff --patch` output is turned into structured hunks with real old/new
//! line numbers. The parser is deliberately tolerant of preamble (`git show`
//! emits a blank line before the first `diff --git`) and of trailing content, but
//! it never guesses line numbers: they come from the `@@` ranges.

/// How a file changed between the two sides of a diff.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChangeKind {
    /// The file did not exist on the old side.
    Added,
    /// Content and/or permission bits changed.
    Modified,
    /// The file does not exist on the new side.
    Deleted,
    /// The file moved, possibly with edits.
    Renamed,
    /// The file was duplicated from another path.
    Copied,
    /// Regular file became a symlink or similar.
    TypeChanged,
}

/// Role of a single line inside a hunk.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LineKind {
    /// Unchanged line, present on both sides.
    Context,
    /// Line only on the new side.
    Added,
    /// Line only on the old side.
    Removed,
    /// The `\ No newline at end of file` marker.
    NoNewline,
}

/// One line of a hunk with its position on each side.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct DiffLine {
    /// Role of the line.
    pub kind: LineKind,
    /// 1-based line number on the old side, when the line exists there.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub old_line: Option<u32>,
    /// 1-based line number on the new side, when the line exists there.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub new_line: Option<u32>,
    /// Line content without the leading marker and without the newline.
    pub text: String,
}

/// One `@@` block.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Hunk {
    /// The verbatim `@@ ... @@` line, including any section heading.
    pub header: String,
    /// First line number covered on the old side.
    pub old_start: u32,
    /// Number of old-side lines covered.
    pub old_lines: u32,
    /// First line number covered on the new side.
    pub new_start: u32,
    /// Number of new-side lines covered.
    pub new_lines: u32,
    /// Lines in file order.
    pub lines: Vec<DiffLine>,
}

/// Everything the diff says about one path.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct FileDiff {
    /// Path on the new side (or the old side for deletions).
    pub path: String,
    /// Previous path for renames and copies.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub old_path: Option<String>,
    /// What happened to the file.
    pub change: ChangeKind,
    /// Added line count.
    pub additions: u32,
    /// Removed line count.
    pub deletions: u32,
    /// True when git refused to produce a textual patch.
    pub binary: bool,
    /// Hunks, empty for binary files and pure renames.
    pub hunks: Vec<Hunk>,
}

/// A parsed patch.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Diff {
    /// Per-file diffs in git's output order.
    pub files: Vec<FileDiff>,
    /// Total added lines.
    pub additions: u32,
    /// Total removed lines.
    pub deletions: u32,
}

impl Diff {
    /// Parse a complete `git diff --patch` / `git show --patch` payload.
    pub fn parse(patch: &str) -> Diff {
        let files = parse_files(patch);
        let additions = files.iter().map(|file| file.additions).sum();
        let deletions = files.iter().map(|file| file.deletions).sum();
        Diff {
            files,
            additions,
            deletions,
        }
    }
}

fn parse_files(patch: &str) -> Vec<FileDiff> {
    let lines: Vec<&str> = patch.split('\n').collect();
    let mut files: Vec<FileDiff> = Vec::new();
    let mut at = 0usize;
    while at < lines.len() {
        if lines[at].starts_with("diff --git ") {
            let (file, next) = parse_file(&lines, at);
            files.push(file);
            at = next;
        } else {
            at += 1;
        }
    }
    files
}

/// Header fields collected before the first hunk.
#[derive(Default)]
struct Header {
    minus: Option<String>,
    plus: Option<String>,
    rename_from: Option<String>,
    rename_to: Option<String>,
    copy_from: Option<String>,
    copy_to: Option<String>,
    old_mode: Option<String>,
    new_mode: Option<String>,
    saw_new_file: bool,
    saw_deleted_file: bool,
    binary: bool,
}

fn parse_file(lines: &[&str], start: usize) -> (FileDiff, usize) {
    let fallback = split_diff_git_header(&lines[start]["diff --git ".len()..]);
    let mut header = Header::default();
    let mut at = start + 1;

    while at < lines.len() {
        let line = strip_cr(lines[at]);
        if line.starts_with("diff --git ") || line.starts_with("@@") {
            break;
        }
        if let Some(rest) = line.strip_prefix("--- ") {
            header.minus = side_path(rest);
        } else if let Some(rest) = line.strip_prefix("+++ ") {
            header.plus = side_path(rest);
        } else if let Some(rest) = line.strip_prefix("rename from ") {
            header.rename_from = Some(unquote(rest));
        } else if let Some(rest) = line.strip_prefix("rename to ") {
            header.rename_to = Some(unquote(rest));
        } else if let Some(rest) = line.strip_prefix("copy from ") {
            header.copy_from = Some(unquote(rest));
        } else if let Some(rest) = line.strip_prefix("copy to ") {
            header.copy_to = Some(unquote(rest));
        } else if let Some(rest) = line.strip_prefix("new file mode ") {
            header.saw_new_file = true;
            header.new_mode = Some(rest.trim().to_owned());
        } else if let Some(rest) = line.strip_prefix("deleted file mode ") {
            header.saw_deleted_file = true;
            header.old_mode = Some(rest.trim().to_owned());
        } else if let Some(rest) = line.strip_prefix("old mode ") {
            header.old_mode = Some(rest.trim().to_owned());
        } else if let Some(rest) = line.strip_prefix("new mode ") {
            header.new_mode = Some(rest.trim().to_owned());
        } else if line.starts_with("Binary files ") || line.starts_with("GIT binary patch") {
            header.binary = true;
        }
        at += 1;
    }

    let (change, path, old_path) = resolve_identity(&header, &fallback);

    let mut hunks: Vec<Hunk> = Vec::new();
    while at < lines.len() && lines[at].starts_with("@@") {
        match parse_hunk(lines, at) {
            Some((hunk, next)) => {
                hunks.push(hunk);
                at = next;
            }
            // Unparseable range: skip the marker so we cannot loop forever.
            None => at += 1,
        }
    }

    let mut additions = 0u32;
    let mut deletions = 0u32;
    for line in hunks.iter().flat_map(|hunk| hunk.lines.iter()) {
        match line.kind {
            LineKind::Added => additions += 1,
            LineKind::Removed => deletions += 1,
            LineKind::Context | LineKind::NoNewline => {}
        }
    }

    (
        FileDiff {
            path,
            old_path,
            change,
            additions,
            deletions,
            binary: header.binary,
            hunks,
        },
        at,
    )
}

/// Decide path, previous path and change kind from the collected header lines.
fn resolve_identity(
    header: &Header,
    fallback: &(Option<String>, Option<String>),
) -> (ChangeKind, String, Option<String>) {
    let (old_fallback, new_fallback) = fallback;
    if let (Some(from), Some(to)) = (&header.rename_from, &header.rename_to) {
        return (ChangeKind::Renamed, to.clone(), Some(from.clone()));
    }
    if let (Some(from), Some(to)) = (&header.copy_from, &header.copy_to) {
        return (ChangeKind::Copied, to.clone(), Some(from.clone()));
    }

    let new_side = header
        .plus
        .clone()
        .or_else(|| new_fallback.clone())
        .or_else(|| header.minus.clone())
        .or_else(|| old_fallback.clone())
        .unwrap_or_default();
    let old_side = header
        .minus
        .clone()
        .or_else(|| old_fallback.clone())
        .or_else(|| header.plus.clone())
        .or_else(|| new_fallback.clone())
        .unwrap_or_default();

    if header.saw_new_file && header.saw_deleted_file {
        return (ChangeKind::TypeChanged, new_side, None);
    }
    if header.saw_new_file || header.minus.is_none() && header.plus.is_some() {
        return (ChangeKind::Added, new_side, None);
    }
    if header.saw_deleted_file || header.plus.is_none() && header.minus.is_some() {
        return (ChangeKind::Deleted, old_side, None);
    }
    if mode_type_changed(header.old_mode.as_deref(), header.new_mode.as_deref()) {
        return (ChangeKind::TypeChanged, new_side, None);
    }
    (ChangeKind::Modified, new_side, None)
}

/// `100644` -> `100755` is a permission change; `100644` -> `120000` is a type
/// change. Only the leading object-type digits matter.
fn mode_type_changed(old: Option<&str>, new: Option<&str>) -> bool {
    match (old, new) {
        (Some(old), Some(new)) if old.len() >= 3 && new.len() >= 3 => old[..3] != new[..3],
        _ => false,
    }
}

fn parse_hunk(lines: &[&str], start: usize) -> Option<(Hunk, usize)> {
    let header = strip_cr(lines[start]);
    let (old_start, old_lines, new_start, new_lines) = parse_hunk_ranges(header)?;

    let mut old_no = old_start;
    let mut new_no = new_start;
    let mut old_left = old_lines;
    let mut new_left = new_lines;
    let mut body: Vec<DiffLine> = Vec::new();
    let mut at = start + 1;

    while at < lines.len() {
        let line = lines[at];
        let marker = line.as_bytes().first().copied();
        if old_left == 0 && new_left == 0 && marker != Some(b'\\') {
            break;
        }
        if line.starts_with("diff --git ") || line.starts_with("@@") {
            break;
        }
        match marker {
            Some(b' ') => {
                body.push(DiffLine {
                    kind: LineKind::Context,
                    old_line: Some(old_no),
                    new_line: Some(new_no),
                    text: line[1..].to_owned(),
                });
                old_no += 1;
                new_no += 1;
                old_left = old_left.saturating_sub(1);
                new_left = new_left.saturating_sub(1);
            }
            Some(b'+') => {
                body.push(DiffLine {
                    kind: LineKind::Added,
                    old_line: None,
                    new_line: Some(new_no),
                    text: line[1..].to_owned(),
                });
                new_no += 1;
                new_left = new_left.saturating_sub(1);
            }
            Some(b'-') => {
                body.push(DiffLine {
                    kind: LineKind::Removed,
                    old_line: Some(old_no),
                    new_line: None,
                    text: line[1..].to_owned(),
                });
                old_no += 1;
                old_left = old_left.saturating_sub(1);
            }
            Some(b'\\') => body.push(DiffLine {
                kind: LineKind::NoNewline,
                old_line: None,
                new_line: None,
                text: line[1..].trim_start().to_owned(),
            }),
            // A truly empty line inside a hunk is an empty context line; some
            // producers strip the single leading space.
            None => {
                body.push(DiffLine {
                    kind: LineKind::Context,
                    old_line: Some(old_no),
                    new_line: Some(new_no),
                    text: String::new(),
                });
                old_no += 1;
                new_no += 1;
                old_left = old_left.saturating_sub(1);
                new_left = new_left.saturating_sub(1);
            }
            Some(_) => break,
        }
        at += 1;
    }

    Some((
        Hunk {
            header: header.to_owned(),
            old_start,
            old_lines,
            new_start,
            new_lines,
            lines: body,
        },
        at,
    ))
}

/// `@@ -12,7 +12,9 @@ fn main()` -> `(12, 7, 12, 9)`.
fn parse_hunk_ranges(header: &str) -> Option<(u32, u32, u32, u32)> {
    let rest = header.strip_prefix("@@ ")?;
    let end = rest.find(" @@")?;
    let mut ranges = rest[..end].split(' ');
    let (old_start, old_lines) = parse_range(ranges.next()?.strip_prefix('-')?)?;
    let (new_start, new_lines) = parse_range(ranges.next()?.strip_prefix('+')?)?;
    Some((old_start, old_lines, new_start, new_lines))
}

fn parse_range(raw: &str) -> Option<(u32, u32)> {
    match raw.split_once(',') {
        Some((start, count)) => Some((start.parse().ok()?, count.parse().ok()?)),
        None => Some((raw.parse().ok()?, 1)),
    }
}

/// `--- a/src/main.rs` -> `Some("src/main.rs")`; `/dev/null` -> `None`.
fn side_path(raw: &str) -> Option<String> {
    let raw = strip_cr(raw);
    if raw == "/dev/null" {
        return None;
    }
    let unquoted = unquote(raw);
    if unquoted == "/dev/null" {
        return None;
    }
    Some(strip_side_prefix(&unquoted))
}

fn strip_side_prefix(path: &str) -> String {
    for prefix in ["a/", "b/", "c/", "i/", "w/", "o/"] {
        if let Some(rest) = path.strip_prefix(prefix) {
            return rest.to_owned();
        }
    }
    path.to_owned()
}

/// Last-resort path recovery from `diff --git a/X b/X`, used only for diffs that
/// carry neither `---`/`+++` nor rename lines (pure mode changes).
fn split_diff_git_header(rest: &str) -> (Option<String>, Option<String>) {
    let rest = strip_cr(rest);
    if let Some(stripped) = rest.strip_prefix('"') {
        // Quoted form: "a/one" "b/two"
        if let Some(close) = find_closing_quote(stripped) {
            let old = unquote(&format!("\"{}\"", &stripped[..close]));
            let tail = stripped[close + 1..].trim_start();
            let new = unquote(tail);
            return (Some(strip_side_prefix(&old)), Some(strip_side_prefix(&new)));
        }
    }
    match rest.rfind(" b/") {
        Some(at) => (
            Some(strip_side_prefix(&rest[..at])),
            Some(rest[at + 3..].to_owned()),
        ),
        None => (None, None),
    }
}

fn find_closing_quote(raw: &str) -> Option<usize> {
    let bytes = raw.as_bytes();
    let mut at = 0usize;
    while at < bytes.len() {
        match bytes[at] {
            b'\\' => at += 2,
            b'"' => return Some(at),
            _ => at += 1,
        }
    }
    None
}

/// Undo git's C-style quoting. Plain paths pass through untouched.
fn unquote(raw: &str) -> String {
    let trimmed = raw.trim_end_matches('\r');
    let Some(inner) = trimmed
        .strip_prefix('"')
        .and_then(|rest| rest.strip_suffix('"'))
    else {
        return trimmed.to_owned();
    };
    let mut out = Vec::with_capacity(inner.len());
    let bytes = inner.as_bytes();
    let mut at = 0usize;
    while at < bytes.len() {
        if bytes[at] != b'\\' {
            out.push(bytes[at]);
            at += 1;
            continue;
        }
        at += 1;
        let Some(&escape) = bytes.get(at) else { break };
        match escape {
            b'n' => out.push(b'\n'),
            b't' => out.push(b'\t'),
            b'r' => out.push(b'\r'),
            b'a' => out.push(0x07),
            b'b' => out.push(0x08),
            b'f' => out.push(0x0c),
            b'v' => out.push(0x0b),
            b'0'..=b'7' => {
                let mut value = 0u32;
                let mut digits = 0;
                while digits < 3 {
                    match bytes.get(at) {
                        Some(digit @ b'0'..=b'7') => {
                            value = value * 8 + u32::from(digit - b'0');
                            at += 1;
                            digits += 1;
                        }
                        _ => break,
                    }
                }
                out.push(u8::try_from(value).unwrap_or(b'?'));
                continue;
            }
            other => out.push(other),
        }
        at += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn strip_cr(line: &str) -> &str {
    line.strip_suffix('\r').unwrap_or(line)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hunk_ranges_default_to_one_line() {
        assert_eq!(
            parse_hunk_ranges("@@ -1 +1,2 @@ heading"),
            Some((1, 1, 1, 2))
        );
        assert_eq!(parse_hunk_ranges("@@ -0,0 +1,3 @@"), Some((0, 0, 1, 3)));
        assert_eq!(parse_hunk_ranges("@@ nonsense @@"), None);
    }

    #[test]
    fn quoted_paths_are_decoded() {
        assert_eq!(unquote("\"a/space name.txt\""), "a/space name.txt");
        assert_eq!(unquote("\"a/tab\\there\""), "a/tab\there");
        assert_eq!(unquote("plain/path"), "plain/path");
        assert_eq!(unquote("\"a/caf\\303\\251\""), "a/café");
    }

    #[test]
    fn diff_git_header_recovers_both_sides() {
        assert_eq!(
            split_diff_git_header("a/src/main.rs b/src/main.rs"),
            (
                Some("src/main.rs".to_owned()),
                Some("src/main.rs".to_owned())
            )
        );
        assert_eq!(
            split_diff_git_header("\"a/with space\" \"b/with space\""),
            (Some("with space".to_owned()), Some("with space".to_owned()))
        );
    }

    #[test]
    fn mode_only_change_is_not_a_type_change() {
        assert!(!mode_type_changed(Some("100644"), Some("100755")));
        assert!(mode_type_changed(Some("100644"), Some("120000")));
        assert!(!mode_type_changed(Some("100644"), None));
    }
}
