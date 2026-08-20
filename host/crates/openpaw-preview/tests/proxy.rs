//! End-to-end tests for the preview proxy against a real upstream socket.
//!
//! The upstream is a hand-written HTTP/1.1 server rather than a framework, for two
//! reasons: it can produce responses a well-behaved server would not (to prove the
//! proxy sanitizes them), and it can control exactly when each byte is flushed,
//! which is the only way to prove that streaming really streams.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use axum::body::Body;
use futures::StreamExt;
use http::{Request, StatusCode};
use openpaw_preview::{PreviewError, PreviewPolicy, Proxy};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

// ---------------------------------------------------------------------------
// upstream harness
// ---------------------------------------------------------------------------

struct Upstream {
    port: u16,
    accepts: Arc<AtomicUsize>,
}

/// Start a loopback server that hands each connection's request head to
/// `handler` along with the still-open socket.
async fn spawn_upstream<F, Fut>(handler: F) -> Upstream
where
    F: Fn(String, TcpStream) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = ()> + Send + 'static,
{
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let accepts = Arc::new(AtomicUsize::new(0));

    let counter = Arc::clone(&accepts);
    let handler = Arc::new(handler);
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            counter.fetch_add(1, Ordering::SeqCst);
            let handler = Arc::clone(&handler);
            tokio::spawn(async move {
                let head = read_head(&mut socket).await;
                handler(head, socket).await;
            });
        }
    });

    Upstream { port, accepts }
}

/// Read bytes until the end of the request head.
async fn read_head(socket: &mut TcpStream) -> String {
    let mut buffer = Vec::new();
    let mut byte = [0u8; 1];
    while socket.read_exact(&mut byte).await.is_ok() {
        buffer.push(byte[0]);
        if buffer.ends_with(b"\r\n\r\n") {
            break;
        }
    }
    String::from_utf8_lossy(&buffer).into_owned()
}

fn request(method: &str, uri: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .body(Body::empty())
        .unwrap()
}

fn policy(port: u16) -> PreviewPolicy {
    PreviewPolicy {
        allowed_ports: vec![port],
        max_body_bytes: 64 * 1024,
    }
}

async fn body_text(response: http::Response<Body>) -> String {
    let bytes = axum::body::to_bytes(response.into_body(), 1024 * 1024)
        .await
        .unwrap();
    String::from_utf8_lossy(&bytes).into_owned()
}

/// Echo the request head back as the response body.
async fn echo_head(head: String, mut socket: TcpStream) {
    let response = format!(
        "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{head}",
        head.len()
    );
    let _ = socket.write_all(response.as_bytes()).await;
    let _ = socket.flush().await;
}

// ---------------------------------------------------------------------------
// policy
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_disallowed_port_is_rejected_without_any_connection_attempt() {
    let upstream = spawn_upstream(echo_head).await;
    // The live upstream's port is deliberately *not* in the allowlist.
    let proxy = Proxy::new(PreviewPolicy {
        allowed_ports: vec![1],
        max_body_bytes: 1024,
    });

    let error = proxy
        .forward(
            upstream.port,
            "/",
            request("GET", "/"),
            &format!("/v1/preview/{}", upstream.port),
        )
        .await
        .expect_err("a port outside the allowlist must be refused");

    assert!(
        matches!(error, PreviewError::PortNotAllowed(port) if port == upstream.port),
        "unexpected error: {error}"
    );

    // Give a hypothetical connection time to land before asserting it never did.
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert_eq!(
        upstream.accepts.load(Ordering::SeqCst),
        0,
        "the policy check must happen before any socket is opened"
    );
}

#[tokio::test]
async fn an_allowlisted_port_with_nothing_listening_is_unreachable() {
    // Bind and immediately drop, so the port is very likely free.
    let port = {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        listener.local_addr().unwrap().port()
    };
    let proxy = Proxy::new(policy(port));

    let error = proxy
        .forward(port, "/", request("GET", "/"), "/v1/preview/x")
        .await
        .expect_err("nothing is listening");
    assert!(
        matches!(error, PreviewError::Unreachable { port: p, .. } if p == port),
        "unexpected error: {error}"
    );
}

// ---------------------------------------------------------------------------
// request headers
// ---------------------------------------------------------------------------

#[tokio::test]
async fn the_host_header_is_rewritten_and_hop_by_hop_headers_are_stripped() {
    let upstream = spawn_upstream(echo_head).await;
    let proxy = Proxy::new(policy(upstream.port));

    let request = Request::builder()
        .method("GET")
        .uri("/assets/app.js?v=2")
        .header("host", "phone.local")
        .header("connection", "keep-alive, x-hop-only")
        .header("x-hop-only", "leaked")
        .header("upgrade", "h2c")
        .header("te", "trailers")
        .header("transfer-encoding", "chunked")
        .header("proxy-authorization", "Basic bGVha2Vk")
        .header("keep-alive", "timeout=5")
        // End-to-end headers that must arrive untouched.
        .header("accept", "application/json")
        .header("range", "bytes=0-1023")
        .header("if-none-match", "\"etag-abc\"")
        .header("cookie", "sid=abc")
        .header("user-agent", "OpenPaw/1.0")
        .body(Body::empty())
        .unwrap();

    let response = proxy
        .forward(
            upstream.port,
            "/assets/app.js",
            request,
            &format!("/v1/preview/{}", upstream.port),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let head = body_text(response).await.to_ascii_lowercase();

    // The upstream believes it is being addressed directly on loopback.
    assert!(
        head.contains(&format!("host: 127.0.0.1:{}", upstream.port)),
        "host was not rewritten:\n{head}"
    );
    assert!(
        !head.contains("phone.local"),
        "the client host leaked:\n{head}"
    );

    for stripped in [
        "x-hop-only",
        "upgrade:",
        "te:",
        "transfer-encoding:",
        "proxy-authorization",
        "keep-alive:",
    ] {
        assert!(
            !head.contains(stripped),
            "{stripped} should not be forwarded:\n{head}"
        );
    }

    for passed in [
        "accept: application/json",
        "range: bytes=0-1023",
        "if-none-match: \"etag-abc\"",
        "cookie: sid=abc",
        "user-agent: openpaw/1.0",
    ] {
        assert!(
            head.contains(passed),
            "{passed} should pass through:\n{head}"
        );
    }

    // The path and query reached the upstream verbatim.
    assert!(
        head.starts_with("get /assets/app.js?v=2 http/1.1"),
        "request line was rewritten:\n{head}"
    );
}

// ---------------------------------------------------------------------------
// response headers
// ---------------------------------------------------------------------------

#[tokio::test]
async fn redirects_and_cookies_are_rewritten_into_the_mount_prefix() {
    let upstream = spawn_upstream(|_head, mut socket| async move {
        let port = socket.local_addr().unwrap().port();
        let response = format!(
            "HTTP/1.1 302 Found\r\n\
             location: http://127.0.0.1:{port}/x\r\n\
             content-location: /canonical\r\n\
             set-cookie: sid=abc; Domain=localhost; Path=/; HttpOnly\r\n\
             set-cookie: theme=dark\r\n\
             connection: close\r\n\
             transfer-encoding: chunked\r\n\
             content-length: 0\r\n\r\n"
        );
        let _ = socket.write_all(response.as_bytes()).await;
        let _ = socket.flush().await;
    })
    .await;

    let proxy = Proxy::new(policy(upstream.port));
    let mount = format!("/v1/preview/{}", upstream.port);
    let response = proxy
        .forward(upstream.port, "/", request("GET", "/"), &mount)
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::FOUND);
    assert_eq!(
        response.headers().get("location").unwrap(),
        format!("{mount}/x").as_str(),
        "an absolute upstream redirect must land inside the mount"
    );
    assert_eq!(
        response.headers().get("content-location").unwrap(),
        format!("{mount}/canonical").as_str()
    );

    let cookies: Vec<&str> = response
        .headers()
        .get_all("set-cookie")
        .iter()
        .map(|value| value.to_str().unwrap())
        .collect();
    assert_eq!(cookies.len(), 2, "both cookies survive: {cookies:?}");
    let scoped = cookies
        .iter()
        .find(|c| c.starts_with("sid="))
        .expect("sid cookie");
    assert!(
        !scoped.to_ascii_lowercase().contains("domain="),
        "the upstream domain must be dropped: {scoped}"
    );
    assert!(
        scoped.contains(&format!("Path={mount}/")),
        "the cookie must be scoped to the mount: {scoped}"
    );
    assert!(
        scoped.contains("HttpOnly"),
        "other attributes survive: {scoped}"
    );

    let defaulted = cookies
        .iter()
        .find(|c| c.starts_with("theme="))
        .expect("theme cookie");
    assert!(
        defaulted.contains(&format!("Path={mount}/")),
        "a cookie with no Path is scoped explicitly: {defaulted}"
    );

    // Hop-by-hop response headers do not survive either.
    assert!(response.headers().get("connection").is_none());
    assert!(response.headers().get("transfer-encoding").is_none());
}

// ---------------------------------------------------------------------------
// streaming
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_server_sent_event_stream_is_delivered_incrementally() {
    /// The gap between the two upstream writes.
    const GAP: Duration = Duration::from_millis(400);

    let upstream = spawn_upstream(|_head, mut socket| async move {
        let head = "HTTP/1.1 200 OK\r\n\
                    content-type: text/event-stream\r\n\
                    cache-control: no-cache\r\n\
                    transfer-encoding: chunked\r\n\r\n";
        let _ = socket.write_all(head.as_bytes()).await;
        let first = "data: one\n\n";
        let _ = socket
            .write_all(format!("{:x}\r\n{first}\r\n", first.len()).as_bytes())
            .await;
        let _ = socket.flush().await;

        // Hold the second event back. If the proxy buffers the response, the
        // client cannot possibly see the first event before this sleep ends.
        tokio::time::sleep(GAP).await;

        let second = "data: two\n\n";
        let _ = socket
            .write_all(format!("{:x}\r\n{second}\r\n0\r\n\r\n", second.len()).as_bytes())
            .await;
        let _ = socket.flush().await;
    })
    .await;

    let proxy = Proxy::new(policy(upstream.port));
    let started = Instant::now();
    let response = proxy
        .forward(
            upstream.port,
            "/events",
            request("GET", "/events"),
            "/v1/preview/x",
        )
        .await
        .unwrap();
    assert_eq!(
        response.headers().get("content-type").unwrap(),
        "text/event-stream"
    );

    let mut stream = response.into_body().into_data_stream();

    let first = stream.next().await.expect("a first chunk").unwrap();
    let first_at = started.elapsed();
    assert_eq!(&first[..], b"data: one\n\n");
    assert!(
        first_at < GAP / 2,
        "the first event took {first_at:?}, so the response was buffered rather than streamed"
    );

    let second = stream.next().await.expect("a second chunk").unwrap();
    assert_eq!(&second[..], b"data: two\n\n");
    assert!(
        started.elapsed() >= GAP,
        "the second event arrived before the upstream sent it"
    );
}

// ---------------------------------------------------------------------------
// request body limits
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_declared_oversized_body_is_refused_before_dialing() {
    let upstream = spawn_upstream(echo_head).await;
    let proxy = Proxy::new(PreviewPolicy {
        allowed_ports: vec![upstream.port],
        max_body_bytes: 8,
    });

    let request = Request::builder()
        .method("POST")
        .uri("/upload")
        .header("content-length", "1024")
        .body(Body::from(vec![b'x'; 1024]))
        .unwrap();

    let error = proxy
        .forward(upstream.port, "/upload", request, "/v1/preview/x")
        .await
        .expect_err("an oversized body must be refused");
    assert!(
        matches!(error, PreviewError::TooLarge { limit: 8 }),
        "unexpected error: {error}"
    );

    tokio::time::sleep(Duration::from_millis(150)).await;
    assert_eq!(
        upstream.accepts.load(Ordering::SeqCst),
        0,
        "an honest content-length lets us refuse without opening a socket"
    );
}

#[tokio::test]
async fn an_undeclared_oversized_body_is_refused_while_it_streams() {
    let upstream = spawn_upstream(echo_head).await;
    let proxy = Proxy::new(PreviewPolicy {
        allowed_ports: vec![upstream.port],
        max_body_bytes: 16,
    });

    // A chunked body has no content-length, so the limit can only be enforced
    // during the read.
    let chunks = futures::stream::iter(
        (0..8).map(|_| Ok::<_, std::io::Error>(bytes::Bytes::from_static(&[b'x'; 8]))),
    );
    let request = Request::builder()
        .method("POST")
        .uri("/upload")
        .body(Body::from_stream(chunks))
        .unwrap();

    let error = proxy
        .forward(upstream.port, "/upload", request, "/v1/preview/x")
        .await
        .expect_err("a streaming body over the limit must be refused");
    assert!(
        matches!(error, PreviewError::TooLarge { limit: 16 }),
        "unexpected error: {error}"
    );
}

#[tokio::test]
async fn a_body_inside_the_limit_reaches_the_upstream() {
    let upstream = spawn_upstream(|head, mut socket| async move {
        // Read the declared body before replying so the client is not cut off.
        let length: usize = head
            .to_ascii_lowercase()
            .lines()
            .find_map(|line| line.strip_prefix("content-length:"))
            .and_then(|value| value.trim().parse().ok())
            .unwrap_or(0);
        let mut body = vec![0u8; length];
        let _ = socket.read_exact(&mut body).await;

        let response = format!(
            "HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
            body.len()
        );
        let _ = socket.write_all(response.as_bytes()).await;
        let _ = socket.write_all(&body).await;
        let _ = socket.flush().await;
    })
    .await;

    let proxy = Proxy::new(policy(upstream.port));
    let request = Request::builder()
        .method("POST")
        .uri("/upload")
        .header("content-length", "5")
        .body(Body::from("hello"))
        .unwrap();

    let response = proxy
        .forward(upstream.port, "/upload", request, "/v1/preview/x")
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(body_text(response).await, "hello");
}
