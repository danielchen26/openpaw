//! Loopback-only reverse proxy for dev-server previews.
//!
//! `openpaw-host` mounts this under `/v1/preview/{port}/{*rest}` so a phone on
//! the far end of an SSH port forward can look at a Vite/Next/Django dev server
//! running on the workstation. The proxy is deliberately narrow:
//!
//! * it only ever dials `127.0.0.1:<port>`, never a hostname and never a
//!   non-loopback address, so it can never be turned into an SSRF pivot;
//! * `<port>` must be in the operator's allowlist, checked *before* any socket
//!   is created;
//! * request and response bodies stream, so Server-Sent Events and Vite's HMR
//!   channel work instead of hanging in a buffer;
//! * only request bodies are size-limited (an upload from the phone is bounded,
//!   but a page or an infinite SSE stream from the dev server is not).

mod headers;
mod ws;

use std::error::Error as StdError;
use std::time::Duration;

use axum::body::Body;
use http::header::{CONTENT_LENGTH, HOST, HeaderValue};
use http::{Request, Response, Uri, Version};
use http_body_util::{LengthLimitError, Limited};
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::rt::TokioExecutor;

/// The loopback address every preview upstream must live on.
pub const LOOPBACK: [u8; 4] = [127, 0, 0, 1];

/// What a preview request is allowed to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreviewPolicy {
    /// Ports the operator opted into previewing.
    pub allowed_ports: Vec<u16>,
    /// Hard cap on a forwarded *request* body.
    pub max_body_bytes: usize,
}

impl PreviewPolicy {
    /// True when `port` may be dialed. Port 0 is never valid.
    pub fn allows(&self, port: u16) -> bool {
        port != 0 && self.allowed_ports.contains(&port)
    }
}

impl Default for PreviewPolicy {
    fn default() -> Self {
        Self {
            allowed_ports: vec![3000, 5173, 8000, 8080],
            max_body_bytes: 8 * 1024 * 1024,
        }
    }
}

/// Why a preview request could not be served.
#[derive(Debug, thiserror::Error)]
pub enum PreviewError {
    /// The port is not in [`PreviewPolicy::allowed_ports`]. No connection was
    /// attempted.
    #[error("preview port {0} is not allowlisted")]
    PortNotAllowed(u16),
    /// Nothing is listening on the loopback port, or the connection broke
    /// before a response head arrived.
    #[error("preview upstream 127.0.0.1:{port} is unreachable: {source}")]
    Unreachable {
        /// The loopback port that was dialed.
        port: u16,
        /// The transport error.
        source: Box<dyn StdError + Send + Sync>,
    },
    /// The request body exceeded [`PreviewPolicy::max_body_bytes`].
    #[error("preview request body exceeds the {limit} byte limit")]
    TooLarge {
        /// The configured limit in bytes.
        limit: usize,
    },
    /// The path or headers could not be turned into an upstream request.
    #[error("malformed preview request: {0}")]
    Malformed(String),
    /// The WebSocket bridge failed after the upstream was reached.
    #[error("preview websocket bridge failed: {0}")]
    WebSocket(String),
}

/// A streaming HTTP/WebSocket reverse proxy bound to loopback.
#[derive(Debug, Clone)]
pub struct Proxy {
    client: Client<HttpConnector, Body>,
    policy: PreviewPolicy,
}

impl Proxy {
    /// Build a proxy that enforces `policy`.
    pub fn new(policy: PreviewPolicy) -> Proxy {
        let mut connector = HttpConnector::new();
        connector.set_nodelay(true);
        connector.set_connect_timeout(Some(Duration::from_secs(5)));
        // Dev servers are HTTP/1.1; keeping the pool small keeps idle sockets
        // off a laptop that may be asleep half the day.
        let client = Client::builder(TokioExecutor::new())
            .pool_idle_timeout(Duration::from_secs(30))
            .pool_max_idle_per_host(4)
            .build(connector);
        Proxy { client, policy }
    }

    /// The policy this proxy enforces.
    pub fn policy(&self) -> &PreviewPolicy {
        &self.policy
    }

    /// Forward one HTTP request to `127.0.0.1:<port>` and stream the response
    /// back.
    ///
    /// `rest` is the still-percent-encoded path remainder after the mount
    /// prefix; the query string is taken from `req`. `mount_prefix` is the
    /// public path this proxy is mounted at (e.g. `/v1/preview/5173`) and is
    /// used to rewrite redirects and cookie scopes.
    pub async fn forward(
        &self,
        port: u16,
        rest: &str,
        req: Request<Body>,
        mount_prefix: &str,
    ) -> Result<Response<Body>, PreviewError> {
        if !self.policy.allows(port) {
            return Err(PreviewError::PortNotAllowed(port));
        }
        let (parts, body) = req.into_parts();
        let uri = upstream_uri("http", port, rest, parts.uri.query())?;

        // Cheap rejection first: an honest `content-length` lets us fail before
        // opening a socket or reading a byte.
        if let Some(len) = declared_length(&parts.headers)
            && len > self.policy.max_body_bytes as u64
        {
            return Err(PreviewError::TooLarge {
                limit: self.policy.max_body_bytes,
            });
        }

        // Chunked bodies have no declared length, so the limit is also enforced
        // while streaming; `Limited` aborts the upstream request instead of
        // letting an unbounded body through.
        let limited = Body::new(Limited::new(body, self.policy.max_body_bytes));
        let mut upstream = Request::builder()
            .method(parts.method)
            .uri(uri)
            .version(Version::HTTP_11)
            .body(limited)
            .map_err(|e| PreviewError::Malformed(e.to_string()))?;

        let out = upstream.headers_mut();
        headers::copy_request_headers(&parts.headers, out);
        let authority = format!("127.0.0.1:{port}");
        out.insert(
            HOST,
            HeaderValue::from_str(&authority)
                .map_err(|e| PreviewError::Malformed(e.to_string()))?,
        );

        let response = self
            .client
            .request(upstream)
            .await
            .map_err(|err| classify_send_error(port, self.policy.max_body_bytes, err))?;

        let (rparts, rbody) = response.into_parts();
        let mut builder = Response::builder().status(rparts.status);
        let dst = builder
            .headers_mut()
            .expect("fresh response builder always exposes headers");
        headers::copy_response_headers(&rparts.headers, dst, port, mount_prefix);
        builder
            // `Body::new` keeps the upstream body a stream: frames are handed
            // downstream as they arrive, which is what makes SSE and HMR work.
            .body(Body::new(rbody))
            .map_err(|e| PreviewError::Malformed(e.to_string()))
    }

    /// Bridge a client WebSocket to `127.0.0.1:<port>`, copying frames both
    /// directions until either side closes.
    pub async fn bridge_websocket(
        &self,
        port: u16,
        rest: &str,
        socket: axum::extract::ws::WebSocket,
        headers: http::HeaderMap,
    ) -> Result<(), PreviewError> {
        if !self.policy.allows(port) {
            return Err(PreviewError::PortNotAllowed(port));
        }
        ws::bridge(port, rest, socket, headers).await
    }
}

/// Build the upstream URI, pinned to the loopback authority.
fn upstream_uri(
    scheme: &str,
    port: u16,
    rest: &str,
    query: Option<&str>,
) -> Result<Uri, PreviewError> {
    let path = normalize_path(rest);
    let mut target = format!("{scheme}://127.0.0.1:{port}{path}");
    if let Some(query) = query
        && !query.is_empty()
    {
        target.push('?');
        target.push_str(query);
    }
    target
        .parse::<Uri>()
        .map_err(|e| PreviewError::Malformed(format!("{target}: {e}")))
}

/// Make `rest` an absolute path. A path that tries to inject an authority
/// (`//host/...`) is collapsed so the request cannot leave loopback even if a
/// caller forwards a hostile remainder.
fn normalize_path(rest: &str) -> String {
    let rest = rest.trim_start_matches('/');
    if rest.is_empty() {
        "/".to_owned()
    } else {
        format!("/{rest}")
    }
}

fn declared_length(headers: &http::HeaderMap) -> Option<u64> {
    headers
        .get(CONTENT_LENGTH)?
        .to_str()
        .ok()?
        .trim()
        .parse::<u64>()
        .ok()
}

/// A streaming body that outgrew the limit surfaces as a client error whose
/// source chain contains [`LengthLimitError`]; everything else is a transport
/// failure against a port we already validated.
fn classify_send_error(
    port: u16,
    limit: usize,
    err: hyper_util::client::legacy::Error,
) -> PreviewError {
    let mut source: Option<&(dyn StdError + 'static)> = Some(&err);
    while let Some(cause) = source {
        if cause.is::<LengthLimitError>() {
            return PreviewError::TooLarge { limit };
        }
        source = cause.source();
    }
    PreviewError::Unreachable {
        port,
        source: Box::new(err),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn policy_allows_only_listed_ports() {
        let policy = PreviewPolicy {
            allowed_ports: vec![5173, 3000],
            max_body_bytes: 1024,
        };
        assert!(policy.allows(5173));
        assert!(policy.allows(3000));
        assert!(!policy.allows(22));
        assert!(!policy.allows(0));
    }

    #[test]
    fn upstream_uri_is_pinned_to_loopback() {
        let uri = upstream_uri("http", 5173, "assets/app.js", Some("v=2")).unwrap();
        assert_eq!(uri.to_string(), "http://127.0.0.1:5173/assets/app.js?v=2");

        let uri = upstream_uri("http", 5173, "", None).unwrap();
        assert_eq!(uri.to_string(), "http://127.0.0.1:5173/");

        // A remainder that looks like an authority cannot redirect the dial.
        let uri = upstream_uri("http", 5173, "//evil.example/x", None).unwrap();
        assert_eq!(uri.host(), Some("127.0.0.1"));
        assert_eq!(uri.port_u16(), Some(5173));
        assert_eq!(uri.path(), "/evil.example/x");
    }

    #[test]
    fn declared_length_reads_content_length() {
        let mut headers = http::HeaderMap::new();
        headers.insert(CONTENT_LENGTH, HeaderValue::from_static("42"));
        assert_eq!(declared_length(&headers), Some(42));
        headers.insert(CONTENT_LENGTH, HeaderValue::from_static("nope"));
        assert_eq!(declared_length(&headers), None);
    }
}
