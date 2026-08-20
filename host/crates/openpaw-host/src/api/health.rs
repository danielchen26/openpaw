//! `GET /v1/health` — the only route a client may call before pairing.

use std::collections::BTreeMap;

use axum::Json;
use axum::extract::State;
use openpaw_protocol::AgentKind;
use serde::{Deserialize, Serialize};

use crate::auth::Capability;
use crate::{AppState, supervisor};

/// Discovery document: what this daemon is and what it can do.
///
/// Unauthenticated on purpose. It carries no session data, no paths and no
/// secrets — only the shape of the API — so a client can find out whether the
/// tunnel is up and whether its own build is compatible before it has a token.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthResponse {
    /// Daemon version.
    pub version: String,
    /// Event protocol version.
    pub protocol: String,
    /// Agents with an enabled adapter.
    pub agents: Vec<AgentKind>,
    /// Capability names this daemon understands.
    pub capabilities: Vec<String>,
    /// Loopback ports the preview proxy will dial. Empty means preview is off.
    pub preview_ports: Vec<u16>,
    /// `agent -> transcript format version`, for the diagnostics view.
    pub adapter_versions: BTreeMap<String, String>,
}

/// `GET /v1/health`.
pub async fn health(State(app): State<AppState>) -> Json<HealthResponse> {
    Json(HealthResponse {
        version: crate::VERSION.to_owned(),
        protocol: crate::PROTOCOL_VERSION.to_owned(),
        agents: supervisor::enabled_kinds(&app.config.agents),
        capabilities: Capability::ALL
            .iter()
            .map(|capability| capability.as_str().to_owned())
            .collect(),
        preview_ports: app.config.preview_ports.clone(),
        adapter_versions: supervisor::adapter_versions(&app.config.agents),
    })
}
