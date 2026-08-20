//! `openpaw-host` binary: the daemon plus the two operator commands that pair a
//! device.

use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use http_body_util::BodyExt;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use openpaw_host::api::pair::IssueResponse;
use openpaw_host::auth::{HOOK_TOKEN_HEADER, Profile};
use openpaw_host::{AppState, Config, config, state, supervisor};
use tracing_subscriber::EnvFilter;

/// Local-first control plane for terminal coding agents.
#[derive(Debug, Parser)]
#[command(name = "openpaw-host", version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    #[command(flatten)]
    overrides: Overrides,
}

/// Settings that override `config.toml` for this run.
#[derive(Debug, Clone, clap::Args)]
struct Overrides {
    /// State directory. Defaults to `$OPENPAW_STATE_DIR`, else `~/.openpaw`.
    #[arg(long, env = "OPENPAW_STATE_DIR", global = true)]
    state_dir: Option<PathBuf>,

    /// Address to bind. Loopback unless you also pass --i-understand-the-risk.
    #[arg(long)]
    bind: Option<IpAddr>,

    /// Port to bind.
    #[arg(long)]
    port: Option<u16>,

    /// Repository root the phone may read. Repeatable.
    #[arg(long = "repo", value_name = "PATH")]
    repos: Vec<PathBuf>,

    /// Loopback port the preview proxy may dial. Repeatable.
    #[arg(long = "preview-port", value_name = "PORT")]
    preview_ports: Vec<u16>,

    /// Supervisor poll cadence in milliseconds.
    #[arg(long)]
    poll_interval_ms: Option<u64>,

    /// How long a hook may block waiting for a decision. 0 never blocks.
    #[arg(long)]
    hook_wait_ms: Option<u64>,

    /// Permit binding a non-loopback address. Read the warning it prints.
    #[arg(long)]
    i_understand_the_risk: bool,
}

impl Overrides {
    fn apply(&self, config: &mut Config) {
        if let Some(bind) = self.bind {
            config.bind = bind;
        }
        if let Some(port) = self.port {
            config.port = port;
        }
        if !self.repos.is_empty() {
            config.repos = self.repos.clone();
        }
        if !self.preview_ports.is_empty() {
            config.preview_ports = self.preview_ports.clone();
        }
        if let Some(interval) = self.poll_interval_ms {
            config.poll_interval_ms = interval;
        }
        if let Some(wait) = self.hook_wait_ms {
            config.hook_wait_ms = wait;
        }
    }
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Run the daemon. This is the default.
    Serve,

    /// Mint a pairing code for a named device and print it.
    Pair {
        /// Label for the device that will redeem the code.
        #[arg(long)]
        name: String,

        /// Capability profile to grant.
        #[arg(long, default_value = "operator")]
        profile: Profile,
    },

    /// Mint an unnamed pairing code and print it.
    PairingCode {
        /// Capability profile to grant.
        #[arg(long, default_value = "operator")]
        profile: Profile,
    },

    /// Print the resolved configuration and state paths.
    Doctor,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_env("OPENPAW_LOG").unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_target(false)
        .init();

    let state_dir = match &cli.overrides.state_dir {
        Some(dir) => dir.clone(),
        None => config::default_state_dir()?,
    };

    match cli.command.unwrap_or(Command::Serve) {
        Command::Serve => serve(&state_dir, &cli.overrides).await,
        Command::Pair { name, profile } => {
            request_code(&state_dir, &cli.overrides, Some(name), profile).await
        }
        Command::PairingCode { profile } => {
            request_code(&state_dir, &cli.overrides, None, profile).await
        }
        Command::Doctor => doctor(&state_dir, &cli.overrides),
    }
}

/// Boot the daemon.
async fn serve(state_dir: &std::path::Path, overrides: &Overrides) -> Result<()> {
    let mut config = Config::load(state_dir)?;
    overrides.apply(&mut config);
    config.validate(overrides.i_understand_the_risk)?;

    let store = state::Store::open(state_dir)?;
    let roots = openpaw_files::Roots::new(config.repos.clone())
        .context("resolving the configured repository roots")?;
    let home = dirs::home_dir().context("cannot determine a home directory")?;

    let address = SocketAddr::new(config.bind, config.port);
    let app = AppState::new(config, store, roots, home);

    let listener = tokio::net::TcpListener::bind(address)
        .await
        .with_context(|| format!("binding {address}"))?;
    let bound = listener.local_addr()?;

    tracing::info!(
        version = openpaw_host::VERSION,
        protocol = openpaw_host::PROTOCOL_VERSION,
        address = %bound,
        repos = app.roots.names().len(),
        state_dir = %app.store.state_dir().display(),
        "openpaw-host listening"
    );
    tracing::info!("pair a device with: openpaw-host pair --name <label>");

    let supervisor = supervisor::spawn(app.clone());
    let router = openpaw_host::router(app);

    let result = axum::serve(listener, router)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("serving");
    supervisor.abort();
    result
}

/// Ask the running daemon for a pairing code and print it.
///
/// The CLI talks to the daemon rather than minting the code itself: the daemon is
/// the only process that will still be alive when the phone redeems it. Because
/// the request travels over loopback with the hook token, the operator never has
/// to copy a secret by hand.
async fn request_code(
    state_dir: &std::path::Path,
    overrides: &Overrides,
    name: Option<String>,
    profile: Profile,
) -> Result<()> {
    let mut config = Config::load(state_dir)?;
    overrides.apply(&mut config);

    let hook_token = std::fs::read_to_string(state_dir.join("hook-token"))
        .with_context(|| {
            format!(
                "reading {}/hook-token — is openpaw-host running?",
                state_dir.display()
            )
        })?
        .trim()
        .to_owned();

    // Always loopback: the daemon may be bound to another address, but its own
    // CLI has no business reaching it over the network.
    let address = SocketAddr::new(IpAddr::from([127, 0, 0, 1]), config.port);
    let body = serde_json::to_vec(&serde_json::json!({
        "device_name": name,
        "profile": profile,
    }))?;

    let client: Client<_, axum::body::Body> = Client::builder(TokioExecutor::new()).build_http();
    let request = hyper::Request::builder()
        .method(hyper::Method::POST)
        .uri(format!("http://{address}/v1/pairing-code"))
        .header(hyper::header::CONTENT_TYPE, "application/json")
        .header(HOOK_TOKEN_HEADER, &hook_token)
        .body(axum::body::Body::from(body))?;

    let response = client.request(request).await.with_context(|| {
        format!("cannot reach openpaw-host at {address}; start it with `openpaw-host serve`")
    })?;
    let status = response.status();
    let bytes = response.into_body().collect().await?.to_bytes();
    anyhow::ensure!(
        status.is_success(),
        "openpaw-host refused the request ({status}): {}",
        String::from_utf8_lossy(&bytes)
    );

    let issued: IssueResponse =
        serde_json::from_slice(&bytes).context("parsing the pairing-code response")?;

    // The code is the machine-readable output and goes to stdout, alone, so
    // `openpaw-host pairing-code | pbcopy` does the obvious thing. Everything a
    // human wants to read goes to stderr, where it cannot corrupt a pipe.
    eprintln!();
    eprintln!("  Profile:   {:?}", issued.profile);
    eprintln!(
        "  Valid for: {} minutes (until {})",
        issued.expires_in_seconds / 60,
        issued.expires_at
    );
    eprintln!(
        "  Enter the code below in the OpenPaw app while an SSH tunnel to port {} is up.",
        config.port
    );
    eprintln!();
    println!("{}", issued.code);
    Ok(())
}

/// Print what the daemon would use, without starting it.
fn doctor(state_dir: &std::path::Path, overrides: &Overrides) -> Result<()> {
    let mut config = Config::load(state_dir)?;
    overrides.apply(&mut config);

    println!("state dir:        {}", state_dir.display());
    println!("config:           {}/config.toml", state_dir.display());
    println!("bind:             {}:{}", config.bind, config.port);
    println!("loopback:         {}", config.bind.is_loopback());
    println!("poll interval:    {:?}", config.poll_interval());
    println!("hook wait:        {:?}", config.hook_wait());
    println!("preview ports:    {:?}", config.preview_ports);
    println!("max blob bytes:   {}", config.max_blob_bytes);
    println!("max upload bytes: {}", config.max_upload_bytes);
    println!("session max age:  {} days", config.session_max_age_days);
    println!(
        "adapters:         {:?}",
        supervisor::enabled_kinds(&config.agents)
    );
    println!("repos:");
    if config.repos.is_empty() {
        println!("  (none configured — add `repos = [\"/path/to/repo\"]` to config.toml)");
    }
    for repo in &config.repos {
        let exists = repo.join(".git").exists();
        println!(
            "  {} {}",
            repo.display(),
            if exists { "(git)" } else { "(not a work tree)" }
        );
    }
    Ok(())
}

/// Resolve on SIGINT or SIGTERM so a service manager can stop the daemon cleanly.
async fn shutdown_signal() {
    let interrupt = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut stream) => {
                stream.recv().await;
            }
            Err(err) => tracing::warn!(%err, "cannot listen for SIGTERM"),
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = interrupt => tracing::info!("interrupted; shutting down"),
        _ = terminate => tracing::info!("terminated; shutting down"),
    }
}
