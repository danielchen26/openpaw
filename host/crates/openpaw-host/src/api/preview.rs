//! `ANY /v1/preview/{port}/{*rest}` — the dev-server preview proxy.
//!
//! Both the port and the path remainder are parsed out of the raw URI rather than
//! taken from a `Path` extractor, for two independent reasons:
//!
//! * the two routes have different parameter arity (`{port}` and `{port}/{*rest}`),
//!   and a single-arity extractor answers the other one with a 500;
//! * axum percent-decodes path parameters, and re-encoding a decoded path is
//!   lossy — `%2F` and `/` become indistinguishable, and a dev server holding a
//!   file with `#` or `?` in its name would receive a different request than the
//!   client sent.

use axum::extract::ws::WebSocketUpgrade;
use axum::extract::{FromRequestParts, OriginalUri, Request, State};
use axum::response::{IntoResponse, Response};

use crate::AppState;
use crate::api::{ApiError, preview_error};

/// Path prefix both preview routes live under.
const MOUNT_ROOT: &str = "/v1/preview/";

/// `ANY /v1/preview/{port}` and `ANY /v1/preview/{port}/{*rest}`.
pub async fn proxy(
    State(app): State<AppState>,
    OriginalUri(original): OriginalUri,
    request: Request,
) -> Result<Response, ApiError> {
    let (port, rest) = split_target(original.path())?;
    let mount_prefix = format!("{MOUNT_ROOT}{port}");
    let (mut parts, body) = request.into_parts();

    if is_websocket_upgrade(&parts.headers) {
        let upgrade = WebSocketUpgrade::from_request_parts(&mut parts, &())
            .await
            .map_err(|rejection| ApiError::bad_request(rejection.body_text()))?;
        // The upstream handshake needs the client's cookies and subprotocol, and an
        // HMR socket authenticates through its query string.
        let headers = parts.headers.clone();
        let target = match original.query() {
            Some(query) if !query.is_empty() => format!("{rest}?{query}"),
            _ => rest,
        };
        let proxy = app.proxy.clone();
        return Ok(upgrade
            .on_upgrade(move |socket| async move {
                if let Err(err) = proxy.bridge_websocket(port, &target, socket, headers).await {
                    tracing::warn!(port, %err, "preview websocket bridge ended with an error");
                }
            })
            .into_response());
    }

    app.proxy
        .forward(port, &rest, Request::from_parts(parts, body), &mount_prefix)
        .await
        .map(IntoResponse::into_response)
        .map_err(preview_error)
}

/// Split `/v1/preview/<port>/<rest>` into its port and its still-encoded
/// remainder.
fn split_target(path: &str) -> Result<(u16, String), ApiError> {
    let after = path
        .strip_prefix(MOUNT_ROOT)
        .ok_or_else(|| ApiError::not_found("not a preview path"))?;
    let (port, rest) = match after.find('/') {
        Some(index) => (&after[..index], &after[index..]),
        None => (after, ""),
    };
    let parsed: u16 = port
        .parse()
        .map_err(|_| ApiError::bad_request(format!("{port:?} is not a port number")))?;
    Ok((parsed, rest.to_owned()))
}

/// RFC 6455 upgrade detection: both header values are token lists, and both must
/// be checked case-insensitively.
fn is_websocket_upgrade(headers: &axum::http::HeaderMap) -> bool {
    let has_token = |name: axum::http::HeaderName, token: &str| {
        headers
            .get_all(name)
            .iter()
            .filter_map(|value| value.to_str().ok())
            .flat_map(|value| value.split(','))
            .any(|candidate| candidate.trim().eq_ignore_ascii_case(token))
    };
    has_token(axum::http::header::CONNECTION, "upgrade")
        && has_token(axum::http::header::UPGRADE, "websocket")
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::{HeaderMap, HeaderValue};

    fn target(path: &str) -> (u16, String) {
        split_target(path).expect("a preview path")
    }

    #[test]
    fn the_port_and_remainder_are_read_off_the_raw_path() {
        assert_eq!(target("/v1/preview/5173"), (5173, String::new()));
        assert_eq!(target("/v1/preview/5173/"), (5173, "/".to_owned()));
        assert_eq!(
            target("/v1/preview/5173/assets/app.js"),
            (5173, "/assets/app.js".to_owned())
        );
        assert_eq!(
            target("/v1/preview/8080/a/b/c"),
            (8080, "/a/b/c".to_owned())
        );
    }

    #[test]
    fn percent_encoding_in_the_remainder_survives() {
        assert_eq!(
            target("/v1/preview/5173/a%2Fb.txt").1,
            "/a%2Fb.txt",
            "an encoded slash must stay encoded"
        );
        assert_eq!(
            target("/v1/preview/5173/weird%23name.txt").1,
            "/weird%23name.txt"
        );
        assert_eq!(target("/v1/preview/5173/sp%20ace").1, "/sp%20ace");
    }

    #[test]
    fn a_non_numeric_or_out_of_range_port_is_a_client_error() {
        for path in [
            "/v1/preview/notaport/x",
            "/v1/preview/70000/x",
            "/v1/preview/-1/x",
            "/v1/preview//x",
        ] {
            let status = split_target(path).unwrap_err().status();
            assert_eq!(status, axum::http::StatusCode::BAD_REQUEST, "{path}");
        }
        assert_eq!(
            split_target("/v1/sessions").unwrap_err().status(),
            axum::http::StatusCode::NOT_FOUND
        );
    }

    #[test]
    fn upgrade_detection_reads_token_lists_case_insensitively() {
        let mut headers = HeaderMap::new();
        assert!(!is_websocket_upgrade(&headers));

        headers.insert("connection", HeaderValue::from_static("Upgrade"));
        headers.insert("upgrade", HeaderValue::from_static("websocket"));
        assert!(is_websocket_upgrade(&headers));

        // Browsers and proxies send multi-token Connection headers.
        headers.insert(
            "connection",
            HeaderValue::from_static("keep-alive, Upgrade"),
        );
        headers.insert("upgrade", HeaderValue::from_static("WebSocket"));
        assert!(is_websocket_upgrade(&headers));

        // A plain keep-alive request is not an upgrade.
        headers.insert("connection", HeaderValue::from_static("keep-alive"));
        assert!(!is_websocket_upgrade(&headers));

        // Neither is an upgrade to something else.
        headers.insert("connection", HeaderValue::from_static("upgrade"));
        headers.insert("upgrade", HeaderValue::from_static("h2c"));
        assert!(!is_websocket_upgrade(&headers));
    }
}
