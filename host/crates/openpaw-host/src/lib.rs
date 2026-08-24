//! `openpaw-host` — the local-first daemon behind the OpenPaw app.
//!
//! The daemon watches the transcripts that terminal coding agents already write,
//! normalizes them into the protocol in `protocol/json-schema/event.schema.json`,
//! and serves them over an authenticated loopback HTTP API. The phone reaches it
//! through SSH port forwarding; there is no cloud hop and no inbound port.
//!
//! What it deliberately does **not** offer is a way to run a command. The app
//! already owns an authenticated SSH/PTY channel for that. Adding remote exec
//! here would widen the blast radius of a stolen device token from "can approve
//! what an agent already proposed" to "can do anything", for no new capability.
//!
//! # Layout
//!
//! * [`config`] — `config.toml` plus CLI overrides.
//! * [`state`] — paired devices, adapter cursors, file permissions.
//! * [`auth`] — bearer + HMAC verification, capabilities, pairing codes.
//! * [`bus`] — event fan-out, replay backlog, action tokens.
//! * [`supervisor`] — the polling loop and the session registry.
//! * [`api`] — the HTTP surface.
//! * [`audit`] — the append-only decision log.
//! * [`uploads`] — the single filesystem write path.

#![warn(missing_docs)]

pub mod api;
pub mod audit;
pub mod auth;
pub mod bus;
pub mod config;
pub mod pairing_link;
pub mod state;
pub mod supervisor;
pub mod uploads;
pub mod workspaces;

use std::path::PathBuf;
use std::sync::Arc;

use time::OffsetDateTime;

pub use api::router;
pub use config::Config;

/// Protocol version this daemon speaks.
pub const PROTOCOL_VERSION: &str = openpaw_protocol::PROTOCOL_VERSION;
/// Daemon version, from the crate manifest.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Shared handles every route and the supervisor need.
///
/// Cheap to clone: everything behind it is an `Arc`.
#[derive(Clone)]
pub struct AppState {
    /// Effective configuration.
    pub config: Arc<Config>,
    /// Persistent state: devices and cursors.
    pub store: Arc<state::Store>,
    /// Event fan-out, replay and inbox.
    pub bus: Arc<bus::Bus>,
    /// Append-only audit log.
    pub audit: Arc<audit::Audit>,
    /// Replay protection for signed requests.
    pub nonces: Arc<auth::NonceCache>,
    /// Outstanding pairing codes.
    pub pairing: Arc<auth::PairingCodes>,
    /// Short-lived pairing response recovery with per-entry timed cleanup.
    pub pair_recovery: Arc<api::pair::PairRecovery>,
    /// Loopback preview proxy.
    pub proxy: Arc<openpaw_preview::Proxy>,
    /// Dynamic workspace registry.
    pub workspaces: Arc<workspaces::WorkspaceRegistry>,
    /// Provider authorization and token manager.
    pub provider_manager: Arc<api::providers::ProviderManager>,
    /// Repository import progress manager.
    pub repo_imports: Arc<api::repo_imports::RepoImportManager>,
    /// Live session registry.
    pub sessions: Arc<supervisor::Registry>,
    /// Fixed read-only Tailscale status runner.
    pub tailscale: Arc<dyn api::tailscale::TailscaleStatusRunner>,
    /// Home directory adapters discover sessions under.
    pub home: PathBuf,
    /// Boot time, reported by `/v1/health`.
    pub started_at: OffsetDateTime,
}

impl AppState {
    /// Assemble state from the pieces resolved at boot.
    pub fn new(
        config: Config,
        store: state::Store,
        roots: openpaw_files::Roots,
        home: PathBuf,
    ) -> AppState {
        let audit = audit::Audit::new(store.state_dir());
        let proxy = openpaw_preview::Proxy::new(config.preview_policy());
        let bus = bus::Bus::new(config.ring_capacity);
        bus.hydrate_dismissed(store.dismissed_inbox_ids());
        let workspace_registry = Arc::new(
            workspaces::WorkspaceRegistry::open_with_roots(store.state_dir(), &roots)
                .expect("workspace registry"),
        );
        let provider_manager = Arc::new(api::providers::ProviderManager::new(
            store.state_dir(),
            config.providers.clone(),
        ));
        let repo_imports = Arc::new(
            api::repo_imports::RepoImportManager::open(store.state_dir()).expect("repo imports"),
        );
        AppState {
            config: Arc::new(config),
            store: Arc::new(store),
            bus: Arc::new(bus),
            audit: Arc::new(audit),
            nonces: Arc::new(auth::NonceCache::new()),
            pairing: Arc::new(auth::PairingCodes::new()),
            pair_recovery: Arc::new(api::pair::PairRecovery::new()),
            proxy: Arc::new(proxy),
            workspaces: workspace_registry,
            provider_manager,
            repo_imports,
            sessions: Arc::new(supervisor::Registry::new()),
            tailscale: api::tailscale::default_runner(),
            home,
            started_at: OffsetDateTime::now_utc(),
        }
    }

    /// Current repository roots snapshot.
    pub fn roots(&self) -> Arc<openpaw_files::Roots> {
        self.workspaces.snapshot()
    }

    /// Publish an event: fan it out, fold it into the session registry, and
    /// project any inbox item it carries.
    ///
    /// This is the *only* way events should enter the system. Publishing to the
    /// bus without updating the registry leaves a session invisible to
    /// `GET /v1/sessions` even though its events are streaming, and that split is
    /// exactly the kind of bug a second call site forgets to avoid.
    pub fn publish(
        &self,
        event: openpaw_protocol::Event,
    ) -> (
        Arc<openpaw_protocol::Event>,
        Option<openpaw_protocol::InboxItem>,
    ) {
        let (stored, item) = self.bus.publish_with_inbox(event);
        self.sessions.observe_event(&stored);
        (stored, item)
    }
}

impl std::fmt::Debug for AppState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never derive Debug here: `store` holds the hook token and device key
        // material, and an accidental `{:?}` in a log line would publish it.
        f.debug_struct("AppState")
            .field("bind", &self.config.bind)
            .field("port", &self.config.port)
            .field("sessions", &self.sessions.len())
            .field("started_at", &self.started_at)
            .finish_non_exhaustive()
    }
}
