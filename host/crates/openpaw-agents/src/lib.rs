//! Adapters that normalize coding-agent state into OpenPaw events.
//!
//! Each supported agent has an [`AgentAdapter`] implementation that knows three
//! things: where the agent keeps its session state ([`AgentAdapter::discover`]),
//! how to turn that state into [`Event`]s incrementally
//! ([`AgentAdapter::parse`]), and — when the agent supports hooks — how to turn a
//! hook payload into a single event ([`AgentAdapter::parse_hook`]).
//!
//! Two invariants hold for every adapter:
//!
//! * **Idempotency.** `event_id` is content addressed from the session id and an
//!   adapter-chosen `source_key`, so re-reading the same transcript bytes yields
//!   the same ids. Combined with the [`Cursor`] a caller can poll forever without
//!   ever emitting a duplicate event.
//! * **Dense sequencing.** `parse` returns events whose `seq` is contiguous,
//!   starting at [`Cursor::next_seq`] and in source order. The cursor is advanced
//!   so the next call continues where this one stopped.

mod claude_code;
mod codex;
mod generic;
mod jsonl;
mod opencode;
mod util;

pub use crate::claude_code::ClaudeCodeAdapter;
pub use crate::codex::CodexAdapter;
pub use crate::generic::GenericAdapter;
pub use crate::opencode::OpenCodeAdapter;

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use anyhow::Result;
use openpaw_protocol::{AgentKind, Event, SessionId};
use serde::{Deserialize, Serialize};
use time::{Duration, OffsetDateTime};

/// Sessions older than this are ignored by discovery unless the caller
/// overrides [`DiscoveryEnv::max_age`].
pub const DEFAULT_MAX_AGE: Duration = Duration::seconds(7 * 24 * 60 * 60);

/// Where and when to look for agent sessions.
///
/// `home` is the user's home directory (injectable so discovery is testable
/// against a synthetic tree), `cwd_filter` restricts results to sessions running
/// inside a directory, and `now`/`max_age` bound how stale a session may be.
#[derive(Debug, Clone)]
pub struct DiscoveryEnv {
    pub home: PathBuf,
    pub cwd_filter: Option<PathBuf>,
    pub now: OffsetDateTime,
    pub max_age: Duration,
}

impl DiscoveryEnv {
    /// Discovery rooted at `home`, as of now, keeping sessions touched within
    /// [`DEFAULT_MAX_AGE`].
    pub fn from_home(home: impl Into<PathBuf>) -> Self {
        Self {
            home: home.into(),
            cwd_filter: None,
            now: OffsetDateTime::now_utc(),
            max_age: DEFAULT_MAX_AGE,
        }
    }

    /// True when a session last touched at `updated_at` is still in scope.
    pub fn is_fresh(&self, updated_at: OffsetDateTime) -> bool {
        self.now - updated_at <= self.max_age
    }

    /// True when a session running in `cwd` passes [`DiscoveryEnv::cwd_filter`].
    /// A session with an unknown cwd is filtered out whenever a filter is set.
    pub fn matches_cwd(&self, cwd: Option<&str>) -> bool {
        match &self.cwd_filter {
            None => true,
            Some(filter) => cwd.is_some_and(|cwd| Path::new(cwd).starts_with(filter)),
        }
    }
}

/// On-disk location backing a discovered session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionSource {
    /// A single append-only JSON Lines transcript (Claude Code, Codex).
    JsonLines(PathBuf),
    /// OpenCode's exploded storage tree. `root` is the `storage` directory that
    /// contains `session/`, `message/` and `part/`; `session_dir` is the
    /// project directory holding this session's `ses_*.json`.
    OpenCodeStorage { root: PathBuf, session_dir: PathBuf },
}

impl SessionSource {
    /// Coarse filesystem location of the session: the transcript file for
    /// [`SessionSource::JsonLines`], the project directory for
    /// [`SessionSource::OpenCodeStorage`].
    ///
    /// For change detection prefer [`DiscoveredSession::watch_path`], which
    /// resolves to a file whose mtime moves when the session gains content.
    pub fn path(&self) -> &Path {
        match self {
            Self::JsonLines(path) => path,
            Self::OpenCodeStorage { session_dir, .. } => session_dir,
        }
    }
}

/// A session an adapter found on disk.
#[derive(Debug, Clone)]
pub struct DiscoveredSession {
    pub session: SessionId,
    pub agent: AgentKind,
    pub source: SessionSource,
    pub title: Option<String>,
    pub cwd: Option<String>,
    pub git_branch: Option<String>,
    pub updated_at: OffsetDateTime,
}

impl DiscoveredSession {
    /// The agent's own session identifier, i.e. the [`SessionId`] with the
    /// `sess_<short>-` prefix removed.
    pub fn raw_id(&self) -> &str {
        self.session.tail()
    }

    /// File to stat when polling for new session content: the transcript for
    /// JSON Lines agents, the session record for OpenCode (which rewrites it
    /// with a new `time.updated` whenever the session advances).
    pub fn watch_path(&self) -> PathBuf {
        match &self.source {
            SessionSource::JsonLines(path) => path.clone(),
            SessionSource::OpenCodeStorage { session_dir, .. } => {
                session_dir.join(format!("{}.json", self.raw_id()))
            }
        }
    }
}

/// Resumable read position for one session.
///
/// For JSON Lines transcripts this is a byte offset over complete lines plus the
/// line index (adapters key `source_key`s off it). For OpenCode's exploded
/// storage there is no single byte stream, so the cursor keeps the set of part
/// keys already emitted as a high-water mark. `next_seq` is the sequence number
/// the next emitted event will carry, and `flags`/`context` carry the small
/// amount of adapter state that must survive across incremental parses (whether
/// a plan was already created, Codex's current cwd, ...).
///
/// It is `Serialize`/`Deserialize` so a host can persist one cursor per session
/// and resume after a restart without re-emitting events.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Cursor {
    pub(crate) next_seq: u64,
    pub(crate) byte_offset: u64,
    pub(crate) line_index: u64,
    pub(crate) consumed: BTreeSet<String>,
    pub(crate) flags: BTreeSet<String>,
    pub(crate) context: BTreeMap<String, String>,
}

impl Cursor {
    /// A cursor positioned before the first event of a session.
    pub fn new() -> Self {
        Self::default()
    }

    /// Sequence number the next emitted event will carry.
    pub fn next_seq(&self) -> u64 {
        self.next_seq
    }

    /// Bytes of the transcript already consumed (always a line boundary).
    pub fn byte_offset(&self) -> u64 {
        self.byte_offset
    }

    /// Number of transcript lines already consumed.
    pub fn line_index(&self) -> u64 {
        self.line_index
    }

    /// True when nothing has been parsed through this cursor yet.
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }

    /// Forget everything, forcing a full re-parse. Event ids are content
    /// addressed, so a re-parse re-emits identical ids with fresh `seq`s.
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    pub(crate) fn flag(&mut self, key: &str) -> bool {
        !self.flags.insert(key.to_owned())
    }

    pub(crate) fn ctx(&self, key: &str) -> Option<&str> {
        self.context.get(key).map(String::as_str)
    }

    pub(crate) fn set_ctx(&mut self, key: &str, value: Option<String>) {
        match value {
            Some(value) => {
                self.context.insert(key.to_owned(), value);
            }
            None => {
                self.context.remove(key);
            }
        }
    }
}

/// Renumber `events` so their `seq` runs contiguously from `start_seq` in the
/// order given.
pub fn renumber(events: Vec<Event>, start_seq: u64) -> Vec<Event> {
    events
        .into_iter()
        .enumerate()
        .map(|(index, event)| event.with_seq(start_seq + index as u64))
        .collect()
}

/// One coding agent's view of the world.
pub trait AgentAdapter: Send + Sync {
    /// Which agent this adapter speaks for.
    fn kind(&self) -> AgentKind;

    /// Identifier of the native format this adapter understands, e.g.
    /// `claude-code/transcript-v1`. Bump it when the mapping changes in a way
    /// that invalidates persisted cursors.
    fn format_version(&self) -> &'static str;

    /// Find the agent's sessions under [`DiscoveryEnv::home`].
    fn discover(&self, env: &DiscoveryEnv) -> Result<Vec<DiscoveredSession>>;

    /// Read everything that appeared since `cursor` and advance it.
    ///
    /// Returns events in source order with contiguous `seq` starting at
    /// [`Cursor::next_seq`]. Calling it again with the same cursor and unchanged
    /// input returns an empty vector.
    fn parse(&self, session: &DiscoveredSession, cursor: &mut Cursor) -> Result<Vec<Event>>;

    /// Normalize one hook payload. `Ok(None)` means "this hook carries nothing
    /// worth an event"; adapters for agents without hooks never emit.
    fn parse_hook(&self, raw: &serde_json::Value, now: OffsetDateTime) -> Result<Option<Event>> {
        let _ = (raw, now);
        Ok(None)
    }
}

/// Every adapter, in display order.
pub fn adapters() -> Vec<Box<dyn AgentAdapter>> {
    vec![
        Box::new(ClaudeCodeAdapter),
        Box::new(CodexAdapter),
        Box::new(OpenCodeAdapter),
        Box::new(GenericAdapter),
    ]
}

/// The adapter for `kind`, or `None` for agents OpenPaw cannot yet read.
pub fn adapter_for(kind: AgentKind) -> Option<Box<dyn AgentAdapter>> {
    match kind {
        AgentKind::ClaudeCode => Some(Box::new(ClaudeCodeAdapter)),
        AgentKind::Codex => Some(Box::new(CodexAdapter)),
        AgentKind::OpenCode => Some(Box::new(OpenCodeAdapter)),
        AgentKind::Generic => Some(Box::new(GenericAdapter)),
        AgentKind::GeminiCli | AgentKind::CursorCli | AgentKind::KimiCli | AgentKind::QwenCode => {
            None
        }
    }
}
