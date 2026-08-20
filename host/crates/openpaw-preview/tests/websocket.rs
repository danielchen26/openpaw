//! WebSocket bridging tests.
//!
//! The full path is exercised: a real client handshakes against a real axum
//! server, that server hands the socket to [`Proxy::bridge_websocket`], and the
//! bridge handshakes against a real upstream echo server. Nothing here is a stub,
//! because the interesting failures in a WebSocket proxy are all in the handshake
//! and in the frame translation between the two tungstenite versions.

use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::extract::ws::WebSocketUpgrade;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::any;
use futures::{SinkExt, StreamExt};
use openpaw_preview::{PreviewError, PreviewPolicy, Proxy};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

/// Outcome of one bridge attempt, reported back to the test.
type Outcome = Result<(), PreviewError>;

#[derive(Clone)]
struct BridgeState {
    proxy: Arc<Proxy>,
    outcomes: mpsc::UnboundedSender<Outcome>,
}

/// Start an upstream WebSocket server that echoes text with an `echo:` prefix and
/// mirrors binary frames.
async fn spawn_ws_echo() -> u16 {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((socket, _)) = listener.accept().await {
            tokio::spawn(async move {
                let Ok(mut upstream) = tokio_tungstenite::accept_async(socket).await else {
                    return;
                };
                while let Some(Ok(message)) = upstream.next().await {
                    let reply = match message {
                        Message::Text(text) => Message::text(format!("echo:{text}")),
                        Message::Binary(bytes) => Message::Binary(bytes),
                        Message::Close(_) => break,
                        _ => continue,
                    };
                    if upstream.send(reply).await.is_err() {
                        break;
                    }
                }
                let _ = upstream.close(None).await;
            });
        }
    });
    port
}

/// Start the axum server that terminates the client socket and bridges it.
async fn spawn_bridge(policy: PreviewPolicy) -> (u16, mpsc::UnboundedReceiver<Outcome>) {
    let (outcomes, receiver) = mpsc::unbounded_channel();
    let state = BridgeState {
        proxy: Arc::new(Proxy::new(policy)),
        outcomes,
    };
    let app = Router::new()
        .route("/v1/preview/{port}/{*rest}", any(handler))
        .with_state(state);

    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    (port, receiver)
}

async fn handler(
    State(state): State<BridgeState>,
    Path((port, rest)): Path<(u16, String)>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Response {
    upgrade.on_upgrade(move |socket| async move {
        let outcome = state
            .proxy
            .bridge_websocket(port, &rest, socket, headers)
            .await;
        let _ = state.outcomes.send(outcome);
    })
}

#[tokio::test]
async fn a_websocket_echo_round_trips_through_the_bridge() {
    let upstream = spawn_ws_echo().await;
    let (proxy_port, mut outcomes) = spawn_bridge(PreviewPolicy {
        allowed_ports: vec![upstream],
        max_body_bytes: 1024,
    })
    .await;

    let url = format!("ws://127.0.0.1:{proxy_port}/v1/preview/{upstream}/hmr");
    let (mut client, response) = tokio_tungstenite::connect_async(&url)
        .await
        .expect("the handshake must succeed through the proxy");
    assert_eq!(response.status().as_u16(), 101);

    client.send(Message::text("hello")).await.unwrap();
    let reply = client.next().await.expect("a reply").unwrap();
    assert_eq!(reply.into_text().unwrap().as_str(), "echo:hello");

    // Binary frames survive the translation between the two message types.
    client
        .send(Message::Binary(bytes::Bytes::from_static(b"\x00\x01\x02")))
        .await
        .unwrap();
    let reply = client.next().await.expect("a binary reply").unwrap();
    assert_eq!(reply.into_data().as_ref(), b"\x00\x01\x02");

    // Several messages in a row keep working: the copy loop is a loop.
    for n in 0..3 {
        client.send(Message::text(format!("n{n}"))).await.unwrap();
        let reply = client.next().await.expect("a reply").unwrap();
        assert_eq!(reply.into_text().unwrap().as_str(), format!("echo:n{n}"));
    }

    // Closing the client ends the bridge cleanly rather than with an error.
    client.close(None).await.unwrap();
    let outcome = tokio::time::timeout(Duration::from_secs(5), outcomes.recv())
        .await
        .expect("the bridge should finish")
        .expect("an outcome");
    assert!(
        outcome.is_ok(),
        "clean close reported an error: {outcome:?}"
    );
}

#[tokio::test]
async fn a_disallowed_port_is_refused_before_the_upstream_handshake() {
    let upstream = spawn_ws_echo().await;
    // The live echo server's port is not allowlisted.
    let (proxy_port, mut outcomes) = spawn_bridge(PreviewPolicy {
        allowed_ports: vec![1],
        max_body_bytes: 1024,
    })
    .await;

    let url = format!("ws://127.0.0.1:{proxy_port}/v1/preview/{upstream}/hmr");
    let (mut client, _response) = tokio_tungstenite::connect_async(&url).await.unwrap();

    let outcome = tokio::time::timeout(Duration::from_secs(5), outcomes.recv())
        .await
        .expect("the bridge should refuse promptly")
        .expect("an outcome");
    assert!(
        matches!(outcome, Err(PreviewError::PortNotAllowed(port)) if port == upstream),
        "unexpected outcome: {outcome:?}"
    );

    let _ = client.close(None).await;
}

#[tokio::test]
async fn an_upstream_that_is_not_listening_reports_unreachable() {
    let dead = {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        listener.local_addr().unwrap().port()
    };
    let (proxy_port, mut outcomes) = spawn_bridge(PreviewPolicy {
        allowed_ports: vec![dead],
        max_body_bytes: 1024,
    })
    .await;

    let url = format!("ws://127.0.0.1:{proxy_port}/v1/preview/{dead}/hmr");
    let (mut client, _response) = tokio_tungstenite::connect_async(&url).await.unwrap();

    let outcome = tokio::time::timeout(Duration::from_secs(5), outcomes.recv())
        .await
        .expect("the bridge should fail promptly")
        .expect("an outcome");
    assert!(
        matches!(outcome, Err(PreviewError::Unreachable { port, .. }) if port == dead),
        "unexpected outcome: {outcome:?}"
    );
    let _ = client.close(None).await;
}
