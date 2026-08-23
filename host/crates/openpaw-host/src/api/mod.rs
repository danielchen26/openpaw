//! The HTTP surface.
//!
//! Routes are grouped by the capability they require, and each group carries the
//! [`crate::auth::authorize`] middleware for that capability. A route cannot
//! accidentally end up unauthenticated: the only routers without the middleware
//! are the two public ones ([`health`], [`pair`]) and the hook ingress, which has
//! its own token check.
//!
//! There is no route that executes a command. That absence is a feature, and
//! `tests/api.rs` asserts it stays that way.

pub mod audit;
pub mod events;
pub mod health;
pub mod hooks;
pub mod inbox;
pub mod pair;
pub mod preview;
pub mod repos;
pub mod sessions;
pub mod tailscale;

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{any, get, post};
use axum::{Json, Router, middleware};
use serde_json::json;

use crate::AppState;
use crate::auth::{self, Capability};

/// A failed request, rendered as `{"error": "..."}` with a status code.
#[derive(Debug, Clone)]
pub struct ApiError {
    status: StatusCode,
    message: String,
    body: Option<serde_json::Value>,
}

impl ApiError {
    /// Error with an explicit status.
    pub fn new(status: StatusCode, message: impl Into<String>) -> ApiError {
        ApiError {
            status,
            message: message.into(),
            body: None,
        }
    }

    /// Error with a pre-shaped safe JSON body.
    pub fn json(status: StatusCode, body: serde_json::Value) -> ApiError {
        ApiError {
            status,
            message: String::new(),
            body: Some(body),
        }
    }

    /// 400.
    pub fn bad_request(message: impl Into<String>) -> ApiError {
        ApiError::new(StatusCode::BAD_REQUEST, message)
    }

    /// 403.
    pub fn forbidden(message: impl Into<String>) -> ApiError {
        ApiError::new(StatusCode::FORBIDDEN, message)
    }

    /// 404.
    pub fn not_found(message: impl Into<String>) -> ApiError {
        ApiError::new(StatusCode::NOT_FOUND, message)
    }

    /// 409.
    pub fn conflict(message: impl Into<String>) -> ApiError {
        ApiError::new(StatusCode::CONFLICT, message)
    }

    /// 413.
    pub fn too_large(message: impl Into<String>) -> ApiError {
        ApiError::new(StatusCode::PAYLOAD_TOO_LARGE, message)
    }

    /// 502.
    pub fn bad_gateway(message: impl Into<String>) -> ApiError {
        ApiError::new(StatusCode::BAD_GATEWAY, message)
    }

    /// Renders as 500. The detail is logged; the client is told only that it failed, since a
    /// filesystem error message can carry paths the caller may not read.
    pub fn internal(error: impl std::fmt::Display) -> ApiError {
        tracing::error!(error = %error, "internal error");
        ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "internal error")
    }

    /// The status this error renders as.
    pub fn status(&self) -> StatusCode {
        self.status
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        if let Some(body) = self.body {
            (self.status, Json(body)).into_response()
        } else {
            (self.status, Json(json!({ "error": self.message }))).into_response()
        }
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(err: anyhow::Error) -> ApiError {
        ApiError::internal(format!("{err:#}"))
    }
}

impl From<tokio::task::JoinError> for ApiError {
    fn from(err: tokio::task::JoinError) -> ApiError {
        ApiError::internal(err)
    }
}

/// Mount every route with its capability requirement.
pub fn router(app: AppState) -> Router {
    // Unauthenticated by design: `health` is how a client discovers whether the
    // daemon is even there, and `pair` is the bootstrap that hands out the first
    // credential. `pair` is safe because it consumes a short-lived code the
    // operator read off their own terminal.
    let public = Router::new()
        .route("/v1/health", get(health::health))
        .route("/v1/pair", post(pair::pair));

    // Authenticated by the file-backed hook token: local agent hooks and the CLI.
    let local = Router::new()
        .route("/v1/hooks/{agent}", post(hooks::ingest))
        .route("/v1/pairing-code", post(pair::issue_code))
        .layer(middleware::from_fn_with_state(
            app.clone(),
            auth::authorize_hook,
        ));

    let sessions = guard(
        &app,
        Capability::SessionsRead,
        Router::new().route("/v1/sessions", get(sessions::list)),
    );
    let events = guard(
        &app,
        Capability::EventsRead,
        Router::new().route("/v1/events", get(events::stream)),
    );
    let inbox = guard(
        &app,
        Capability::InboxRead,
        Router::new()
            .route("/v1/inbox", get(inbox::list))
            .route("/v1/audit", get(audit::list)),
    );
    let approvals = guard(
        &app,
        Capability::ApprovalsWrite,
        Router::new().route("/v1/inbox/{id}/resolve", post(inbox::resolve)),
    );
    let inbox_write = guard(
        &app,
        Capability::InboxWrite,
        Router::new().route("/v1/inbox/{id}/dismiss", post(inbox::dismiss)),
    );
    let repos = guard(
        &app,
        Capability::ReposRead,
        Router::new()
            .route("/v1/repos", get(repos::list))
            .route("/v1/repos/{repo}/status", get(repos::status))
            .route("/v1/repos/{repo}/diff", get(repos::diff))
            .route("/v1/repos/{repo}/tree", get(repos::tree))
            .route("/v1/repos/{repo}/search", get(repos::search)),
    );
    let files = guard(
        &app,
        Capability::FilesRead,
        Router::new().route("/v1/repos/{repo}/blob", get(repos::blob)),
    );
    let uploads = guard(
        &app,
        Capability::UploadsWrite,
        Router::new().route("/v1/uploads", post(crate::uploads::upload)),
    );
    let preview = guard(
        &app,
        Capability::PreviewProxy,
        Router::new()
            // Three routes, because `{*rest}` matches one-or-more segments: without
            // the middle one, `/v1/preview/5173/` — the site root, and the single
            // most common preview URL — would 404.
            .route("/v1/preview/{port}", any(preview::proxy))
            .route("/v1/preview/{port}/", any(preview::proxy))
            .route("/v1/preview/{port}/{*rest}", any(preview::proxy)),
    );

    let tailscale = guard(
        &app,
        Capability::DevicesRead,
        Router::new().route("/v1/tailscale/devices", get(tailscale::devices)),
    );

    public
        .merge(local)
        .merge(sessions)
        .merge(events)
        .merge(inbox)
        .merge(approvals)
        .merge(inbox_write)
        .merge(repos)
        .merge(files)
        .merge(uploads)
        .merge(preview)
        .merge(tailscale)
        .layer(tower_http::trace::TraceLayer::new_for_http())
        .with_state(app)
}

/// Wrap `routes` in the two-factor check for `capability`.
fn guard(app: &AppState, capability: Capability, routes: Router<AppState>) -> Router<AppState> {
    routes.layer(middleware::from_fn_with_state(
        (app.clone(), capability),
        auth::authorize,
    ))
}

/// Map an [`openpaw_files::FileError`] onto a status.
pub fn file_error(err: openpaw_files::FileError) -> ApiError {
    use openpaw_files::FileError;
    let message = err.to_string();
    match err {
        FileError::UnknownRoot | FileError::NotFound => ApiError::not_found(message),
        FileError::Escape | FileError::NotAFile | FileError::NotADirectory => {
            ApiError::bad_request(message)
        }
        FileError::TooLarge { .. } => ApiError::too_large(message),
        FileError::Io(_) => ApiError::internal(message),
    }
}

/// Map an [`openpaw_git::GitError`] onto a status.
pub fn git_error(err: openpaw_git::GitError) -> ApiError {
    use openpaw_git::GitError;
    let message = err.to_string();
    match err {
        GitError::NotARepository | GitError::NotFound => ApiError::not_found(message),
        GitError::InvalidRef(_) | GitError::NotAFile => ApiError::bad_request(message),
        GitError::Path(inner) => file_error(inner),
        _ => ApiError::internal(message),
    }
}

/// Map a [`openpaw_preview::PreviewError`] onto a status.
pub fn preview_error(err: openpaw_preview::PreviewError) -> ApiError {
    use openpaw_preview::PreviewError;
    let message = err.to_string();
    match err {
        // A port outside the allowlist is a policy decision, not a missing thing:
        // saying 403 tells the client the port exists as a concept but is closed.
        PreviewError::PortNotAllowed(_) => ApiError::forbidden(message),
        PreviewError::Unreachable { .. } => ApiError::bad_gateway(message),
        PreviewError::TooLarge { .. } => ApiError::too_large(message),
        PreviewError::Malformed(_) => ApiError::bad_request(message),
        PreviewError::WebSocket(_) => ApiError::bad_gateway(message),
    }
}
