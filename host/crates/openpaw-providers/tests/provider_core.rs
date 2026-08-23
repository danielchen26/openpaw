use axum::{
    Json, Router,
    extract::Query,
    http::HeaderMap,
    routing::{delete, get, post},
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
            let repos: Vec<_> = (0..len).map(|i| json!({"id":i + ((page - 1) * 100),"name":format!("r{i}"),"full_name":format!("me/r{i}"),"private":false,"owner":{"login":"me"},"clone_url":format!("https://github.com/me/r{i}.git")})).collect();
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
async fn github_repository_metadata_preserves_stable_id_and_private_visibility() {
    let app = Router::new().route(
        "/user/repos",
        get(|| async {
            Json(json!([
                {"id": 123456789, "name":"public.repo", "full_name":"me/public.repo", "private":false, "owner":{"login":"me"}, "clone_url":"https://github.com/me/public.repo.git"},
                {"id": 987654321, "name":"private.repo", "full_name":"me/private.repo", "private":true, "owner":{"login":"me"}, "clone_url":"https://github.com/me/private.repo.git"},
                {"name":"fallback", "full_name":"me/fallback", "private":false, "owner":{"login":"me"}, "clone_url":"https://github.com/me/fallback.git"}
            ]))
        }),
    );
    let base = serve(app).await;
    let gh = GitHubProvider::new(PublicClientConfig::github_app("client", &base, &base));
    let repos = gh
        .list_repositories(&SecretToken::new("gh_secret_private".into()))
        .await
        .unwrap();

    assert_eq!(repos[0].provider_repo_id, "123456789");
    assert!(!repos[0].is_private);
    assert_eq!(repos[1].provider_repo_id, "987654321");
    assert!(repos[1].is_private);
    assert_eq!(repos[2].provider_repo_id, "me/fallback");
    let rendered = format!("{repos:?}");
    assert!(!rendered.contains("gh_secret_private"));
    assert!(!rendered.contains("Authorization"));
}

#[tokio::test]
async fn device_poll_400_pending_and_repeated_slow_down_grows_by_exact_five_seconds() {
    let step = Arc::new(Mutex::new(0usize));
    let app_step = step.clone();
    let app = Router::new().route(
        "/login/oauth/access_token",
        post(move || {
            let app_step = app_step.clone();
            async move {
                let mut n = app_step.lock().unwrap();
                let body = match *n {
                    0 => json!({"error":"authorization_pending"}),
                    _ => json!({"error":"slow_down"}),
                };
                *n += 1;
                (axum::http::StatusCode::BAD_REQUEST, Json(body))
            }
        }),
    );
    let base = serve(app).await;
    let gh = GitHubProvider::new(PublicClientConfig::github_app("client", &base, &base));

    assert_eq!(
        gh.poll_device_authorization_with_interval("dev", 7)
            .await
            .unwrap(),
        DevicePollState::Pending {
            interval_seconds: 7
        }
    );
    assert_eq!(
        gh.poll_device_authorization_with_interval("dev", 7)
            .await
            .unwrap(),
        DevicePollState::SlowDown {
            interval_seconds: 12
        }
    );
    assert_eq!(
        gh.poll_device_authorization_with_interval("dev", 12)
            .await
            .unwrap(),
        DevicePollState::SlowDown {
            interval_seconds: 17
        }
    );
}

#[tokio::test]
async fn hf_listing_uses_whoami_author_scope_and_preserves_link_cursor_for_all_repo_kinds() {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let app_seen = seen.clone();
    let app = Router::new()
        .route("/hf/api/whoami-v2", get(|| async { Json(json!({"name":"me"})) }))
        .route("/hf/api/{kind}", get(move |Query(params): Query<std::collections::HashMap<String, String>>, axum::extract::Path(kind): axum::extract::Path<String>| {
            let app_seen = app_seen.clone();
            async move {
                app_seen.lock().unwrap().push((kind.clone(), params.clone()));
                let mut headers = HeaderMap::new();
                let cursor = params.get("cursor").cloned();
                let id_kind = match kind.as_str() {
                    "datasets" => "ds",
                    "spaces" => "sp",
                    _ => "model",
                };
                if cursor.is_none() {
                    headers.insert("link", format!("</hf/api/{kind}?limit=100&full=false&author=me&cursor=opaque%2B{kind}>; rel=\"next\"").parse().unwrap());
                }
                let repo_id = format!("me/{id_kind}-{}", cursor.unwrap_or_else(|| "first".into()));
                (headers, Json(json!([{ "id": repo_id, "private": false }])))
            }
        }));
    let base = serve(app).await;
    let hf = HuggingFaceProvider::new(PublicClientConfig::hugging_face(
        "client",
        &base,
        format!("{base}/hf"),
    ));
    let repos = hf
        .list_repositories(&SecretToken::new("hf_secret".into()))
        .await
        .unwrap();

    assert_eq!(repos.len(), 6);
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 6);
    for (_, params) in seen.iter() {
        assert_eq!(params.get("author").map(String::as_str), Some("me"));
        assert_eq!(params.get("limit").map(String::as_str), Some("100"));
        assert_eq!(params.get("full").map(String::as_str), Some("false"));
    }
    assert!(
        seen.iter()
            .any(|(_, params)| params.get("cursor").map(String::as_str) == Some("opaque+models"))
    );
    assert!(
        seen.iter()
            .any(|(_, params)| params.get("cursor").map(String::as_str) == Some("opaque+datasets"))
    );
    assert!(
        seen.iter()
            .any(|(_, params)| params.get("cursor").map(String::as_str) == Some("opaque+spaces"))
    );
}

#[tokio::test]
async fn hf_repository_metadata_preserves_ids_visibility_and_kind_collisions() {
    let app = Router::new()
        .route(
            "/hf/api/whoami-v2",
            get(|| async { Json(json!({"name":"me"})) }),
        )
        .route(
            "/hf/api/{kind}",
            get(
                |axum::extract::Path(kind): axum::extract::Path<String>| async move {
                    let items = match kind.as_str() {
                        "datasets" => json!([
                            {"id":"me/shared.name", "private":true},
                            {"id":"me/dot.slash-resistant", "private":false}
                        ]),
                        "spaces" => json!([
                            {"id":"me/shared.name", "private":false},
                            {"id":"me/gated-space", "gated":true}
                        ]),
                        _ => json!([
                            {"id":"me/shared.name", "private":false},
                            {"modelId":"me/private-model", "private":true}
                        ]),
                    };
                    Json(items)
                },
            ),
        );
    let base = serve(app).await;
    let hf = HuggingFaceProvider::new(PublicClientConfig::hugging_face(
        "client",
        &base,
        format!("{base}/hf"),
    ));
    let repos = hf
        .list_repositories(&SecretToken::new("hf_secret_private".into()))
        .await
        .unwrap();

    assert!(
        repos
            .iter()
            .any(|r| r.provider_repo_id == "model:me/shared.name"
                && !r.is_private
                && r.https_url == "https://huggingface.co/me/shared.name")
    );
    assert!(
        repos
            .iter()
            .any(|r| r.provider_repo_id == "dataset:me/shared.name"
                && r.is_private
                && r.https_url == "https://huggingface.co/datasets/me/shared.name")
    );
    assert!(
        repos
            .iter()
            .any(|r| r.provider_repo_id == "space:me/shared.name"
                && !r.is_private
                && r.https_url == "https://huggingface.co/spaces/me/shared.name")
    );
    assert!(
        repos
            .iter()
            .any(|r| r.provider_repo_id == "space:me/gated-space" && r.is_private)
    );
    assert_eq!(
        repos
            .iter()
            .filter(|r| r.name == "shared.name")
            .map(|r| r.provider_repo_id.as_str())
            .collect::<std::collections::BTreeSet<_>>()
            .len(),
        3
    );
    let rendered = format!("{repos:?}");
    assert!(!rendered.contains("hf_secret_private"));
    assert!(!rendered.contains("Bearer"));
}

#[test]
fn clone_specs_reject_unapproved_hosts_and_url_tricks_before_token_use() {
    let gh = GitHubProvider::new(PublicClientConfig::github_app(
        "client",
        "https://github.com",
        "https://api.github.com",
    ));
    let hf = HuggingFaceProvider::new(PublicClientConfig::hugging_face(
        "client",
        "https://huggingface.co",
        "https://huggingface.co",
    ));
    let github_bad_urls = [
        "https://evil.example/me/r.git",
        "http://github.com/me/r.git",
        "https://token@github.com/me/r.git",
        "https://github.com:443/me/r.git",
        "https://github.com.evil.example/me/r.git",
        "https://github.com/me/r.git?redirect=https://evil.example",
    ];
    for url in github_bad_urls {
        let repo = Repository {
            provider_repo_id: "github:bad".into(),
            owner: "me".into(),
            name: "r".into(),
            https_url: url.into(),
            is_private: false,
        };
        let err = gh
            .clone_spec(&repo, SecretToken::new("gh_secret".into()))
            .unwrap_err();
        assert!(!format!("{err:?} {err}").contains("gh_secret"));
    }
    let hf_bad_urls = [
        "https://evil.example/me/r",
        "http://huggingface.co/me/r",
        "https://token@huggingface.co/me/r",
        "https://huggingface.co:443/me/r",
        "https://huggingface.co.evil.example/me/r",
        "https://huggingface.co/me/r#frag",
    ];
    for url in hf_bad_urls {
        let repo = Repository {
            provider_repo_id: "hf:bad".into(),
            owner: "me".into(),
            name: "r".into(),
            https_url: url.into(),
            is_private: false,
        };
        let err = hf
            .clone_spec(&repo, SecretToken::new("hf_secret".into()))
            .unwrap_err();
        assert!(!format!("{err:?} {err}").contains("hf_secret"));
    }
}

#[tokio::test]
async fn cancellation_prevents_requests_and_follow_on_listing_pages() {
    let requests = Arc::new(Mutex::new(0usize));
    let cancel = Arc::new(CancellationFlag::new());
    let handler_cancel = cancel.clone();
    let handler_requests = requests.clone();
    let app = Router::new().route("/user/repos", get(move || {
        let handler_cancel = handler_cancel.clone();
        let handler_requests = handler_requests.clone();
        async move {
            *handler_requests.lock().unwrap() += 1;
            handler_cancel.cancel();
            let mut headers = HeaderMap::new();
            headers.insert("link", "</user/repos?per_page=100&page=2>; rel=\"next\"".parse().unwrap());
            (headers, Json(json!([{ "id":1, "name":"r", "full_name":"me/r", "private":false, "owner":{"login":"me"}, "clone_url":"https://github.com/me/r.git" }])))
        }
    }));
    let base = serve(app).await;
    let gh = GitHubProvider::new(PublicClientConfig::github_app("client", &base, &base));
    let pre_cancel = CancellationFlag::new();
    pre_cancel.cancel();
    assert!(matches!(
        gh.list_repositories_with_cancel(&SecretToken::new("secret".into()), Some(&pre_cancel))
            .await,
        Err(ProviderError::Cancelled)
    ));
    assert_eq!(*requests.lock().unwrap(), 0);

    assert!(matches!(
        gh.list_repositories_with_cancel(&SecretToken::new("secret".into()), Some(cancel.as_ref()))
            .await,
        Err(ProviderError::Cancelled)
    ));
    assert_eq!(*requests.lock().unwrap(), 1);
}

#[tokio::test]
async fn rate_limit_headers_are_parsed_for_github_and_hugging_face() {
    let app = Router::new()
        .route(
            "/github/user/repos",
            get(|| async {
                let mut headers = HeaderMap::new();
                headers.insert("x-ratelimit-limit", "60".parse().unwrap());
                headers.insert("x-ratelimit-remaining", "0".parse().unwrap());
                headers.insert("x-ratelimit-reset", "4102444800".parse().unwrap());
                (axum::http::StatusCode::TOO_MANY_REQUESTS, headers, "nope")
            }),
        )
        .route(
            "/hf/api/whoami-v2",
            get(|| async {
                let mut headers = HeaderMap::new();
                headers.insert("ratelimit", "\"api\";r=2;t=9".parse().unwrap());
                headers.insert(
                    "ratelimit-policy",
                    "\"fixed window\";q=10;w=60".parse().unwrap(),
                );
                headers.insert("retry-after", "9".parse().unwrap());
                (axum::http::StatusCode::TOO_MANY_REQUESTS, headers, "nope")
            }),
        );
    let base = serve(app).await;
    let gh = GitHubProvider::new(PublicClientConfig::github_app(
        "client",
        &base,
        format!("{base}/github"),
    ));
    let hf = HuggingFaceProvider::new(PublicClientConfig::hugging_face(
        "client",
        &base,
        format!("{base}/hf"),
    ));

    let gh_err = gh
        .list_repositories(&SecretToken::new("secret".into()))
        .await
        .unwrap_err();
    let ProviderError::HttpStatus {
        rate_limit: Some(gh_rate),
        ..
    } = gh_err
    else {
        panic!("missing GitHub rate limit")
    };
    assert_eq!(gh_rate.limit, Some(60));
    assert_eq!(gh_rate.remaining, Some(0));
    assert!(gh_rate.reset_at.is_some());

    let hf_err = hf
        .list_repositories(&SecretToken::new("secret".into()))
        .await
        .unwrap_err();
    let ProviderError::HttpStatus {
        rate_limit: Some(hf_rate),
        ..
    } = hf_err
    else {
        panic!("missing HF rate limit")
    };
    assert_eq!(hf_rate.limit, Some(10));
    assert_eq!(hf_rate.remaining, Some(2));
    assert_eq!(hf_rate.retry_after_seconds, Some(9));
    assert!(hf_rate.reset_at.is_some());
}

#[tokio::test]
async fn provider_specific_remote_revoke_http_semantics_and_local_disconnect() {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let app_seen = seen.clone();
    let app = Router::new()
        .route(
            "/github/revoke",
            delete(move || {
                let app_seen = app_seen.clone();
                async move {
                    app_seen.lock().unwrap().push("github-delete".to_string());
                    axum::http::StatusCode::NO_CONTENT
                }
            }),
        )
        .route(
            "/hf/revoke",
            post({
                let seen = seen.clone();
                move || {
                    let seen = seen.clone();
                    async move {
                        seen.lock().unwrap().push("hf-post".to_string());
                        axum::http::StatusCode::OK
                    }
                }
            }),
        );
    let base = serve(app).await;
    let gh = GitHubProvider::new(
        PublicClientConfig::github_app("client", &base, &base).with_confidential(
            SecretToken::new("client_secret".into()),
            format!("{base}/github/revoke"),
        ),
    );
    let hf_public =
        HuggingFaceProvider::new(PublicClientConfig::hugging_face("client", &base, &base));
    let hf_conf = HuggingFaceProvider::new(
        PublicClientConfig::hugging_face("client", &base, &base).with_confidential(
            SecretToken::new("client_secret".into()),
            format!("{base}/hf/revoke"),
        ),
    );
    assert!(matches!(
        hf_public
            .revoke_remote(&SecretToken::new("secret".into()))
            .await,
        Err(ProviderError::RemoteRevokeUnsupported)
    ));
    gh.revoke_remote(&SecretToken::new("secret".into()))
        .await
        .unwrap();
    hf_conf
        .revoke_remote(&SecretToken::new("secret".into()))
        .await
        .unwrap();
    assert_eq!(*seen.lock().unwrap(), vec!["github-delete", "hf-post"]);

    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("token.json");
    let store = TokenStore::new(&path);
    store
        .save(&TokenSet::short_lived(
            SecretToken::new("secret".into()),
            None,
            60,
            vec![],
        ))
        .await
        .unwrap();
    store.delete_local().await.unwrap();
    assert!(store.load().await.unwrap().is_none());
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
        provider_repo_id: "1".into(),
        owner: "me".into(),
        name: "r".into(),
        https_url: canonical_https_clone_url("github.com", "me", "r"),
        is_private: false,
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
