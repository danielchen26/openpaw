//! Incremental reader for append-only JSON Lines transcripts.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use anyhow::{Context, Result};

/// A window of complete lines read from a transcript.
pub(crate) struct Chunk {
    /// `(line index within the whole file, raw line without the newline)`.
    pub(crate) lines: Vec<(u64, String)>,
    /// Byte offset just past the last complete line consumed.
    pub(crate) next_offset: u64,
    /// Index the next line in the file will have.
    pub(crate) next_index: u64,
    /// True when the file shrank below `offset` and reading restarted at 0,
    /// i.e. the transcript was rotated or rewritten.
    pub(crate) restarted: bool,
}

/// Read complete lines starting at `offset`, which must be a line boundary.
///
/// A trailing partial line (the agent is mid-write) is deliberately left
/// unconsumed so the next call sees it whole.
pub(crate) fn read_lines_from(path: &Path, offset: u64, first_index: u64) -> Result<Chunk> {
    let mut file = File::open(path).with_context(|| format!("open {}", path.display()))?;
    let len = file
        .metadata()
        .with_context(|| format!("stat {}", path.display()))?
        .len();

    let (start, mut index, restarted) = if len < offset {
        (0, 0, true)
    } else {
        (offset, first_index, false)
    };

    file.seek(SeekFrom::Start(start))
        .with_context(|| format!("seek {} to {start}", path.display()))?;
    let mut buffer = Vec::with_capacity((len.saturating_sub(start)) as usize);
    file.read_to_end(&mut buffer)
        .with_context(|| format!("read {}", path.display()))?;

    let mut lines = Vec::new();
    let mut consumed = 0usize;
    for line in buffer.split_inclusive(|byte| *byte == b'\n') {
        if !line.ends_with(b"\n") {
            break;
        }
        consumed += line.len();
        let text = String::from_utf8_lossy(&line[..line.len() - 1])
            .trim_end_matches('\r')
            .to_owned();
        if !text.trim().is_empty() {
            lines.push((index, text));
        }
        index += 1;
    }

    Ok(Chunk {
        lines,
        next_offset: start + consumed as u64,
        next_index: index,
        restarted,
    })
}

/// Bytes of a transcript discovery is willing to sniff for session metadata.
const HEAD_BYTES: u64 = 256 * 1024;

/// Read at most `max` complete, non-empty lines from the start of a transcript,
/// looking at no more than [`HEAD_BYTES`] bytes. Used by discovery to sniff
/// session metadata without walking whole files.
pub(crate) fn head_lines(path: &Path, max: usize) -> Result<Vec<String>> {
    let file = File::open(path).with_context(|| format!("open {}", path.display()))?;
    let mut buffer = Vec::new();
    file.take(HEAD_BYTES)
        .read_to_end(&mut buffer)
        .with_context(|| format!("read {}", path.display()))?;

    let mut lines = Vec::new();
    for line in buffer.split(|byte| *byte == b'\n') {
        if lines.len() == max {
            break;
        }
        let text = String::from_utf8_lossy(line).trim().to_owned();
        if !text.is_empty() {
            lines.push(text);
        }
    }
    Ok(lines)
}
