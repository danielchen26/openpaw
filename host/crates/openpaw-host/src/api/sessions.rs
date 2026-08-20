//! `GET /v1/sessions` — what the app's session list is built from.

use axum::Json;
use axum::extract::State;

use crate::AppState;
use crate::supervisor::SessionSummary;

/// `GET /v1/sessions`, newest activity first.
///
/// The pending-inbox count is read from the bus rather than stored on the
/// registry, so a resolved approval changes a session's state on the next read
/// with no extra bookkeeping.
pub async fn list(State(app): State<AppState>) -> Json<Vec<SessionSummary>> {
    let pending = app.bus.pending_counts();
    Json(app.sessions.summaries(&pending))
}
