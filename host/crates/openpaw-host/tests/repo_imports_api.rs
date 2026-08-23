use std::path::PathBuf;
use std::time::Duration;

use base64::Engine as _;
use openpaw_host::auth::{self, Profile};
use openpaw_host::state::{Device, Store};
use openpaw_host::{AppState, Config};
use openpaw_protocol::{RepoImportProgress, RepoImportState};
use serde_json::{Value, json};
use time::OffsetDateTime;

struct Creds {
    device_id: String,
    token: String,
    key: Vec<u8>,
}

struct Harness {
    base: String,
    client: reqwest::Client,
    operator: Creds,
    observer: Creds,
    state_dir: PathBuf,
    _temp: tempfile::TempDir,
}

impl Harness {
    async fn boot() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let state_dir = temp.path().join("state");
        let config = Config::default();
        let store = Store::open(&state_dir).unwrap();
        let roots = openpaw_files::Roots::new(Vec::<PathBuf>::new()).unwrap();
        let app = AppState::new(config, store, roots, temp.path().to_path_buf());
        let operator = enroll(&app, "operator", Profile::Operator);
        let observer = enroll(&app, "observer", Profile::Observer);
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let _ = axum::serve(listener, openpaw_host::router(app)).await;
        });
        Self {
            base: format!("http://127.0.0.1:{port}"),
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
                .unwrap(),
            operator,
            observer,
            state_dir,
            _temp: temp,
        }
    }

    async fn signed(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Value,
        creds: &Creds,
    ) -> reqwest::Response {
        let bytes = serde_json::to_vec(&body).unwrap();
        let timestamp = OffsetDateTime::now_utc().unix_timestamp();
        let nonce = auth::mint_secret();
        let canonical = openpaw_protocol::signing::canonical_string(
            method.as_str(),
            path,
            timestamp,
            &nonce,
            &bytes,
        );
        let signature = openpaw_protocol::signing::sign(&creds.key, &canonical);
        self.client
            .request(method, format!("{}{path}", self.base))
            .header("authorization", format!("Bearer {}", creds.token))
            .header(auth::DEVICE_HEADER, &creds.device_id)
            .header(auth::TIMESTAMP_HEADER, timestamp.to_string())
            .header(auth::NONCE_HEADER, nonce)
            .header(auth::SIGNATURE_HEADER, signature)
            .header("content-type", "application/json")
            .body(bytes)
            .send()
            .await
            .unwrap()
    }
}

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
            profile: Some(profile),
            paired_at: OffsetDateTime::now_utc(),
            last_seen: None,
        })
        .unwrap();
    Creds {
        device_id: device_id.to_owned(),
        token,
        key: base64::engine::general_purpose::STANDARD
            .decode(hmac_key_b64)
            .unwrap(),
    }
}

#[tokio::test]
async fn repo_import_routes_are_guarded_and_sanitized() {
    let h = Harness::boot().await;
    let body = json!({"provider":"github","repo_id":"owner-name","requested_name":"name"});
    let denied = h
        .signed(
            reqwest::Method::POST,
            "/v1/repo-imports",
            body.clone(),
            &h.observer,
        )
        .await;
    assert_eq!(denied.status(), reqwest::StatusCode::FORBIDDEN);

    let accepted = h
        .signed(reqwest::Method::POST, "/v1/repo-imports", body, &h.operator)
        .await;
    assert_eq!(accepted.status(), reqwest::StatusCode::OK);
    let progress: RepoImportProgress = accepted.json().await.unwrap();
    assert!(progress.id.starts_with("import-"));
    assert_eq!(progress.state, RepoImportState::Queued);
    let encoded = serde_json::to_string(&progress).unwrap();
    assert!(!encoded.contains(h.state_dir.to_str().unwrap()));
    assert!(!encoded.contains("token"));

    let cancelled = h
        .signed(
            reqwest::Method::DELETE,
            &format!("/v1/repo-imports/{}", progress.id),
            json!({}),
            &h.operator,
        )
        .await;
    assert_eq!(cancelled.status(), reqwest::StatusCode::OK);
    let cancelled_again = h
        .signed(
            reqwest::Method::DELETE,
            &format!("/v1/repo-imports/{}", progress.id),
            json!({}),
            &h.operator,
        )
        .await;
    assert_eq!(cancelled_again.status(), reqwest::StatusCode::OK);
}

#[tokio::test]
async fn register_route_accepts_only_host_owned_root_ids() {
    let h = Harness::boot().await;
    std::fs::create_dir_all(h.state_dir.join("repos/known")).unwrap();
    let status = std::process::Command::new("git")
        .arg("init")
        .arg(h.state_dir.join("repos/known"))
        .status()
        .unwrap();
    assert!(status.success());
    let outside = h
        .signed(
            reqwest::Method::POST,
            "/v1/repos/register",
            json!({"root_id":"../../etc","requested_name":"bad"}),
            &h.operator,
        )
        .await;
    assert_eq!(outside.status(), reqwest::StatusCode::UNPROCESSABLE_ENTITY);

    let registered = h
        .signed(
            reqwest::Method::POST,
            "/v1/repos/register",
            json!({"root_id":"known","requested_name":"known"}),
            &h.operator,
        )
        .await;
    assert_eq!(registered.status(), reqwest::StatusCode::OK);
    let progress: RepoImportProgress = registered.json().await.unwrap();
    assert!(progress.id.starts_with("register-"));
    assert_eq!(progress.state, RepoImportState::Completed);
    assert_eq!(progress.destination_name, "known");
    let encoded = serde_json::to_string(&progress).unwrap();
    assert!(!encoded.contains(h.state_dir.to_str().unwrap()));
}

#[tokio::test]
async fn register_rejects_non_git_dirs_and_import_id_guards_hold() {
    let h = Harness::boot().await;
    std::fs::create_dir_all(h.state_dir.join("repos/plain")).unwrap();
    let plain = h
        .signed(
            reqwest::Method::POST,
            "/v1/repos/register",
            json!({"root_id":"plain","requested_name":"plain"}),
            &h.operator,
        )
        .await;
    assert_eq!(plain.status(), reqwest::StatusCode::INTERNAL_SERVER_ERROR);

    let unknown = h
        .signed(
            reqwest::Method::GET,
            "/v1/repo-imports/import-missing",
            json!({}),
            &h.operator,
        )
        .await;
    assert_eq!(unknown.status(), reqwest::StatusCode::NOT_FOUND);

    let invalid = h
        .signed(
            reqwest::Method::DELETE,
            "/v1/repo-imports/..%2Fbad",
            json!({}),
            &h.operator,
        )
        .await;
    assert_eq!(invalid.status(), reqwest::StatusCode::BAD_REQUEST);

    let cancelled = h
        .signed(
            reqwest::Method::DELETE,
            "/v1/repo-imports/import-missing",
            json!({}),
            &h.operator,
        )
        .await;
    assert_eq!(cancelled.status(), reqwest::StatusCode::OK);
    let progress: RepoImportProgress = cancelled.json().await.unwrap();
    assert_eq!(progress.state, RepoImportState::Cancelled);
}
