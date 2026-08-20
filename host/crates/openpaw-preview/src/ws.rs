//! WebSocket bridging for the preview proxy.
//!
//! Vite/Next HMR and dev-server live-reload channels are WebSockets, so a
//! preview that only spoke HTTP would show a page that never updates. This
//! module terminates the phone's WebSocket in axum, opens a second WebSocket to
//! `127.0.0.1:<port>`, and copies frames in both directions until either peer
//! closes.

use axum::extract::ws::{CloseFrame as DownCloseFrame, Message as DownMessage, WebSocket};
use futures::{SinkExt, StreamExt};
use http::header::{HeaderMap, HeaderName};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message as UpMessage;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::protocol::CloseFrame as UpCloseFrame;

use crate::{PreviewError, headers, normalize_path};

/// Handshake headers the upstream client generates for itself; forwarding the
/// downstream copies would produce a mismatched or double handshake.
const HANDSHAKE_OWNED: &[&str] = &[
    "host",
    "sec-websocket-key",
    "sec-websocket-version",
    "sec-websocket-accept",
    // Extension negotiation is per hop: we relay decoded frames, so each hop
    // negotiates compression independently.
    "sec-websocket-extensions",
    "content-length",
];

/// Open the upstream socket and copy frames until either side closes.
///
/// `rest` is the path remainder after the mount prefix and may carry a `?query`
/// (Vite's HMR socket authenticates with one).
pub(crate) async fn bridge(
    port: u16,
    rest: &str,
    socket: WebSocket,
    request_headers: HeaderMap,
) -> Result<(), PreviewError> {
    let target = format!("ws://127.0.0.1:{port}{}", normalize_path(rest));
    let mut request = target
        .as_str()
        .into_client_request()
        .map_err(|e| PreviewError::Malformed(format!("{target}: {e}")))?;
    forward_handshake_headers(&request_headers, request.headers_mut(), port);

    let stream = TcpStream::connect(("127.0.0.1", port))
        .await
        .map_err(|source| PreviewError::Unreachable {
            port,
            source: Box::new(source),
        })?;
    let _ = stream.set_nodelay(true);

    let (upstream, _response) = tokio_tungstenite::client_async(request, stream)
        .await
        .map_err(|source| PreviewError::Unreachable {
            port,
            source: Box::new(source),
        })?;

    let (mut up_sink, mut up_stream) = upstream.split();
    let (mut down_sink, mut down_stream) = socket.split();
    let mut failure: Option<String> = None;

    loop {
        tokio::select! {
            from_client = down_stream.next() => match from_client {
                Some(Ok(message)) => {
                    let closing = matches!(message, DownMessage::Close(_));
                    if let Some(message) = to_upstream(message)
                        && let Err(err) = up_sink.send(message).await {
                            failure = Some(format!("upstream write: {err}"));
                            break;
                        }
                    if closing {
                        break;
                    }
                }
                Some(Err(err)) => {
                    failure = Some(format!("client read: {err}"));
                    break;
                }
                None => break,
            },
            from_upstream = up_stream.next() => match from_upstream {
                Some(Ok(message)) => {
                    let closing = matches!(message, UpMessage::Close(_));
                    if let Some(message) = to_downstream(message)
                        && let Err(err) = down_sink.send(message).await {
                            failure = Some(format!("client write: {err}"));
                            break;
                        }
                    if closing {
                        break;
                    }
                }
                Some(Err(err)) => {
                    failure = Some(format!("upstream read: {err}"));
                    break;
                }
                None => break,
            },
        }
    }

    // Both closes are best-effort: the peer that hung up first is already gone.
    let _ = up_sink.close().await;
    let _ = down_sink.close().await;

    match failure {
        Some(reason) => Err(PreviewError::WebSocket(reason)),
        None => Ok(()),
    }
}

/// Copy the client's end-to-end handshake headers (cookies, subprotocol,
/// authorization) onto the upstream handshake.
///
/// `host` and `origin` are rewritten to the loopback origin for the same reason
/// `forward` rewrites `Host`: dev servers validate them against their own
/// address, and this hop is already authenticated by the daemon's capability
/// check, so the origin check adds nothing here.
fn forward_handshake_headers(src: &HeaderMap, dst: &mut HeaderMap, port: u16) {
    for (name, value) in src.iter() {
        if headers::is_hop_by_hop(name) {
            continue;
        }
        if HANDSHAKE_OWNED.iter().any(|h| *h == name.as_str()) {
            continue;
        }
        if name.as_str() == "origin" {
            continue;
        }
        dst.append(name.clone(), value.clone());
    }
    if let Ok(origin) = format!("http://127.0.0.1:{port}").parse() {
        dst.insert(HeaderName::from_static("origin"), origin);
    }
}

fn to_upstream(message: DownMessage) -> Option<UpMessage> {
    Some(match message {
        DownMessage::Text(text) => UpMessage::Text(text.as_str().into()),
        DownMessage::Binary(bytes) => UpMessage::Binary(bytes),
        DownMessage::Ping(bytes) => UpMessage::Ping(bytes),
        DownMessage::Pong(bytes) => UpMessage::Pong(bytes),
        DownMessage::Close(frame) => UpMessage::Close(frame.map(|frame| UpCloseFrame {
            code: frame.code.into(),
            reason: frame.reason.as_str().into(),
        })),
    })
}

fn to_downstream(message: UpMessage) -> Option<DownMessage> {
    Some(match message {
        UpMessage::Text(text) => DownMessage::Text(text.as_str().into()),
        UpMessage::Binary(bytes) => DownMessage::Binary(bytes),
        UpMessage::Ping(bytes) => DownMessage::Ping(bytes),
        UpMessage::Pong(bytes) => DownMessage::Pong(bytes),
        UpMessage::Close(frame) => DownMessage::Close(frame.map(|frame| DownCloseFrame {
            code: frame.code.into(),
            reason: frame.reason.as_str().into(),
        })),
        // Raw frames are only produced by the low-level writer API, never by
        // reading a stream.
        UpMessage::Frame(_) => return None,
    })
}
