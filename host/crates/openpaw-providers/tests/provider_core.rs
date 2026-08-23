use axum::{
    Json, Router,
    extract::Query,
    http::HeaderMap,
    routing::{get, post},
};
use openpaw_providers::*;
use serde_json::json;
use std::sync::{Arc, Mutex};

async fn serve(app: Router) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    format!("http://{addr}")
}

#[test]
fn secret_token_debug_and_display_are_redacted() {
    let token = SecretToken::new("gho_super_secret".to_string());
    assert_eq!(format!("{token}"), "<redacted>");
    assert_eq!(format!("{token:?}"), "SecretToken(<redacted>)");
}

#[test]
fn provider_errors_do_not_reveal_secret_values() {
    let err = ProviderError::http_status(
        "https://example.invalid",
        401,
        Some(SecretToken::new("hf_secret".into())),
    );
    let rendered = format!("{err:?} {err}");
    assert!(!rendered.contains("hf_secret"));
}

#[test]
fn github_minimum_scopes_avoid_coarse_repo_by_default() {
    let gh = GitHubProvider::new(PublicClientConfig::github_app(
        "client",
        "https://github.test",
        "https://api.github.test",
    ));
    assert_eq!(gh.minimum_scopes(), &["read:user"]);
    assert!(!gh.minimum_scopes().contains(&"repo"));
}

#[tokio::test]
async fn device_poll_states_and_hf_refresh_are_supported() {
    let step = Arc::new(Mutex::new(0usize));
    let app_step = step.clone();
    let app = Router::new()
        .route("/oauth/device", post(|| async { Json(json!({"device_code":"dev","user_code":"ABCD","verification_uri":"https://hf/device","expires_in":600,"interval":5})) }))
        .route("/oauth/token", post(move || {
            let app_step = app_step.clone();
            async move {
                let mut n = app_step.lock().unwrap();
                let body = match *n {
                    0 => json!({"error":"authorization_pending"}),
                    1 => json!({"error":"slow_down"}),
                    2 => json!({"access_token":"access-secret","refresh_token":"refresh-secret","expires_in":60,"scope":"read-repos"}),
                    _ => json!({"access_token":"new-access-secret","refresh_token":"refresh-secret","expires_in":60,"scope":"read-repos"}),
                };
                *n += 1;
                Json(body)
            }
        }));
    let base = serve(app).await;
    let hf = HuggingFaceProvider::new(PublicClientConfig::hugging_face("client", &base, &base));
    assert_eq!(
        hf.begin_device_authorization(hf.minimum_scopes())
            .await
            .unwrap()
            .device_code,
        "dev"
    );
    assert_eq!(
        hf.poll_device_authorization("dev").await.unwrap(),
        DevicePollState::Pending {
            interval_seconds: 5
        }
    );
    assert!(matches!(
        hf.poll_device_authorization("dev").await.unwrap(),
        DevicePollState::SlowDown { .. }
    ));
    let authorized = hf.poll_device_authorization("dev").await.unwrap();
    let DevicePollState::Authorized(tokens) = authorized else {
        panic!("not authorized")
    };
    assert!(tokens.is_expiring());
    let refreshed = hf
        .refresh(tokens.refresh_token.as_ref().unwrap())
        .await
        .unwrap();
    assert_eq!(refreshed.scopes, vec!["read-repos"]);
    assert!(!format!("{refreshed:?}").contains("new-access-secret"));
}

#[tokio::test]
async fn github_repository_listing_uses_real_page_parameters() {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let app_seen = seen.clone();
    let app = Router::new().route("/user/repos", get(move |Query(params): Query<std::collections::HashMap<String, String>>| {
        let app_seen = app_seen.clone();
        async move {
            app_seen.lock().unwrap().push(params.clone());
            let page: usize = params["page"].parse().unwrap();
            let len = if page == 1 { 100 } else { 1 };
            let repos: Vec<_> = (0..len).map(|i| json!({"name":format!("r{i}"),"owner":{"login":"me"},"clone_url":format!("https://github.example/me/r{i}.git")})).collect();
            let mut headers = HeaderMap::new();
            if page == 1 {
                headers.insert("link", format!("<{}/user/repos?per_page=100&page=2>; rel=\"next\"", params.get("base").map_or("", String::as_str)).parse().unwrap());
            }
            (headers, Json(repos))
        }
    }));
    let base = serve(app).await;
    let gh = GitHubProvider::new(PublicClientConfig::github_app("client", &base, &base));
    let repos = gh
        .list_repositories(&SecretToken::new("secret".into()))
        .await
        .unwrap();
    assert_eq!(repos.len(), 101);
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0]["per_page"], "100");
    assert_eq!(seen[0]["page"], "1");
    assert_eq!(seen[1]["page"], "2");
}

#[tokio::test]
async fn token_store_is_0600_atomic_and_delete_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("token.json");
    let store = TokenStore::new(&path);
    let token = TokenSet::short_lived(
        SecretToken::new("store-secret".into()),
        None,
        60,
        vec!["read:user".into()],
    );
    store.save(&token).await.unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    let loaded = store.load().await.unwrap().unwrap();
    assert_eq!(loaded.scopes, vec!["read:user"]);
    store.delete_local().await.unwrap();
    store.delete_local().await.unwrap();
    assert!(store.load().await.unwrap().is_none());
}

#[tokio::test]
async fn remote_revoke_requires_confidential_config_and_status_is_sanitized() {
    let gh = GitHubProvider::new(PublicClientConfig::github_app(
        "client",
        "http://localhost",
        "http://localhost",
    ));
    assert!(matches!(
        gh.revoke_remote(&SecretToken::new("secret".into())).await,
        Err(ProviderError::MissingConfidentialClient)
    ));
    let token = TokenSet::short_lived(
        SecretToken::new("secret".into()),
        None,
        60,
        vec!["read:user".into()],
    );
    let status = gh.status(Some("octo".into()), Some(&token));
    assert_eq!(status.identity.as_deref(), Some("octo"));
    assert_eq!(status.scopes, vec!["read:user"]);
    assert!(!format!("{status:?}").contains("secret"));
    let cancel = CancellationFlag::new();
    cancel.cancel();
    cancel.cancel();
    assert!(cancel.is_cancelled());
}

#[test]
fn canonical_clone_spec_has_https_url_and_secret_credential_seam() {
    let repo = Repository {
        owner: "me".into(),
        name: "r".into(),
        https_url: canonical_https_clone_url("github.com", "me", "r"),
    };
    let gh = GitHubProvider::new(PublicClientConfig::github_app(
        "client",
        "https://github.com",
        "https://api.github.com",
    ));
    let spec = gh
        .clone_spec(&repo, SecretToken::new("short-lived".into()))
        .unwrap();
    assert_eq!(spec.url, "https://github.com/me/r.git");
    assert_eq!(spec.username, "x-access-token");
    assert!(!format!("{spec:?}").contains("short-lived"));
}
