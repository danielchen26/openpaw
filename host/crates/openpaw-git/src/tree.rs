//! `git ls-tree -l -z` parsing.

use openpaw_files::{EntryKind, TreeEntry};

use crate::GitError;

/// Parse the NUL-delimited `ls-tree -l -z` payload into tree entries.
///
/// Each record is `<mode> SP <type> SP <object> SP..<size> TAB <path>`, where
/// `size` is `-` for anything that is not a blob.
pub(crate) fn parse_ls_tree(data: &[u8]) -> Result<Vec<TreeEntry>, GitError> {
    let mut entries: Vec<TreeEntry> = Vec::new();
    for record in data.split(|byte| *byte == 0) {
        if record.is_empty() {
            continue;
        }
        let record = String::from_utf8_lossy(record).into_owned();
        let (meta, path) = record
            .split_once('\t')
            .ok_or_else(|| GitError::Parse(format!("ls-tree record without tab: {record:?}")))?;
        let mut fields = meta.split_whitespace();
        let (Some(mode), Some(kind), Some(_oid)) = (fields.next(), fields.next(), fields.next())
        else {
            return Err(GitError::Parse(format!("short ls-tree record: {record:?}")));
        };
        let size = fields.next().and_then(|value| value.parse::<u64>().ok());

        let is_symlink = mode == "120000";
        let entry_kind = match (kind, is_symlink) {
            (_, true) => EntryKind::Symlink,
            ("tree", _) => EntryKind::Directory,
            ("blob", _) => EntryKind::File,
            // `commit` entries are submodule gitlinks; anything else is not
            // content we can serve either.
            _ => EntryKind::Other,
        };
        let name = path.rsplit('/').next().unwrap_or(path).to_owned();
        entries.push(TreeEntry {
            name,
            path: path.to_owned(),
            kind: entry_kind,
            size: if entry_kind == EntryKind::File {
                size
            } else {
                None
            },
            is_symlink,
        });
    }

    entries.sort_by(|left, right| {
        let by_kind =
            (left.kind != EntryKind::Directory).cmp(&(right.kind != EntryKind::Directory));
        by_kind.then_with(|| left.name.cmp(&right.name))
    });
    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_blobs_trees_symlinks_and_submodules() {
        let mut data = Vec::new();
        for record in [
            "100644 blob aaaaaaa     42\tREADME.md",
            "040000 tree bbbbbbb      -\tsrc",
            "120000 blob ccccccc     11\tlink",
            "160000 commit ddddddd      -\tvendor/dep",
        ] {
            data.extend_from_slice(record.as_bytes());
            data.push(0);
        }
        let entries = parse_ls_tree(&data).expect("parse");
        assert_eq!(entries[0].name, "src");
        assert_eq!(entries[0].kind, EntryKind::Directory);
        let by_name = |name: &str| {
            entries
                .iter()
                .find(|entry| entry.name == name)
                .unwrap_or_else(|| panic!("missing {name}"))
                .clone()
        };
        let readme = by_name("README.md");
        assert_eq!(readme.kind, EntryKind::File);
        assert_eq!(readme.size, Some(42));
        let link = by_name("link");
        assert_eq!(link.kind, EntryKind::Symlink);
        assert!(link.is_symlink);
        assert_eq!(link.size, None);
        // `name` is the final component even when the tree reports a full path.
        let submodule = by_name("dep");
        assert_eq!(submodule.kind, EntryKind::Other);
        assert_eq!(submodule.path, "vendor/dep");
        assert_eq!(submodule.size, None);
    }

    #[test]
    fn malformed_records_are_errors() {
        let err = parse_ls_tree(b"100644 blob aaaa 12 README.md\0").expect_err("no tab");
        assert!(matches!(err, GitError::Parse(_)), "got {err:?}");
    }
}
