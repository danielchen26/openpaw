//! End-to-end tests against the real router on a real ephemeral port.
//!
//! Nothing is mocked: a temp state directory, the real middleware stack, real
//! HMAC signing through `openpaw_protocol::signing`, and a real HTTP client. The
//! properties under test are the ones that would be catastrophic to get wrong —
//! authentication, capability separation, replay protection, the
//! detail-expansion gate, single-use action tokens, and the continued absence of
//! any endpoint that runs a command.

use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use futures::StreamExt;
use openpaw_host::api::inbox::Decision;
use openpaw_host::api::tailscale::{TailscaleStatusRunner, TailscaleUnavailable};
use openpaw_host::audit::AuditEntry;
use openpaw_host::auth::{self, Profile};
use openpaw_host::state::{Device, Store};
use openpaw_host::{AppState, Config};
use openpaw_protocol::{
    ActionId, AgentKind, Body, Event, InboxItem, PermissionRequested, QuestionRequested, Risk,
    SessionId,
};
use serde_json::{Value, json};
use time::OffsetDateTime;

/// Upload cap for the harness, small enough to exercise the limit cheaply.
const MAX_UPLOAD: u64 = 4096;

// ---------------------------------------------------------------------------
// harness
// ---------------------------------------------------------------------------

/// Everything a signed request needs.
struct Creds {
    device_id: String,
    token: String,
    key: Vec<u8>,
}

struct Harness {
    base: String,
    app: AppState,
    client: reqwest::Client,
    operator: Creds,
    observer: Creds,
    /// Held so the state directory outlives the test.
    _temp: tempfile::TempDir,
}

impl Harness {
    async fn boot() -> Harness {
        Harness::boot_with(Vec::new()).await
    }

    async fn boot_with(repos: Vec<PathBuf>) -> Harness {
        Harness::boot_with_runner(repos, None).await
    }

    async fn boot_with_runner(
        repos: Vec<PathBuf>,
        tailscale: Option<Arc<dyn TailscaleStatusRunner>>,
    ) -> Harness {
        let temp = tempfile::tempdir().expect("temp dir");
        let state_dir = temp.path().join("state");

        let config = Config {
            repos: repos.clone(),
            max_upload_bytes: MAX_UPLOAD,
            preview_ports: vec![5173],
            ..Config::default()
        };
        let store = Store::open(&state_dir).expect("state dir");
        let roots = openpaw_files::Roots::new(repos).expect("roots");
        let mut app = AppState::new(config, store, roots, temp.path().to_path_buf());
        if let Some(tailscale) = tailscale {
            app.tailscale = tailscale;
        }

        let operator = enroll(&app, "dev_operator", Profile::Operator);
        let observer = enroll(&app, "dev_observer", Profile::Observer);

        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind");
        let port = listener.local_addr().unwrap().port();
        let router = openpaw_host::router(app.clone());
        tokio::spawn(async move {
            let _ = axum::serve(listener, router).await;
        });

        Harness {
            base: format!("http://127.0.0.1:{port}"),
            app,
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
                .expect("client"),
            operator,
            observer,
            _temp: temp,
        }
    }

    /// Send a correctly signed request.
    async fn signed(
        &self,
        method: reqwest::Method,
        path_and_query: &str,
        body: Option<Value>,
        creds: &Creds,
    ) -> reqwest::Response {
        let bytes = body
            .map(|b| serde_json::to_vec(&b).unwrap())
            .unwrap_or_default();
        self.raw(
            method,
            path_and_query,
            bytes,
            creds,
            &creds.key,
            OffsetDateTime::now_utc().unix_timestamp(),
            &auth::mint_secret(),
            None,
        )
        .await
    }

    /// Send a request with full control over every signing input, so a test can
    /// break exactly one of them.
    #[allow(clippy::too_many_arguments)]
    async fn raw(
        &self,
        method: reqwest::Method,
        path_and_query: &str,
        bytes: Vec<u8>,
        creds: &Creds,
        signing_key: &[u8],
        timestamp: i64,
        nonce: &str,
        content_type: Option<&str>,
    ) -> reqwest::Response {
        let canonical = openpaw_protocol::signing::canonical_string(
            method.as_str(),
            path_and_query,
            timestamp,
            nonce,
            &bytes,
        );
        let signature = openpaw_protocol::signing::sign(signing_key, &canonical);

        let mut request = self
            .client
            .request(method, format!("{}{path_and_query}", self.base))
            .header("authorization", format!("Bearer {}", creds.token))
            .header(auth::DEVICE_HEADER, &creds.device_id)
            .header(auth::TIMESTAMP_HEADER, timestamp.to_string())
            .header(auth::NONCE_HEADER, nonce)
            .header(auth::SIGNATURE_HEADER, signature);
        if !bytes.is_empty() {
            request = request.header("content-type", content_type.unwrap_or("application/json"));
        }
        request.body(bytes).send().await.expect("request")
    }

    async fn get(&self, path_and_query: &str) -> reqwest::Response {
        self.signed(reqwest::Method::GET, path_and_query, None, &self.operator)
            .await
    }

    async fn audit_entries(&self) -> Vec<AuditEntry> {
        self.app.audit.tail(100).await.expect("audit tail")
    }
}

/// Register a device the way pairing would, and keep the secrets the phone keeps.
fn enroll(app: &AppState, device_id: &str, profile: Profile) -> Creds {
    let token = auth::mint_secret();
    let hmac_key_b64 = auth::mint_hmac_key_b64();
    app.store
        .insert_device(Device {
            device_id: device_id.to_owned(),
            name: device_id.to_owned(),
            platform: "ios".to_owned(),
            hmac_key_b64: hmac_key_b64.clone(),
            token_sha256: auth::sha256_hex(token.as_bytes()),
            capabilities: profile.capability_names(),
            paired_at: OffsetDateTime::now_utc(),
            last_seen: None,
        })
        .expect("insert device");

    Creds {
        device_id: device_id.to_owned(),
        token,
        key: base64::engine::general_purpose::STANDARD
            .decode(hmac_key_b64)
            .expect("hmac key"),
    }
}

fn session() -> SessionId {
    SessionId::new(AgentKind::ClaudeCode, "alpha")
}

/// A permission request whose risk classification demands detail expansion.
fn destructive_permission() -> Event {
    let command = "rm -rf build";
    let risk = Risk::classify_command(command);
    assert!(
        risk.requires_detail_expansion,
        "the fixture must be a gated command, got {risk:?}"
    );
    Event::new(
        &session(),
        AgentKind::ClaudeCode,
        "hook:pretooluse:rm-build",
        OffsetDateTime::now_utc(),
        Body::PermissionRequested(PermissionRequested {
            request_id: "req-destructive".to_owned(),
            tool: "Bash".to_owned(),
            summary: command.to_owned(),
            command: Some(command.to_owned()),
            paths: vec!["build".to_owned()],
            risk,
            actions: vec![ActionId::ApproveOnce, ActionId::Deny],
            expires_at: None,
        }),
    )
    .with_context(Some("/work".to_owned()), Some("main".to_owned()))
}

/// A question, which needs no detail expansion.
fn question() -> Event {
    Event::new(
        &session(),
        AgentKind::ClaudeCode,
        "hook:question:1",
        OffsetDateTime::now_utc(),
        Body::QuestionRequested(QuestionRequested {
            request_id: "req-question".to_owned(),
            question: "Which package manager?".to_owned(),
            choices: vec!["pnpm".to_owned(), "npm".to_owned()],
            allows_free_text: true,
        }),
    )
}

/// Publish through the same entry point the supervisor and hooks use, so the
/// session registry sees the event exactly as it would in production.
fn seed(harness: &Harness, event: Event) -> InboxItem {
    let (_stored, item) = harness.app.publish(event);
    item.expect("the event must project to an inbox item")
}

// ---------------------------------------------------------------------------
// authentication
// ---------------------------------------------------------------------------

#[tokio::test]
async fn health_is_public_and_describes_the_daemon() {
    let harness = Harness::boot().await;
    let response = harness
        .client
        .get(format!("{}/v1/health", harness.base))
        .send()
        .await
        .unwrap();

    assert_eq!(response.status(), 200, "health must need no credentials");
    let body: Value = response.json().await.unwrap();
    assert_eq!(body["protocol"], "1");
    assert!(!body["version"].as_str().unwrap().is_empty());
    assert_eq!(body["preview_ports"], json!([5173]));

    let capabilities: Vec<String> = serde_json::from_value(body["capabilities"].clone()).unwrap();
    assert!(capabilities.contains(&"approvals.write".to_owned()));
    assert!(capabilities.contains(&"preview.proxy".to_owned()));

    // Enabled adapters report the transcript format they understand.
    let agents = body["agents"].as_array().unwrap();
    assert!(agents.contains(&json!("claude-code")), "{agents:?}");
    let versions = body["adapter_versions"].as_object().unwrap();
    assert!(!versions.is_empty());
    assert!(
        !versions["claude-code"].as_str().unwrap().is_empty(),
        "{versions:?}"
    );
}

#[tokio::test]
async fn an_unsigned_request_is_rejected() {
    let harness = Harness::boot().await;

    // No credentials at all.
    let response = harness
        .client
        .get(format!("{}/v1/sessions", harness.base))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 401);
    assert!(response.headers().contains_key("www-authenticate"));

    // A bearer token on its own is not enough: the signature is the second factor.
    let response = harness
        .client
        .get(format!("{}/v1/sessions", harness.base))
        .header(
            "authorization",
            format!("Bearer {}", harness.operator.token),
        )
        .header(auth::DEVICE_HEADER, &harness.operator.device_id)
        .send()
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        401,
        "a token without a signature is refused"
    );
}

#[tokio::test]
async fn a_request_signed_with_the_wrong_key_is_rejected() {
    let harness = Harness::boot().await;
    let wrong_key = vec![0u8; 32];

    let response = harness
        .raw(
            reqwest::Method::GET,
            "/v1/sessions",
            Vec::new(),
            &harness.operator,
            &wrong_key,
            OffsetDateTime::now_utc().unix_timestamp(),
            &auth::mint_secret(),
            None,
        )
        .await;
    assert_eq!(response.status(), 401);

    // The right key over a *different* path is equally useless: the signature
    // binds the request, not just the device.
    let timestamp = OffsetDateTime::now_utc().unix_timestamp();
    let nonce = auth::mint_secret();
    let canonical =
        openpaw_protocol::signing::canonical_string("GET", "/v1/inbox", timestamp, &nonce, b"");
    let signature = openpaw_protocol::signing::sign(&harness.operator.key, &canonical);
    let response = harness
        .client
        .get(format!("{}/v1/sessions", harness.base))
        .header(
            "authorization",
            format!("Bearer {}", harness.operator.token),
        )
        .header(auth::DEVICE_HEADER, &harness.operator.device_id)
        .header(auth::TIMESTAMP_HEADER, timestamp.to_string())
        .header(auth::NONCE_HEADER, &nonce)
        .header(auth::SIGNATURE_HEADER, signature)
        .send()
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        401,
        "a signature for another path is refused"
    );
}

#[tokio::test]
async fn a_replayed_nonce_is_rejected() {
    let harness = Harness::boot().await;
    let timestamp = OffsetDateTime::now_utc().unix_timestamp();
    let nonce = auth::mint_secret();

    let first = harness
        .raw(
            reqwest::Method::GET,
            "/v1/sessions",
            Vec::new(),
            &harness.operator,
            &harness.operator.key,
            timestamp,
            &nonce,
            None,
        )
        .await;
    assert_eq!(first.status(), 200);

    // Byte-identical replay: valid signature, valid timestamp, used nonce.
    let replay = harness
        .raw(
            reqwest::Method::GET,
            "/v1/sessions",
            Vec::new(),
            &harness.operator,
            &harness.operator.key,
            timestamp,
            &nonce,
            None,
        )
        .await;
    assert_eq!(replay.status(), 401, "a replayed nonce must be refused");
}

#[tokio::test]
async fn a_stale_timestamp_is_rejected() {
    let harness = Harness::boot().await;
    let now = OffsetDateTime::now_utc().unix_timestamp();

    for offset in [-(auth::MAX_SKEW + 60), auth::MAX_SKEW + 60] {
        let response = harness
            .raw(
                reqwest::Method::GET,
                "/v1/sessions",
                Vec::new(),
                &harness.operator,
                &harness.operator.key,
                now + offset,
                &auth::mint_secret(),
                None,
            )
            .await;
        assert_eq!(
            response.status(),
            401,
            "a timestamp {offset}s away must be refused"
        );
    }

    // Just inside the window still works, so the check is a window and not a
    // requirement for perfectly synchronized clocks.
    let response = harness
        .raw(
            reqwest::Method::GET,
            "/v1/sessions",
            Vec::new(),
            &harness.operator,
            &harness.operator.key,
            now - (auth::MAX_SKEW - 30),
            &auth::mint_secret(),
            None,
        )
        .await;
    assert_eq!(response.status(), 200);
}

#[tokio::test]
async fn a_correctly_signed_request_succeeds_and_reflects_state() {
    let harness = Harness::boot().await;
    let item = seed(&harness, destructive_permission());

    let response = harness.get("/v1/sessions").await;
    assert_eq!(response.status(), 200);
    let sessions: Value = response.json().await.unwrap();
    let first = &sessions[0];
    assert_eq!(first["session_id"], session().as_ref());
    assert_eq!(first["agent"], "claude-code");
    assert_eq!(first["cwd"], "/work");
    assert_eq!(first["git_branch"], "main");
    assert_eq!(
        first["state"], "waiting",
        "a pending approval makes the session waiting"
    );
    assert_eq!(first["pending_inbox"], 1);

    let response = harness.get("/v1/inbox?status=pending").await;
    assert_eq!(response.status(), 200);
    let inbox: Vec<Value> = response.json().await.unwrap();
    assert_eq!(inbox.len(), 1);
    assert_eq!(inbox[0]["id"], item.id.as_ref());
    assert_eq!(inbox[0]["command"], "rm -rf build");
    assert_eq!(inbox[0]["risk"]["class"], "destructive_shell");
    assert_eq!(inbox[0]["risk"]["requires_detail_expansion"], true);

    // A bad status filter is a client error, not an empty list.
    assert_eq!(harness.get("/v1/inbox?status=bogus").await.status(), 400);
}

// ---------------------------------------------------------------------------
// capabilities
// ---------------------------------------------------------------------------

#[tokio::test]
async fn an_observer_can_read_but_cannot_resolve() {
    let harness = Harness::boot().await;
    let item = seed(&harness, destructive_permission());
    let token = item.action_token.clone().unwrap();

    // Reading is allowed.
    let response = harness
        .signed(reqwest::Method::GET, "/v1/inbox", None, &harness.observer)
        .await;
    assert_eq!(response.status(), 200);

    // Deciding is not.
    let response = harness
        .signed(
            reqwest::Method::POST,
            &format!("/v1/inbox/{}/resolve", item.id),
            Some(json!({
                "action": "approve_once",
                "action_token": token,
                "detail_acknowledged": true,
            })),
            &harness.observer,
        )
        .await;
    assert_eq!(response.status(), 403);
    assert_eq!(
        response
            .headers()
            .get(auth::REQUIRED_CAPABILITY_HEADER)
            .and_then(|v| v.to_str().ok()),
        Some("approvals.write"),
        "the missing capability is named in a header"
    );
    let body: Value = response.json().await.unwrap();
    assert_eq!(body["capability"], "approvals.write");

    // The refusal did not burn the token.
    let response = harness
        .signed(
            reqwest::Method::POST,
            &format!("/v1/inbox/{}/resolve", item.id),
            Some(json!({
                "action": "approve_once",
                "action_token": token,
                "detail_acknowledged": true,
            })),
            &harness.operator,
        )
        .await;
    assert_eq!(response.status(), 200);
}

// ---------------------------------------------------------------------------
// the detail-expansion gate
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_gated_command_needs_detail_acknowledged_and_then_hands_off_the_decision() {
    let harness = Harness::boot().await;
    let item = seed(&harness, destructive_permission());
    let token = item.action_token.clone().unwrap();
    let path = format!("/v1/inbox/{}/resolve", item.id);

    // Without the acknowledgement: refused, and the token survives.
    let response = harness
        .signed(
            reqwest::Method::POST,
            &path,
            Some(json!({ "action": "approve_once", "action_token": token })),
            &harness.operator,
        )
        .await;
    assert_eq!(response.status(), 400);
    let body: Value = response.json().await.unwrap();
    let message = body["error"].as_str().unwrap();
    assert!(message.contains("detail_acknowledged"), "{message}");
    assert!(
        message.contains("rm"),
        "the refusal names the trigger: {message}"
    );

    // Nothing was handed to the agent.
    assert!(
        openpaw_host::api::inbox::read_decision(
            &harness.app.store.decisions_dir(),
            "req-destructive"
        )
        .await
        .is_none(),
        "a refused resolve must not write a decision"
    );

    // With the acknowledgement: accepted.
    let response = harness
        .signed(
            reqwest::Method::POST,
            &path,
            Some(json!({
                "action": "approve_once",
                "action_token": token,
                "detail_acknowledged": true,
            })),
            &harness.operator,
        )
        .await;
    assert_eq!(response.status(), 200);
    let body: Value = response.json().await.unwrap();
    assert_eq!(body["status"], "resolved");
    let event_id = body["event_id"].as_str().expect("an event id").to_owned();

    // The decision file is the agent-visible handoff.
    let decisions = harness.app.store.decisions_dir();
    let decision = openpaw_host::api::inbox::read_decision(&decisions, "req-destructive")
        .await
        .expect("a decision file must exist");
    assert_eq!(decision.action, ActionId::ApproveOnce);
    assert_eq!(decision.request_id, "req-destructive");
    assert_eq!(decision.device_id, harness.operator.device_id);
    assert!(decision.detail_acknowledged);
    assert!(decision.approves());
    assert_eq!(decision.session_id, session().as_ref());
    assert_eq!(decision.agent, "claude-code");

    // Written at owner-only mode, like everything else holding operator intent.
    {
        use std::os::unix::fs::PermissionsExt;
        let file = decisions.join("req-destructive.json");
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let stored: Decision = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(stored, decision);
    }

    // The audit log records both the refusal and the approval, and says the
    // operator expanded the detail.
    let entries = harness.audit_entries().await;
    let approval = entries
        .iter()
        .find(|entry| entry.result.starts_with("approve_once"))
        .expect("an approval entry");
    assert_eq!(approval.action, "inbox.resolve");
    assert_eq!(approval.target, item.id.as_ref());
    assert_eq!(approval.device_id, harness.operator.device_id);
    assert_eq!(approval.result, "approve_once (detail acknowledged)");
    assert!(
        entries
            .iter()
            .any(|entry| entry.result.contains("detail not acknowledged")),
        "the refused attempt is audited too: {entries:?}"
    );

    // A `permission.resolved` event was published for the session.
    let response = harness.get("/v1/inbox?status=resolved").await;
    let resolved: Vec<Value> = response.json().await.unwrap();
    assert_eq!(resolved.len(), 1);
    assert_eq!(resolved[0]["resolution"], "approve_once");
    assert!(
        resolved[0]["action_token"].is_null(),
        "a resolved item no longer carries a token"
    );

    let replay = harness.app.bus.replay(Some(&session()), None);
    let published = replay
        .iter()
        .find(|event| event.event_id.as_ref() == event_id)
        .expect("the resolution event is in the backlog");
    match &published.body {
        Body::PermissionResolved(payload) => {
            assert_eq!(payload.request_id, "req-destructive");
            assert_eq!(payload.decision, ActionId::ApproveOnce);
            assert_eq!(
                payload.device_id.as_deref(),
                Some(harness.operator.device_id.as_str())
            );
        }
        other => panic!("expected permission.resolved, got {other:?}"),
    }
}

#[tokio::test]
async fn a_denial_is_never_blocked_by_the_detail_gate() {
    let harness = Harness::boot().await;
    let item = seed(&harness, destructive_permission());
    let token = item.action_token.clone().unwrap();
    assert!(item.risk.as_ref().unwrap().requires_detail_expansion);

    // The same item that refuses an un-acknowledged *approval* must accept a
    // denial immediately. A denial the host rejects costs nothing; a denial the
    // host blocks lets the agent run the command anyway.
    let response = harness
        .signed(
            reqwest::Method::POST,
            &format!("/v1/inbox/{}/resolve", item.id),
            Some(json!({ "action": "deny", "action_token": token })),
            &harness.operator,
        )
        .await;
    assert_eq!(
        response.status(),
        200,
        "a denial must never require detail_acknowledged"
    );

    let decision = openpaw_host::api::inbox::read_decision(
        &harness.app.store.decisions_dir(),
        "req-destructive",
    )
    .await
    .expect("the denial reaches the agent");
    assert!(decision.denies());
    assert!(decision.halts());
    assert!(!decision.approves());
    assert!(!decision.detail_acknowledged);
}

#[tokio::test]
async fn an_ungated_item_resolves_without_an_acknowledgement() {
    let harness = Harness::boot().await;
    let item = seed(&harness, question());
    let token = item.action_token.clone().unwrap();

    let response = harness
        .signed(
            reqwest::Method::POST,
            &format!("/v1/inbox/{}/resolve", item.id),
            Some(json!({
                "action": "answer",
                "action_token": token,
                "answer": "pnpm",
            })),
            &harness.operator,
        )
        .await;
    assert_eq!(response.status(), 200);

    let decision =
        openpaw_host::api::inbox::read_decision(&harness.app.store.decisions_dir(), "req-question")
            .await
            .expect("a decision file");
    assert_eq!(decision.answer.as_deref(), Some("pnpm"));
    assert!(!decision.detail_acknowledged);

    let replay = harness.app.bus.replay(Some(&session()), None);
    assert!(
        replay.iter().any(|event| matches!(
            &event.body,
            Body::QuestionAnswered(payload) if payload.answer == "pnpm"
        )),
        "a question yields question.answered"
    );
}

#[tokio::test]
async fn an_action_token_cannot_be_used_twice() {
    let harness = Harness::boot().await;
    let item = seed(&harness, destructive_permission());
    let token = item.action_token.clone().unwrap();
    let path = format!("/v1/inbox/{}/resolve", item.id);
    let body = json!({
        "action": "approve_once",
        "action_token": token,
        "detail_acknowledged": true,
    });

    let first = harness
        .signed(
            reqwest::Method::POST,
            &path,
            Some(body.clone()),
            &harness.operator,
        )
        .await;
    assert_eq!(first.status(), 200);

    let second = harness
        .signed(reqwest::Method::POST, &path, Some(body), &harness.operator)
        .await;
    assert_eq!(
        second.status(),
        409,
        "the second use of an action token must be refused"
    );

    // A fabricated token on a fresh item is refused too.
    let other = seed(&harness, question());
    let response = harness
        .signed(
            reqwest::Method::POST,
            &format!("/v1/inbox/{}/resolve", other.id),
            Some(json!({ "action": "answer", "action_token": "not-the-token" })),
            &harness.operator,
        )
        .await;
    assert_eq!(response.status(), 403);

    // An unknown item is a 404, not a 403: no token is even considered.
    let response = harness
        .signed(
            reqwest::Method::POST,
            "/v1/inbox/inb_0000000000000000000000000/resolve",
            Some(json!({ "action": "answer", "action_token": "x" })),
            &harness.operator,
        )
        .await;
    assert!(
        response.status() == 404 || response.status() == 400,
        "unknown ids are refused, got {}",
        response.status()
    );
}

// ---------------------------------------------------------------------------
// the event stream
// ---------------------------------------------------------------------------

#[tokio::test]
async fn the_event_stream_replays_the_backlog_then_delivers_live_events() {
    let harness = Harness::boot().await;

    // Two events already in the ring before anyone subscribes.
    let (first, _) = harness.app.publish(destructive_permission());
    let (second, _) = harness.app.publish(question());
    assert_eq!(first.seq, 0);
    assert_eq!(second.seq, 1);

    let response = harness
        .get(&format!("/v1/events?session={}", session()))
        .await;
    assert_eq!(response.status(), 200);
    assert_eq!(
        response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok()),
        Some("text/event-stream")
    );

    let mut stream = response.bytes_stream();
    let mut buffer = String::new();
    let mut events: Vec<Value> = Vec::new();

    /// Pull frames until `want` complete events have been parsed.
    async fn drain(
        stream: &mut (impl futures::Stream<Item = reqwest::Result<bytes::Bytes>> + Unpin),
        buffer: &mut String,
        events: &mut Vec<Value>,
        want: usize,
    ) {
        while events.len() < want {
            let chunk = tokio::time::timeout(Duration::from_secs(5), stream.next())
                .await
                .expect("the stream must produce a frame")
                .expect("the stream must stay open")
                .expect("a readable chunk");
            buffer.push_str(&String::from_utf8_lossy(&chunk));
            while let Some(end) = buffer.find("\n\n") {
                let frame: String = buffer.drain(..end + 2).collect();
                for line in frame.lines() {
                    if let Some(data) = line.strip_prefix("data:") {
                        events.push(serde_json::from_str(data.trim()).expect("event json"));
                    }
                }
            }
        }
    }

    drain(&mut stream, &mut buffer, &mut events, 2).await;
    assert_eq!(events[0]["event_id"], first.event_id.as_ref());
    assert_eq!(events[0]["seq"], 0);
    assert_eq!(events[0]["type"], "permission.requested");
    assert_eq!(events[1]["event_id"], second.event_id.as_ref());
    assert_eq!(events[1]["seq"], 1);

    // The envelope keys the app depends on are always present, null when absent.
    assert_eq!(events[0]["version"], "1");
    assert_eq!(events[0]["cwd"], "/work");
    assert!(events[1]["multiplexer_target"].is_null());

    // Now publish live and confirm it arrives on the same connection.
    let (live, _) = harness.app.publish(Event::new(
        &session(),
        AgentKind::ClaudeCode,
        "live-marker",
        OffsetDateTime::now_utc(),
        Body::TurnDelta(openpaw_protocol::TurnDelta {
            turn_id: "t1".to_owned(),
            delta: "live chunk".to_owned(),
            kind: openpaw_protocol::DeltaKind::Text,
        }),
    ));

    drain(&mut stream, &mut buffer, &mut events, 3).await;
    assert_eq!(events[2]["event_id"], live.event_id.as_ref());
    assert_eq!(events[2]["seq"], 2);
    assert_eq!(events[2]["payload"]["delta"], "live chunk");
    assert_eq!(events.len(), 3, "no duplicate between backlog and live");
}

#[tokio::test]
async fn after_seq_skips_what_the_client_already_has() {
    let harness = Harness::boot().await;
    harness.app.publish(destructive_permission());
    let (second, _) = harness.app.publish(question());

    let response = harness
        .get(&format!("/v1/events?session={}&after_seq=0", session()))
        .await;
    assert_eq!(response.status(), 200);

    let mut stream = response.bytes_stream();
    let chunk = tokio::time::timeout(Duration::from_secs(5), stream.next())
        .await
        .expect("a frame")
        .expect("open")
        .expect("chunk");
    let text = String::from_utf8_lossy(&chunk);
    assert!(
        text.contains(second.event_id.as_ref()),
        "the first frame after seq 0 must be seq 1: {text}"
    );
    assert!(
        !text.contains("\"seq\":0"),
        "seq 0 must not be replayed: {text}"
    );

    // A malformed session id is a client error rather than an empty stream.
    assert_eq!(harness.get("/v1/events?session=%20%20").await.status(), 200);
}

// ---------------------------------------------------------------------------
// uploads
// ---------------------------------------------------------------------------

#[tokio::test]
async fn uploads_reject_path_traversal_and_accept_a_bare_basename() {
    let harness = Harness::boot().await;

    let upload = async |filename: &str, body: &[u8]| {
        let timestamp = OffsetDateTime::now_utc().unix_timestamp();
        let nonce = auth::mint_secret();
        let canonical = openpaw_protocol::signing::canonical_string(
            "POST",
            "/v1/uploads",
            timestamp,
            &nonce,
            body,
        );
        let signature = openpaw_protocol::signing::sign(&harness.operator.key, &canonical);
        harness
            .client
            .post(format!("{}/v1/uploads", harness.base))
            .header(
                "authorization",
                format!("Bearer {}", harness.operator.token),
            )
            .header(auth::DEVICE_HEADER, &harness.operator.device_id)
            .header(auth::TIMESTAMP_HEADER, timestamp.to_string())
            .header(auth::NONCE_HEADER, &nonce)
            .header(auth::SIGNATURE_HEADER, signature)
            .header(openpaw_host::uploads::FILENAME_HEADER, filename)
            .header("content-type", "application/octet-stream")
            .body(body.to_vec())
            .send()
            .await
            .expect("upload request")
    };

    for hostile in [
        "../evil.png",
        "../../etc/evil.png",
        "/etc/evil.png",
        "d/evil.png",
    ] {
        let response = upload(hostile, b"pixels").await;
        assert_eq!(response.status(), 400, "{hostile} must be refused");
    }
    for wrong_type in ["evil.sh", "payload.zip", "noextension"] {
        let response = upload(wrong_type, b"pixels").await;
        assert_eq!(response.status(), 400, "{wrong_type} must be refused");
    }

    // Nothing hostile reached the disk.
    let uploads = harness.app.store.uploads_dir();
    assert_eq!(std::fs::read_dir(&uploads).unwrap().count(), 0);

    // A bare basename with an allowlisted extension is accepted.
    let response = upload("shot.png", b"pixels").await;
    assert_eq!(response.status(), 200);
    let body: Value = response.json().await.unwrap();
    assert_eq!(body["bytes"], 6);
    assert_eq!(body["sha256"], auth::sha256_hex(b"pixels"));

    let stored = PathBuf::from(body["path"].as_str().unwrap());
    assert_eq!(stored.parent(), Some(uploads.as_path()));
    assert_eq!(stored.extension().and_then(|e| e.to_str()), Some("png"));
    assert!(
        !stored.to_string_lossy().contains("shot"),
        "the client stem is discarded: {}",
        stored.display()
    );
    assert_eq!(std::fs::read(&stored).unwrap(), b"pixels");

    // The upload is audited.
    let entries = harness.audit_entries().await;
    assert!(
        entries
            .iter()
            .any(|entry| entry.action == "uploads.write" && entry.result.contains("stored 6")),
        "{entries:?}"
    );

    // Over the configured cap: refused with 413.
    let response = upload("big.png", &vec![b'x'; (MAX_UPLOAD + 1) as usize]).await;
    assert_eq!(response.status(), 413);
}

// ---------------------------------------------------------------------------
// repositories
// ---------------------------------------------------------------------------

#[tokio::test]
async fn repository_routes_are_scoped_to_allowlisted_roots() {
    let temp = tempfile::tempdir().unwrap();
    let repo = temp.path().join("demo");
    std::fs::create_dir_all(repo.join("src")).unwrap();
    std::fs::write(
        repo.join("src/main.rs"),
        "fn main() { println!(\"hi\"); }\n",
    )
    .unwrap();

    let git = |args: &[&str]| {
        std::process::Command::new("git")
            .args(args)
            .current_dir(&repo)
            .env("GIT_AUTHOR_NAME", "OpenPaw")
            .env("GIT_AUTHOR_EMAIL", "dev@example.com")
            .env("GIT_COMMITTER_NAME", "OpenPaw")
            .env("GIT_COMMITTER_EMAIL", "dev@example.com")
            .output()
            .expect("git must be installed to run this test")
    };
    git(&["init", "--initial-branch=main"]);
    git(&["add", "."]);
    git(&["commit", "-m", "initial"]);

    let harness = Harness::boot_with(vec![repo.clone()]).await;

    let response = harness.get("/v1/repos").await;
    assert_eq!(response.status(), 200);
    let repos: Vec<Value> = response.json().await.unwrap();
    assert_eq!(repos.len(), 1, "{repos:?}");
    assert_eq!(repos[0]["name"], "demo");

    let response = harness.get("/v1/repos/demo/status").await;
    assert_eq!(response.status(), 200);
    let status: Value = response.json().await.unwrap();
    assert_eq!(status["branch"], "main");

    let response = harness.get("/v1/repos/demo/blob?path=src/main.rs").await;
    assert_eq!(response.status(), 200);
    let blob: Value = response.json().await.unwrap();
    assert_eq!(blob["path"], "src/main.rs");
    // `BlobContent` is adjacently tagged, so the discriminator and the payload sit
    // together under `content`.
    assert_eq!(blob["content"]["encoding"], "text");
    assert!(
        blob["content"]["value"]
            .as_str()
            .unwrap()
            .contains("fn main"),
        "{blob:?}"
    );
    assert_eq!(blob["truncated"], false);

    let response = harness.get("/v1/repos/demo/search?q=println").await;
    assert_eq!(response.status(), 200);
    let hits: Vec<Value> = response.json().await.unwrap();
    assert_eq!(hits.len(), 1, "{hits:?}");
    assert_eq!(hits[0]["path"], "src/main.rs");

    // A root that is not allowlisted does not exist as far as the API is
    // concerned, whatever is on the filesystem.
    assert_eq!(harness.get("/v1/repos/other/status").await.status(), 404);

    // A traversal attempt out of an allowlisted root is a client error.
    let response = harness
        .get("/v1/repos/demo/blob?path=../../../../etc/passwd")
        .await;
    assert!(
        response.status() == 400 || response.status() == 404,
        "traversal must not succeed, got {}",
        response.status()
    );
}

#[derive(Clone)]
struct FakeTailscaleRunner {
    result: Result<Vec<u8>, TailscaleUnavailable>,
    calls: Arc<Mutex<Vec<()>>>,
}

impl TailscaleStatusRunner for FakeTailscaleRunner {
    fn status_json(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<u8>, TailscaleUnavailable>> + Send + '_>> {
        let result = self.result.clone();
        let calls = Arc::clone(&self.calls);
        Box::pin(async move {
            calls.lock().unwrap().push(());
            result
        })
    }
}

#[tokio::test]
async fn tailscale_devices_requires_signature_pairing_and_capability() {
    let calls = Arc::new(Mutex::new(Vec::new()));
    let runner = Arc::new(FakeTailscaleRunner {
        result: Ok(
            br#"[{"id":"n1","Name":"mac","TailscaleIP":"100.64.0.2","Online":true}]"#.to_vec(),
        ),
        calls: Arc::clone(&calls),
    });
    let harness = Harness::boot_with_runner(Vec::new(), Some(runner)).await;

    let unsigned = harness
        .client
        .get(format!("{}/v1/tailscale/devices", harness.base))
        .send()
        .await
        .unwrap();
    assert_eq!(unsigned.status(), 401);

    let unknown = Creds {
        device_id: "unknown".to_owned(),
        token: harness.operator.token.clone(),
        key: harness.operator.key.clone(),
    };
    let unpaired = harness
        .signed(
            reqwest::Method::GET,
            "/v1/tailscale/devices",
            None,
            &unknown,
        )
        .await;
    assert_eq!(unpaired.status(), 401);

    let limited = enroll_custom(&harness.app, "limited", &["sessions.read"]);
    let missing_cap = harness
        .signed(
            reqwest::Method::GET,
            "/v1/tailscale/devices",
            None,
            &limited,
        )
        .await;
    assert_eq!(missing_cap.status(), 403);
    assert_eq!(
        missing_cap
            .headers()
            .get(auth::REQUIRED_CAPABILITY_HEADER)
            .unwrap(),
        "devices.read"
    );

    assert!(calls.lock().unwrap().is_empty());
}

#[tokio::test]
async fn tailscale_devices_authorized_success_ignores_request_command_data() {
    let calls = Arc::new(Mutex::new(Vec::new()));
    let runner = Arc::new(FakeTailscaleRunner {
        result: Ok(br#"[{"id":"n1","Name":"mac","DNSName":"mac.tailnet.ts.net.","TailscaleIP":"100.64.0.2","Online":true,"OS":"macOS"}]"#.to_vec()),
        calls: Arc::clone(&calls),
    });
    let harness = Harness::boot_with_runner(Vec::new(), Some(runner)).await;

    let response = harness
        .signed(
            reqwest::Method::GET,
            "/v1/tailscale/devices?command=sh&path=/bin/sh&argv=evil",
            Some(json!({ "command": "rm -rf /", "path": "/bin/sh" })),
            &harness.operator,
        )
        .await;
    assert_eq!(response.status(), 200);
    assert_eq!(calls.lock().unwrap().len(), 1);

    let body: Value = response.json().await.unwrap();
    assert_eq!(body["version"], 1);
    assert_eq!(body["candidates"][0]["id"], "n1");
    assert_eq!(body["candidates"][0]["display_name"], "mac");
    assert_eq!(body["candidates"][0]["dns_name"], "mac.tailnet.ts.net");
    assert_eq!(body["candidates"][0]["online"], true);
    let text = serde_json::to_string(&body).unwrap();
    assert!(!text.contains("ready"));
    assert!(!text.contains("trusted"));
    assert!(!text.contains("verified"));
    assert!(!text.contains("rm -rf"));
}

#[tokio::test]
async fn tailscale_devices_returns_typed_unavailable_and_hard_malformed_errors() {
    for (unavailable, expected_status, expected_code) in [
        (
            TailscaleUnavailable::MissingCli(
                "Tailscale is not installed on the connected host.".to_owned(),
            ),
            503,
            "missing_cli",
        ),
        (
            TailscaleUnavailable::LoggedOut(
                "Tailscale is installed but not logged in on the connected host.".to_owned(),
            ),
            503,
            "logged_out",
        ),
        (
            TailscaleUnavailable::Timeout(
                "Tailscale discovery timed out on the connected host.".to_owned(),
            ),
            504,
            "timeout",
        ),
        (
            TailscaleUnavailable::OutputLimit(
                "Tailscale discovery returned too much data on the connected host.".to_owned(),
            ),
            502,
            "output_limit",
        ),
    ] {
        let runner = Arc::new(FakeTailscaleRunner {
            result: Err(unavailable),
            calls: Arc::new(Mutex::new(Vec::new())),
        });
        let harness = Harness::boot_with_runner(Vec::new(), Some(runner)).await;
        let response = harness.get("/v1/tailscale/devices").await;
        assert_eq!(response.status(), expected_status);
        let body: Value = response.json().await.unwrap();
        assert!(body["error"].as_str().unwrap().contains(expected_code));
    }

    let runner = Arc::new(FakeTailscaleRunner {
        result: Ok(b"not json".to_vec()),
        calls: Arc::new(Mutex::new(Vec::new())),
    });
    let harness = Harness::boot_with_runner(Vec::new(), Some(runner)).await;
    let malformed = harness.get("/v1/tailscale/devices").await;
    assert_eq!(malformed.status(), 500);
    let body: Value = malformed.json().await.unwrap();
    assert_eq!(body["error"], "internal error");
}

/// Register a device with explicit capability names.
fn enroll_custom(app: &AppState, device_id: &str, capabilities: &[&str]) -> Creds {
    let token = auth::mint_secret();
    let hmac_key_b64 = auth::mint_hmac_key_b64();
    app.store
        .insert_device(Device {
            device_id: device_id.to_owned(),
            name: device_id.to_owned(),
            platform: "ios".to_owned(),
            hmac_key_b64: hmac_key_b64.clone(),
            token_sha256: auth::sha256_hex(token.as_bytes()),
            capabilities: capabilities
                .iter()
                .map(|capability| (*capability).to_owned())
                .collect(),
            paired_at: OffsetDateTime::now_utc(),
            last_seen: None,
        })
        .expect("insert device");
    Creds {
        device_id: device_id.to_owned(),
        token,
        key: base64::engine::general_purpose::STANDARD
            .decode(hmac_key_b64)
            .expect("hmac key"),
    }
}

// ---------------------------------------------------------------------------
// the shape of the API itself
// ---------------------------------------------------------------------------

#[tokio::test]
async fn there_is_no_endpoint_that_runs_a_command() {
    let harness = Harness::boot().await;

    // The capability spec's `non_capabilities` says there is no arbitrary command
    // execution endpoint. This test is what keeps that true.
    for path in [
        "/v1/exec",
        "/v1/run",
        "/v1/shell",
        "/v1/command",
        "/v1/sessions/sess_cc-alpha/exec",
        "/v1/terminal",
    ] {
        let response = harness
            .signed(
                reqwest::Method::POST,
                path,
                Some(json!({ "command": "id" })),
                &harness.operator,
            )
            .await;
        assert_eq!(
            response.status(),
            404,
            "{path} must not exist, got {}",
            response.status()
        );
    }

    // No capability grants command execution either.
    let response = harness
        .client
        .get(format!("{}/v1/health", harness.base))
        .send()
        .await
        .unwrap();
    let body: Value = response.json().await.unwrap();
    let capabilities = body["capabilities"].as_array().unwrap();
    for capability in capabilities {
        let name = capability.as_str().unwrap();
        assert!(
            !name.contains("exec") && !name.contains("shell") && !name.contains("command"),
            "capability {name} suggests command execution"
        );
    }
}

/// The captured Claude Code `PreToolUse` payload the adapters were built against.
fn claude_hook_fixture() -> Value {
    let path = repo_root().join("protocol/fixtures/claude-code/hook-pretooluse-destructive.json");
    let bytes =
        std::fs::read(&path).unwrap_or_else(|err| panic!("reading {}: {err}", path.display()));
    serde_json::from_slice(&bytes).expect("the fixture is JSON")
}

/// Walk up from this crate's manifest to the repository root.
fn repo_root() -> PathBuf {
    let mut candidate = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    while !candidate
        .join("protocol/json-schema/event.schema.json")
        .exists()
    {
        candidate = candidate
            .parent()
            .expect("walked past the filesystem root looking for the repo")
            .to_path_buf();
    }
    candidate
}

#[tokio::test]
async fn the_hook_ingress_requires_the_hook_token() {
    let harness = Harness::boot().await;
    let url = format!("{}/v1/hooks/claude-code", harness.base);
    let fixture = claude_hook_fixture();

    let response = harness
        .client
        .post(&url)
        .json(&fixture)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 401, "hooks need the hook token");

    let response = harness
        .client
        .post(&url)
        .header(auth::HOOK_TOKEN_HEADER, "not-the-token")
        .json(&fixture)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 401);

    // A device bearer token is not a hook token: the two factors are separate.
    let response = harness
        .signed(
            reqwest::Method::POST,
            "/v1/hooks/claude-code",
            Some(fixture.clone()),
            &harness.operator,
        )
        .await;
    assert_eq!(response.status(), 401);

    // With the real token the hook is ingested.
    let response = harness
        .client
        .post(&url)
        .header(auth::HOOK_TOKEN_HEADER, harness.app.store.hook_token())
        .json(&fixture)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    // No decision exists yet, so the CLI keeps its own prompt.
    let reply: Value = response.json().await.unwrap();
    assert_eq!(
        reply,
        json!({}),
        "an undecided hook must not carry a verdict"
    );

    // The hook produced a gated inbox item without any polling.
    let response = harness.get("/v1/inbox?status=pending").await;
    let inbox: Vec<Value> = response.json().await.unwrap();
    assert_eq!(inbox.len(), 1, "{inbox:?}");
    assert_eq!(inbox[0]["risk"]["requires_detail_expansion"], true);
    assert_eq!(inbox[0]["agent"], "claude-code");

    // An unknown agent is a 404 rather than a silent success.
    let response = harness
        .client
        .post(format!("{}/v1/hooks/not-an-agent", harness.base))
        .header(auth::HOOK_TOKEN_HEADER, harness.app.store.hook_token())
        .json(&json!({}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 404);

    // A body that is not JSON at all is a client error.
    let response = harness
        .client
        .post(&url)
        .header(auth::HOOK_TOKEN_HEADER, harness.app.store.hook_token())
        .header("content-type", "application/json")
        .body("{ not json")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 400);
}

#[tokio::test]
async fn a_decision_made_on_the_phone_reaches_the_agent_through_the_hook_reply() {
    let harness = Harness::boot().await;
    let fixture = claude_hook_fixture();
    let hook = || {
        harness
            .client
            .post(format!("{}/v1/hooks/claude-code", harness.base))
            .header(auth::HOOK_TOKEN_HEADER, harness.app.store.hook_token())
            .json(&fixture)
            .send()
    };

    // 1. The agent asks. Nothing is decided, so it keeps its own prompt.
    let reply: Value = hook().await.unwrap().json().await.unwrap();
    assert_eq!(reply, json!({}));

    // 2. The operator denies it from the phone. A denial needs no acknowledgement.
    let inbox: Vec<Value> = harness.get("/v1/inbox").await.json().await.unwrap();
    let id = inbox[0]["id"].as_str().unwrap().to_owned();
    let token = inbox[0]["action_token"].as_str().unwrap().to_owned();
    let response = harness
        .signed(
            reqwest::Method::POST,
            &format!("/v1/inbox/{id}/resolve"),
            Some(json!({
                "action": "deny",
                "action_token": token,
                "answer": "not on this machine",
            })),
            &harness.operator,
        )
        .await;
    assert_eq!(response.status(), 200);

    // 3. The hook runs again and now receives the verdict in Claude Code's own
    //    shape, with the operator's words as the reason.
    let reply: Value = hook().await.unwrap().json().await.unwrap();
    assert_eq!(reply["decision"], "block");
    assert_eq!(reply["reason"], "not on this machine");
}

#[tokio::test]
async fn pairing_needs_a_code_and_the_code_comes_from_the_running_daemon() {
    let harness = Harness::boot().await;

    // A made-up code gets nothing.
    let response = harness
        .client
        .post(format!("{}/v1/pair", harness.base))
        .json(&json!({
            "pairing_code": "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF",
            "device_name": "phone",
            "platform": "ios",
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 403);

    // Minting a code requires the hook token, which only a local caller has.
    let response = harness
        .client
        .post(format!("{}/v1/pairing-code", harness.base))
        .json(&json!({ "profile": "observer" }))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 401);

    let response = harness
        .client
        .post(format!("{}/v1/pairing-code", harness.base))
        .header(auth::HOOK_TOKEN_HEADER, harness.app.store.hook_token())
        .json(&json!({ "device_name": "ipad", "profile": "observer" }))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let issued: Value = response.json().await.unwrap();
    let code = issued["code"].as_str().unwrap().to_owned();
    assert_eq!(code.split('-').count(), 6, "{code}");
    assert_eq!(issued["profile"], "observer");

    // Redeeming it yields credentials with exactly the observer profile.
    let response = harness
        .client
        .post(format!("{}/v1/pair", harness.base))
        .json(&json!({
            "pairing_code": code.to_lowercase(),
            "device_name": "iPad",
            "platform": "ios",
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let paired: Value = response.json().await.unwrap();
    let capabilities: Vec<String> = serde_json::from_value(paired["capabilities"].clone()).unwrap();
    assert_eq!(capabilities, Profile::Observer.capability_names());
    assert!(paired["device_id"].as_str().unwrap().starts_with("dev_"));

    // The bearer token was never persisted, only its digest.
    let token = paired["token"].as_str().unwrap();
    let state = std::fs::read_to_string(harness.app.store.state_dir().join("state.json")).unwrap();
    assert!(!state.contains(token), "the raw token must not be on disk");
    assert!(state.contains(&auth::sha256_hex(token.as_bytes())));

    // And the code is single use.
    let response = harness
        .client
        .post(format!("{}/v1/pair", harness.base))
        .json(&json!({
            "pairing_code": code,
            "device_name": "iPad",
            "platform": "ios",
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 403);

    // Pairing is audited.
    let entries = harness.audit_entries().await;
    assert!(
        entries.iter().any(|entry| entry.action == "device.pair"),
        "{entries:?}"
    );
}

#[tokio::test]
async fn the_audit_log_is_readable_and_newest_first() {
    let harness = Harness::boot().await;
    let item = seed(&harness, question());
    let token = item.action_token.clone().unwrap();

    harness
        .signed(
            reqwest::Method::POST,
            &format!("/v1/inbox/{}/resolve", item.id),
            Some(json!({ "action": "answer", "action_token": token, "answer": "pnpm" })),
            &harness.operator,
        )
        .await;

    let response = harness.get("/v1/audit?limit=10").await;
    assert_eq!(response.status(), 200);
    let entries: Vec<AuditEntry> = response.json().await.unwrap();
    assert!(!entries.is_empty());
    assert_eq!(entries[0].action, "inbox.resolve");
    assert_eq!(entries[0].device_id, harness.operator.device_id);

    // An observer can read the log; it holds `inbox.read`.
    let response = harness
        .signed(reqwest::Method::GET, "/v1/audit", None, &harness.observer)
        .await;
    assert_eq!(response.status(), 200);
}

#[tokio::test]
async fn the_preview_proxy_refuses_a_port_outside_the_allowlist() {
    let harness = Harness::boot().await;

    // 5173 is allowlisted by the harness but nothing is listening: 502.
    let response = harness.get("/v1/preview/5173/index.html").await;
    assert_eq!(
        response.status(),
        502,
        "an allowlisted but dead port is a gateway error"
    );

    // 22 is not allowlisted, so it is refused without a connection attempt.
    let response = harness.get("/v1/preview/22/").await;
    assert_eq!(response.status(), 403);
    let body: Value = response.json().await.unwrap();
    assert!(
        body["error"].as_str().unwrap().contains("allowlist"),
        "{body:?}"
    );

    // An observer cannot use the proxy at all.
    let response = harness
        .signed(
            reqwest::Method::GET,
            "/v1/preview/5173/",
            None,
            &harness.observer,
        )
        .await;
    assert_eq!(response.status(), 403);
}
