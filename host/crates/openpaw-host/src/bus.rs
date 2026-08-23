//! The event bus: fan-out, replay backlog, and the pending-inbox map.
//!
//! Three responsibilities that belong together because they share one lock:
//!
//! * **Fan-out.** Every normalized event goes to every live SSE subscriber.
//! * **Replay.** A phone that was in a tunnel for two minutes reconnects with
//!   `after_seq` and must receive what it missed, so the last `ring_capacity`
//!   events per session are retained.
//! * **Authority.** An inbox item is only actionable while it holds an unused
//!   action token. A push notification is never sufficient to approve anything;
//!   the token is, and it is single-use with a 10-minute lifetime.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use openpaw_protocol::{Body, Event, InboxId, InboxItem, InboxStatus, SessionId};
use tokio::sync::broadcast;

/// How long an action token stays usable.
pub const ACTION_TOKEN_TTL: Duration = Duration::from_secs(600);
/// Events retained per session when the caller does not configure it.
pub const DEFAULT_RING_CAPACITY: usize = 2000;
/// Fan-out buffer. A subscriber that falls this far behind is lagged and
/// resubscribes with `after_seq` rather than blocking the publisher.
const BROADCAST_CAPACITY: usize = 4096;

/// An inbox item plus the secret that authorizes acting on it.
#[derive(Debug, Clone)]
pub struct PendingItem {
    /// The projection shown on the phone.
    pub item: InboxItem,
    /// The event this item was projected from. Carries the agent-side
    /// `request_id` the decision file must reference.
    pub source: Arc<Event>,
    /// `None` once the token has been spent.
    action_token: Option<String>,
    issued: Instant,
}

impl PendingItem {
    /// The agent-side request id this item is answering, if it has one.
    ///
    /// Read off the source event rather than the projection: this is the id the
    /// agent's own hook is waiting on, and it must survive verbatim.
    pub fn request_id(&self) -> Option<&str> {
        match &self.source.body {
            Body::PermissionRequested(payload) => Some(payload.request_id.as_str()),
            Body::QuestionRequested(payload) => Some(payload.request_id.as_str()),
            _ => None,
        }
    }
}

/// Why an action token could not be spent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum ClaimError {
    /// No such inbox item.
    #[error("unknown inbox item")]
    Unknown,
    /// Wrong token, or a token that was already spent.
    #[error("invalid or already-used action token")]
    BadToken,
    /// The token aged out.
    #[error("action token expired")]
    Expired,
    /// Someone (or something) already resolved this item.
    #[error("inbox item is already resolved")]
    AlreadyResolved,
}

#[derive(Debug, Default)]
struct Inner {
    /// Per-session replay backlog, oldest first.
    rings: HashMap<SessionId, VecDeque<Arc<Event>>>,
    /// Authoritative per-session sequence counter.
    seqs: HashMap<SessionId, u64>,
    /// Inbox items keyed by id; ordered so listings are stable.
    inbox: BTreeMap<InboxId, PendingItem>,
    dismissed: std::collections::BTreeSet<InboxId>,
}

/// Event fan-out with replay and the pending-inbox map.
#[derive(Debug)]
pub struct Bus {
    tx: broadcast::Sender<Arc<Event>>,
    inner: Mutex<Inner>,
    ring_capacity: usize,
    token_ttl: Duration,
}

impl Bus {
    /// Bus retaining `ring_capacity` events per session.
    pub fn new(ring_capacity: usize) -> Bus {
        Bus::with_token_ttl(ring_capacity, ACTION_TOKEN_TTL)
    }

    /// Bus with a custom action-token lifetime. Used by tests.
    pub fn with_token_ttl(ring_capacity: usize, token_ttl: Duration) -> Bus {
        let (tx, _rx) = broadcast::channel(BROADCAST_CAPACITY);
        Bus {
            tx,
            inner: Mutex::new(Inner::default()),
            ring_capacity: ring_capacity.max(1),
            token_ttl,
        }
    }

    /// Subscribe to live events.
    pub fn subscribe(&self) -> broadcast::Receiver<Arc<Event>> {
        self.tx.subscribe()
    }

    /// Number of live subscribers. Diagnostics only.
    pub fn subscribers(&self) -> usize {
        self.tx.receiver_count()
    }

    /// Publish `event`, assigning the authoritative per-session `seq`.
    ///
    /// Adapter events already carry a contiguous seq from their persisted
    /// cursor, so the counter takes the greater of the two: adapter numbering is
    /// preserved exactly, and host-originated events (resolutions, hook events,
    /// which arrive with `seq == 0`) are appended past the high-water mark. The
    /// result is monotonic per session across restarts without a second
    /// persisted counter.
    pub fn publish(&self, event: Event) -> Arc<Event> {
        let stored = {
            let mut inner = self.lock();
            let slot = inner.seqs.entry(event.session_id.clone()).or_insert(0);
            let seq = (*slot).max(event.seq);
            *slot = seq + 1;

            let stored = Arc::new(event.with_seq(seq));
            let ring = inner
                .rings
                .entry(stored.session_id.clone())
                .or_insert_with(|| VecDeque::with_capacity(self.ring_capacity.min(256)));
            ring.push_back(Arc::clone(&stored));
            while ring.len() > self.ring_capacity {
                ring.pop_front();
            }
            stored
        };
        // A send error only means nobody is subscribed right now; the backlog
        // still holds the event for the next reader.
        let _ = self.tx.send(Arc::clone(&stored));
        stored
    }

    /// Publish `event` and, when it is actionable, register the inbox item it
    /// projects to.
    ///
    /// Returns the stored event and the item with its freshly minted action
    /// token. Re-publishing the same source event does not mint a second token:
    /// inbox ids are content-addressed, so a re-parsed transcript cannot hand out
    /// a duplicate approval authority.
    pub fn publish_with_inbox(&self, event: Event) -> (Arc<Event>, Option<InboxItem>) {
        let stored = self.publish(event);
        let projected = match InboxItem::from_event(&stored) {
            Some(item) => item,
            None => return (stored, None),
        };

        let mut inner = self.lock();
        if inner.dismissed.contains(&projected.id) {
            let mut item = projected;
            item.status = InboxStatus::Dismissed;
            item.action_token = None;
            item.resolution = Some("dismissed".to_owned());
            inner.inbox.insert(
                item.id.clone(),
                PendingItem {
                    item: item.clone(),
                    source: Arc::clone(&stored),
                    action_token: None,
                    issued: Instant::now(),
                },
            );
            return (stored, Some(item));
        }
        if let Some(existing) = inner.inbox.get(&projected.id) {
            let item = existing.item.clone();
            return (stored, Some(item));
        }
        let mut item = projected;
        let token = if matches!(
            stored.body,
            Body::PermissionRequested(_) | Body::QuestionRequested(_)
        ) {
            let token = crate::auth::mint_secret();
            item.action_token = Some(token.clone());
            Some(token)
        } else {
            item.action_token = None;
            None
        };
        inner.inbox.insert(
            item.id.clone(),
            PendingItem {
                item: item.clone(),
                source: Arc::clone(&stored),
                action_token: token,
                issued: Instant::now(),
            },
        );
        (stored, Some(item))
    }

    /// Backlog for replay, oldest first.
    ///
    /// `after_seq` is exclusive. Without a `session` filter the per-session rings
    /// are merged by `(timestamp, seq)` so a global subscriber sees a stable
    /// interleaving.
    pub fn replay(&self, session: Option<&SessionId>, after_seq: Option<u64>) -> Vec<Arc<Event>> {
        let inner = self.lock();
        let mut out: Vec<Arc<Event>> = match session {
            Some(session) => match inner.rings.get(session) {
                Some(ring) => ring.iter().cloned().collect(),
                None => Vec::new(),
            },
            None => inner.rings.values().flatten().cloned().collect(),
        };
        drop(inner);

        if let Some(after) = after_seq {
            out.retain(|event| event.seq > after);
        }
        if session.is_none() {
            out.sort_by(|a, b| {
                a.timestamp
                    .cmp(&b.timestamp)
                    .then_with(|| a.seq.cmp(&b.seq))
                    .then_with(|| a.event_id.as_ref().cmp(b.event_id.as_ref()))
            });
        }
        out
    }

    /// Inbox items, newest first, optionally filtered by status.
    pub fn inbox(&self, status: Option<InboxStatus>) -> Vec<InboxItem> {
        let mut inner = self.lock();
        Self::sweep(&mut inner, self.token_ttl);
        let mut out: Vec<InboxItem> = inner
            .inbox
            .values()
            .filter(|pending| status.is_none_or(|want| pending.item.status == want))
            .map(|pending| pending.item.clone())
            .collect();
        drop(inner);
        out.sort_by(|a, b| {
            b.created_at
                .cmp(&a.created_at)
                .then_with(|| a.id.as_ref().cmp(b.id.as_ref()))
        });
        out
    }

    /// Read one item without spending its token.
    pub fn peek(&self, id: &InboxId) -> Option<PendingItem> {
        let mut inner = self.lock();
        Self::sweep(&mut inner, self.token_ttl);
        inner.inbox.get(id).cloned()
    }

    /// Count of still-actionable items per session, for session summaries.
    pub fn pending_counts(&self) -> HashMap<SessionId, usize> {
        let mut inner = self.lock();
        Self::sweep(&mut inner, self.token_ttl);
        let mut counts: HashMap<SessionId, usize> = HashMap::new();
        for pending in inner.inbox.values() {
            if pending.item.status == InboxStatus::Pending {
                *counts.entry(pending.item.session_id.clone()).or_insert(0) += 1;
            }
        }
        counts
    }

    /// Spend an action token and mark the item resolved.
    ///
    /// Atomic: the check and the state transition happen under one lock, so two
    /// concurrent taps on the same approval cannot both win.
    pub fn claim(
        &self,
        id: &InboxId,
        presented: &str,
        resolution: &str,
    ) -> Result<PendingItem, ClaimError> {
        let mut inner = self.lock();
        Self::sweep(&mut inner, self.token_ttl);
        let pending = inner.inbox.get_mut(id).ok_or(ClaimError::Unknown)?;

        // Status before token. The caller is already an authenticated device
        // holding `approvals.write`, so "this expired" and "someone already
        // answered this" are not secrets — and they are the two answers a phone
        // needs to show something useful instead of a generic refusal. An expired
        // item has had its token cleared anyway, so checking the token first would
        // only ever report `BadToken` and lose the reason.
        match pending.item.status {
            InboxStatus::Pending => {}
            InboxStatus::Expired => return Err(ClaimError::Expired),
            InboxStatus::Resolved | InboxStatus::Dismissed => {
                return Err(ClaimError::AlreadyResolved);
            }
        }

        let token = pending.action_token.clone().ok_or(ClaimError::BadToken)?;
        if !crate::auth::constant_time_eq(token.as_bytes(), presented.as_bytes()) {
            return Err(ClaimError::BadToken);
        }
        // Guards the sliver between the sweep above and this line.
        if pending.issued.elapsed() >= self.token_ttl {
            pending.item.status = InboxStatus::Expired;
            pending.item.action_token = None;
            pending.action_token = None;
            return Err(ClaimError::Expired);
        }

        pending.action_token = None;
        pending.item.action_token = None;
        pending.item.status = InboxStatus::Resolved;
        pending.item.resolution = Some(resolution.to_owned());
        Ok(pending.clone())
    }

    /// Undo a [`Bus::claim`] whose follow-up work failed.
    ///
    /// Without this, a decision file that could not be written would leave an
    /// item marked resolved that the agent never heard about — the phone would
    /// show "approved" while the terminal still waits.
    pub fn restore(&self, pending: PendingItem) {
        let mut inner = self.lock();
        if let Some(slot) = inner.inbox.get_mut(&pending.item.id) {
            let token = crate::auth::mint_secret();
            slot.item = pending.item;
            slot.item.status = InboxStatus::Pending;
            slot.item.resolution = None;
            slot.item.action_token = Some(token.clone());
            slot.action_token = Some(token);
            slot.issued = Instant::now();
        }
    }

    /// Mark an informational item dismissed. Idempotent for already-dismissed items.
    pub fn dismiss(&self, id: &InboxId) -> Result<InboxItem, DismissError> {
        let mut inner = self.lock();
        Self::sweep(&mut inner, self.token_ttl);
        if inner.dismissed.contains(id) {
            return inner
                .inbox
                .get(id)
                .map(|pending| pending.item.clone())
                .ok_or(DismissError::Unknown);
        }
        let pending = inner.inbox.get_mut(id).ok_or(DismissError::Unknown)?;
        if pending.request_id().is_some() || pending.item.request_id.is_some() {
            return Err(DismissError::Actionable);
        }
        pending.action_token = None;
        pending.item.action_token = None;
        pending.item.status = InboxStatus::Dismissed;
        pending.item.resolution = Some("dismissed".to_owned());
        let item = pending.item.clone();
        inner.dismissed.insert(id.clone());
        Ok(item)
    }

    /// Hydrate durable dismissal tombstones on boot.
    pub fn hydrate_dismissed(&self, ids: impl IntoIterator<Item = InboxId>) {
        let mut inner = self.lock();
        inner.dismissed.extend(ids);
    }

    /// Flip items whose token aged out, or whose own `expires_at` passed, to
    /// [`InboxStatus::Expired`].
    ///
    /// Done lazily on read instead of on a timer: an item nobody looks at does
    /// not need a task waking up to relabel it, and a dead token is unusable
    /// either way because [`Bus::claim`] checks the same clock.
    fn sweep(inner: &mut Inner, ttl: Duration) {
        let now = time::OffsetDateTime::now_utc();
        for pending in inner.inbox.values_mut() {
            if pending.item.status != InboxStatus::Pending {
                continue;
            }
            let token_dead = pending.action_token.is_some() && pending.issued.elapsed() >= ttl;
            let deadline_passed = pending.item.expires_at.is_some_and(|at| at <= now);
            if token_dead || deadline_passed {
                pending.item.status = InboxStatus::Expired;
                pending.item.action_token = None;
                pending.action_token = None;
            }
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// Why an inbox item cannot be dismissed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum DismissError {
    /// No such item.
    #[error("unknown inbox item")]
    Unknown,
    /// The item represents an agent request and must be resolved or denied.
    #[error("only informational inbox items can be dismissed")]
    Actionable,
}

#[cfg(test)]
mod tests {
    use super::*;
    use openpaw_protocol::{
        ActionId, AgentKind, AgentLifecycle, DeltaKind, PermissionRequested, Risk, TurnDelta,
    };
    use time::OffsetDateTime;

    fn session() -> SessionId {
        SessionId::new(AgentKind::ClaudeCode, "alpha")
    }

    fn delta(n: u64) -> Event {
        Event::new(
            &session(),
            AgentKind::ClaudeCode,
            &format!("delta-{n}"),
            OffsetDateTime::UNIX_EPOCH + time::Duration::seconds(n as i64),
            Body::TurnDelta(TurnDelta {
                turn_id: "t1".into(),
                delta: format!("chunk {n}"),
                kind: DeltaKind::Text,
            }),
        )
    }

    fn permission(command: &str) -> Event {
        Event::new(
            &session(),
            AgentKind::ClaudeCode,
            &format!("perm-{command}"),
            OffsetDateTime::UNIX_EPOCH,
            Body::PermissionRequested(PermissionRequested {
                request_id: "req-1".into(),
                tool: "Bash".into(),
                summary: command.to_owned(),
                command: Some(command.to_owned()),
                paths: Vec::new(),
                risk: Risk::classify_command(command),
                actions: vec![ActionId::ApproveOnce, ActionId::Deny],
                expires_at: None,
            }),
        )
    }

    fn completion() -> Event {
        Event::new(
            &session(),
            AgentKind::ClaudeCode,
            "agent:completed:1",
            OffsetDateTime::UNIX_EPOCH,
            Body::AgentCompleted(AgentLifecycle {
                reason: Some("done".into()),
                exit_code: None,
                title: Some("Done".into()),
            }),
        )
    }

    #[test]
    fn hydrated_dismissal_tombstone_keeps_reprojected_item_dismissed_without_token() {
        let bus = Bus::new(16);
        let first = InboxItem::from_event(&completion()).unwrap();
        bus.hydrate_dismissed([first.id.clone()]);

        let (_stored, item) = bus.publish_with_inbox(completion());
        let item = item.expect("projection");
        assert_eq!(item.status, InboxStatus::Dismissed);
        assert!(item.action_token.is_none());
        let peeked = bus.peek(&item.id).expect("dismissed projection is listed");
        assert_eq!(peeked.item.status, InboxStatus::Dismissed);
        assert!(
            peeked.item.action_token.is_none(),
            "no pending authority is minted"
        );
    }

    #[test]
    fn publish_assigns_monotonic_seq_and_keeps_adapter_numbering() {
        let bus = Bus::new(16);
        let first = bus.publish(delta(0));
        assert_eq!(first.seq, 0);

        // An adapter event that already carries seq 7 keeps it.
        let mut ahead = delta(1);
        ahead.seq = 7;
        assert_eq!(bus.publish(ahead).seq, 7);

        // A host-originated event (seq 0) lands past the high-water mark.
        assert_eq!(bus.publish(delta(2)).seq, 8);
    }

    #[test]
    fn ring_buffer_drops_the_oldest_and_replay_respects_after_seq() {
        let bus = Bus::new(3);
        for n in 0..6 {
            bus.publish(delta(n));
        }
        let all = bus.replay(Some(&session()), None);
        assert_eq!(all.len(), 3, "only the newest 3 are retained");
        assert_eq!(all.iter().map(|e| e.seq).collect::<Vec<_>>(), vec![3, 4, 5]);

        let tail = bus.replay(Some(&session()), Some(4));
        assert_eq!(tail.iter().map(|e| e.seq).collect::<Vec<_>>(), vec![5]);
        assert!(bus.replay(Some(&session()), Some(99)).is_empty());
        assert!(
            bus.replay(Some(&SessionId::new(AgentKind::Codex, "other")), None)
                .is_empty()
        );
    }

    #[test]
    fn live_subscribers_receive_published_events() {
        let bus = Bus::new(8);
        let mut rx = bus.subscribe();
        let published = bus.publish(delta(0));
        let received = rx.try_recv().expect("subscriber should get the event");
        assert_eq!(received.event_id, published.event_id);
        assert_eq!(received.seq, 0);
    }

    #[test]
    fn actionable_events_mint_a_single_use_token() {
        let bus = Bus::new(8);
        let (_event, item) = bus.publish_with_inbox(permission("rm -rf build"));
        let item = item.expect("a permission request is actionable");
        let token = item.action_token.clone().expect("token minted");
        assert_eq!(item.status, InboxStatus::Pending);
        assert!(item.risk.as_ref().unwrap().requires_detail_expansion);

        let claimed = bus.claim(&item.id, &token, "approve_once").unwrap();
        assert_eq!(claimed.request_id(), Some("req-1"));
        assert_eq!(claimed.item.status, InboxStatus::Resolved);
        assert_eq!(claimed.item.resolution.as_deref(), Some("approve_once"));
        assert!(
            claimed.item.action_token.is_none(),
            "token is not echoed back"
        );

        assert_eq!(
            bus.claim(&item.id, &token, "approve_once").unwrap_err(),
            ClaimError::AlreadyResolved,
            "a spent token cannot be reused"
        );
    }

    #[test]
    fn informational_inbox_items_do_not_get_action_tokens_or_token_ttl_expiry() {
        let bus = Bus::with_token_ttl(8, Duration::from_millis(10));
        let (_event, item) = bus.publish_with_inbox(completion());
        let item = item.expect("completion is informational inbox item");
        assert_eq!(item.status, InboxStatus::Pending);
        assert!(
            item.action_token.is_none(),
            "informational items are not actionable"
        );

        std::thread::sleep(Duration::from_millis(20));
        let listed = bus.inbox(None);
        assert_eq!(listed[0].status, InboxStatus::Pending);
        assert!(bus.inbox(Some(InboxStatus::Expired)).is_empty());
    }

    #[test]
    fn non_actionable_events_do_not_enter_the_inbox() {
        let bus = Bus::new(8);
        let (_event, item) = bus.publish_with_inbox(delta(0));
        assert!(item.is_none());
        assert!(bus.inbox(None).is_empty());
    }

    #[test]
    fn republishing_the_same_request_does_not_mint_a_second_token() {
        let bus = Bus::new(8);
        let (_e1, first) = bus.publish_with_inbox(permission("rm -rf build"));
        let (_e2, second) = bus.publish_with_inbox(permission("rm -rf build"));
        let first = first.unwrap();
        let second = second.unwrap();
        assert_eq!(first.id, second.id);
        assert_eq!(first.action_token, second.action_token);
        assert_eq!(bus.inbox(None).len(), 1);
    }

    #[test]
    fn wrong_token_and_unknown_id_are_distinguished() {
        let bus = Bus::new(8);
        let (_event, item) = bus.publish_with_inbox(permission("git push --force"));
        let item = item.unwrap();
        assert_eq!(
            bus.claim(&item.id, "not-the-token", "deny").unwrap_err(),
            ClaimError::BadToken
        );
        let unknown = InboxId::derive(&openpaw_protocol::EventId::derive(&session(), "nope"));
        assert_eq!(
            bus.claim(&unknown, "x", "deny").unwrap_err(),
            ClaimError::Unknown
        );
        // The failed claims left the item usable.
        assert_eq!(
            bus.peek(&item.id).unwrap().item.status,
            InboxStatus::Pending
        );
    }

    #[test]
    fn expired_tokens_expire_the_item() {
        let bus = Bus::with_token_ttl(8, Duration::from_millis(10));
        let (_event, item) = bus.publish_with_inbox(permission("rm -rf build"));
        let item = item.unwrap();
        let token = item.action_token.clone().unwrap();
        std::thread::sleep(Duration::from_millis(20));

        assert_eq!(
            bus.claim(&item.id, &token, "approve_once").unwrap_err(),
            ClaimError::Expired
        );
        assert_eq!(
            bus.inbox(Some(InboxStatus::Expired)).len(),
            1,
            "the listing reflects expiry"
        );
        assert!(bus.inbox(Some(InboxStatus::Pending)).is_empty());
        assert!(bus.pending_counts().is_empty());
    }

    #[test]
    fn restore_puts_a_claimed_item_back_with_a_fresh_token() {
        let bus = Bus::new(8);
        let (_event, item) = bus.publish_with_inbox(permission("rm -rf build"));
        let item = item.unwrap();
        let token = item.action_token.clone().unwrap();

        let claimed = bus.claim(&item.id, &token, "approve_once").unwrap();
        bus.restore(claimed);

        let restored = bus.peek(&item.id).unwrap();
        assert_eq!(restored.item.status, InboxStatus::Pending);
        assert!(restored.item.resolution.is_none());
        let fresh = restored.item.action_token.clone().unwrap();
        assert_ne!(fresh, token, "the leaked token is not reinstated");
        assert!(bus.claim(&item.id, &fresh, "deny").is_ok());
    }

    #[test]
    fn pending_counts_track_unresolved_items_per_session() {
        let bus = Bus::new(8);
        let (_e, item) = bus.publish_with_inbox(permission("rm -rf build"));
        let item = item.unwrap();
        assert_eq!(bus.pending_counts().get(&session()).copied(), Some(1));

        let token = item.action_token.clone().unwrap();
        bus.claim(&item.id, &token, "deny").unwrap();
        assert!(bus.pending_counts().is_empty());
        assert_eq!(bus.inbox(Some(InboxStatus::Resolved)).len(), 1);
    }
}
