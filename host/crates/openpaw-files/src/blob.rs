//! Blob reads with binary detection and hard byte budgets.

use std::fs::File;
use std::io::Read;

use sha2::{Digest, Sha256};

use crate::path::{relative_string, resolve_in};
use crate::{FileError, ResolvedRoot};

/// How many leading bytes are inspected to decide text vs binary.
pub const BINARY_PROBE_BYTES: usize = 8 * 1024;

/// Default per-blob byte budget: 2 MiB.
pub const DEFAULT_MAX_BLOB_BYTES: u64 = 2 * 1024 * 1024;

/// Byte budget for a single blob read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReadOptions {
    /// Maximum number of bytes of text returned. Text longer than this is cut
    /// and flagged; binary longer than this is refused with
    /// [`FileError::TooLarge`] because a hash would require reading all of it.
    pub max_bytes: u64,
}

impl Default for ReadOptions {
    fn default() -> Self {
        ReadOptions {
            max_bytes: DEFAULT_MAX_BLOB_BYTES,
        }
    }
}

/// A file's contents, or its digest when the contents are not text.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "encoding", content = "value", rename_all = "snake_case")]
pub enum BlobContent {
    /// Valid UTF-8 text, possibly cut at `max_bytes`.
    Text(String),
    /// Non-text content, identified only by digest. Bytes are never shipped.
    Binary {
        /// Lowercase hex SHA-256 of the complete object.
        sha256: String,
    },
}

/// One file read through the boundary.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Blob {
    /// Path relative to the root it was read from, `/`-separated.
    pub path: String,
    /// Real size of the object in bytes, before any truncation.
    pub bytes: u64,
    /// Text or digest.
    pub content: BlobContent,
    /// Best-effort media type.
    pub mime: String,
    /// True when text was deliberately cut short.
    pub truncated: bool,
}

/// Heuristic: does this leading slice look like something other than text?
///
/// A NUL byte or a definitively invalid UTF-8 sequence means binary. An
/// *incomplete* multi-byte sequence at the very end of the slice does not, since
/// the slice is only a prefix of the object.
pub fn looks_binary(prefix: &[u8]) -> bool {
    if prefix.contains(&0) {
        return true;
    }
    match std::str::from_utf8(prefix) {
        Ok(_) => false,
        Err(err) => err.error_len().is_some(),
    }
}

/// Build a [`Blob`] from bytes already in memory.
///
/// `data` may be a prefix of the object when `total_bytes` exceeds
/// `opts.max_bytes` and the content is text. For binary content `data` must be
/// complete, because the digest covers the whole object; a binary prefix is
/// reported as [`FileError::TooLarge`].
pub fn blob_from_bytes(
    display_path: &str,
    data: &[u8],
    total_bytes: u64,
    opts: &ReadOptions,
) -> Result<Blob, FileError> {
    let probe = &data[..data.len().min(BINARY_PROBE_BYTES)];
    if !looks_binary(probe)
        && let Some((text, cut)) = decode_text(data)
    {
        return Ok(Blob {
            path: display_path.to_owned(),
            bytes: total_bytes,
            content: BlobContent::Text(text),
            mime: text_mime(display_path),
            truncated: cut || total_bytes > data.len() as u64,
        });
    }

    if total_bytes > opts.max_bytes || data.len() as u64 != total_bytes {
        return Err(FileError::TooLarge {
            bytes: total_bytes,
            limit: opts.max_bytes,
        });
    }
    let digest = Sha256::digest(data);
    Ok(Blob {
        path: display_path.to_owned(),
        bytes: total_bytes,
        content: BlobContent::Binary {
            sha256: hex_lower(&digest),
        },
        mime: binary_mime(display_path),
        truncated: false,
    })
}

/// Read one file inside `root`.
///
/// The size is taken from `stat` before any content is read, so an oversized
/// object never gets slurped into memory.
pub fn read_blob(
    root: &ResolvedRoot,
    relative: &str,
    opts: &ReadOptions,
) -> Result<Blob, FileError> {
    let resolved = resolve_in(root, relative)?;
    let meta = std::fs::metadata(&resolved)?;
    if !meta.is_file() {
        return Err(FileError::NotAFile);
    }
    let size = meta.len();
    let display = relative_string(&root.path, &resolved);

    let mut file = File::open(&resolved)?;
    let probe_len = usize::try_from(size.min(BINARY_PROBE_BYTES as u64)).unwrap_or(usize::MAX);
    let mut data = vec![0u8; probe_len];
    let filled = fill(&mut file, &mut data)?;
    data.truncate(filled);

    if looks_binary(&data) {
        if size > opts.max_bytes {
            return Err(FileError::TooLarge {
                bytes: size,
                limit: opts.max_bytes,
            });
        }
        file.read_to_end(&mut data)?;
        let total = data.len() as u64;
        return blob_from_bytes(&display, &data, total, opts);
    }

    let want = usize::try_from(size.min(opts.max_bytes)).unwrap_or(usize::MAX);
    if want > data.len() {
        let already = data.len();
        data.resize(want, 0);
        let extra = fill(&mut file, &mut data[already..])?;
        data.truncate(already + extra);
    } else {
        data.truncate(want);
    }
    blob_from_bytes(&display, &data, size, opts)
}

/// Read until `buf` is full or the source hits EOF; returns bytes written.
fn fill(source: &mut impl Read, buf: &mut [u8]) -> Result<usize, FileError> {
    let mut at = 0usize;
    while at < buf.len() {
        let read = source.read(&mut buf[at..])?;
        if read == 0 {
            break;
        }
        at += read;
    }
    Ok(at)
}

/// `Some((text, cut_incomplete_char))` when `data` decodes as text, `None` when
/// it contains a genuinely invalid sequence.
fn decode_text(data: &[u8]) -> Option<(String, bool)> {
    match std::str::from_utf8(data) {
        Ok(text) => Some((text.to_owned(), false)),
        Err(err) if err.error_len().is_none() => {
            let valid = std::str::from_utf8(&data[..err.valid_up_to()]).ok()?;
            Some((valid.to_owned(), true))
        }
        Err(_) => None,
    }
}

fn text_mime(path: &str) -> String {
    match mime_guess::from_path(path).first() {
        Some(mime) if mime.essence_str() != "application/octet-stream" => mime.to_string(),
        _ => "text/plain".to_owned(),
    }
}

fn binary_mime(path: &str) -> String {
    mime_guess::from_path(path)
        .first_or_octet_stream()
        .to_string()
}

pub(crate) fn hex_lower(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(char::from_digit(u32::from(byte >> 4), 16).unwrap_or('0'));
        out.push(char::from_digit(u32::from(byte & 0x0f), 16).unwrap_or('0'));
    }
    out
}
