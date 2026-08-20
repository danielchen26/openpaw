//! The polling supervisor and the session registry.
//!
//! Every adapter is asked to discover its sessions on a fixed cadence, and a
//! session is re-parsed only when its backing file's `(mtime, size)` changed.
//!
//! Polling rather than watching is a deliberate choice. Agent transcripts live in
//! `~/.claude`, `~/.codex` and `~/.local/share/opencode`, which on a developer
//! machine are routinely on a network filesystem, a synced folder, or inside a
//! container bind mount — all places where inotify/FSEvents either does not fire
//! or silently drops events. A 750 ms stat of a handful of files is cheap and
//! never lies.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::Result;
use openpaw_agents::{AgentAdapter, Cursor, DiscoveredSession, DiscoveryEnv};
use openpaw_protocol::{AgentKind, Body, Event, SessionId};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::AppState;
use crate::config::AgentToggles;
use crate::state::Store;

/// A session with no new events for this long is reported idle rather than
/// working. Long enough that a slow tool call is not mislabelled, short enough
/// that a finished session stops looking busy.
const IDLE_AFTER: Duration = Duration::from_secs(90);

/// Cheap change detector for a transcript file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Fingerprint {
    /// Modification time in nanoseconds since the unix epoch.
    pub mtime_ns: u128,
    /// Size in bytes. Carries the change when a filesystem's mtime resolution is
    /// coarse, which is the usual failure mode over NFS and SMB.
    pub size: u64,
}

impl Fingerprint {
    /// Stat `path`. `None` when it vanished between discovery and the stat.
    pub fn of(path: &std::path::Path) -> Option<Fingerprint> {
        let meta = std::fs::metadata(path).ok()?;
        let mtime_ns = meta
            .modified()
            .ok()?
            .duration_since(std::time::UNIX_EPOCH)
            .ok()?
            .as_nanos();
        Some(Fingerprint {
            mtime_ns,
            size: meta.len(),
        })
    }
}

/// Coarse activity state of a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionState {
    /// Alive but quiet.
    Idle,
    /// Producing events right now.
    Working,
    /// Blocked on the operator: at least one actionable inbox item.
    Waiting,
    /// Last thing it did was fail.
    Failed,
    /// No longer discoverable.
    Exited,
}

/// What `GET /v1/sessions` returns per session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSummary {
    /// Stable session identifier.
    pub session_id: SessionId,
    /// Which agent produced it.
    pub agent: AgentKind,
    /// First user message or adapter-supplied title.
    pub title: Option<String>,
    /// Working directory the agent runs in.
    pub cwd: Option<String>,
    /// Git branch at the time of the last event.
    pub git_branch: Option<String>,
    /// tmux/zellij target, when the agent runs inside a multiplexer.
    pub multiplexer_target: Option<String>,
    /// Derived activity state.
    pub state: SessionState,
    /// Timestamp of the newest event.
    #[serde(with = "time::serde::rfc3339::option")]
    pub last_event_at: Option<OffsetDateTime>,
    /// Sequence number of the newest event.
    pub last_seq: u64,
    /// Actionable inbox items waiting on the operator.
    pub pending_inbox: usize,
}

#[derive(Debug, Clone)]
struct Record {
    agent: AgentKind,
    title: Option<String>,
    cwd: Option<String>,
    git_branch: Option<String>,
    multiplexer_target: Option<String>,
    last_event_at: Option<OffsetDateTime>,
    last_seq: u64,
    last_body_failed: bool,
    last_body_completed: bool,
    last_event_instant: Option<Instant>,
    fingerprint: Option<Fingerprint>,
    /// False once discovery stops returning this session.
    present: bool,
}

impl Record {
    fn new(agent: AgentKind) -> Record {
        Record {
            agent,
            title: None,
            cwd: None,
            git_branch: None,
            multiplexer_target: None,
            last_event_at: None,
            last_seq: 0,
            last_body_failed: false,
            last_body_completed: false,
            last_event_instant: None,
            fingerprint: None,
            present: true,
        }
    }

    fn state(&self, pending_inbox: usize) -> SessionState {
        if !self.present {
            return SessionState::Exited;
        }
        if pending_inbox > 0 {
            return SessionState::Waiting;
        }
        if self.last_body_failed {
            return SessionState::Failed;
        }
        if self.last_body_completed {
            return SessionState::Idle;
        }
        match self.last_event_instant {
            Some(at) if at.elapsed() < IDLE_AFTER => SessionState::Working,
            _ => SessionState::Idle,
        }
    }
}

/// Everything the daemon knows about live sessions.
#[derive(Debug, Default)]
pub struct Registry {
    inner: Mutex<HashMap<SessionId, Record>>,
}

impl Registry {
    /// Empty registry.
    pub fn new() -> Registry {
        Registry::default()
    }

    /// Fingerprints from the previous pass, handed to the blocking harvester.
    pub fn fingerprints(&self) -> HashMap<SessionId, Fingerprint> {
        self.lock()
            .iter()
            .filter_map(|(session, record)| record.fingerprint.map(|fp| (session.clone(), fp)))
            .collect()
    }

    /// Fold one discovery pass in: refresh metadata and mark absent sessions.
    pub fn observe_discovery(
        &self,
        discovered: &[DiscoveredSession],
        fingerprints: &[(SessionId, Fingerprint)],
    ) {
        let mut guard = self.lock();
        for record in guard.values_mut() {
            record.present = false;
        }
        for session in discovered {
            let record = guard
                .entry(session.session.clone())
                .or_insert_with(|| Record::new(session.agent));
            record.present = true;
            record.agent = session.agent;
            // Discovery metadata is authoritative for identity fields; events
            // refine them as they arrive.
            if session.title.is_some() {
                record.title = session.title.clone();
            }
            if session.cwd.is_some() {
                record.cwd = session.cwd.clone();
            }
            if session.git_branch.is_some() {
                record.git_branch = session.git_branch.clone();
            }
        }
        for (session, fingerprint) in fingerprints {
            if let Some(record) = guard.get_mut(session) {
                record.fingerprint = Some(*fingerprint);
            }
        }
    }

    /// Fold one event in. Creates a record when the event arrived from a hook for
    /// a session discovery has not seen yet.
    pub fn observe_event(&self, event: &Event) {
        let mut guard = self.lock();
        let record = guard
            .entry(event.session_id.clone())
            .or_insert_with(|| Record::new(event.agent));
        record.agent = event.agent;
        if event.cwd.is_some() {
            record.cwd = event.cwd.clone();
        }
        if event.git_branch.is_some() {
            record.git_branch = event.git_branch.clone();
        }
        if event.multiplexer_target.is_some() {
            record.multiplexer_target = event.multiplexer_target.clone();
        }
        if record
            .last_event_at
            .is_none_or(|previous| event.timestamp >= previous)
        {
            record.last_event_at = Some(event.timestamp);
        }
        record.last_seq = record.last_seq.max(event.seq);
        record.last_event_instant = Some(Instant::now());

        match &event.body {
            Body::AgentFailed(_) => {
                record.last_body_failed = true;
                record.last_body_completed = false;
            }
            Body::AgentCompleted(lifecycle) => {
                record.last_body_failed = false;
                record.last_body_completed = true;
                if record.title.is_none() {
                    record.title = lifecycle.title.clone();
                }
            }
            Body::AgentStarted(lifecycle) => {
                record.last_body_failed = false;
                record.last_body_completed = false;
                if record.title.is_none() {
                    record.title = lifecycle.title.clone();
                }
            }
            _ => {
                record.last_body_failed = false;
                record.last_body_completed = false;
            }
        }
    }

    /// Summaries, newest activity first.
    pub fn summaries(&self, pending: &HashMap<SessionId, usize>) -> Vec<SessionSummary> {
        let guard = self.lock();
        let mut out: Vec<SessionSummary> = guard
            .iter()
            .map(|(session, record)| {
                let pending_inbox = pending.get(session).copied().unwrap_or(0);
                SessionSummary {
                    session_id: session.clone(),
                    agent: record.agent,
                    title: record.title.clone(),
                    cwd: record.cwd.clone(),
                    git_branch: record.git_branch.clone(),
                    multiplexer_target: record.multiplexer_target.clone(),
                    state: record.state(pending_inbox),
                    last_event_at: record.last_event_at,
                    last_seq: record.last_seq,
                    pending_inbox,
                }
            })
            .collect();
        drop(guard);
        out.sort_by(|a, b| {
            b.last_event_at
                .cmp(&a.last_event_at)
                .then_with(|| a.session_id.as_ref().cmp(b.session_id.as_ref()))
        });
        out
    }

    /// Number of tracked sessions.
    pub fn len(&self) -> usize {
        self.lock().len()
    }

    /// True when nothing has been discovered yet.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<SessionId, Record>> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// Result of one blocking discovery + parse pass.
#[derive(Debug, Default)]
struct Harvest {
    discovered: Vec<DiscoveredSession>,
    events: Vec<Event>,
    cursors: Vec<(SessionId, Cursor)>,
    fingerprints: Vec<(SessionId, Fingerprint)>,
}

/// The wire name of an agent kind, e.g. `claude-code`.
///
/// Derived from the protocol's own serde representation so it can never drift
/// from what the schema says.
pub fn agent_name(kind: AgentKind) -> String {
    serde_json::to_value(kind)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_else(|| format!("{kind:?}"))
}

/// Adapters the config enables.
pub fn enabled_adapters(toggles: &AgentToggles) -> Vec<Box<dyn AgentAdapter>> {
    openpaw_agents::adapters()
        .into_iter()
        .filter(|adapter| toggles.enabled(adapter.kind()))
        .collect()
}

/// `agent -> format version` for the health endpoint's diagnostics view.
pub fn adapter_versions(toggles: &AgentToggles) -> std::collections::BTreeMap<String, String> {
    enabled_adapters(toggles)
        .iter()
        .map(|adapter| {
            (
                agent_name(adapter.kind()),
                adapter.format_version().to_owned(),
            )
        })
        .collect()
}

/// Agent kinds the config enables, in adapter order.
pub fn enabled_kinds(toggles: &AgentToggles) -> Vec<AgentKind> {
    enabled_adapters(toggles)
        .iter()
        .map(|adapter| adapter.kind())
        .collect()
}

/// Discover and parse everything that changed. Blocking: all filesystem work.
fn harvest(
    toggles: &AgentToggles,
    home: &Path,
    max_age: time::Duration,
    store: &Store,
    known: &HashMap<SessionId, Fingerprint>,
) -> Harvest {
    let env = DiscoveryEnv {
        home: home.to_path_buf(),
        cwd_filter: None,
        now: OffsetDateTime::now_utc(),
        max_age,
    };

    let mut harvest = Harvest::default();
    for adapter in enabled_adapters(toggles) {
        let sessions = match adapter.discover(&env) {
            Ok(sessions) => sessions,
            Err(err) => {
                // One broken adapter must not stop the others: a malformed
                // transcript in ~/.codex should never hide Claude Code activity.
                tracing::warn!(agent = %agent_name(adapter.kind()), %err, "discovery failed");
                continue;
            }
        };

        for session in sessions {
            let fingerprint = Fingerprint::of(session.source.path());
            if let Some(fingerprint) = fingerprint {
                harvest
                    .fingerprints
                    .push((session.session.clone(), fingerprint));
                if known.get(&session.session) == Some(&fingerprint) {
                    harvest.discovered.push(session);
                    continue;
                }
            }

            let mut cursor = store.cursor(&session.session);
            match adapter.parse(&session, &mut cursor) {
                Ok(events) => {
                    if !events.is_empty() {
                        harvest.cursors.push((session.session.clone(), cursor));
                        harvest.events.extend(events);
                    }
                }
                Err(err) => {
                    tracing::warn!(
                        agent = %agent_name(adapter.kind()),
                        session = %session.session,
                        %err,
                        "parse failed; the cursor is left untouched so the next pass retries"
                    );
                }
            }
            harvest.discovered.push(session);
        }
    }
    harvest
}

/// Run one poll pass. Returns how many events were published.
///
/// Separated from the loop so it can be driven directly by a test or a signal
/// rather than only by the timer.
pub async fn poll_once(app: &AppState) -> Result<usize> {
    let toggles = app.config.agents.clone();
    let home = app.home.clone();
    let max_age = app.config.session_max_age();
    let store = app.store.clone();
    let known = app.sessions.fingerprints();

    let harvest =
        tokio::task::spawn_blocking(move || harvest(&toggles, &home, max_age, &store, &known))
            .await?;

    let published = harvest.events.len();
    for event in harvest.events {
        app.publish(event);
    }
    app.sessions
        .observe_discovery(&harvest.discovered, &harvest.fingerprints);

    if let Err(err) = app.store.save_cursors(harvest.cursors) {
        // Losing a cursor costs a re-parse, which is idempotent because event ids
        // are content-addressed. It is not worth failing the pass over.
        tracing::warn!(%err, "could not persist adapter cursors");
    }
    Ok(published)
}

/// Spawn the polling loop.
pub fn spawn(app: AppState) -> tokio::task::JoinHandle<()> {
    let interval = app.config.poll_interval();
    tokio::spawn(async move {
        tracing::info!(?interval, "supervisor polling started");
        let mut ticker = tokio::time::interval(interval);
        // A slow pass must not cause a burst of catch-up ticks.
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            ticker.tick().await;
            match poll_once(&app).await {
                Ok(0) => {}
                Ok(count) => tracing::debug!(count, "published events"),
                Err(err) => tracing::warn!(%err, "poll pass failed"),
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use openpaw_protocol::{AgentLifecycle, DeltaKind, TurnDelta};

    fn session() -> SessionId {
        SessionId::new(AgentKind::ClaudeCode, "alpha")
    }

    fn event(body: Body, seq: u64) -> Event {
        Event::new(
            &session(),
            AgentKind::ClaudeCode,
            &format!("k{seq}"),
            OffsetDateTime::UNIX_EPOCH + time::Duration::seconds(seq as i64),
            body,
        )
        .with_seq(seq)
        .with_context(Some("/w".into()), Some("main".into()))
    }

    fn working(seq: u64) -> Event {
        event(
            Body::TurnDelta(TurnDelta {
                turn_id: "t".into(),
                delta: "x".into(),
                kind: DeltaKind::Text,
            }),
            seq,
        )
    }

    fn lifecycle(title: Option<String>) -> AgentLifecycle {
        AgentLifecycle {
            reason: None,
            exit_code: None,
            title,
        }
    }

    #[test]
    fn session_summary_serializes_the_exact_keys_the_app_reads() {
        let registry = Registry::new();
        registry.observe_event(&working(3));
        let summary = registry.summaries(&HashMap::new()).remove(0);

        let value = serde_json::to_value(&summary).unwrap();
        let mut keys: Vec<&str> = value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort_unstable();

        // Asserting the whole key set at once, rather than one field at a time: a
        // stray container-level rename would otherwise only be caught by whichever
        // multi-word field a test happened to read.
        assert_eq!(
            keys,
            vec![
                "agent",
                "cwd",
                "git_branch",
                "last_event_at",
                "last_seq",
                "multiplexer_target",
                "pending_inbox",
                "session_id",
                "state",
                "title",
            ]
        );
        assert_eq!(value["session_id"], session().as_ref());
        assert_eq!(value["agent"], "claude-code");
        assert_eq!(value["state"], "working");
        assert!(value["multiplexer_target"].is_null());
    }

    #[test]
    fn an_event_creates_a_working_session_with_context() {
        let registry = Registry::new();
        registry.observe_event(&working(3));

        let summaries = registry.summaries(&HashMap::new());
        assert_eq!(summaries.len(), 1);
        let summary = &summaries[0];
        assert_eq!(summary.session_id, session());
        assert_eq!(summary.agent, AgentKind::ClaudeCode);
        assert_eq!(summary.cwd.as_deref(), Some("/w"));
        assert_eq!(summary.git_branch.as_deref(), Some("main"));
        assert_eq!(summary.last_seq, 3);
        assert_eq!(summary.state, SessionState::Working);
        assert_eq!(summary.pending_inbox, 0);
    }

    #[test]
    fn pending_inbox_items_make_a_session_waiting() {
        let registry = Registry::new();
        registry.observe_event(&working(0));
        let pending = HashMap::from([(session(), 2usize)]);
        let summaries = registry.summaries(&pending);
        assert_eq!(summaries[0].state, SessionState::Waiting);
        assert_eq!(summaries[0].pending_inbox, 2);
    }

    #[test]
    fn lifecycle_events_drive_completed_and_failed_states() {
        let registry = Registry::new();
        registry.observe_event(&event(Body::AgentCompleted(lifecycle(None)), 1));
        assert_eq!(
            registry.summaries(&HashMap::new())[0].state,
            SessionState::Idle
        );

        registry.observe_event(&event(Body::AgentFailed(lifecycle(None)), 2));
        assert_eq!(
            registry.summaries(&HashMap::new())[0].state,
            SessionState::Failed
        );

        // Activity after a failure clears it.
        registry.observe_event(&working(3));
        assert_eq!(
            registry.summaries(&HashMap::new())[0].state,
            SessionState::Working
        );
    }

    #[test]
    fn a_session_that_discovery_stops_returning_is_exited() {
        let registry = Registry::new();
        registry.observe_event(&working(0));
        assert_eq!(
            registry.summaries(&HashMap::new())[0].state,
            SessionState::Working
        );

        // An empty discovery pass marks every known session absent.
        registry.observe_discovery(&[], &[]);
        assert_eq!(
            registry.summaries(&HashMap::new())[0].state,
            SessionState::Exited
        );
    }

    #[test]
    fn titles_come_from_lifecycle_events_and_are_not_overwritten() {
        let registry = Registry::new();
        registry.observe_event(&event(
            Body::AgentStarted(lifecycle(Some("first".into()))),
            0,
        ));
        registry.observe_event(&event(
            Body::AgentCompleted(lifecycle(Some("second".into()))),
            1,
        ));
        assert_eq!(
            registry.summaries(&HashMap::new())[0].title.as_deref(),
            Some("first")
        );
    }

    #[test]
    fn summaries_are_ordered_by_recency() {
        let registry = Registry::new();
        let other = SessionId::new(AgentKind::Codex, "beta");
        registry.observe_event(&working(1));
        registry.observe_event(&Event::new(
            &other,
            AgentKind::Codex,
            "later",
            OffsetDateTime::UNIX_EPOCH + time::Duration::seconds(500),
            Body::TurnDelta(TurnDelta {
                turn_id: "t".into(),
                delta: "x".into(),
                kind: DeltaKind::Text,
            }),
        ));
        let summaries = registry.summaries(&HashMap::new());
        assert_eq!(summaries[0].session_id, other, "newest first");
        assert_eq!(summaries[1].session_id, session());
    }

    #[test]
    fn fingerprints_change_with_size_even_at_the_same_mtime() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("transcript.jsonl");
        std::fs::write(&path, b"one").unwrap();
        let first = Fingerprint::of(&path).unwrap();
        std::fs::write(&path, b"one-two").unwrap();
        let second = Fingerprint::of(&path).unwrap();

        assert_ne!(first, second);
        assert_eq!(first.size, 3);
        assert_eq!(second.size, 7);
        assert!(Fingerprint::of(&dir.path().join("missing.jsonl")).is_none());
    }

    #[test]
    fn agent_names_use_the_protocol_spelling() {
        assert_eq!(agent_name(AgentKind::ClaudeCode), "claude-code");
        assert_eq!(agent_name(AgentKind::OpenCode), "opencode");
        assert_eq!(agent_name(AgentKind::Codex), "codex");
    }

    #[test]
    fn disabled_agents_are_not_polled_and_report_no_version() {
        let toggles = AgentToggles {
            claude_code: true,
            codex: false,
            opencode: false,
            generic: false,
        };
        let kinds = enabled_kinds(&toggles);
        assert_eq!(kinds, vec![AgentKind::ClaudeCode]);

        let versions = adapter_versions(&toggles);
        assert_eq!(versions.len(), 1);
        assert!(versions.contains_key("claude-code"));
        assert!(!versions["claude-code"].is_empty());
    }
}
