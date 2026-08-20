//! Daemon configuration: `<state_dir>/config.toml` plus CLI overrides.

use std::net::IpAddr;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use openpaw_protocol::AgentKind;
use serde::{Deserialize, Serialize};

/// Environment variable that relocates the whole state directory.
pub const STATE_DIR_ENV: &str = "OPENPAW_STATE_DIR";

/// Resolve the state directory: `$OPENPAW_STATE_DIR`, else `~/.openpaw`.
pub fn default_state_dir() -> Result<PathBuf> {
    if let Some(dir) = std::env::var_os(STATE_DIR_ENV) {
        let dir = PathBuf::from(dir);
        if !dir.as_os_str().is_empty() {
            return Ok(dir);
        }
    }
    let home =
        dirs::home_dir().context("cannot determine a home directory; set OPENPAW_STATE_DIR")?;
    Ok(home.join(".openpaw"))
}

/// Which adapters the supervisor is allowed to poll.
///
/// Only agents with an implemented adapter get a switch; a toggle for an agent
/// that cannot be parsed would be a lie in the config file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AgentToggles {
    /// Claude Code transcripts under `~/.claude/projects`.
    pub claude_code: bool,
    /// Codex rollout files under `~/.codex/sessions`.
    pub codex: bool,
    /// OpenCode storage under `~/.local/share/opencode`.
    pub opencode: bool,
    /// Terminal marker ingestion for agents without a native format.
    pub generic: bool,
}

impl Default for AgentToggles {
    fn default() -> Self {
        Self {
            claude_code: true,
            codex: true,
            opencode: true,
            generic: true,
        }
    }
}

impl AgentToggles {
    /// True when `kind` should be polled. Agents without an adapter are never
    /// enabled, whatever the file says.
    pub fn enabled(&self, kind: AgentKind) -> bool {
        match kind {
            AgentKind::ClaudeCode => self.claude_code,
            AgentKind::Codex => self.codex,
            AgentKind::OpenCode => self.opencode,
            AgentKind::Generic => self.generic,
            _ => false,
        }
    }
}

/// Everything the daemon reads at boot.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    /// Address to bind. Loopback unless the operator opts out explicitly.
    pub bind: IpAddr,
    /// TCP port to bind.
    pub port: u16,
    /// Repository roots the phone may read. Nothing outside these is reachable.
    pub repos: Vec<PathBuf>,
    /// Loopback ports the preview proxy may dial.
    pub preview_ports: Vec<u16>,
    /// Cap on a single blob read.
    pub max_blob_bytes: u64,
    /// Cap on a single upload.
    pub max_upload_bytes: u64,
    /// Adapter switches.
    pub agents: AgentToggles,
    /// Sessions older than this are not discovered.
    pub session_max_age_days: u64,
    /// Supervisor poll cadence in milliseconds.
    pub poll_interval_ms: u64,
    /// How long a hook request may block waiting for a decision from the phone.
    /// `0` means never block, so a phone-less operator is never stuck.
    pub hook_wait_ms: u64,
    /// Events retained per session for `after_seq` replay.
    pub ring_capacity: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            bind: IpAddr::from([127, 0, 0, 1]),
            port: 8787,
            repos: Vec::new(),
            preview_ports: vec![3000, 5173, 8000, 8080],
            max_blob_bytes: 2 * 1024 * 1024,
            max_upload_bytes: 16 * 1024 * 1024,
            agents: AgentToggles::default(),
            session_max_age_days: 7,
            poll_interval_ms: 750,
            hook_wait_ms: 0,
            ring_capacity: 2000,
        }
    }
}

impl Config {
    /// Read `<state_dir>/config.toml`. A missing file yields the defaults; a
    /// malformed file is an error, because silently ignoring a typo in `repos`
    /// would silently reduce what the operator thinks they exposed.
    pub fn load(state_dir: &Path) -> Result<Config> {
        let path = state_dir.join("config.toml");
        match std::fs::read_to_string(&path) {
            Ok(text) => {
                toml::from_str(&text).with_context(|| format!("parsing {}", path.display()))
            }
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(Config::default()),
            Err(err) => Err(err).with_context(|| format!("reading {}", path.display())),
        }
    }

    /// Reject a non-loopback bind unless the operator accepted the risk.
    ///
    /// The daemon has no remote-exec endpoint, but it does serve file contents
    /// and approve/deny authority, so exposing it to a LAN is a real decision.
    pub fn validate(&self, risk_accepted: bool) -> Result<()> {
        if self.bind.is_loopback() {
            return Ok(());
        }
        anyhow::ensure!(
            risk_accepted,
            "refusing to bind {}: openpaw-host is loopback-only by design. \
             Reach it from a phone through SSH port forwarding. \
             Pass --i-understand-the-risk to override.",
            self.bind
        );
        tracing::warn!(
            bind = %self.bind,
            port = self.port,
            "openpaw-host is bound to a NON-LOOPBACK address. Every device that can \
             reach this port can attempt pairing, and a paired device can read file \
             contents and approve agent actions. Use SSH port forwarding instead."
        );
        Ok(())
    }

    /// Preview policy derived from this config.
    pub fn preview_policy(&self) -> openpaw_preview::PreviewPolicy {
        openpaw_preview::PreviewPolicy {
            allowed_ports: self.preview_ports.clone(),
            max_body_bytes: self.max_upload_bytes as usize,
        }
    }

    /// Poll cadence, floored so a bad config cannot spin the CPU.
    pub fn poll_interval(&self) -> std::time::Duration {
        std::time::Duration::from_millis(self.poll_interval_ms.max(50))
    }

    /// Maximum hook block duration.
    pub fn hook_wait(&self) -> std::time::Duration {
        std::time::Duration::from_millis(self.hook_wait_ms)
    }

    /// Discovery age window.
    pub fn session_max_age(&self) -> time::Duration {
        time::Duration::days(self.session_max_age_days.max(1) as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_loopback_and_pass_validation() {
        let config = Config::default();
        assert!(config.bind.is_loopback());
        assert_eq!(config.port, 8787);
        assert_eq!(config.preview_ports, vec![3000, 5173, 8000, 8080]);
        assert_eq!(config.max_blob_bytes, 2 * 1024 * 1024);
        assert_eq!(config.max_upload_bytes, 16 * 1024 * 1024);
        assert_eq!(config.session_max_age_days, 7);
        assert_eq!(config.ring_capacity, 2000);
        assert_eq!(config.hook_wait_ms, 0);
        config.validate(false).unwrap();
    }

    #[test]
    fn non_loopback_bind_requires_explicit_risk_acceptance() {
        let config = Config {
            bind: IpAddr::from([0, 0, 0, 0]),
            ..Config::default()
        };
        let err = config.validate(false).unwrap_err().to_string();
        assert!(err.contains("loopback-only"), "unexpected error: {err}");
        config.validate(true).unwrap();
    }

    #[test]
    fn partial_toml_keeps_defaults_for_absent_keys() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("config.toml"),
            "port = 9000\npreview_ports = [4321]\n\n[agents]\ncodex = false\n",
        )
        .unwrap();
        let config = Config::load(dir.path()).unwrap();
        assert_eq!(config.port, 9000);
        assert_eq!(config.preview_ports, vec![4321]);
        assert_eq!(config.max_blob_bytes, Config::default().max_blob_bytes);
        assert!(!config.agents.enabled(AgentKind::Codex));
        assert!(config.agents.enabled(AgentKind::ClaudeCode));
    }

    #[test]
    fn missing_config_file_is_defaults_but_malformed_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(Config::load(dir.path()).unwrap(), Config::default());
        std::fs::write(dir.path().join("config.toml"), "port = \"not a number\"").unwrap();
        assert!(Config::load(dir.path()).is_err());
    }

    #[test]
    fn agents_without_an_adapter_are_never_enabled() {
        let toggles = AgentToggles::default();
        for kind in [
            AgentKind::GeminiCli,
            AgentKind::CursorCli,
            AgentKind::KimiCli,
            AgentKind::QwenCode,
        ] {
            assert!(!toggles.enabled(kind));
        }
    }
}
