//! `GET /v1/audit` — reading back the decision log.

use axum::Json;
use axum::extract::{Query, State};
use serde::Deserialize;

use crate::AppState;
use crate::api::ApiError;
use crate::audit::AuditEntry;

/// Default number of entries returned.
const DEFAULT_LIMIT: usize = 100;
/// Hard cap. The log is append-only and unbounded; a phone does not need all of
/// it, and reading it all would mean loading the whole file into memory.
const MAX_LIMIT: usize = 1000;

/// `?limit=` for the audit log.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct AuditQuery {
    /// Maximum entries to return, newest first.
    pub limit: Option<usize>,
}

/// `GET /v1/audit`, newest first.
///
/// Gated on `inbox.read` rather than a capability of its own: the log records
/// which commands were approved, which is the same information an inbox reader
/// already has, so a separate capability would be a distinction without a
/// difference.
pub async fn list(
    State(app): State<AppState>,
    Query(query): Query<AuditQuery>,
) -> Result<Json<Vec<AuditEntry>>, ApiError> {
    let limit = query.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);
    let entries = app.audit.tail(limit).await.map_err(ApiError::internal)?;
    Ok(Json(entries))
}
