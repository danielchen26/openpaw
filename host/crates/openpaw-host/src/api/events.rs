//! `GET /v1/events` — the Server-Sent Events stream.
//!
//! A phone on a train loses its tunnel constantly. The contract that makes that
//! survivable is: reconnect with `after_seq`, receive the backlog you missed,
//! then continue live, with no gap and no duplicate.
//!
//! The ordering that guarantees it is subtle enough to state plainly: subscribe
//! to the live channel *first*, then snapshot the backlog. Doing it the other way
//! round would drop any event published between the snapshot and the subscribe.
//! Subscribing first can only produce the harmless failure — an event in both
//! halves — which the sequence high-water mark filters out.

use std::collections::HashMap;
use std::convert::Infallible;
use std::time::Duration;

use axum::extract::{Query, State};
use axum::response::sse::{Event as SseEvent, KeepAlive, Sse};
use futures::StreamExt;
use futures::stream::Stream;
use openpaw_protocol::SessionId;
use serde::Deserialize;
use tokio::sync::broadcast::error::RecvError;

use crate::AppState;
use crate::api::ApiError;

/// Comment frames every 15 s keep the tunnel and any intermediary from deciding
/// an idle stream is dead.
const KEEP_ALIVE: Duration = Duration::from_secs(15);

/// Query parameters for the event stream.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct EventQuery {
    /// Restrict to one session.
    pub session: Option<String>,
    /// Exclusive lower bound on `seq`.
    pub after_seq: Option<u64>,
}

/// `GET /v1/events`.
pub async fn stream(
    State(app): State<AppState>,
    Query(query): Query<EventQuery>,
) -> Result<Sse<impl Stream<Item = Result<SseEvent, Infallible>>>, ApiError> {
    let session = match query
        .session
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        Some(raw) => Some(
            raw.parse::<SessionId>()
                .map_err(|err| ApiError::bad_request(format!("invalid session id: {err}")))?,
        ),
        None => None,
    };
    let after_seq = query.after_seq;

    // Order matters: subscribe, then snapshot. See the module comment.
    let receiver = app.bus.subscribe();
    let backlog = app.bus.replay(session.as_ref(), after_seq);

    // Highest seq already delivered per session. Because the bus assigns seq
    // monotonically per session, a live event at or below this mark is exactly a
    // duplicate of something in the backlog, and anything above it is genuinely
    // new. No id set, no unbounded memory.
    let mut delivered: HashMap<SessionId, u64> = HashMap::new();
    for event in &backlog {
        let slot = delivered
            .entry(event.session_id.clone())
            .or_insert(event.seq);
        *slot = (*slot).max(event.seq);
    }

    let live = futures::stream::unfold(receiver, |mut receiver| async move {
        loop {
            match receiver.recv().await {
                Ok(event) => return Some((event, receiver)),
                // A lagged subscriber lost events it can only recover by
                // reconnecting with `after_seq`; keep the stream alive rather
                // than dropping it silently.
                Err(RecvError::Lagged(skipped)) => {
                    tracing::warn!(skipped, "event subscriber lagged behind the fan-out buffer");
                }
                Err(RecvError::Closed) => return None,
            }
        }
    })
    .filter(move |event| {
        let keep = session
            .as_ref()
            .is_none_or(|want| &event.session_id == want)
            && after_seq.is_none_or(|after| event.seq > after)
            && delivered
                .get(&event.session_id)
                .is_none_or(|&high| event.seq > high);
        futures::future::ready(keep)
    });

    let stream = futures::stream::iter(backlog).chain(live).map(|event| {
        // `event`/`id` let a client dispatch on type and resume by id without
        // parsing the payload.
        let frame = SseEvent::default()
            .event(event.kind().as_str())
            .id(event.event_id.as_ref());
        Ok(match frame.json_data(&*event) {
            Ok(frame) => frame,
            Err(err) => {
                // Serializing a normalized event cannot fail in practice; if it
                // ever does, say so on the stream instead of tearing it down.
                tracing::error!(%err, event_id = %event.event_id, "could not serialize event");
                SseEvent::default().comment("unserializable event skipped")
            }
        })
    });

    Ok(Sse::new(stream).keep_alive(KeepAlive::new().interval(KEEP_ALIVE)))
}
